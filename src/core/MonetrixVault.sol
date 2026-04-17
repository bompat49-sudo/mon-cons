// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../tokens/USDM.sol";
import "../tokens/sUSDM.sol";
import "./MonetrixConfig.sol";
import "./InsuranceFund.sol";
import "../interfaces/IHyperCore.sol";
import "../interfaces/IActionEncoder.sol";
import "../interfaces/HyperCoreConstants.sol";
import "../interfaces/IMonetrixAccountant.sol";
import "../interfaces/IRedeemEscrow.sol";
import "../interfaces/IYieldEscrow.sol";
import "./MonetrixAccountant.sol";
import {MonetrixGovernedUpgradeable} from "../governance/MonetrixGovernedUpgradeable.sol";

/// @title MonetrixVault - Core vault managing USDC deposits, USDM minting, redemption queue, and L1 hedge execution
/// @dev Role mapping (via shared MonetrixAccessController):
///      - GUARDIAN: pause / unpause (delay=0)
///      - OPERATOR: bridge / hedge / HLP / yield-distribution (delay=0)
///      - GOVERNOR: set* / emergency* (24h timelock)
///      - UPGRADER: _authorizeUpgrade (48h timelock, inherited from base)
contract MonetrixVault is PausableUpgradeable, ReentrancyGuard, MonetrixGovernedUpgradeable {
    using SafeERC20 for IERC20;

    enum BridgeTarget { Vault, Multisig }

    // ═══════════════════════════════════════════════════════════
    //                      STATE
    // ═══════════════════════════════════════════════════════════

    // ─── Core references ────────────────────────────────────
    IERC20 public usdc;
    USDM public usdm;
    sUSDM public susdm;
    MonetrixConfig public config;
    IActionEncoder public encoder;
    address public coreDepositWallet;
    InsuranceFund public insuranceFund;
    address public accountant;
    address public multisigVault;
    address public redeemEscrow;
    address public yieldEscrow;

    // ─── Operational state ──────────────────────────────────
    bool public hlpDepositEnabled;
    bool public multisigVaultEnabled;
    uint256 public lastBridgeTimestamp;

    // ─── L1 principal tracking ───────────────────────────────
    uint256 public outstandingL1Principal;
    /// @dev DEPRECATED. Previously tracked HLP principal for the old `min(equity, principal)`
    ///      backing cap. As of the mark-to-market migration, HLP equity is counted at full
    ///      mark value in MonetrixAccountant, so this counter is no longer read anywhere.
    ///      Slot preserved (private) for UUPS storage-layout safety. Do NOT re-use — any
    ///      new state variable must be appended at the end and shrink `__gap`.
    uint256 private _deprecated_outstandingHlpPrincipal;
    uint256 public bridgeRetentionAmount;

    // ─── Redeem queue ───────────────────────────────────────
    struct RedeemRequest {
        address owner;
        uint152 usdmAmount;
        uint104 cooldownEnd;
    }

    uint256 public nextRedeemId;
    mapping(uint256 => RedeemRequest) public redeemRequests;
    mapping(address => uint256[]) private _userRedeemIds;

    uint256[50] private __gap;

    // ─── Events ─────────────────────────────────────────────
    event Deposited(address indexed user, uint256 amount);
    event RedeemRequested(uint256 indexed requestId, address indexed owner, uint256 usdmAmount, uint256 cooldownEnd);
    event RedeemClaimed(uint256 indexed requestId, address indexed owner, uint256 usdmAmount);
    event BridgedToL1(uint256 amount);
    event PrincipalBridgedFromL1(uint256 amount);
    event YieldBridgedFromL1(uint256 amount);
    event YieldCollected(uint256 amount);
    event YieldDistributed(uint256 totalYield, uint256 userShare, uint256 insuranceShare, uint256 foundationShare);
    event HedgeExecuted(uint256 indexed batchId, uint32 spotAsset, uint32 perpAsset, uint64 size);
    event HedgeClosed(uint256 indexed positionId, uint32 spotAsset, uint64 size);
    event HedgeRepaired(uint256 indexed positionId, uint16 residualBps);
    event HlpDeposited(uint64 usdAmount);
    event HlpWithdrawn(uint64 usdAmount);
    event HlpDepositEnabledUpdated(bool enabled);
    event RedemptionsFunded(uint256 amount);
    event RedeemEscrowReclaimed(uint256 amount);
    event EmergencyActionSent(address indexed sender, bytes32 dataHash);
    event EncoderUpdated(address newEncoder);
    event AccountantUpdated(address newAccountant);
    event MultisigVaultUpdated(address newMultisigVault);
    event RedeemEscrowUpdated(address redeemEscrow);
    event YieldEscrowUpdated(address yieldEscrow);
    event BridgeRetentionAmountUpdated(uint256 amount);



    // ═══════════════════════════════════════════════════════════
    //                    INITIALIZER
    // ═══════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _usdc,
        address _usdm,
        address _susdm,
        address _config,
        address _encoder,
        address _coreDepositWallet,
        address _insuranceFund,
        address _acl
    ) external initializer {
        require(_usdc != address(0) && _usdm != address(0) && _susdm != address(0), "Vault: zero token");
        require(_config != address(0) && _encoder != address(0) && _coreDepositWallet != address(0), "Vault: zero dep");
        require(_insuranceFund != address(0), "Vault: zero addr");

        __Pausable_init();
        __Governed_init(_acl);

        usdc = IERC20(_usdc);
        usdm = USDM(_usdm);
        susdm = sUSDM(_susdm);
        config = MonetrixConfig(_config);
        encoder = IActionEncoder(_encoder);
        coreDepositWallet = _coreDepositWallet;
        insuranceFund = InsuranceFund(_insuranceFund);
        lastBridgeTimestamp = block.timestamp;
        hlpDepositEnabled = true;
    }

    
    // ═══════════════════════════════════════════════════════════
    //                      MODIFIER
    // ═══════════════════════════════════════════════════════════

    modifier requireWired() {
        require(accountant != address(0) && redeemEscrow != address(0) && yieldEscrow != address(0), "Vault: not wired");
        _;
    }

    // ═══════════════════════════════════════════════════════════
    //                   USER OPERATIONS
    // ═══════════════════════════════════════════════════════════

    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        require(amount >= config.minDepositAmount(), "Vault: below minimum");
        require(amount <= config.maxDepositAmount(), "Vault: above maximum");
        uint256 maxTVL = config.maxTVL();
        if (maxTVL > 0) {
            require(usdm.totalSupply() + amount <= maxTVL, "Vault: TVL cap exceeded");
        }
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        usdm.mint(msg.sender, amount);
        emit Deposited(msg.sender, amount);
    }

    function requestRedeem(uint256 usdmAmount) external nonReentrant whenNotPaused requireWired returns (uint256 requestId) {
        require(usdmAmount > 0, "Vault: zero amount");
        IERC20(address(usdm)).safeTransferFrom(msg.sender, address(this), usdmAmount);
        IRedeemEscrow(redeemEscrow).addObligation(usdmAmount);

        requestId = nextRedeemId++;
        redeemRequests[requestId] = RedeemRequest({
            owner: msg.sender,
            usdmAmount: uint152(usdmAmount),
            cooldownEnd: uint104(block.timestamp + config.redeemCooldown())
        });
        _userRedeemIds[msg.sender].push(requestId);
        emit RedeemRequested(requestId, msg.sender, usdmAmount, block.timestamp + config.redeemCooldown());
    }

    function claimRedeem(uint256 requestId) external nonReentrant whenNotPaused requireWired {
        RedeemRequest memory req = redeemRequests[requestId];
        require(req.usdmAmount > 0, "Vault: already claimed");
        require(msg.sender == req.owner, "Vault: not owner");
        require(block.timestamp >= req.cooldownEnd, "Vault: cooldown active");
        uint256 amount = req.usdmAmount;
        delete redeemRequests[requestId];
        _removeUserRedeemId(req.owner, requestId);

        usdm.burn(amount);
        IRedeemEscrow(redeemEscrow).payOut(msg.sender, amount);
        emit RedeemClaimed(requestId, msg.sender, amount);
    }

    // ═══════════════════════════════════════════════════════════
    //                 OPERATOR OPERATIONS
    // ═══════════════════════════════════════════════════════════

    // ─── Bridge (EVM ↔ L1) ──────────────────────────────────
    // NOTE: Once the vault contract account supports Portfolio Margin,
    // all positions will be held by the vault directly and multisigVault
    // will be disabled.
    function keeperBridge(BridgeTarget target) external onlyOperator requireWired {
        require(block.timestamp >= lastBridgeTimestamp + config.bridgeInterval(), "Vault: too early");
        uint256 amount = netBridgeable();
        require(amount > 0, "Vault: nothing to bridge");
        address recipient = (target == BridgeTarget.Multisig && multisigVaultEnabled && multisigVault != address(0))
            ? multisigVault
            : address(this);
        outstandingL1Principal += amount;
        lastBridgeTimestamp = block.timestamp;
        usdc.forceApprove(coreDepositWallet, amount);
        ICoreDepositWallet(coreDepositWallet).depositFor(recipient, amount, HyperCoreConstants.SPOT_DEX);
        emit BridgedToL1(amount);
    }

    function bridgePrincipalFromL1(uint256 amount) external onlyOperator requireWired {
        require(amount > 0, "Vault: zero amount");
        uint256 shortfall = redemptionShortfall();
        require(amount <= shortfall, "Vault: exceeds redemption shortfall");
        require(amount <= outstandingL1Principal, "Vault: exceeds L1 principal");
        outstandingL1Principal -= amount;
        _sendL1Bridge(amount);
        emit PrincipalBridgedFromL1(amount);
    }

    function bridgeYieldFromL1(uint256 amount) external onlyOperator requireWired {
        require(amount > 0, "Vault: zero amount");
        require(amount <= yieldShortfall(), "Vault: exceeds yield shortfall");
        _sendL1Bridge(amount);
        emit YieldBridgedFromL1(amount);
    }

    // ─── Hedge execution ────────────────────────────────────

    function executeHedge(uint256 batchId, HedgeParams calldata params)
        external
        onlyOperator
        whenNotPaused
    {
        require(params.size > 0, "Vault: zero size");
        _requireHedgePair(params.perpAsset, params.spotAsset);

        bytes memory spotAction = encoder.encodeBuySpot(params);
        bytes memory perpAction = encoder.encodeShortPerp(params);

        ICoreWriter(HyperCoreConstants.CORE_WRITER).sendRawAction(spotAction);
        ICoreWriter(HyperCoreConstants.CORE_WRITER).sendRawAction(perpAction);

        emit HedgeExecuted(batchId, params.spotAsset, params.perpAsset, params.size);
    }

    function closeHedge(CloseParams calldata params) external onlyOperator whenNotPaused {
        _requireHedgePair(params.perpAsset, params.spotAsset);

        bytes memory sellSpotAction = encoder.encodeSellSpot(params);
        bytes memory closePerpAction = encoder.encodeClosePerp(params);

        ICoreWriter(HyperCoreConstants.CORE_WRITER).sendRawAction(sellSpotAction);
        ICoreWriter(HyperCoreConstants.CORE_WRITER).sendRawAction(closePerpAction);

        emit HedgeClosed(params.positionId, params.spotAsset, params.size);
    }

    function repairHedge(uint256 positionId, RepairParams calldata params)
        external
        onlyOperator
        whenNotPaused
    {
        _requireRepairAsset(params.asset, params.isPerp);

        bytes memory repairAction = encoder.encodeRepairAction(params);
        ICoreWriter(HyperCoreConstants.CORE_WRITER).sendRawAction(repairAction);

        emit HedgeRepaired(positionId, params.residualBps);
    }

    // ─── HLP strategy ───────────────────────────────────────

    function depositToHLP(uint64 usdAmount) external onlyOperator whenNotPaused {
        require(usdAmount > 0, "Vault: zero amount");
        require(hlpDepositEnabled, "Vault: HLP deposit frozen");

        bytes memory action = encoder.encodeVaultDeposit(HyperCoreConstants.HLP_VAULT, usdAmount);
        ICoreWriter(HyperCoreConstants.CORE_WRITER).sendRawAction(action);
        emit HlpDeposited(usdAmount);
    }

    function setHlpDepositEnabled(bool enabled) external onlyOperator {
        hlpDepositEnabled = enabled;
        emit HlpDepositEnabledUpdated(enabled);
    }

    function withdrawFromHLP(uint64 usdAmount) external onlyOperator whenNotPaused {
        require(usdAmount > 0, "Vault: zero amount");

        (bool ok, bytes memory res) = HyperCoreConstants.PRECOMPILE_VAULT_EQUITY.staticcall(
            abi.encode(address(this), HyperCoreConstants.HLP_VAULT)
        );
        require(ok && res.length >= 16, "Vault: hlp equity read failed");
        (uint64 equity,) = abi.decode(res, (uint64, uint64));
        require(uint256(usdAmount) <= uint256(equity), "Vault: exceeds hlp equity");

        bytes memory action = encoder.encodeVaultWithdraw(HyperCoreConstants.HLP_VAULT, usdAmount);
        ICoreWriter(HyperCoreConstants.CORE_WRITER).sendRawAction(action);
        emit HlpWithdrawn(usdAmount);
    }

    // ─── Settlement + Yield ─────────────────────────────────

    function settle() external onlyOperator requireWired {
        IMonetrixAccountant(accountant).settleDailyPnL();
        collectYield();
    }

    function collectYield() public onlyOperator requireWired {
        int256 s = IMonetrixAccountant(accountant).surplus();
        if (s <= 0) return;
        uint256 yield = uint256(s);
        uint256 vaultBal = usdc.balanceOf(address(this));
        uint256 reserved = IRedeemEscrow(redeemEscrow).shortfall() + bridgeRetentionAmount;
        uint256 available = vaultBal > reserved ? vaultBal - reserved : 0;
        uint256 toCollect = yield < available ? yield : available;
        if (toCollect > 0) {
            usdc.safeTransfer(yieldEscrow, toCollect);
            IMonetrixAccountant(accountant).notifyRouteYield(toCollect);
            emit YieldCollected(toCollect);
        }
    }

    function distributeYield() external nonReentrant onlyOperator requireWired {
        uint256 totalYield = IYieldEscrow(yieldEscrow).balance();
        require(totalYield > 0, "Vault: no yield");

        uint256 balBefore = usdc.balanceOf(address(this));
        IYieldEscrow(yieldEscrow).pullForDistribution(totalYield);
        require(usdc.balanceOf(address(this)) >= balBefore + totalYield, "Vault: pull failed");

        uint256 userShare = (totalYield * config.userYieldBps()) / 10000;
        uint256 insuranceShare = (totalYield * config.insuranceYieldBps()) / 10000;
        uint256 foundationShare = totalYield - userShare - insuranceShare;

        usdm.mint(address(this), userShare);
        IERC20(address(usdm)).forceApprove(address(susdm), userShare);
        susdm.injectYield(userShare);

        if (insuranceShare > 0) {
            InsuranceFund _insuranceFund = InsuranceFund(config.insuranceFund());
            usdc.forceApprove(address(_insuranceFund), insuranceShare);
            _insuranceFund.deposit(insuranceShare);
        }
        if (foundationShare > 0) {
            usdc.safeTransfer(config.foundation(), foundationShare);
        }

        emit YieldDistributed(totalYield, userShare, insuranceShare, foundationShare);
    }

    // ─── Fund routing (Vault ↔ RedeemEscrow) ────────────────

    function fundRedemptions(uint256 amount) external onlyOperator requireWired {
        uint256 sf = IRedeemEscrow(redeemEscrow).shortfall();
        if (sf == 0) return;
        uint256 toFund = amount == 0 ? sf : amount;
        require(toFund <= sf, "Vault: exceeds shortfall");
        uint256 vaultBal = usdc.balanceOf(address(this));
        uint256 toTransfer = toFund < vaultBal ? toFund : vaultBal;
        require(toTransfer > 0, "Vault: nothing to fund");
        usdc.safeTransfer(redeemEscrow, toTransfer);
        emit RedemptionsFunded(toTransfer);
    }

    function reclaimFromRedeemEscrow(uint256 amount) external onlyOperator requireWired {
        require(amount > 0, "Vault: zero amount");
        IRedeemEscrow(redeemEscrow).reclaimTo(address(this), amount);
        emit RedeemEscrowReclaimed(amount);
    }

    // ═══════════════════════════════════════════════════════════
    //                  GUARDIAN OPERATIONS
    // ═══════════════════════════════════════════════════════════

    function pause() external onlyGuardian {
        _pause();
    }

    function unpause() external onlyGuardian {
        _unpause();
    }

    // ═══════════════════════════════════════════════════════════
    //                  GOVERNOR OPERATIONS
    // ═══════════════════════════════════════════════════════════

    function emergencyRawAction(bytes calldata data) external onlyGovernor {
        ICoreWriter(HyperCoreConstants.CORE_WRITER).sendRawAction(data);
        emit EmergencyActionSent(msg.sender, keccak256(data));
    }

    function emergencyBridgePrincipalFromL1(uint256 amount) external onlyGovernor {
        require(amount > 0, "Vault: zero amount");
        require(amount <= outstandingL1Principal, "Vault: exceeds L1 principal");
        outstandingL1Principal -= amount;
        _sendL1Bridge(amount);
        emit PrincipalBridgedFromL1(amount);
    }

    function setEncoder(address _encoder) external onlyGovernor {
        require(_encoder != address(0), "Vault: zero encoder");
        encoder = IActionEncoder(_encoder);
        emit EncoderUpdated(_encoder);
    }

    function setAccountant(address _accountant) external onlyGovernor {
        require(_accountant != address(0), "Vault: zero accountant");
        accountant = _accountant;
        emit AccountantUpdated(_accountant);
    }

    function setMultisigVault(address _multisig) external onlyGovernor {
        if (_multisig == address(0)) {
            require(!multisigVaultEnabled, "Vault: disable multisig first");
        }
        multisigVault = _multisig;
        emit MultisigVaultUpdated(_multisig);
    }

    function setMultisigVaultEnabled(bool _enabled) external onlyGovernor {
        if (_enabled) {
            require(multisigVault != address(0), "Vault: multisig not set");
        }
        multisigVaultEnabled = _enabled;
    }

    function setRedeemEscrow(address _escrow) external onlyGovernor {
        require(_escrow != address(0), "Vault: zero address");
        redeemEscrow = _escrow;
        emit RedeemEscrowUpdated(_escrow);
    }

    function setYieldEscrow(address _escrow) external onlyGovernor {
        require(_escrow != address(0), "Vault: zero address");
        yieldEscrow = _escrow;
        emit YieldEscrowUpdated(_escrow);
    }

    function setBridgeRetentionAmount(uint256 amount) external onlyGovernor {
        bridgeRetentionAmount = amount;
        emit BridgeRetentionAmountUpdated(amount);
    }

    // ═══════════════════════════════════════════════════════════
    //                      INTERNAL
    // ═══════════════════════════════════════════════════════════

    function _sendL1Bridge(uint256 amount) internal {
        uint64 l1Amount = uint64(amount) * uint64(HyperCoreConstants.EVM_TO_L1_PRECISION);
        bytes memory action = abi.encodePacked(
            HyperCoreConstants.ACTION_VERSION,
            HyperCoreConstants.ACTION_SEND_ASSET,
            abi.encode(
                HyperCoreConstants.USDC_SYSTEM_ADDRESS,
                address(0),
                HyperCoreConstants.SPOT_DEX,
                HyperCoreConstants.SPOT_DEX,
                uint64(HyperCoreConstants.USDC_TOKEN_INDEX),
                l1Amount
            )
        );
        ICoreWriter(HyperCoreConstants.CORE_WRITER).sendRawAction(action);
    }

    function _requireHedgePair(uint32 perpAsset, uint32 spotAsset) internal view {
        require(config.isPerpWhitelisted(perpAsset), "Vault: perp not whitelisted");
        require(config.perpToSpot(perpAsset) == spotAsset, "Vault: spot/perp mismatch");
    }

    function _requireRepairAsset(uint32 asset, bool isPerp) internal view {
        if (isPerp) {
            require(config.isPerpWhitelisted(asset), "Vault: perp not whitelisted");
        } else {
            require(config.isSpotWhitelisted(asset), "Vault: spot not whitelisted");
        }
    }

    function _removeUserRedeemId(address user, uint256 requestId) private {
        uint256[] storage ids = _userRedeemIds[user];
        uint256 len = ids.length;
        for (uint256 i = 0; i < len; i++) {
            if (ids[i] == requestId) {
                ids[i] = ids[len - 1];
                ids.pop();
                return;
            }
        }
    }

    // ═══════════════════════════════════════════════════════════
    //                       VIEW
    // ═══════════════════════════════════════════════════════════

    function netBridgeable() public view returns (uint256) {
        uint256 bal = usdc.balanceOf(address(this));
        uint256 sf = IRedeemEscrow(redeemEscrow).shortfall();
        uint256 reserved = sf + bridgeRetentionAmount;
        return bal > reserved ? bal - reserved : 0;
    }

    function redemptionShortfall() public view returns (uint256) {
        if (redeemEscrow == address(0)) return 0;
        return IRedeemEscrow(redeemEscrow).shortfall();
    }

    function availableUSDC() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function yieldShortfall() public view returns (uint256) {
        if (accountant == address(0)) return 0;
        int256 s = IMonetrixAccountant(accountant).surplus();
        if (s <= 0) return 0;
        uint256 yield = uint256(s);
        uint256 vaultBal = usdc.balanceOf(address(this));
        uint256 res = IRedeemEscrow(redeemEscrow).shortfall() + bridgeRetentionAmount;
        uint256 available = vaultBal > res ? vaultBal - res : 0;
        return yield > available ? yield - available : 0;
    }

    function maxDistributableYield() external view returns (uint256) {
        if (accountant == address(0)) return 0;
        int256 s = IMonetrixAccountant(accountant).surplus();
        return s > 0 ? uint256(s) : 0;
    }

   

    function canKeeperBridge() external view returns (bool) {
        if (redeemEscrow == address(0)) return false;
        return block.timestamp >= lastBridgeTimestamp + config.bridgeInterval()
            && netBridgeable() > 0;
    }

    function readHlpEquity() external view returns (bool success, uint64 equity, uint64 lockedUntil) {
        (bool ok, bytes memory res) = HyperCoreConstants.PRECOMPILE_VAULT_EQUITY.staticcall(
            abi.encode(address(this), HyperCoreConstants.HLP_VAULT)
        );
        if (ok && res.length >= 16) {
            (equity, lockedUntil) = abi.decode(res, (uint64, uint64));
            success = true;
        }
    }

    struct RedeemRequestDetail {
        uint256 requestId;
        uint256 usdmAmount;
        uint256 cooldownEnd;
    }

    function getUserRedeemIds(address user) external view returns (uint256[] memory) {
        return _userRedeemIds[user];
    }

    function getUserRedeemRequests(address user) external view returns (RedeemRequestDetail[] memory) {
        uint256[] memory ids = _userRedeemIds[user];
        RedeemRequestDetail[] memory details = new RedeemRequestDetail[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            RedeemRequest memory req = redeemRequests[ids[i]];
            details[i] =
                RedeemRequestDetail({requestId: ids[i], usdmAmount: req.usdmAmount, cooldownEnd: req.cooldownEnd});
        }
        return details;
    }

}

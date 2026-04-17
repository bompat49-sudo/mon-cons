// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {MonetrixGovernedUpgradeable} from "../governance/MonetrixGovernedUpgradeable.sol";

/// @title MonetrixConfig - Centralized protocol parameter registry
/// @notice Holds operational parameters: yield split ratios, deposit/TVL
///         limits, cooldowns, and the recipient addresses (insurance fund,
///         foundation) that the yield split targets.
/// @dev All parameter mutations are gated by the 24h timelock via
///      `onlyGovernor`. Upgrades are gated by the 48h timelock via the
///      inherited `_authorizeUpgrade` hook.
contract MonetrixConfig is MonetrixGovernedUpgradeable {
    uint256 public userYieldBps;
    uint256 public insuranceYieldBps;
    uint256 public minDepositAmount;
    uint256 public maxDepositAmount;
    uint256 public maxTVL;
    uint256 public autoBridgeThreshold;
    uint256 public bridgeInterval;
    address public insuranceFund;
    address public foundation;
    uint256 public redeemCooldown;
    uint256 public unstakeCooldown;

    // ─── Tradeable asset whitelist ──────────────────────────
    struct TradeableAsset {
        uint32 perpIndex;   // perp market id, also 0x807 oracle key
        uint32 spotIndex;   // spot market id, also 0x801 balance key
    }

    TradeableAsset[] public tradeableAssets;
    mapping(uint32 => uint32) public perpToSpot;
    mapping(uint32 => uint32) public spotToPerp;
    mapping(uint32 => bool) public isPerpWhitelisted;
    mapping(uint32 => bool) public isSpotWhitelisted;

    /// @notice Per-injection cap on sUSDM.injectYield. Was originally a constant (1M USDC)
    ///         in sUSDM guarding against off-chain yield input errors; now that yield is
    ///         derived on-chain from backing − supply, the cap is governor-tunable
    ///         defense-in-depth.
    /// @dev Appended at the end of the V1 storage layout so existing proxy slots are
    ///      preserved. Must be seeded by `reinitializeV2()` on upgrade of an existing
    ///      deployment (fresh deployments get it via `initialize`).
    uint256 public maxYieldPerInjection;

    event YieldBpsUpdated(uint256 userBps, uint256 insuranceBps, uint256 foundationBps);
    event DepositLimitsUpdated(uint256 minAmount, uint256 maxAmount);
    event MaxTVLUpdated(uint256 newCap);
    event AutoBridgeUpdated(uint256 threshold, uint256 interval);
    event CooldownsUpdated(uint256 redeemCooldown, uint256 unstakeCooldown);
    event AddressUpdated(string name, address addr);
    event TradeableAssetsUpdated(uint256 count);
    event MaxYieldPerInjectionUpdated(uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _insuranceFund, address _foundation, address _acl) external initializer {
        require(_insuranceFund != address(0), "Config: zero insuranceFund");
        require(_foundation != address(0), "Config: zero foundation");
        __Governed_init(_acl);
        insuranceFund = _insuranceFund;
        foundation = _foundation;
        userYieldBps = 7000;
        insuranceYieldBps = 1000;
        minDepositAmount = 100e6;
        maxDepositAmount = 1_000_000e6;
        maxTVL = 10_000_000e6;
        bridgeInterval = 6 hours;
        redeemCooldown = 3 days;
        unstakeCooldown = 7 days;
        maxYieldPerInjection = 1_000_000e6;
    }

    /// @notice One-time seeder for `maxYieldPerInjection` when upgrading an existing
    ///         Config proxy from V1 (no such field) to V2. Fresh deployments use
    ///         `initialize` and never call this.
    /// @dev Uses `reinitializer(2)` so it can only run once per proxy. Value is
    ///      governor-tunable afterwards via `setMaxYieldPerInjection`.
    function reinitializeV2() external reinitializer(2) onlyGovernor {
        maxYieldPerInjection = 1_000_000e6;
        emit MaxYieldPerInjectionUpdated(1_000_000e6);
    }

    /// @notice Foundation share = 10000 - userYieldBps - insuranceYieldBps.
    function foundationYieldBps() external view returns (uint256) {
        return 10000 - userYieldBps - insuranceYieldBps;
    }

    function setYieldBps(uint256 _userBps, uint256 _insuranceBps) external onlyGovernor {
        require(_userBps + _insuranceBps <= 10000, "Config: bps exceed 10000");
        userYieldBps = _userBps;
        insuranceYieldBps = _insuranceBps;
        emit YieldBpsUpdated(_userBps, _insuranceBps, 10000 - _userBps - _insuranceBps);
    }

    function setDepositLimits(uint256 _min, uint256 _max) external onlyGovernor {
        require(_min > 0, "Config: zero min");
        require(_min < _max, "Config: min >= max");
        minDepositAmount = _min;
        maxDepositAmount = _max;
        emit DepositLimitsUpdated(_min, _max);
    }

    function setMaxTVL(uint256 _maxTVL) external onlyGovernor {
        maxTVL = _maxTVL;
        emit MaxTVLUpdated(_maxTVL);
    }

    function setAutoBridge(uint256 _threshold, uint256 _interval) external onlyGovernor {
        require(_threshold > 0 && _interval > 0, "Config: zero value");
        autoBridgeThreshold = _threshold;
        bridgeInterval = _interval;
        emit AutoBridgeUpdated(_threshold, _interval);
    }

    function setCooldowns(uint256 _redeemCooldown, uint256 _unstakeCooldown) external onlyGovernor {
        require(_redeemCooldown >= 1 minutes, "Config: redeem cooldown too short");
        require(_unstakeCooldown >= 1 minutes, "Config: unstake cooldown too short");
        require(_redeemCooldown <= 30 days, "Config: redeem cooldown too long");
        require(_unstakeCooldown <= 30 days, "Config: unstake cooldown too long");
        redeemCooldown = _redeemCooldown;
        unstakeCooldown = _unstakeCooldown;
        emit CooldownsUpdated(_redeemCooldown, _unstakeCooldown);
    }

    function setInsuranceFund(address _addr) external onlyGovernor {
        require(_addr != address(0), "Config: zero address");
        insuranceFund = _addr;
        emit AddressUpdated("insuranceFund", _addr);
    }

    function setFoundation(address _addr) external onlyGovernor {
        require(_addr != address(0), "Config: zero address");
        foundation = _addr;
        emit AddressUpdated("foundation", _addr);
    }

    function setMaxYieldPerInjection(uint256 _amount) external onlyGovernor {
        require(_amount > 0, "Config: zero max");
        maxYieldPerInjection = _amount;
        emit MaxYieldPerInjectionUpdated(_amount);
    }

    // ─── Tradeable asset whitelist management ──────────────

    function addTradeableAsset(TradeableAsset calldata asset) external onlyGovernor {
        _addAsset(asset);
        emit TradeableAssetsUpdated(tradeableAssets.length);
    }

    function addTradeableAssets(TradeableAsset[] calldata assets) external onlyGovernor {
        for (uint256 i = 0; i < assets.length; i++) {
            _addAsset(assets[i]);
        }
        emit TradeableAssetsUpdated(tradeableAssets.length);
    }

    function _addAsset(TradeableAsset calldata asset) internal {
        require(!isPerpWhitelisted[asset.perpIndex], "Config: perp already listed");
        require(!isSpotWhitelisted[asset.spotIndex], "Config: spot already listed");
        tradeableAssets.push(asset);
        perpToSpot[asset.perpIndex] = asset.spotIndex;
        spotToPerp[asset.spotIndex] = asset.perpIndex;
        isPerpWhitelisted[asset.perpIndex] = true;
        isSpotWhitelisted[asset.spotIndex] = true;
    }

    function removeTradeableAsset(uint32 perpIndex) external onlyGovernor {
        require(isPerpWhitelisted[perpIndex], "Config: perp not listed");
        uint32 spotIdx = perpToSpot[perpIndex];

        // Swap-and-pop from the array
        uint256 len = tradeableAssets.length;
        for (uint256 i = 0; i < len; i++) {
            if (tradeableAssets[i].perpIndex == perpIndex) {
                tradeableAssets[i] = tradeableAssets[len - 1];
                tradeableAssets.pop();
                break;
            }
        }

        delete perpToSpot[perpIndex];
        delete spotToPerp[spotIdx];
        delete isPerpWhitelisted[perpIndex];
        delete isSpotWhitelisted[spotIdx];
        emit TradeableAssetsUpdated(tradeableAssets.length);
    }

    function tradeableAssetsLength() external view returns (uint256) {
        return tradeableAssets.length;
    }

    /// @dev Reduced from 50 to 49 when `maxYieldPerInjection` was appended in V2.
    uint256[49] private __gap;
}

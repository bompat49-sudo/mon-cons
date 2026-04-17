// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../tokens/USDM.sol";
import "../interfaces/HyperCoreConstants.sol";
import "../interfaces/IMonetrixAccountant.sol";
import {MonetrixGovernedUpgradeable} from "../governance/MonetrixGovernedUpgradeable.sol";

/// @notice Minimal reader interfaces to avoid circular imports.
interface IMonetrixVaultReader {
    function multisigVault() external view returns (address);
}

interface IMonetrixConfigReader {
    function tradeableAssets(uint256 index) external view returns (uint32 perpIndex, uint32 spotIndex);
    function tradeableAssetsLength() external view returns (uint256);
}

/// @title MonetrixAccountant - Peg guardian & yield gate for Monetrix V1
/// @notice Peg defense and yield accounting only. Holds no tokens and no
/// operational counters — those live on Vault and RedeemEscrow respectively.
/// @dev `settleDailyPnL` is `onlyOperator` (bot hot wallet).
///      Config and debt corrections are `onlyGovernor` (24h timelock).
contract MonetrixAccountant is IMonetrixAccountant, MonetrixGovernedUpgradeable {
    address public vault;
    IERC20 public usdc;
    USDM public usdm;
    address public config;

    int256 public lastSurplusSnapshot;
    uint256 public lastSettlementTime;
    uint256 public minSettlementInterval;

    address public redeemEscrow;

    // ─── Events ──────────────────────────────────────────────

    event Settled(uint256 indexed day, int256 dailyPnL, int256 currentSurplus);
    event RouteYieldNotified(uint256 amount, int256 newSnapshot);
    event MinSettlementIntervalUpdated(uint256 interval);
    event ConfigUpdated(address config);
    event SnapshotInitialized(int256 surplusBaseline, uint256 timestamp);
    event RedeemEscrowUpdated(address redeemEscrow);

    uint256[50] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _vault, address _usdc, address _usdm, address _acl) external initializer {
        require(_vault != address(0), "Accountant: zero vault");
        require(_usdc != address(0), "Accountant: zero usdc");
        require(_usdm != address(0), "Accountant: zero usdm");

        __Governed_init(_acl);

        vault = _vault;
        usdc = IERC20(_usdc);
        usdm = USDM(_usdm);
        minSettlementInterval = 20 hours;
    }


    // ─── View: backing + surplus ─────────────────────────────

    /// @notice Signed real backing. Use this internally so a negative perp
    /// accountValue (e.g. liquidated) correctly shows up as reduced backing.
    /// @dev Fully mark-to-market: HLP equity is counted at its current value for
    function totalBackingSigned() public view returns (int256 total) {
        // EVM USDC — Vault + RedeemEscrow (not YieldEscrow: undistributed yield is not backing)
        total = int256(usdc.balanceOf(vault));
        if (redeemEscrow != address(0)) {
            total += int256(usdc.balanceOf(redeemEscrow));
        }

        // L1 state — read from vault + multisigVault (if configured on Vault)
        total += _readL1Backing(vault);
        address _multisigVault = IMonetrixVaultReader(vault).multisigVault();
        if (_multisigVault != address(0)) {
            total += _readL1Backing(_multisigVault);
        }
    }

    /// @dev Sum perp + spot USDC + spot hedge tokens + supplied (PM) + HLP for a single L1 account.
    function _readL1Backing(address account) internal view returns (int256 total) {
        total = _readPerpAccountValueSigned(account);

        // L1 spot USDC (idle cash not yet deployed to perp/hedge)
        total += int256(_readSpotUsdcBalance(account));

        // PM supplied USDC (cross-collateral, invisible to 0x801)
        total += int256(_readSuppliedUsdc(account));

        if (config != address(0)) {
            IMonetrixConfigReader cfg = IMonetrixConfigReader(config);
            uint256 len = cfg.tradeableAssetsLength();
            for (uint256 i = 0; i < len; i++) {
                (uint32 perpIndex, uint32 spotIndex) = cfg.tradeableAssets(i);
                total += int256(_readSpotAssetUsdc(spotIndex, perpIndex, account));
                // PM supplied hedge tokens
                total += int256(_readSuppliedAssetUsdc(uint64(spotIndex), perpIndex, account));
            }
        }

        // HLP equity counted at full mark value (no principal cap).
        // multisigVault-held HLP is recognized on the same basis as Vault-held HLP.
        total += int256(_readHlpEquity(account));
    }

    /// @notice Unsigned view, clamped at 0. Internal math must use `totalBackingSigned()`.
    function totalBacking() public view returns (uint256) {
        int256 signed = totalBackingSigned();
        return signed > 0 ? uint256(signed) : 0;
    }

    function surplus() public view returns (int256) {
        return totalBackingSigned() - int256(usdm.totalSupply());
    }

    // ─── Daily settlement ────────────────────────────────────

    /// @notice Keeper-triggered daily PnL recording. Pure audit trail —
    /// surplus itself is the real-time source of truth for distributable profit.
    function settleDailyPnL() external onlyVaultCaller returns (int256 currentSurplus) {
        require(lastSettlementTime > 0, "Accountant: not initialized");
        require(
            block.timestamp >= lastSettlementTime + minSettlementInterval, "Accountant: settlement too early"
        );

        currentSurplus = surplus();
        int256 dailyPnL = currentSurplus - lastSurplusSnapshot;

        lastSurplusSnapshot = currentSurplus;
        lastSettlementTime = block.timestamp;

        emit Settled(_currentDay(), dailyPnL, currentSurplus);
    }

    // ─── Snapshot adjustment ────────────────────────────────

    /// @notice Called by the vault when yield USDC is routed from Vault to YieldEscrow.
    /// YieldEscrow is excluded from totalBacking, so routing drops backing/surplus.
    /// Adjust snapshot to prevent the next settleDailyPnL from booking it as a loss.
    function notifyRouteYield(uint256 amount) external onlyVaultCaller {
        lastSurplusSnapshot -= int256(amount);
        emit RouteYieldNotified(amount, lastSurplusSnapshot);
    }

    // ─── Admin: config ───────────────────────────────────────

    function setConfig(address _config) external onlyGovernor {
        config = _config;
        emit ConfigUpdated(_config);
    }

    function setMinSettlementInterval(uint256 interval) external onlyGovernor {
        require(interval >= 1 hours, "Accountant: interval too short");
        require(interval <= 2 days, "Accountant: interval too long");
        minSettlementInterval = interval;
        emit MinSettlementIntervalUpdated(interval);
    }

    function setRedeemEscrow(address _redeemEscrow) external onlyGovernor {
        redeemEscrow = _redeemEscrow;
        emit RedeemEscrowUpdated(_redeemEscrow);
    }

    // ─── Admin: lifecycle ────────────────────────────────────

    /// @notice Seed the initial surplus baseline. Must run once before settleDailyPnL.
    function initializeSnapshot() external onlyGovernor {
        require(lastSettlementTime == 0, "Accountant: already initialized");
        int256 baseline = surplus();
        lastSurplusSnapshot = baseline;
        lastSettlementTime = block.timestamp;
        emit SnapshotInitialized(baseline, block.timestamp);
    }

    // ─── Internal precompile readers ─────────────────────────
    // Fail-closed: any staticcall failure / short response reverts, so a
    // transient HyperCore glitch cannot be silently booked as a loss.

    function _readPerpAccountValueSigned(address user) internal view returns (int256) {
        (bool ok, bytes memory res) = HyperCoreConstants.PRECOMPILE_ACCOUNT_MARGIN_SUMMARY.staticcall(
            abi.encode(uint32(0), user)
        );
        require(ok && res.length >= 128, "Accountant: perp read failed");
        (int64 accountValue,,,) = abi.decode(res, (int64, uint64, uint64, int64));
        return int256(accountValue);
    }

    function _readSpotAssetUsdc(uint32 spotTokenIndex, uint32 perpIndex, address account) internal view returns (uint256) {
        (bool okBalance, bytes memory balanceRes) = HyperCoreConstants.PRECOMPILE_SPOT_BALANCE.staticcall(
            abi.encode(account, spotTokenIndex)
        );
        require(okBalance && balanceRes.length >= 96, "Accountant: spot balance read failed");
        (uint64 spotTotal,,) = abi.decode(balanceRes, (uint64, uint64, uint64));
        if (spotTotal == 0) return 0;

        (bool okPx, bytes memory pxRes) = HyperCoreConstants.PRECOMPILE_ORACLE_PX.staticcall(
            abi.encode(perpIndex)
        );
        require(okPx && pxRes.length >= 32, "Accountant: oracle px read failed");
        uint64 price = abi.decode(pxRes, (uint64));
        require(price > 0, "Accountant: oracle px zero");

        return (uint256(spotTotal) * uint256(price)) / 1e10;
    }

    /// @dev Read L1 spot USDC balance (token index 0). Returns 6-decimal USDC.
    function _readSpotUsdcBalance(address account) internal view returns (uint256) {
        (bool ok, bytes memory res) = HyperCoreConstants.PRECOMPILE_SPOT_BALANCE.staticcall(
            abi.encode(account, uint64(HyperCoreConstants.USDC_TOKEN_INDEX))
        );
        require(ok && res.length >= 96, "Accountant: spot USDC read failed");
        (uint64 spotTotal,,) = abi.decode(res, (uint64, uint64, uint64));
        return uint256(spotTotal) / 100; // 8-decimal → 6-decimal
    }

    /// @dev Read PM supplied USDC (0x811). Returns 6-decimal USDC.
    /// Fail-closed: reverts on precompile failure to prevent silent under-reporting of backing.
    function _readSuppliedUsdc(address account) internal view returns (uint256) {
        (bool ok, bytes memory res) = HyperCoreConstants.PRECOMPILE_SUPPLIED_BALANCE.staticcall(
            abi.encode(account, uint64(HyperCoreConstants.USDC_TOKEN_INDEX))
        );
        require(ok && res.length >= 128, "Accountant: supplied USDC read failed");
        (,,, uint64 supplied) = abi.decode(res, (uint64, uint64, uint64, uint64));
        return uint256(supplied) / 100; // 8-decimal → 6-decimal
    }

    /// @dev Read PM supplied balance for a hedge token, converted to USDC via oracle.
    /// Fail-closed: reverts on precompile failure to prevent silent under-reporting of backing.
    function _readSuppliedAssetUsdc(uint64 spotTokenIndex, uint32 perpIndex, address account) internal view returns (uint256) {
        (bool ok, bytes memory res) = HyperCoreConstants.PRECOMPILE_SUPPLIED_BALANCE.staticcall(
            abi.encode(account, spotTokenIndex)
        );
        require(ok && res.length >= 128, "Accountant: supplied balance read failed");
        (,,, uint64 supplied) = abi.decode(res, (uint64, uint64, uint64, uint64));
        if (supplied == 0) return 0;

        (bool okPx, bytes memory pxRes) = HyperCoreConstants.PRECOMPILE_ORACLE_PX.staticcall(
            abi.encode(perpIndex)
        );
        require(okPx && pxRes.length >= 32, "Accountant: oracle px read failed");
        uint64 price = abi.decode(pxRes, (uint64));
        require(price > 0, "Accountant: oracle px zero");

        return (uint256(supplied) * uint256(price)) / 1e10;
    }

    function _readHlpEquity(address account) internal view returns (uint256) {
        (bool ok, bytes memory res) = HyperCoreConstants.PRECOMPILE_VAULT_EQUITY.staticcall(
            abi.encode(account, HyperCoreConstants.HLP_VAULT)
        );
        require(ok && res.length >= 64, "Accountant: hlp equity read failed");
        (uint64 equity,) = abi.decode(res, (uint64, uint64));
        return uint256(equity);
    }

    function _currentDay() internal view returns (uint256) {
        return block.timestamp / 1 days;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/core/MonetrixAccountant.sol";
import "../src/core/MonetrixConfig.sol";
import "../src/tokens/USDM.sol";
import "./mocks/MockUSDC.sol";
import "../src/interfaces/HyperCoreConstants.sol";
import "../src/governance/MonetrixAccessController.sol";

/// @notice Controllable mock precompile for testing. Its `staticcall` fallback
/// decodes a selector from the incoming calldata to match the layout the
/// precompile expects, then returns pre-programmed state.
/// @dev Default response is 32 bytes of zeros. This size satisfies the
/// minimum length check in every Accountant reader (perp=32, spot=24, hlp=16,
/// oracle=8), and decodes to "zero balance / zero account value" which the
/// readers interpret as "no position" (short-circuit without error). Tests
/// that want specific non-zero values still call setResponse explicitly.
/// A test that wants to simulate a precompile outage can install a
/// FailingPrecompile via vm.etch on the target address.
contract MockPrecompile {
    mapping(bytes32 => bytes) public responses;

    function setResponse(bytes calldata callData, bytes calldata response) external {
        responses[keccak256(callData)] = response;
    }

    fallback(bytes calldata data) external payable returns (bytes memory) {
        bytes memory r = responses[keccak256(data)];
        if (r.length == 0) {
            // 128 zero bytes — satisfies every reader's min length check
            // (perp=128, spot=96, hlp=64, oracle=32) and decodes to
            // "no position / zero balance" semantics. Tests that want
            // specific non-zero values still call setResponse explicitly.
            return new bytes(128);
        }
        return r;
    }
}

/// @notice Test helper that always reverts. Used with vm.etch to simulate
/// a HyperCore precompile outage and verify fail-closed behavior.
contract FailingPrecompile {
    fallback(bytes calldata) external payable returns (bytes memory) {
        revert("precompile down");
    }
}

/// @notice Test helper that always returns empty bytes. Simulates a malformed
/// precompile response (shorter than the decode length).
contract EmptyPrecompile {
    fallback(bytes calldata) external payable returns (bytes memory) {
        return new bytes(0);
    }
}

/// @notice Minimal stand-in for MonetrixVault exposing just the fields the
/// Accountant reads via IMonetrixVaultReader.
contract MockVault {
    address public multisigVault;

    function setMultisigVault(address _multisig) external {
        multisigVault = _multisig;
    }
}

contract MonetrixAccountantTest is Test {
    MonetrixAccountant accountant;
    MonetrixConfig config;
    USDM usdm;
    MockUSDC usdc;
    MockVault mockVault;
    MonetrixAccessController acl;
    address vault; // points at mockVault for convenience

    address admin = address(0xAD);
    address keeper = address(0xB01);

    MockPrecompile mockAccountMargin;
    MockPrecompile mockSpotBalance;
    MockPrecompile mockOraclePx;
    MockPrecompile mockVaultEquity;
    MockPrecompile mockSuppliedBalance;

    function setUp() public {
        vm.startPrank(admin);

        usdc = new MockUSDC();
        mockVault = new MockVault();
        vault = address(mockVault);

        // Deploy ACL
        MonetrixAccessController aclImpl = new MonetrixAccessController();
        ERC1967Proxy aclProxy =
            new ERC1967Proxy(address(aclImpl), abi.encodeCall(MonetrixAccessController.initialize, (admin)));
        acl = MonetrixAccessController(address(aclProxy));

        // Deploy USDM proxy
        USDM usdmImpl = new USDM();
        ERC1967Proxy usdmProxy = new ERC1967Proxy(address(usdmImpl), abi.encodeCall(USDM.initialize, (address(acl))));
        usdm = USDM(address(usdmProxy));

        // Deploy MonetrixAccountant proxy
        MonetrixAccountant acctImpl = new MonetrixAccountant();
        ERC1967Proxy acctProxy = new ERC1967Proxy(
            address(acctImpl),
            abi.encodeCall(MonetrixAccountant.initialize, (vault, address(usdc), address(usdm), address(acl)))
        );
        accountant = MonetrixAccountant(address(acctProxy));

        // Deploy Config proxy (needed for tradeableAssets in totalBacking)
        MonetrixConfig configImpl = new MonetrixConfig();
        ERC1967Proxy configProxy = new ERC1967Proxy(
            address(configImpl),
            abi.encodeCall(MonetrixConfig.initialize, (address(0x1), address(0x2), address(acl)))
        );
        config = MonetrixConfig(address(configProxy));

        // Grant roles: keeper plays OPERATOR (merged from old KEEPER), mockVault
        // gets VAULT_CALLER (unifies old VAULT_ROLE + MINTER + YIELD_MANAGER),
        // admin gets GOVERNOR + VAULT_CALLER to retain the pre-existing test
        // privilege of minting USDM directly.
        acl.grantRole(acl.OPERATOR(), keeper);
        acl.grantRole(acl.VAULT_CALLER(), vault);
        acl.grantRole(acl.VAULT_CALLER(), admin);
        acl.grantRole(acl.GOVERNOR(), admin);

        // Wire config to accountant (after governor role granted)
        accountant.setConfig(address(config));

        // Install mock precompiles via vm.etch
        MockPrecompile mockAmImpl = new MockPrecompile();
        MockPrecompile mockSbImpl = new MockPrecompile();
        MockPrecompile mockOpImpl = new MockPrecompile();
        MockPrecompile mockVeImpl = new MockPrecompile();
        MockPrecompile mockSuImpl = new MockPrecompile();

        vm.etch(HyperCoreConstants.PRECOMPILE_ACCOUNT_MARGIN_SUMMARY, address(mockAmImpl).code);
        vm.etch(HyperCoreConstants.PRECOMPILE_SPOT_BALANCE, address(mockSbImpl).code);
        vm.etch(HyperCoreConstants.PRECOMPILE_ORACLE_PX, address(mockOpImpl).code);
        vm.etch(HyperCoreConstants.PRECOMPILE_VAULT_EQUITY, address(mockVeImpl).code);
        vm.etch(HyperCoreConstants.PRECOMPILE_SUPPLIED_BALANCE, address(mockSuImpl).code);

        mockAccountMargin = MockPrecompile(payable(HyperCoreConstants.PRECOMPILE_ACCOUNT_MARGIN_SUMMARY));
        mockSpotBalance = MockPrecompile(payable(HyperCoreConstants.PRECOMPILE_SPOT_BALANCE));
        mockOraclePx = MockPrecompile(payable(HyperCoreConstants.PRECOMPILE_ORACLE_PX));
        mockVaultEquity = MockPrecompile(payable(HyperCoreConstants.PRECOMPILE_VAULT_EQUITY));
        mockSuppliedBalance = MockPrecompile(payable(HyperCoreConstants.PRECOMPILE_SUPPLIED_BALANCE));

        vm.stopPrank();
    }

    // ─── Helpers: program mock precompile responses ──────────

    function _setAccountValue(int64 accountValue) internal {
        bytes memory key = abi.encode(uint32(0), vault);
        bytes memory response = abi.encode(accountValue, uint64(0), uint64(0), int64(0));
        mockAccountMargin.setResponse(key, response);
    }

    function _setSpotBalance(uint64 tokenIndex, uint64 total) internal {
        bytes memory key = abi.encode(vault, tokenIndex);
        bytes memory response = abi.encode(total, uint64(0), uint64(0));
        mockSpotBalance.setResponse(key, response);
    }

    function _setOraclePrice(uint16 perpIndex, uint64 price) internal {
        bytes memory key = abi.encode(perpIndex);
        bytes memory response = abi.encode(price);
        mockOraclePx.setResponse(key, response);
    }

    function _setHlpEquity(uint64 equity) internal {
        bytes memory key = abi.encode(vault, HyperCoreConstants.HLP_VAULT);
        bytes memory response = abi.encode(equity, uint64(0));
        mockVaultEquity.setResponse(key, response);
    }

    function _setEvmUsdc(uint256 amount) internal {
        usdc.mint(vault, amount);
    }

    function _mintUsdm(uint256 amount) internal {
        vm.prank(admin);
        usdm.mint(address(this), amount);
    }

    function _setHedgeAsset(uint32 spotToken, uint32 perpIndex) internal {
        vm.prank(admin);
        config.addTradeableAsset(MonetrixConfig.TradeableAsset({perpIndex: perpIndex, spotIndex: spotToken}));
    }

    // ─── Tests: totalBacking ─────────────────────────────────

    function test_totalBacking_sumsAllSources() public {
        _setEvmUsdc(100e6); // 100 USDC in EVM
        _setAccountValue(200e6); // 200 USDC in perp
        _setHlpEquity(50e6); // 50 USDC in HLP
        _setHedgeAsset(197, 0);
        _setSpotBalance(197, 1e7); // 0.1 BTC (8-decimal → 1e7 = 0.1)
        _setOraclePrice(0, 6_000e8); // $6,000 per BTC (test value)

        // spot NAV = (1e7 × 6000e8) / 1e10 = 6e18/1e10 = 6e8 = 600 USDC
        // Total = 100 + 200 + 50 (HLP at mark) + 600 = 950e6
        assertEq(accountant.totalBacking(), 950e6);
    }

    /// @notice HLP MTM gains are recognized at full mark value (mark-to-market).
    /// Protocol design doc: HLP is the fallback strategy; the InsuranceFund buffers
    /// drawdowns, and unrealized gains flow into surplus / distributable yield.
    function test_totalBacking_hlpMarkToMarketGain() public {
        _setEvmUsdc(0);
        _setAccountValue(0);
        _setHlpEquity(120e6); // HLP mark value 120

        // HLP contribution = 120 (full mark, no cap)
        assertEq(accountant.totalBacking(), 120e6);
    }

    /// @notice HLP losses are recognized immediately at mark value (symmetric
    /// with gains — this drives debt recognition so surplus drops and blocks
    /// distributions until recovered).
    function test_totalBacking_hlpLossReducesBacking() public {
        _setEvmUsdc(0);
        _setAccountValue(0);
        _setHlpEquity(80e6); // HLP dropped to 80

        // HLP contribution = 80 (mark value)
        assertEq(accountant.totalBacking(), 80e6);
    }

    /// @notice Negative perp accountValue (e.g. liquidated position) must
    /// subtract from backing, not be clamped to zero.
    function test_totalBacking_negativeAccountValueReducesBacking() public {
        _setEvmUsdc(100e6);
        _setAccountValue(-30e6); // perp underwater by 30
        _setHlpEquity(50e6);

        // signed total = 100 + (-30) + 50 = 120
        // totalBacking clamps the signed view at 0 but the underlying value is positive
        assertEq(accountant.totalBacking(), 120e6);
    }

    /// @notice When perp liability exceeds all other assets, totalBackingSigned
    /// reports the true negative position. totalBacking() clamps to 0 (view safety).
    function test_totalBackingSigned_deeplyUnderwater() public {
        _setEvmUsdc(10e6);
        _setAccountValue(-50e6); // big liability
        _setHlpEquity(0);

        // signed = 10 + (-50) + 0 = -40
        assertEq(accountant.totalBackingSigned(), -40e6);
        // clamped view returns 0
        assertEq(accountant.totalBacking(), 0);
    }

    function test_totalBacking_noPrecompiles_returnsEvmOnly() public {
        _setEvmUsdc(500e6);
        // No precompile state set → all return 0
        assertEq(accountant.totalBacking(), 500e6);
    }

    // ─── Tests: surplus ──────────────────────────────────────

    function test_surplus_positive() public {
        _setEvmUsdc(1_000e6);
        _mintUsdm(900e6);
        assertEq(accountant.surplus(), int256(100e6));
    }

    function test_surplus_negative() public {
        _setEvmUsdc(800e6);
        _mintUsdm(1_000e6);
        assertEq(accountant.surplus(), -int256(200e6));
    }

    // ─── Tests: settleDailyPnL ───────────────────────────────

    function test_settleDailyPnL_requiresInitialized() public {
        // Have not called initializeSnapshot yet
        vm.warp(block.timestamp + 21 hours);
        vm.prank(vault);
        vm.expectRevert("Accountant: not initialized");
        accountant.settleDailyPnL();
    }

    function test_settleDailyPnL_respectsMinInterval() public {
        _initializeBaseline(1_000e6, 1_000e6);

        vm.prank(vault);
        vm.expectRevert("Accountant: settlement too early");
        accountant.settleDailyPnL();
    }

    function test_settleDailyPnL_profit_increasesSurplus() public {
        _initializeBaseline(1_000e6, 1_000e6);

        // Simulate profit: backing +50, supply unchanged
        // _initializeBaseline minted 1000 EVM + 1000 USDM. Now add 50 more EVM (profit).
        _setEvmUsdc(50e6);
        vm.warp(block.timestamp + 21 hours);

        vm.prank(vault);
        accountant.settleDailyPnL();

        // surplus = totalBacking - totalSupply = (1000 + 50) - 1000 = 50
        assertEq(accountant.surplus(), int256(50e6));
    }

    function test_settleDailyPnL_loss_reducesSurplus() public {
        _initializeBaseline(1_000e6, 1_000e6);

        // Simulate loss: backing drops by 30
        vm.prank(vault);
        usdc.transfer(address(0xdead), 30e6);
        vm.warp(block.timestamp + 21 hours);

        vm.prank(vault);
        accountant.settleDailyPnL();

        // surplus = (1000 - 30) - 1000 = -30
        assertEq(accountant.surplus(), -int256(30e6));
    }

    function test_settleDailyPnL_netLoss_surplusNegative() public {
        _initializeBaseline(1_000e6, 1_000e6);
        uint256 t0 = block.timestamp;

        // Day 1: lose 100
        vm.prank(vault);
        usdc.transfer(address(0xdead), 100e6);
        vm.warp(t0 + 21 hours);
        vm.prank(vault);
        accountant.settleDailyPnL();
        assertEq(accountant.surplus(), -int256(100e6));

        // Day 2: profit 40 (less than prior loss → still net negative)
        _setEvmUsdc(40e6);
        vm.warp(t0 + 42 hours);
        vm.prank(vault);
        accountant.settleDailyPnL();

        // surplus = (1000 - 100 + 40) - 1000 = -60
        assertEq(accountant.surplus(), -int256(60e6));
    }

    function test_settleDailyPnL_profitExceedsLoss_surplusPositive() public {
        _initializeBaseline(1_000e6, 1_000e6);
        uint256 t0 = block.timestamp;

        // Day 1: lose 50
        vm.prank(vault);
        usdc.transfer(address(0xdead), 50e6);
        vm.warp(t0 + 21 hours);
        vm.prank(vault);
        accountant.settleDailyPnL();
        assertEq(accountant.surplus(), -int256(50e6));

        // Day 2: profit 80 (exceeds prior loss → net surplus positive)
        _setEvmUsdc(80e6);
        vm.warp(t0 + 42 hours);
        vm.prank(vault);
        accountant.settleDailyPnL();

        // surplus = (1000 - 50 + 80) - 1000 = 30
        assertEq(accountant.surplus(), int256(30e6));
    }

    function test_settleDailyPnL_neutralizesUserDeposits() public {
        _initializeBaseline(1_000e6, 1_000e6);

        // Simulate user deposit: backing and supply both rise by 500 (no real PnL)
        _setEvmUsdc(500e6);
        _mintUsdm(500e6);
        vm.warp(block.timestamp + 21 hours);

        vm.prank(vault);
        accountant.settleDailyPnL();

        // No profit/loss — surplus should remain 0
        assertEq(accountant.surplus(), int256(0));
    }

    function test_settleDailyPnL_deposit_then_profit() public {
        _initializeBaseline(1_000e6, 1_000e6);

        // User deposits 500 + real profit of 20 happens in same window
        _setEvmUsdc(520e6);
        _mintUsdm(500e6);
        vm.warp(block.timestamp + 21 hours);

        vm.prank(vault);
        accountant.settleDailyPnL();

        // The 500 deposit neutralizes; only 20 net profit → surplus = 20
        assertEq(accountant.surplus(), int256(20e6));
    }

    // ─── Tests: init ────────────────────────────────────────

    function test_initializeSnapshot_cannotReinitialize() public {
        _initializeBaseline(1_000e6, 1_000e6);
        vm.prank(admin);
        vm.expectRevert("Accountant: already initialized");
        accountant.initializeSnapshot();
    }

    // ─── Tests: precompile fail-closed ───────────────────────
    //
    // These tests prove that a transient HyperCore RPC glitch cannot be
    // silently written into the ledger as a loss. Any critical read failure
    // must bubble up as a revert so the keeper simply retries in the next
    // settlement window.

    /// @notice Perp precompile outage → settlement must revert, not book a
    /// fake loss by treating the missing backing as zero.
    function test_perpReadFailure_settlementReverts() public {
        _setEvmUsdc(1_000e6);
        _setAccountValue(500e6);
        _mintUsdm(1_400e6);

        vm.prank(admin);
        accountant.initializeSnapshot();

        // Simulate precompile outage
        vm.etch(HyperCoreConstants.PRECOMPILE_ACCOUNT_MARGIN_SUMMARY, address(new FailingPrecompile()).code);

        vm.warp(block.timestamp + 21 hours);
        vm.prank(vault);
        vm.expectRevert("Accountant: perp read failed");
        accountant.settleDailyPnL();
    }

    /// @notice Perp precompile returning malformed short data → revert.
    function test_perpReadMalformed_settlementReverts() public {
        _setEvmUsdc(1_000e6);
        _setAccountValue(500e6);
        _mintUsdm(1_400e6);

        vm.prank(admin);
        accountant.initializeSnapshot();

        // Install a stub that returns empty bytes
        vm.etch(HyperCoreConstants.PRECOMPILE_ACCOUNT_MARGIN_SUMMARY, address(new EmptyPrecompile()).code);

        vm.warp(block.timestamp + 21 hours);
        vm.prank(vault);
        vm.expectRevert("Accountant: perp read failed");
        accountant.settleDailyPnL();
    }

    /// @notice HLP equity precompile outage → totalBacking revert. Under mark-to-market
    /// there is no short-circuit: the HLP precompile is read unconditionally and any
    /// staticcall failure is propagated (fail-closed).
    function test_hlpReadFailure_reverts() public {
        _setEvmUsdc(500e6);
        _setAccountValue(500e6);
        _setHlpEquity(200e6);

        // Baseline works
        assertEq(accountant.totalBacking(), 1_200e6);

        // Now knock out the HLP precompile
        vm.etch(HyperCoreConstants.PRECOMPILE_VAULT_EQUITY, address(new FailingPrecompile()).code);

        vm.expectRevert("Accountant: hlp equity read failed");
        accountant.totalBacking();
    }

    /// @notice Spot precompile outage → revert when tradeableAssets configured.
    function test_spotReadFailure_revertsWhenHedgeConfigured() public {
        _setEvmUsdc(500e6);
        _setAccountValue(500e6);
        _setHedgeAsset(197, 0);
        _setSpotBalance(197, 1e7);
        _setOraclePrice(0, 6_000e8);

        // Baseline works
        assertGt(accountant.totalBacking(), 1_000e6);

        vm.etch(HyperCoreConstants.PRECOMPILE_SPOT_BALANCE, address(new FailingPrecompile()).code);
        vm.expectRevert("Accountant: spot USDC read failed");
        accountant.totalBacking();
    }

    /// @notice Empty tradeableAssets → broken spot precompile is irrelevant.
    /// @notice No tradeable assets → oracle precompile not read, but spot USDC
    /// balance IS still read (L1 idle cash is always part of backing).
    function test_spotHedgeSkipped_whenNoTradeableAssets() public {
        _setEvmUsdc(1_000e6);
        _setAccountValue(500e6);
        // Do not set hedgeAssets — oracle can be broken, spot USDC still reads
        vm.etch(HyperCoreConstants.PRECOMPILE_ORACLE_PX, address(new FailingPrecompile()).code);

        assertEq(accountant.totalBacking(), 1_500e6);
    }

    /// @notice Oracle precompile outage → revert during totalBacking, even
    /// though the spot balance read succeeded.
    function test_oracleReadFailure_reverts() public {
        _setEvmUsdc(500e6);
        _setAccountValue(500e6);
        _setHedgeAsset(197, 0);
        _setSpotBalance(197, 1e7);
        _setOraclePrice(0, 6_000e8);

        // Baseline works
        assertGt(accountant.totalBacking(), 1_000e6);

        vm.etch(HyperCoreConstants.PRECOMPILE_ORACLE_PX, address(new FailingPrecompile()).code);
        vm.expectRevert("Accountant: oracle px read failed");
        accountant.totalBacking();
    }

    /// @notice Oracle returning zero price is rejected as invalid (not silently
    /// multiplied to produce a zero NAV).
    function test_oracleZeroPrice_reverts() public {
        _setEvmUsdc(500e6);
        _setAccountValue(500e6);
        _setHedgeAsset(197, 0);
        _setSpotBalance(197, 1e7);
        _setOraclePrice(0, 0); // explicit zero price

        vm.expectRevert("Accountant: oracle px zero");
        accountant.totalBacking();
    }

    /// @notice Recovery path: once the precompile comes back, settlement
    /// picks up correctly from the previous snapshot without having booked
    /// a fake loss in between.
    function test_perpReadRecovery_noFakeLossAccumulated() public {
        _setEvmUsdc(1_000e6);
        _setAccountValue(500e6);
        _mintUsdm(1_400e6);

        vm.prank(admin);
        accountant.initializeSnapshot();

        // Simulate outage → settlement attempt reverts
        vm.etch(HyperCoreConstants.PRECOMPILE_ACCOUNT_MARGIN_SUMMARY, address(new FailingPrecompile()).code);
        vm.warp(block.timestamp + 21 hours);
        vm.prank(vault);
        vm.expectRevert("Accountant: perp read failed");
        accountant.settleDailyPnL();

        // Snapshot not updated during failed settlement — surplus is unchanged
        // surplus = (1000 + 500) - 1400 = 100 (same as at init, since backing still includes the
        // precompile value we set before the outage was installed)

        // Recovery: install working mock again, same account value → no profit, no loss
        MockPrecompile working = new MockPrecompile();
        vm.etch(HyperCoreConstants.PRECOMPILE_ACCOUNT_MARGIN_SUMMARY, address(working).code);
        _setAccountValue(500e6);

        vm.prank(vault);
        accountant.settleDailyPnL();

        // surplus = (1000 + 500) - 1400 = 100; no phantom loss booked
        assertEq(accountant.surplus(), int256(100e6), "surplus unchanged after recovery settlement");
    }

    // ─── Tests: notifyRouteYield (snapshot sync) ─────────────
    //
    // When yield USDC is routed from Vault to YieldEscrow (via routeYield),
    // the backing drops because YieldEscrow is excluded from totalBacking.
    // If the accountant's lastSurplusSnapshot is not adjusted after routing,
    // the next settleDailyPnL will treat that routing as a phantom loss and
    // misrecord debt. `notifyRouteYield` fixes that drift.

    function test_notifyRouteYield_updatesSnapshotDirectly() public {
        _initializeBaseline(1_000e6, 1_000e6);
        assertEq(accountant.lastSurplusSnapshot(), int256(0), "baseline snapshot = 0");

        vm.prank(vault);
        accountant.notifyRouteYield(100e6);

        assertEq(accountant.lastSurplusSnapshot(), -int256(100e6), "snapshot -= 100 after notify");
    }

    function test_notifyRouteYield_onlyVaultRole() public {
        _initializeBaseline(1_000e6, 1_000e6);

        vm.prank(address(0x9999));
        vm.expectRevert();
        accountant.notifyRouteYield(10e6);
    }

    /// @notice Lock in the 5-day scenario:
    /// Day 1: profit 50, Day 2: loss 20, Day 3: loss 30, Day 4: loss 10,
    /// Day 5: profit 80. Keeper routes yield via notifyRouteYield every day
    /// a profit is produced. Without the snapshot sync fix, Day 2 would record
    /// a phantom dailyPnL of -70 (20 real + 50 phantom from Day 1 routing)
    /// and surplus tracking would diverge from reality.
    function test_settleDailyPnL_5day_dailyDrain_snapshotSyncFix() public {
        _initializeBaseline(1_000e6, 1_000e6);
        uint256 t0 = block.timestamp;

        // ═══ Day 1: profit 50 ═══
        _setEvmUsdc(50e6);
        vm.warp(t0 + 21 hours);
        vm.prank(vault);
        accountant.settleDailyPnL();
        // surplus = (1000 + 50) - 1000 = 50
        assertEq(accountant.surplus(), int256(50e6), "D1 surplus = 50");

        // Operator routes yield: USDC moves to YieldEscrow (excluded from backing)
        // notifyRouteYield adjusts snapshot so next settlement sees no phantom loss
        _simulateDailyDrain(50e6);

        // ═══ Day 2: loss 20 ═══
        vm.prank(vault);
        usdc.transfer(address(0xdead), 20e6);
        vm.warp(t0 + 42 hours);
        vm.prank(vault);
        accountant.settleDailyPnL();
        // ✅ With fix: surplus = 0 - 20 = -20 (only real loss)
        // ❌ Without fix: surplus would appear as -70 (20 real + 50 phantom from Day 1 drain)
        assertEq(accountant.surplus(), -int256(20e6), "D2 surplus = -20 (real loss only)");

        // ═══ Day 3: loss 30 ═══
        vm.prank(vault);
        usdc.transfer(address(0xdead), 30e6);
        vm.warp(t0 + 63 hours);
        vm.prank(vault);
        accountant.settleDailyPnL();
        assertEq(accountant.surplus(), -int256(50e6), "D3 surplus = -50");

        // ═══ Day 4: loss 10 ═══
        vm.prank(vault);
        usdc.transfer(address(0xdead), 10e6);
        vm.warp(t0 + 84 hours);
        vm.prank(vault);
        accountant.settleDailyPnL();
        assertEq(accountant.surplus(), -int256(60e6), "D4 surplus = -60");

        // ═══ Day 5: profit 80 ═══
        _setEvmUsdc(80e6);
        vm.warp(t0 + 105 hours);
        vm.prank(vault);
        accountant.settleDailyPnL();
        // net PnL = 50 - 20 - 30 - 10 + 80 = +70, but 50 was routed → surplus = 70 - 50 = 20
        assertEq(accountant.surplus(), int256(20e6), "D5 surplus = 20");

        // Drain Day 5 yield to complete the cycle
        _simulateDailyDrain(20e6);

        // After full drain: surplus = 0, snapshot adjusted by notifyRouteYield
        assertEq(accountant.surplus(), int256(0), "final surplus = 0 after full drain");
    }

    /// @notice Lock in the simpler case: Day 1 profit → drain → Day 2 neutral
    /// (no change). Without the fix, Day 2 would record a phantom daily PnL
    /// equal to the negative of the Day 1 drain amount.
    function test_settleDailyPnL_drainThenNeutralDay_noPhantomLoss() public {
        _initializeBaseline(1_000e6, 1_000e6);
        uint256 t0 = block.timestamp;

        // Day 1: profit 40, settle, drain
        _setEvmUsdc(40e6);
        vm.warp(t0 + 21 hours);
        vm.prank(vault);
        accountant.settleDailyPnL();
        _simulateDailyDrain(40e6);

        // Day 2: no change in real backing (drain already happened)
        vm.warp(t0 + 42 hours);
        vm.prank(vault);
        accountant.settleDailyPnL();

        // ✅ With fix: surplus = 0 (no phantom loss from Day 1 drain)
        // ❌ Without fix: surplus = -40 (phantom loss equal to Day 1 drain)
        assertEq(accountant.surplus(), int256(0), "no phantom loss from routing");
    }

    /// @dev Simulate the vault routing `amount` of yield USDC to YieldEscrow.
    /// YieldEscrow is excluded from totalBacking, so backing/surplus drop by `amount`.
    /// notifyRouteYield adjusts the snapshot so the next settlement does not
    /// misread the routing as a real protocol loss.
    function _simulateDailyDrain(uint256 amount) internal {
        vm.startPrank(vault);
        // Simulate yield USDC moving out of vault (to YieldEscrow or similar)
        usdc.transfer(address(0xdead), amount);
        accountant.notifyRouteYield(amount);
        vm.stopPrank();
    }

    // ─── helper ──────────────────────────────────────────────

    function _initializeBaseline(uint256 evmAmount, uint256 usdmSupply) internal {
        _setEvmUsdc(evmAmount);
        _mintUsdm(usdmSupply);
        vm.prank(admin);
        accountant.initializeSnapshot();
    }
}

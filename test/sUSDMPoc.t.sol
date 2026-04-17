// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/tokens/USDM.sol";
import "../src/tokens/sUSDM.sol";
import {sUSDMEscrow} from "../src/tokens/sUSDMEscrow.sol";
import "../src/core/MonetrixConfig.sol";
import "../src/core/InsuranceFund.sol";
import "../src/governance/MonetrixAccessController.sol";

/// @title sUSDM + sUSDMEscrow POC Test Suite
/// @notice Covers: lifecycle (D6), boundary (D5), fuzz (D4), adversarial (D1), pause (EMG)
///         Every state-changing step checks INV-1/2/6; attacks verify exploits are mitigated.
contract sUSDMPocTest is Test {
    uint256 internal constant ONE_SUSDM = 1e12;
    uint256 internal constant ONE_USDM = 1e6;

    USDM usdm;
    sUSDM susdm;
    sUSDMEscrow unstakeEscrow;
    MonetrixConfig config;
    MonetrixAccessController acl;

    address admin = address(0xAD);
    address vaultMock = address(0xAA);
    address user1 = address(0x1001);
    address user2 = address(0x1002);
    address user3 = address(0x1003);
    address attacker = address(0xDEAD);

    function setUp() public {
        vm.startPrank(admin);

        MonetrixAccessController aclImpl = new MonetrixAccessController();
        ERC1967Proxy aclProxy =
            new ERC1967Proxy(address(aclImpl), abi.encodeCall(MonetrixAccessController.initialize, (admin)));
        acl = MonetrixAccessController(address(aclProxy));

        InsuranceFund insImpl = new InsuranceFund();
        ERC1967Proxy insProxy =
            new ERC1967Proxy(address(insImpl), abi.encodeCall(InsuranceFund.initialize, (address(1), address(acl))));

        MonetrixConfig configImpl = new MonetrixConfig();
        ERC1967Proxy configProxy = new ERC1967Proxy(
            address(configImpl),
            abi.encodeCall(MonetrixConfig.initialize, (address(insProxy), address(0xF0), address(acl)))
        );
        config = MonetrixConfig(address(configProxy));

        USDM usdmImpl = new USDM();
        ERC1967Proxy usdmProxy = new ERC1967Proxy(address(usdmImpl), abi.encodeCall(USDM.initialize, (address(acl))));
        usdm = USDM(address(usdmProxy));

        sUSDM susdmImpl = new sUSDM();
        ERC1967Proxy susdmProxy = new ERC1967Proxy(
            address(susdmImpl), abi.encodeCall(sUSDM.initialize, (address(usdm), address(config), address(acl)))
        );
        susdm = sUSDM(address(susdmProxy));

        acl.grantRole(acl.GOVERNOR(), admin);
        acl.grantRole(acl.GUARDIAN(), admin);
        acl.grantRole(acl.VAULT_CALLER(), admin);
        acl.grantRole(acl.VAULT_CALLER(), vaultMock);

        config.setCooldowns(3 days, 7 days);

        unstakeEscrow = new sUSDMEscrow(address(usdm), address(susdm));
        susdm.setEscrow(address(unstakeEscrow));

        vm.stopPrank();
    }

    // ─── Helpers ───

    function _mintUsdm(address to, uint256 amount) internal {
        vm.prank(admin);
        usdm.mint(to, amount);
    }

    function _stake(address user, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(user);
        usdm.approve(address(susdm), amount);
        shares = susdm.deposit(amount, user);
        vm.stopPrank();
    }

    function _mintAndStake(address user, uint256 amount) internal returns (uint256 shares) {
        _mintUsdm(user, amount);
        shares = _stake(user, amount);
    }

    function _injectYield(uint256 amount) internal {
        _mintUsdm(vaultMock, amount);
        vm.startPrank(vaultMock);
        usdm.approve(address(susdm), amount);
        susdm.injectYield(amount);
        vm.stopPrank();
    }

    function _rate() internal view returns (uint256) {
        return susdm.convertToAssets(ONE_SUSDM);
    }

    // ─── Invariant Checkers ───

    function _checkInvariants() internal view {
        // INV-1: Physical isolation
        assertEq(susdm.totalAssets(), usdm.balanceOf(address(susdm)), "INV-1: totalAssets != balanceOf(sUSDM)");

        // INV-2: Escrow solvency
        assertEq(
            usdm.balanceOf(address(unstakeEscrow)),
            susdm.totalPendingClaims(),
            "INV-2: escrow balance != totalPendingClaims"
        );

        // INV-6: Shares fully backed
        if (susdm.totalSupply() > 0) {
            assertLe(
                susdm.convertToAssets(susdm.totalSupply()),
                susdm.totalAssets(),
                "INV-6: shares not fully backed"
            );
        }
    }

    function _checkRateUnchanged(uint256 rateBefore) internal view {
        if (susdm.totalSupply() > 0) {
            assertApproxEqAbs(_rate(), rateBefore, 1, "INV-4: rate changed after unstake");
        }
    }

    function _checkRateIncreased(uint256 rateBefore) internal view {
        if (susdm.totalSupply() > 0) {
            assertGt(_rate(), rateBefore, "INV-5: rate did not increase after yield");
        }
    }

    // ================================================================
    //  D6: LIFECYCLE TESTS
    // ================================================================

    /// @notice Full happy path: stake → yield → unstake → wait → claim
    function test_lifecycle_stakeYieldUnstakeClaim() public {
        uint256 shares = _mintAndStake(user1, 100 * ONE_USDM);
        _checkInvariants();
        assertEq(shares, 100 * ONE_SUSDM, "initial stake 1:1");
        assertEq(_rate(), ONE_USDM, "initial rate = 1.0");

        uint256 rateBefore = _rate();
        _injectYield(10 * ONE_USDM);
        _checkInvariants();
        _checkRateIncreased(rateBefore);

        rateBefore = _rate();
        vm.prank(user1);
        uint256 reqId = susdm.cooldownShares(50 * ONE_SUSDM);
        _checkInvariants();
        _checkRateUnchanged(rateBefore);

        vm.warp(block.timestamp + 7 days);

        uint256 usdmBefore = usdm.balanceOf(user1);
        vm.prank(user1);
        susdm.claimUnstake(reqId);
        _checkInvariants();

        uint256 received = usdm.balanceOf(user1) - usdmBefore;
        assertGt(received, 50 * ONE_USDM, "should get > 50 USDM due to yield");
    }

    /// @notice 3 users, interleaved: stake, yield, unstake, stake, yield, claim
    function test_lifecycle_multiUser_interleaved() public {
        _mintAndStake(user1, 100 * ONE_USDM);
        _mintAndStake(user2, 200 * ONE_USDM);
        _checkInvariants();

        uint256 rateBefore = _rate();
        _injectYield(30 * ONE_USDM);
        _checkInvariants();
        _checkRateIncreased(rateBefore);

        uint256 user1Bal = susdm.balanceOf(user1);
        rateBefore = _rate();
        vm.prank(user1);
        uint256 req1 = susdm.cooldownShares(user1Bal);
        _checkInvariants();
        _checkRateUnchanged(rateBefore);

        rateBefore = _rate();
        uint256 user3Shares = _mintAndStake(user3, 50 * ONE_USDM);
        _checkInvariants();
        assertLt(user3Shares, 50 * ONE_SUSDM, "fewer shares at rate > 1");
        assertApproxEqAbs(_rate(), rateBefore, 1, "deposit doesn't change rate");

        rateBefore = _rate();
        _injectYield(15 * ONE_USDM);
        _checkInvariants();
        _checkRateIncreased(rateBefore);

        uint256 user2Half = susdm.balanceOf(user2) / 2;
        rateBefore = _rate();
        vm.prank(user2);
        uint256 req2 = susdm.cooldownShares(user2Half);
        _checkInvariants();
        _checkRateUnchanged(rateBefore);

        vm.warp(block.timestamp + 7 days);

        vm.prank(user1);
        susdm.claimUnstake(req1);
        _checkInvariants();

        vm.prank(user2);
        susdm.claimUnstake(req2);
        _checkInvariants();

        assertGt(susdm.balanceOf(user2), 0);
        assertGt(susdm.balanceOf(user3), 0);
    }

    /// @notice Same user creates multiple requests with staggered cooldowns
    function test_lifecycle_multipleRequestsPerUser() public {
        _mintAndStake(user1, 100 * ONE_USDM);
        _injectYield(20 * ONE_USDM);

        // Batch 1: two requests at t=1
        vm.startPrank(user1);
        uint256 req1 = susdm.cooldownShares(10 * ONE_SUSDM);
        uint256 req2 = susdm.cooldownShares(10 * ONE_SUSDM);
        vm.stopPrank();
        _checkInvariants();

        // Warp to t = 7 days, claim batch 1
        vm.warp(block.timestamp + 7 days);

        vm.prank(user1);
        susdm.claimUnstake(req1);
        _checkInvariants();

        vm.prank(user1);
        susdm.claimUnstake(req2);
        _checkInvariants();

        // Batch 2: one request at t = 7 days
        vm.prank(user1);
        uint256 req3 = susdm.cooldownShares(10 * ONE_SUSDM);
        _checkInvariants();

        // req3 not yet expired (just created)
        vm.expectRevert();
        vm.prank(user1);
        susdm.claimUnstake(req3);

        // Warp past req3 cooldown, then claim
        (,,,, uint256 req3End) = susdm.unstakeRequests(req3);
        vm.warp(req3End);
        vm.prank(user1);
        susdm.claimUnstake(req3);
        _checkInvariants();

        assertEq(susdm.getUserUnstakeIds(user1).length, 0, "all requests claimed");
    }

    /// @notice cooldownAssets delivers exact requested amount (previewWithdraw fix)
    function test_lifecycle_cooldownAssets_exactAmount() public {
        _mintAndStake(user1, 100 * ONE_USDM);
        _injectYield(10 * ONE_USDM);

        uint256 requested = 55 * ONE_USDM;
        vm.prank(user1);
        uint256 reqId = susdm.cooldownAssets(requested);
        _checkInvariants();

        (,, uint256 stored,,) = susdm.unstakeRequests(reqId);
        assertEq(stored, requested, "exact assets stored");

        vm.warp(block.timestamp + 7 days);
        uint256 balBefore = usdm.balanceOf(user1);
        vm.prank(user1);
        susdm.claimUnstake(reqId);

        assertEq(usdm.balanceOf(user1) - balBefore, requested, "exact assets received");
        _checkInvariants();
    }

    // ================================================================
    //  D5: BOUNDARY TESTS
    // ================================================================

    function test_boundary_zeroDeposit_noop() public {
        _mintUsdm(user1, ONE_USDM);
        vm.startPrank(user1);
        usdm.approve(address(susdm), ONE_USDM);
        uint256 shares = susdm.deposit(0, user1);
        vm.stopPrank();

        // ERC4626 deposit(0) is a no-op, returns 0 shares
        assertEq(shares, 0, "zero deposit = zero shares");
        assertEq(susdm.balanceOf(user1), 0, "no balance");
    }

    function test_boundary_zeroCooldownShares_reverts() public {
        _mintAndStake(user1, 100 * ONE_USDM);
        vm.prank(user1);
        vm.expectRevert("sUSDM: zero shares");
        susdm.cooldownShares(0);
    }

    function test_boundary_zeroCooldownAssets_reverts() public {
        _mintAndStake(user1, 100 * ONE_USDM);
        vm.prank(user1);
        vm.expectRevert("sUSDM: zero assets");
        susdm.cooldownAssets(0);
    }

    function test_boundary_zeroYield_reverts() public {
        _mintAndStake(user1, 100 * ONE_USDM);
        vm.prank(vaultMock);
        vm.expectRevert("sUSDM: zero yield");
        susdm.injectYield(0);
    }

    function test_boundary_firstDepositor() public {
        assertEq(susdm.totalSupply(), 0);
        assertEq(susdm.totalAssets(), 0);

        uint256 shares = _mintAndStake(user1, ONE_USDM);

        assertEq(shares, ONE_SUSDM, "first depositor gets 1:1");
        assertEq(_rate(), ONE_USDM, "rate starts at 1.0");
        _checkInvariants();
    }

    function test_boundary_lastWithdrawer_emptyVault() public {
        uint256 shares = _mintAndStake(user1, 100 * ONE_USDM);

        vm.prank(user1);
        uint256 reqId = susdm.cooldownShares(shares);

        assertEq(susdm.totalSupply(), 0, "vault empty");
        assertEq(susdm.totalAssets(), 0, "no assets left");
        _checkInvariants();

        vm.warp(block.timestamp + 7 days);
        vm.prank(user1);
        susdm.claimUnstake(reqId);

        assertEq(usdm.balanceOf(user1), 100 * ONE_USDM, "full USDM returned");
        assertEq(susdm.totalPendingClaims(), 0);
        _checkInvariants();
    }

    function test_boundary_minimalDeposit_1wei() public {
        _mintUsdm(user1, 1);
        vm.startPrank(user1);
        usdm.approve(address(susdm), 1);
        uint256 shares = susdm.deposit(1, user1);
        vm.stopPrank();

        assertGt(shares, 0, "should get shares for 1 wei");
        _checkInvariants();
    }

    function test_boundary_cooldownExactExpiry() public {
        _mintAndStake(user1, 100 * ONE_USDM);

        vm.prank(user1);
        uint256 reqId = susdm.cooldownShares(50 * ONE_SUSDM);
        (,,,, uint256 cooldownEnd) = susdm.unstakeRequests(reqId);

        // 1 second before: revert
        vm.warp(cooldownEnd - 1);
        vm.prank(user1);
        vm.expectRevert();
        susdm.claimUnstake(reqId);

        // Exactly at expiry: success
        vm.warp(cooldownEnd);
        vm.prank(user1);
        susdm.claimUnstake(reqId);
        _checkInvariants();
    }

    function test_boundary_fullBalance_cooldownShares() public {
        uint256 shares = _mintAndStake(user1, 100 * ONE_USDM);
        _injectYield(20 * ONE_USDM);

        vm.prank(user1);
        susdm.cooldownShares(shares);

        assertEq(susdm.totalSupply(), 0, "all shares burned");
        // Floor rounding in convertToAssets may leave ≤1 wei dust in sUSDM
        assertLe(susdm.totalAssets(), 1, "at most 1 wei dust");
        _checkInvariants();
    }

    function test_boundary_fullBalance_cooldownAssets() public {
        _mintAndStake(user1, 100 * ONE_USDM);
        _injectYield(20 * ONE_USDM);

        uint256 maxAssets = susdm.convertToAssets(susdm.balanceOf(user1));

        vm.prank(user1);
        susdm.cooldownAssets(maxAssets);

        // previewWithdraw ceil rounding may need more shares than available,
        // leaving a small remainder. Bounded by virtual shares offset.
        assertLe(susdm.balanceOf(user1), ONE_SUSDM, "remainder bounded by 1 sUSDM");
        _checkInvariants();
    }

    function test_boundary_insufficientShares_reverts() public {
        _mintAndStake(user1, 100 * ONE_USDM);

        vm.prank(user1);
        vm.expectRevert("sUSDM: insufficient balance");
        susdm.cooldownShares(101 * ONE_SUSDM);
    }

    function test_boundary_maxYieldPerInjection() public {
        _mintAndStake(user1, 100 * ONE_USDM);
        uint256 maxYield = config.maxYieldPerInjection();

        // Exactly at max: success
        _mintUsdm(vaultMock, maxYield);
        vm.startPrank(vaultMock);
        usdm.approve(address(susdm), maxYield);
        susdm.injectYield(maxYield);
        vm.stopPrank();
        _checkInvariants();

        // Max + 1: revert
        _mintUsdm(vaultMock, maxYield + 1);
        vm.startPrank(vaultMock);
        usdm.approve(address(susdm), maxYield + 1);
        vm.expectRevert("sUSDM: yield exceeds max");
        susdm.injectYield(maxYield + 1);
        vm.stopPrank();
    }

    function test_boundary_yieldWhenNoStakers() public {
        assertEq(susdm.totalSupply(), 0);

        // Yield with no stakers: USDM enters but benefits no one
        _injectYield(10 * ONE_USDM);

        assertEq(susdm.totalAssets(), 10 * ONE_USDM, "USDM entered sUSDM");
        assertEq(susdm.totalSupply(), 0, "still no shares");
        _checkInvariants();

        // Next depositor inherits the "dead" USDM via rate
        uint256 shares = _mintAndStake(user1, 100 * ONE_USDM);
        assertLt(shares, 100 * ONE_SUSDM, "fewer shares due to existing assets");
    }

    // ================================================================
    //  D4: FUZZ TESTS
    // ================================================================

    /// @notice Deposit → full unstake → claim round-trip preserves value (±1 wei)
    function testFuzz_depositUnstakeRoundTrip(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000 * ONE_USDM);

        uint256 shares = _mintAndStake(user1, amount);
        _checkInvariants();

        vm.prank(user1);
        uint256 reqId = susdm.cooldownShares(shares);
        _checkInvariants();

        vm.warp(block.timestamp + 7 days);
        vm.prank(user1);
        susdm.claimUnstake(reqId);

        assertLe(usdm.balanceOf(user1), amount, "round-trip must not create value");
        assertApproxEqAbs(usdm.balanceOf(user1), amount, 1, "round-trip loss <= 1 wei");
        _checkInvariants();
    }

    /// @notice Rate strictly increases after any meaningful yield injection
    function testFuzz_rateMonotonicity(uint256 yieldAmount) public {
        uint256 maxYield = config.maxYieldPerInjection();
        // At 1M USDM scale, need ~2 USDM yield to move integer rate by 1
        yieldAmount = bound(yieldAmount, 10 * ONE_USDM, maxYield);

        _mintAndStake(user1, 1_000_000 * ONE_USDM);

        uint256 rateBefore = _rate();
        _injectYield(yieldAmount);

        assertGt(_rate(), rateBefore, "rate must increase");
        _checkInvariants();
    }

    /// @notice cooldownShares preserves rate for any stake/unstake %
    function testFuzz_cooldownSharesPreservesRate(uint256 stakeAmount, uint256 unstakePct) public {
        stakeAmount = bound(stakeAmount, 10 * ONE_USDM, 1_000_000 * ONE_USDM);
        unstakePct = bound(unstakePct, 1, 99);

        uint256 shares = _mintAndStake(user1, stakeAmount);

        // Shift rate away from 1.0
        uint256 yieldAmount = bound(stakeAmount / 10, 1, config.maxYieldPerInjection());
        _injectYield(yieldAmount);

        uint256 unstakeShares = shares * unstakePct / 100;
        if (unstakeShares == 0) unstakeShares = 1;

        uint256 rateBefore = _rate();

        vm.prank(user1);
        susdm.cooldownShares(unstakeShares);

        if (susdm.totalSupply() > 0) {
            // Floor rounding in convertToAssets can cause small drift at edge ratios
            assertApproxEqAbs(_rate(), rateBefore, 10, "rate shifted significantly");
        }
        _checkInvariants();
    }

    /// @notice cooldownAssets always stores exact requested amount
    function testFuzz_cooldownAssetsExact(uint256 stakeAmount, uint256 withdrawPct) public {
        stakeAmount = bound(stakeAmount, 10 * ONE_USDM, 1_000_000 * ONE_USDM);
        withdrawPct = bound(withdrawPct, 1, 95);

        _mintAndStake(user1, stakeAmount);
        uint256 yieldAmount = bound(stakeAmount / 10, 1, config.maxYieldPerInjection());
        _injectYield(yieldAmount);

        uint256 maxWithdrawable = susdm.convertToAssets(susdm.balanceOf(user1));
        uint256 requested = maxWithdrawable * withdrawPct / 100;
        if (requested == 0) requested = 1;

        vm.prank(user1);
        uint256 reqId = susdm.cooldownAssets(requested);

        (,, uint256 stored,,) = susdm.unstakeRequests(reqId);
        assertEq(stored, requested, "stored must equal requested exactly");
        _checkInvariants();
    }

    // ================================================================
    //  D1: ADVERSARIAL / ATTACK TESTS
    // ================================================================

    /// @notice Donation to sUSDM inflates rate but attacker gains nothing
    function test_attack_donationToSUSDM() public {
        _mintAndStake(user1, 100 * ONE_USDM);
        uint256 rateBefore = _rate();

        // Attacker donates USDM directly (not via deposit)
        _mintUsdm(attacker, 50 * ONE_USDM);
        vm.prank(attacker);
        usdm.transfer(address(susdm), 50 * ONE_USDM);

        assertGt(_rate(), rateBefore, "donation increases rate");
        assertEq(susdm.balanceOf(attacker), 0, "attacker has no shares");
        _checkInvariants();

        // Victim (user1) benefits
        uint256 victimValue = susdm.convertToAssets(susdm.balanceOf(user1));
        assertGt(victimValue, 100 * ONE_USDM, "victim benefits from donation");
    }

    /// @notice Donation to escrow is harmless — funds are stuck
    function test_attack_donationToEscrow() public {
        _mintAndStake(user1, 100 * ONE_USDM);

        vm.prank(user1);
        uint256 reqId = susdm.cooldownShares(50 * ONE_SUSDM);

        // Attacker donates to escrow
        _mintUsdm(attacker, 10 * ONE_USDM);
        vm.prank(attacker);
        usdm.transfer(address(unstakeEscrow), 10 * ONE_USDM);

        // Escrow has excess, but INV-1 unaffected
        assertGt(usdm.balanceOf(address(unstakeEscrow)), susdm.totalPendingClaims());
        assertEq(susdm.totalAssets(), usdm.balanceOf(address(susdm)), "INV-1 intact");

        // User's claim still works
        vm.warp(block.timestamp + 7 days);
        vm.prank(user1);
        susdm.claimUnstake(reqId);

        // Attacker's donation stuck in escrow permanently
        assertEq(usdm.balanceOf(address(unstakeEscrow)), 10 * ONE_USDM, "attacker USDM stuck");
    }

    /// @notice First-depositor inflation mitigated by _decimalsOffset = 6
    function test_attack_firstDepositorInflation() public {
        // Step 1: attacker deposits minimal amount
        _mintUsdm(attacker, 1);
        vm.startPrank(attacker);
        usdm.approve(address(susdm), 1);
        uint256 attackerShares = susdm.deposit(1, attacker);
        vm.stopPrank();

        // Step 2: attacker donates large amount to inflate rate
        _mintUsdm(attacker, 1_000 * ONE_USDM);
        vm.prank(attacker);
        usdm.transfer(address(susdm), 1_000 * ONE_USDM);

        // Step 3: victim deposits normally
        uint256 victimShares = _mintAndStake(user1, 100 * ONE_USDM);

        // Virtual shares (1e6 from offset) protect the victim
        assertGt(victimShares, 0, "victim must get shares");

        uint256 victimValue = susdm.convertToAssets(victimShares);
        assertGt(victimValue, 99 * ONE_USDM, "victim loses < 1% to inflation");
        _checkInvariants();

        // Attacker's shares are diluted — attack is unprofitable
        uint256 attackerValue = susdm.convertToAssets(attackerShares);
        assertLt(attackerValue, 1_000 * ONE_USDM, "attacker lost most of donation");
    }

    /// @notice Escrow rejects unauthorized deposit
    function test_attack_escrowUnauthorizedDeposit() public {
        _mintUsdm(attacker, 100 * ONE_USDM);
        vm.prank(attacker);
        usdm.approve(address(unstakeEscrow), 100 * ONE_USDM);

        vm.prank(attacker);
        vm.expectRevert(sUSDMEscrow.NotSUSDM.selector);
        unstakeEscrow.deposit(100 * ONE_USDM);
    }

    /// @notice Escrow rejects unauthorized release
    function test_attack_escrowUnauthorizedRelease() public {
        _mintAndStake(user1, 100 * ONE_USDM);
        vm.prank(user1);
        susdm.cooldownShares(50 * ONE_SUSDM);

        vm.prank(attacker);
        vm.expectRevert(sUSDMEscrow.NotSUSDM.selector);
        unstakeEscrow.release(attacker, 50 * ONE_USDM);
    }

    /// @notice Escrow constructor rejects zero addresses
    function test_attack_escrowZeroAddress() public {
        vm.expectRevert(sUSDMEscrow.ZeroAddress.selector);
        new sUSDMEscrow(address(0), address(susdm));

        vm.expectRevert(sUSDMEscrow.ZeroAddress.selector);
        new sUSDMEscrow(address(usdm), address(0));
    }

    /// @notice Double claim reverts
    function test_attack_doubleClaim() public {
        _mintAndStake(user1, 100 * ONE_USDM);

        vm.prank(user1);
        uint256 reqId = susdm.cooldownShares(50 * ONE_SUSDM);

        vm.warp(block.timestamp + 7 days);

        vm.prank(user1);
        susdm.claimUnstake(reqId);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(sUSDM.AlreadyClaimed.selector, reqId));
        susdm.claimUnstake(reqId);
    }

    /// @notice Cannot claim another user's request
    function test_attack_claimOthersRequest() public {
        _mintAndStake(user1, 100 * ONE_USDM);

        vm.prank(user1);
        uint256 reqId = susdm.cooldownShares(50 * ONE_SUSDM);

        vm.warp(block.timestamp + 7 days);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(sUSDM.NotRequestOwner.selector, reqId, attacker, user1));
        susdm.claimUnstake(reqId);
    }

    /// @notice setEscrow is one-shot — replay reverts
    function test_attack_setEscrowReplay() public {
        sUSDMEscrow newEscrow = new sUSDMEscrow(address(usdm), address(susdm));

        vm.prank(admin);
        vm.expectRevert(sUSDM.EscrowAlreadySet.selector);
        susdm.setEscrow(address(newEscrow));
    }

    /// @notice setEscrow with wrong USDM token
    function test_attack_setEscrowWrongUsdm() public {
        vm.startPrank(admin);
        sUSDM fresh = sUSDM(
            address(
                new ERC1967Proxy(
                    address(new sUSDM()),
                    abi.encodeCall(sUSDM.initialize, (address(usdm), address(config), address(acl)))
                )
            )
        );

        sUSDMEscrow badEscrow = new sUSDMEscrow(address(0xBAD), address(fresh));

        vm.expectRevert(sUSDM.EscrowMismatch.selector);
        fresh.setEscrow(address(badEscrow));
        vm.stopPrank();
    }

    /// @notice setEscrow with wrong sUSDM binding
    function test_attack_setEscrowWrongSusdm() public {
        vm.startPrank(admin);
        sUSDM fresh = sUSDM(
            address(
                new ERC1967Proxy(
                    address(new sUSDM()),
                    abi.encodeCall(sUSDM.initialize, (address(usdm), address(config), address(acl)))
                )
            )
        );

        sUSDMEscrow badEscrow = new sUSDMEscrow(address(usdm), address(0xDEAD));

        vm.expectRevert(sUSDM.EscrowMismatch.selector);
        fresh.setEscrow(address(badEscrow));
        vm.stopPrank();
    }

    /// @notice Non-governor cannot set escrow
    function test_attack_setEscrowUnauthorized() public {
        vm.startPrank(admin);
        sUSDM fresh = sUSDM(
            address(
                new ERC1967Proxy(
                    address(new sUSDM()),
                    abi.encodeCall(sUSDM.initialize, (address(usdm), address(config), address(acl)))
                )
            )
        );
        vm.stopPrank();

        sUSDMEscrow goodEscrow = new sUSDMEscrow(address(usdm), address(fresh));

        vm.prank(attacker);
        vm.expectRevert();
        fresh.setEscrow(address(goodEscrow));
    }

    /// @notice Front-running yield is impractical due to 7-day cooldown
    function test_attack_frontRunYieldInjection() public {
        _mintAndStake(user1, 1_000 * ONE_USDM);

        // Attacker front-runs: stakes just before yield
        uint256 attackerShares = _mintAndStake(attacker, 1_000 * ONE_USDM);
        _injectYield(100 * ONE_USDM);

        // Attacker can unstake but cannot claim for 7 days
        vm.prank(attacker);
        uint256 reqId = susdm.cooldownShares(attackerShares);

        vm.prank(attacker);
        vm.expectRevert();
        susdm.claimUnstake(reqId);

        _checkInvariants();
    }

    /// @notice Unauthorized injectYield call
    function test_attack_injectYieldUnauthorized() public {
        _mintAndStake(user1, 100 * ONE_USDM);
        _mintUsdm(attacker, 10 * ONE_USDM);

        vm.startPrank(attacker);
        usdm.approve(address(susdm), 10 * ONE_USDM);
        vm.expectRevert();
        susdm.injectYield(10 * ONE_USDM);
        vm.stopPrank();
    }

    /// @notice Unstake without escrow set reverts
    function test_attack_unstakeWithoutEscrow() public {
        // Deploy fresh sUSDM without escrow
        vm.startPrank(admin);
        sUSDM fresh = sUSDM(
            address(
                new ERC1967Proxy(
                    address(new sUSDM()),
                    abi.encodeCall(sUSDM.initialize, (address(usdm), address(config), address(acl)))
                )
            )
        );
        vm.stopPrank();

        // Stake works (no escrow needed)
        _mintUsdm(user1, 100 * ONE_USDM);
        vm.startPrank(user1);
        usdm.approve(address(fresh), 100 * ONE_USDM);
        fresh.deposit(100 * ONE_USDM, user1);

        // Unstake reverts — escrow not set
        vm.expectRevert(sUSDM.EscrowNotSet.selector);
        fresh.cooldownShares(50 * ONE_SUSDM);

        vm.expectRevert(sUSDM.EscrowNotSet.selector);
        fresh.cooldownAssets(50 * ONE_USDM);
        vm.stopPrank();
    }

    // ================================================================
    //  EMG: PAUSE TESTS
    // ================================================================

    /// @notice sUSDM pause blocks all user ops (EMG-2)
    function test_pause_blocksAllOps() public {
        _mintAndStake(user1, 100 * ONE_USDM);
        _mintUsdm(user2, 50 * ONE_USDM);

        vm.prank(admin);
        susdm.pause();

        // deposit
        vm.startPrank(user2);
        usdm.approve(address(susdm), 50 * ONE_USDM);
        vm.expectRevert();
        susdm.deposit(50 * ONE_USDM, user2);
        vm.stopPrank();

        // cooldownShares
        vm.prank(user1);
        vm.expectRevert();
        susdm.cooldownShares(10 * ONE_SUSDM);

        // cooldownAssets
        vm.prank(user1);
        vm.expectRevert();
        susdm.cooldownAssets(10 * ONE_USDM);

        // transfer
        vm.prank(user1);
        vm.expectRevert();
        susdm.transfer(user2, 10 * ONE_SUSDM);
    }

    /// @notice Unpause restores pending requests (EMG-3)
    function test_pause_unpause_requestsSurvive() public {
        _mintAndStake(user1, 100 * ONE_USDM);

        vm.prank(user1);
        uint256 reqId = susdm.cooldownShares(50 * ONE_SUSDM);

        vm.warp(block.timestamp + 7 days);

        // Pause: claim blocked
        vm.prank(admin);
        susdm.pause();

        vm.prank(user1);
        vm.expectRevert();
        susdm.claimUnstake(reqId);

        // Unpause: claim works, request survived
        vm.prank(admin);
        susdm.unpause();

        vm.prank(user1);
        susdm.claimUnstake(reqId);
        _checkInvariants();

        assertGt(usdm.balanceOf(user1), 0, "user received USDM after unpause");
    }

    /// @notice Non-guardian cannot pause
    function test_pause_nonGuardian_reverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        susdm.pause();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/tokens/USDM.sol";
import "../src/tokens/sUSDM.sol";
import {sUSDMEscrow} from "../src/tokens/sUSDMEscrow.sol";
import "../src/core/MonetrixConfig.sol";
import "../src/core/MonetrixVault.sol";
import "../src/core/InsuranceFund.sol";
import "../src/core/YieldEscrow.sol";
import "../src/governance/MonetrixAccessController.sol";
import "./mocks/MockUSDC.sol";

contract sUSDMExchangeRateStrictTest is Test {
    uint256 internal constant ONE_SUSDM = 1e12;
    uint256 internal constant VIRTUAL_SHARES = 1e6;

    MockUSDC usdc;
    USDM usdm;
    sUSDM susdm;
    sUSDMEscrow unstakeEscrow;
    MonetrixConfig config;
    MonetrixVault vault;
    InsuranceFund insurance;
    YieldEscrow yieldEscrow;
    MonetrixAccessController acl;

    address admin = address(0xAD);
    address user1 = address(0x1);
    address user2 = address(0x2);
    address foundation = address(0xF0);
    address dummyAccountant = address(0xA11CE);
    address dummyRedeemEscrow = address(0xBEEF);

    function setUp() public {
        vm.startPrank(admin);

        usdc = new MockUSDC();

        MonetrixAccessController aclImpl = new MonetrixAccessController();
        ERC1967Proxy aclProxy =
            new ERC1967Proxy(address(aclImpl), abi.encodeCall(MonetrixAccessController.initialize, (admin)));
        acl = MonetrixAccessController(address(aclProxy));

        USDM usdmImpl = new USDM();
        ERC1967Proxy usdmProxy = new ERC1967Proxy(address(usdmImpl), abi.encodeCall(USDM.initialize, (address(acl))));
        usdm = USDM(address(usdmProxy));

        InsuranceFund insuranceImpl = new InsuranceFund();
        ERC1967Proxy insuranceProxy = new ERC1967Proxy(
            address(insuranceImpl), abi.encodeCall(InsuranceFund.initialize, (address(usdc), address(acl)))
        );
        insurance = InsuranceFund(address(insuranceProxy));

        MonetrixConfig configImpl = new MonetrixConfig();
        ERC1967Proxy configProxy = new ERC1967Proxy(
            address(configImpl),
            abi.encodeCall(MonetrixConfig.initialize, (address(insurance), foundation, address(acl)))
        );
        config = MonetrixConfig(address(configProxy));

        sUSDM susdmImpl = new sUSDM();
        ERC1967Proxy susdmProxy = new ERC1967Proxy(
            address(susdmImpl), abi.encodeCall(sUSDM.initialize, (address(usdm), address(config), address(acl)))
        );
        susdm = sUSDM(address(susdmProxy));

        MonetrixVault vaultImpl = new MonetrixVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeCall(
                MonetrixVault.initialize,
                (
                    address(usdc),
                    address(usdm),
                    address(susdm),
                    address(config),
                    address(0x1234),
                    address(0x5678),
                    address(insurance),
                    address(acl)
                )
            )
        );
        vault = MonetrixVault(address(vaultProxy));

        YieldEscrow yieldImpl = new YieldEscrow();
        ERC1967Proxy yieldProxy = new ERC1967Proxy(
            address(yieldImpl),
            abi.encodeCall(YieldEscrow.initialize, (address(usdc), address(vault), address(acl)))
        );
        yieldEscrow = YieldEscrow(address(yieldProxy));

        acl.grantRole(acl.GOVERNOR(), admin);
        acl.grantRole(acl.GUARDIAN(), admin);
        acl.grantRole(acl.OPERATOR(), admin);
        acl.grantRole(acl.VAULT_CALLER(), admin);
        acl.grantRole(acl.VAULT_CALLER(), address(vault));

        config.setCooldowns(3 days, 7 days);

        unstakeEscrow = new sUSDMEscrow(address(usdm), address(susdm));
        susdm.setEscrow(address(unstakeEscrow));

        vault.setAccountant(dummyAccountant);
        vault.setRedeemEscrow(dummyRedeemEscrow);
        vault.setYieldEscrow(address(yieldEscrow));

        vm.stopPrank();

        usdc.mint(user1, 1_000_000e6);
        usdc.mint(user2, 1_000_000e6);
    }

    function _depositUsdc(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
    }

    function _stakeUsdm(address user, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(user);
        usdm.approve(address(susdm), amount);
        shares = susdm.deposit(amount, user);
        vm.stopPrank();
    }

    function _mintUsdm(address user, uint256 amount) internal {
        vm.prank(admin);
        usdm.mint(user, amount);
    }

    function _depositAndStake(address user, uint256 amount) internal returns (uint256 shares) {
        _depositUsdc(user, amount);
        shares = _stakeUsdm(user, amount);
    }

    function _mintAndStake(address user, uint256 amount) internal returns (uint256 shares) {
        _mintUsdm(user, amount);
        shares = _stakeUsdm(user, amount);
    }

    function _injectYieldDirect(uint256 amount) internal {
        vm.startPrank(admin);
        usdm.mint(admin, amount);
        usdm.approve(address(susdm), amount);
        susdm.injectYield(amount);
        vm.stopPrank();
    }

    function _rate() internal view returns (uint256) {
        return susdm.convertToAssets(ONE_SUSDM);
    }

    function _expectedRate(uint256 totalAssets_, uint256 totalSupply_) internal pure returns (uint256) {
        return (ONE_SUSDM * (totalAssets_ + 1)) / (totalSupply_ + VIRTUAL_SHARES);
    }

    function test_initialStake_startsAtOneToOneRate() public {
        uint256 shares = _depositAndStake(user1, 100e6);

        assertEq(shares, 100e12, "initial stake should mint 1:1 shares");
        assertEq(susdm.totalAssets(), 100e6, "100 USDM should back shares");
        assertEq(susdm.totalSupply(), 100e12, "raw share supply should match");
        assertEq(_rate(), 1e6, "1 sUSDM should start at 1 USDM");
        assertEq(_rate(), _expectedRate(susdm.totalAssets(), susdm.totalSupply()), "rate formula mismatch");
    }

    function test_yieldInjection_increasesRate_byExactFormula() public {
        _mintAndStake(user1, 5e6);

        vm.prank(user1);
        susdm.cooldownShares(2e12);

        assertEq(susdm.totalAssets(), 3e6, "only 3 USDM should remain backing live shares");
        assertEq(susdm.totalSupply(), 3e12, "only 3 sUSDM should remain live");
        assertEq(_rate(), 1e6, "rate should still be 1 before yield");

        _injectYieldDirect(795883);

        assertEq(susdm.totalAssets(), 3_795_883, "yield should add directly to sUSDM backing");
        assertEq(susdm.totalSupply(), 3e12, "yield should not mint new sUSDM shares");
        assertEq(_rate(), 1_265_294, "1 sUSDM should now be worth about 1.265294 USDM");
        assertEq(_rate(), _expectedRate(susdm.totalAssets(), susdm.totalSupply()), "rate formula mismatch");
    }

    function test_newStakeAfterYield_keepsRate_butMintsFewerShares() public {
        _mintAndStake(user1, 5e6);

        vm.prank(user1);
        susdm.cooldownShares(2e12);

        _injectYieldDirect(795883);

        uint256 rateBeforeSecondStake = _rate();
        uint256 previewedShares = susdm.previewDeposit(18e6);
        uint256 mintedShares = _mintAndStake(user2, 18e6);

        assertEq(rateBeforeSecondStake, 1_265_294, "setup rate should match reproduced scenario");
        assertEq(mintedShares, previewedShares, "deposit should mint previewed shares");
        assertEq(mintedShares, 14_225_939_991_843, "second staker should receive fewer shares at higher rate");
        assertLt(mintedShares, 18e12, "rate > 1 means later staker gets fewer than 1:1 shares");
        assertEq(_rate(), rateBeforeSecondStake, "adding stake should not change the sUSDM/USDM rate");
    }

    function test_unstakeAndClaimAfterYield_doNotChangeRate() public {
        _mintAndStake(user1, 5e6);

        vm.prank(user1);
        susdm.cooldownShares(2e12);

        _injectYieldDirect(795883);
        _mintAndStake(user2, 18e6);

        uint256 rateBeforeCooldown = _rate();

        vm.prank(user2);
        uint256 requestId = susdm.cooldownShares(1e12);

        assertEq(_rate(), rateBeforeCooldown, "cooldown request should not change the live exchange rate");

        vm.warp(block.timestamp + 7 days);
        vm.prank(user2);
        susdm.claimUnstake(requestId);

        assertEq(_rate(), rateBeforeCooldown, "claim should not change the live exchange rate");
    }

    function test_vaultDistributeYield_changesRate_onlyByUserShare() public {
        _depositAndStake(user1, 100_000e6);

        uint256 assetsBefore = susdm.totalAssets();
        uint256 supplyBefore = susdm.totalSupply();
        uint256 rateBefore = _rate();

        usdc.mint(address(yieldEscrow), 1_000e6);

        vm.prank(admin);
        vault.distributeYield();

        uint256 userShare = 700e6;
        uint256 insuranceShare = 100e6;
        uint256 foundationShare = 200e6;

        assertEq(susdm.totalAssets(), assetsBefore + userShare, "only user share should enter sUSDM backing");
        assertEq(susdm.totalSupply(), supplyBefore, "yield distribution should not mint sUSDM shares");
        assertEq(_rate(), _expectedRate(susdm.totalAssets(), susdm.totalSupply()), "rate formula mismatch");
        assertGt(_rate(), rateBefore, "vault yield distribution should increase rate");
        assertEq(usdc.balanceOf(address(insurance)), insuranceShare, "insurance split mismatch");
        assertEq(usdc.balanceOf(foundation), foundationShare, "foundation split mismatch");
    }
}

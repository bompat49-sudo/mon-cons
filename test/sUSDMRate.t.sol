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

/// @title sUSDM Rate POC - reproduces testnet rate=1.265 scenario
contract sUSDMRateTest is Test {
    USDM usdm;
    sUSDM susdm;
    sUSDMEscrow unstakeEscrow;
    MonetrixConfig config;
    MonetrixAccessController acl;

    address admin = address(0xAD);
    address deployer = address(0xFcb74c854254868fD9fD4A31C9098725E4217Ad7);
    address user2 = address(0xd9301F2938BAaE83c408956976aDa0924A3F488B);
    address vaultMock = address(0xAA);

    function setUp() public {
        vm.startPrank(admin);

        MonetrixAccessController aclImpl = new MonetrixAccessController();
        ERC1967Proxy aclProxy =
            new ERC1967Proxy(address(aclImpl), abi.encodeCall(MonetrixAccessController.initialize, (admin)));
        acl = MonetrixAccessController(address(aclProxy));

        InsuranceFund insImpl = new InsuranceFund();
        ERC1967Proxy insProxy = new ERC1967Proxy(
            address(insImpl), abi.encodeCall(InsuranceFund.initialize, (address(1), address(acl)))
        );
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

    function _mintUsdm(address to, uint256 amount) internal {
        vm.prank(admin);
        usdm.mint(to, amount);
    }

    function _depositToSusdm(address user, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(user);
        usdm.approve(address(susdm), amount);
        shares = susdm.deposit(amount, user);
        vm.stopPrank();
    }

    function _injectYield(uint256 amount) internal {
        _mintUsdm(vaultMock, amount);
        vm.startPrank(vaultMock);
        usdm.approve(address(susdm), amount);
        susdm.injectYield(amount);
        vm.stopPrank();
    }

    function _getRate() internal view returns (uint256) {
        return susdm.convertToAssets(1e12);
    }

    /// @notice Reproduce exact testnet timeline:
    ///   1. deployer sUSDM.deposit(5 USDM)
    ///   2. deployer cooldownShares(2e12)
    ///   3. yield inject 0.796 USDM  <-- only 3 USDM backing, rate jumps to ~1.265
    ///   4. user2 sUSDM.deposit(18 USDM) at rate=1.265
    ///   5. user2 cooldownShares(1e12)
    function test_reproduce_testnet_rate() public {
        // === Step 1: deployer deposits 5 USDM into sUSDM ===
        _mintUsdm(deployer, 5e6);
        uint256 deployerShares = _depositToSusdm(deployer, 5e6);

        emit log_named_uint("Step 1 - deployer deposit 5 USDM", 0);
        emit log_named_uint("  shares", deployerShares);
        emit log_named_uint("  totalSupply", susdm.totalSupply());
        emit log_named_uint("  totalAssets", susdm.totalAssets());
        emit log_named_uint("  rate", _getRate());

        assertEq(deployerShares, 5e12, "deployer should get 5e12 shares");
        assertEq(_getRate(), 1e6, "rate should be 1.0");

        // === Step 2: deployer unstakes 2e12 shares ===
        vm.prank(deployer);
        uint256 reqId = susdm.cooldownShares(2e12);

        emit log_named_uint("Step 2 - deployer unstake 2e12", 0);
        emit log_named_uint("  totalSupply", susdm.totalSupply());
        emit log_named_uint("  totalAssets", susdm.totalAssets());
        emit log_named_uint("  totalPendingClaims", susdm.totalPendingClaims());
        emit log_named_uint("  rate", _getRate());

        assertEq(susdm.totalSupply(), 3e12, "supply should be 3e12");
        assertEq(susdm.totalAssets(), 3e6, "totalAssets should be 3 USDM");
        assertEq(_getRate(), 1e6, "rate should still be 1.0");

        // === Step 3: yield inject 0.796 USDM ===
        // KEY: only 3e12 shares / 3 USDM backing at this point
        // 0.796 / 3 = 26.5% rate increase
        _injectYield(795883);

        uint256 rateAfterYield = _getRate();
        emit log_named_uint("Step 3 - yield inject 0.796 USDM", 0);
        emit log_named_uint("  totalSupply", susdm.totalSupply());
        emit log_named_uint("  totalAssets", susdm.totalAssets());
        emit log_named_uint("  rate", rateAfterYield);

        assertEq(susdm.totalSupply(), 3e12, "supply unchanged");
        assertApproxEqAbs(rateAfterYield, 1265294, 1, "rate should be ~1.265294");

        // === Step 4: user2 deposits 18 USDM at rate=1.265 ===
        _mintUsdm(user2, 18e6);
        uint256 user2Shares = _depositToSusdm(user2, 18e6);

        emit log_named_uint("Step 4 - user2 deposit 18 USDM", 0);
        emit log_named_uint("  shares", user2Shares);
        emit log_named_uint("  totalSupply", susdm.totalSupply());
        emit log_named_uint("  totalAssets", susdm.totalAssets());
        emit log_named_uint("  rate", _getRate());

        // user2 gets fewer shares because rate > 1.0
        assertLt(user2Shares, 18e12, "user2 gets < 18e12 shares at rate > 1.0");
        assertApproxEqAbs(_getRate(), 1265294, 1, "rate should remain ~1.265");

        // === Step 5: user2 unstakes 1e12 shares ===
        vm.prank(user2);
        susdm.cooldownShares(1e12);

        emit log_named_uint("Step 5 - user2 unstake 1e12", 0);
        emit log_named_uint("  totalSupply", susdm.totalSupply());
        emit log_named_uint("  totalAssets", susdm.totalAssets());
        emit log_named_uint("  totalPendingClaims", susdm.totalPendingClaims());
        emit log_named_uint("  rate", _getRate());

        assertApproxEqAbs(_getRate(), 1265294, 1, "rate unchanged after unstake");

        // === Final state verification: match testnet ===
        emit log_named_uint("=== Final State ===", 0);
        emit log_named_uint("  totalSupply", susdm.totalSupply());
        emit log_named_uint("  totalAssets", susdm.totalAssets());
        emit log_named_uint("  USDM in sUSDM", usdm.balanceOf(address(susdm)));
        emit log_named_uint("  totalPendingClaims", susdm.totalPendingClaims());
        emit log_named_uint("  rate", _getRate());
        emit log_named_uint("  deployer shares", susdm.balanceOf(deployer));
        emit log_named_uint("  user2 shares", susdm.balanceOf(user2));

        // With physical isolation, solvency splits across two contracts:
        //   1) sUSDM holds USDM backing live shares only
        //   2) Escrow holds USDM backing outstanding unstake requests
        uint256 allSharesValue = susdm.convertToAssets(susdm.totalSupply());
        uint256 usdmInSusdm = usdm.balanceOf(address(susdm));
        uint256 usdmInEscrow = usdm.balanceOf(address(unstakeEscrow));
        uint256 pendingClaims = susdm.totalPendingClaims();
        assertApproxEqAbs(allSharesValue, usdmInSusdm, 1, "solvency: shares backed by sUSDM balance");
        assertEq(pendingClaims, usdmInEscrow, "solvency: pending claims backed 1:1 by escrow balance");
    }
}

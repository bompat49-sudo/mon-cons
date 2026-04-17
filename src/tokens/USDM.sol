// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {MonetrixGovernedUpgradeable} from "../governance/MonetrixGovernedUpgradeable.sol";

/// @title USDM - Monetrix Delta-Neutral Stablecoin
/// @notice 1:1 USDC-backed stablecoin, 6 decimals. Pure token, no business logic.
/// @dev `mint` / `burn` are restricted to VAULT_CALLER role — only MonetrixVault
///      can mint and burn. `pause` / `unpause` are held by GUARDIAN for instant response.
contract USDM is ERC20Upgradeable, PausableUpgradeable, MonetrixGovernedUpgradeable {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _acl) external initializer {
        __ERC20_init("Monetrix USD", "USDM");
        __Pausable_init();
        __Governed_init(_acl);
    }

    function mint(address to, uint256 amount) external onlyVaultCaller {
        _mint(to, amount);
    }

    /// @notice Burn USDM from the caller's own balance.
    /// @dev Vault.claimRedeem holds the USDM to be burned in its own balance
    ///      (transferred in during requestRedeem), so self-burn is sufficient.
    function burn(uint256 amount) external onlyVaultCaller {
        _burn(msg.sender, amount);
    }

    function pause() external onlyGuardian {
        _pause();
    }

    function unpause() external onlyGuardian {
        _unpause();
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function _update(address from, address to, uint256 value) internal override whenNotPaused {
        super._update(from, to, value);
    }

    uint256[50] private __gap;
}

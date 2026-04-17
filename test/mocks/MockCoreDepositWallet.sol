// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../src/interfaces/IHyperCore.sol";

/// @title MockCoreDepositWallet - Test mock for HyperCore L1 bridge
contract MockCoreDepositWallet is ICoreDepositWallet {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;

    constructor(address _token) {
        token = IERC20(_token);
    }

    function deposit(uint256 amount, uint32) external override {
        token.safeTransferFrom(msg.sender, address(this), amount);
    }

    function depositFor(address, uint256 amount, uint32) external override {
        token.safeTransferFrom(msg.sender, address(this), amount);
    }
}

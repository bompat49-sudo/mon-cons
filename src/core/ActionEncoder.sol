// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "../interfaces/IActionEncoder.sol";
import "../interfaces/HyperCoreConstants.sol";

/// @title ActionEncoder - Encodes HyperCore L1 actions for spot/perp trading
/// @notice Encodes per HyperCore wire format:
///   Action 1 (Order): (asset, isBuy, limitPx, sz, reduceOnly, encodedTif, cloid)
///                      (uint32, bool, uint64, uint64, bool, uint8, uint128)
///   encodedTif: 1=ALO, 2=GTC, 3=IOC
///   cloid: uint128, 0 means no cloid
///   limitPx and sz: 10^8 * human readable value
contract ActionEncoder is IActionEncoder {
    uint8 constant TIF_IOC = 3;
    uint8 constant TIF_GTC = 2;

    // Buy spot: IOC order, not reduce-only
    function encodeBuySpot(HedgeParams calldata p) external pure returns (bytes memory) {
        return abi.encodePacked(
            HyperCoreConstants.ACTION_VERSION,
            HyperCoreConstants.ACTION_LIMIT_ORDER,
            abi.encode(p.spotAsset, true, p.spotPrice, p.size, false, TIF_IOC, p.cloid)
        );
    }

    // Short perp: IOC order, not reduce-only
    function encodeShortPerp(HedgeParams calldata p) external pure returns (bytes memory) {
        return abi.encodePacked(
            HyperCoreConstants.ACTION_VERSION,
            HyperCoreConstants.ACTION_LIMIT_ORDER,
            abi.encode(p.perpAsset, false, p.perpPrice, p.size, false, TIF_IOC, p.cloid)
        );
    }

    // Sell spot: IOC order, not reduce-only
    function encodeSellSpot(CloseParams calldata p) external pure returns (bytes memory) {
        return abi.encodePacked(
            HyperCoreConstants.ACTION_VERSION,
            HyperCoreConstants.ACTION_LIMIT_ORDER,
            abi.encode(p.spotAsset, false, p.spotPrice, p.size, false, TIF_IOC, p.cloid)
        );
    }

    // Close perp: IOC order, reduce-only = true
    function encodeClosePerp(CloseParams calldata p) external pure returns (bytes memory) {
        return abi.encodePacked(
            HyperCoreConstants.ACTION_VERSION,
            HyperCoreConstants.ACTION_LIMIT_ORDER,
            abi.encode(p.perpAsset, true, p.perpPrice, p.size, true, TIF_IOC, p.cloid)
        );
    }

    // Repair: IOC order, reduce-only = true to prevent accidentally opening new positions
    function encodeRepairAction(RepairParams calldata p) external pure returns (bytes memory) {
        return abi.encodePacked(
            HyperCoreConstants.ACTION_VERSION,
            HyperCoreConstants.ACTION_LIMIT_ORDER,
            abi.encode(p.asset, p.isBuy, p.price, p.size, p.reduceOnly, TIF_IOC, p.cloid)
        );
    }

    /// @notice EVM USDC uses 6 decimals; HyperCore L1 amounts use 8 decimals.
    /// @dev Multiply by EVM_TO_L1_PRECISION (100) to convert before encoding.
    function encodeSpotSend(address destination, uint64 token, uint64 amount) external pure returns (bytes memory) {
        uint64 l1Amount = amount * uint64(HyperCoreConstants.EVM_TO_L1_PRECISION);
        return abi.encodePacked(
            HyperCoreConstants.ACTION_VERSION,
            HyperCoreConstants.ACTION_SPOT_SEND,
            abi.encode(destination, token, l1Amount)
        );
    }

    /// @notice Deposit USD into a HyperCore vault (e.g. HLP)
    /// @dev Amount is in 6-decimal perp units (NOT 8-decimal L1 wei). 10 USDC = 10_000_000.
    function encodeVaultDeposit(address vault, uint64 usdAmount) external pure returns (bytes memory) {
        return abi.encodePacked(
            HyperCoreConstants.ACTION_VERSION,
            HyperCoreConstants.ACTION_VAULT_TRANSFER,
            abi.encode(vault, true, usdAmount)
        );
    }

    /// @notice Withdraw USD from a HyperCore vault (e.g. HLP)
    /// @dev Amount is in 6-decimal perp units. Subject to vault lock period (HLP = 4 days).
    function encodeVaultWithdraw(address vault, uint64 usdAmount) external pure returns (bytes memory) {
        return abi.encodePacked(
            HyperCoreConstants.ACTION_VERSION,
            HyperCoreConstants.ACTION_VAULT_TRANSFER,
            abi.encode(vault, false, usdAmount)
        );
    }
}

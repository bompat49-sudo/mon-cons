// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

struct HedgeParams {
    uint32 spotAsset;
    uint32 perpAsset;
    uint64 size; // 10^8 * human readable
    uint64 spotPrice; // 10^8 * human readable
    uint64 perpPrice; // 10^8 * human readable
    uint128 cloid; // 0 = no cloid
}

struct CloseParams {
    uint256 positionId;
    uint32 spotAsset;
    uint32 perpAsset;
    uint64 size;
    uint64 spotPrice;
    uint64 perpPrice;
    uint128 cloid;
}

struct RepairParams {
    uint32 asset;
    bool isPerp; // true = repairing perp leg, false = repairing spot leg
    bool isBuy;
    bool reduceOnly; // true = close (undo failed hedge), false = open (complete failed hedge)
    uint64 size;
    uint64 price;
    uint16 residualBps;
    uint128 cloid;
}

interface IActionEncoder {
    function encodeBuySpot(HedgeParams calldata params) external pure returns (bytes memory);
    function encodeShortPerp(HedgeParams calldata params) external pure returns (bytes memory);
    function encodeSellSpot(CloseParams calldata params) external pure returns (bytes memory);
    function encodeClosePerp(CloseParams calldata params) external pure returns (bytes memory);
    function encodeRepairAction(RepairParams calldata params) external pure returns (bytes memory);
    function encodeSpotSend(address destination, uint64 token, uint64 amount) external pure returns (bytes memory);
    function encodeVaultDeposit(address vault, uint64 usdAmount) external pure returns (bytes memory);
    function encodeVaultWithdraw(address vault, uint64 usdAmount) external pure returns (bytes memory);
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

/// @title IMonetrixAccountant
/// @notice Minimal interface for peg defense and daily PnL recording.
/// The accountant holds no tokens and no operational counters — it only
/// provides real-time peg checks, snapshot adjustments, and surplus reads.
interface IMonetrixAccountant {
    function settleDailyPnL() external returns (int256 currentSurplus);
    function notifyRouteYield(uint256 amount) external;
    function surplus() external view returns (int256);
}

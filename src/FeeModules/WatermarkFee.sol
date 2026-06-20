// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPerfFeeModule} from "./IPerfFeeModule.sol";

/// @title WatermarkFee
/// @notice Calculates a high-watermark performance fee: the fee is charged only on the price gain
///         above the highest share price previously seen for the calling fund.
/// @dev    Watermark state is keyed by `msg.sender` (the calling KpkShares proxy), so:
///         - a single deployment can safely serve many funds without cross-contaminating watermarks;
///         - a direct, unauthorized caller can only mutate its OWN slot and cannot grief any fund's
///           watermark (each fund's slot is keyed by its own address).
///         The first call for a fund SEEDS the watermark at the observed price and charges nothing,
///         so the fund's starting NAV is never mistaken for profit. `timeElapsed` is part of the
///         IPerfFeeModule interface but does not affect the (purely price-based) fee math; it is
///         retained only for event transparency.
contract WatermarkFee is IPerfFeeModule {
    /// @notice Highest share price seen per calling fund (keyed by `msg.sender`).
    mapping(address => uint256) public highWatermark;

    /// @notice Emitted when a fund's high watermark changes (including the initial seeding).
    /// @param fund         The calling fund (msg.sender).
    /// @param oldWatermark The previous watermark value.
    /// @param newWatermark The new watermark value.
    event WatermarkUpdated(address indexed fund, uint256 oldWatermark, uint256 newWatermark);

    /// @notice Emitted whenever a performance fee is calculated.
    /// @param fund        The calling fund (msg.sender).
    /// @param fee         The calculated performance fee amount in shares.
    /// @param sharesPrice The current price per share in normalized USD units (8 decimals).
    /// @param timeElapsed The time elapsed since last calculation (informational only).
    event PerformanceFeeCalculated(address indexed fund, uint256 fee, uint256 sharesPrice, uint256 timeElapsed);

    /// @notice Calculates the performance fee for the IPerfFeeModule interface.
    /// @param sharesPrice The current price per share in normalized USD units (8 decimals, i.e., _NORMALIZED_PRECISION_USD)
    /// @param timeElapsed The time elapsed since last calculation (informational only; not used in the fee math)
    /// @param feePct The performance fee percentage in basis points
    /// @param netSupply The net supply of shares (totalSupply - feeReceiverBalance), used as the base for fee calculations
    /// @return fee The performance fee amount in shares
    function calculatePerformanceFee(uint256 sharesPrice, uint256 timeElapsed, uint256 feePct, uint256 netSupply)
        external
        returns (uint256 fee)
    {
        uint256 previousWatermark = highWatermark[msg.sender];

        // First observation for this fund: seed the baseline at the current price and charge nothing,
        // so the fund's starting NAV is never treated as profit.
        if (previousWatermark == 0) {
            highWatermark[msg.sender] = sharesPrice;
            emit WatermarkUpdated(msg.sender, 0, sharesPrice);
            emit PerformanceFeeCalculated(msg.sender, 0, sharesPrice, timeElapsed);
            return 0;
        }

        // No new high → no fee, watermark unchanged.
        if (sharesPrice <= previousWatermark) {
            return 0;
        }

        // New high watermark for this fund.
        highWatermark[msg.sender] = sharesPrice;
        emit WatermarkUpdated(msg.sender, previousWatermark, sharesPrice);

        // Charge the fee only on the gain above the previous watermark, across net supply.
        uint256 profitPerShare = sharesPrice - previousWatermark;
        uint256 totalProfit = (profitPerShare * netSupply) / sharesPrice;
        fee = (totalProfit * feePct) / 10_000;

        emit PerformanceFeeCalculated(msg.sender, fee, sharesPrice, timeElapsed);
    }
}

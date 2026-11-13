// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PeriodicWatermarkFee} from "./PeriodicWatermarkFee.sol";

/// @title HurdleFee
/// @notice Shared hurdle for `HardHurdleFee`, `SoftHurdleFee` and `CatchUpHurdleFee`: no fee is due until the
///         price clears the watermark grown by `hurdleBps` a year.
/// @dev    The hurdle is simple interest from the moment the watermark last moved, so it keeps growing while
///         the fund is below it, and compounds only through new watermarks. Two years under water at a 5%
///         hurdle need +10%, not +10.25%.
///
///         With period 0, a fund that keeps rising is charged at every settlement, so each hurdle is measured
///         over the few hours since the previous charge. The hard hurdle still leaves investors the hurdle
///         return over time; the soft and catch-up hurdles are cleared by almost any gain over so short a
///         window, so they only bite with a period such as a year.
abstract contract HurdleFee is PeriodicWatermarkFee {
    uint256 private constant YEAR = 365 days;

    /// @notice Annual hurdle rate in basis points.
    uint256 public immutable hurdleBps;

    /// @param hurdleBps_             Annual hurdle rate in basis points.
    /// @param crystallizationPeriod_ Minimum time between two charges, in seconds; 0 for every call.
    constructor(uint256 hurdleBps_, uint256 crystallizationPeriod_) PeriodicWatermarkFee(crystallizationPeriod_) {
        hurdleBps = hurdleBps_;
    }

    /// @dev The watermark grown by the hurdle over `elapsed` seconds, rounded up in investors' favour.
    function _hurdle(uint256 watermark, uint256 elapsed) internal view returns (uint256) {
        return watermark + Math.mulDiv(watermark, hurdleBps * elapsed, 10_000 * YEAR, Math.Rounding.Ceil);
    }
}

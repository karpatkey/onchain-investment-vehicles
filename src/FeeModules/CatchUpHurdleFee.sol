// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HurdleFee} from "./HurdleFee.sol";

/// @title CatchUpHurdleFee
/// @notice Soft hurdle with a catch-up: above the hurdle, the fee takes `catchUpBps` of each further gain
///         until it reaches `feePct` of the whole gain above the watermark, and stays at that rate after.
///         With `catchUpBps` = 10_000 (full catch-up) the fee is `min(gain above hurdle, feePct * whole gain)`.
/// @dev    The catch-up is measured per charge, from the watermark the previous charge left, not over the
///         fund's life as in a private-equity waterfall.
contract CatchUpHurdleFee is HurdleFee {
    /// @notice Share of the gain above the hurdle taken during the catch-up, in basis points.
    uint256 public immutable catchUpBps;

    error InvalidCatchUp();

    /// @param hurdleBps_             Annual hurdle rate in basis points.
    /// @param catchUpBps_            Catch-up share in basis points, 1 to 10_000.
    /// @param crystallizationPeriod_ Minimum time between two charges, in seconds; 0 for every call.
    constructor(uint256 hurdleBps_, uint256 catchUpBps_, uint256 crystallizationPeriod_)
        HurdleFee(hurdleBps_, crystallizationPeriod_)
    {
        if (catchUpBps_ == 0 || catchUpBps_ > 10_000) revert InvalidCatchUp();
        catchUpBps = catchUpBps_;
    }

    /// @dev Catch-up share of the gain above the hurdle, capped at `feePct` of the whole gain.
    function _crystallizeDue(uint256 sharesPrice, uint256 watermark, uint256 feePct, uint256 netSupply, uint256 elapsed)
        internal
        view
        override
        returns (uint256 fee, uint256 newWatermark)
    {
        uint256 hurdle = _hurdle(watermark, elapsed);
        if (sharesPrice <= hurdle) return (0, watermark);
        uint256 scaledFee = Math.min((sharesPrice - hurdle) * catchUpBps, (sharesPrice - watermark) * feePct);
        return _sizeExact(sharesPrice, scaledFee, netSupply);
    }
}

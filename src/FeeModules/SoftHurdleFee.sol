// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {HurdleFee} from "./HurdleFee.sol";

/// @title SoftHurdleFee
/// @notice Soft hurdle: nothing is due until the price clears the hurdle, and then the fee is `feePct` of the
///         whole gain above the watermark. The fee jumps at the hurdle: a price just below it owes nothing, a
///         price just above it owes the full rate on everything. `CatchUpHurdleFee` smooths that jump.
contract SoftHurdleFee is HurdleFee {
    /// @param hurdleBps_             Annual hurdle rate in basis points.
    /// @param crystallizationPeriod_ Minimum time between two charges, in seconds; 0 for every call.
    constructor(uint256 hurdleBps_, uint256 crystallizationPeriod_) HurdleFee(hurdleBps_, crystallizationPeriod_) {}

    /// @dev Charges `feePct` of the whole gain above the watermark once the hurdle is cleared.
    function _crystallizeDue(uint256 sharesPrice, uint256 watermark, uint256 feePct, uint256 netSupply, uint256 elapsed)
        internal
        view
        override
        returns (uint256 fee, uint256 newWatermark)
    {
        if (sharesPrice <= _hurdle(watermark, elapsed)) return (0, watermark);
        return _sizeExact(sharesPrice, (sharesPrice - watermark) * feePct, netSupply);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {HurdleFee} from "./HurdleFee.sol";

/// @title HardHurdleFee
/// @notice Hard hurdle: the fee is `feePct` of the gain above the hurdle only. Investors keep the hurdle
///         return fee-free whatever the fund earns.
contract HardHurdleFee is HurdleFee {
    /// @param hurdleBps_             Annual hurdle rate in basis points.
    /// @param crystallizationPeriod_ Minimum time between two charges, in seconds; 0 for every call.
    constructor(uint256 hurdleBps_, uint256 crystallizationPeriod_) HurdleFee(hurdleBps_, crystallizationPeriod_) {}

    /// @dev Charges `feePct` of the gain above the hurdle.
    function _crystallizeDue(uint256 sharesPrice, uint256 watermark, uint256 feePct, uint256 netSupply, uint256 elapsed)
        internal
        view
        override
        returns (uint256 fee, uint256 newWatermark)
    {
        uint256 hurdle = _hurdle(watermark, elapsed);
        if (sharesPrice <= hurdle) return (0, watermark);
        return _sizeExact(sharesPrice, (sharesPrice - hurdle) * feePct, netSupply);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PeriodicWatermarkFee} from "./PeriodicWatermarkFee.sol";

/// @title NoWatermarkFee
/// @notice No loss carry-forward: each charge is `feePct` of the gain since the previous reference price,
///         and a fall resets the reference down to the lower price. `highWatermark` therefore holds the last
///         reference price, not a high.
/// @dev    Investors pay again on recovering their own losses: a fall from 1.00 to 0.90 followed by a return
///         to 1.00 is charged on the 0.10, which a watermark module would not charge. With a period of 0
///         every up-move between settlements is charged and every down-move forgiven, so a fund that ends
///         flat after swinging still pays. Not a standard investor-protective structure; kept for comparison.
contract NoWatermarkFee is PeriodicWatermarkFee {
    /// @param crystallizationPeriod_ Minimum time between two charges, in seconds; 0 for every call.
    constructor(uint256 crystallizationPeriod_) PeriodicWatermarkFee(crystallizationPeriod_) {}

    /// @dev Charges any gain over the reference; resets the reference on a fall.
    function _crystallizeDue(uint256 sharesPrice, uint256 watermark, uint256 feePct, uint256 netSupply, uint256)
        internal
        view
        override
        returns (uint256 fee, uint256 newWatermark)
    {
        if (sharesPrice <= watermark) return (0, sharesPrice);
        return _sizeExact(sharesPrice, (sharesPrice - watermark) * feePct, netSupply);
    }
}

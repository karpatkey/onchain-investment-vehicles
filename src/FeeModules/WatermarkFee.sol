// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {WatermarkFeeBase} from "./WatermarkFeeBase.sol";

/// @title WatermarkFee
/// @notice High-watermark performance fee, gross convention: the watermark moves to the pre-fee price,
///         and the fee shares are sized at that price with no adjustment for their own dilution.
/// @dev    Collects less than `feePct` of investors' gains, for two reasons. Minting the fee drops the
///         share price below the stored watermark, so the next rise back up to it is fee-free. And shares
///         sized at the pre-mint price are worth less once minted, a shortfall that grows with the fee
///         receiver's own holding, which the mint also dilutes. Simulated with a 20% rate, gains of
///         0.03%-5% per crystallization: effective 16.7% if the receiver redeems its fee shares each time,
///         14.0-15.6% if it holds them (2026-11-04). `PostFeeWatermarkFee` and `ExactWatermarkFee` are
///         the alternatives.
contract WatermarkFee is WatermarkFeeBase {
    /// @inheritdoc WatermarkFeeBase
    function _crystallize(uint256 sharesPrice, uint256 watermark, uint256 feePct, uint256 netSupply)
        internal
        view
        virtual
        override
        returns (uint256 fee, uint256 newWatermark)
    {
        if (sharesPrice <= watermark) return (0, watermark);
        uint256 totalProfit = ((sharesPrice - watermark) * netSupply) / sharesPrice;
        fee = (totalProfit * feePct) / 10_000;
        newWatermark = sharesPrice;
    }
}

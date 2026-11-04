// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WatermarkFee} from "./WatermarkFee.sol";

/// @title PostFeeWatermarkFee
/// @notice High-watermark performance fee that moves the watermark to the post-fee share price, so no part
///         of a later gain is fee-free. Fee shares are sized exactly as in `WatermarkFee`.
/// @dev    That sizing still dilutes the fee receiver's existing shares, so collection falls short of
///         `feePct` in proportion to the receiver's holding. Simulated with a 20% rate, gains of 0.03%-5%
///         per crystallization: effective 19.8-20.0% if the receiver redeems its fee shares each time,
///         15.8-18.2% if it holds them (2026-11-04).
///
///         Reads `totalSupply()` from the caller, so the caller must be an ERC-20 (KpkShares is).
///         Assumes `sharesPrice` is NAV / totalSupply() at call time. KpkShares mints the management fee
///         before calling, so a price struck before that mint leaves the watermark above the true post-fee
///         price by about the management fee's share of supply, in investors' favour.
contract PostFeeWatermarkFee is WatermarkFee {
    /// @inheritdoc WatermarkFee
    function _crystallize(uint256 sharesPrice, uint256 watermark, uint256 feePct, uint256 netSupply)
        internal
        view
        override
        returns (uint256 fee, uint256 newWatermark)
    {
        (fee, newWatermark) = super._crystallize(sharesPrice, watermark, feePct, netSupply);
        // Nothing minted, so the price is unchanged and `newWatermark` is already `sharesPrice`.
        if (fee == 0) return (fee, newWatermark);
        uint256 supply = IERC20(msg.sender).totalSupply();
        // Rounded up, in investors' favour: a unit high defers a fee, a unit low charges a phantom gain.
        newWatermark = Math.mulDiv(sharesPrice, supply, supply + fee, Math.Rounding.Ceil);
    }
}

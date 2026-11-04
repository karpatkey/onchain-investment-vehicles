// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WatermarkFeeBase} from "./WatermarkFeeBase.sol";

/// @title ExactWatermarkFee
/// @notice High-watermark performance fee that charges investors `feePct` of their gain above the watermark,
///         to within one price unit of rounding (pinned: test/WatermarkFeeVariants.t.sol::testFuzz_exact_eachShareGivesUpFeePctOfGain).
/// @dev    With price P, watermark W and total supply S, the per-share fee is a = feePct * (P - W) / 10_000.
///         Minting f = a * S / (P - a) shares leaves every share worth P - a: each investor share gives up
///         `a`, and the receiver's existing shares give up `a` too, so the receiver nets a * netSupply and
///         pays no fee on its own holding (pinned: test/WatermarkFeeVariants.t.sol::test_exact_investorsPayConfiguredRate_whileReceiverHoldsShares).
///         The watermark moves to P - a, the post-fee price, so no part of a later gain is fee-free.
///
///         Reads `totalSupply()` from the caller, so the caller must be an ERC-20 (KpkShares is).
///         Assumes `sharesPrice` is NAV / totalSupply() at call time. KpkShares mints the management fee
///         before calling, so a price struck before that mint leaves the watermark above the true post-fee
///         price by about the management fee's share of supply, in investors' favour.
contract ExactWatermarkFee is WatermarkFeeBase {
    /// @inheritdoc WatermarkFeeBase
    function _crystallize(uint256 sharesPrice, uint256 watermark, uint256 feePct, uint256 netSupply)
        internal
        view
        virtual
        override
        returns (uint256 fee, uint256 newWatermark)
    {
        if (sharesPrice <= watermark) return (0, watermark);
        return _sizeExact(sharesPrice, (sharesPrice - watermark) * feePct, netSupply);
    }

    /// @dev Exact sizing, shared with the modules built on this one: mints the shares that take
    ///      `scaledFee / 10_000` price units from every share, and returns the resulting post-fee price as
    ///      the new watermark. Requires `scaledFee < sharesPrice * 10_000`, which holds whenever the per-share
    ///      fee is at most `feePct` (<= 10_000) of a gain that is itself below `sharesPrice`.
    /// @param sharesPrice The current price per share (8 decimals).
    /// @param scaledFee   The per-share fee in price units, times 10_000.
    /// @param netSupply   totalSupply minus the fee receiver's balance.
    function _sizeExact(uint256 sharesPrice, uint256 scaledFee, uint256 netSupply)
        internal
        view
        returns (uint256 fee, uint256 newWatermark)
    {
        // No investor shares: nothing to charge, and minting would only dilute the receiver against itself.
        if (netSupply == 0) return (0, sharesPrice);
        uint256 supply = IERC20(msg.sender).totalSupply();
        fee = Math.mulDiv(scaledFee, supply, sharesPrice * 10_000 - scaledFee);
        // Flooring `a` rounds the watermark up, in investors' favour.
        newWatermark = fee == 0 ? sharesPrice : sharesPrice - scaledFee / 10_000;
    }
}

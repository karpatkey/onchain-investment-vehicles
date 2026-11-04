// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ExactWatermarkFee} from "./ExactWatermarkFee.sol";

/// @title PeriodicWatermarkFee
/// @notice `ExactWatermarkFee` that charges at most once per `crystallizationPeriod`: a call before the
///         period has run since the watermark last moved changes nothing, and the first call after it
///         charges on whatever gain is above the watermark at that moment. A period of 0 charges at every
///         call, like `ExactWatermarkFee`. Also the base for the hurdle, benchmark and no-watermark
///         modules, which take the same period.
/// @dev    Nothing accrues between charges. KpkShares prices subscriptions and redemptions at the operator's
///         price, which carries no pending performance fee, so an investor who redeems mid-period pays none
///         of that period's fee and one who subscribes mid-period pays it on gains made before they joined.
///         The longer the period, the larger both effects.
///
///         The period is rolling: it restarts whenever the watermark moves (a charge, the first seed, a fee that
///         rounds to 0, or `NoWatermarkFee`'s reset on a fall), so charges do not fall on fixed calendar dates.
///
///         With a period, a charge uses the lowest rate passed in since the period began, counting from the first
///         call after the watermark last moved. So a raise reaches no gain made under a lower rate in the same
///         period, and a cut applies to the period it lands in. The call that moves the watermark is left out
///         because KpkShares' rate-change call passes the outgoing rate: when it charges a due period, the next
///         period still runs at the new rate. KpkShares charges at the old rate just before a change, but
///         mid-period that call is a no-op here (pinned: test/WatermarkFeeVariants.t.sol::test_periodic_rateRaisedMidPeriod_chargesTheOldRate,
///         test/FeeStructures.t.sol::test_periodic_cutThenRaiseChargesTheLowestRate,
///         test/FeeStructures.t.sol::test_periodic_raiseWhenTheRateChangeCallChargesAppliesNextPeriod).
///         With a period of 0 every charge uses the rate passed in, as in `ExactWatermarkFee`.
contract PeriodicWatermarkFee is ExactWatermarkFee {
    /// @notice Minimum time between two charges for the same fund, in seconds.
    uint256 public immutable crystallizationPeriod;

    /// @notice When each fund's watermark was last seeded or moved.
    mapping(address => uint256) public watermarkSetAt;

    /// @notice Lowest fee rate passed in since each fund's period began, in basis points; 0 until the first call
    ///         after the watermark moves.
    mapping(address => uint256) public periodRate;

    /// @param crystallizationPeriod_ Minimum time between two charges, in seconds; 0 for every call.
    constructor(uint256 crystallizationPeriod_) {
        crystallizationPeriod = crystallizationPeriod_;
    }

    /// @inheritdoc ExactWatermarkFee
    function _crystallize(uint256 sharesPrice, uint256 watermark, uint256 feePct, uint256 netSupply)
        internal
        override
        returns (uint256 fee, uint256 newWatermark)
    {
        uint256 elapsed = block.timestamp - watermarkSetAt[msg.sender];
        uint256 rate = feePct;
        if (crystallizationPeriod != 0) {
            uint256 lowest = periodRate[msg.sender];
            if (lowest != 0 && lowest < rate) rate = lowest;
            if (rate != lowest) periodRate[msg.sender] = rate;
            if (elapsed < crystallizationPeriod) return (0, watermark);
        }
        return _crystallizeDue(sharesPrice, watermark, rate, netSupply, elapsed);
    }

    /// @dev `_crystallize` once the period has run, with the seconds since the watermark was last seeded or
    ///      moved as the last argument. Defaults to the plain high watermark, which ignores it.
    function _crystallizeDue(uint256 sharesPrice, uint256 watermark, uint256 feePct, uint256 netSupply, uint256)
        internal
        virtual
        returns (uint256 fee, uint256 newWatermark)
    {
        return ExactWatermarkFee._crystallize(sharesPrice, watermark, feePct, netSupply);
    }

    /// @dev Starts the period, and the hurdle clock, from every new watermark, and restarts the rate record.
    function _afterWatermarkSet(uint256) internal virtual override {
        watermarkSetAt[msg.sender] = block.timestamp;
        delete periodRate[msg.sender];
    }
}

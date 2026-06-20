// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {WatermarkFee} from "src/FeeModules/WatermarkFee.sol";

/// @notice Unit tests for the WatermarkFee performance-fee module, covering the audit fixes:
///         seed-on-first-use (no fee on the starting NAV), per-fund (msg.sender-keyed) isolation,
///         and that a direct unauthorized caller cannot grief a fund's watermark.
contract WatermarkFeeTest is Test {
    WatermarkFee fee;

    uint256 constant PRICE = 1e8; // 1.00 in 8-decimal USD
    uint256 constant FEE_PCT = 2000; // 20%
    uint256 constant NET_SUPPLY = 1_000_000e18;

    address fund = makeAddr("fund");
    address otherFund = makeAddr("otherFund");
    address attacker = makeAddr("attacker");

    function setUp() public {
        fee = new WatermarkFee();
    }

    // ── High: first settlement seeds the watermark and charges nothing ──────────────

    function test_firstSettlement_chargesZeroAndSeeds() public {
        vm.prank(fund);
        uint256 f = fee.calculatePerformanceFee(PRICE, 1 days, FEE_PCT, NET_SUPPLY);
        assertEq(f, 0, "first accrual must charge nothing");
        assertEq(fee.highWatermark(fund), PRICE, "watermark seeded at first observed price");
    }

    function test_noFeeWhenPriceFlatOrDown() public {
        vm.startPrank(fund);
        fee.calculatePerformanceFee(PRICE, 1 days, FEE_PCT, NET_SUPPLY); // seed at 1.00
        assertEq(fee.calculatePerformanceFee(PRICE, 1 days, FEE_PCT, NET_SUPPLY), 0, "flat price = no fee");
        assertEq(fee.calculatePerformanceFee(PRICE / 2, 1 days, FEE_PCT, NET_SUPPLY), 0, "lower price = no fee");
        assertEq(fee.highWatermark(fund), PRICE, "watermark does not drop");
        vm.stopPrank();
    }

    // ── Fee is charged only on the gain above the seeded baseline ───────────────────

    function test_feeChargedOnlyOnGainAboveWatermark() public {
        vm.startPrank(fund);
        fee.calculatePerformanceFee(PRICE, 1 days, FEE_PCT, NET_SUPPLY); // seed at 1.00, no fee

        uint256 newPrice = 2 * PRICE; // +100%
        uint256 f = fee.calculatePerformanceFee(newPrice, 1 days, FEE_PCT, NET_SUPPLY);
        vm.stopPrank();

        // profitPerShare/price = (2-1)/2 = 1/2 of net supply is "profit"; 20% of that = 10% of supply
        uint256 expected = (((newPrice - PRICE) * NET_SUPPLY) / newPrice) * FEE_PCT / 10_000;
        assertEq(f, expected, "fee on the gain above watermark");
        assertEq(fee.highWatermark(fund), newPrice, "watermark ratchets up");
    }

    // ── Medium: a direct attacker call cannot affect a fund's watermark ─────────────

    function test_attackerCannotGriefFundWatermark() public {
        // Attacker ratchets their OWN slot to the max.
        vm.prank(attacker);
        fee.calculatePerformanceFee(type(uint256).max, 1 days, FEE_PCT, NET_SUPPLY);
        assertEq(fee.highWatermark(attacker), type(uint256).max, "attacker only moved their own slot");
        assertEq(fee.highWatermark(fund), 0, "fund slot untouched by attacker");

        // The fund still works normally and accrues fees on real gains.
        vm.startPrank(fund);
        fee.calculatePerformanceFee(PRICE, 1 days, FEE_PCT, NET_SUPPLY); // seed
        uint256 f = fee.calculatePerformanceFee(2 * PRICE, 1 days, FEE_PCT, NET_SUPPLY);
        vm.stopPrank();
        assertGt(f, 0, "fund accrues fees despite attacker's direct call");
    }

    // ── Low: two funds sharing one instance are isolated ────────────────────────────

    function test_perFundIsolation() public {
        vm.prank(fund);
        fee.calculatePerformanceFee(PRICE, 1 days, FEE_PCT, NET_SUPPLY); // fund seeds at 1.00

        vm.prank(otherFund);
        fee.calculatePerformanceFee(5 * PRICE, 1 days, FEE_PCT, NET_SUPPLY); // otherFund seeds at 5.00

        assertEq(fee.highWatermark(fund), PRICE, "fund watermark independent");
        assertEq(fee.highWatermark(otherFund), 5 * PRICE, "otherFund watermark independent");

        // otherFund's high price does not suppress fund's legitimate fee on its own gain.
        vm.prank(fund);
        uint256 f = fee.calculatePerformanceFee(2 * PRICE, 1 days, FEE_PCT, NET_SUPPLY);
        assertGt(f, 0, "fund charges its own fee regardless of otherFund's watermark");
    }
}

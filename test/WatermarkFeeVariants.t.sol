// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {kpkSharesTestBase} from "test/kpkShares.TestBase.sol";
import {KpkShares} from "src/kpkShares.sol";
import {IPerfFeeModule} from "src/FeeModules/IPerfFeeModule.sol";
import {WatermarkFeeBase} from "src/FeeModules/WatermarkFeeBase.sol";
import {WatermarkFee} from "src/FeeModules/WatermarkFee.sol";
import {PostFeeWatermarkFee} from "src/FeeModules/PostFeeWatermarkFee.sol";
import {ExactWatermarkFee} from "src/FeeModules/ExactWatermarkFee.sol";
import {HardHurdleFee} from "src/FeeModules/HardHurdleFee.sol";

/// @notice The watermark fee variants, driven through KpkShares with honest pricing: every settlement
///         reports NAV / totalSupply(), so a fee minted at one settlement shows up as a lower price at
///         the next. NAV is tracked in 1e18 USD and starts equal to supply (price 1.00).
contract WatermarkFeeVariantsTest is kpkSharesTestBase {
    uint256 constant RATE = 2000; // 20%
    address fund = makeAddr("fund");

    function _fund(IPerfFeeModule module) internal returns (KpkShares k) {
        perfFeeModule = module;
        k = _deployKpkSharesWithFees(0, 0, RATE);
        _createSharesForTestingWithContract(k, alice, _sharesAmount(1000));
    }

    function _priceAt(KpkShares k, uint256 nav) internal view returns (uint256) {
        return nav * 1e8 / k.totalSupply();
    }

    function _settle(KpkShares k, uint256 nav) internal {
        skip(7 hours);
        uint256 price = _priceAt(k, nav);
        vm.prank(ops);
        k.processRequests(new uint256[](0), new uint256[](0), address(usdc), price);
    }

    function _value(KpkShares k, address who, uint256 nav) internal view returns (uint256) {
        return k.balanceOf(who) * nav / k.totalSupply();
    }

    // ── Exact: investors pay the configured rate, the receiver's own holding pays nothing ───────────

    function test_exact_investorsPayConfiguredRate_whileReceiverHoldsShares() public {
        KpkShares k = _fund(new ExactWatermarkFee());
        _createSharesForTestingWithContract(k, feeRecipient, _sharesAmount(500));
        uint256 nav = k.totalSupply();
        _settle(k, nav); // seed at 1.00
        uint256 aliceBefore = _value(k, alice, nav);

        nav = nav * 12 / 10;
        _settle(k, nav); // +20%

        uint256 gain = aliceBefore * 2 / 10;
        uint256 expected = aliceBefore + gain - gain * RATE / 10_000;
        assertApproxEqRel(_value(k, alice, nav), expected, 1e10, "alice keeps exactly 80% of her gain");
    }

    function test_hardHurdle_investorsKeepTheHurdleAndPayOnTheExcess() public {
        KpkShares k = _fund(new HardHurdleFee(1000, 0)); // 10% a year
        uint256 nav = k.totalSupply();
        _settle(k, nav); // seed at 1.00
        uint256 aliceBefore = _value(k, alice, nav);

        skip(365 days - 7 hours); // `_settle` adds the last 7 hours: a year after the seed
        nav = nav * 12 / 10;
        _settle(k, nav);

        // 10% kept fee-free, then 80% of the other 10%.
        assertApproxEqRel(_value(k, alice, nav), aliceBefore * 118 / 100, 1e10, "hurdle plus 80% of the excess");
    }

    function testFuzz_exact_eachShareGivesUpFeePctOfGain(
        uint256 supply,
        uint256 netSupply,
        uint256 gainBps,
        uint256 feePct
    ) public {
        supply = bound(supply, 1e18, 1e30);
        netSupply = bound(netSupply, 1, supply);
        gainBps = bound(gainBps, 1, 3000); // KpkShares' MAX_PRICE_DEVIATION_BPS
        feePct = bound(feePct, 1, 2000); // KpkShares' MAX_FEE_RATE
        ExactWatermarkFee module = new ExactWatermarkFee();
        vm.mockCall(fund, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(supply));

        uint256 price = 1e8 * (10_000 + gainBps) / 10_000;
        vm.startPrank(fund);
        module.calculatePerformanceFee(1e8, 0, feePct, netSupply);
        uint256 fee = module.calculatePerformanceFee(price, 0, feePct, netSupply);
        vm.stopPrank();

        uint256 postFeePrice = price * supply / (supply + fee);
        assertApproxEqAbs(price - postFeePrice, (price - 1e8) * feePct / 10_000, 1, "per-share fee");
        assertLe(postFeePrice, module.highWatermark(fund), "unchanged NAV is not a new high");
    }

    // ── Post-fee watermark: a rise from the post-fee price is charged ──────────────────────────────

    function test_postFeeVariants_chargeRiseThatStaysBelowPreviousPreFeePrice() public {
        IPerfFeeModule[2] memory modules =
            [IPerfFeeModule(new PostFeeWatermarkFee()), IPerfFeeModule(new ExactWatermarkFee())];
        for (uint256 i; i < modules.length; i++) {
            KpkShares k = _fund(modules[i]);
            uint256 nav = k.totalSupply();
            _settle(k, nav); // seed at 1.00
            nav = nav * 12 / 10;
            _settle(k, nav); // fee charged at a pre-fee price of 1.20

            nav = nav * 102 / 100;
            assertLt(_priceAt(k, nav), 1.2e8, "still below the previous pre-fee price");
            uint256 before = k.balanceOf(feeRecipient);
            _settle(k, nav);
            assertGt(k.balanceOf(feeRecipient), before, "the +2% NAV gain is charged");
        }
    }

    function test_allVariants_noFeeWhenNavUnchangedAfterAFee() public {
        IPerfFeeModule[3] memory modules = [
            IPerfFeeModule(new WatermarkFee()),
            IPerfFeeModule(new PostFeeWatermarkFee()),
            IPerfFeeModule(new ExactWatermarkFee())
        ];
        for (uint256 i; i < modules.length; i++) {
            KpkShares k = _fund(modules[i]);
            uint256 nav = k.totalSupply();
            _settle(k, nav);
            nav = nav * 12 / 10;
            _settle(k, nav);
            uint256 charged = k.balanceOf(feeRecipient);
            assertGt(charged, 0, "a fee was charged");

            _settle(k, nav); // same NAV, priced over the post-fee supply
            assertEq(k.balanceOf(feeRecipient), charged, "no fee without a gain");
        }
    }

    // ── An emptied fund must not revert settlement ─────────────────────────────────────────────────

    function test_postFeeVariants_zeroSupplyChargesNothing() public {
        IPerfFeeModule[2] memory modules =
            [IPerfFeeModule(new PostFeeWatermarkFee()), IPerfFeeModule(new ExactWatermarkFee())];
        vm.mockCall(fund, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(uint256(0)));
        for (uint256 i; i < modules.length; i++) {
            vm.startPrank(fund);
            modules[i].calculatePerformanceFee(1e8, 0, RATE, 0);
            assertEq(modules[i].calculatePerformanceFee(1.2e8, 0, RATE, 0), 0, "no shares, no fee");
            vm.stopPrank();
            assertEq(WatermarkFeeBase(address(modules[i])).highWatermark(fund), 1.2e8, "price unchanged by a mint");
        }
    }
}

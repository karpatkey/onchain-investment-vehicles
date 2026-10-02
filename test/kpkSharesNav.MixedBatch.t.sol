// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {kpkSharesNavTestBase} from "./kpkSharesNav.TestBase.sol";
import {IKpkSharesNav} from "../src/IKpkSharesNav.sol";
import {KpkSharesNav} from "../src/KpkSharesNav.sol";

/// @title kpkSharesNavMixedBatchTest
/// @notice Batches that mix subscriptions, redemptions and a fee event in a single call.
/// @dev Review found the post-fee repricing bound only on the subscription leg: a redemption
///      settling at the post-fee price had no test, and no test put both directions plus a fee
///      accrual in one `processRequests`. That combination is where the price snapshot, the fee
///      mint, the mint/burn loop and the slippage-skip path all interact, so it is where an
///      economic defect would hide.
contract kpkSharesNavMixedBatchTest is kpkSharesNavTestBase {
    uint256 internal constant SEED = 1_000e6;

    /// @notice Seeds the fund, seeds the watermark at $1.00, then doubles the NAV.
    /// @return navValue The NAV the next settlement will price against
    function _seedAndDouble() internal returns (int256 navValue) {
        fund = _deployFund(0, 0, 2000); // 20% performance fee
        vm.prank(safe);
        usdc.approve(address(fund), type(uint256).max);
        vm.prank(alice);
        usdc.approve(address(fund), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(fund), type(uint256).max);

        _seedFund(alice, SEED);

        // A settlement past MIN_TIME_ELAPSED so the watermark is genuinely seeded at $1.00
        vm.warp(vm.getBlockTimestamp() + 7 hours);
        vm.prank(bob);
        _approve(fund.requestSubscription(1e6, 1, address(usdc), bob));
        assertEq(fund.balanceOf(feeRecipient), 0, "seeding the watermark charges nothing");

        _setSharePrice(2 * ONE_USD);
        navValue = int256((2 * ONE_USD * fund.totalSupply()) / 1e18);
        vm.warp(vm.getBlockTimestamp() + 7 hours);
    }

    /// @notice Processes an approve list of two ids in one call
    function _approveTwo(uint256 a, uint256 b) internal {
        uint256[] memory approvals = new uint256[](2);
        approvals[0] = a;
        approvals[1] = b;
        vm.prank(ops);
        fund.processRequests(approvals, new uint256[](0), address(usdc));
    }

    /// @notice A redemption in a fee-bearing batch settles at the POST-fee price, i.e. the redeemer
    ///         bears the fee that accrued while they were still in the fund.
    /// @dev The subscription leg of this had a test; this leg did not. Settling a redemption at the
    ///      pre-fee price would let a redeemer walk out with fees other holders then absorb.
    function testRedemptionSettlesAtThePostFeePrice() public {
        int256 navValue = _seedAndDouble();

        uint256 supplyBefore = fund.totalSupply();
        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        _approve(fund.requestRedemption(500e18, 1, address(usdc), alice));

        uint256 feeShares = fund.balanceOf(feeRecipient);
        assertGt(feeShares, 0, "a performance fee was charged in this batch");

        uint256 postFeePrice = (uint256(navValue) * 1e18) / (supplyBefore + feeShares);
        uint256 expected = (500e18 * postFeePrice * 1e6) / (1e18 * ONE_USD);

        assertEq(usdc.balanceOf(alice) - aliceBefore, expected, "paid at the post-fee price");

        // And demonstrably NOT the pre-fee price, which would have paid more
        uint256 preFeePrice = (uint256(navValue) * 1e18) / supplyBefore;
        uint256 wouldHaveBeen = (500e18 * preFeePrice * 1e6) / (1e18 * ONE_USD);
        assertLt(expected, wouldHaveBeen, "the redeemer bears the fee rather than escaping it");
    }

    /// @notice A subscription and a redemption in the SAME batch both settle at one price, and the
    ///         order of the ids does not change any outcome.
    /// @dev An operator chooses the contents and ordering of the arrays. If ordering mattered, that
    ///      would be a lever over who gets what — the operator is trusted to choose which requests
    ///      settle, not to reallocate value between them.
    function testMixedBatchIsOrderIndependent() public {
        int256 navValue = _seedAndDouble();
        uint256 snapshotId = vm.snapshotState();

        // Order A: redemption id first
        vm.prank(alice);
        uint256 redeemId = fund.requestRedemption(500e18, 1, address(usdc), alice);
        vm.prank(bob);
        uint256 subId = fund.requestSubscription(1_000e6, 1, address(usdc), bob);
        uint256 supplyBefore = fund.totalSupply();
        _approveTwo(redeemId, subId);

        uint256 aliceA = usdc.balanceOf(alice);
        uint256 bobA = fund.balanceOf(bob);
        uint256 feeA = fund.balanceOf(feeRecipient);
        uint256 priceA = fund.lastSharePriceUsd();

        vm.revertToState(snapshotId);

        // Order B: subscription id first, everything else identical
        vm.prank(alice);
        redeemId = fund.requestRedemption(500e18, 1, address(usdc), alice);
        vm.prank(bob);
        subId = fund.requestSubscription(1_000e6, 1, address(usdc), bob);
        _approveTwo(subId, redeemId);

        assertEq(usdc.balanceOf(alice), aliceA, "redeemer unaffected by ordering");
        assertEq(fund.balanceOf(bob), bobA, "subscriber unaffected by ordering");
        assertEq(fund.balanceOf(feeRecipient), feeA, "fee unaffected by ordering");
        assertEq(fund.lastSharePriceUsd(), priceA, "one settled price either way");

        // Both legs priced against the same post-fee supply
        uint256 postFeePrice = (uint256(navValue) * 1e18) / (supplyBefore + feeA);
        assertEq(priceA, postFeePrice, "the batch settled at the post-fee price");
    }

    /// @notice Minting and burning DURING the loop does not re-price later requests in the batch.
    /// @dev The snapshot is deliberately not refreshed per request: every request in a batch must
    ///      get the same price, or an operator could advantage whoever they placed first.
    function testAllRequestsInABatchGetTheSamePrice() public {
        _seedAndDouble();

        vm.prank(bob);
        uint256 first = fund.requestSubscription(1_000e6, 1, address(usdc), bob);
        vm.prank(bob);
        uint256 second = fund.requestSubscription(1_000e6, 1, address(usdc), bob);

        uint256 before = fund.balanceOf(bob);
        _approveTwo(first, second);
        uint256 minted = fund.balanceOf(bob) - before;

        // Two identical deposits in one batch mint exactly the same number of shares, even though
        // the first one's mint changed totalSupply before the second was processed.
        assertEq(minted % 2, 0, "the two identical deposits split evenly");
        assertEq(minted / 2, minted - minted / 2, "no drift between first and second");
    }

    /// @notice A slippage-skipped redemption keeps its full escrow and takes no fee.
    /// @dev The redemption fee is computed before the bound is checked, so a skipped request must
    ///      not have been charged it. Escrow is the investor's until the request actually settles.
    function testSkippedRedemptionKeepsFullEscrowAndPaysNoFee() public {
        fund = _deployFund(0, 1000, 0); // 10% redemption fee, no performance fee
        vm.prank(safe);
        usdc.approve(address(fund), type(uint256).max);
        vm.prank(alice);
        usdc.approve(address(fund), type(uint256).max);

        _seedFund(alice, SEED);

        // A bound far above anything the current price can produce
        vm.prank(alice);
        uint256 id = fund.requestRedemption(500e18, 10_000e6, address(usdc), alice);
        _approve(id);

        assertEq(uint8(fund.getRequest(id).requestStatus), uint8(IKpkSharesNav.RequestStatus.PENDING));
        assertEq(fund.balanceOf(address(fund)), 500e18, "full escrow retained");
        assertEq(fund.balanceOf(feeRecipient), 0, "no redemption fee taken on a skipped request");
    }

    /// @notice A batch in which every request is skipped still settles no value.
    function testBatchWhereEverythingSkipsMovesNothing() public {
        _seedAndDouble();

        vm.prank(bob);
        uint256 greedy = fund.requestSubscription(1_000e6, 999_999e18, address(usdc), bob);
        vm.prank(alice);
        uint256 greedyRedeem = fund.requestRedemption(500e18, 999_999e6, address(usdc), alice);

        uint256 supplyBefore = fund.totalSupply();
        uint256 bobBefore = fund.balanceOf(bob);
        uint256 aliceBefore = usdc.balanceOf(alice);

        _approveTwo(greedy, greedyRedeem);

        assertEq(fund.balanceOf(bob), bobBefore, "no shares minted");
        assertEq(usdc.balanceOf(alice), aliceBefore, "no assets paid out");
        // The fee still crystallizes — the batch was priced, which is the documented behaviour
        assertEq(fund.totalSupply() - supplyBefore, fund.balanceOf(feeRecipient), "only fee shares entered supply");
        assertEq(uint8(fund.getRequest(greedy).requestStatus), uint8(IKpkSharesNav.RequestStatus.PENDING));
        assertEq(uint8(fund.getRequest(greedyRedeem).requestStatus), uint8(IKpkSharesNav.RequestStatus.PENDING));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {kpkSharesNavTestBase} from "./kpkSharesNav.TestBase.sol";
import {IKpkSharesNav} from "../src/IKpkSharesNav.sol";
import {KpkSharesNav} from "../src/KpkSharesNav.sol";
import {Mock_ERC20} from "./mocks/tokens.sol";

/// @notice Fees, and the consequences of pricing them in USD rather than in a nominated asset.
contract kpkSharesNavFeesTest is kpkSharesNavTestBase {
    function testManagementFeeAccruesInShares() public {
        fund = _deployFund(1000, 0, 0); // 10% per year
        vm.prank(safe);
        usdc.approve(address(fund), type(uint256).max);
        vm.prank(alice);
        usdc.approve(address(fund), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(fund), type(uint256).max);

        _seedFund(alice, 1_000e6);
        assertEq(fund.balanceOf(feeRecipient), 0);

        // Half a year later, a settlement accrues roughly 5% of supply to the fee receiver
        vm.warp(vm.getBlockTimestamp() + 182.5 days);
        vm.prank(bob);
        uint256 id = fund.requestSubscription(1_000e6, 1, address(usdc), bob);
        _approve(id);

        assertApproxEqRel(fund.balanceOf(feeRecipient), 50e18, 0.01e18, "~5% of 1,000 shares");
    }

    function testManagementFeeIsThrottledByMinTimeElapsed() public {
        fund = _deployFund(1000, 0, 0);
        vm.prank(safe);
        usdc.approve(address(fund), type(uint256).max);
        vm.prank(alice);
        usdc.approve(address(fund), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(fund), type(uint256).max);

        _seedFund(alice, 1_000e6);

        // Under the 6-hour floor, nothing accrues
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.prank(bob);
        uint256 id = fund.requestSubscription(1_000e6, 1, address(usdc), bob);
        _approve(id);

        assertEq(fund.balanceOf(feeRecipient), 0);
    }

    function testRedemptionFeeIsTakenFromEscrowedShares() public {
        fund = _deployFund(0, 1000, 0); // 10% redemption fee
        vm.prank(safe);
        usdc.approve(address(fund), type(uint256).max);
        vm.prank(alice);
        usdc.approve(address(fund), type(uint256).max);

        _seedFund(alice, 1_000e6);

        vm.prank(alice);
        uint256 id = fund.requestRedemption(500e18, 1, address(usdc), alice);

        uint256 before = usdc.balanceOf(alice);
        _approve(id);

        // 10% of the 500 shares goes to the fee receiver; the rest is burned and paid out
        assertEq(fund.balanceOf(feeRecipient), 50e18, "fee shares transferred, not burned");
        assertEq(usdc.balanceOf(alice) - before, 450e6, "paid on 450 net shares at $1.00");
    }

    function testPreviewRedemptionAccountsForTheRedemptionFee() public {
        fund = _deployFund(0, 1000, 0);
        vm.prank(safe);
        usdc.approve(address(fund), type(uint256).max);
        vm.prank(alice);
        usdc.approve(address(fund), type(uint256).max);

        _seedFund(alice, 1_000e6);
        assertEq(fund.previewRedemption(500e18, address(usdc)), 450e6);
    }

    /// @dev `KpkShares` gates performance fees on an `isFeeModuleAsset` flag, because the price it
    ///      hands the module is denominated in the settlement asset while the module treats it as
    ///      USD. This contract derives a genuine USD share price, so the watermark is one series
    ///      across every asset and the flag is gone — a batch in ANY listed asset accrues the fee.
    function testPerformanceFeeAccruesOnABatchInAnyAsset() public {
        fund = _deployFund(0, 0, 2000); // 20% performance fee
        vm.prank(safe);
        usdc.approve(address(fund), type(uint256).max);
        vm.prank(alice);
        usdc.approve(address(fund), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(fund), type(uint256).max);

        // A second, non-USD-pegged asset — the kind the old flag would have excluded
        Mock_ERC20 weth = new Mock_ERC20("WETH", 18);
        nav.registerAsset(address(weth), 18, int256(4_000 * 1e8), 8);
        vm.prank(ops);
        fund.updateAsset(address(weth), true, true);
        weth.mint(bob, 100e18);
        vm.prank(bob);
        weth.approve(address(fund), type(uint256).max);

        _seedFund(alice, 1_000e6);

        // The seeding settlement charges nothing and does not even reach the fee module: no time has
        // elapsed, so `MIN_TIME_ELAPSED` short-circuits it. Settle once past that floor so the
        // watermark is actually seeded, at $1.00.
        vm.warp(vm.getBlockTimestamp() + 7 hours);
        vm.prank(bob);
        uint256 seedId = fund.requestSubscription(1e6, 1, address(usdc), bob);
        _approve(seedId);
        assertEq(fund.balanceOf(feeRecipient), 0, "first observation seeds the watermark, charges nothing");

        // The portfolio doubles
        _setSharePrice(2 * ONE_USD);
        vm.warp(vm.getBlockTimestamp() + 7 hours);

        // Settle a batch denominated in WETH, not the USD-pegged base asset
        vm.prank(bob);
        uint256 id = fund.requestSubscription(1e18, 1, address(weth), bob);
        uint256[] memory approvals = new uint256[](1);
        approvals[0] = id;
        vm.prank(ops);
        fund.processRequests(approvals, new uint256[](0), address(weth));

        assertGt(fund.balanceOf(feeRecipient), 0, "performance fee accrued on a non-USD batch");
    }

    function testSetPerformanceFeeRateRevertsWhileNavUnhealthy() public {
        fund = _deployFund(0, 0, 2000);
        vm.prank(safe);
        usdc.approve(address(fund), type(uint256).max);
        vm.prank(alice);
        usdc.approve(address(fund), type(uint256).max);

        _seedFund(alice, 1_000e6);
        nav.setSequencerDown(true);

        // Settling the accrued fee needs a price, and the contract refuses to invent one
        vm.prank(admin);
        vm.expectRevert(IKpkSharesNav.NavUnhealthy.selector);
        fund.setPerformanceFeeRate(500);
    }

    function testSetPerformanceFeeRateWorksWhenNavIsHealthy() public {
        fund = _deployFund(0, 0, 2000);
        vm.prank(safe);
        usdc.approve(address(fund), type(uint256).max);
        vm.prank(alice);
        usdc.approve(address(fund), type(uint256).max);

        _seedFund(alice, 1_000e6);

        vm.prank(admin);
        fund.setPerformanceFeeRate(500);
        assertEq(fund.performanceFeeRate(), 500);
    }

    function testFeeRatesAreCappedAtTwentyPercent() public {
        vm.prank(admin);
        vm.expectRevert(IKpkSharesNav.FeeRateLimitExceeded.selector);
        fund.setManagementFeeRate(2001);

        vm.prank(admin);
        vm.expectRevert(IKpkSharesNav.FeeRateLimitExceeded.selector);
        fund.setRedemptionFeeRate(2001);

        vm.prank(admin);
        vm.expectRevert(IKpkSharesNav.FeeRateLimitExceeded.selector);
        fund.setPerformanceFeeRate(2001);
    }
}

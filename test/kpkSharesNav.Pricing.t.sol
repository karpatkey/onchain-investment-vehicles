// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {kpkSharesNavTestBase} from "./kpkSharesNav.TestBase.sol";
import {IKpkSharesNav} from "../src/IKpkSharesNav.sol";
import {KpkSharesNav} from "../src/KpkSharesNav.sol";
import {Mock_ERC20} from "./mocks/tokens.sol";
import {MockNavCalculator} from "./mocks/MockNavCalculator.sol";

/// @notice Pricing, the NAV health gate, and the bootstrap path.
contract kpkSharesNavPricingTest is kpkSharesNavTestBase {
    //
    // Bootstrap
    //

    function testBootstrapPriceUsedWhileSupplyIsZero() public view {
        assertEq(fund.totalSupply(), 0);
        // No NAV read at all on this path — the price is the configured bootstrap price
        assertEq(fund.getSharePriceUsd(), ONE_USD);
    }

    function testBootstrapPriceIsUsedEvenWhenNavWouldRevert() public {
        nav.setNavReverts(true);
        assertEq(fund.getSharePriceUsd(), ONE_USD);
    }

    function testFirstSubscriptionMintsAtBootstrapPrice() public {
        // 1,000 USDC at $1.00/share => 1,000 shares
        _subscribeAndSettle(alice, 1_000e6, 1);
        assertEq(fund.balanceOf(alice), 1_000e18);
    }

    //
    // NAV-derived price
    //

    function testSharePriceDerivedFromNavAndSupply() public {
        _seedFund(alice, 1_000e6);
        assertEq(fund.getSharePriceUsd(), ONE_USD);

        // Portfolio doubles in value: $2,000 against 1,000 shares => $2.00/share
        nav.setNavValue(int256(2_000 * 1e8));
        assertEq(fund.getSharePriceUsd(), 2 * ONE_USD);
    }

    function testSharePriceReadsNavForThePortfolioSafe() public {
        _seedFund(alice, 1_000e6);
        // The mock only reports a NAV for the account it was told about
        nav.setNavAccount(address(0xDEAD));
        vm.expectRevert(IKpkSharesNav.NavNotPositive.selector);
        fund.getSharePriceUsd();
    }

    function testSubscriptionAtDoubledNavMintsHalfTheShares() public {
        _seedFund(alice, 1_000e6);
        nav.setNavValue(int256(2_000 * 1e8));

        // 1,000 USDC at $2.00/share => 500 shares
        _subscribeAndSettle(bob, 1_000e6, 1);
        assertEq(fund.balanceOf(bob), 500e18);
    }

    //
    // Health gate — each flag independently halts pricing
    //

    function testSequencerDownHaltsPricing() public {
        _seedFund(alice, 1_000e6);
        nav.setSequencerDown(true);
        vm.expectRevert(IKpkSharesNav.NavUnhealthy.selector);
        fund.getSharePriceUsd();
    }

    function testQuoteAssetStaleHaltsPricing() public {
        _seedFund(alice, 1_000e6);
        nav.setQuoteAssetStale(true);
        vm.expectRevert(IKpkSharesNav.NavUnhealthy.selector);
        fund.getSharePriceUsd();
    }

    function testQuoteAssetIrregularHaltsPricing() public {
        _seedFund(alice, 1_000e6);
        nav.setQuoteAssetIrregular(true);
        vm.expectRevert(IKpkSharesNav.NavUnhealthy.selector);
        fund.getSharePriceUsd();
    }

    function testStalePriceAssetHaltsPricing() public {
        _seedFund(alice, 1_000e6);
        nav.pushStaleAsset(address(usdc));
        vm.expectRevert(IKpkSharesNav.NavUnhealthy.selector);
        fund.getSharePriceUsd();
    }

    function testIrregularPriceAssetHaltsPricing() public {
        _seedFund(alice, 1_000e6);
        nav.pushIrregularAsset(address(usdc));
        vm.expectRevert(IKpkSharesNav.NavUnhealthy.selector);
        fund.getSharePriceUsd();
    }

    function testMonitorsUnhealthyAssetHaltsPricing() public {
        _seedFund(alice, 1_000e6);
        nav.pushMonitorsUnhealthyAsset(address(usdc));
        vm.expectRevert(IKpkSharesNav.NavUnhealthy.selector);
        fund.getSharePriceUsd();
    }

    function testUnhealthyNavBlocksSettlement() public {
        _seedFund(alice, 1_000e6);

        vm.prank(bob);
        uint256 id = fund.requestSubscription(1_000e6, 1, address(usdc), bob);

        nav.setSequencerDown(true);
        uint256[] memory approvals = new uint256[](1);
        approvals[0] = id;
        vm.prank(ops);
        vm.expectRevert(IKpkSharesNav.NavUnhealthy.selector);
        fund.processRequests(approvals, new uint256[](0), address(usdc));
    }

    //
    // Non-positive NAV
    //

    function testNegativeNavHaltsPricing() public {
        _seedFund(alice, 1_000e6);
        nav.setNavValue(-1);
        vm.expectRevert(IKpkSharesNav.NavNotPositive.selector);
        fund.getSharePriceUsd();
    }

    function testZeroNavHaltsPricing() public {
        _seedFund(alice, 1_000e6);
        nav.setNavValue(0);
        vm.expectRevert(IKpkSharesNav.NavNotPositive.selector);
        fund.getSharePriceUsd();
    }

    function testSharePriceRoundingToZeroReverts() public {
        _seedFund(alice, 1_000e6);
        // A NAV of 1 (i.e. $0.00000001) against 1,000e18 shares floors to a zero price per share
        nav.setNavValue(1);
        vm.expectRevert(IKpkSharesNav.SharePriceZero.selector);
        fund.getSharePriceUsd();
    }

    //
    // Asset price health
    //

    function testStaleAssetPriceHaltsSettlement() public {
        _seedFund(alice, 1_000e6);
        nav.setPriceStale(address(usdc), true);
        vm.expectRevert(IKpkSharesNav.AssetPriceUnhealthy.selector);
        fund.previewSubscription(1_000e6, address(usdc));
    }

    function testIrregularAssetPriceHaltsSettlement() public {
        _seedFund(alice, 1_000e6);
        nav.setPriceIrregular(address(usdc), true);
        vm.expectRevert(IKpkSharesNav.AssetPriceUnhealthy.selector);
        fund.previewSubscription(1_000e6, address(usdc));
    }

    function testNonPositiveAssetPriceHaltsSettlement() public {
        _seedFund(alice, 1_000e6);
        nav.setPrice(address(usdc), 0, 8);
        vm.expectRevert(IKpkSharesNav.AssetPriceUnhealthy.selector);
        fund.previewSubscription(1_000e6, address(usdc));
    }

    //
    // Decimals
    //

    /// @dev The NAV reports each feed's own scale rather than guaranteeing 8, so a feed with more or
    ///      fewer decimals must produce the same shares as an equivalent 8-decimal one.
    function testAssetPriceDecimalsAreNormalized() public {
        _seedFund(alice, 1_000e6);
        uint256 expected = fund.previewSubscription(1_000e6, address(usdc));

        nav.setPrice(address(usdc), int256(1e18), 18);
        assertEq(fund.previewSubscription(1_000e6, address(usdc)), expected, "18-dec feed");

        nav.setPrice(address(usdc), int256(1e6), 6);
        assertEq(fund.previewSubscription(1_000e6, address(usdc)), expected, "6-dec feed");
    }

    /// @dev A non-18-decimal, non-USD-pegged asset is where an asset-denominated price unit would
    ///      have gone wrong, so it gets an explicit worked case.
    function testNonUsdPeggedAssetWithEightDecimals() public {
        Mock_ERC20 wbtc = new Mock_ERC20("WBTC", 8);
        nav.registerAsset(address(wbtc), 8, int256(60_000 * 1e8), 8);

        vm.prank(ops);
        fund.updateAsset(address(wbtc), true, true);

        _seedFund(alice, 1_000e6);
        // Share price $1.05
        nav.setNavValue(int256(1_050 * 1e8));

        // 0.5 WBTC = $30,000, at $1.05/share => 28,571.428571… shares
        uint256 shares = fund.previewSubscription(5e7, address(wbtc));
        assertEq(shares, (uint256(30_000) * 1e18 * 1e8) / (105 * 1e6), "0.5 WBTC at $1.05/share");
        assertApproxEqRel(shares, 28_571.428571e18, 1e12);
    }

    function testRedemptionRoundTripFloorsInTheFundsFavour() public {
        _seedFund(alice, 1_000e6);
        uint256 assetsBack = fund.previewRedemption(1_000e18, address(usdc));
        // Floors, so a round trip never returns more than was put in
        assertLe(assetsBack, 1_000e6);
        assertEq(assetsBack, 1_000e6);
    }

    //
    // The NAV read is scoped correctly
    //

    function testAdapterGasExhaustionHaltsSettlementButNotRefunds() public {
        _seedFund(alice, 1_000e6);

        vm.prank(bob);
        uint256 id = fund.requestSubscription(1_000e6, 1, address(usdc), bob);

        // Simulate a gas-starved NAV scan
        nav.setNavReverts(true);

        uint256[] memory approvals = new uint256[](1);
        approvals[0] = id;
        vm.prank(ops);
        vm.expectRevert(MockNavCalculator.AdapterGasExhausted.selector);
        fund.processRequests(approvals, new uint256[](0), address(usdc));

        // ...but a pure-rejection call still refunds, because it never reaches for the NAV
        uint256 balanceBefore = usdc.balanceOf(bob);
        _reject(id);
        assertEq(usdc.balanceOf(bob) - balanceBefore, 1_000e6, "escrow refunded while unpriceable");
    }
}

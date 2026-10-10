// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {kpkSharesNavTestBase} from "./kpkSharesNav.TestBase.sol";
import {IKpkSharesNav} from "../src/IKpkSharesNav.sol";
import {KpkSharesNav} from "../src/KpkSharesNav.sol";
import {Mock_ERC20} from "./mocks/tokens.sol";
import {MockNavCalculator, MockWrongScaleNavCalculator} from "./mocks/MockNavCalculator.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @notice The NAV-registry listing gate, and the admin surface around the NAV calculator.
contract kpkSharesNavAssetsTest is kpkSharesNavTestBase {
    Mock_ERC20 internal weth;

    function setUp() public override {
        super.setUp();
        weth = new Mock_ERC20("WETH", 18);
    }

    //
    // Listing gate
    //

    function testCannotListAssetUnknownToTheNav() public {
        vm.prank(ops);
        vm.expectRevert(IKpkSharesNav.AssetNotRegisteredInNav.selector);
        fund.updateAsset(address(weth), true, true);
    }

    function testCanListAssetRegisteredInTheNav() public {
        nav.registerAsset(address(weth), 18, int256(4_000 * 1e8), 8);

        vm.prank(ops);
        vm.expectEmit(true, true, true, true);
        emit IKpkSharesNav.AssetAdd(address(weth));
        fund.updateAsset(address(weth), true, true);

        assertTrue(fund.isApprovedAsset(address(weth)));
        assertEq(fund.assetDecimals(address(weth)), 18);
    }

    function testCannotListAssetTheNavCannotPrice() public {
        // Registered, but with no price feed configured
        nav.registerAssetWithoutFeed(address(weth), 18);

        vm.prank(ops);
        vm.expectRevert(IKpkSharesNav.AssetNotPriceable.selector);
        fund.updateAsset(address(weth), true, true);
    }

    function testCannotListAssetWhosePriceIsCurrentlyStale() public {
        nav.registerAsset(address(weth), 18, int256(4_000 * 1e8), 8);
        nav.setPriceStale(address(weth), true);

        vm.prank(ops);
        vm.expectRevert(IKpkSharesNav.AssetNotPriceable.selector);
        fund.updateAsset(address(weth), true, true);
    }

    function testCannotListAssetWhenNavDecimalsDisagreeWithTheToken() public {
        // NAV registry claims 6 decimals for an 18-decimal token
        nav.registerAsset(address(weth), 6, int256(4_000 * 1e8), 8);

        vm.prank(ops);
        vm.expectRevert(IKpkSharesNav.InvalidArguments.selector);
        fund.updateAsset(address(weth), true, true);
    }

    /// @dev An asset must stay removable even after the NAV stops supporting it, or a fund could be
    ///      permanently stuck holding a listing it cannot settle and cannot drop.
    function testDelistingSkipsTheNavChecks() public {
        nav.registerAsset(address(weth), 18, int256(4_000 * 1e8), 8);
        vm.prank(ops);
        fund.updateAsset(address(weth), true, true);

        nav.unregisterAsset(address(weth));

        vm.prank(ops);
        vm.expectEmit(true, true, true, true);
        emit IKpkSharesNav.AssetRemove(address(weth));
        fund.updateAsset(address(weth), false, false);

        assertFalse(fund.isApprovedAsset(address(weth)));
    }

    function testCannotDelistTheLastAsset() public {
        vm.prank(ops);
        vm.expectRevert(IKpkSharesNav.InvalidArguments.selector);
        fund.updateAsset(address(usdc), false, false);
    }

    function testCannotDelistAssetWithPendingRequests() public {
        nav.registerAsset(address(weth), 18, int256(4_000 * 1e8), 8);
        vm.prank(ops);
        fund.updateAsset(address(weth), true, true);

        vm.prank(alice);
        fund.requestSubscription(1_000e6, 1, address(usdc), alice);

        vm.prank(ops);
        vm.expectRevert(IKpkSharesNav.InvalidArguments.selector);
        fund.updateAsset(address(usdc), false, false);
    }

    function testOnlyOperatorCanUpdateAssets() public {
        nav.registerAsset(address(weth), 18, int256(4_000 * 1e8), 8);

        vm.prank(alice);
        vm.expectRevert(IKpkSharesNav.NotAuthorized.selector);
        fund.updateAsset(address(weth), true, true);
    }

    //
    // setNavCalculator
    //

    function testSetNavCalculatorRejectsNonContract() public {
        vm.prank(admin);
        vm.expectRevert(IKpkSharesNav.InvalidNavCalculator.selector);
        fund.setNavCalculator(makeAddr("eoa"));
    }

    function testSetNavCalculatorRejectsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(IKpkSharesNav.InvalidNavCalculator.selector);
        fund.setNavCalculator(address(0));
    }

    function testSetNavCalculatorRejectsWrongUsdScale() public {
        MockWrongScaleNavCalculator wrong = new MockWrongScaleNavCalculator();
        vm.prank(admin);
        vm.expectRevert(IKpkSharesNav.InvalidNavCalculator.selector);
        fund.setNavCalculator(address(wrong));
    }

    /// @dev The guard that stops an admin bricking the fund by pointing it at a NAV that cannot
    ///      price what the fund already lists.
    function testSetNavCalculatorRejectsNavMissingAListedAsset() public {
        MockNavCalculator fresh = new MockNavCalculator();
        // The new NAV knows nothing about USDC, which this fund lists

        vm.prank(admin);
        vm.expectRevert(IKpkSharesNav.AssetNotRegisteredInNav.selector);
        fund.setNavCalculator(address(fresh));
    }

    function testSetNavCalculatorAcceptsAFullyConfiguredNav() public {
        MockNavCalculator fresh = new MockNavCalculator();
        fresh.registerAsset(address(usdc), 6, int256(ONE_USD), 8);
        fresh.setNavAccount(safe);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit IKpkSharesNav.NavCalculatorUpdate(address(nav), address(fresh));
        fund.setNavCalculator(address(fresh));

        assertEq(fund.navCalculator(), address(fresh));
    }

    function testOnlyAdminCanSetNavCalculator() public {
        MockNavCalculator fresh = new MockNavCalculator();
        fresh.registerAsset(address(usdc), 6, int256(ONE_USD), 8);

        vm.prank(ops);
        vm.expectRevert(IKpkSharesNav.NotAuthorized.selector);
        fund.setNavCalculator(address(fresh));
    }

    function testFundPricesFromTheNewNavAfterSwap() public {
        _seedFund(alice, 1_000e6);

        MockNavCalculator fresh = new MockNavCalculator();
        fresh.registerAsset(address(usdc), 6, int256(ONE_USD), 8);
        fresh.setNavAccount(safe);
        // The new NAV values the same portfolio at twice as much
        fresh.setNavValue(int256(2_000 * 1e8));

        vm.prank(admin);
        fund.setNavCalculator(address(fresh));

        assertEq(fund.getSharePriceUsd(), 2 * ONE_USD);
    }

    //
    // Initialization
    //

    function testInitializeRejectsBadNavCalculator() public {
        address impl = address(new KpkSharesNav());
        KpkSharesNav.ConstructorParams memory params = _baseParams();
        params.navCalculator = makeAddr("eoa");

        vm.expectRevert(IKpkSharesNav.InvalidNavCalculator.selector);
        UnsafeUpgrades.deployUUPSProxy(impl, abi.encodeCall(KpkSharesNav.initialize, (params)));
    }

    function testInitializeRejectsZeroInitialSharePrice() public {
        address impl = address(new KpkSharesNav());
        KpkSharesNav.ConstructorParams memory params = _baseParams();
        params.initialSharePrice = 0;

        vm.expectRevert(IKpkSharesNav.InvalidArguments.selector);
        UnsafeUpgrades.deployUUPSProxy(impl, abi.encodeCall(KpkSharesNav.initialize, (params)));
    }

    function testInitializeRejectsBaseAssetUnknownToTheNav() public {
        Mock_ERC20 stranger = new Mock_ERC20("STR", 18);
        address impl = address(new KpkSharesNav());
        KpkSharesNav.ConstructorParams memory params = _baseParams();
        params.asset = address(stranger);

        vm.expectRevert(IKpkSharesNav.AssetNotRegisteredInNav.selector);
        UnsafeUpgrades.deployUUPSProxy(impl, abi.encodeCall(KpkSharesNav.initialize, (params)));
    }

    function _baseParams() internal view returns (KpkSharesNav.ConstructorParams memory) {
        return KpkSharesNav.ConstructorParams({
            asset: address(usdc),
            admin: admin,
            name: "kpk NAV",
            symbol: "kpkNAV",
            safe: safe,
            subscriptionRequestTtl: SUBSCRIPTION_TTL,
            redemptionRequestTtl: REDEMPTION_TTL,
            feeReceiver: feeRecipient,
            managementFeeRate: 0,
            redemptionFeeRate: 0,
            performanceFeeModule: address(perfFeeModule),
            performanceFeeRate: 0,
            navCalculator: address(nav),
            initialSharePrice: ONE_USD
        });
    }
}

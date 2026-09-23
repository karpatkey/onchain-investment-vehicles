// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {KpkSharesRouterTestBase} from "test/KpkSharesRouter.TestBase.sol";
import {IKpkSharesRouter} from "src/periphery/IKpkSharesRouter.sol";
import {IkpkShares} from "src/IkpkShares.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";

/// @notice Happy-path and accounting behaviour of atomic subscription.
contract KpkSharesRouterSubscribeTest is KpkSharesRouterTestBase {
    function test_subscribe_mintsExactPreviewedShares() public {
        uint256 assetsIn = _usdcAmount(1000);
        uint256 expected = kpkSharesContract.assetsToShares(assetsIn, SHARES_PRICE, address(usdc));

        (uint256 requestId, uint256 sharesOut) = _routerSubscribe(investor, assetsIn, SHARES_PRICE);

        assertEq(sharesOut, expected, "shares out must equal the preview exactly");
        assertEq(sharesOut, _sharesAmount(1000), "1000 USDC at $1 must mint 1000 shares");
        assertEq(kpkSharesContract.balanceOf(investor), sharesOut, "receiver must hold the minted shares");
        assertGt(requestId, 0, "a request must have been created");
    }

    function test_subscribe_forwardsAssetsToPortfolioSafe() public {
        uint256 assetsIn = _usdcAmount(1000);
        uint256 safeBefore = usdc.balanceOf(safe);

        _routerSubscribe(investor, assetsIn, SHARES_PRICE);

        assertEq(usdc.balanceOf(safe) - safeBefore, assetsIn, "assets must land in the portfolio Safe");
        assertEq(usdc.balanceOf(address(kpkSharesContract)), 0, "no assets may remain escrowed");
    }

    function test_subscribe_mintsToDistinctReceiver() public {
        uint256 assetsIn = _usdcAmount(500);

        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        bytes memory sig = _signNav(nav);

        vm.prank(investor);
        (, uint256 sharesOut) = router.subscribe(address(usdc), assetsIn, 1, carol, nav, sig);

        assertEq(kpkSharesContract.balanceOf(carol), sharesOut, "receiver must hold the shares");
        assertEq(kpkSharesContract.balanceOf(investor), 0, "payer must hold none");
    }

    function test_subscribe_settlesRequestAndLeavesRouterEmpty() public {
        (uint256 requestId,) = _routerSubscribe(investor, _usdcAmount(1000), SHARES_PRICE);

        IkpkShares.UserRequest memory request = kpkSharesContract.getRequest(requestId);
        assertEq(uint8(request.requestStatus), uint8(IkpkShares.RequestStatus.PROCESSED), "request must end PROCESSED");

        assertEq(usdc.balanceOf(address(router)), 0, "router must hold no assets");
        assertEq(kpkSharesContract.balanceOf(address(router)), 0, "router must hold no shares");
        assertEq(usdc.allowance(address(router), address(kpkSharesContract)), 0, "transient allowance must be consumed");
    }

    function test_subscribe_recordsRouterAsRequestInvestor() public {
        (uint256 requestId,) = _routerSubscribe(investor, _usdcAmount(100), SHARES_PRICE);

        IkpkShares.UserRequest memory request = kpkSharesContract.getRequest(requestId);

        // Documents why the router's own events are the attribution record: the fund records the
        // router, not the person who paid.
        assertEq(request.investor, address(router), "fund records the router as investor");
        assertEq(request.receiver, investor, "receiver is the real subscriber");
    }

    /// @notice The property the whole atomic design rests on: fee shares minted inside the same
    ///         `processRequests` call cannot change the subscriber's share count, because the
    ///         conversion never reads `totalSupply`.
    function test_subscribe_feeMintDoesNotChangeSharesOut() public {
        _seedPerformanceWatermark(kpkSharesContract, alice);

        // Past the fund's 6-hour fee gate (note: the contract's MIN_TIME_ELAPSED is 6 hours, not the
        // 1 days in test/constants.sol), so management and performance fees both accrue on settlement.
        skip(7 hours);

        uint256 price = 1.001e8; // small enough that the fee-dilution guard stays satisfied
        uint256 assetsIn = _usdcAmount(1000);
        uint256 expected = kpkSharesContract.assetsToShares(assetsIn, price, address(usdc));
        uint256 feeReceiverBefore = kpkSharesContract.balanceOf(feeRecipient);

        (, uint256 sharesOut) = _routerSubscribe(investor, assetsIn, price);

        assertGt(
            kpkSharesContract.balanceOf(feeRecipient),
            feeReceiverBefore,
            "fees must actually have been minted, or this test proves nothing"
        );
        assertEq(sharesOut, expected, "fee dilution must not shift the subscriber's share count");
        assertEq(kpkSharesContract.balanceOf(investor), expected, "receiver got exactly the quoted shares");
    }

    function test_subscribe_revertsWhenBelowCallersMinimum() public {
        uint256 assetsIn = _usdcAmount(1000);
        uint256 expected = kpkSharesContract.assetsToShares(assetsIn, SHARES_PRICE, address(usdc));

        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        bytes memory sig = _signNav(nav);

        vm.prank(investor);
        vm.expectRevert(abi.encodeWithSelector(IKpkSharesRouter.InsufficientOutput.selector, expected, expected + 1));
        router.subscribe(address(usdc), assetsIn, expected + 1, investor, nav, sig);
    }

    function test_subscribe_revertsOnZeroAssets() public {
        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        bytes memory sig = _signNav(nav);

        vm.prank(investor);
        vm.expectRevert(IKpkSharesRouter.InvalidAmount.selector);
        router.subscribe(address(usdc), 0, 1, investor, nav, sig);
    }

    function test_subscribe_revertsWhenAssetNotConfigured() public {
        Mock_ERC20 dai = new Mock_ERC20("DAI", 18);

        IKpkSharesRouter.NavAttestation memory nav = _nav(address(dai), SHARES_PRICE);
        bytes memory sig = _signNav(nav);

        vm.prank(investor);
        vm.expectRevert(abi.encodeWithSelector(IKpkSharesRouter.AssetNotEnabled.selector, address(dai)));
        router.subscribe(address(dai), _usdcAmount(1), 1, investor, nav, sig);
    }

    function test_subscribe_worksWithEighteenDecimalAsset() public {
        Mock_ERC20 dai = _enableEighteenDecimalAsset();

        uint256 assetsIn = 1000e18;
        uint256 expected = kpkSharesContract.assetsToShares(assetsIn, SHARES_PRICE, address(dai));

        IKpkSharesRouter.NavAttestation memory nav = _nav(address(dai), SHARES_PRICE);
        bytes memory sig = _signNav(nav);

        vm.prank(investor);
        (, uint256 sharesOut) = router.subscribe(address(dai), assetsIn, 1, investor, nav, sig);

        assertEq(sharesOut, expected, "18-decimal asset must price exactly");
        assertEq(sharesOut, _sharesAmount(1000), "1000 DAI at $1 must mint 1000 shares");
    }

    /// @notice A dust subscription whose conversion floors to zero must revert rather than gift the
    ///         fund the assets. Only reachable with an 18-decimal asset, since the 6-decimal path
    ///         cannot round to zero inside the configured price bounds.
    function test_subscribe_revertsWhenConversionRoundsToZero() public {
        Mock_ERC20 dai = _enableEighteenDecimalAsset();

        uint256 price = 2e8;
        assertEq(kpkSharesContract.assetsToShares(1, price, address(dai)), 0, "precondition: rounds to zero");

        IKpkSharesRouter.NavAttestation memory nav = _nav(address(dai), price);
        bytes memory sig = _signNav(nav);

        vm.prank(investor);
        vm.expectRevert(IKpkSharesRouter.InvalidAmount.selector);
        router.subscribe(address(dai), 1, 1, investor, nav, sig);
    }

    function test_previewSubscribe_matchesActualMint() public {
        uint256 assetsIn = _usdcAmount(777);
        uint256 preview = router.previewSubscribe(address(usdc), assetsIn, SHARES_PRICE);

        (, uint256 sharesOut) = _routerSubscribe(investor, assetsIn, SHARES_PRICE);

        assertEq(sharesOut, preview, "preview must match the settled amount");
    }

    // ============================================================================
    // Helpers
    // ============================================================================

    /// @dev Registers an 18-decimal deposit asset on the fund and configures it on the router.
    function _enableEighteenDecimalAsset() internal returns (Mock_ERC20 dai) {
        dai = new Mock_ERC20("DAI", 18);
        dai.mint(investor, 1_000_000e18);

        vm.prank(ops);
        kpkSharesContract.updateAsset(address(dai), false, true, true);

        IKpkSharesRouter.AssetConfig memory config = _defaultConfig();
        config.maxAssetsInPerTx = 1_000_000e18;
        vm.prank(admin);
        router.setAssetConfig(address(dai), config);

        vm.prank(investor);
        dai.approve(address(router), type(uint256).max);

        vm.prank(safe);
        dai.approve(address(kpkSharesContract), type(uint256).max);
    }
}

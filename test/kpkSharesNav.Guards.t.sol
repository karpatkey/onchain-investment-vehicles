// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {kpkSharesNavTestBase} from "./kpkSharesNav.TestBase.sol";
import {IKpkSharesNav} from "../src/IKpkSharesNav.sol";
import {Mock_ERC20} from "./mocks/tokens.sol";

/// @title kpkSharesNavGuardsTest
/// @notice Guards that mutation testing showed no test was binding.
/// @dev Each of these survived a mutation that deleted or neutered the guard it covers — the suite
///      stayed green while the protection was gone. They are individually small; the point is that
///      "the whole suite passes" was not evidence any of them worked.
contract kpkSharesNavGuardsTest is kpkSharesNavTestBase {
    /// @notice An asset with more decimals than the conversion arithmetic is bounded for is refused.
    /// @dev The cap exists so `10 ** assetDecimals` cannot blow up the `mulDiv` operands. Mutation:
    ///      deleting the check left every test green.
    function testCannotListAssetWithTooManyDecimals() public {
        Mock_ERC20 absurd = new Mock_ERC20("ABSURD", 37);
        nav.registerAsset(address(absurd), 37, int256(ONE_USD), 8);

        vm.prank(ops);
        vm.expectRevert(IKpkSharesNav.InvalidArguments.selector);
        fund.updateAsset(address(absurd), true, true);
    }

    /// @notice Exactly the cap is still accepted, so the guard is not off by one.
    function testCanListAssetAtTheDecimalsCap() public {
        Mock_ERC20 atCap = new Mock_ERC20("CAP", 36);
        nav.registerAsset(address(atCap), 36, int256(ONE_USD), 8);

        vm.prank(ops);
        fund.updateAsset(address(atCap), true, true);
        assertEq(fund.assetDecimals(address(atCap)), 36);
    }

    /// @notice A TTL above MAX_TTL is clamped rather than stored raw.
    /// @dev A raw store would let an admin push a request's cancellation window past its 7-day
    ///      expiry, stranding escrow that could then be neither cancelled nor settled. Mutation:
    ///      dropping the clamp left every test green.
    function testTtlsAreClampedToMaxTtl() public {
        uint64 tooLong = 30 days;

        vm.prank(admin);
        fund.setSubscriptionRequestTtl(tooLong);
        assertEq(fund.subscriptionRequestTtl(), fund.MAX_TTL(), "subscription TTL clamped");

        vm.prank(admin);
        fund.setRedemptionRequestTtl(tooLong);
        assertEq(fund.redemptionRequestTtl(), fund.MAX_TTL(), "redemption TTL clamped");
    }

    /// @notice The management fee base excludes shares the fee receiver already holds.
    /// @dev Otherwise the fee compounds on itself. Mutation: charging on the raw `totalSupply()`
    ///      left every test green, because no test had a non-zero fee-receiver balance before a
    ///      second accrual.
    function testManagementFeeBaseExcludesTheFeeReceiversOwnShares() public {
        fund = _deployFund(1000, 0, 0); // 10%/yr
        vm.prank(safe);
        usdc.approve(address(fund), type(uint256).max);
        vm.prank(alice);
        usdc.approve(address(fund), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(fund), type(uint256).max);

        _seedFund(alice, 1_000e6);

        // First accrual gives the fee receiver a balance
        vm.warp(vm.getBlockTimestamp() + 182.5 days);
        vm.prank(bob);
        _approve(fund.requestSubscription(1e6, 1, address(usdc), bob));
        uint256 firstFee = fund.balanceOf(feeRecipient);
        assertGt(firstFee, 0, "fee receiver now holds shares");

        // Second accrual over the same span: the base must exclude those shares, so the second fee
        // is strictly smaller than 10%/yr on the whole supply would give.
        uint256 supply = fund.totalSupply();
        vm.warp(vm.getBlockTimestamp() + 182.5 days);
        vm.prank(bob);
        _approve(fund.requestSubscription(1e6, 1, address(usdc), bob));
        uint256 secondFee = fund.balanceOf(feeRecipient) - firstFee;

        uint256 onRawSupply = (supply * 1000 * 182.5 days) / (10_000 * 365 days);
        assertLt(secondFee, onRawSupply, "fee did not compound on the receiver's own shares");
    }

    /// @notice A request that has already settled cannot be settled again.
    /// @dev `_checkValidRequest` gates on both a non-zero investor AND a PENDING status. Mutation:
    ///      replacing the status half with `true` left every test green — the existing coverage only
    ///      exercised the zero-investor half.
    function testAlreadyProcessedRequestIsNotSettledTwice() public {
        _seedFund(alice, 1_000e6);

        vm.prank(bob);
        uint256 id = fund.requestSubscription(1_000e6, 1, address(usdc), bob);
        _approve(id);

        uint256 sharesAfterFirst = fund.balanceOf(bob);
        uint256 supplyAfterFirst = fund.totalSupply();
        assertEq(uint8(fund.getRequest(id).requestStatus), uint8(IKpkSharesNav.RequestStatus.PROCESSED));

        // Replaying the same id mints nothing more
        _approve(id);
        assertEq(fund.balanceOf(bob), sharesAfterFirst, "no second mint");
        assertEq(fund.totalSupply(), supplyAfterFirst, "supply unchanged");
    }

    /// @notice A cancelled request cannot then be approved.
    function testCancelledRequestCannotBeSettled() public {
        vm.prank(alice);
        uint256 id = fund.requestSubscription(1_000e6, 1, address(usdc), alice);

        vm.warp(vm.getBlockTimestamp() + SUBSCRIPTION_TTL + 1);
        vm.prank(alice);
        fund.cancelSubscription(id);

        _approve(id);
        assertEq(fund.balanceOf(alice), 0, "a cancelled request mints nothing");
        assertEq(uint8(fund.getRequest(id).requestStatus), uint8(IKpkSharesNav.RequestStatus.CANCELLED));
    }

    /// @notice Rejecting only touches requests denominated in the batch's asset.
    /// @dev Without the filter, an operator processing asset A would also reject pending requests in
    ///      asset B that happened to be in the list. Mutation: removing the filter left every test
    ///      green, because no test mixed assets in a reject batch.
    function testRejectionIgnoresRequestsForADifferentAsset() public {
        Mock_ERC20 weth = new Mock_ERC20("WETH", 18);
        nav.registerAsset(address(weth), 18, int256(4_000 * 1e8), 8);
        vm.prank(ops);
        fund.updateAsset(address(weth), true, true);
        weth.mint(alice, 10e18);
        vm.prank(alice);
        weth.approve(address(fund), type(uint256).max);

        vm.prank(alice);
        uint256 wethId = fund.requestSubscription(1e18, 1, address(weth), alice);

        // Reject that id while processing USDC: the asset does not match, so it must be untouched
        uint256[] memory rejections = new uint256[](1);
        rejections[0] = wethId;
        vm.prank(ops);
        fund.processRequests(new uint256[](0), rejections, address(usdc));

        assertEq(uint8(fund.getRequest(wethId).requestStatus), uint8(IKpkSharesNav.RequestStatus.PENDING));
        assertEq(weth.balanceOf(address(fund)), 1e18, "escrow untouched");
        assertEq(fund.subscriptionAssets(address(weth)), 1e18, "books untouched");
    }

    /// @notice Delisting removes the RIGHT asset from the enumerable list.
    /// @dev `_shadowAsset` swaps the target with the last element before popping. Mutation testing
    ///      showed that popping without the swap left the whole suite green: the map entry for the
    ///      intended asset is deleted either way, so counts and `isApprovedAsset` still look right —
    ///      but the list would silently lose a DIFFERENT, still-listed asset, desyncing
    ///      `getApprovedAssets()` from `_approvedAssetsMap`. That list is what `setNavCalculator`
    ///      iterates, so a stale entry would validate a NAV against an asset the fund no longer
    ///      lists, and a dropped one would skip an asset it does. Asserted by address, not count.
    function testDelistingRemovesTheCorrectAssetFromTheList() public {
        Mock_ERC20 weth = new Mock_ERC20("WETH", 18);
        Mock_ERC20 wbtc = new Mock_ERC20("WBTC", 8);
        nav.registerAsset(address(weth), 18, int256(4_000 * 1e8), 8);
        nav.registerAsset(address(wbtc), 8, int256(60_000 * 1e8), 8);

        vm.prank(ops);
        fund.updateAsset(address(weth), true, true);
        vm.prank(ops);
        fund.updateAsset(address(wbtc), true, true);

        // [usdc, weth, wbtc] — delist the MIDDLE one, so a bare pop would drop wbtc instead
        assertEq(fund.getApprovedAssets().length, 3);
        vm.prank(ops);
        fund.updateAsset(address(weth), false, false);

        address[] memory remaining = fund.getApprovedAssets();
        assertEq(remaining.length, 2, "one asset removed");

        bool sawUsdc;
        bool sawWbtc;
        for (uint256 i; i < remaining.length; i++) {
            if (remaining[i] == address(usdc)) sawUsdc = true;
            if (remaining[i] == address(wbtc)) sawWbtc = true;
            assertTrue(remaining[i] != address(weth), "the delisted asset is gone");
        }
        assertTrue(sawUsdc, "usdc survived");
        assertTrue(sawWbtc, "wbtc survived - a bare pop would have dropped it");
    }

    /// @notice Recorded subscription escrow ALONE blocks delisting, with no pending-request help.
    /// @dev Delisting clears the map entry, which the conversion paths and `_assetRecoverableAmount`
    ///      both read — so escrowed assets would become unsettleable and unrecoverable. The guard had
    ///      no binding test: a real pending subscription raises `_pendingRequestsCount` too, and that
    ///      separate guard reverts first, so deleting this one changed nothing observable. Planting
    ///      the escrow figure directly (slot 55, verified via `forge inspect`) with nothing pending
    ///      is what isolates it.
    function testEscrowAloneBlocksDelisting() public {
        Mock_ERC20 weth = new Mock_ERC20("WETH", 18);
        nav.registerAsset(address(weth), 18, int256(4_000 * 1e8), 8);
        vm.prank(ops);
        fund.updateAsset(address(weth), true, true);

        // Escrow recorded, but no request pending — only the escrow guard can refuse
        vm.store(address(fund), keccak256(abi.encode(address(weth), uint256(55))), bytes32(uint256(1e18)));
        assertEq(fund.subscriptionAssets(address(weth)), 1e18, "escrow recorded");

        vm.prank(ops);
        vm.expectRevert(IKpkSharesNav.InvalidArguments.selector);
        fund.updateAsset(address(weth), false, false);

        // And with the escrow cleared, the same delist succeeds — the guard is not over-broad
        vm.store(address(fund), keccak256(abi.encode(address(weth), uint256(55))), bytes32(uint256(0)));
        vm.prank(ops);
        fund.updateAsset(address(weth), false, false);
        assertFalse(fund.isApprovedAsset(address(weth)), "delist succeeds once escrow is zero");
    }

    /// @notice A live pending request ALONE blocks delisting, with no escrow help.
    /// @dev The mirror of `testEscrowAloneBlocksDelisting`, and the third time this PR has hit the
    ///      same trap: `_updateAsset`'s removal branch checks escrow first and the pending count
    ///      second, so a test using a SUBSCRIPTION trips the escrow guard and never reaches this one
    ///      — deleting it left all 794 tests green. A REDEMPTION isolates it honestly and without
    ///      `vm.store`: it escrows shares and raises `_pendingRequestsCount[asset]` while leaving
    ///      `subscriptionAssets[asset]` at zero, so only the pending-count guard can refuse.
    function testPendingRequestAloneBlocksDelisting() public {
        Mock_ERC20 weth = new Mock_ERC20("WETH", 18);
        nav.registerAsset(address(weth), 18, int256(4_000 * 1e8), 8);
        vm.prank(ops);
        fund.updateAsset(address(weth), true, true);

        _seedFund(alice, 1_000e6);

        // A redemption denominated in WETH: shares go to escrow, no WETH escrow is recorded
        vm.prank(alice);
        uint256 id = fund.requestRedemption(100e18, 1, address(weth), alice);
        assertEq(fund.subscriptionAssets(address(weth)), 0, "no asset escrow - only the count is set");

        vm.prank(ops);
        vm.expectRevert(IKpkSharesNav.InvalidArguments.selector);
        fund.updateAsset(address(weth), false, false);

        // Once the request is gone the same delist succeeds, so the guard is not over-broad.
        // Rejected against WETH specifically: the shared `_reject` helper targets the base asset,
        // and `_processRejected` filters on `request.asset`, so it would silently skip this one.
        uint256[] memory rejections = new uint256[](1);
        rejections[0] = id;
        vm.prank(ops);
        fund.processRequests(new uint256[](0), rejections, address(weth));

        vm.prank(ops);
        fund.updateAsset(address(weth), false, false);
        assertFalse(fund.isApprovedAsset(address(weth)), "delist succeeds once nothing is pending");
    }

    /// @notice The fund advertises its own interface via ERC-165.
    /// @dev Mutation testing showed `supportsInterface` could return the wrong id with every test
    ///      still green — integrators that feature-detect would silently see the wrong contract.
    function testSupportsItsOwnInterface() public view {
        assertTrue(fund.supportsInterface(type(IKpkSharesNav).interfaceId), "own interface");
        assertTrue(fund.supportsInterface(0x01ffc9a7), "ERC-165 itself");
        assertFalse(fund.supportsInterface(0xdeadbeef), "and not an arbitrary id");
    }

    /// @notice Recorded subscription escrow alone blocks a sweep, with no pending-request help.
    /// @dev The two guards in `_assetRecoverableAmount` were only ever exercised together, so
    ///      neutering the escrow one left every test green. Here the request is settled — which
    ///      clears the pending count — while `subscriptionAssets` is made non-zero directly, so only
    ///      the escrow guard can refuse.
    function testEscrowGuardAloneBlocksRecovery() public {
        // A pending subscription raises both counters; settle it so only escrow can be non-zero
        vm.prank(alice);
        uint256 id = fund.requestSubscription(1_000e6, 1, address(usdc), alice);
        assertEq(fund.subscriptionAssets(address(usdc)), 1_000e6);

        // Force the escrow figure to persist while nothing is pending
        vm.store(address(fund), keccak256(abi.encode(address(usdc), uint256(55))), bytes32(uint256(1_000e6)));
        _approve(id); // clears the pending count

        // Re-assert escrow is what the guard will see
        vm.store(address(fund), keccak256(abi.encode(address(usdc), uint256(55))), bytes32(uint256(1_000e6)));
        assertEq(fund.subscriptionAssets(address(usdc)), 1_000e6, "escrow recorded, nothing pending");

        usdc.mint(address(fund), 500e6);
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        fund.recoverAssets(assets);

        assertEq(usdc.balanceOf(address(fund)), 500e6, "escrow guard alone refused the sweep");
    }
}

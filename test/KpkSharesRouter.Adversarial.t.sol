// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {KpkSharesRouterTestBase} from "test/KpkSharesRouter.TestBase.sol";
import {KpkSharesRouter} from "src/periphery/KpkSharesRouter.sol";
import {IKpkSharesRouter} from "src/periphery/IKpkSharesRouter.sol";
import {OPERATOR} from "test/constants.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";

/// @notice A deposit asset that re-enters the router from inside `transferFrom`, modelling the fact
///         that `KpkShares` has no reentrancy guard of its own and the fund may register any token.
contract ReentrantToken is Mock_ERC20 {
    KpkSharesRouter public router;
    IKpkSharesRouter.NavAttestation internal nav;
    bytes internal navSig;
    bool public armed;

    constructor() Mock_ERC20("REE", 18) {}

    function arm(KpkSharesRouter router_, IKpkSharesRouter.NavAttestation memory nav_, bytes memory navSig_) external {
        router = router_;
        nav = nav_;
        navSig = navSig_;
        armed = true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false;
            router.subscribe(address(this), 1e18, 1, msg.sender, nav, navSig);
        }
        return super.transferFrom(from, to, amount);
    }
}

/// @notice A redemption asset that delivers less than it reports, modelling a transfer-tax token.
contract FeeOnTransferToken is Mock_ERC20 {
    constructor() Mock_ERC20("FOT", 18) {}

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        // Deliver 99%, burn the rest: the caller is told `amount` moved, the receiver sees less.
        uint256 fee = amount / 100;
        _transfer(from, to, amount - fee);
        _burn(from, fee);
        _spendAllowance(from, msg.sender, amount);
        return true;
    }
}

/// @notice Price-provenance, atomicity and reentrancy behaviour. These are the checks that carry the
///         fund's economic protection once atomic settlement voids the audited min-out guard.
contract KpkSharesRouterAdversarialTest is KpkSharesRouterTestBase {
    // ============================================================================
    // Price provenance
    // ============================================================================

    function test_subscribe_revertsWhenInvestorSignsTheirOwnPrice() public {
        // The whole point: the investor broadcasts, so they control the calldata — but not the key.
        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), 0.6e8); // self-serving low price
        bytes memory sig = _signNavWith(nav, rogueSignerPk);

        vm.prank(investor);
        vm.expectRevert(abi.encodeWithSelector(IKpkSharesRouter.InvalidNavSigner.selector, rogueSigner));
        router.subscribe(address(usdc), _usdcAmount(1000), 1, investor, nav, sig);
    }

    function test_subscribe_revertsOnTamperedPrice() public {
        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        bytes memory sig = _signNav(nav);

        nav.sharesPrice = 0.6e8; // mutate after signing

        vm.prank(investor);
        vm.expectRevert();
        router.subscribe(address(usdc), _usdcAmount(1000), 1, investor, nav, sig);
    }

    function test_subscribe_revertsOnQuoteForAnotherAsset() public {
        Mock_ERC20 dai = new Mock_ERC20("DAI", 18);

        IKpkSharesRouter.NavAttestation memory nav = _nav(address(dai), SHARES_PRICE);
        bytes memory sig = _signNav(nav);

        vm.prank(investor);
        vm.expectRevert(abi.encodeWithSelector(IKpkSharesRouter.AssetMismatch.selector, address(usdc), address(dai)));
        router.subscribe(address(usdc), _usdcAmount(1000), 1, investor, nav, sig);
    }

    function test_subscribe_revertsOnQuoteForAnotherFund() public {
        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        nav.fund = address(0xdead);
        bytes memory sig = _signNav(nav);

        vm.prank(investor);
        vm.expectRevert(
            abi.encodeWithSelector(IKpkSharesRouter.FundMismatch.selector, address(kpkSharesContract), address(0xdead))
        );
        router.subscribe(address(usdc), _usdcAmount(1000), 1, investor, nav, sig);
    }

    /// @notice The EIP-712 domain binds `verifyingContract`, so a quote signed for one router cannot be
    ///         lifted onto another router serving the same fund.
    function test_subscribe_revertsOnQuoteSignedForAnotherRouter() public {
        KpkSharesRouter other = new KpkSharesRouter(address(kpkSharesContract), admin, ops);

        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);

        // Sign against the other router's domain.
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "NavAttestation(address fund,address asset,uint256 sharesPrice,uint256 navRound,uint64 issuedAt,uint64 validUntil)"
                ),
                nav.fund,
                nav.asset,
                nav.sharesPrice,
                nav.navRound,
                nav.issuedAt,
                nav.validUntil
            )
        );
        bytes32 otherDomain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("KpkSharesRouter"),
                keccak256("1"),
                block.chainid,
                address(other)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(navSignerPk, keccak256(abi.encodePacked("\x19\x01", otherDomain, structHash)));

        vm.prank(investor);
        vm.expectRevert();
        router.subscribe(address(usdc), _usdcAmount(1000), 1, investor, nav, abi.encodePacked(r, s, v));
    }

    function test_subscribe_revertsOnExpiredQuote() public {
        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        bytes memory sig = _signNav(nav);

        skip(61); // past validUntil

        vm.prank(investor);
        vm.expectRevert(
            abi.encodeWithSelector(IKpkSharesRouter.NavAttestationExpired.selector, nav.validUntil, block.timestamp)
        );
        router.subscribe(address(usdc), _usdcAmount(1000), 1, investor, nav, sig);
    }

    function test_subscribe_revertsOnPostDatedQuote() public {
        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        nav.issuedAt = uint64(block.timestamp + 10);
        bytes memory sig = _signNav(nav);

        vm.prank(investor);
        vm.expectRevert(
            abi.encodeWithSelector(IKpkSharesRouter.NavAttestationNotYetValid.selector, nav.issuedAt, block.timestamp)
        );
        router.subscribe(address(usdc), _usdcAmount(1000), 1, investor, nav, sig);
    }

    /// @notice A signer cannot mint a longer-lived option than the fund's configuration permits.
    function test_subscribe_revertsWhenQuoteOutlivesConfiguredTtl() public {
        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        nav.validUntil = uint64(block.timestamp + MAX_NAV_TTL + 1);
        bytes memory sig = _signNav(nav);

        vm.prank(investor);
        vm.expectRevert(
            abi.encodeWithSelector(
                IKpkSharesRouter.NavTtlTooLong.selector, nav.validUntil, block.timestamp + MAX_NAV_TTL
            )
        );
        router.subscribe(address(usdc), _usdcAmount(1000), 1, investor, nav, sig);
    }

    /// @notice Rounds are monotonic, so a published strip of unexpired quotes collapses to the freshest
    ///         one — an investor cannot go back and exercise a stale favourable quote.
    function test_subscribe_revertsOnStaleNavRound() public {
        IKpkSharesRouter.NavAttestation memory older = _nav(address(usdc), SHARES_PRICE);
        bytes memory olderSig = _signNav(older);

        IKpkSharesRouter.NavAttestation memory newer = _nav(address(usdc), SHARES_PRICE);
        bytes memory newerSig = _signNav(newer);

        vm.prank(investor);
        router.subscribe(address(usdc), _usdcAmount(10), 1, investor, newer, newerSig);

        assertEq(router.lastNavRound(), newer.navRound, "round must be recorded");

        vm.prank(investor);
        vm.expectRevert(abi.encodeWithSelector(IKpkSharesRouter.StaleNavRound.selector, older.navRound, newer.navRound));
        router.subscribe(address(usdc), _usdcAmount(10), 1, investor, older, olderSig);
    }

    /// @notice `>=` on the round, so one quote can serve many investors in its window.
    function test_subscribe_sameRoundServesMultipleInvestors() public {
        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        bytes memory sig = _signNav(nav);

        vm.prank(investor);
        router.subscribe(address(usdc), _usdcAmount(10), 1, investor, nav, sig);

        vm.prank(investor2);
        router.subscribe(address(usdc), _usdcAmount(10), 1, investor2, nav, sig);

        assertGt(kpkSharesContract.balanceOf(investor2), 0, "second investor used the same quote");
    }

    function test_subscribe_revertsBelowPriceFloor() public {
        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), PRICE_FLOOR - 1);
        bytes memory sig = _signNav(nav);

        vm.prank(investor);
        vm.expectRevert(
            abi.encodeWithSelector(IKpkSharesRouter.PriceOutOfBounds.selector, PRICE_FLOOR - 1, PRICE_FLOOR, PRICE_CEIL)
        );
        router.subscribe(address(usdc), _usdcAmount(1000), 1, investor, nav, sig);
    }

    function test_subscribe_revertsAbovePriceCeil() public {
        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), PRICE_CEIL + 1);
        bytes memory sig = _signNav(nav);

        vm.prank(investor);
        vm.expectRevert(
            abi.encodeWithSelector(IKpkSharesRouter.PriceOutOfBounds.selector, PRICE_CEIL + 1, PRICE_FLOOR, PRICE_CEIL)
        );
        router.subscribe(address(usdc), _usdcAmount(1000), 1, investor, nav, sig);
    }

    function test_subscribe_revertsOutsideDeviationBand() public {
        // Establish an anchor at $1.
        _routerSubscribe(investor, _usdcAmount(10), SHARES_PRICE);
        assertEq(kpkSharesContract.getLastSettledPrice(address(usdc)), SHARES_PRICE, "anchor set");

        uint256 tooFar = 1.06e8; // 600 bps, above the configured 500
        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), tooFar);
        bytes memory sig = _signNav(nav);

        vm.prank(investor);
        vm.expectRevert(
            abi.encodeWithSelector(
                IKpkSharesRouter.PriceDeviationTooLarge.selector, tooFar, SHARES_PRICE, MAX_DEVIATION_BPS
            )
        );
        router.subscribe(address(usdc), _usdcAmount(1000), 1, investor, nav, sig);
    }

    function test_subscribe_revertsAfterNavSignerRevoked() public {
        bytes32 signerRole = router.NAV_SIGNER_ROLE();
        vm.prank(admin);
        router.revokeRole(signerRole, navSigner);

        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        bytes memory sig = _signNav(nav);

        vm.prank(investor);
        vm.expectRevert(abi.encodeWithSelector(IKpkSharesRouter.InvalidNavSigner.selector, navSigner));
        router.subscribe(address(usdc), _usdcAmount(1000), 1, investor, nav, sig);
    }

    // ============================================================================
    // Receivers
    // ============================================================================

    function test_subscribe_revertsOnForbiddenReceivers() public {
        address[4] memory forbidden = [address(0), address(router), address(kpkSharesContract), feeRecipient];

        for (uint256 i = 0; i < forbidden.length; i++) {
            IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
            bytes memory sig = _signNav(nav);

            vm.prank(investor);
            vm.expectRevert(abi.encodeWithSelector(IKpkSharesRouter.InvalidReceiver.selector, forbidden[i]));
            router.subscribe(address(usdc), _usdcAmount(10), 1, forbidden[i], nav, sig);
        }
    }

    // ============================================================================
    // Atomicity
    // ============================================================================

    /// @notice The core invariant: every reverting path must leave the fund with no new request, so no
    ///         router-created request can ever sit `PENDING` with the router recorded as its investor.
    function test_noRequestSurvivesAnyRevertingSubscribe() public {
        uint256 requestIdBefore = kpkSharesContract.requestId();

        // Bad signer.
        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        vm.prank(investor);
        vm.expectRevert();
        router.subscribe(address(usdc), _usdcAmount(10), 1, investor, nav, _signNavWith(nav, rogueSignerPk));
        assertEq(kpkSharesContract.requestId(), requestIdBefore, "bad signer left a request");

        // Price out of bounds.
        IKpkSharesRouter.NavAttestation memory low = _nav(address(usdc), PRICE_FLOOR - 1);
        vm.prank(investor);
        vm.expectRevert();
        router.subscribe(address(usdc), _usdcAmount(10), 1, investor, low, _signNav(low));
        assertEq(kpkSharesContract.requestId(), requestIdBefore, "bad price left a request");

        // Caller's own bound unmet.
        IKpkSharesRouter.NavAttestation memory ok = _nav(address(usdc), SHARES_PRICE);
        vm.prank(investor);
        vm.expectRevert();
        router.subscribe(address(usdc), _usdcAmount(10), type(uint256).max, investor, ok, _signNav(ok));
        assertEq(kpkSharesContract.requestId(), requestIdBefore, "unmet minimum left a request");

        // Per-transaction cap.
        IKpkSharesRouter.NavAttestation memory big = _nav(address(usdc), SHARES_PRICE);
        vm.prank(investor);
        vm.expectRevert();
        router.subscribe(address(usdc), _usdcAmount(2_000_000), 1, investor, big, _signNav(big));
        assertEq(kpkSharesContract.requestId(), requestIdBefore, "capped size left a request");

        assertEq(usdc.balanceOf(address(router)), 0, "router must hold nothing");
    }

    /// @notice With `OPERATOR` revoked the router cannot settle, so the request it just created must be
    ///         unwound rather than orphaned with the router as its investor.
    function test_subscribe_revertsWhenOperatorRoleRevoked() public {
        vm.prank(admin);
        kpkSharesContract.revokeRole(OPERATOR, address(router));

        uint256 requestIdBefore = kpkSharesContract.requestId();
        uint256 investorBalanceBefore = usdc.balanceOf(investor);

        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        bytes memory sig = _signNav(nav);

        vm.prank(investor);
        vm.expectRevert();
        router.subscribe(address(usdc), _usdcAmount(1000), 1, investor, nav, sig);

        assertEq(kpkSharesContract.requestId(), requestIdBefore, "no orphaned request");
        assertEq(usdc.balanceOf(investor), investorBalanceBefore, "investor keeps their assets");
        assertEq(usdc.balanceOf(address(router)), 0, "router holds nothing");
    }

    // ============================================================================
    // Reentrancy
    // ============================================================================

    function test_subscribe_revertsOnReentrantAsset() public {
        ReentrantToken evil = new ReentrantToken();
        evil.mint(investor, 1_000_000e18);

        vm.prank(ops);
        kpkSharesContract.updateAsset(address(evil), false, true, true);

        IKpkSharesRouter.AssetConfig memory config = _defaultConfig();
        config.maxAssetsInPerTx = 1_000_000e18;
        vm.prank(admin);
        router.setAssetConfig(address(evil), config);

        vm.prank(investor);
        evil.approve(address(router), type(uint256).max);

        IKpkSharesRouter.NavAttestation memory nav = _nav(address(evil), SHARES_PRICE);
        bytes memory sig = _signNav(nav);

        evil.arm(router, nav, sig);

        vm.prank(investor);
        vm.expectRevert(); // ReentrancyGuardReentrantCall bubbles up through the token
        router.subscribe(address(evil), 1000e18, 1, investor, nav, sig);

        assertEq(kpkSharesContract.balanceOf(investor), 0, "no shares minted");
    }

    // ============================================================================
    // Performance-fee boundary guard
    // ============================================================================

    /// @notice `_chargeFees` mints fee shares before the subscriber is priced, so a large uncharged
    ///         performance fee would misprice whichever investor happens to cross the fund's six-hour
    ///         gate. The router refuses rather than silently concentrating that cost on one person.
    function test_subscribe_revertsWhenPerformanceFeeDilutionIsMaterial() public {
        _seedPerformanceWatermark(kpkSharesContract, alice);

        IKpkSharesRouter.AssetConfig memory config = _defaultConfig();
        config.maxFeeDilutionBps = 10;
        vm.prank(admin);
        router.setAssetConfig(address(usdc), config);

        skip(7 hours);

        uint256 price = 1.02e8; // ~200 bps above the watermark: ~196 bps of dilution at a 10% fee rate
        (uint256 feeShares, bool blocking) = router.previewPendingPerformanceFee(address(usdc), price);
        assertTrue(blocking, "precondition: this dilution must exceed the tolerance");

        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), price);
        bytes memory sig = _signNav(nav);

        vm.prank(investor);
        vm.expectRevert(abi.encodeWithSelector(IKpkSharesRouter.FeeSettlementRequired.selector, feeShares, uint16(10)));
        router.subscribe(address(usdc), _usdcAmount(1000), 1, investor, nav, sig);
    }

    function test_previewPendingPerformanceFee_isZeroBelowWatermark() public {
        _seedPerformanceWatermark(kpkSharesContract, alice);

        (uint256 feeShares, bool blocking) = router.previewPendingPerformanceFee(address(usdc), SHARES_PRICE - 1);

        assertEq(feeShares, 0, "no fee below the watermark");
        assertFalse(blocking, "must not block");
    }

    // ============================================================================
    // Review regressions
    // ============================================================================

    /// @notice `maxNavTtl` must bound the AGE of the price, not merely the quote's remaining life.
    ///         Without the `issuedAt` check a week-old quote settles during its final `maxNavTtl`
    ///         seconds — the forward bound alone passes.
    function test_subscribe_revertsOnStalePriceInsideItsFinalWindow() public {
        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        nav.validUntil = uint64(block.timestamp + 7 days);
        bytes memory sig = _signNav(nav);

        // Land inside the last 30s of a week-long quote: `validUntil <= now + maxNavTtl` now holds,
        // so only the age check can reject this.
        vm.warp(nav.validUntil - 30);

        assertLe(nav.validUntil, block.timestamp + MAX_NAV_TTL, "precondition: forward TTL bound passes");

        vm.prank(investor);
        vm.expectRevert(
            abi.encodeWithSelector(IKpkSharesRouter.NavQuoteTooOld.selector, nav.issuedAt, block.timestamp, MAX_NAV_TTL)
        );
        router.subscribe(address(usdc), _usdcAmount(1000), 1, investor, nav, sig);
    }

    function test_subscribe_acceptsQuoteAtTheEdgeOfMaxAge() public {
        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        nav.validUntil = uint64(block.timestamp + MAX_NAV_TTL);
        bytes memory sig = _signNav(nav);

        skip(MAX_NAV_TTL); // age == maxNavTtl exactly, still inside the bound

        vm.prank(investor);
        (, uint256 sharesOut) = router.subscribe(address(usdc), _usdcAmount(10), 1, investor, nav, sig);
        assertGt(sharesOut, 0, "a quote exactly at max age must still settle");
    }

    /// @notice The round counter is router-wide. Keyed per asset, a superseded quote stayed live on any
    ///         sibling asset that had not transacted, defeating the anti-cherry-pick guard — the price
    ///         is fund-wide, so the asset only selects decimals.
    /// @dev Registers a second 18-decimal deposit asset on the fund and configures it on the router.
    function _enableSecondAsset() internal returns (Mock_ERC20 dai) {
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
    }

    function test_navRoundIsRetiredAcrossAllAssets() public {
        Mock_ERC20 dai = _enableSecondAsset();

        IKpkSharesRouter.NavAttestation memory oldDaiQuote = _nav(address(dai), SHARES_PRICE);
        bytes memory oldDaiSig = _signNav(oldDaiQuote);

        // Settle a NEWER round on USDC.
        IKpkSharesRouter.NavAttestation memory newer = _nav(address(usdc), SHARES_PRICE);
        vm.prank(investor);
        router.subscribe(address(usdc), _usdcAmount(10), 1, investor, newer, _signNav(newer));

        // The older DAI quote must now be dead too.
        vm.prank(investor);
        vm.expectRevert(
            abi.encodeWithSelector(IKpkSharesRouter.StaleNavRound.selector, oldDaiQuote.navRound, newer.navRound)
        );
        router.subscribe(address(dai), 1000e18, 1, investor, oldDaiQuote, oldDaiSig);
    }

    /// @notice The portfolio Safe is forbidden on the SUBSCRIBE path too, matching the interface's
    ///         documented forbidden set. Minting there creates self-referential treasury shares that an
    ///         off-chain NAV service valuing the Safe's holdings could double-count.
    function test_subscribe_revertsWhenReceiverIsPortfolioSafe() public {
        address portfolioSafe = kpkSharesContract.portfolioSafe();

        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        bytes memory sig = _signNav(nav);

        vm.prank(investor);
        vm.expectRevert(abi.encodeWithSelector(IKpkSharesRouter.InvalidReceiver.selector, portfolioSafe));
        router.subscribe(address(usdc), _usdcAmount(1000), 1, portfolioSafe, nav, sig);
    }

    /// @notice A redemption asset that under-delivers must fail closed. The fund only ever compares
    ///         numbers it computed itself, so the router's realised-balance check is the only thing
    ///         standing between a transfer-tax token and a silently short-paid redeemer.
    function test_redeem_revertsWhenAssetDeliversLessThanReported() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        fot.mint(safe, 1_000_000e18);

        vm.prank(ops);
        kpkSharesContract.updateAsset(address(fot), false, true, true);

        IKpkSharesRouter.AssetConfig memory config = _defaultConfig();
        config.maxAssetsOutPerDay = 1_000_000e18;
        vm.prank(admin);
        router.setAssetConfig(address(fot), config);

        vm.prank(safe);
        fot.approve(address(kpkSharesContract), type(uint256).max);

        // Give the investor shares and let the router spend them.
        _routerSubscribeAndApproveShares(investor, _usdcAmount(1000), SHARES_PRICE);

        IKpkSharesRouter.RedemptionIntent memory intent = _intent(investor, address(fot), _sharesAmount(100), 1);
        bytes memory intentSig = _signIntent(intent, investorPk);
        IKpkSharesRouter.NavAttestation memory nav = _nav(address(fot), SHARES_PRICE);
        bytes memory navSig = _signNav(nav);

        uint256 sharesBefore = kpkSharesContract.balanceOf(investor);

        vm.prank(bot);
        vm.expectRevert(); // InsufficientOutput: delivered < assetsOut
        router.redeem(intent, intentSig, nav, navSig);

        assertEq(kpkSharesContract.balanceOf(investor), sharesBefore, "owner keeps their shares");
    }

    function test_subscribe_succeedsWhenFeeDilutionWithinTolerance() public {
        _seedPerformanceWatermark(kpkSharesContract, alice);
        skip(7 hours);

        // 10 bps above the watermark is ~1 bp of dilution, well inside the 50 bps default.
        (, bool blocking) = router.previewPendingPerformanceFee(address(usdc), 1.001e8);
        assertFalse(blocking, "precondition: tolerable");

        (, uint256 sharesOut) = _routerSubscribe(investor, _usdcAmount(1000), 1.001e8);
        assertGt(sharesOut, 0, "settlement must proceed");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {KpkSharesRouterTestBase} from "test/KpkSharesRouter.TestBase.sol";
import {KpkSharesRouter} from "src/periphery/KpkSharesRouter.sol";
import {IKpkSharesRouter} from "src/periphery/IKpkSharesRouter.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {DEFAULT_ADMIN_ROLE} from "test/constants.sol";

/// @notice Configuration, volume budgets, pausing, rescue paths and the deployment guards.
contract KpkSharesRouterAdminTest is KpkSharesRouterTestBase {
    // ============================================================================
    // Construction
    // ============================================================================

    function test_constructor_revertsOnZeroAddresses() public {
        vm.expectRevert(IKpkSharesRouter.ZeroAddress.selector);
        new KpkSharesRouter(address(0), admin, ops);

        vm.expectRevert(IKpkSharesRouter.ZeroAddress.selector);
        new KpkSharesRouter(address(kpkSharesContract), address(0), ops);

        vm.expectRevert(IKpkSharesRouter.ZeroAddress.selector);
        new KpkSharesRouter(address(kpkSharesContract), admin, address(0));
    }

    function test_constructor_wiresFundAndRoles() public view {
        assertEq(router.SHARES(), address(kpkSharesContract), "fund bound immutably");
        assertTrue(router.hasRole(DEFAULT_ADMIN_ROLE, admin), "admin role granted");
        assertTrue(router.hasRole(router.GUARDIAN_ROLE(), ops), "guardian role granted");
    }

    function test_domainSeparatorMatchesLocallyComputedValue() public view {
        assertEq(router.DOMAIN_SEPARATOR(), _domainSeparator(), "EIP-712 domain must be stable");
    }

    // ============================================================================
    // Asset configuration
    // ============================================================================

    function test_setAssetConfig_onlyAdmin() public {
        IKpkSharesRouter.AssetConfig memory config = _defaultConfig();

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bob, DEFAULT_ADMIN_ROLE)
        );
        router.setAssetConfig(address(usdc), config);
    }

    function test_setAssetConfig_revertsOnZeroAsset() public {
        IKpkSharesRouter.AssetConfig memory config = _defaultConfig();

        vm.prank(admin);
        vm.expectRevert(IKpkSharesRouter.ZeroAddress.selector);
        router.setAssetConfig(address(0), config);
    }

    /// @dev An enabled asset must be fully bounded. Leaving a limit at zero would either brick the
    ///      asset or, for the price bounds, remove the only constraint that does not track a value an
    ///      operator can walk.
    function test_setAssetConfig_rejectsIncompleteEnabledConfigs() public {
        vm.startPrank(admin);

        IKpkSharesRouter.AssetConfig memory config = _defaultConfig();
        config.maxNavTtl = 0;
        vm.expectRevert(IKpkSharesRouter.InvalidAmount.selector);
        router.setAssetConfig(address(usdc), config);

        config = _defaultConfig();
        config.maxDeviationBps = 0;
        vm.expectRevert(IKpkSharesRouter.InvalidAmount.selector);
        router.setAssetConfig(address(usdc), config);

        config = _defaultConfig();
        config.priceFloor = 0;
        vm.expectRevert(IKpkSharesRouter.InvalidAmount.selector);
        router.setAssetConfig(address(usdc), config);

        config = _defaultConfig();
        config.priceCeil = config.priceFloor - 1;
        vm.expectRevert(IKpkSharesRouter.InvalidAmount.selector);
        router.setAssetConfig(address(usdc), config);

        config = _defaultConfig();
        config.maxAssetsInPerTx = 0;
        vm.expectRevert(IKpkSharesRouter.InvalidAmount.selector);
        router.setAssetConfig(address(usdc), config);

        config = _defaultConfig();
        config.maxSharesMintedPerDay = 0;
        vm.expectRevert(IKpkSharesRouter.InvalidAmount.selector);
        router.setAssetConfig(address(usdc), config);

        config = _defaultConfig();
        config.maxSharesInPerTx = 0;
        vm.expectRevert(IKpkSharesRouter.InvalidAmount.selector);
        router.setAssetConfig(address(usdc), config);

        config = _defaultConfig();
        config.maxAssetsOutPerDay = 0;
        vm.expectRevert(IKpkSharesRouter.InvalidAmount.selector);
        router.setAssetConfig(address(usdc), config);

        vm.stopPrank();
    }

    /// @notice An all-zero config is the disable switch, so it must be accepted.
    function test_setAssetConfig_acceptsFullyDisabledConfig() public {
        IKpkSharesRouter.AssetConfig memory off;

        vm.prank(admin);
        router.setAssetConfig(address(usdc), off);

        assertFalse(router.assetConfig(address(usdc)).subscribeEnabled, "subscribe disabled");

        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        bytes memory sig = _signNav(nav);

        vm.prank(investor);
        vm.expectRevert(abi.encodeWithSelector(IKpkSharesRouter.AssetNotEnabled.selector, address(usdc)));
        router.subscribe(address(usdc), _usdcAmount(10), 1, investor, nav, sig);
    }

    function test_setAssetConfig_disablingRedeemBlocksRedemption() public {
        _routerSubscribeAndApproveShares(investor, _usdcAmount(1000), SHARES_PRICE);

        IKpkSharesRouter.AssetConfig memory config = _defaultConfig();
        config.redeemEnabled = false;
        vm.prank(admin);
        router.setAssetConfig(address(usdc), config);

        IKpkSharesRouter.RedemptionIntent memory intent = _intent(investor, address(usdc), _sharesAmount(10), 1);
        bytes memory intentSig = _signIntent(intent, investorPk);
        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        bytes memory navSig = _signNav(nav);

        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(IKpkSharesRouter.AssetNotEnabled.selector, address(usdc)));
        router.redeem(intent, intentSig, nav, navSig);
    }

    // ============================================================================
    // Volume budgets
    // ============================================================================

    function test_subscribe_revertsAbovePerTxCap() public {
        IKpkSharesRouter.AssetConfig memory config = _defaultConfig();
        config.maxAssetsInPerTx = _usdcAmount(100);
        vm.prank(admin);
        router.setAssetConfig(address(usdc), config);

        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        bytes memory sig = _signNav(nav);

        vm.prank(investor);
        vm.expectRevert(
            abi.encodeWithSelector(IKpkSharesRouter.PerTxCapExceeded.selector, _usdcAmount(101), _usdcAmount(100))
        );
        router.subscribe(address(usdc), _usdcAmount(101), 1, investor, nav, sig);
    }

    function test_subscribe_dailyMintBudgetIsEnforcedAndRollsOver() public {
        IKpkSharesRouter.AssetConfig memory config = _defaultConfig();
        config.maxSharesMintedPerDay = _sharesAmount(150);
        vm.prank(admin);
        router.setAssetConfig(address(usdc), config);

        // 100 shares fit.
        _routerSubscribe(investor, _usdcAmount(100), SHARES_PRICE);

        (uint256 mintable,) = router.remainingDailyBudget(address(usdc));
        assertEq(mintable, _sharesAmount(50), "budget must decrement");

        // Another 100 does not.
        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        bytes memory sig = _signNav(nav);
        vm.prank(investor);
        vm.expectRevert(
            abi.encodeWithSelector(IKpkSharesRouter.DailyCapExceeded.selector, _sharesAmount(100), _sharesAmount(50))
        );
        router.subscribe(address(usdc), _usdcAmount(100), 1, investor, nav, sig);

        // Next UTC day, the budget is fresh.
        skip(1 days);
        (uint256 mintableNextDay,) = router.remainingDailyBudget(address(usdc));
        assertEq(mintableNextDay, _sharesAmount(150), "budget must roll over");

        _routerSubscribe(investor, _usdcAmount(100), SHARES_PRICE);
    }

    function test_redeem_dailyPayoutBudgetIsEnforced() public {
        _routerSubscribeAndApproveShares(investor, _usdcAmount(1000), SHARES_PRICE);

        IKpkSharesRouter.AssetConfig memory config = _defaultConfig();
        config.maxAssetsOutPerDay = _usdcAmount(10);
        vm.prank(admin);
        router.setAssetConfig(address(usdc), config);

        IKpkSharesRouter.RedemptionIntent memory intent = _intent(investor, address(usdc), _sharesAmount(100), 1);
        bytes memory intentSig = _signIntent(intent, investorPk);
        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        bytes memory navSig = _signNav(nav);

        vm.prank(bot);
        vm.expectRevert();
        router.redeem(intent, intentSig, nav, navSig);
    }

    // ============================================================================
    // Pausing
    // ============================================================================

    function test_pause_blocksBothEntryPoints() public {
        _routerSubscribeAndApproveShares(investor, _usdcAmount(1000), SHARES_PRICE);

        vm.prank(ops);
        router.pause();

        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), SHARES_PRICE);
        bytes memory sig = _signNav(nav);

        vm.prank(investor);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        router.subscribe(address(usdc), _usdcAmount(10), 1, investor, nav, sig);

        IKpkSharesRouter.RedemptionIntent memory intent = _intent(investor, address(usdc), _sharesAmount(10), 1);
        bytes memory intentSig = _signIntent(intent, investorPk);

        vm.prank(bot);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        router.redeem(intent, intentSig, nav, sig);
    }

    function test_pause_onlyGuardian() public {
        bytes32 guardianRole = router.GUARDIAN_ROLE();

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bob, guardianRole)
        );
        router.pause();
    }

    /// @notice Unpausing is admin-only, deliberately slower than pausing.
    function test_unpause_onlyAdminNotGuardian() public {
        vm.prank(ops);
        router.pause();

        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ops, DEFAULT_ADMIN_ROLE)
        );
        router.unpause();

        vm.prank(admin);
        router.unpause();

        _routerSubscribe(investor, _usdcAmount(10), SHARES_PRICE);
    }

    // ============================================================================
    // Rescue paths
    // ============================================================================

    function test_rescue_onlyAdminAndForwardsFunds() public {
        usdc.mint(address(router), _usdcAmount(42));

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bob, DEFAULT_ADMIN_ROLE)
        );
        router.rescue(address(usdc), bob, _usdcAmount(42));

        uint256 before = usdc.balanceOf(carol);
        vm.prank(admin);
        router.rescue(address(usdc), carol, _usdcAmount(42));

        assertEq(usdc.balanceOf(carol) - before, _usdcAmount(42), "stranded funds forwarded");
        assertEq(usdc.balanceOf(address(router)), 0, "router emptied");
    }

    function test_rescue_revertsOnZeroDestination() public {
        vm.prank(admin);
        vm.expectRevert(IKpkSharesRouter.ZeroAddress.selector);
        router.rescue(address(usdc), address(0), 1);
    }

    function test_revokeSharesAllowance_zeroesAllowance() public {
        // Force a standing allowance, then clear it.
        vm.prank(address(router));
        usdc.approve(address(kpkSharesContract), 1000);
        assertEq(usdc.allowance(address(router), address(kpkSharesContract)), 1000, "precondition");

        vm.prank(admin);
        router.revokeSharesAllowance(address(usdc));

        assertEq(usdc.allowance(address(router), address(kpkSharesContract)), 0, "allowance cleared");
    }

    /// @notice Unreachable against the current shares implementation — the atomicity invariant reverts
    ///         instead — but retained because each fund's implementation is independently upgradeable.
    ///         Forced here by creating a request directly as the router.
    function test_emergencyCancelSubscription_refundsToNamedAddress() public {
        uint256 amount = _usdcAmount(500);
        usdc.mint(address(router), amount);

        vm.startPrank(address(router));
        usdc.approve(address(kpkSharesContract), amount);
        uint256 requestId = kpkSharesContract.requestSubscription(amount, 1, address(usdc), investor);
        vm.stopPrank();

        skip(SUBSCRIPTION_REQUEST_TTL + 1);

        uint256 before = usdc.balanceOf(carol);
        vm.prank(admin);
        router.emergencyCancelSubscription(requestId, carol);

        assertEq(usdc.balanceOf(carol) - before, amount, "refund forwarded to the named address");
        assertEq(usdc.balanceOf(address(router)), 0, "router emptied");
    }

    function test_emergencyCancelRedemption_returnsSharesToNamedAddress() public {
        uint256 shares = _routerSubscribeAndApproveShares(investor, _usdcAmount(1000), SHARES_PRICE);

        // Move shares onto the router and open a redemption as the router.
        vm.prank(investor);
        kpkSharesContract.transfer(address(router), shares);

        vm.prank(address(router));
        uint256 requestId = kpkSharesContract.requestRedemption(shares, 1, address(usdc), investor);

        skip(REDEMPTION_REQUEST_TTL + 1);

        vm.prank(admin);
        router.emergencyCancelRedemption(requestId, carol);

        assertEq(kpkSharesContract.balanceOf(carol), shares, "shares returned to the named address");
        assertEq(kpkSharesContract.balanceOf(address(router)), 0, "router emptied");
    }

    function test_emergencyCancel_onlyAdmin() public {
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bob, DEFAULT_ADMIN_ROLE)
        );
        router.emergencyCancelSubscription(1, carol);
    }

    // ============================================================================
    // Review regressions
    // ============================================================================

    /// @notice `lastNavRound` is the only irreversible state in the contract and ratchets from an
    ///         unbounded `uint256` carried in a signed quote. One absurd round would otherwise brick
    ///         settlement permanently — the router is non-upgradeable and rotating the signer key does
    ///         not help, because the check is on the round, not the key.
    function test_resetNavRound_recoversFromAnExhaustedRound() public {
        IKpkSharesRouter.NavAttestation memory poison = _nav(address(usdc), SHARES_PRICE);
        poison.navRound = type(uint256).max;

        vm.prank(investor);
        router.subscribe(address(usdc), _usdcAmount(1), 1, investor, poison, _signNav(poison));
        assertEq(router.lastNavRound(), type(uint256).max, "counter is exhausted");

        // Rotating the signing key does not help: the block is on the round.
        bytes32 signerRole = router.NAV_SIGNER_ROLE();
        (address freshSigner, uint256 freshPk) = makeAddrAndKey("freshNavSigner");
        vm.startPrank(admin);
        router.revokeRole(signerRole, navSigner);
        router.grantRole(signerRole, freshSigner);
        vm.stopPrank();

        IKpkSharesRouter.NavAttestation memory normal = _nav(address(usdc), SHARES_PRICE);
        vm.prank(investor);
        vm.expectRevert(
            abi.encodeWithSelector(IKpkSharesRouter.StaleNavRound.selector, normal.navRound, type(uint256).max)
        );
        router.subscribe(address(usdc), _usdcAmount(10), 1, investor, normal, _signNavWith(normal, freshPk));

        // The admin lever restores service.
        vm.prank(admin);
        router.resetNavRound(normal.navRound - 1);
        assertEq(router.lastNavRound(), normal.navRound - 1, "counter rewound");

        vm.prank(investor);
        (, uint256 sharesOut) =
            router.subscribe(address(usdc), _usdcAmount(10), 1, investor, normal, _signNavWith(normal, freshPk));
        assertGt(sharesOut, 0, "settlement resumes after the reset");
    }

    function test_resetNavRound_onlyAdmin() public {
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bob, DEFAULT_ADMIN_ROLE)
        );
        router.resetNavRound(1);
    }

    /// @notice `KpkShares` authorises cancellation by investor OR receiver, so anyone can name the
    ///         router as their receiver and thereby make it an authorised canceller of their request.
    ///         The admin must not be able to reach a request the router did not create.
    function test_emergencyCancelSubscription_rejectsThirdPartyRequest() public {
        // A stranger opens a request directly on the fund, naming the router as receiver.
        vm.prank(alice);
        uint256 strangerId = kpkSharesContract.requestSubscription(_usdcAmount(100), 1, address(usdc), address(router));

        skip(SUBSCRIPTION_REQUEST_TTL + 1);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IKpkSharesRouter.NotRouterRequest.selector, strangerId, alice));
        router.emergencyCancelSubscription(strangerId, carol);
    }

    // ============================================================================
    // Fuzz
    // ============================================================================

    /// @notice Across the whole configured price band and a wide size range, the settled share count is
    ///         exactly the quoted conversion and the router retains nothing.
    function testFuzz_subscribeMintsExactlyPreviewedShares(uint96 rawAssets, uint64 rawPrice) public {
        uint256 assetsIn = bound(uint256(rawAssets), _usdcAmount(1), _usdcAmount(500_000));
        uint256 price = bound(uint256(rawPrice), PRICE_FLOOR, PRICE_CEIL);

        uint256 expected = kpkSharesContract.assetsToShares(assetsIn, price, address(usdc));
        vm.assume(expected > 0);

        (, uint256 sharesOut) = _routerSubscribe(investor, assetsIn, price);

        assertEq(sharesOut, expected, "settled shares must equal the quoted conversion");
        assertEq(kpkSharesContract.balanceOf(investor), expected, "receiver holds exactly that");
        assertEq(usdc.balanceOf(address(router)), 0, "router holds no assets");
        assertEq(kpkSharesContract.balanceOf(address(router)), 0, "router holds no shares");
    }
}

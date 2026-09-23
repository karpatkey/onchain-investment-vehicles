// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {kpkSharesNavTestBase} from "./kpkSharesNav.TestBase.sol";
import {IKpkSharesNav} from "../src/IKpkSharesNav.sol";
import {KpkSharesNav} from "../src/KpkSharesNav.sol";

/// @notice A minimal V2 that adds behaviour without touching the layout.
/// @dev Deliberately declares NO new storage: this suite is about proving the EXISTING state
///      survives an upgrade, so a V2 that shifted anything would test the wrong thing. A real V2
///      adding state must consume the trailing `__gap`, which the layout test below pins.
contract KpkSharesNavV2 is KpkSharesNav {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @title kpkSharesNavUpgradeTest
/// @notice The first UUPS upgrade of a live fund.
/// @dev There was no upgrade coverage for this contract at all — `test/kpkShares.Upgrade.sol` covers
///      only the frozen sibling — and every deploy path uses `UnsafeUpgrades`, which skips OpenZeppelin's
///      layout validation. So nothing would have caught a reordered base or an inserted
///      non-namespaced parent silently moving `RecoverFunds`'s 50 reserved slots underneath live
///      escrow. These tests are that check.
contract kpkSharesNavUpgradeTest is kpkSharesNavTestBase {
    /// @dev Slot numbers verified with `forge inspect KpkSharesNav storageLayout`. They are pinned
    ///      here on purpose: if an upgrade shifts them, escrow and request bookkeeping silently
    ///      point at the wrong words, and no other test in this repo would notice.
    uint256 internal constant SLOT_REQUEST_ID = 52;
    uint256 internal constant SLOT_PORTFOLIO_SAFE = 53;
    uint256 internal constant SLOT_SUBSCRIPTION_ASSETS = 55;
    uint256 internal constant SLOT_NAV_CALCULATOR = 65;
    uint256 internal constant SLOT_INITIAL_SHARE_PRICE = 66;
    uint256 internal constant SLOT_LAST_SHARE_PRICE = 67;

    /// @notice Puts the fund into a rich live state: shares out, escrow held both ways, a settled
    ///         price on record and a pending request of each kind.
    function _makeLive() internal returns (uint256 pendingSub, uint256 pendingRedeem) {
        _seedFund(alice, 1_000e6);

        vm.prank(bob);
        pendingSub = fund.requestSubscription(500e6, 1, address(usdc), bob);

        vm.prank(alice);
        pendingRedeem = fund.requestRedemption(200e18, 1, address(usdc), alice);
    }

    function testUpgradePreservesLiveState() public {
        (uint256 pendingSub, uint256 pendingRedeem) = _makeLive();

        uint256 supplyBefore = fund.totalSupply();
        uint256 aliceBefore = fund.balanceOf(alice);
        uint256 escrowBefore = fund.subscriptionAssets(address(usdc));
        uint256 shareEscrowBefore = fund.balanceOf(address(fund));
        uint256 requestIdBefore = fund.requestId();
        uint256 lastPriceBefore = fund.lastSharePriceUsd();
        address navBefore = fund.navCalculator();

        address v2 = address(new KpkSharesNavV2());
        vm.prank(admin);
        fund.upgradeToAndCall(v2, "");

        assertEq(KpkSharesNavV2(address(fund)).version(), 2, "new behaviour is live");

        assertEq(fund.totalSupply(), supplyBefore, "supply");
        assertEq(fund.balanceOf(alice), aliceBefore, "holder balance");
        assertEq(fund.subscriptionAssets(address(usdc)), escrowBefore, "asset escrow");
        assertEq(fund.balanceOf(address(fund)), shareEscrowBefore, "share escrow");
        assertEq(fund.requestId(), requestIdBefore, "request counter");
        assertEq(fund.lastSharePriceUsd(), lastPriceBefore, "recorded price");
        assertEq(fund.navCalculator(), navBefore, "NAV calculator");
        assertEq(fund.portfolioSafe(), safe, "portfolio safe");
        assertEq(fund.initialSharePrice(), ONE_USD, "bootstrap price");

        // The pending requests still describe what they described
        assertEq(uint8(fund.getRequest(pendingSub).requestStatus), uint8(IKpkSharesNav.RequestStatus.PENDING));
        assertEq(fund.getRequest(pendingSub).investor, bob);
        assertEq(fund.getRequest(pendingSub).assetAmount, 500e6);
        assertEq(uint8(fund.getRequest(pendingRedeem).requestStatus), uint8(IKpkSharesNav.RequestStatus.PENDING));
        assertEq(fund.getRequest(pendingRedeem).sharesAmount, 200e18);
    }

    /// @notice The fund still settles, and still refuses to sweep escrow, after an upgrade.
    /// @dev State surviving is necessary but not sufficient — the point is that the upgraded
    ///      implementation can still operate on it.
    function testUpgradedFundStillSettlesAndStillGuardsEscrow() public {
        (uint256 pendingSub, uint256 pendingRedeem) = _makeLive();

        address v2 = address(new KpkSharesNavV2());
        vm.prank(admin);
        fund.upgradeToAndCall(v2, "");

        // A batch settles normally
        uint256 bobBefore = fund.balanceOf(bob);
        _approve(pendingSub);
        assertEq(fund.balanceOf(bob) - bobBefore, 500e18, "subscription settled at $1.00");

        // Escrow guards still hold
        address[] memory assets = new address[](1);
        assets[0] = address(fund);
        fund.recoverAssets(assets);
        assertEq(fund.balanceOf(address(fund)), 200e18, "share escrow still unsweepable");

        // And the surviving redemption still settles. Note the price is no longer $1.00: the mock's
        // NAV is a fixed scalar, so settling the subscription above added shares without adding NAV.
        // That is a property of the fixture, not the fund — so assert against the live price rather
        // than a constant.
        uint256 expected = fund.previewRedemption(200e18, address(usdc));
        uint256 aliceAssets = usdc.balanceOf(alice);
        _approve(pendingRedeem);
        assertEq(usdc.balanceOf(alice) - aliceAssets, expected, "redemption settled at the live price");
        assertGt(expected, 0, "and it actually paid out");
    }

    /// @notice Only the admin may upgrade.
    function testUpgradeIsAdminOnly() public {
        address v2 = address(new KpkSharesNavV2());

        vm.prank(ops);
        vm.expectRevert(IKpkSharesNav.NotAuthorized.selector);
        fund.upgradeToAndCall(v2, "");

        vm.prank(alice);
        vm.expectRevert(IKpkSharesNav.NotAuthorized.selector);
        fund.upgradeToAndCall(v2, "");
    }

    /// @notice Pins the storage slots the fund's own variables occupy.
    /// @dev Reads raw slots and checks they hold what the getters report. `RecoverFunds` contributes
    ///      a 50-slot gap ahead of these, and the OpenZeppelin v5 bases are ERC-7201 namespaced and
    ///      contribute none — so slot 50 onward belongs to this contract. Reordering the inheritance
    ///      list or inserting a non-namespaced base would break this test, which is the entire point.
    function testStorageSlotsAreWhereWeThinkTheyAre() public {
        _seedFund(alice, 1_000e6);
        vm.prank(bob);
        fund.requestSubscription(500e6, 1, address(usdc), bob);

        assertEq(uint256(vm.load(address(fund), bytes32(SLOT_REQUEST_ID))), fund.requestId(), "slot 52 = requestId");
        assertEq(
            address(uint160(uint256(vm.load(address(fund), bytes32(SLOT_PORTFOLIO_SAFE))))),
            fund.portfolioSafe(),
            "slot 53 = portfolioSafe"
        );
        assertEq(
            uint256(vm.load(address(fund), keccak256(abi.encode(address(usdc), SLOT_SUBSCRIPTION_ASSETS)))),
            fund.subscriptionAssets(address(usdc)),
            "slot 55 = subscriptionAssets mapping"
        );
        // navCalculator shares slot 65 with syncDepositsEnabled and lastPricedAt, so mask the address
        assertEq(
            address(uint160(uint256(vm.load(address(fund), bytes32(SLOT_NAV_CALCULATOR))))),
            fund.navCalculator(),
            "slot 65 = navCalculator"
        );
        assertEq(
            uint256(vm.load(address(fund), bytes32(SLOT_INITIAL_SHARE_PRICE))),
            fund.initialSharePrice(),
            "slot 66 = initialSharePrice"
        );
        assertEq(
            uint256(vm.load(address(fund), bytes32(SLOT_LAST_SHARE_PRICE))),
            fund.lastSharePriceUsd(),
            "slot 67 = lastSharePriceUsd"
        );
    }

    /// @notice The trailing gap is still reserved and untouched.
    /// @dev A V2 that adds state must take it from here. If these are ever non-zero on a fresh fund,
    ///      something upstream has grown into the reservation.
    function testTrailingGapIsUntouched() public view {
        for (uint256 i = 68; i < 118; i++) {
            assertEq(uint256(vm.load(address(fund), bytes32(i))), 0, "reserved gap slot is clean");
        }
    }
}

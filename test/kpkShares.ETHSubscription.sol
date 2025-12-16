// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./kpkShares.TestBase.sol";
import "src/IkpkShares.sol";

/// @notice Tests for kpkShares ETH subscription and USDC redemption scenarios
contract kpkSharesETHSubscriptionTest is kpkSharesTestBase {
    // Mock ETH token for testing
    Mock_ERC20 public mockETH;

    // ETH price in USD (8 decimals like other price oracles)
    uint256 private constant _ETH_PRICE_USD = 3500; // $3500.00

    // Amount of ETH to subscribe (10 ETH)
    uint256 private constant _ETH_SUBSCRIPTION_AMOUNT = 10 ether; // 10 ETH in 18 decimals

    // Share price in ETH units (calculated as: SHARES_PRICE * 1e18 / ETH_PRICE_USD)
    // This represents how much ETH is needed to buy 1 share
    uint256 private constant _SHARES_PRICE_IN_ETH = (SHARES_PRICE) / _ETH_PRICE_USD;

    // ETH price in USD with 8 decimals (for use with assetsToShares)
    uint256 private constant _ETH_PRICE_USD_8_DECIMALS = _ETH_PRICE_USD * 1e8;

    function setUp() public virtual override {
        super.setUp();

        // Deploy mock ETH token
        mockETH = new Mock_ERC20("ETH", 18);

        // Mint ETH to test users
        mockETH.mint(address(alice), _ETH_SUBSCRIPTION_AMOUNT);
        mockETH.mint(address(bob), _ETH_SUBSCRIPTION_AMOUNT);
        mockETH.mint(address(carol), _ETH_SUBSCRIPTION_AMOUNT);

        // Approve ETH spending for the contract
        vm.startPrank(alice);
        mockETH.approve(address(kpkSharesContract), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        mockETH.approve(address(kpkSharesContract), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(carol);
        mockETH.approve(address(kpkSharesContract), type(uint256).max);
        vm.stopPrank();

        vm.prank(ops);

        // Add ETH as an approved asset
        kpkSharesContract.updateAsset(address(mockETH), false, true, true);
    }

    // ============================================================================
    // ETH Subscription and USDC Redemption Tests
    // ============================================================================

    /// @notice Test complete workflow: user subscribes 10 ETH and redeems shares in USDC
    function testCompleteETHSubscriptionToUSDCRedemption() public {
        // Set fee rates to 0 for testing
        vm.startPrank(admin);
        kpkSharesContract.setManagementFeeRate(0);
        kpkSharesContract.setRedemptionFeeRate(0);
        kpkSharesContract.setPerformanceFeeRate(0, address(usdc));
        vm.stopPrank();

        // 1. Alice subscribes 10 ETH
        uint256 ethSubscriptionAmount = _ETH_SUBSCRIPTION_AMOUNT;
        // Calculate shares manually: 10 ETH * $3500 = $35,000 worth of shares
        // At $1 per share, this equals 35,000 shares
        uint256 sharesOut = (ethSubscriptionAmount * _ETH_PRICE_USD);
        uint256 initialAliceUSDC = usdc.balanceOf(alice);

        vm.startPrank(alice);
        uint256 subscriptionRequestId =
            kpkSharesContract.requestSubscription(ethSubscriptionAmount, sharesOut, address(mockETH), alice);
        vm.stopPrank();

        // 2. Process the ETH subscription request
        vm.prank(ops);
        uint256[] memory approveRequests = new uint256[](1);
        approveRequests[0] = subscriptionRequestId;
        uint256[] memory rejectRequests = new uint256[](0);
        kpkSharesContract.processRequests(approveRequests, rejectRequests, address(mockETH), _SHARES_PRICE_IN_ETH);

        // 3. Check that shares were minted for Alice
        uint256 sharesMinted = kpkSharesContract.balanceOf(alice);
        assertGt(sharesMinted, 0, "Shares should be minted after ETH subscription");

        // 4. Verify ETH was transferred to the safe (not the contract)
        uint256 safeETHBalance = mockETH.balanceOf(safe);
        assertEq(safeETHBalance, ethSubscriptionAmount, "Safe should hold the subscribed ETH");

        // 5. Alice creates a redemption request for all her shares in USDC
        uint256 redeemShares = sharesMinted;
        uint256 assetsOut = kpkSharesContract.sharesToAssets(redeemShares, SHARES_PRICE, address(usdc));
        vm.startPrank(alice);
        uint256 redeemRequestId = kpkSharesContract.requestRedemption(redeemShares, assetsOut, address(usdc), alice);
        vm.stopPrank();

        // 6. Process the redemption request
        vm.prank(ops);
        uint256[] memory redeemApproveRequests = new uint256[](1);
        redeemApproveRequests[0] = redeemRequestId;
        uint256[] memory redeemRejectRequests = new uint256[](0);
        kpkSharesContract.processRequests(redeemApproveRequests, redeemRejectRequests, address(usdc), SHARES_PRICE);

        // 7. Check final balances
        uint256 finalShares = kpkSharesContract.balanceOf(alice);
        uint256 finalUSDC = usdc.balanceOf(alice);
        uint256 finalETH = mockETH.balanceOf(alice);

        // Alice should have no shares left
        assertEq(finalShares, 0, "Alice should have no shares after full redemption");

        // Alice should have received USDC (minus fees)
        assertGt(finalUSDC - initialAliceUSDC, 0, "Alice should receive USDC after redemption");

        // Alice should have no ETH (she subscribed it all)
        assertEq(finalETH, 0, "Alice should have no ETH after subscription");

        // 8. Verify the redemption amount is reasonable
        // The redemption amount depends on the share price and asset decimals
        // In this test, we're getting about 3,500 USDC for 10 ETH shares
        assertApproxEqAbs(
            (finalUSDC - initialAliceUSDC) * 1e18,
            _ETH_PRICE_USD * _ETH_SUBSCRIPTION_AMOUNT * 1e6,
            100,
            "Alice should receive USDC after redemption"
        );
    }

    /// @notice Test partial ETH subscription and partial USDC redemption
    function testPartialETHSubscriptionAndPartialUSDCRedemption() public {
        // 1. Alice subscribes 5 ETH (half of her 10 ETH)
        uint256 partialEthSubscription = _ETH_SUBSCRIPTION_AMOUNT / 2;
        // Calculate shares manually: 5 ETH * $3500 = $17,500 worth of shares
        uint256 sharesOut =
            kpkSharesContract.assetsToShares(partialEthSubscription, _SHARES_PRICE_IN_ETH, address(mockETH));

        vm.startPrank(alice);
        uint256 subscriptionRequestId =
            kpkSharesContract.requestSubscription(partialEthSubscription, sharesOut, address(mockETH), alice);
        vm.stopPrank();

        // 2. Process the subscription
        vm.prank(ops);
        uint256[] memory approveRequests = new uint256[](1);
        approveRequests[0] = subscriptionRequestId;
        uint256[] memory rejectRequests = new uint256[](0);
        kpkSharesContract.processRequests(approveRequests, rejectRequests, address(mockETH), _SHARES_PRICE_IN_ETH);

        // 3. Check shares minted
        uint256 sharesMinted = kpkSharesContract.balanceOf(alice);
        assertGt(sharesMinted, 0, "Shares should be minted for partial ETH subscription");

        // 4. Alice redeems half her shares in USDC
        uint256 redeemShares = sharesMinted / 2;
        uint256 assetsOut = kpkSharesContract.sharesToAssets(redeemShares, SHARES_PRICE, address(usdc));
        vm.startPrank(alice);
        uint256 redeemRequestId = kpkSharesContract.requestRedemption(redeemShares, assetsOut, address(usdc), alice);
        vm.stopPrank();

        // 5. Process redemption
        vm.prank(ops);
        uint256[] memory redeemApproveRequests = new uint256[](1);
        redeemApproveRequests[0] = redeemRequestId;
        uint256[] memory redeemRejectRequests = new uint256[](0);
        kpkSharesContract.processRequests(redeemApproveRequests, redeemRejectRequests, address(usdc), SHARES_PRICE);

        // 6. Check final balances
        uint256 finalShares = kpkSharesContract.balanceOf(alice);
        uint256 finalUSDC = usdc.balanceOf(alice);
        uint256 finalETH = mockETH.balanceOf(alice);

        // Alice should have half her shares left
        assertEq(finalShares, sharesMinted - redeemShares, "Alice should have half her shares remaining");

        // Alice should have received some USDC
        assertGt(finalUSDC, 0, "Alice should receive USDC for partial redemption");

        // Alice should have 5 ETH left (she only subscribed 5 ETH)
        assertEq(finalETH, _ETH_SUBSCRIPTION_AMOUNT - partialEthSubscription, "Alice should have 5 ETH remaining");
    }

    /// @notice Test multiple users subscribing ETH and redeeming in USDC
    function testMultipleUsersETHSubscriptionAndUSDCRedemption() public {
        // 1. Alice subscribes 10 ETH
        vm.startPrank(alice);
        uint256 aliceShares = (_ETH_SUBSCRIPTION_AMOUNT * _ETH_PRICE_USD);
        uint256 aliceSubscriptionId =
            kpkSharesContract.requestSubscription(_ETH_SUBSCRIPTION_AMOUNT, aliceShares, address(mockETH), alice);
        vm.stopPrank();

        // 2. Bob subscribes 5 ETH
        vm.startPrank(bob);
        uint256 bobShares = ((_ETH_SUBSCRIPTION_AMOUNT / 2) * _ETH_PRICE_USD);
        uint256 bobSubscriptionId =
            kpkSharesContract.requestSubscription(_ETH_SUBSCRIPTION_AMOUNT / 2, bobShares, address(mockETH), bob);
        vm.stopPrank();

        // 3. Process both subscriptions
        vm.prank(ops);
        uint256[] memory approveRequests = new uint256[](2);
        approveRequests[0] = aliceSubscriptionId;
        approveRequests[1] = bobSubscriptionId;
        uint256[] memory rejectRequests = new uint256[](0);
        kpkSharesContract.processRequests(approveRequests, rejectRequests, address(mockETH), _SHARES_PRICE_IN_ETH);

        // 4. Check shares were minted
        uint256 aliceBalance = kpkSharesContract.balanceOf(alice);
        uint256 bobBalance = kpkSharesContract.balanceOf(bob);
        assertGt(aliceBalance, 0, "Alice should have shares");
        assertGt(bobBalance, 0, "Bob should have shares");
        assertGt(aliceBalance, bobBalance, "Alice should have more shares than Bob");

        // 5. Both users redeem all their shares in USDC
        vm.startPrank(alice);
        uint256 aliceRedeemId = kpkSharesContract.requestRedemption(
            aliceBalance,
            kpkSharesContract.sharesToAssets(aliceBalance, SHARES_PRICE, address(usdc)),
            address(usdc),
            alice
        );
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 bobRedeemId = kpkSharesContract.requestRedemption(
            bobBalance, kpkSharesContract.sharesToAssets(bobBalance, SHARES_PRICE, address(usdc)), address(usdc), bob
        );
        vm.stopPrank();

        // 6. Process both redemptions
        vm.prank(ops);
        uint256[] memory redeemApproveRequests = new uint256[](2);
        redeemApproveRequests[0] = aliceRedeemId;
        redeemApproveRequests[1] = bobRedeemId;
        uint256[] memory redeemRejectRequests = new uint256[](0);
        kpkSharesContract.processRequests(redeemApproveRequests, redeemRejectRequests, address(usdc), SHARES_PRICE);

        // 7. Check final balances
        assertEq(kpkSharesContract.balanceOf(alice), 0, "Alice should have no shares");
        assertEq(kpkSharesContract.balanceOf(bob), 0, "Bob should have no shares");

        uint256 aliceUSDC = usdc.balanceOf(alice);
        uint256 bobUSDC = usdc.balanceOf(bob);

        assertGt(aliceUSDC, 0, "Alice should receive USDC");
        assertGt(bobUSDC, 0, "Bob should receive USDC");
        assertGt(aliceUSDC, bobUSDC, "Alice should receive more USDC than Bob");
    }

    /// @notice Test that ETH subscriptions are properly tracked in the contract
    function testETHSubscriptionTracking() public {
        // 1. Alice subscribes ETH
        vm.startPrank(alice);
        uint256 shares = (_ETH_SUBSCRIPTION_AMOUNT * _ETH_PRICE_USD) / 1e18;
        uint256 subscriptionRequestId =
            kpkSharesContract.requestSubscription(_ETH_SUBSCRIPTION_AMOUNT, shares, address(mockETH), alice);
        vm.stopPrank();

        // 2. Check that the request is properly created
        IkpkShares.UserRequest memory request = kpkSharesContract.getRequest(subscriptionRequestId);
        assertEq(request.asset, address(mockETH), "Request should track ETH as asset");
        assertEq(request.assetAmount, _ETH_SUBSCRIPTION_AMOUNT, "Request should track correct ETH amount");

        // 3. Check that ETH is tracked in subscription assets
        uint256 trackedETH = kpkSharesContract.subscriptionAssets(address(mockETH));
        assertEq(trackedETH, _ETH_SUBSCRIPTION_AMOUNT, "Contract should track ETH in subscription assets");
    }

    /// @notice Test that ETH subscriptions can be cancelled before processing
    function testETHSubscriptionCancellation() public {
        // 1. Alice subscribes ETH
        vm.startPrank(alice);
        uint256 shares = (_ETH_SUBSCRIPTION_AMOUNT * _ETH_PRICE_USD) / 1e18;
        uint256 subscriptionRequestId =
            kpkSharesContract.requestSubscription(_ETH_SUBSCRIPTION_AMOUNT, shares, address(mockETH), alice);
        vm.stopPrank();

        // 2. Wait for TTL to expire
        skip(SUBSCRIPTION_REQUEST_TTL + 1);

        // 3. Alice cancels the subscription
        vm.startPrank(alice);
        kpkSharesContract.cancelSubscription(subscriptionRequestId);
        vm.stopPrank();

        // 4. Check that ETH was returned to Alice
        uint256 aliceETH = mockETH.balanceOf(alice);
        assertEq(aliceETH, _ETH_SUBSCRIPTION_AMOUNT, "Alice should have her ETH back after cancellation");

        // 5. Check that no shares were minted
        uint256 aliceShares = kpkSharesContract.balanceOf(alice);
        assertEq(aliceShares, 0, "Alice should have no shares after cancellation");
    }
}

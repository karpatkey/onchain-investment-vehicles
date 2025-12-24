// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./kpkShares.TestBase.sol";

/// @notice Tests for kpkShares asset management functionality
contract kpkSharesAssetsTest is kpkSharesTestBase {
    function setUp() public virtual override {
        super.setUp();
    }

    // ============================================================================
    // Asset Update Tests
    // ============================================================================

    function testUpdateAsset() public {
        Mock_ERC20 newAsset = new Mock_ERC20("NEW_ASSET", 18);

        vm.prank(ops);
        kpkSharesContract.updateAsset(address(newAsset), true, true, true);

        // Check that asset was added to the list
        address[] memory approvedAssets = kpkSharesContract.getApprovedAssets();
        assertEq(approvedAssets.length, 2); // USDC + new asset
        assertTrue(approvedAssets[0] == address(usdc) || approvedAssets[1] == address(usdc));
        assertTrue(approvedAssets[0] == address(newAsset) || approvedAssets[1] == address(newAsset));
    }

    function testUpdateAssetWithZeroAddressBranch() public {
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IkpkShares.InvalidArguments.selector));
        kpkSharesContract.updateAsset(address(0), true, true, true);
    }

    function testUpdateAssetWithAlreadyApprovedAsset() public {
        // Try to approve an already approved asset
        vm.prank(ops);
        kpkSharesContract.updateAsset(address(usdc), true, true, true);

        // Should not revert, but also not duplicate
        address[] memory approvedAssets = kpkSharesContract.getApprovedAssets();
        assertEq(approvedAssets.length, 1); // Still only USDC
    }

    function testUpdateAssetUnauthorized() public {
        Mock_ERC20 newAsset = new Mock_ERC20("NEW_ASSET", 18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IkpkShares.NotAuthorized.selector));
        kpkSharesContract.updateAsset(address(newAsset), true, true, true);
    }

    // ============================================================================
    // Asset Removal Tests
    // ============================================================================

    function testRemoveAsset() public {
        // Add a new asset (now properly configured on first call)
        Mock_ERC20 newAsset = new Mock_ERC20("NEW_ASSET", 18);

        vm.prank(ops);
        kpkSharesContract.updateAsset(address(newAsset), true, true, true);

        // Then remove it - this now properly clears oracle, canDeposit, canRedeem from mapping
        vm.prank(ops);
        kpkSharesContract.updateAsset(address(newAsset), false, false, false);

        IkpkShares.ApprovedAsset memory asset = kpkSharesContract.getApprovedAsset(address(newAsset));
        // Asset removal now properly clears the mapping data
        assertFalse(asset.canDeposit); // Cleared by removal logic
        assertFalse(asset.canRedeem); // Cleared by removal logic
        assertEq(asset.isFeeModuleAsset, false); // Cleared by removal logic
        assertEq(asset.asset, address(0)); // Asset address cleared
        assertEq(asset.decimals, 0); // Decimals cleared
    }

    function testRemoveAssetWithAssetNotInList() public {
        Mock_ERC20 newAsset = new Mock_ERC20("NEW_ASSET", 18);

        // Try to remove an asset that was never approved - this should revert with InvalidArguments
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IkpkShares.InvalidArguments.selector));
        kpkSharesContract.updateAsset(address(newAsset), true, false, false);
    }

    function testRemoveAssetUnauthorized() public {
        Mock_ERC20 newAsset = new Mock_ERC20("NEW_ASSET", 18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IkpkShares.NotAuthorized.selector));
        kpkSharesContract.updateAsset(address(newAsset), true, false, false);
    }

    function testCannotRemoveLastAsset() public {
        // USDC is the only asset
        // Try to remove it completely - should revert
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IkpkShares.InvalidArguments.selector));
        kpkSharesContract.updateAsset(address(usdc), false, false, false);

        // Add another asset
        Mock_ERC20 newAsset = new Mock_ERC20("NEW_ASSET", 18);
        vm.prank(ops);
        kpkSharesContract.updateAsset(address(newAsset), true, true, true);

        // Now we can remove USDC completely
        vm.prank(ops);
        kpkSharesContract.updateAsset(address(usdc), false, false, false);

        // Verify USDC is removed
        IkpkShares.ApprovedAsset memory usdcAsset = kpkSharesContract.getApprovedAsset(address(usdc));
        assertEq(usdcAsset.asset, address(0));

        // Verify newAsset is still there
        IkpkShares.ApprovedAsset memory newAssetConfig = kpkSharesContract.getApprovedAsset(address(newAsset));
        assertEq(newAssetConfig.asset, address(newAsset));

        // Now try to remove newAsset (which is now the last asset) - should revert
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IkpkShares.InvalidArguments.selector));
        kpkSharesContract.updateAsset(address(newAsset), false, false, false);
    }

    // ============================================================================
    // Asset Validation Tests
    // ============================================================================

    function testIsAsset() public {
        // USDC was properly configured during setup with updateAsset
        IkpkShares.ApprovedAsset memory asset = kpkSharesContract.getApprovedAsset(address(usdc));
        assertTrue(asset.canDeposit); // Set to true during setup
        assertTrue(asset.canRedeem); // Set to true during setup
        assertEq(asset.decimals, 6);
        assertEq(asset.asset, address(usdc));
        assertEq(asset.isFeeModuleAsset, true);
        // Non-existent asset should return default values
        assertFalse(kpkSharesContract.getApprovedAsset(address(alice)).canDeposit);

        // Test with a new asset
        Mock_ERC20 newAsset = new Mock_ERC20("NEW_ASSET", 18);
        assertFalse(kpkSharesContract.getApprovedAsset(address(newAsset)).canDeposit);

        // Add it (now properly sets all fields on first call)
        vm.prank(ops);
        kpkSharesContract.updateAsset(address(newAsset), true, true, true);
        assertTrue(kpkSharesContract.getApprovedAsset(address(newAsset)).canDeposit);
    }

    function testAssetDecimals() public {
        address[] memory approvedAssets = kpkSharesContract.getApprovedAssets();

        assertEq(kpkSharesContract.getApprovedAsset(address(usdc)).decimals, 6);

        // Test with a new asset
        Mock_ERC20 newAsset = new Mock_ERC20("NEW_ASSET", 12);
        vm.prank(ops);
        kpkSharesContract.updateAsset(address(newAsset), true, true, true);

        assertEq(kpkSharesContract.getApprovedAsset(address(newAsset)).decimals, 12);

        approvedAssets = kpkSharesContract.getApprovedAssets();
        assertEq(approvedAssets.length, 2);
        assertEq(approvedAssets[0], address(usdc));
        assertEq(approvedAssets[1], address(newAsset));
    }

    function testGetApprovedAssets() public {
        address[] memory approvedAssets = kpkSharesContract.getApprovedAssets();
        assertEq(approvedAssets.length, 1);
        assertEq(approvedAssets[0], address(usdc));

        // Add another asset
        Mock_ERC20 newAsset = new Mock_ERC20("NEW_ASSET", 18);
        vm.prank(ops);
        kpkSharesContract.updateAsset(address(newAsset), true, true, true);

        approvedAssets = kpkSharesContract.getApprovedAssets();
        assertEq(approvedAssets.length, 2);

        // Check that both assets are in the list
        bool hasUsdc = false;
        bool hasNewAsset = false;
        for (uint256 i = 0; i < approvedAssets.length; i++) {
            if (approvedAssets[i] == address(usdc)) hasUsdc = true;
            if (approvedAssets[i] == address(newAsset)) hasNewAsset = true;
        }
        assertTrue(hasUsdc);
        assertTrue(hasNewAsset);
    }

    // ============================================================================
    // Asset Integration Tests
    // ============================================================================

    function testMultipleAssets() public {
        // Add multiple assets
        Mock_ERC20 asset1 = new Mock_ERC20("ASSET_1", 8);
        Mock_ERC20 asset2 = new Mock_ERC20("ASSET_2", 12);
        Mock_ERC20 asset3 = new Mock_ERC20("ASSET_3", 18);

        vm.startPrank(ops);
        kpkSharesContract.updateAsset(address(asset1), true, true, true);
        kpkSharesContract.updateAsset(address(asset2), true, true, true);
        kpkSharesContract.updateAsset(address(asset3), true, true, true);
        vm.stopPrank();

        // Check that all assets are approved
        assertTrue(kpkSharesContract.getApprovedAsset(address(asset1)).canDeposit);
        assertTrue(kpkSharesContract.getApprovedAsset(address(asset2)).canDeposit);
        assertTrue(kpkSharesContract.getApprovedAsset(address(asset3)).canDeposit);

        // Check the list
        address[] memory approvedAssets = kpkSharesContract.getApprovedAssets();
        assertEq(approvedAssets.length, 4); // USDC + 3 new assets
    }

    function testAssetRemovalWithComplexState() public {
        // Use the existing USDC asset which is already configured and the safe holds
        // We can't remove USDC completely since it's the base asset, but we can test
        // the logic by temporarily disabling it and then re-enabling it

        // First, ensure USDC is enabled for both deposit and redeem
        vm.prank(ops);
        kpkSharesContract.updateAsset(address(usdc), true, true, true);

        // Create a subscription request using USDC (which the safe already holds)
        vm.startPrank(alice);
        usdc.approve(address(kpkSharesContract), type(uint256).max);
        uint256 requestId = kpkSharesContract.requestSubscription(
            _usdcAmount(100),
            kpkSharesContract.assetsToShares(_usdcAmount(100), SHARES_PRICE, address(usdc)),
            address(usdc),
            alice
        );
        vm.stopPrank();

        // Process the subscription request
        uint256[] memory approveRequests = new uint256[](1);
        approveRequests[0] = requestId;
        vm.prank(ops);
        kpkSharesContract.processRequests(approveRequests, new uint256[](0), address(usdc), SHARES_PRICE);

        // Now should be able to disable USDC subscriptions since no pending requests
        vm.prank(ops);
        kpkSharesContract.updateAsset(address(usdc), true, false, true);
        assertFalse(kpkSharesContract.getApprovedAsset(address(usdc)).canDeposit);
        assertTrue(kpkSharesContract.getApprovedAsset(address(usdc)).canRedeem);

        // Re-enable USDC subscriptions
        vm.prank(ops);
        kpkSharesContract.updateAsset(address(usdc), true, true, true);
        assertTrue(kpkSharesContract.getApprovedAsset(address(usdc)).canDeposit);
        assertTrue(kpkSharesContract.getApprovedAsset(address(usdc)).canRedeem);
    }

    // ============================================================================
    // Asset Management Edge Cases Tests
    // ============================================================================

    function testAssetUpdateWithInvalidConfiguration() public {
        // Test asset update with invalid configuration (both canDeposit and canRedeem false)
        Mock_ERC20 asset = new Mock_ERC20("ASSET", 18);

        // Try to add asset with both flags false - should revert
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IkpkShares.InvalidArguments.selector));
        kpkSharesContract.updateAsset(address(asset), true, false, false);
    }

    function testAssetUpdateWithZeroAddressValidation() public {
        // Test asset update with zero address validation
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IkpkShares.InvalidArguments.selector));
        kpkSharesContract.updateAsset(address(0), true, true, true);
    }

    function testAssetUpdateWithComplexStateTransitions() public {
        // Test complex asset state transitions
        Mock_ERC20 asset = new Mock_ERC20("ASSET", 18);

        // Add asset with both flags true
        vm.prank(ops);
        kpkSharesContract.updateAsset(address(asset), true, true, true);
        assertTrue(kpkSharesContract.getApprovedAsset(address(asset)).canDeposit);
        assertTrue(kpkSharesContract.getApprovedAsset(address(asset)).canRedeem);

        // Update to deposit only
        vm.prank(ops);
        kpkSharesContract.updateAsset(address(asset), true, true, false);
        assertTrue(kpkSharesContract.getApprovedAsset(address(asset)).canDeposit);
        assertFalse(kpkSharesContract.getApprovedAsset(address(asset)).canRedeem);

        // Update to redeem only
        vm.prank(ops);
        kpkSharesContract.updateAsset(address(asset), true, false, true);
        assertFalse(kpkSharesContract.getApprovedAsset(address(asset)).canDeposit);
        assertTrue(kpkSharesContract.getApprovedAsset(address(asset)).canRedeem);

        // Update back to both
        vm.prank(ops);
        kpkSharesContract.updateAsset(address(asset), true, true, true);
        assertTrue(kpkSharesContract.getApprovedAsset(address(asset)).canDeposit);
        assertTrue(kpkSharesContract.getApprovedAsset(address(asset)).canRedeem);
    }

    function testAssetRemovalAndReapproval() public {
        // Test asset removal and reapproval
        Mock_ERC20 asset = new Mock_ERC20("ASSET", 18);

        // Add asset
        vm.prank(ops);
        kpkSharesContract.updateAsset(address(asset), true, true, true);
        assertTrue(kpkSharesContract.getApprovedAsset(address(asset)).canDeposit);

        // Remove asset (this now properly clears mapping data)
        vm.prank(ops);
        kpkSharesContract.updateAsset(address(asset), true, false, false);
        assertFalse(kpkSharesContract.getApprovedAsset(address(asset)).canDeposit); // Cleared by removal

        // Re-add asset
        vm.prank(ops);
        kpkSharesContract.updateAsset(address(asset), true, true, true);
        assertTrue(kpkSharesContract.getApprovedAsset(address(asset)).canDeposit);
    }

    function testAssetUpdateWithExistingAsset() public {
        // Test updating an existing asset
        Mock_ERC20 asset = new Mock_ERC20("ASSET", 18);

        // Add asset initially
        vm.prank(ops);
        kpkSharesContract.updateAsset(address(asset), true, true, true);

        // Update the same asset with different configuration
        vm.prank(ops);
        kpkSharesContract.updateAsset(address(asset), true, false, true);

        // Check that the asset was updated
        IkpkShares.ApprovedAsset memory assetConfig = kpkSharesContract.getApprovedAsset(address(asset));
        assertFalse(assetConfig.canDeposit);
        assertTrue(assetConfig.canRedeem);
    }

    function testAssetUpdateWithNewIsUsd() public {
        // Test updating an asset with a new isFeeModuleAsset value
        Mock_ERC20 asset = new Mock_ERC20("ASSET", 18);

        // Add asset initially
        vm.prank(ops);
        kpkSharesContract.updateAsset(address(asset), true, true, true);

        // Update with new isFeeModuleAsset value
        vm.prank(ops);
        kpkSharesContract.updateAsset(address(asset), false, true, true);

        // Check that the isFeeModuleAsset was updated
        IkpkShares.ApprovedAsset memory assetConfig = kpkSharesContract.getApprovedAsset(address(asset));
        assertEq(assetConfig.isFeeModuleAsset, false);
    }

    function testAssetUpdateWithSymbolAndDecimals() public {
        // Test that asset symbol and decimals are properly set
        Mock_ERC20 asset = new Mock_ERC20("TEST_ASSET", 6);

        // Add asset
        vm.prank(ops);
        kpkSharesContract.updateAsset(address(asset), true, true, true);

        // Check that symbol and decimals were set
        IkpkShares.ApprovedAsset memory assetConfig = kpkSharesContract.getApprovedAsset(address(asset));
        assertEq(assetConfig.symbol, "TEST_ASSET");
        assertEq(assetConfig.decimals, 6);
    }

    // ============================================================================
    // Pending Subscription Requests Tests
    // ============================================================================

    // ============================================================================
    // Asset Event Tests
    // ============================================================================

    function testAssetEventsEmitted() public {
        Mock_ERC20 newAsset = new Mock_ERC20("NEW_ASSET", 18);

        // Test asset added event (when adding a new asset)
        // Now emits both AssetAdd and AssetUpdated events
        vm.prank(ops);
        vm.expectEmit(true, true, false, true);
        emit IkpkShares.AssetAdd(address(newAsset));
        vm.expectEmit(true, true, false, true);
        emit IkpkShares.AssetUpdate(address(newAsset), true, true, true);
        kpkSharesContract.updateAsset(address(newAsset), true, true, true);

        // Test asset updated event (when updating existing asset)
        vm.prank(ops);
        vm.expectEmit(true, true, false, true);
        emit IkpkShares.AssetUpdate(address(newAsset), true, false, true);
        kpkSharesContract.updateAsset(address(newAsset), true, false, true);

        // Test asset removed event (when setting both canDeposit and canRedeem to false)
        vm.prank(ops);
        vm.expectEmit(true, true, false, true);
        emit IkpkShares.AssetRemove(address(newAsset));
        kpkSharesContract.updateAsset(address(newAsset), true, false, false);
    }

    function testAssetUpdatedEvent() public {
        Mock_ERC20 newAsset = new Mock_ERC20("NEW_ASSET", 18);

        // First add the asset (now properly emits both AssetAdded and AssetUpdated)
        vm.prank(ops);
        kpkSharesContract.updateAsset(address(newAsset), true, true, true);

        // Test AssetUpdated event when changing isFeeModuleAsset
        vm.prank(ops);
        vm.expectEmit(true, true, false, true);
        emit IkpkShares.AssetUpdate(address(newAsset), false, true, true);
        kpkSharesContract.updateAsset(address(newAsset), false, true, true);

        // Test AssetUpdated event when changing canDeposit only
        vm.prank(ops);
        vm.expectEmit(true, true, false, true);
        emit IkpkShares.AssetUpdate(address(newAsset), false, false, true);
        kpkSharesContract.updateAsset(address(newAsset), false, false, true);
    }

    // ============================================================================
    // Edge Cases and Error Handling
    // ============================================================================

    // ============================================================================
    // Asset State Persistence Tests
    // ============================================================================

    function testAssetStatePersistence() public {
        Mock_ERC20 asset = new Mock_ERC20("ASSET", 18);

        // Add asset
        vm.prank(ops);
        kpkSharesContract.updateAsset(address(asset), true, true, true);

        // Check state
        assertTrue(kpkSharesContract.getApprovedAsset(address(asset)).canDeposit);
        assertEq(kpkSharesContract.getApprovedAsset(address(asset)).decimals, 18);

        // Remove asset
        vm.prank(ops);
        kpkSharesContract.updateAsset(address(asset), true, false, false);

        // Check state after removal - mapping data is now properly cleared
        IkpkShares.ApprovedAsset memory removedAsset = kpkSharesContract.getApprovedAsset(address(asset));
        assertFalse(removedAsset.canDeposit); // Cleared by removal logic
        assertFalse(removedAsset.canRedeem); // Cleared by removal logic
        assertEq(removedAsset.decimals, 0); // Decimals cleared
        assertEq(removedAsset.isFeeModuleAsset, false); // isFeeModuleAsset cleared
        assertEq(removedAsset.asset, address(0)); // Asset address cleared

        // Check that it's not in the list
        address[] memory approvedAssets = kpkSharesContract.getApprovedAssets();
        assertEq(approvedAssets.length, 1); // Only USDC
        assertEq(approvedAssets[0], address(usdc));
    }

    function testAssetListOrdering() public {
        // Add multiple assets to test ordering
        Mock_ERC20 asset1 = new Mock_ERC20("ASSET1", 18);
        Mock_ERC20 asset2 = new Mock_ERC20("ASSET2", 18);
        Mock_ERC20 asset3 = new Mock_ERC20("ASSET3", 18);

        vm.startPrank(ops);
        kpkSharesContract.updateAsset(address(asset1), true, true, true);
        kpkSharesContract.updateAsset(address(asset2), true, true, true);
        kpkSharesContract.updateAsset(address(asset3), true, true, true);
        vm.stopPrank();

        address[] memory approvedAssets = kpkSharesContract.getApprovedAssets();
        assertEq(approvedAssets.length, 4); // USDC + 3 new assets

        // Check that assets are added in order
        assertEq(approvedAssets[0], address(usdc));
        assertEq(approvedAssets[1], address(asset1));
        assertEq(approvedAssets[2], address(asset2));
        assertEq(approvedAssets[3], address(asset3));
    }

    // ============================================================================
    // Pending Subscription Requests Tests
    // ============================================================================

    function testUpdateAssetCanSetCanDepositToFalseWithoutPendingDeposits() public {
        // First add a new asset
        Mock_ERC20 newAsset = new Mock_ERC20("NEW_ASSET", 18);
        vm.prank(ops);
        kpkSharesContract.updateAsset(address(newAsset), true, true, true);

        // No subscription requests made, so subscriptionAssets should be 0
        assertEq(kpkSharesContract.subscriptionAssets(address(newAsset)), 0);

        // Should be able to set canDeposit to false without pending subscriptions
        vm.prank(ops);
        kpkSharesContract.updateAsset(address(newAsset), true, false, true);

        // Verify the asset no longer allows subscriptions
        assertFalse(kpkSharesContract.getApprovedAsset(address(newAsset)).canDeposit);
        assertTrue(kpkSharesContract.getApprovedAsset(address(newAsset)).canRedeem);
    }

    function testUpdateAssetCanSetCanDepositToFalseAfterProcessingSubscriptions() public {
        // First add a new asset
        Mock_ERC20 newAsset = new Mock_ERC20("NEW_ASSET", 18);
        vm.prank(ops);
        kpkSharesContract.updateAsset(address(newAsset), true, true, true);

        // Mint tokens to alice and approve the contract
        newAsset.mint(alice, 1000e18);
        vm.startPrank(alice);
        newAsset.approve(address(kpkSharesContract), type(uint256).max);

        // Create a subscription request
        uint256 requestId = kpkSharesContract.requestSubscription(
            100e18,
            1e18, // 1 USD per share
            address(newAsset),
            alice
        );
        vm.stopPrank();

        // Process the subscription request
        uint256[] memory approveRequests = new uint256[](1);
        approveRequests[0] = requestId;
        uint256[] memory rejectRequests = new uint256[](0);

        vm.prank(ops);
        kpkSharesContract.processRequests(approveRequests, rejectRequests, address(newAsset), SHARES_PRICE);

        // Verify the subscription assets have been processed (should be 0 now)
        assertEq(kpkSharesContract.subscriptionAssets(address(newAsset)), 0);

        // Now should be able to set canDeposit to false since no pending subscriptions
        vm.prank(ops);
        kpkSharesContract.updateAsset(address(newAsset), true, false, true);

        // Verify the asset no longer allows subscriptions
        assertFalse(kpkSharesContract.getApprovedAsset(address(newAsset)).canDeposit);
    }

    function testUpdateAssetCanSetCanDepositToTrueRegardlessOfPendingSubscriptions() public {
        // First add a new asset with canDeposit = false
        Mock_ERC20 newAsset = new Mock_ERC20("NEW_ASSET", 18);
        vm.startPrank(ops);
        kpkSharesContract.updateAsset(address(newAsset), true, false, true);
        vm.stopPrank();

        // Should be able to set canDeposit to true even with pending subscriptions (if any existed)
        vm.prank(ops);
        kpkSharesContract.updateAsset(address(newAsset), true, true, true);

        // Verify the asset now allows subscriptions
        assertTrue(kpkSharesContract.getApprovedAsset(address(newAsset)).canDeposit);
    }
}

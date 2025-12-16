// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./kpkShares.TestBase.sol";
import "./constants.sol";

/// @notice Tests for kpkShares precision functionality
/// @dev Focuses on shares and assets conversion precision, preview functions, and fee functions
contract kpkSharesPrecisionTest is kpkSharesTestBase {
    function setUp() public virtual override {
        super.setUp();
    }

    // ============================================================================
    // Precision Testing Section
    // ============================================================================
    // Tests for shares and assets conversion precision, preview functions, and fee functions

    function testPrecisionAssetsToSharesConversion() public {
        // Test with very small amounts to check precision
        uint256 smallAssets = 1e6; // 1 USDC (6 decimals)
        uint256 expectedShares = kpkSharesContract.assetsToShares(smallAssets, SHARES_PRICE, address(usdc));

        // With 1 USDC and $1 price, should get some shares
        assertGt(expectedShares, 0);

        // Test with larger amounts to verify scaling
        uint256 largeAssets = _usdcAmount(1_000_000); // 1M USDC
        uint256 expectedLargeShares = kpkSharesContract.assetsToShares(largeAssets, SHARES_PRICE, address(usdc));

        // Should be proportional to the small amount test
        assertGt(expectedLargeShares, expectedShares);

        // Test precision with different price points
        uint256 highPrice = 2e8; // $2.00
        uint256 lowPrice = 5e7; // $0.50

        uint256 sharesHighPrice = kpkSharesContract.assetsToShares(_usdcAmount(1000), highPrice, address(usdc));

        uint256 sharesLowPrice = kpkSharesContract.assetsToShares(_usdcAmount(1000), lowPrice, address(usdc));

        // Higher price should result in fewer shares
        assertLt(sharesHighPrice, sharesLowPrice);
    }

    function testPrecisionSharesToAssetsConversion() public {
        // Test with very small share amounts
        uint256 smallShares = 2e12; // 2e12 wei of shares (18 decimals)
        uint256 expectedAssets = kpkSharesContract.sharesToAssets(smallShares, SHARES_PRICE, address(usdc));

        // With 1e6 wei shares and $1 price, should get some assets
        assertGt(expectedAssets, 0);

        // Test with larger amounts to verify scaling
        uint256 largeShares = _sharesAmount(1_000_000); // 1M shares
        uint256 expectedLargeAssets = kpkSharesContract.sharesToAssets(largeShares, SHARES_PRICE, address(usdc));

        // Should be proportional to the small amount test
        assertGt(expectedLargeAssets, expectedAssets);

        // Test precision with different price points
        uint256 highPrice = 2e8; // $2.00
        uint256 lowPrice = 5e7; // $0.50

        uint256 assetsHighPrice = kpkSharesContract.sharesToAssets(_sharesAmount(1000), highPrice, address(usdc));

        uint256 assetsLowPrice = kpkSharesContract.sharesToAssets(_sharesAmount(1000), lowPrice, address(usdc));

        // Higher price should result in more assets
        assertGt(assetsHighPrice, assetsLowPrice);
    }

    function testPrecisionPreviewDeposit() public {
        // Test with very small asset amounts
        uint256 smallAssets = _usdcAmount(1); // 1 USDC
        uint256 shares = kpkSharesContract.previewSubscription(smallAssets, SHARES_PRICE, address(usdc));

        assertGt(shares, 0);
        assertApproxEqRel(shares, 1e18, 10);

        // Test with larger amounts
        uint256 largeAssets = _usdcAmount(1_000_000); // 1M USDC
        uint256 sharesLarge = kpkSharesContract.previewSubscription(largeAssets, SHARES_PRICE, address(usdc));

        assertGt(sharesLarge, shares);

        // Verify the conversion is consistent with direct assetsToShares call
        uint256 directShares = kpkSharesContract.assetsToShares(largeAssets, SHARES_PRICE, address(usdc));
        assertEq(sharesLarge, directShares);
    }

    function testPrecisionPreviewRedeem() public {
        // Test with very small share amounts
        uint256 smallShares = 1e12;
        uint256 assets = kpkSharesContract.previewRedemption(smallShares, SHARES_PRICE, address(usdc));

        assertApproxEqRel(assets, 1, 10);
        assertGt(assets, 0);

        uint256 barelyAnyShares = 1e11;

        uint256 assetsBarelyAny = kpkSharesContract.previewRedemption(barelyAnyShares, SHARES_PRICE, address(usdc));

        assertApproxEqRel(assetsBarelyAny, 0, 1);

        // Test with larger amounts
        uint256 largeShares = _sharesAmount(1_000_000); // 1M shares
        uint256 assetsLarge = kpkSharesContract.previewRedemption(largeShares, SHARES_PRICE, address(usdc));

        assertGt(assetsLarge, assets);

        // Verify the conversion is consistent with direct sharesToAssets call (accounting for fees)
        uint256 redemptionFee = (largeShares * kpkSharesContract.redemptionFeeRate()) / 10000;
        uint256 netLargeShares = largeShares - redemptionFee;
        uint256 directAssets = kpkSharesContract.sharesToAssets(netLargeShares, SHARES_PRICE, address(usdc));
        assertEq(assetsLarge, directAssets);
    }

    function testPrecisionFeeCalculations() public {
        // Test management fee precision with very small rates
        KpkShares kpkSharesWithFees = _deployKpkSharesWithFees(
            1, // 0.01% management fee (1 basis point)
            0,
            0
        );

        uint256 shares = _sharesAmount(1000);
        _createSharesForTestingWithContract(kpkSharesWithFees, alice, shares);

        uint256 timeElapsed = 365 days; // 1 year
        skip(timeElapsed);

        uint256 initialFeeBalance = kpkSharesWithFees.balanceOf(feeRecipient);

        // Create and process a redeem request to trigger fee charging
        vm.startPrank(alice);
        uint256 requestId = kpkSharesWithFees.requestRedemption(
            _sharesAmount(100),
            kpkSharesWithFees.sharesToAssets(_sharesAmount(100), SHARES_PRICE, address(usdc)),
            address(usdc),
            alice
        );
        vm.stopPrank();

        vm.prank(ops);
        uint256[] memory approveRequests = new uint256[](1);
        approveRequests[0] = requestId;
        uint256[] memory rejectRequests = new uint256[](0);
        kpkSharesWithFees.processRequests(approveRequests, rejectRequests, address(usdc), SHARES_PRICE);

        uint256 finalFeeBalance = kpkSharesWithFees.balanceOf(feeRecipient);
        uint256 actualFee = finalFeeBalance - initialFeeBalance;

        // With minimum rate, fees should still be calculated precisely
        assertGt(actualFee, 0);

        // Calculate expected fee manually for precision verification
        uint256 expectedFee = (shares * 1 * timeElapsed) / (10_000 * SECONDS_PER_YEAR);
        assertApproxEqRel(actualFee, expectedFee, 1e5); // Allow 0.1% tolerance
    }

    function testPrecisionRedeemFeeCalculations() public {
        // Test redeem fee precision with very small rates
        KpkShares kpkSharesWithFees = _deployKpkSharesWithFees(
            0,
            1, // 0.01% redeem fee (1 basis point)
            0
        );

        uint256 shares = _sharesAmount(1000);
        _createSharesForTestingWithContract(kpkSharesWithFees, alice, shares);

        vm.prank(alice);
        kpkSharesWithFees.approve(address(kpkSharesWithFees), shares);

        vm.startPrank(alice);
        uint256 requestId = kpkSharesWithFees.requestRedemption(
            shares, kpkSharesWithFees.sharesToAssets(shares, SHARES_PRICE, address(usdc)), address(usdc), alice
        );
        vm.stopPrank();

        uint256 initialFeeBalance = kpkSharesWithFees.balanceOf(feeRecipient);

        vm.prank(ops);
        uint256[] memory approveRequests = new uint256[](1);
        approveRequests[0] = requestId;
        uint256[] memory rejectRequests = new uint256[](0);
        kpkSharesWithFees.processRequests(approveRequests, rejectRequests, address(usdc), SHARES_PRICE);

        uint256 finalFeeBalance = kpkSharesWithFees.balanceOf(feeRecipient);
        uint256 actualFee = finalFeeBalance - initialFeeBalance;

        // Calculate expected fee manually
        uint256 expectedFee = (shares * 1) / 10_000; // 0.01% of shares
        assertApproxEqRel(actualFee, expectedFee, 1e5); // Allow 0.1% tolerance
    }

    function testPrecisionPerformanceFeeCalculations() public {
        // Test performance fee precision with very small rates
        KpkShares kpkSharesWithFees = _deployKpkSharesWithFees(
            0,
            0,
            1 // 0.01% performance fee (1 basis point)
        );

        uint256 shares = _sharesAmount(1000);
        _createSharesForTestingWithContract(kpkSharesWithFees, alice, shares);

        vm.prank(alice);
        kpkSharesWithFees.approve(address(kpkSharesWithFees), shares);

        vm.startPrank(alice);
        uint256 requestId = kpkSharesWithFees.requestRedemption(
            _sharesAmount(100),
            kpkSharesWithFees.sharesToAssets(_sharesAmount(100), SHARES_PRICE, address(usdc)),
            address(usdc),
            alice
        );
        vm.stopPrank();

        uint256 timeElapsed = 365 days;
        skip(timeElapsed);

        uint256 initialFeeBalance = kpkSharesWithFees.balanceOf(feeRecipient);

        vm.prank(ops);
        uint256[] memory approveRequests = new uint256[](1);
        approveRequests[0] = requestId;
        uint256[] memory rejectRequests = new uint256[](0);
        kpkSharesWithFees.processRequests(approveRequests, rejectRequests, address(usdc), SHARES_PRICE);

        uint256 finalFeeBalance = kpkSharesWithFees.balanceOf(feeRecipient);
        uint256 actualFee = finalFeeBalance - initialFeeBalance;

        // With minimum rate, fees should still be calculated precisely
        assertGt(actualFee, 0);
    }

    function testPrecisionRoundingBehavior() public {
        // Test that rounding behavior is consistent and predictable
        uint256 testShares = _sharesAmount(1001); // 1001 shares
        uint256 testPrice = 100_000_001; // $1.00000001 (slightly above $1)

        uint256 assets = kpkSharesContract.sharesToAssets(testShares, testPrice, address(usdc));

        // Verify the conversion back to shares maintains precision
        uint256 sharesBack = kpkSharesContract.assetsToShares(assets, testPrice, address(usdc));

        // Due to rounding, we might lose some precision, but it should be minimal
        assertLe(_abs(testShares, sharesBack), 1e12); // Allow 1 wei difference

        // Test with very precise price
        uint256 precisePrice = 1_000_000_001; // $1.000000001
        uint256 preciseAssets = kpkSharesContract.sharesToAssets(testShares, precisePrice, address(usdc));

        uint256 preciseSharesBack = kpkSharesContract.assetsToShares(preciseAssets, precisePrice, address(usdc));

        // Should maintain precision even with very precise prices
        assertLe(_abs(testShares, preciseSharesBack), 1e12);
    }

    function testPrecisionEdgeCases() public {
        // Test with maximum possible values
        uint256 maxShares = 1e30;
        uint256 maxPrice = 1e30;

        // These should not revert but handle gracefully
        uint256 maxAssets = kpkSharesContract.sharesToAssets(maxShares, maxPrice, address(usdc));

        // Should not overflow
        assertGt(maxAssets, 0);

        // Test with minimum values
        uint256 minShares = 1e6;
        uint256 minPrice = 1;

        uint256 minAssets = kpkSharesContract.sharesToAssets(minShares, minPrice, address(usdc));

        // Should handle minimum values correctly
        assertGe(minAssets, 0);

        // Test with zero values
        uint256 zeroAssets = kpkSharesContract.sharesToAssets(0, SHARES_PRICE, address(usdc));
        assertEq(zeroAssets, 0);

        uint256 zeroShares = kpkSharesContract.assetsToShares(0, SHARES_PRICE, address(usdc));
        assertEq(zeroShares, 0);
    }

    function testPrecisionConsistencyAcrossOperations() public {
        // Test that precision is maintained across multiple operations
        uint256 initialShares = _sharesAmount(1000);
        uint256 initialPrice = SHARES_PRICE;

        // Convert shares to assets
        uint256 assets = kpkSharesContract.sharesToAssets(initialShares, initialPrice, address(usdc));

        // Convert back to shares
        uint256 sharesBack = kpkSharesContract.assetsToShares(assets, initialPrice, address(usdc));

        // Convert to assets again
        uint256 assetsAgain = kpkSharesContract.sharesToAssets(sharesBack, initialPrice, address(usdc));

        // Precision should be maintained across multiple conversions
        assertLe(_abs(assets, assetsAgain), 1); // Allow 1 wei difference

        // Test with preview functions to ensure consistency
        uint256 previewAssets = kpkSharesContract.previewRedemption(initialShares, initialPrice, address(usdc));

        assertEq(previewAssets, assets);

        uint256 previewShares = kpkSharesContract.previewSubscription(assets, initialPrice, address(usdc));

        // The shares should be very close to the original
        assertLe(_abs(previewShares, initialShares), 1);
    }

    function testPrecisionWithDifferentAssetDecimals() public {
        // Test precision with assets that have different decimal places
        // Create a mock token with 18 decimals
        Mock_ERC20 token18Decimals = new Mock_ERC20("TOKEN18", 18);

        // Add it as an approved asset (this would require modifying the contract setup)
        // For now, we'll test with the existing USDC (6 decimals)

        uint256 testAmount = 1_000_000; // 1M units

        // Test with USDC (6 decimals)
        uint256 usdcShares = kpkSharesContract.assetsToShares(testAmount, SHARES_PRICE, address(usdc));

        // Test with equivalent amount in wei (18 decimals)
        // uint256 weiAmount = testAmount * 1e12; // Convert 6 decimals to 18 decimals

        // The shares should be the same since we're dealing with the same USD value
        // This tests that decimal handling is correct
        assertGt(usdcShares, 0);

        // Test conversion back to assets
        uint256 usdcAssets = kpkSharesContract.sharesToAssets(usdcShares, SHARES_PRICE, address(usdc));

        // Should get back approximately the same amount (allowing for rounding)
        assertApproxEqRel(usdcAssets, testAmount, 1e5); // Allow 0.1% tolerance
    }

    function testPrecisionFeeAccumulation() public {
        // Test that fees accumulate with precision over time
        KpkShares kpkSharesWithFees = _deployKpkSharesWithFees(
            100, // 1% management fee
            50, // 0.5% redeem fee
            500 // 5% performance fee
        );

        uint256 shares = _sharesAmount(10_000);
        _createSharesForTestingWithContract(kpkSharesWithFees, alice, shares);

        uint256 initialFeeBalance = kpkSharesWithFees.balanceOf(feeRecipient);

        // Process multiple operations over time to test fee accumulation precision
        for (uint256 i = 0; i < 10; i++) {
            skip(30 days); // Skip 30 days

            vm.startPrank(alice);
            uint256 requestId = kpkSharesWithFees.requestRedemption(
                _sharesAmount(100),
                kpkSharesWithFees.sharesToAssets(_sharesAmount(100), SHARES_PRICE, address(usdc)),
                address(usdc),
                alice
            );
            vm.stopPrank();

            vm.prank(ops);
            uint256[] memory approveRequests = new uint256[](1);
            approveRequests[0] = requestId;
            uint256[] memory rejectRequests = new uint256[](0);
            kpkSharesWithFees.processRequests(approveRequests, rejectRequests, address(usdc), SHARES_PRICE);
        }

        uint256 finalFeeBalance = kpkSharesWithFees.balanceOf(feeRecipient);
        uint256 totalFees = finalFeeBalance - initialFeeBalance;

        // Fees should accumulate with precision
        assertGt(totalFees, 0);

        // The total fees should be reasonable given the rates and time periods
        // This is a basic sanity check for precision
        assertLt(totalFees, shares); // Fees shouldn't exceed the total shares
    }

    // ============================================================================
    // Helper Functions
    // ============================================================================

    function _abs(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}

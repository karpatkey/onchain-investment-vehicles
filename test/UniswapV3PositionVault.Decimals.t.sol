// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IUniswapV3PositionVault} from "../src/IUniswapV3PositionVault.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3Pool.sol";
import {UniswapV3PositionVaultTestBase} from "./UniswapV3PositionVault.TestBase.sol";

/// @title  UniswapV3PositionVaultDecimalsTest
/// @author KPK
/// @notice Runs the vault's core flows against a second live pool whose token0 has 8 decimals
///         rather than 6.
/// @dev    The human price the vault takes is decimal-adjusted, so the conversion between it and
///         Uniswap's sqrt ratio depends on both tokens' decimals. A suite that only ever ran on
///         USDC/WETH would pass with a scaling factor that is wrong for every other pairing. WBTC
///         and WETH also sit far enough apart in value that the raw ratio lands in a different
///         part of Uniswap's range, which is the regime the price conversion handles with a
///         different arrangement of the shift around the square root.
contract UniswapV3PositionVaultDecimalsTest is UniswapV3PositionVaultTestBase {
    function _poolAddress() internal view override returns (address) {
        return POOL_WBTC_WETH;
    }

    function _poolFee() internal view override returns (uint24) {
        return 3000;
    }

    function _token0Address() internal view override returns (address) {
        return WBTC;
    }

    function _fundAmount0() internal view override returns (uint256) {
        return 2_000e8;
    }

    function _fundAmount1() internal view override returns (uint256) {
        return 40_000e18;
    }

    function _feeSwapAmount0() internal view override returns (uint256) {
        return 2e8;
    }

    function _feeSwapAmount1() internal view override returns (uint256) {
        return 60e18;
    }

    function _whaleAmount0() internal view override returns (uint256) {
        return 5_000_000e8;
    }

    function _whaleAmount1() internal view override returns (uint256) {
        return 100_000_000e18;
    }

    function _openAmount0() internal view override returns (uint256) {
        return 20e8;
    }

    function _vaultName() internal view override returns (string memory) {
        return "kpk WBTC/WETH Position";
    }

    function _vaultSymbol() internal view override returns (string memory) {
        return "kpkBW";
    }

    //
    // Price scaling
    //

    function test_initialize_cachesTheEightDecimalScaling() public view {
        assertEq(address(vault.token0()), WBTC, "token0 is WBTC");
        assertEq(vault.priceScaleNum(), 1e18, "numerator is 10**decimals1");
        assertEq(vault.priceScaleDen(), 1e18 * 1e8, "denominator is 1e18 * 10**decimals0");
        assertEq(vault.tickSpacing(), int24(60), "tick spacing cached from the 0.3% tier");
    }

    function test_spotPrice_readsAsWethPerWholeBitcoin() public view {
        uint256 spot = _spotPrice();

        // A whole WBTC is worth tens of WETH, not billions and not fractions. Getting the decimal
        // adjustment wrong moves this by ten orders of magnitude, so the band is deliberately wide
        // and still catches the mistake.
        assertGt(spot, 1e18, "more than one WETH per WBTC");
        assertLt(spot, 1000e18, "fewer than a thousand WETH per WBTC");
    }

    function test_priceConversion_roundTripsAgainstTheLivePool() public view {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(POOL).slot0();

        uint256 humanPrice = vault.sqrtPriceX96ToPrice(sqrtPriceX96);
        uint160 back = vault.priceToSqrtPriceX96(humanPrice);

        assertApproxEqRel(uint256(back), uint256(sqrtPriceX96), 1e10, "round trip within 1e-8");
    }

    function test_priceRangeToTicks_coversTheRequestedRange() public view {
        (uint256 lower, uint256 upper) = _rangeAroundSpot(1500);
        (int24 tickLower, int24 tickUpper) = vault.priceRangeToTicks(lower, upper);

        assertLt(tickLower, tickUpper, "range is non-empty");
        assertEq(tickLower % 60, int24(0), "lower is aligned to the spacing");
        assertEq(tickUpper % 60, int24(0), "upper is aligned to the spacing");
    }

    //
    // Core flows
    //

    function test_createPosition_opensOnTheEightDecimalPool() public {
        (uint256 lower, uint256 upper) = _rangeAroundSpot(1000);
        uint256 amount0 = 20e8;
        uint256 need1 = vault.previewCounterAmountForRange(lower, upper, amount0, true);
        _seedVault(amount0, need1);

        vm.prank(curator);
        (uint256 tokenId, uint128 liquidity, uint256 used0, uint256 used1) =
            vault.createPosition(lower, upper, amount0, true);

        assertGt(tokenId, 0, "position minted");
        assertGt(liquidity, 0, "liquidity minted");
        assertLe(used0, amount0, "never takes more token0 than named");
        assertApproxEqRel(used1, need1, 1e15, "counter amount matches the preview");
        assertEq(vault.totalSupply(), liquidity, "shares bootstrap one to one");
    }

    function test_deposit_andRedeem_roundTripOnTheEightDecimalPool() public {
        _openPosition();

        uint256 before0 = token0.balanceOf(alice);
        uint256 before1 = token1.balanceOf(alice);

        vm.prank(alice);
        (uint256 shares, uint256 spent0, uint256 spent1) = vault.deposit(5e8, true, 500, block.timestamp);

        assertGt(shares, 0, "shares minted");
        assertLe(spent0, 5e8, "never exceeds the token0 maximum");
        assertLe(spent1, 200e18, "never exceeds the token1 maximum");

        vm.prank(alice);
        (uint256 out0, uint256 out1) = vault.redeem(shares, 500, block.timestamp);

        assertGt(out0 + out1, 0, "redemption pays out");
        assertLe(token0.balanceOf(alice), before0, "no free token0");
        assertLe(token1.balanceOf(alice), before1, "no free token1");
    }

    function test_rebalanceWithSwap_movesTheRangeOnTheEightDecimalPool() public {
        _openPosition();
        uint256 oldTokenId = vault.activeTokenId();

        (uint256 balance0, uint256 balance1) = vault.totalAssets();

        uint256 centre = _spotPrice() * 10_400 / 10_000;
        uint256 lower = centre * 8000 / 10_000;
        uint256 upper = centre * 12_000 / 10_000;

        vm.prank(curator);
        (uint256 tokenId, uint128 liquidity,,) = vault.rebalanceWithSwap(lower, upper, 500);

        assertTrue(tokenId != oldTokenId, "the position was replaced");
        assertGt(liquidity, 0, "the new position holds liquidity");

        // The swap has to be sized correctly in 8-decimal units for this bound to hold.
        assertLe(token0.balanceOf(address(vault)) * 10_000, balance0 * 100, "token0 residue is negligible");
        assertLe(token1.balanceOf(address(vault)) * 10_000, balance1 * 100, "token1 residue is negligible");
    }

    function test_collectFees_compoundsOnTheEightDecimalPool() public {
        _openPosition();
        _accrueFees();

        uint128 before = _positionLiquidity();

        vm.prank(curator);
        uint128 added = vault.collectFees();

        assertGt(added, 0, "fees were reinvested");
        assertEq(_positionLiquidity(), before + added, "position grew by the reinvested amount");
    }

    function test_twapGuard_worksOnTheEightDecimalPool() public {
        _openPosition();
        _movePriceBps(4000);

        (uint256 lower, uint256 upper) = _rangeAroundSpot(1000);
        vm.prank(curator);
        vm.expectPartialRevert(IUniswapV3PositionVault.PriceDeviationTooHigh.selector);
        vault.rebalanceWithSwap(lower, upper, 500);
    }
}

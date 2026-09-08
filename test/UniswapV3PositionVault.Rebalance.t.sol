// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IUniswapV3PositionVault} from "../src/IUniswapV3PositionVault.sol";
import {INonfungiblePositionManager} from "../src/interfaces/INonfungiblePositionManager.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3Pool.sol";
import {FullMath} from "../src/libraries/uniswap/FullMath.sol";
import {TickMath} from "../src/libraries/uniswap/TickMath.sol";
import {UniswapV3VaultMath} from "../src/libraries/UniswapV3VaultMath.sol";
import {UniswapV3PositionVaultTestBase} from "./UniswapV3PositionVault.TestBase.sol";

/// @title  UniswapV3PositionVaultRebalanceTest
/// @author KPK
/// @notice Fork tests for the rebalance path: collecting fees, closing the old position, swapping
///         inside the pool to reach the new range's ratio, and minting the largest position the
///         resulting balances support.
contract UniswapV3PositionVaultRebalanceTest is UniswapV3PositionVaultTestBase {
    /// @dev How much of the vault's holdings may be left idle after a rebalance, in basis points.
    ///      The residue comes from wei-level rounding and from the swap crossing initialized ticks,
    ///      both second-order next to the position itself.
    uint256 internal constant MAX_LEFTOVER_BPS = 100;

    function test_rebalanceWithSwap_movesThePositionAndConsumesAlmostEverything() public {
        _openPosition(200_000e6);
        uint256 oldTokenId = vault.activeTokenId();

        (uint256 balance0, uint256 balance1) = vault.totalAssets();
        (uint256 lower, uint256 upper) = _shiftedRange(2000, 500);

        vm.prank(curator);
        (uint256 tokenId, uint128 liquidity,,) = vault.rebalanceWithSwap(lower, upper, 0);

        assertGt(tokenId, 0, "a new position was minted");
        assertTrue(tokenId != oldTokenId, "the position was replaced");
        assertEq(vault.activeTokenId(), tokenId, "the new position is the active one");
        assertGt(liquidity, 0, "the new position holds liquidity");

        vm.expectRevert();
        INonfungiblePositionManager(POSITION_MANAGER).ownerOf(oldTokenId);

        // Almost everything the vault held ended up as liquidity rather than idle.
        uint256 leftover0 = token0.balanceOf(address(vault));
        uint256 leftover1 = token1.balanceOf(address(vault));
        assertLe(leftover0 * 10_000, balance0 * MAX_LEFTOVER_BPS, "token0 residue is negligible");
        assertLe(leftover1 * 10_000, balance1 * MAX_LEFTOVER_BPS, "token1 residue is negligible");
    }

    function test_rebalanceWithSwap_holdsOnlyToken1WhenTheRangeSitsBelowThePrice() public {
        _openPosition(200_000e6);

        // A range entirely below the spot price is funded by token1 alone, so every unit of token0
        // has to be sold to reach it.
        uint256 spot = _spotPrice();
        uint256 lower = spot * 5000 / 10_000;
        uint256 upper = spot * 7000 / 10_000;

        vm.prank(curator);
        (,, uint256 amount0, uint256 amount1) = vault.rebalanceWithSwap(lower, upper, 0);

        assertEq(amount0, 0, "a range below the price takes no token0");
        assertGt(amount1, 0, "it is funded entirely by token1");
        assertLe(token0.balanceOf(address(vault)), 1e6, "token0 was sold, not left behind");
    }

    function test_rebalanceWithSwap_holdsOnlyToken0WhenTheRangeSitsAboveThePrice() public {
        _openPosition(200_000e6);

        uint256 spot = _spotPrice();
        uint256 lower = spot * 14_000 / 10_000;
        uint256 upper = spot * 18_000 / 10_000;

        vm.prank(curator);
        (,, uint256 amount0, uint256 amount1) = vault.rebalanceWithSwap(lower, upper, 0);

        assertGt(amount0, 0, "it is funded entirely by token0");
        assertEq(amount1, 0, "a range above the price takes no token1");
        assertLe(token1.balanceOf(address(vault)), 1e15, "token1 was sold, not left behind");
    }

    function test_rebalanceWithSwap_opensAPositionWhenTheVaultHoldsOnlyIdleTokens() public {
        // No position yet: the vault has never been anything but idle balances.
        _seedVault(100_000e6, 30e18);
        (uint256 lower, uint256 upper) = _rangeAroundSpot(1000);

        vm.prank(curator);
        (uint256 tokenId, uint128 liquidity,,) = vault.rebalanceWithSwap(lower, upper, 0);

        assertGt(tokenId, 0, "a position was opened");
        assertGt(liquidity, 0, "it holds liquidity");
        assertEq(vault.totalSupply(), liquidity, "shares bootstrap from the first position");
    }

    function test_rebalanceWithSwap_worksFromASingleSidedBalance() public {
        _seedVault(250_000e6, 0);
        (uint256 lower, uint256 upper) = _rangeAroundSpot(1500);

        vm.prank(curator);
        (, uint128 liquidity,, uint256 amount1) = vault.rebalanceWithSwap(lower, upper, 0);

        assertGt(liquidity, 0, "a two-sided position was funded from one token");
        assertGt(amount1, 0, "the swap produced the other side");
    }

    function test_rebalanceWithSwap_revertsWhenThereIsNothingToWorkWith() public {
        (uint256 lower, uint256 upper) = _rangeAroundSpot(1000);

        vm.prank(curator);
        vm.expectRevert(IUniswapV3PositionVault.NothingToRebalance.selector);
        vault.rebalanceWithSwap(lower, upper, 0);
    }

    function test_rebalanceWithSwap_collectsFeesBeforeMovingTheRange() public {
        _openPosition(200_000e6);
        _accrueFees();

        // The position manager only refreshes a position's owed balance when the position is
        // touched, so fees earned since the last touch are invisible to totalAssets. That makes the
        // reading below a floor on what the vault owns, which is the safe direction: the rebalance
        // collects those fees and folds them in, so the value after must clear the value before.
        (uint256 before0, uint256 before1) = vault.totalAssets();
        (uint256 lower, uint256 upper) = _shiftedRange(1500, 400);

        vm.prank(curator);
        vault.rebalanceWithSwap(lower, upper, 0);

        (uint256 after0, uint256 after1) = vault.totalAssets();

        // Value is conserved apart from the pool fee paid on the swap, so measure both sides
        // together at the spot price rather than each in isolation.
        uint256 valueBefore = _valueInToken1(before0, before1);
        uint256 valueAfter = _valueInToken1(after0, after1);
        assertGe(valueAfter * 10_000, valueBefore * 9900, "value survives the move");
        assertEq(vault.activeTokenId() == 0, false, "a new position is open");
    }

    function test_rebalanceWithSwap_rejectsAPriceLimitOnTheWrongSide() public {
        _openPosition(200_000e6);

        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(POOL).slot0();

        // Moving into a range below the price sells token0, which pushes the price down, so a limit
        // above the current price could never be reached and is rejected rather than ignored.
        uint256 spot = _spotPrice();
        uint256 lower = spot * 5000 / 10_000;
        uint256 upper = spot * 7000 / 10_000;

        vm.prank(curator);
        vm.expectRevert(IUniswapV3PositionVault.InvalidSqrtPriceLimit.selector);
        vault.rebalanceWithSwap(lower, upper, uint160(uint256(sqrtPriceX96) * 11 / 10));
    }

    function test_rebalanceWithSwap_honoursATighterPriceLimit() public {
        _openPosition(200_000e6);

        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(POOL).slot0();

        uint256 spot = _spotPrice();
        uint256 lower = spot * 5000 / 10_000;
        uint256 upper = spot * 7000 / 10_000;

        // A limit just below the current price stops the swap almost immediately, so most of the
        // token0 cannot be sold and stays idle. The mint must still succeed.
        vm.prank(curator);
        (, uint128 liquidity,,) = vault.rebalanceWithSwap(lower, upper, uint160(uint256(sqrtPriceX96) * 9999 / 10_000));

        assertGt(liquidity, 0, "a partially filled swap still mints");
        assertGt(token0.balanceOf(address(vault)), 0, "the unsold token0 stays idle");
    }

    function test_rebalanceWithSwap_leavesResidueThatTheNextDepositCompoundsAway() public {
        _openPosition(200_000e6);
        (uint256 lower, uint256 upper) = _shiftedRange(2000, 500);

        vm.prank(curator);
        vault.rebalanceWithSwap(lower, upper, 0);

        uint128 before = _positionLiquidity();

        // A deposit compounds whatever the rebalance left behind before pricing the new shares.
        vm.prank(alice);
        vault.deposit(10_000e6, 10e18, 0, 0, block.timestamp);

        assertGt(_positionLiquidity(), before, "the residue went back to work");
    }

    function test_rebalanceWithSwap_keepsShareholdersWholeAcrossTheMove() public {
        _openPosition(200_000e6);

        vm.prank(alice);
        (uint256 shares,,) = vault.deposit(50_000e6, 50e18, 0, 0, block.timestamp);

        (uint256 before0, uint256 before1) = vault.previewRedeem(shares);
        (uint256 lower, uint256 upper) = _shiftedRange(1200, 400);

        vm.prank(curator);
        vault.rebalanceWithSwap(lower, upper, 0);

        (uint256 after0, uint256 after1) = vault.previewRedeem(shares);

        // The holder's claim is worth the same before and after, apart from the swap fee.
        uint256 valueBefore = _valueInToken1(before0, before1);
        uint256 valueAfter = _valueInToken1(after0, after1);
        assertGe(valueAfter * 10_000, valueBefore * 9900, "the holder is not diluted by a rebalance");
    }

    //
    // The no-swap variant
    //

    function test_rebalance_movesTheRangeWithoutTrading() public {
        _openPosition();
        uint256 oldTokenId = vault.activeTokenId();

        uint256 poolToken0Before = token0.balanceOf(POOL);
        uint256 poolToken1Before = token1.balanceOf(POOL);
        (uint256 lower, uint256 upper) = _shiftedRange(2000, 500);

        vm.prank(curator);
        (uint256 tokenId, uint128 liquidity,,) = vault.rebalance(lower, upper);

        assertTrue(tokenId != oldTokenId, "the position was replaced");
        assertGt(liquidity, 0, "the new position holds liquidity");

        // Nothing was traded, so the pool's balances only moved by what the position itself
        // withdrew and put back, never by a swap in one direction.
        assertLe(
            _absDiff(token0.balanceOf(POOL), poolToken0Before), poolToken0Before / 100, "the pool's token0 barely moved"
        );
        assertLe(
            _absDiff(token1.balanceOf(POOL), poolToken1Before), poolToken1Before / 100, "the pool's token1 barely moved"
        );
    }

    function test_rebalance_leavesASurplusOfExactlyOneToken() public {
        _openPosition();

        // Shift the range so the new position wants a different mix than the old one held, which is
        // what leaves a surplus once no trade is allowed to correct it.
        (uint256 lower, uint256 upper) = _shiftedRange(1000, 1500);

        vm.prank(curator);
        vault.rebalance(lower, upper);

        uint256 leftover0 = token0.balanceOf(address(vault));
        uint256 leftover1 = token1.balanceOf(address(vault));

        // Without a swap the mint consumes one side and leaves the other. Both being large would
        // mean the mint failed to use what it had.
        assertTrue(leftover0 <= 1e6 || leftover1 <= 1e12, "one side must be consumed");
        assertGt(leftover0 + leftover1, 0, "the other side is the surplus");
    }

    function test_rebalance_mintsAsMuchLiquidityAsTheBalancesAllow() public {
        _openPosition();
        (uint256 lower, uint256 upper) = _shiftedRange(2000, 500);

        vm.prank(curator);
        (,, uint256 used0, uint256 used1) = vault.rebalance(lower, upper);

        // Whatever is left cannot fund any more liquidity in the range that was just minted, which
        // is what "as much as available" means when trading is off the table.
        (int24 tickLower, int24 tickUpper,,,) = vault.activePosition();
        (uint160 sqrtRatioAX96, uint160 sqrtRatioBX96) = UniswapV3VaultMath.sqrtRatiosForTicks(tickLower, tickUpper);
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(POOL).slot0();

        uint128 stillMintable = UniswapV3VaultMath.mintableLiquidity(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            token0.balanceOf(address(vault)),
            token1.balanceOf(address(vault))
        );

        assertEq(stillMintable, 0, "the leftover cannot fund any more liquidity");
        assertGt(used0 + used1, 0, "the mint consumed something");
    }

    function test_rebalance_opensAPositionWithoutTradingWhenThereIsNoneYet() public {
        _seedVault(100_000e6, 30e18);
        (uint256 lower, uint256 upper) = _rangeAroundSpot(1000);

        vm.prank(curator);
        (uint256 tokenId, uint128 liquidity,,) = vault.rebalance(lower, upper);

        assertGt(tokenId, 0, "a position was opened");
        assertEq(vault.totalSupply(), liquidity, "shares bootstrap from the first position");
    }

    function test_rebalance_revertsWhenTheRangeCannotBeFunded() public {
        // A range wholly above the price is funded by token0 alone, so a vault holding only token1
        // has nothing the range can use and, without a swap, no way to get any.
        _seedVault(0, 10e18);

        uint256 spot = _spotPrice();
        vm.prank(curator);
        vm.expectRevert(IUniswapV3PositionVault.NothingToRebalance.selector);
        vault.rebalance(spot * 14_000 / 10_000, spot * 18_000 / 10_000);
    }

    function test_rebalance_revertsWhenThereIsNothingToWorkWith() public {
        (uint256 lower, uint256 upper) = _rangeAroundSpot(1000);

        vm.prank(curator);
        vm.expectRevert(IUniswapV3PositionVault.NothingToRebalance.selector);
        vault.rebalance(lower, upper);
    }

    function test_rebalance_isBlockedAtAManipulatedPrice() public {
        _openPosition();
        _movePriceBps(4000);

        (uint256 lower, uint256 upper) = _rangeAroundSpot(1000);
        vm.prank(curator);
        vm.expectPartialRevert(IUniswapV3PositionVault.PriceDeviationTooHigh.selector);
        vault.rebalance(lower, upper);
    }

    function test_rebalance_rejectsEveryCallerButTheCurator() public {
        _openPosition();
        (uint256 lower, uint256 upper) = _rangeAroundSpot(1000);

        vm.prank(stranger);
        vm.expectRevert(IUniswapV3PositionVault.NotAuthorized.selector);
        vault.rebalance(lower, upper);
    }

    function test_rebalance_collectsFeesBeforeMoving() public {
        _openPosition();
        _accrueFees();

        (uint256 before0, uint256 before1) = vault.totalAssets();
        (uint256 lower, uint256 upper) = _shiftedRange(1500, 400);

        vm.prank(curator);
        vault.rebalance(lower, upper);

        (uint256 after0, uint256 after1) = vault.totalAssets();

        // No swap means no fee is paid to the pool, so value is conserved and the fees the old
        // position had earned must show up on the other side of the move.
        assertGe(_valueInToken1(after0, after1), _valueInToken1(before0, before1), "value is conserved");
    }

    function test_rebalanceWithSwap_putsMoreToWorkThanTheNoSwapVariant() public {
        (uint256 lower, uint256 upper) = _shiftedRange(1000, 1500);

        uint256 snapshot = vm.snapshotState();

        _openPosition();
        vm.prank(curator);
        (, uint128 withoutSwap,,) = vault.rebalance(lower, upper);

        vm.revertToState(snapshot);

        _openPosition();
        vm.prank(curator);
        (, uint128 withSwap,,) = vault.rebalanceWithSwap(lower, upper, 0);

        // Trading the surplus into the side the range actually wants is the whole point of the
        // swapping variant, so it must mint strictly more from the same starting balances.
        assertGt(withSwap, withoutSwap, "swapping puts more of the balance to work");
    }

    //
    // Helpers
    //

    /// @notice The absolute difference between two amounts.
    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    /// @notice A range of the given half-width, centred a fraction away from the current price.
    /// @param widthBps How far the range extends either side of its centre.
    /// @param shiftBps How far the centre sits above the current price.
    function _shiftedRange(uint256 widthBps, uint256 shiftBps) internal view returns (uint256 lower, uint256 upper) {
        uint256 centre = _spotPrice() * (10_000 + shiftBps) / 10_000;
        lower = centre * (10_000 - widthBps) / 10_000;
        upper = centre * (10_000 + widthBps) / 10_000;
    }

    /// @notice Values a token0 and token1 pair in token1 base units at the pool's current price.
    /// @dev    The human price is decimal-adjusted, so converting a base-unit amount of token0 has
    ///         to reapply both tokens' decimals; the vault's cached scaling factors carry exactly
    ///         that conversion. Getting this wrong makes a change of composition look like a change
    ///         of value, which is the whole thing these tests are trying to measure.
    function _valueInToken1(uint256 amount0, uint256 amount1) internal view returns (uint256) {
        uint256 converted = FullMath.mulDiv(amount0, _spotPrice() * vault.priceScaleNum(), vault.priceScaleDen());
        return amount1 + converted;
    }
}

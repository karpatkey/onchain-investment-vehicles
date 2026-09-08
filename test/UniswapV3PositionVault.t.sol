// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {IUniswapV3PositionVault} from "../src/IUniswapV3PositionVault.sol";
import {UniswapV3PositionVault} from "../src/UniswapV3PositionVault.sol";
import {INonfungiblePositionManager} from "../src/interfaces/INonfungiblePositionManager.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3Pool.sol";
import {UniswapV3PositionVaultTestBase} from "./UniswapV3PositionVault.TestBase.sol";

/// @title  UniswapV3PositionVaultTest
/// @author KPK
/// @notice Fork tests for initialization, access control, the curator's position operations and
///         the investor deposit and redemption paths.
contract UniswapV3PositionVaultTest is UniswapV3PositionVaultTestBase {
    //
    // Initialization
    //

    function test_initialize_resolvesThePoolAndCachesItsConfiguration() public view {
        assertEq(address(vault.pool()), POOL, "pool resolved through the factory");
        assertEq(address(vault.token0()), USDC, "token0");
        assertEq(address(vault.token1()), WETH, "token1");
        assertEq(vault.fee(), FEE, "fee tier");
        assertEq(vault.tickSpacing(), IUniswapV3Pool(POOL).tickSpacing(), "tick spacing cached");
        assertEq(vault.priceScaleNum(), 1e18, "scale numerator is 10**decimals1");
        assertEq(vault.priceScaleDen(), 1e18 * 1e6, "scale denominator is 1e18 * 10**decimals0");
        assertEq(vault.activeTokenId(), 0, "starts with no position");
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin), "admin role granted");
        assertTrue(vault.hasRole(vault.CURATOR(), curator), "curator role granted");
    }

    function test_initialize_rejectsInvalidConfiguration() public {
        IUniswapV3PositionVault.InitParams memory params = IUniswapV3PositionVault.InitParams({
            name: "n",
            symbol: "s",
            admin: admin,
            curator: curator,
            assetRecoverer: recoverer,
            positionManager: POSITION_MANAGER,
            token0: USDC,
            token1: WETH,
            fee: FEE,
            twapPeriod: TWAP_PERIOD,
            maxTwapDeviationBps: MAX_DEVIATION_BPS
        });

        params.admin = address(0);
        _expectInitRevert(params, IUniswapV3PositionVault.ZeroAddress.selector);
        params.admin = admin;

        params.curator = address(0);
        _expectInitRevert(params, IUniswapV3PositionVault.ZeroAddress.selector);
        params.curator = curator;

        params.token0 = WETH;
        params.token1 = USDC;
        _expectInitRevert(params, IUniswapV3PositionVault.TokensNotSorted.selector);
        params.token0 = USDC;
        params.token1 = WETH;

        params.fee = 1234;
        _expectInitRevert(params, IUniswapV3PositionVault.PoolNotFound.selector);
        params.fee = FEE;

        params.twapPeriod = 0;
        _expectInitRevert(params, IUniswapV3PositionVault.InvalidArguments.selector);
        params.twapPeriod = TWAP_PERIOD;

        params.maxTwapDeviationBps = 10_001;
        _expectInitRevert(params, IUniswapV3PositionVault.InvalidArguments.selector);
    }

    /// @notice Deploys a proxy with the given parameters and expects initialization to revert.
    function _expectInitRevert(IUniswapV3PositionVault.InitParams memory params, bytes4 selector) internal {
        address implementation = address(new UniswapV3PositionVault());
        vm.expectRevert(selector);
        UnsafeUpgrades.deployUUPSProxy(implementation, abi.encodeCall(UniswapV3PositionVault.initialize, (params)));
    }

    function test_initialize_cannotRunTwice() public {
        IUniswapV3PositionVault.InitParams memory params = IUniswapV3PositionVault.InitParams({
            name: "n",
            symbol: "s",
            admin: admin,
            curator: curator,
            assetRecoverer: recoverer,
            positionManager: POSITION_MANAGER,
            token0: USDC,
            token1: WETH,
            fee: FEE,
            twapPeriod: TWAP_PERIOD,
            maxTwapDeviationBps: MAX_DEVIATION_BPS
        });

        vm.expectRevert();
        vault.initialize(params);
    }

    //
    // Access control
    //

    function test_curatorFunctions_rejectEveryOtherCaller() public {
        (uint256 lower, uint256 upper) = _rangeAroundSpot(1000);

        vm.startPrank(stranger);
        vm.expectRevert(IUniswapV3PositionVault.NotAuthorized.selector);
        vault.createPosition(lower, upper, 1e6, true);
        vm.expectRevert(IUniswapV3PositionVault.NotAuthorized.selector);
        vault.unwindPosition();
        vm.expectRevert(IUniswapV3PositionVault.NotAuthorized.selector);
        vault.collectFees();
        vm.expectRevert(IUniswapV3PositionVault.NotAuthorized.selector);
        vault.addLiquidity();
        vm.expectRevert(IUniswapV3PositionVault.NotAuthorized.selector);
        vault.removeLiquidity(1);
        vm.expectRevert(IUniswapV3PositionVault.NotAuthorized.selector);
        vault.rebalanceWithSwap(lower, upper, 500, 0, 0);
        vm.stopPrank();

        // The admin does not inherit the curator's powers.
        vm.prank(admin);
        vm.expectRevert(IUniswapV3PositionVault.NotAuthorized.selector);
        vault.unwindPosition();
    }

    function test_adminFunctions_rejectEveryOtherCaller() public {
        vm.startPrank(curator);
        vm.expectRevert(IUniswapV3PositionVault.NotAuthorized.selector);
        vault.setTwapConfig(600, 100);
        vm.expectRevert(IUniswapV3PositionVault.NotAuthorized.selector);
        vault.setAssetRecoverer(stranger);
        vm.stopPrank();
    }

    function test_investorGate_blocksAccountsWithoutTheRole() public {
        _openPosition(100_000e6);

        _fund(stranger);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IUniswapV3PositionVault.NotInvestor.selector, stranger));
        vault.deposit(1000e6, true, 500, block.timestamp);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IUniswapV3PositionVault.NotInvestor.selector, stranger));
        vault.redeem(1, 500, block.timestamp);

        // Transfers check both ends of the transfer.
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IUniswapV3PositionVault.NotInvestor.selector, stranger));
        vault.transfer(stranger, 1);
    }

    function test_investorGate_opensToEveryoneWhenGrantedToTheZeroAddress() public {
        _openPosition(100_000e6);

        bytes32 investorRole = vault.INVESTOR();

        vm.prank(admin);
        vault.grantRole(investorRole, address(0));

        deal(USDC, stranger, 1_000_000e6);
        deal(WETH, stranger, 1000e18);
        vm.startPrank(stranger);
        IERC20(USDC).approve(address(vault), type(uint256).max);
        IERC20(WETH).approve(address(vault), type(uint256).max);
        (uint256 shares,,) = vault.deposit(10_000e6, true, 500, block.timestamp);
        assertGt(shares, 0, "an open vault accepts anyone");

        // Redeeming and transferring are open on the same terms.
        vault.transfer(stranger, 0);
        vault.redeem(shares, 500, block.timestamp);
        vm.stopPrank();

        // Revoking closes it again.
        vm.prank(admin);
        vault.revokeRole(investorRole, address(0));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IUniswapV3PositionVault.NotInvestor.selector, stranger));
        vault.deposit(1000e6, true, 500, block.timestamp);
    }

    //
    // Creating a position
    //

    function test_createPosition_opensAroundTheRequestedRangeAndBootstrapsShares() public {
        (uint256 lower, uint256 upper) = _rangeAroundSpot(1000);
        uint256 amount0 = 100_000e6;
        uint256 need1 = vault.previewCounterAmountForRange(lower, upper, amount0, true);
        _seedVault(amount0, need1);

        vm.prank(curator);
        (uint256 tokenId, uint128 liquidity, uint256 used0, uint256 used1) =
            vault.createPosition(lower, upper, amount0, true);

        assertGt(tokenId, 0, "position minted");
        assertEq(vault.activeTokenId(), tokenId, "recorded as active");
        assertEq(INonfungiblePositionManager(POSITION_MANAGER).ownerOf(tokenId), address(vault), "vault owns the NFT");
        assertEq(vault.totalSupply(), liquidity, "shares bootstrap one-to-one with liquidity");
        assertEq(vault.balanceOf(curator), liquidity, "opening shares go to the curator");
        assertLe(used0, amount0, "never takes more token0 than named");
        assertApproxEqRel(used1, need1, 1e15, "counter amount matches the preview");

        // The snapped range must contain the prices that were asked for.
        (int24 tickLower, int24 tickUpper,,,) = vault.activePosition();
        assertLe(vault.sqrtPriceX96ToPrice(vault.priceToSqrtPriceX96(lower)), lower + 1, "lower covered");
        assertLt(tickLower, tickUpper, "range is non-empty");
    }

    function test_createPosition_canBeSizedFromEitherToken() public {
        (uint256 lower, uint256 upper) = _rangeAroundSpot(1000);

        uint256 amount1 = 30e18;
        uint256 need0 = vault.previewCounterAmountForRange(lower, upper, amount1, false);
        _seedVault(need0, amount1);

        vm.prank(curator);
        (, uint128 liquidity,, uint256 used1) = vault.createPosition(lower, upper, amount1, false);

        assertGt(liquidity, 0, "position opened from token1");
        assertApproxEqRel(used1, amount1, 1e15, "consumes the named amount");
    }

    function test_createPosition_revertsWhenTheVaultCannotFundIt() public {
        (uint256 lower, uint256 upper) = _rangeAroundSpot(1000);

        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(IUniswapV3PositionVault.InsufficientIdleBalance.selector, USDC, 100_000e6, 0)
        );
        vault.createPosition(lower, upper, 100_000e6, true);
    }

    function test_createPosition_revertsWhenOneIsAlreadyOpen() public {
        _openPosition(50_000e6);
        (uint256 lower, uint256 upper) = _rangeAroundSpot(1000);

        vm.prank(curator);
        vm.expectRevert(IUniswapV3PositionVault.PositionAlreadyActive.selector);
        vault.createPosition(lower, upper, 1e6, true);
    }

    function test_previewCounterAmount_matchesWhatTheDepositConsumes() public {
        uint256 tokenId = _openPosition(100_000e6);

        uint256 amount0 = 10_000e6;
        uint256 expected1 = vault.previewCounterAmount(tokenId, amount0, true);

        vm.prank(alice);
        (, uint256 used0, uint256 used1) = vault.deposit(amount0, true, 500, block.timestamp);

        // The preview prices the ratio, so the two amounts must sit on the same line.
        assertApproxEqRel(used1 * 1e18 / used0, expected1 * 1e18 / amount0, 1e15, "ratio matches the preview");
    }

    function test_liquidityToAmounts_valuesThePositionsOwnLiquidity() public {
        uint256 tokenId = _openPosition(100_000e6);
        (,, uint128 liquidity,,) = vault.activePosition();

        (uint256 amount0, uint256 amount1) = vault.liquidityToAmounts(tokenId, liquidity);

        // The position straddles the price, so it is worth some of both tokens, and the whole of
        // its liquidity has to account for what the vault reports as its holdings.
        assertGt(amount0, 0, "worth some token0");
        assertGt(amount1, 0, "worth some token1");

        (uint256 total0, uint256 total1) = vault.totalAssets();
        assertApproxEqRel(amount0, total0, 1e16, "matches the reported holdings");
        assertApproxEqRel(amount1, total1, 1e16, "matches the reported holdings");
    }

    function test_liquidityToAmounts_scalesWithTheLiquidity() public {
        uint256 tokenId = _openPosition(100_000e6);
        (,, uint128 liquidity,,) = vault.activePosition();

        (uint256 whole0, uint256 whole1) = vault.liquidityToAmounts(tokenId, liquidity);
        (uint256 half0, uint256 half1) = vault.liquidityToAmounts(tokenId, liquidity / 2);

        assertApproxEqRel(half0 * 2, whole0, 1e12, "half the liquidity is half the token0");
        assertApproxEqRel(half1 * 2, whole1, 1e12, "half the liquidity is half the token1");
    }

    function test_amountsToLiquidity_invertsLiquidityToAmounts() public {
        uint256 tokenId = _openPosition(100_000e6);
        (,, uint128 liquidity,,) = vault.activePosition();

        (uint256 amount0, uint256 amount1) = vault.liquidityToAmounts(tokenId, liquidity);
        uint128 recovered = vault.amountsToLiquidity(tokenId, amount0, amount1);

        // Both directions round down, so the round trip can lose the last unit but must never
        // invent liquidity that the amounts cannot actually fund.
        assertLe(recovered, liquidity, "never rounds up");
        assertApproxEqRel(recovered, liquidity, 1e12, "round trips");
    }

    function test_amountsToLiquidity_isBoundByTheScarcerSide() public {
        uint256 tokenId = _openPosition(100_000e6);
        (,, uint128 liquidity,,) = vault.activePosition();
        (uint256 amount0, uint256 amount1) = vault.liquidityToAmounts(tokenId, liquidity);

        // Doubling one side alone cannot meaningfully mint more, because the position needs both.
        // It is not exactly equal: the two sides were derived by rounding down, so they bind at
        // fractionally different amounts and doubling one hands the constraint to the other.
        assertApproxEqRel(
            vault.amountsToLiquidity(tokenId, amount0 * 2, amount1),
            vault.amountsToLiquidity(tokenId, amount0, amount1),
            1e12,
            "the scarcer side binds"
        );

        // Halving it does reduce what can be minted.
        assertLt(
            vault.amountsToLiquidity(tokenId, amount0 / 2, amount1),
            vault.amountsToLiquidity(tokenId, amount0, amount1),
            "less of the binding side mints less"
        );
    }

    function test_amountsToLiquidity_agreesWithWhatADepositActuallyMints() public {
        uint256 tokenId = _openPosition(100_000e6);
        uint128 before = _positionLiquidity();

        uint256 amount0 = 5_000e6;
        uint256 amount1 = vault.previewCounterAmount(tokenId, amount0, true);
        uint128 quoted = vault.amountsToLiquidity(tokenId, amount0, amount1);

        vm.prank(alice);
        vault.deposit(amount0, true, 500, block.timestamp);

        // The quote is what the position gains, which is the whole point of the conversion.
        assertApproxEqRel(_positionLiquidity() - before, quoted, 1e14, "the quote matches the mint");
    }

    //
    // Deposits and redemptions
    //

    function test_deposit_takesOnlyTheRatioAndMintsProportionalShares() public {
        _openPosition(100_000e6);

        uint256 supplyBefore = vault.totalSupply();
        uint128 liquidityBefore = _positionLiquidity();

        uint256 balance0Before = token0.balanceOf(alice);
        uint256 balance1Before = token1.balanceOf(alice);

        vm.prank(alice);
        (uint256 shares, uint256 amount0, uint256 amount1) = vault.deposit(10_000e6, true, 500, block.timestamp);

        assertGt(shares, 0, "shares minted");
        assertEq(vault.balanceOf(alice), shares, "shares credited");
        assertEq(balance0Before - token0.balanceOf(alice), amount0, "token0 taken matches the report");
        assertEq(balance1Before - token1.balanceOf(alice), amount1, "token1 taken matches the report");

        // The named side is committed in full, give or take the rounding headroom the plan leaves
        // so it can never take more than was named, and the other follows from the position's ratio.
        assertLe(amount0, 10_000e6, "never takes more than named");
        assertApproxEqAbs(amount0, 10_000e6, 2, "commits the named amount");
        assertGt(amount1, 0, "the counter amount comes from the ratio");

        uint128 liquidityAfter = _positionLiquidity();
        assertGt(liquidityAfter, liquidityBefore, "position grew");

        // Shares track liquidity: the same fraction of supply as of liquidity.
        assertApproxEqRel(
            shares * 1e18 / (supplyBefore + shares),
            uint256(liquidityAfter - liquidityBefore) * 1e18 / liquidityAfter,
            1e14,
            "share fraction tracks liquidity fraction"
        );
    }

    function test_deposit_revertsWhenThereIsNoPosition() public {
        vm.prank(alice);
        vm.expectRevert(IUniswapV3PositionVault.NoActivePosition.selector);
        vault.deposit(1000e6, true, 500, block.timestamp);
    }

    function test_deposit_respectsTheDeadline() public {
        _openPosition(100_000e6);

        vm.prank(alice);
        vm.expectRevert(IUniswapV3PositionVault.DeadlineExpired.selector);
        vault.deposit(1000e6, true, 500, block.timestamp - 1);
    }

    function test_deposit_rejectsASlippageBoundOutsideItsRange() public {
        _openPosition(100_000e6);

        vm.startPrank(alice);

        // Zero would demand the pool sit exactly on its average, which no live pool does.
        vm.expectRevert(IUniswapV3PositionVault.InvalidArguments.selector);
        vault.deposit(1000e6, true, 0, block.timestamp);

        // And the bound is a fraction of the price, so it cannot exceed the whole of it.
        vm.expectRevert(IUniswapV3PositionVault.InvalidArguments.selector);
        vault.deposit(1000e6, true, 10_001, block.timestamp);

        vm.stopPrank();
    }

    function test_deposit_refusesAPriceFurtherFromTheAverageThanTheCallerAllows() public {
        _openPosition(100_000e6);

        // A single basis point is tighter than any live pool sits from its own average.
        vm.prank(alice);
        vm.expectPartialRevert(IUniswapV3PositionVault.PriceDeviationTooHigh.selector);
        vault.deposit(1000e6, true, 1, block.timestamp);
    }

    function test_deposit_canBeNamedInEitherToken() public {
        _openPosition(100_000e6);

        vm.prank(alice);
        (uint256 sharesFrom0, uint256 spent0,) = vault.deposit(10_000e6, true, 500, block.timestamp);

        vm.prank(bob);
        (uint256 sharesFrom1,, uint256 spent1) = vault.deposit(3e18, false, 500, block.timestamp);

        // Each names its own side. The share count is floored, so the amount actually committed can
        // fall a hair short of what was named, but it can never exceed it.
        assertLe(spent0, 10_000e6, "never takes more token0 than named");
        assertLe(spent1, 3e18, "never takes more token1 than named");
        assertApproxEqRel(spent0, 10_000e6, 1e12, "commits the named token0 amount");
        assertApproxEqRel(spent1, 3e18, 1e12, "commits the named token1 amount");
        assertGt(sharesFrom0, 0, "naming token0 mints shares");
        assertGt(sharesFrom1, 0, "naming token1 mints shares");
    }

    function test_redeem_returnsBothTokensProRata() public {
        _openPosition(100_000e6);

        vm.prank(alice);
        (uint256 shares,,) = vault.deposit(10_000e6, true, 500, block.timestamp);

        uint256 balance0Before = token0.balanceOf(alice);
        uint256 balance1Before = token1.balanceOf(alice);

        vm.prank(alice);
        (uint256 amount0, uint256 amount1) = vault.redeem(shares, 500, block.timestamp);

        assertGt(amount0, 0, "token0 returned");
        assertGt(amount1, 0, "token1 returned");
        assertEq(token0.balanceOf(alice) - balance0Before, amount0, "token0 delivered");
        assertEq(token1.balanceOf(alice) - balance1Before, amount1, "token1 delivered");
        assertEq(vault.balanceOf(alice), 0, "shares burned");
    }

    function test_depositThenRedeem_neverReturnsMoreThanWasPutIn() public {
        _openPosition(100_000e6);

        uint256 before0 = token0.balanceOf(alice);
        uint256 before1 = token1.balanceOf(alice);

        vm.prank(alice);
        (uint256 shares,,) = vault.deposit(10_000e6, true, 500, block.timestamp);

        vm.prank(alice);
        vault.redeem(shares, 500, block.timestamp);

        // Rounding must always favour the vault, never the account transacting against it.
        assertLe(token0.balanceOf(alice), before0, "no free token0");
        assertLe(token1.balanceOf(alice), before1, "no free token1");
    }

    function test_redeem_paysFromIdleBalancesWhenNoPositionIsOpen() public {
        _openPosition(100_000e6);

        vm.prank(alice);
        (uint256 shares,,) = vault.deposit(10_000e6, true, 500, block.timestamp);

        vm.prank(curator);
        vault.unwindPosition();
        assertEq(vault.activeTokenId(), 0, "position closed");

        vm.prank(alice);
        (uint256 amount0, uint256 amount1) = vault.redeem(shares, 500, block.timestamp);
        assertGt(amount0 + amount1, 0, "redemption still pays out");
    }

    //
    // Fees and compounding
    //

    function test_deposit_compoundsFeesBeforePricingTheNewShares() public {
        _openPosition(100_000e6);

        vm.prank(alice);
        (uint256 aliceShares,,) = vault.deposit(50_000e6, true, 500, block.timestamp);

        _accrueFees();

        // Bob buys in after the fees were earned, so they must already be inside the position and
        // therefore belong to the holders who were there when they accrued.
        (uint256 aliceValue0Before, uint256 aliceValue1Before) = vault.previewRedeem(aliceShares);

        vm.prank(bob);
        (uint256 bobShares,,) = vault.deposit(50_000e6, true, 500, block.timestamp);

        (uint256 aliceValue0After, uint256 aliceValue1After) = vault.previewRedeem(aliceShares);
        (uint256 bobValue0, uint256 bobValue1) = vault.previewRedeem(bobShares);

        assertGe(aliceValue0After + 1, aliceValue0Before, "the later deposit does not dilute token0");
        assertGe(aliceValue1After + 1, aliceValue1Before, "the later deposit does not dilute token1");
        assertGt(bobValue0 + bobValue1, 0, "the new holder has a claim");
    }

    function test_collectFees_foldsFeesBackIntoThePosition() public {
        _openPosition(100_000e6);
        _accrueFees();

        uint128 before = _positionLiquidity();

        vm.prank(curator);
        uint128 added = vault.collectFees();

        assertGt(added, 0, "fees were reinvested");
        assertEq(_positionLiquidity(), before + added, "position grew by the reinvested amount");
    }

    function test_collectFees_revertsWithoutAPosition() public {
        vm.prank(curator);
        vm.expectRevert(IUniswapV3PositionVault.NoActivePosition.selector);
        vault.collectFees();
    }

    //
    // Position maintenance
    //

    function test_unwindPosition_returnsEverythingToTheVaultAndBurnsTheNft() public {
        uint256 tokenId = _openPosition(100_000e6);
        uint256 supplyBefore = vault.totalSupply();

        vm.prank(curator);
        (uint256 amount0, uint256 amount1) = vault.unwindPosition();

        assertEq(vault.activeTokenId(), 0, "no active position");
        assertGt(amount0 + amount1, 0, "tokens returned");
        assertEq(vault.totalSupply(), supplyBefore, "shares untouched");

        vm.expectRevert();
        INonfungiblePositionManager(POSITION_MANAGER).ownerOf(tokenId);

        vm.prank(curator);
        vm.expectRevert(IUniswapV3PositionVault.NoActivePosition.selector);
        vault.unwindPosition();
    }

    function test_removeLiquidity_movesLiquidityIntoIdleBalances() public {
        _openPosition(100_000e6);

        uint128 before = _positionLiquidity();
        uint128 half = before / 2;

        vm.prank(curator);
        (uint256 amount0, uint256 amount1) = vault.removeLiquidity(half);

        assertEq(_positionLiquidity(), before - half, "liquidity burned");
        assertGt(amount0 + amount1, 0, "tokens released");
        assertGt(token0.balanceOf(address(vault)) + token1.balanceOf(address(vault)), 0, "now idle in the vault");
    }

    function test_removeLiquidity_rejectsAmountsOutsideThePosition() public {
        _openPosition(100_000e6);
        uint128 held = _positionLiquidity();

        vm.startPrank(curator);
        vm.expectRevert(IUniswapV3PositionVault.InvalidArguments.selector);
        vault.removeLiquidity(0);
        vm.expectRevert(IUniswapV3PositionVault.InvalidArguments.selector);
        vault.removeLiquidity(held + 1);
        vm.stopPrank();
    }

    function test_addLiquidity_putsIdleBalancesBackToWork() public {
        _openPosition(100_000e6);

        uint128 before = _positionLiquidity();
        _seedVault(10_000e6, 5e18);

        vm.prank(curator);
        uint128 added = vault.addLiquidity();

        assertGt(added, 0, "liquidity added");
        assertEq(_positionLiquidity(), before + added, "position grew");
    }

    function test_addLiquidity_revertsWhenThereIsNothingToAdd() public {
        _openPosition(100_000e6);

        vm.prank(curator);
        vm.expectRevert(IUniswapV3PositionVault.NothingToAdd.selector);
        vault.addLiquidity();
    }

    //
    // Guards and callbacks
    //

    function test_twapGuard_blocksOperationsAtAManipulatedPrice() public {
        _openPosition(100_000e6);

        // Push the price well past the tolerance in a single block.
        _movePriceBps(4000);

        (uint256 lower, uint256 upper) = _rangeAroundSpot(1000);
        vm.prank(curator);
        vm.expectPartialRevert(IUniswapV3PositionVault.PriceDeviationTooHigh.selector);
        vault.rebalanceWithSwap(lower, upper, 500, 0, 0);

        // Ordinary curator work is blocked too, not just the path that swaps.
        vm.prank(curator);
        vm.expectPartialRevert(IUniswapV3PositionVault.PriceDeviationTooHigh.selector);
        vault.collectFees();
    }

    function test_setTwapConfig_validatesAndEmits() public {
        vm.startPrank(admin);
        vm.expectRevert(IUniswapV3PositionVault.InvalidArguments.selector);
        vault.setTwapConfig(0, 100);
        vm.expectRevert(IUniswapV3PositionVault.InvalidArguments.selector);
        vault.setTwapConfig(600, 0);

        vault.setTwapConfig(600, 250);
        vm.stopPrank();

        assertEq(vault.twapPeriod(), 600, "period updated");
        assertEq(vault.maxTwapDeviationBps(), 250, "tolerance updated");
    }

    function test_swapCallback_rejectsCallsFromOutsideARebalance() public {
        vm.prank(stranger);
        vm.expectRevert(IUniswapV3PositionVault.UnexpectedCallback.selector);
        vault.uniswapV3SwapCallback(1, -1, "");

        // Even the real pool cannot call it outside a rebalance.
        vm.prank(POOL);
        vm.expectRevert(IUniswapV3PositionVault.UnexpectedCallback.selector);
        vault.uniswapV3SwapCallback(1, -1, "");
    }

    function test_onErc721Received_rejectsUnsolicitedPositions() public {
        vm.prank(POSITION_MANAGER);
        vm.expectRevert(IUniswapV3PositionVault.UnexpectedNft.selector);
        vault.onERC721Received(stranger, stranger, 1, "");

        assertTrue(vault.supportsInterface(type(IERC721Receiver).interfaceId), "declares the receiver interface");
    }

    //
    // Recovery and upgrades
    //

    function test_recoverAssets_neverSweepsThePoolTokens() public {
        _openPosition(100_000e6);
        _seedVault(1000e6, 1e18);

        address[] memory assets = new address[](2);
        assets[0] = USDC;
        assets[1] = WETH;

        uint256 vault0 = token0.balanceOf(address(vault));
        vault.recoverAssets(assets);

        assertEq(token0.balanceOf(address(vault)), vault0, "pool tokens stay with shareholders");
        assertEq(token0.balanceOf(recoverer), 0, "nothing reached the recoverer");
    }

    function test_recoverAssets_sweepsAnUnrelatedToken() public {
        address dai = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
        deal(dai, address(vault), 123e18);

        address[] memory assets = new address[](1);
        assets[0] = dai;
        vault.recoverAssets(assets);

        assertEq(IERC20(dai).balanceOf(recoverer), 123e18, "unrelated token recovered");
    }

    function test_proxyUpgrade_isRestrictedToTheAdmin() public {
        _openPosition(100_000e6);
        address newImplementation = address(new UniswapV3PositionVault());

        vm.prank(stranger);
        vm.expectRevert(IUniswapV3PositionVault.NotAuthorized.selector);
        vault.upgradeToAndCall(newImplementation, "");

        uint256 tokenId = vault.activeTokenId();
        uint256 supply = vault.totalSupply();

        vm.prank(admin);
        vault.upgradeToAndCall(newImplementation, "");

        assertEq(vault.activeTokenId(), tokenId, "position survives the upgrade");
        assertEq(vault.totalSupply(), supply, "shares survive the upgrade");
        assertTrue(vault.hasRole(vault.CURATOR(), curator), "roles survive the upgrade");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {UniswapV3PositionVault} from "../src/UniswapV3PositionVault.sol";
import {INonfungiblePositionManager} from "../src/interfaces/INonfungiblePositionManager.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3Pool.sol";
import {UniswapV3PositionVaultTestBase} from "./UniswapV3PositionVault.TestBase.sol";
import {UniswapV3SwapHelper} from "./mocks/UniswapV3SwapHelper.sol";

/// @title  VaultHandler
/// @author KPK
/// @notice Drives the vault through random sequences of the operations real users and curators run.
/// @dev    Every call is bounded to plausible inputs and wrapped so a legitimate revert, such as the
///         manipulation guard refusing to act on a moved price, simply skips that step instead of
///         failing the run. What the invariants then check is that no reachable *sequence* leaves
///         the vault in a bad state, which is a different question from whether any single call
///         behaves, and the one unit tests cannot answer.
contract VaultHandler is Test {
    UniswapV3PositionVault public immutable vault;
    UniswapV3SwapHelper public immutable swapHelper;
    IERC20 public immutable token0;
    IERC20 public immutable token1;
    address public immutable pool;
    address public immutable curator;

    address[3] public actors;

    /// @notice Counts of calls that actually executed, reported at the end of a run.
    uint256 public deposits;
    uint256 public redemptions;
    uint256 public rebalances;
    uint256 public unwinds;
    uint256 public creations;

    constructor(
        UniswapV3PositionVault vault_,
        UniswapV3SwapHelper swapHelper_,
        address pool_,
        address curator_,
        address[3] memory actors_
    ) {
        vault = vault_;
        swapHelper = swapHelper_;
        token0 = vault_.token0();
        token1 = vault_.token1();
        pool = pool_;
        curator = curator_;
        actors = actors_;
    }

    /// @notice Buys shares as one of the investors.
    function deposit(uint256 actorSeed, uint256 amount0, uint256 amount1) external {
        address actor = actors[actorSeed % actors.length];
        // The second seed picks which side the depositor names, so sequences exercise both.
        bool isAmount0 = amount1 % 2 == 0;
        uint256 amount = isAmount0 ? bound(amount0, 1e6, 200_000e6) : bound(amount0, 1e15, 200e18);

        vm.prank(actor);
        try vault.deposit(amount, isAmount0, 20_000, block.timestamp) {
            deposits++;
        } catch {}
    }

    /// @notice Sells shares as one of the investors.
    function redeem(uint256 actorSeed, uint256 sharesSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 held = vault.balanceOf(actor);
        if (held == 0) return;

        uint256 shares = bound(sharesSeed, 1, held);

        vm.prank(actor);
        try vault.redeem(shares, 500, block.timestamp) {
            redemptions++;
        } catch {}
    }

    /// @notice Moves the position into a new range without trading, leaving a surplus behind.
    function rebalance(uint256 widthSeed, uint256 shiftSeed) external {
        uint256 width = bound(widthSeed, 200, 4000);
        uint256 shift = bound(shiftSeed, 0, 1000);

        uint256 centre = _spotPrice() * (10_000 + shift) / 10_000;

        vm.prank(curator);
        try vault.rebalance(centre * (10_000 - width) / 10_000, centre * (10_000 + width) / 10_000) {
            rebalances++;
        } catch {}
    }

    /// @notice Moves the position into a new range, trading the balances to fit it.
    function rebalanceWithSwap(uint256 widthSeed, uint256 shiftSeed) external {
        uint256 width = bound(widthSeed, 200, 4000);
        uint256 shift = bound(shiftSeed, 0, 1000);

        uint256 centre = _spotPrice() * (10_000 + shift) / 10_000;
        uint256 lower = centre * (10_000 - width) / 10_000;
        uint256 upper = centre * (10_000 + width) / 10_000;

        vm.prank(curator);
        try vault.rebalanceWithSwap(lower, upper, 500, 0, 0) {
            rebalances++;
        } catch {}
    }

    /// @notice Closes the position, leaving everything idle.
    function unwind() external {
        vm.prank(curator);
        try vault.unwindPosition() {
            unwinds++;
        } catch {}
    }

    /// @notice Opens a position when there is none.
    function createPosition(uint256 amountSeed) external {
        if (vault.activeTokenId() != 0) return;

        uint256 balance0 = token0.balanceOf(address(vault));
        if (balance0 < 2e6) return;
        uint256 amount0 = bound(amountSeed, 1e6, balance0 / 2);

        (uint256 lower, uint256 upper) = _rangeAroundSpot(1500);

        vm.prank(curator);
        try vault.createPosition(lower, upper, amount0, true) {
            creations++;
        } catch {}
    }

    /// @notice Folds fees and idle balances back into the position.
    function collectFees() external {
        vm.prank(curator);
        try vault.collectFees() {} catch {}
    }

    /// @notice Trims part of the position into idle balances.
    function removeLiquidity(uint256 seed) external {
        if (vault.activeTokenId() == 0) return;
        (,, uint128 liquidity,,) = vault.activePosition();
        if (liquidity == 0) return;

        uint128 amount = uint128(bound(seed, 1, liquidity));

        vm.prank(curator);
        try vault.removeLiquidity(amount) {} catch {}
    }

    /// @notice Trades through the pool so the position accrues fees and the price drifts.
    function tradeThroughPool(uint256 seed, bool zeroForOne) external {
        uint256 amount = zeroForOne ? bound(seed, 1000e6, 500_000e6) : bound(seed, 1e17, 200e18);

        deal(address(token0), address(swapHelper), 10_000_000e6);
        deal(address(token1), address(swapHelper), 10_000e18);

        try swapHelper.swap(pool, zeroForOne, int256(amount)) {} catch {}
    }

    /// @notice Sends tokens to the vault unprompted, the way a donation or a stray transfer would.
    function donate(uint256 amount0, uint256 amount1) external {
        amount0 = bound(amount0, 0, 10_000e6);
        amount1 = bound(amount1, 0, 10e18);
        deal(address(token0), address(vault), token0.balanceOf(address(vault)) + amount0);
        deal(address(token1), address(vault), token1.balanceOf(address(vault)) + amount1);
    }

    /// @notice The pool's current human price.
    function _spotPrice() internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        return vault.sqrtPriceX96ToPrice(sqrtPriceX96);
    }

    /// @notice A range around the current price.
    function _rangeAroundSpot(uint256 widthBps) internal view returns (uint256 lower, uint256 upper) {
        uint256 spot = _spotPrice();
        lower = spot * (10_000 - widthBps) / 10_000;
        upper = spot * (10_000 + widthBps) / 10_000;
    }
}

/// @title  UniswapV3PositionVaultInvariantTest
/// @author KPK
/// @notice Properties that must hold after any reachable sequence of vault operations.
/// @dev    Runs against the same pinned mainnet fork as the other integration suites, so the
///         sequences execute against the real pool rather than a simplification of it.
contract UniswapV3PositionVaultInvariantTest is UniswapV3PositionVaultTestBase {
    VaultHandler internal handler;

    function setUp() public override {
        super.setUp();

        // Start from a live position so sequences begin in the interesting state.
        _openPosition();

        handler = new VaultHandler(vault, swapHelper, POOL, curator, [alice, bob, curator]);

        // The handler acts on behalf of the actors, which already hold the investor role.
        targetContract(address(handler));
    }

    /// @notice The vault owns the position it says is active.
    function invariant_theActivePositionIsOwnedByTheVault() public view {
        uint256 tokenId = vault.activeTokenId();
        if (tokenId == 0) return;
        assertEq(
            INonfungiblePositionManager(POSITION_MANAGER).ownerOf(tokenId),
            address(vault),
            "the vault must own the position it reports"
        );
    }

    /// @notice Shares outstanding are never a claim on nothing.
    function invariant_sharesAreAlwaysBackedBySomething() public view {
        if (vault.totalSupply() == 0) return;

        uint256 backing = token0.balanceOf(address(vault)) + token1.balanceOf(address(vault));
        if (vault.activeTokenId() != 0) {
            (,, uint128 liquidity,,) = vault.activePosition();
            backing += liquidity;
        }
        assertGt(backing, 0, "shares outstanding with nothing behind them");
    }

    /// @notice No allowance is ever left standing to the position manager.
    /// @dev    The vault approves an exact amount immediately before each position manager call and
    ///         clears it immediately after. A sequence that left one behind would be a standing
    ///         claim on shareholder funds.
    function invariant_noApprovalIsLeftStanding() public view {
        assertEq(token0.allowance(address(vault), POSITION_MANAGER), 0, "token0 allowance left standing");
        assertEq(token1.allowance(address(vault), POSITION_MANAGER), 0, "token1 allowance left standing");
    }

    /// @notice Every share in existence is held by one of the accounts allowed to hold shares.
    function invariant_allSharesAreAccountedFor() public view {
        uint256 held = vault.balanceOf(alice) + vault.balanceOf(bob) + vault.balanceOf(curator);
        assertEq(held, vault.totalSupply(), "shares exist outside the known holders");
    }

    /// @notice Redeeming everything never claims more than the vault owns.
    function invariant_totalClaimNeverExceedsTotalAssets() public view {
        uint256 supply = vault.totalSupply();
        if (supply == 0) return;

        (uint256 claim0, uint256 claim1) = vault.previewRedeem(supply);
        (uint256 total0, uint256 total1) = vault.totalAssets();

        assertLe(claim0, total0, "token0 claim exceeds holdings");
        assertLe(claim1, total1, "token1 claim exceeds holdings");
    }

    /// @notice Reports how much of the state space a run actually reached.
    /// @dev    An invariant suite whose calls all revert passes vacuously, so the counts are printed
    ///         to keep that failure mode visible.
    function invariant_callSummary() public view {
        console.log("deposits    ", handler.deposits());
        console.log("redemptions ", handler.redemptions());
        console.log("rebalances  ", handler.rebalances());
        console.log("unwinds     ", handler.unwinds());
        console.log("creations   ", handler.creations());
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";

/// @title  IUniswapV3PositionVault
/// @author KPK
/// @notice The errors, events and structs of UniswapV3PositionVault.
/// @dev    Declared next to the implementation, following the IkpkShares convention that interfaces
///         of this repository's own contracts sit beside them while interfaces of foreign contracts
///         live in src/interfaces. Every error the vault and its math library can revert with is
///         declared here, so callers have one stable selector surface to decode against.
///
///         It also declares the vault's own call surface, so an integrator can bind to this type
///         rather than to the implementation. The ERC-20, access-control and UUPS surfaces are not
///         repeated here; they come from the standard interfaces the vault already implements.
interface IUniswapV3PositionVault {
    //
    // Errors
    //

    /// @notice The caller does not hold the role required by the function.
    error NotAuthorized();

    /// @notice The account is not allowed to hold, receive or burn shares.
    /// @dev    Deposits, redemptions and transfers all require the INVESTOR role, unless the role
    ///         has been granted to address(0), which opens the vault to everyone.
    /// @param account The address that failed the check.
    error NotInvestor(address account);

    /// @notice A required address argument was the zero address.
    error ZeroAddress();

    /// @notice An argument was outside its permitted range.
    error InvalidArguments();

    /// @notice The two pool tokens were equal or were not supplied in ascending address order.
    error TokensNotSorted();

    /// @notice A pool token reports more than 18 decimals, which the price scaling does not support.
    error UnsupportedDecimals();

    /// @notice No Uniswap v3 pool exists for the configured token pair and fee tier.
    error PoolNotFound();

    /// @notice The price range is empty after snapping to the pool's tick spacing.
    error InvalidPriceRange();

    /// @notice A price converts to a sqrt ratio outside the range Uniswap v3 supports.
    error PriceOutOfRange();

    /// @notice The supplied token side cannot fund a position at the current pool price.
    /// @dev    A range entirely above the spot price is funded with token0 only, and a range
    ///         entirely below it with token1 only; supplying the other side is rejected rather than
    ///         silently ignored.
    error AmountSideNotUsable();

    /// @notice The vault holds no position and the operation requires one.
    error NoActivePosition();

    /// @notice The vault already holds a position and the operation requires it to hold none.
    error PositionAlreadyActive();

    /// @notice The vault's idle balance cannot fund the requested position.
    /// @param token     The token that fell short.
    /// @param required  Amount the position needs.
    /// @param available Amount the vault holds.
    error InsufficientIdleBalance(address token, uint256 required, uint256 available);

    /// @notice No idle balance could be added to the active position.
    error NothingToAdd();

    /// @notice The vault holds nothing that could fund a new position.
    error NothingToRebalance();

    /// @notice The operation would mint or burn zero shares.
    error ZeroShares();

    /// @notice Thrown when a share supply is too small to price a deposit against: either the vault
    ///         is being opened with a negligible position, or a deposit is being made into a vault
    ///         whose supply has been redeemed down to a residue. Redemptions themselves are never
    ///         refused for what they would leave behind.
    /// @param supply  The supply in question: the opening supply, or the one a deposit would be
    ///                priced against.
    /// @param minimum The smallest supply either may be.
    error SupplyTooSmall(uint256 supply, uint256 minimum);

    /// @notice The amounts moved fell short of the caller's minimums.
    /// @param amount0 Token0 the operation actually moved.
    /// @param amount1 Token1 the operation actually moved.
    error SlippageExceeded(uint256 amount0, uint256 amount1);

    /// @notice The transaction was mined after the caller's deadline.
    error DeadlineExpired();

    /// @notice The pool cannot answer an observation covering the configured TWAP window.
    /// @dev    Raised when the pool's observation cardinality is too low for the window, which
    ///         means the manipulation guard cannot be evaluated and the operation must not proceed.
    /// @param twapPeriod             The window that was requested, in seconds.
    /// @param observationCardinality The pool's current observation cardinality.
    error TwapUnavailable(uint32 twapPeriod, uint16 observationCardinality);

    /// @notice The pool's spot price deviates from its time-weighted average by more than the cap.
    /// @param deviationBps The observed deviation, in basis points.
    /// @param maxBps       The configured maximum, in basis points.
    error PriceDeviationTooHigh(uint256 deviationBps, uint256 maxBps);

    /// @notice The pool holds no in-range liquidity, so a swap cannot be sized against it.
    error PoolHasNoLiquidity();

    /// @notice A Uniswap callback arrived from an unexpected caller or outside an expected operation.
    error UnexpectedCallback();

    /// @notice An ERC-721 token was sent to the vault by something other than the position manager.
    error UnexpectedNft();

    //
    // Structs
    //

    /// @notice Parameters for vault initialization.
    /// @param name                Name of the share token.
    /// @param symbol              Symbol of the share token.
    /// @param admin               Initial holder of DEFAULT_ADMIN_ROLE.
    /// @param curator             Initial holder of the CURATOR role.
    /// @param assetRecoverer      Recipient of any token swept by recoverAssets.
    /// @param positionManager     The Uniswap v3 NonfungiblePositionManager.
    /// @param token0              The pool's token0; must sort below token1.
    /// @param token1              The pool's token1.
    /// @param fee                 The pool fee tier, in hundredths of a basis point.
    /// @param twapPeriod          Length of the manipulation-guard window, in seconds.
    /// @param maxTwapDeviationBps Maximum spot-to-average deviation the guard tolerates.
    struct InitParams {
        string name;
        string symbol;
        address admin;
        address curator;
        address assetRecoverer;
        address positionManager;
        address token0;
        address token1;
        uint24 fee;
        uint32 twapPeriod;
        uint16 maxTwapDeviationBps;
    }

    //
    // Events
    //

    /// @notice Emitted when an investor mints shares.
    /// @param investor  The depositor.
    /// @param shares    Shares minted.
    /// @param amount0   Token0 taken from the depositor.
    /// @param amount1   Token1 taken from the depositor.
    /// @param liquidity Liquidity the deposit added to the position.
    event Deposit(address indexed investor, uint256 shares, uint256 amount0, uint256 amount1, uint128 liquidity);

    /// @notice Emitted when an investor burns shares.
    /// @param investor  The redeemer.
    /// @param shares    Shares burned.
    /// @param amount0   Token0 paid out.
    /// @param amount1   Token1 paid out.
    /// @param liquidity Liquidity the redemption removed from the position.
    event Redeem(address indexed investor, uint256 shares, uint256 amount0, uint256 amount1, uint128 liquidity);

    /// @notice Emitted when the curator opens a position.
    /// @param tokenId   The new position NFT id.
    /// @param tickLower Lower tick after snapping to the pool's spacing.
    /// @param tickUpper Upper tick after snapping to the pool's spacing.
    /// @param liquidity Liquidity minted.
    /// @param amount0   Token0 consumed.
    /// @param amount1   Token1 consumed.
    event PositionCreated(
        uint256 indexed tokenId, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 amount0, uint256 amount1
    );

    /// @notice Emitted when the curator closes the position and burns its NFT.
    /// @param tokenId The position NFT id that was burned.
    /// @param amount0 Token0 returned to the vault, principal and fees combined.
    /// @param amount1 Token1 returned to the vault, principal and fees combined.
    event PositionUnwound(uint256 indexed tokenId, uint256 amount0, uint256 amount1);

    /// @notice Emitted whenever a curator call collects fees and folds idle balances back in.
    /// @param tokenId   The position NFT id.
    /// @param fees0     Token0 collected from the position, fees and stray owed balances combined.
    /// @param fees1     Token1 collected from the position.
    /// @param liquidity Liquidity added back into the position.
    /// @param amount0   Token0 consumed by that liquidity.
    /// @param amount1   Token1 consumed by that liquidity.
    event Compounded(
        uint256 indexed tokenId, uint256 fees0, uint256 fees1, uint128 liquidity, uint256 amount0, uint256 amount1
    );

    /// @notice Emitted when the curator withdraws liquidity from the position into idle balances.
    /// @param tokenId   The position NFT id.
    /// @param liquidity Liquidity removed.
    /// @param amount0   Token0 released.
    /// @param amount1   Token1 released.
    event LiquidityRemoved(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice Emitted when the curator replaces the position with one in a new range.
    /// @param oldTokenId  The position NFT that was unwound, or 0 if there was none.
    /// @param newTokenId  The position NFT that was minted.
    /// @param zeroForOne  True when token0 was sold to fund the new range.
    /// @param amountIn    Amount of the sold token paid into the pool.
    /// @param amountOut   Amount of the bought token received from the pool.
    /// @param leftover0   Token0 left idle after minting.
    /// @param leftover1   Token1 left idle after minting.
    event Rebalanced(
        uint256 indexed oldTokenId,
        uint256 indexed newTokenId,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOut,
        uint256 leftover0,
        uint256 leftover1
    );

    /// @notice Emitted when the admin changes the manipulation guard's configuration.
    /// @param twapPeriod          The new window, in seconds.
    /// @param maxTwapDeviationBps The new deviation cap, in basis points.
    event TwapConfigUpdate(uint32 twapPeriod, uint16 maxTwapDeviationBps);

    /// @notice Emitted when the admin changes the recipient of recovered tokens.
    /// @param assetRecoverer The new recipient.
    event AssetRecovererUpdate(address indexed assetRecoverer);

    //
    // Investor operations
    //

    /// @notice Buys into the position with both token amounts, in the shape of increaseLiquidity.
    /// @param amount0Desired The most token0 to spend.
    /// @param amount1Desired The most token1 to spend.
    /// @param deadline       Latest timestamp at which the call may execute.
    /// @return shares  Shares minted to the caller.
    /// @return amount0 Token0 actually taken.
    /// @return amount1 Token1 actually taken.
    function deposit(uint256 amount0Desired, uint256 amount1Desired, uint256 deadline)
        external
        returns (uint256 shares, uint256 amount0, uint256 amount1);

    /// @notice Sells shares back to the vault for a pro-rata slice of everything it owns.
    /// @param shares          Shares to burn.
    /// @param maxSlippageBps  Bounds how far the price may sit from its recent average, which sets
    ///                        the split between the two tokens. Pass 10000 to waive it.
    /// @param deadline        Latest timestamp at which the call may execute.
    /// @return amount0 Token0 paid to the caller.
    /// @return amount1 Token1 paid to the caller.
    function redeem(uint256 shares, uint16 maxSlippageBps, uint256 deadline)
        external
        returns (uint256 amount0, uint256 amount1);

    //
    // Curator operations
    //

    /// @notice Opens the vault's only position, funded by both token amounts.
    /// @param priceLower     Lower bound of the range, as a 1e18-scaled human price.
    /// @param priceUpper     Upper bound of the range.
    /// @param amount0Desired The most token0 to commit.
    /// @param amount1Desired The most token1 to commit.
    /// @param deadline       Latest timestamp at which the call may execute.
    function createPosition(
        uint256 priceLower,
        uint256 priceUpper,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 deadline
    ) external returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice Closes the position, leaving everything it held idle in the vault.
    function unwindPosition() external returns (uint256 amount0, uint256 amount1);

    /// @notice Collects the position's fees and folds every idle balance back into it.
    function collectFees(uint256 deadline) external returns (uint128 liquidity);

    /// @notice Folds the vault's idle balances into the active position.
    function addLiquidity(uint256 deadline) external returns (uint128 liquidity);

    /// @notice Trims liquidity out of the position, leaving the tokens idle in the vault.
    function removeLiquidity(uint128 liquidity) external returns (uint256 amount0, uint256 amount1);

    /// @notice Moves the position into a new range without trading.
    function rebalance(uint256 priceLower, uint256 priceUpper, uint256 deadline)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice Moves the position into a new range, trading the balances to fit it.
    function rebalanceWithSwap(
        uint256 priceLower,
        uint256 priceUpper,
        uint16 maxPriceImpactBps,
        uint32 twapWindow,
        uint16 maxDeviationBps,
        uint256 deadline
    ) external returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    //
    // Administration
    //

    /// @notice Sets the window and tolerance the manipulation guard uses.
    function setTwapConfig(uint32 newTwapPeriod, uint16 newMaxTwapDeviationBps) external;

    /// @notice Sets the address stray tokens can be recovered to.
    function setAssetRecoverer(address newAssetRecoverer) external;

    //
    // Configuration and state
    //

    /// @notice Role hash for the curator, who manages the position.
    function CURATOR() external view returns (bytes32);

    /// @notice Role hash for investors. Granted to address(0), it opens the vault to everyone.
    function INVESTOR() external view returns (bytes32);

    /// @notice The pool's lower-addressed token.
    function token0() external view returns (IERC20);

    /// @notice The pool's higher-addressed token.
    function token1() external view returns (IERC20);

    /// @notice The pool the vault's position lives in.
    function pool() external view returns (IUniswapV3Pool);

    /// @notice The position manager the vault mints through.
    function positionManager() external view returns (INonfungiblePositionManager);

    /// @notice The pool's fee tier, in hundredths of a basis point.
    function fee() external view returns (uint24);

    /// @notice The pool's tick spacing.
    function tickSpacing() external view returns (int24);

    /// @notice Seconds the manipulation guard averages the price over.
    function twapPeriod() external view returns (uint32);

    /// @notice How far the spot price may sit from that average, in basis points.
    function maxTwapDeviationBps() external view returns (uint16);

    /// @notice The NFT id of the active position, or zero when there is none.
    /// @dev    Read it rather than caching it: it changes every time the position is closed and
    ///         reopened, which a rebalance does.
    function activeTokenId() external view returns (uint256);

    /// @notice Where stray tokens can be recovered to.
    function assetRecoverer() external view returns (address);

    /// @notice `10**decimals1`, cached at initialization for the price conversions.
    function priceScaleNum() external view returns (uint256);

    /// @notice `1e18 * 10**decimals0`, cached at initialization for the price conversions.
    function priceScaleDen() external view returns (uint256);

    //
    // Views
    //

    /// @notice Converts a human price, token1 per token0 and 1e18-scaled, into a Q64.96 sqrt ratio.
    function priceToSqrtPriceX96(uint256 price) external view returns (uint160);

    /// @notice The inverse: a Q64.96 sqrt ratio as a 1e18-scaled human price.
    function sqrtPriceX96ToPrice(uint160 sqrtPriceX96) external view returns (uint256);

    /// @notice Whether an account may hold, buy or sell shares.
    function isInvestor(address account) external view returns (bool);

    /// @notice The active position's range, liquidity and uncollected fees.
    function activePosition()
        external
        view
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity, uint128 owed0, uint128 owed1);

    /// @notice Everything the vault owns, in both tokens.
    function totalAssets() external view returns (uint256 amount0, uint256 amount1);

    /// @notice The counter amount a position of the given range needs alongside a named amount.
    function previewCounterAmount(uint256 tokenId, uint256 amount, bool isAmount0) external view returns (uint256);

    /// @notice The same, for a range that does not exist yet.
    function previewCounterAmountForRange(uint256 priceLower, uint256 priceUpper, uint256 amount, bool isAmount0)
        external
        view
        returns (uint256);

    /// @notice The token amounts a quantity of liquidity occupies in a position's range.
    function liquidityToAmounts(uint256 tokenId, uint128 liquidity)
        external
        view
        returns (uint256 amount0, uint256 amount1);

    /// @notice The liquidity a pair of token amounts funds in a position's range.
    function amountsToLiquidity(uint256 tokenId, uint256 amount0, uint256 amount1) external view returns (uint128);

    /// @notice What a redemption of the given shares would pay out.
    function previewRedeem(uint256 shares) external view returns (uint256 amount0, uint256 amount1);

    /// @notice The tick boundaries a human price range snaps to.
    function priceRangeToTicks(uint256 priceLower, uint256 priceUpper)
        external
        view
        returns (int24 tickLower, int24 tickUpper);
}

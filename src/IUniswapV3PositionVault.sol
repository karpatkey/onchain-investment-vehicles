// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title  IUniswapV3PositionVault
/// @author KPK
/// @notice The errors, events and structs of UniswapV3PositionVault.
/// @dev    Declared next to the implementation, following the IkpkShares convention that interfaces
///         of this repository's own contracts sit beside them while interfaces of foreign contracts
///         live in src/interfaces. Every error the vault and its math library can revert with is
///         declared here, so callers have one stable selector surface to decode against.
///
///         Unlike IkpkShares this declares no function signatures, so it cannot be used to CALL the
///         vault: integrators bind to the concrete UniswapV3PositionVault type, or write their own
///         minimal interface. Adding the call surface here is tracked as an open item on the pull
///         request rather than assumed.
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
}

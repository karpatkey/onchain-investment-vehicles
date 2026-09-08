// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IUniswapV3PositionVault} from "./IUniswapV3PositionVault.sol";
import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {IUniswapV3Factory} from "./interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "./interfaces/IUniswapV3SwapCallback.sol";
import {UniswapV3VaultMath} from "./libraries/UniswapV3VaultMath.sol";
import {TickMath} from "./libraries/uniswap/TickMath.sol";
import {RecoverFunds} from "./utils/RecoverFunds.sol";

/// @title  UniswapV3PositionVault
/// @author KPK
/// @notice An ERC-20 share token backed by a single Uniswap v3 liquidity position.
/// @dev    The vault owns at most one position NFT on one fixed pool, chosen at initialization and
///         never changed. A curator opens, moves and closes that position; investors buy into it at
///         the position's own token ratio and redeem for a slice of it paid in both tokens.
///
///         A share is a pro-rata claim on the whole vault, meaning the position's liquidity and any
///         idle token balances together. Deposits and redemptions move both, so tokens that are
///         waiting to be folded back into the position are never given away to, or taken from, a
///         single investor. Every deposit and redemption first collects the position's fees and
///         folds the idle balances back in, which is what makes fees accrue to existing holders
///         before a new one is priced.
///
///         All Uniswap arithmetic comes from Uniswap's own libraries, vendored under
///         src/libraries/uniswap and composed in UniswapV3VaultMath. Amounts the vault pays are
///         rounded up and amounts it receives are rounded down, so rounding always favours the pool
///         of existing shareholders over the account currently transacting.
///
///         Tokens that do not move their full transferred amount, such as fee-on-transfer or
///         rebasing tokens, are not supported and must not be configured.
contract UniswapV3PositionVault is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ERC20Upgradeable,
    ReentrancyGuardUpgradeable,
    IUniswapV3PositionVault,
    IUniswapV3SwapCallback,
    IERC721Receiver,
    RecoverFunds
{
    using SafeERC20 for IERC20;

    //
    // Constants
    //

    /// @notice Role identifier for the account that manages the position.
    bytes32 public constant CURATOR = keccak256("CURATOR");

    /// @notice Role identifier for accounts allowed to hold shares.
    /// @dev    Granting this role to address(0) opens the vault to everyone, which is how a
    ///         permissionless deployment is expressed without a separate flag.
    bytes32 public constant INVESTOR = keccak256("INVESTOR");

    /// @dev Largest deviation cap that can be configured, in basis points.
    uint256 private constant _MAX_BPS = 10_000;

    //
    // State Variables
    //

    /// @notice The pool's token0.
    IERC20 public token0;

    /// @notice The pool's token1.
    IERC20 public token1;

    /// @notice The Uniswap v3 pool the vault provides liquidity to.
    IUniswapV3Pool public pool;

    /// @notice The Uniswap v3 position manager that custodies the position NFT.
    INonfungiblePositionManager public positionManager;

    /// @notice The pool's fee tier, in hundredths of a basis point.
    uint24 public fee;

    /// @notice The pool's tick spacing, cached at initialization.
    int24 public tickSpacing;

    /// @notice Length of the manipulation-guard window, in seconds.
    uint32 public twapPeriod;

    /// @notice Maximum tolerated deviation of spot price from the average, in basis points.
    uint16 public maxTwapDeviationBps;

    /// @dev True only while this contract is inside its own pool swap, so the swap callback can
    ///      reject calls that did not originate from a rebalance.
    bool private _swapping;

    /// @dev True only while this contract is inside its own position mint, so an incoming NFT can
    ///      be distinguished from an unsolicited transfer.
    bool private _minting;

    /// @notice Id of the position NFT the vault currently holds, or 0 when it holds none.
    /// @dev    Changes every time a position is opened or closed, so integrators must read it
    ///         rather than cache it.
    uint256 public activeTokenId;

    /// @notice Recipient of any token swept by recoverAssets.
    address public assetRecoverer;

    /// @dev `10**decimals1`, the numerator of the human-price scaling.
    uint256 public priceScaleNum;

    /// @dev `1e18 * 10**decimals0`, the denominator of the human-price scaling.
    uint256 public priceScaleDen;

    /// @notice Gap for upgradeability.
    uint256[50] private __gap;

    //
    // Constructor
    //

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    //
    // Initialization
    //

    /// @notice Initializes the vault against one Uniswap v3 pool.
    /// @dev    The pool is resolved through the position manager's own factory, so a mismatched
    ///         token pair or fee tier fails here rather than at the first position.
    /// @param params Initialization parameters.
    function initialize(InitParams memory params) external initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ERC20_init(params.name, params.symbol);
        __ReentrancyGuard_init();

        if (
            params.admin == address(0) || params.curator == address(0) || params.assetRecoverer == address(0)
                || params.positionManager == address(0)
        ) revert ZeroAddress();
        if (params.token0 >= params.token1) revert TokensNotSorted();
        _validateTwapConfig(params.twapPeriod, params.maxTwapDeviationBps);

        address poolAddress = IUniswapV3Factory(INonfungiblePositionManager(params.positionManager).factory())
            .getPool(params.token0, params.token1, params.fee);
        if (poolAddress == address(0)) revert PoolNotFound();

        uint8 decimals0 = IERC20Metadata(params.token0).decimals();
        uint8 decimals1 = IERC20Metadata(params.token1).decimals();
        if (decimals0 > 18 || decimals1 > 18) revert UnsupportedDecimals();

        token0 = IERC20(params.token0);
        token1 = IERC20(params.token1);
        pool = IUniswapV3Pool(poolAddress);
        positionManager = INonfungiblePositionManager(params.positionManager);
        fee = params.fee;
        tickSpacing = IUniswapV3Pool(poolAddress).tickSpacing();
        twapPeriod = params.twapPeriod;
        maxTwapDeviationBps = params.maxTwapDeviationBps;
        assetRecoverer = params.assetRecoverer;
        priceScaleNum = 10 ** decimals1;
        priceScaleDen = 1e18 * 10 ** decimals0;

        _grantRole(DEFAULT_ADMIN_ROLE, params.admin);
        _grantRole(CURATOR, params.curator);
    }

    //
    // Authorization
    //

    /// @notice Restricts a function to the default admin.
    modifier isAdmin() {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert NotAuthorized();
        _;
    }

    /// @notice Restricts a function to the curator.
    modifier isCurator() {
        if (!hasRole(CURATOR, msg.sender)) revert NotAuthorized();
        _;
    }

    /// @notice Rejects a call mined after the caller's deadline.
    /// @param deadline The latest timestamp at which the call may execute.
    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        _;
    }

    /// @notice Whether an account may hold shares.
    /// @dev    Granting INVESTOR to address(0) opens the vault, which is checked first so an open
    ///         vault costs a single role lookup.
    /// @param account The address to check.
    /// @return True when the account may hold, receive or burn shares.
    function isInvestor(address account) public view returns (bool) {
        return hasRole(INVESTOR, address(0)) || hasRole(INVESTOR, account);
    }

    //
    // Investor Operations
    //

    /// @notice Buys into the position at its current token ratio.
    /// @dev    Mirrors NonfungiblePositionManager.increaseLiquidity: the caller names the most it
    ///         will supply of each token, and the vault takes only what the ratio actually needs.
    ///         The position's fees are collected and folded in first, so they belong to existing
    ///         holders and are not shared with this deposit. Amounts are pulled exactly, and the
    ///         wei-level remainder left by the pool's own rounding is returned in the same call.
    /// @param amount0Desired Maximum token0 the caller will supply.
    /// @param amount1Desired Maximum token1 the caller will supply.
    /// @param amount0Min     Minimum token0 the deposit must consume, as a slippage bound.
    /// @param amount1Min     Minimum token1 the deposit must consume, as a slippage bound.
    /// @param deadline       Latest timestamp at which the deposit may execute.
    /// @return shares  Shares minted to the caller.
    /// @return amount0 Token0 taken from the caller.
    /// @return amount1 Token1 taken from the caller.
    function deposit(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external nonReentrant checkDeadline(deadline) returns (uint256 shares, uint256 amount0, uint256 amount1) {
        if (!isInvestor(msg.sender)) revert NotInvestor(msg.sender);

        uint256 tokenId = activeTokenId;
        if (tokenId == 0) revert NoActivePosition();

        uint256 supply = totalSupply();
        if (supply == 0) revert ZeroShares();

        _compound();

        (uint160 sqrtPriceX96, uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity) =
            _positionState(tokenId);
        if (liquidity == 0) revert NoActivePosition();

        uint256 idle0 = token0.balanceOf(address(this));
        uint256 idle1 = token1.balanceOf(address(this));

        (uint256 targetShares, uint256 charge0, uint256 charge1, uint256 pulled0, uint256 pulled1) = UniswapV3VaultMath.depositPlan(
            sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, liquidity, idle0, idle1, supply, amount0Desired, amount1Desired
        );

        // The plan already leaves headroom for its own rounding; this is the hard guarantee that a
        // deposit can never take more of either token than the caller put on offer.
        if (pulled0 > amount0Desired || pulled1 > amount1Desired) revert SlippageExceeded(pulled0, pulled1);

        if (pulled0 != 0) token0.safeTransferFrom(msg.sender, address(this), pulled0);
        if (pulled1 != 0) token1.safeTransferFrom(msg.sender, address(this), pulled1);

        uint128 mintedLiquidity;
        (mintedLiquidity, amount0, amount1) = _increaseLiquidity(tokenId, charge0, charge1);

        // Price the shares on the liquidity the position actually gained, then cap at what the
        // caller's maxima paid for, so the idle share charged below can never exceed what was taken.
        shares = UniswapV3VaultMath.sharesForLiquidity(supply, mintedLiquidity, liquidity);
        if (shares > targetShares) shares = targetShares;
        if (shares == 0) revert ZeroShares();

        amount0 += UniswapV3VaultMath.idleShare(idle0, shares, supply);
        amount1 += UniswapV3VaultMath.idleShare(idle1, shares, supply);
        if (amount0 < amount0Min || amount1 < amount1Min) revert SlippageExceeded(amount0, amount1);

        _mint(msg.sender, shares);

        if (pulled0 > amount0) token0.safeTransfer(msg.sender, pulled0 - amount0);
        if (pulled1 > amount1) token1.safeTransfer(msg.sender, pulled1 - amount1);

        emit Deposit(msg.sender, shares, amount0, amount1, mintedLiquidity);
    }

    /// @notice Sells shares back for a pro-rata slice of the vault, paid in both tokens.
    /// @dev    Withdraws the caller's share of the position's liquidity and of any idle balance.
    ///         Only the principal released by this redemption is collected from the position, so a
    ///         redemption can never sweep fees that belong to the remaining holders.
    /// @param shares     Shares to burn.
    /// @param amount0Min Minimum token0 the caller will accept.
    /// @param amount1Min Minimum token1 the caller will accept.
    /// @param deadline   Latest timestamp at which the redemption may execute.
    /// @return amount0 Token0 paid to the caller.
    /// @return amount1 Token1 paid to the caller.
    function redeem(uint256 shares, uint256 amount0Min, uint256 amount1Min, uint256 deadline)
        external
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 amount0, uint256 amount1)
    {
        if (shares == 0) revert ZeroShares();
        if (!isInvestor(msg.sender)) revert NotInvestor(msg.sender);

        _compound();

        uint256 supply = totalSupply();
        uint256 idle0 = token0.balanceOf(address(this));
        uint256 idle1 = token1.balanceOf(address(this));

        uint128 burnedLiquidity;
        uint256 tokenId = activeTokenId;
        if (tokenId != 0) {
            (,,, uint128 liquidity) = _positionState(tokenId);
            burnedLiquidity = UniswapV3VaultMath.liquidityForShares(liquidity, shares, supply);
            if (burnedLiquidity != 0) (amount0, amount1) = _withdrawLiquidity(tokenId, burnedLiquidity);
        }

        amount0 += UniswapV3VaultMath.idleShareDown(idle0, shares, supply);
        amount1 += UniswapV3VaultMath.idleShareDown(idle1, shares, supply);
        if (amount0 == 0 && amount1 == 0) revert ZeroShares();
        if (amount0 < amount0Min || amount1 < amount1Min) revert SlippageExceeded(amount0, amount1);

        _burn(msg.sender, shares);

        if (amount0 != 0) token0.safeTransfer(msg.sender, amount0);
        if (amount1 != 0) token1.safeTransfer(msg.sender, amount1);

        emit Redeem(msg.sender, shares, amount0, amount1, burnedLiquidity);
    }

    //
    // Curator Operations
    //

    /// @notice Opens the vault's position, sizing it from one named token amount.
    /// @dev    The counter amount is derived from the pool's current price, so the caller only has
    ///         to decide how much of one token to commit. Both amounts must already sit idle in the
    ///         vault. When the vault has no shares outstanding, the liquidity minted here becomes
    ///         the initial share supply and is credited to the caller, who must therefore be
    ///         allowed to hold shares.
    /// @param priceLower Lower bound of the range, as a 1e18-scaled human price.
    /// @param priceUpper Upper bound of the range, as a 1e18-scaled human price.
    /// @param amount     Amount of the named token to commit.
    /// @param isAmount0  True when the amount is token0, false when it is token1.
    /// @return tokenId   The new position NFT id.
    /// @return liquidity Liquidity minted.
    /// @return amount0   Token0 consumed.
    /// @return amount1   Token1 consumed.
    function createPosition(uint256 priceLower, uint256 priceUpper, uint256 amount, bool isAmount0)
        external
        nonReentrant
        isCurator
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        if (activeTokenId != 0) revert PositionAlreadyActive();
        if (amount == 0) revert InvalidArguments();
        _checkPriceDeviation();

        (int24 tickLower, int24 tickUpper) = priceRangeToTicks(priceLower, priceUpper);
        (uint160 sqrtRatioAX96, uint160 sqrtRatioBX96) = UniswapV3VaultMath.sqrtRatiosForTicks(tickLower, tickUpper);
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();

        (, uint256 need0, uint256 need1) =
            UniswapV3VaultMath.createPlan(sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, amount, isAmount0);
        _requireIdle(token0, need0);
        _requireIdle(token1, need1);

        (tokenId, liquidity, amount0, amount1) = _mintPosition(tickLower, tickUpper, need0, need1);
        _bootstrapShares(liquidity);

        emit PositionCreated(tokenId, tickLower, tickUpper, liquidity, amount0, amount1);
    }

    /// @notice Closes the vault's position, leaving everything it held idle in the vault.
    /// @dev    Collects fees and principal together and burns the NFT, so activeTokenId returns to
    ///         zero. Shares are untouched; holders simply now own idle tokens instead of liquidity.
    /// @return amount0 Token0 returned to the vault.
    /// @return amount1 Token1 returned to the vault.
    function unwindPosition() external nonReentrant isCurator returns (uint256 amount0, uint256 amount1) {
        uint256 tokenId = activeTokenId;
        if (tokenId == 0) revert NoActivePosition();
        (amount0, amount1) = _unwind(tokenId);
    }

    /// @notice Collects the position's fees and folds every idle balance back into it.
    /// @dev    With fees compounded rather than distributed, collecting and reinvesting are the
    ///         same action, so this is the curator's on-demand version of what deposits and
    ///         redemptions already do.
    /// @return liquidity Liquidity added back into the position.
    function collectFees() external nonReentrant isCurator returns (uint128 liquidity) {
        if (activeTokenId == 0) revert NoActivePosition();
        _checkPriceDeviation();
        liquidity = _compound();
    }

    /// @notice Adds the vault's idle balances to the active position.
    /// @dev    Only the part of the idle balances that matches the position's ratio can be added;
    ///         a one-sided remainder stays idle until a rebalance swaps it.
    /// @return liquidity Liquidity added.
    function addLiquidity() external nonReentrant isCurator returns (uint128 liquidity) {
        if (activeTokenId == 0) revert NoActivePosition();
        _checkPriceDeviation();
        liquidity = _compound();
        if (liquidity == 0) revert NothingToAdd();
    }

    /// @notice Withdraws part of the position's liquidity into the vault's idle balances.
    /// @dev    The withdrawn tokens stay in the vault and remain owned pro-rata by shareholders.
    /// @param liquidity Liquidity to withdraw.
    /// @return amount0 Token0 released.
    /// @return amount1 Token1 released.
    function removeLiquidity(uint128 liquidity)
        external
        nonReentrant
        isCurator
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 tokenId = activeTokenId;
        if (tokenId == 0) revert NoActivePosition();

        (,,, uint128 current) = _positionState(tokenId);
        if (liquidity == 0 || liquidity > current) revert InvalidArguments();

        (amount0, amount1) = _withdrawLiquidity(tokenId, liquidity);

        emit LiquidityRemoved(tokenId, liquidity, amount0, amount1);
    }

    /// @notice Moves the vault's liquidity into a new price range.
    /// @dev    Collects fees, closes the current position, then swaps inside the same pool so the
    ///         balances match the new range's ratio, and finally mints the largest position those
    ///         balances support. The swap is sized by UniswapV3VaultMath.solveSwap, and the mint is
    ///         computed from the pool state read back after the swap rather than from the model, so
    ///         a swap that crossed a tick still mints correctly and leaves only the residue idle.
    ///
    ///         The pool's price is compared against its own time-weighted average before and after
    ///         the swap, so a rebalance cannot execute against a manipulated price. Passing zero as
    ///         the price limit defaults it to the edge of that same tolerance band, which makes an
    ///         oversized swap stop at the edge instead of reverting.
    /// @param priceLower       Lower bound of the new range, as a 1e18-scaled human price.
    /// @param priceUpper       Upper bound of the new range, as a 1e18-scaled human price.
    /// @param sqrtPriceLimitX96 Price limit for the swap, or zero to use the tolerance band.
    /// @return tokenId   The new position NFT id.
    /// @return liquidity Liquidity minted.
    /// @return amount0   Token0 consumed by the mint.
    /// @return amount1   Token1 consumed by the mint.
    function rebalance(uint256 priceLower, uint256 priceUpper, uint160 sqrtPriceLimitX96)
        external
        nonReentrant
        isCurator
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        (, uint160 sqrtTwapX96) = _checkPriceDeviation();

        (int24 tickLower, int24 tickUpper) = priceRangeToTicks(priceLower, priceUpper);
        (uint160 sqrtRatioAX96, uint160 sqrtRatioBX96) = UniswapV3VaultMath.sqrtRatiosForTicks(tickLower, tickUpper);

        uint256 oldTokenId = activeTokenId;
        if (oldTokenId != 0) _unwind(oldTokenId);

        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = token1.balanceOf(address(this));
        if (balance0 == 0 && balance1 == 0) revert NothingToRebalance();

        bool zeroForOne;
        uint256 amountIn;
        uint256 amountOut;
        {
            (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
            (zeroForOne, amountIn) = UniswapV3VaultMath.solveSwap(
                UniswapV3VaultMath.SwapParams({
                    sqrtPriceX96: sqrtPriceX96,
                    sqrtRatioAX96: sqrtRatioAX96,
                    sqrtRatioBX96: sqrtRatioBX96,
                    poolLiquidity: pool.liquidity(),
                    feePips: fee,
                    amount0: balance0,
                    amount1: balance1
                })
            );
            if (amountIn != 0) {
                (amountIn, amountOut) = _swap(zeroForOne, amountIn, sqrtPriceLimitX96, sqrtTwapX96, sqrtPriceX96);
            }
        }

        _checkPriceDeviation();

        (tokenId, liquidity, amount0, amount1) = _mintFromBalances(tickLower, tickUpper, sqrtRatioAX96, sqrtRatioBX96);
        _bootstrapShares(liquidity);

        emit Rebalanced(
            oldTokenId,
            tokenId,
            zeroForOne,
            amountIn,
            amountOut,
            token0.balanceOf(address(this)),
            token1.balanceOf(address(this))
        );
        emit PositionCreated(tokenId, tickLower, tickUpper, liquidity, amount0, amount1);
    }

    //
    // Admin Functions
    //

    /// @notice Updates the manipulation guard's window and tolerance.
    /// @param newTwapPeriod          The new window, in seconds.
    /// @param newMaxTwapDeviationBps The new tolerance, in basis points.
    function setTwapConfig(uint32 newTwapPeriod, uint16 newMaxTwapDeviationBps) external isAdmin {
        _validateTwapConfig(newTwapPeriod, newMaxTwapDeviationBps);
        twapPeriod = newTwapPeriod;
        maxTwapDeviationBps = newMaxTwapDeviationBps;
        emit TwapConfigUpdate(newTwapPeriod, newMaxTwapDeviationBps);
    }

    /// @notice Updates the recipient of tokens swept by recoverAssets.
    /// @param newAssetRecoverer The new recipient.
    function setAssetRecoverer(address newAssetRecoverer) external isAdmin {
        if (newAssetRecoverer == address(0)) revert ZeroAddress();
        assetRecoverer = newAssetRecoverer;
        emit AssetRecovererUpdate(newAssetRecoverer);
    }

    //
    // View Functions
    //

    /// @notice The active position's range and liquidity.
    /// @return tickLower Lower tick boundary.
    /// @return tickUpper Upper tick boundary.
    /// @return liquidity Liquidity currently held.
    /// @return tokensOwed0 Token0 collectable from the position.
    /// @return tokensOwed1 Token1 collectable from the position.
    function activePosition()
        external
        view
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity, uint128 tokensOwed0, uint128 tokensOwed1)
    {
        uint256 tokenId = activeTokenId;
        if (tokenId == 0) revert NoActivePosition();
        return _position(tokenId);
    }

    /// @notice Everything the vault owns, valued at the pool's current price.
    /// @dev    The position's principal plus its collectable balance plus the vault's idle tokens.
    ///         Principal is rounded down, matching what the position would actually release.
    ///
    ///         This is a floor, not an exact figure. The position manager only refreshes a
    ///         position's collectable balance when the position is touched, so fees earned since
    ///         the last deposit, redemption or curator action are not counted here even though they
    ///         belong to the vault. The understatement is always in shareholders' favour: a
    ///         redemption compounds those fees before pricing itself, so it pays at least what
    ///         previewRedeem quoted.
    /// @return amount0 Total token0.
    /// @return amount1 Total token1.
    function totalAssets() public view returns (uint256 amount0, uint256 amount1) {
        amount0 = token0.balanceOf(address(this));
        amount1 = token1.balanceOf(address(this));

        uint256 tokenId = activeTokenId;
        if (tokenId == 0) return (amount0, amount1);

        (uint160 sqrtPriceX96, uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity) =
            _positionState(tokenId);
        (uint256 principal0, uint256 principal1) =
            UniswapV3VaultMath.positionValue(sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, liquidity);

        (,,, uint128 owed0, uint128 owed1) = _position(tokenId);
        amount0 += principal0 + owed0;
        amount1 += principal1 + owed1;
    }

    /// @notice The counter amount a position of the given range needs alongside a named amount.
    /// @dev    Answers "if I put in this much token0, how much token1 does the position take?" at
    ///         the pool's current price. Rounds the counter amount up, so supplying it is always
    ///         enough. Works for any position id, not only the vault's own.
    /// @param tokenId   The position NFT id whose range should be used.
    /// @param amount    Amount of the named token.
    /// @param isAmount0 True when the amount is token0, false when it is token1.
    /// @return The amount of the other token required.
    function previewCounterAmount(uint256 tokenId, uint256 amount, bool isAmount0) external view returns (uint256) {
        (uint160 sqrtPriceX96, uint160 sqrtRatioAX96, uint160 sqrtRatioBX96,) = _positionState(tokenId);
        return UniswapV3VaultMath.counterAmount(sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, amount, isAmount0);
    }

    /// @notice The counter amount a not-yet-created range would need alongside a named amount.
    /// @param priceLower Lower bound of the range, as a 1e18-scaled human price.
    /// @param priceUpper Upper bound of the range, as a 1e18-scaled human price.
    /// @param amount     Amount of the named token.
    /// @param isAmount0  True when the amount is token0, false when it is token1.
    /// @return The amount of the other token required.
    function previewCounterAmountForRange(uint256 priceLower, uint256 priceUpper, uint256 amount, bool isAmount0)
        external
        view
        returns (uint256)
    {
        (int24 tickLower, int24 tickUpper) = priceRangeToTicks(priceLower, priceUpper);
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        (uint160 sqrtRatioAX96, uint160 sqrtRatioBX96) = UniswapV3VaultMath.sqrtRatiosForTicks(tickLower, tickUpper);
        return UniswapV3VaultMath.counterAmount(sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, amount, isAmount0);
    }

    /// @notice What a redemption of the given shares would pay out.
    /// @dev    Indicative. Prices the caller's pro-rata slice of everything the vault owns, which
    ///         is what a redemption pays once fees have been compounded. The executed amounts can
    ///         differ by rounding and by fees that accrue between the call and the transaction.
    /// @param shares Shares to price.
    /// @return amount0 Token0 the redemption would pay.
    /// @return amount1 Token1 the redemption would pay.
    function previewRedeem(uint256 shares) external view returns (uint256 amount0, uint256 amount1) {
        uint256 supply = totalSupply();
        if (supply == 0) return (0, 0);
        (uint256 total0, uint256 total1) = totalAssets();
        amount0 = UniswapV3VaultMath.idleShareDown(total0, shares, supply);
        amount1 = UniswapV3VaultMath.idleShareDown(total1, shares, supply);
    }

    /// @notice What a deposit of the given maxima would mint and cost.
    /// @dev    Indicative, on the same terms as previewRedeem.
    /// @param amount0Desired Maximum token0 the caller would supply.
    /// @param amount1Desired Maximum token1 the caller would supply.
    /// @return shares  Shares the deposit would mint.
    /// @return amount0 Token0 the deposit would take.
    /// @return amount1 Token1 the deposit would take.
    function previewDeposit(uint256 amount0Desired, uint256 amount1Desired)
        external
        view
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        uint256 supply = totalSupply();
        if (supply == 0) return (0, 0, 0);

        (uint256 total0, uint256 total1) = totalAssets();
        shares = UniswapV3VaultMath.affordableShares(amount0Desired, amount1Desired, total0, total1, supply);
        if (shares == 0) return (0, 0, 0);

        amount0 = UniswapV3VaultMath.idleShare(total0, shares, supply);
        amount1 = UniswapV3VaultMath.idleShare(total1, shares, supply);
    }

    /// @notice Converts a human price into the pool's Q64.96 sqrt ratio.
    /// @param price The human price, 1e18-scaled.
    /// @return The equivalent sqrt ratio.
    function priceToSqrtPriceX96(uint256 price) external view returns (uint160) {
        return UniswapV3VaultMath.priceToSqrtPriceX96(price, priceScaleNum, priceScaleDen);
    }

    /// @notice Converts a Q64.96 sqrt ratio into a human price.
    /// @param sqrtPriceX96 The sqrt ratio.
    /// @return The equivalent human price, 1e18-scaled.
    function sqrtPriceX96ToPrice(uint160 sqrtPriceX96) external view returns (uint256) {
        return UniswapV3VaultMath.sqrtPriceX96ToPrice(sqrtPriceX96, priceScaleNum, priceScaleDen);
    }

    /// @notice Snaps a human price range onto the pool's usable ticks.
    /// @dev    The lower bound rounds down and the upper bound rounds up, so the resulting range
    ///         always contains the prices that were asked for.
    /// @param priceLower Lower bound, as a 1e18-scaled human price.
    /// @param priceUpper Upper bound, as a 1e18-scaled human price.
    /// @return tickLower The snapped lower tick.
    /// @return tickUpper The snapped upper tick.
    function priceRangeToTicks(uint256 priceLower, uint256 priceUpper)
        public
        view
        returns (int24 tickLower, int24 tickUpper)
    {
        return UniswapV3VaultMath.priceRangeToTicks(priceLower, priceUpper, tickSpacing, priceScaleNum, priceScaleDen);
    }

    //
    // Callbacks
    //

    /// @inheritdoc IUniswapV3SwapCallback
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external override {
        if (!_swapping || msg.sender != address(pool)) revert UnexpectedCallback();
        if (amount0Delta > 0) token0.safeTransfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) token1.safeTransfer(msg.sender, uint256(amount1Delta));
    }

    /// @inheritdoc IERC721Receiver
    /// @dev The vault only ever holds a position it minted itself, so any other incoming NFT, and
    ///      any arriving outside a mint, is rejected rather than silently custodied.
    function onERC721Received(address, address, uint256, bytes calldata) external view override returns (bytes4) {
        if (!_minting || msg.sender != address(positionManager)) revert UnexpectedNft();
        return IERC721Receiver.onERC721Received.selector;
    }

    //
    // Overrides
    //

    /// @inheritdoc UUPSUpgradeable
    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(
        address /* newImplementation */
    )
        internal
        view
        override(UUPSUpgradeable)
        isAdmin
    {
        // Authorization is handled by the isAdmin modifier
    }

    /// @inheritdoc ERC20Upgradeable
    /// @dev Single point where the investor gate is enforced. Minting checks the recipient, burning
    ///      checks the holder and a transfer checks both, so shares can never reach an account that
    ///      is not permitted to hold them.
    function _update(address from, address to, uint256 value) internal override(ERC20Upgradeable) {
        if (from != address(0) && !isInvestor(from)) revert NotInvestor(from);
        if (to != address(0) && !isInvestor(to)) revert NotInvestor(to);
        super._update(from, to, value);
    }

    /// @inheritdoc RecoverFunds
    function _assetRecoverer() internal view override(RecoverFunds) returns (address) {
        return assetRecoverer;
    }

    /// @inheritdoc RecoverFunds
    /// @dev The two pool tokens belong to shareholders, so they are never recoverable; anything
    ///      else that reaches the vault has no claim against it and can be swept in full.
    function _assetRecoverableAmount(address token) internal view override(RecoverFunds) returns (uint256) {
        if (token == address(token0) || token == address(token1)) return 0;
        return IERC20(token).balanceOf(address(this));
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view override(AccessControlUpgradeable) returns (bool) {
        return interfaceId == type(IERC721Receiver).interfaceId || super.supportsInterface(interfaceId);
    }

    //
    // Internal Functions
    //

    /// @notice Collects the position's fees and folds every idle balance back into it.
    /// @dev    The step that makes fees accrue to holders already in the vault. Runs before any
    ///         deposit or redemption is priced, so the share price already reflects the fees at the
    ///         moment an investor transacts. A one-sided remainder cannot be added at the pool's
    ///         ratio and stays idle, still owned pro-rata, until a rebalance swaps it.
    /// @return added Liquidity added back into the position.
    function _compound() internal returns (uint128 added) {
        uint256 tokenId = activeTokenId;
        if (tokenId == 0) return 0;

        (uint256 fees0, uint256 fees1) = _collect(tokenId, type(uint128).max, type(uint128).max);

        (uint160 sqrtPriceX96, uint160 sqrtRatioAX96, uint160 sqrtRatioBX96,) = _positionState(tokenId);

        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = token1.balanceOf(address(this));

        (uint128 target, uint256 need0, uint256 need1) =
            UniswapV3VaultMath.positionPlan(sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, balance0, balance1);
        if (target == 0) {
            if (fees0 != 0 || fees1 != 0) emit Compounded(tokenId, fees0, fees1, 0, 0, 0);
            return 0;
        }

        uint256 used0;
        uint256 used1;
        (added, used0, used1) = _increaseLiquidity(tokenId, need0, need1);
        emit Compounded(tokenId, fees0, fees1, added, used0, used1);
    }

    /// @notice Closes a position and burns its NFT, leaving its contents idle in the vault.
    /// @param tokenId The position NFT id.
    /// @return amount0 Token0 returned to the vault.
    /// @return amount1 Token1 returned to the vault.
    function _unwind(uint256 tokenId) internal returns (uint256 amount0, uint256 amount1) {
        (,,, uint128 liquidity) = _positionState(tokenId);
        if (liquidity != 0) _decreaseLiquidity(tokenId, liquidity);
        (amount0, amount1) = _collect(tokenId, type(uint128).max, type(uint128).max);
        positionManager.burn(tokenId);
        activeTokenId = 0;

        emit PositionUnwound(tokenId, amount0, amount1);
    }

    /// @notice Mints the largest position the vault's current balances support in a range.
    /// @param tickLower     Lower tick boundary.
    /// @param tickUpper     Upper tick boundary.
    /// @param sqrtRatioAX96 The range's lower sqrt ratio.
    /// @param sqrtRatioBX96 The range's upper sqrt ratio.
    /// @return tokenId   The new position NFT id.
    /// @return liquidity Liquidity minted.
    /// @return amount0   Token0 consumed.
    /// @return amount1   Token1 consumed.
    function _mintFromBalances(int24 tickLower, int24 tickUpper, uint160 sqrtRatioAX96, uint160 sqrtRatioBX96)
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = token1.balanceOf(address(this));

        (uint128 target, uint256 need0, uint256 need1) =
            UniswapV3VaultMath.positionPlan(sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, balance0, balance1);
        if (target == 0) revert NothingToRebalance();

        (tokenId, liquidity, amount0, amount1) = _mintPosition(tickLower, tickUpper, need0, need1);
    }

    /// @notice Mints a position NFT to the vault and records it as the active one.
    /// @param tickLower Lower tick boundary.
    /// @param tickUpper Upper tick boundary.
    /// @param need0     Token0 to offer.
    /// @param need1     Token1 to offer.
    /// @return tokenId   The new position NFT id.
    /// @return liquidity Liquidity minted.
    /// @return amount0   Token0 consumed.
    /// @return amount1   Token1 consumed.
    function _mintPosition(int24 tickLower, int24 tickUpper, uint256 need0, uint256 need1)
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        _approve(token0, need0);
        _approve(token1, need1);

        _minting = true;
        (tokenId, liquidity, amount0, amount1) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(token0),
                token1: address(token1),
                fee: fee,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: need0,
                amount1Desired: need1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
        _minting = false;

        _resetApproval(token0);
        _resetApproval(token1);

        activeTokenId = tokenId;
    }

    /// @notice Withdraws owed tokens from a position.
    /// @param tokenId The position NFT id.
    /// @param max0    Upper bound on the token0 withdrawn.
    /// @param max1    Upper bound on the token1 withdrawn.
    /// @return amount0 Token0 withdrawn.
    /// @return amount1 Token1 withdrawn.
    function _collect(uint256 tokenId, uint128 max0, uint128 max1) internal returns (uint256 amount0, uint256 amount1) {
        return positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId, recipient: address(this), amount0Max: max0, amount1Max: max1
            })
        );
    }

    /// @notice Burns liquidity, moving its principal into the position's owed balance.
    /// @dev    The vault's own minimums are zero because it never asks for a specific output here;
    ///         the caller-facing function checks the totals it ends up with instead.
    /// @param tokenId   The position NFT id.
    /// @param liquidity Liquidity to burn.
    /// @return amount0 Token0 released.
    /// @return amount1 Token1 released.
    function _decreaseLiquidity(uint256 tokenId, uint128 liquidity)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        return positionManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId, liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            })
        );
    }

    /// @notice Burns liquidity and withdraws exactly the principal it released.
    /// @dev    Collecting exactly the released principal, rather than everything owed, is what stops
    ///         a partial withdrawal from also sweeping fees that belong to the remaining holders.
    /// @param tokenId   The position NFT id.
    /// @param liquidity Liquidity to withdraw.
    /// @return amount0 Token0 received.
    /// @return amount1 Token1 received.
    function _withdrawLiquidity(uint256 tokenId, uint128 liquidity)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        (uint256 principal0, uint256 principal1) = _decreaseLiquidity(tokenId, liquidity);
        return _collect(tokenId, SafeCast.toUint128(principal0), SafeCast.toUint128(principal1));
    }

    /// @notice Adds liquidity to the active position from the vault's own balances.
    /// @dev    The vault offers at most what it computed it needs, so the position manager's own
    ///         minimums are left at zero; slippage is enforced by the caller-facing function
    ///         against the totals it reports.
    /// @param tokenId The position NFT id.
    /// @param need0   Token0 to offer.
    /// @param need1   Token1 to offer.
    /// @return liquidity Liquidity added.
    /// @return amount0   Token0 consumed.
    /// @return amount1   Token1 consumed.
    function _increaseLiquidity(uint256 tokenId, uint256 need0, uint256 need1)
        internal
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        if (need0 == 0 && need1 == 0) return (0, 0, 0);

        _approve(token0, need0);
        _approve(token1, need1);

        (liquidity, amount0, amount1) = positionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: need0,
                amount1Desired: need1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );

        _resetApproval(token0);
        _resetApproval(token1);
    }

    /// @notice Executes the rebalance swap against the vault's own pool.
    /// @dev    A caller-supplied limit must lie on the far side of the current price, so it can
    ///         only ever tighten the swap. Zero means "use the tolerance band", which bounds the
    ///         swap by the same rule the guard enforces and lets an oversized swap fill partially
    ///         instead of reverting.
    /// @param zeroForOne        True to sell token0.
    /// @param amountIn          Amount to pay into the pool.
    /// @param sqrtPriceLimitX96 Caller's price limit, or zero for the tolerance band.
    /// @param sqrtTwapX96       The average price the band is centred on.
    /// @param sqrtPriceX96      The pool's price before the swap.
    /// @return spent    Amount actually paid into the pool.
    /// @return received Amount actually received from the pool.
    function _swap(
        bool zeroForOne,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96,
        uint160 sqrtTwapX96,
        uint160 sqrtPriceX96
    ) internal returns (uint256 spent, uint256 received) {
        uint160 limit = sqrtPriceLimitX96;
        if (limit == 0) {
            (uint160 bandLow, uint160 bandHigh) = UniswapV3VaultMath.deviationBand(sqrtTwapX96, maxTwapDeviationBps);
            limit = zeroForOne ? bandLow : bandHigh;
        }
        if (zeroForOne) {
            if (limit >= sqrtPriceX96 || limit <= TickMath.MIN_SQRT_RATIO) revert InvalidSqrtPriceLimit();
        } else {
            if (limit <= sqrtPriceX96 || limit >= TickMath.MAX_SQRT_RATIO) revert InvalidSqrtPriceLimit();
        }

        _swapping = true;
        (int256 amount0Delta, int256 amount1Delta) =
            pool.swap(address(this), zeroForOne, SafeCast.toInt256(amountIn), limit, "");
        _swapping = false;

        spent = uint256(zeroForOne ? amount0Delta : amount1Delta);
        received = uint256(-(zeroForOne ? amount1Delta : amount0Delta));
    }

    /// @notice Reverts unless the pool's spot price is close enough to its own recent average.
    /// @dev    The vault's only defence against acting on a manipulated price. A pool whose
    ///         observation history is too short to answer the window cannot be checked at all, so
    ///         that case reverts rather than proceeding unguarded.
    /// @return sqrtPriceX96 The pool's current sqrt price.
    /// @return sqrtTwapX96  The sqrt price implied by the average tick over the window.
    function _checkPriceDeviation() internal view returns (uint160 sqrtPriceX96, uint160 sqrtTwapX96) {
        uint16 cardinality;
        (sqrtPriceX96,,, cardinality,,,) = pool.slot0();

        uint32 period = twapPeriod;
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = period;
        secondsAgos[1] = 0;

        int56[] memory tickCumulatives;
        try pool.observe(secondsAgos) returns (int56[] memory cumulatives, uint160[] memory) {
            tickCumulatives = cumulatives;
        } catch {
            revert TwapUnavailable(period, cardinality);
        }

        sqrtTwapX96 = UniswapV3VaultMath.twapCheck(
            sqrtPriceX96, tickCumulatives[0], tickCumulatives[1], period, maxTwapDeviationBps
        );
    }

    /// @notice Mints the opening share supply when the vault has none.
    /// @dev    Shares start one-to-one with liquidity, so no virtual offset is needed: a would-be
    ///         attacker cannot inflate the share price by donating tokens, because donated balances
    ///         are claimed pro-rata by every holder rather than by the next depositor.
    /// @param liquidity Liquidity just minted, which becomes the opening supply.
    function _bootstrapShares(uint128 liquidity) internal {
        if (totalSupply() == 0 && liquidity != 0) _mint(msg.sender, liquidity);
    }

    /// @notice The pool price plus a position's range bounds and liquidity.
    /// @param tokenId The position NFT id.
    /// @return sqrtPriceX96  The pool's current price.
    /// @return sqrtRatioAX96 The position's lower sqrt ratio.
    /// @return sqrtRatioBX96 The position's upper sqrt ratio.
    /// @return liquidity     The position's liquidity.
    function _positionState(uint256 tokenId)
        internal
        view
        returns (uint160 sqrtPriceX96, uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity)
    {
        (int24 tickLower, int24 tickUpper, uint128 held,,) = _position(tokenId);
        liquidity = held;
        (sqrtPriceX96,,,,,,) = pool.slot0();
        (sqrtRatioAX96, sqrtRatioBX96) = UniswapV3VaultMath.sqrtRatiosForTicks(tickLower, tickUpper);
    }

    /// @notice The fields of a position the vault cares about.
    /// @dev    The position manager returns twelve values; decoding them in one place keeps that
    ///         decoding out of every caller.
    /// @param tokenId The position NFT id.
    /// @return tickLower   Lower tick boundary.
    /// @return tickUpper   Upper tick boundary.
    /// @return liquidity   Liquidity currently held.
    /// @return tokensOwed0 Token0 collectable from the position.
    /// @return tokensOwed1 Token1 collectable from the position.
    function _position(uint256 tokenId)
        internal
        view
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity, uint128 tokensOwed0, uint128 tokensOwed1)
    {
        (,,,,, tickLower, tickUpper, liquidity,,, tokensOwed0, tokensOwed1) = positionManager.positions(tokenId);
    }

    /// @notice Reverts unless the vault already holds the required amount of a token.
    /// @param token    The token to check.
    /// @param required The amount needed.
    function _requireIdle(IERC20 token, uint256 required) internal view {
        uint256 available = token.balanceOf(address(this));
        if (required > available) revert InsufficientIdleBalance(address(token), required, available);
    }

    /// @notice Approves the position manager for an exact amount.
    /// @param token  The token to approve.
    /// @param amount The allowance to set.
    function _approve(IERC20 token, uint256 amount) internal {
        if (amount != 0) token.forceApprove(address(positionManager), amount);
    }

    /// @notice Clears the position manager's allowance.
    /// @dev Called after every position manager interaction so no standing allowance is left.
    /// @param token The token whose allowance to clear.
    function _resetApproval(IERC20 token) internal {
        if (token.allowance(address(this), address(positionManager)) != 0) {
            token.forceApprove(address(positionManager), 0);
        }
    }

    /// @notice Validates a manipulation-guard configuration.
    /// @param period The window, in seconds.
    /// @param maxBps The tolerance, in basis points.
    function _validateTwapConfig(uint32 period, uint16 maxBps) internal pure {
        if (period == 0 || maxBps == 0 || maxBps > _MAX_BPS) revert InvalidArguments();
    }
}

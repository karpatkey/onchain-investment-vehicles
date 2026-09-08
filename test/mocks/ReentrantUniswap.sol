// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {INonfungiblePositionManager} from "../../src/interfaces/INonfungiblePositionManager.sol";
import {IUniswapV3SwapCallback} from "../../src/interfaces/IUniswapV3SwapCallback.sol";
import {LiquidityAmounts} from "../../src/libraries/uniswap/LiquidityAmounts.sol";
import {SqrtPriceMath} from "../../src/libraries/uniswap/SqrtPriceMath.sol";
import {TickMath} from "../../src/libraries/uniswap/TickMath.sol";

/// @title  Reentrant Uniswap test doubles
/// @author KPK
/// @notice A minimal, hostile stand-in for the Uniswap v3 contracts the vault talks to.
/// @dev    Real pool tokens never call back into their sender, so on a mainnet fork there is no way
///         to actually attempt reentrancy against the vault. These doubles create the opportunity:
///         each one can be told to call an arbitrary function on the vault at the exact moment the
///         vault is mid-operation and has already handed over control. That is what turns the
///         `nonReentrant` modifiers from an assertion by inspection into a tested property.
///
///         They implement only as much of Uniswap as the vault needs to reach that moment, but the
///         amounts they compute come from Uniswap's own libraries so the vault's arithmetic behaves
///         as it would against the real thing.

/// @notice Records an attack to run at the next opportunity.
struct Attack {
    address target;
    bytes payload;
    bool armed;
}

/// @notice A stand-in for the Uniswap v3 factory, resolving one pair to one pool.
contract MockUniswapV3Factory {
    address public pool;

    /// @notice Points the factory at the pool every lookup should resolve to.
    /// @param pool_ The pool address.
    function setPool(address pool_) external {
        pool = pool_;
    }

    /// @notice Resolves any pair and fee tier to the configured pool.
    /// @return The configured pool.
    function getPool(address, address, uint24) external view returns (address) {
        return pool;
    }
}

/// @notice A stand-in for a Uniswap v3 pool, fixed at one price and able to re-enter its caller.
contract MockUniswapV3Pool {
    using SafeERC20 for IERC20;

    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    int24 public constant tickSpacing = 60;

    /// @dev The pool sits at tick 0, so the sqrt price is exactly 2**96.
    uint160 public sqrtPriceX96 = 79_228_162_514_264_337_593_543_950_336;
    int24 public tick;
    uint128 public liquidity = 1e24;

    Attack private _attack;

    constructor(address token0_, address token1_, uint24 fee_) {
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
    }

    /// @notice Arms a call to make from inside the next swap, before the callback runs.
    /// @param target  Contract to call.
    /// @param payload Calldata to send it.
    function armSwapAttack(address target, bytes calldata payload) external {
        _attack = Attack({target: target, payload: payload, armed: true});
    }

    /// @notice The pool's price and oracle bookkeeping.
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, tick, 0, 100, 100, 0, true);
    }

    /// @notice Cumulative ticks consistent with the pool having sat at its current tick throughout.
    /// @param secondsAgos Ages at which to read the cumulatives.
    /// @return tickCumulatives Cumulative tick values.
    /// @return secondsPerLiquidity Unused by the vault.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidity)
    {
        tickCumulatives = new int56[](2);
        secondsPerLiquidity = new uint160[](2);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = int56(tick) * int56(uint56(secondsAgos[0]));
    }

    /// @notice Swaps at the pool's fixed price, optionally re-entering the caller first.
    /// @dev    The price does not move, which is all the vault's rebalance needs to proceed; the
    ///         point of this double is the re-entry, not the pricing.
    /// @param recipient        Receives the output.
    /// @param zeroForOne       True to sell token0.
    /// @param amountSpecified  Exact input amount.
    /// @return amount0 The pool's token0 delta.
    /// @return amount1 The pool's token1 delta.
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        if (_attack.armed) {
            _attack.armed = false;
            (bool ok, bytes memory reason) = _attack.target.call(_attack.payload);
            if (!ok) {
                assembly {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
        }

        uint256 amountIn = uint256(amountSpecified);
        uint256 amountOut = amountIn; // one-to-one; the price is fixed by construction

        if (zeroForOne) {
            amount0 = int256(amountIn);
            amount1 = -int256(amountOut);
            IERC20(token1).safeTransfer(recipient, amountOut);
        } else {
            amount1 = int256(amountIn);
            amount0 = -int256(amountOut);
            IERC20(token0).safeTransfer(recipient, amountOut);
        }

        IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
    }
}

/// @notice A stand-in for the position manager, able to re-enter its caller mid-operation.
contract MockPositionManager {
    using SafeERC20 for IERC20;

    struct Position {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 owed0;
        uint128 owed1;
        address owner;
    }

    address public immutable factory;
    MockUniswapV3Pool public pool;

    mapping(uint256 => Position) private _positions;
    uint256 private _nextId = 1;

    Attack private _attack;

    constructor(address factory_) {
        factory = factory_;
    }

    /// @notice Points the manager at the pool it prices positions against.
    /// @param pool_ The pool.
    function setPool(MockUniswapV3Pool pool_) external {
        pool = pool_;
    }

    /// @notice Arms a call to make from inside the next increaseLiquidity, before any accounting.
    /// @param target  Contract to call.
    /// @param payload Calldata to send it.
    function armIncreaseAttack(address target, bytes calldata payload) external {
        _attack = Attack({target: target, payload: payload, armed: true});
    }

    /// @notice The stored state of a position, in the position manager's own return shape.
    /// @param tokenId The position id.
    function positions(uint256 tokenId)
        external
        view
        returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128)
    {
        Position memory p = _positions[tokenId];
        return (0, address(0), p.token0, p.token1, p.fee, p.tickLower, p.tickUpper, p.liquidity, 0, 0, p.owed0, p.owed1);
    }

    /// @notice Owner of a position.
    /// @param tokenId The position id.
    /// @return The owner.
    function ownerOf(uint256 tokenId) external view returns (address) {
        return _positions[tokenId].owner;
    }

    /// @notice Opens a position, pulling exactly what the liquidity costs.
    function mint(INonfungiblePositionManager.MintParams calldata params)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        (liquidity, amount0, amount1) =
            _price(params.tickLower, params.tickUpper, params.amount0Desired, params.amount1Desired);

        tokenId = _nextId++;
        _positions[tokenId] = Position({
            token0: params.token0,
            token1: params.token1,
            fee: params.fee,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: liquidity,
            owed0: 0,
            owed1: 0,
            owner: params.recipient
        });

        _pull(params.token0, amount0);
        _pull(params.token1, amount1);
    }

    /// @notice Adds liquidity to a position, running any armed attack first.
    function increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams calldata params)
        external
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        if (_attack.armed) {
            _attack.armed = false;
            (bool ok, bytes memory reason) = _attack.target.call(_attack.payload);
            if (!ok) {
                assembly {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
        }

        Position storage p = _positions[params.tokenId];
        (liquidity, amount0, amount1) = _price(p.tickLower, p.tickUpper, params.amount0Desired, params.amount1Desired);

        p.liquidity += liquidity;
        _pull(p.token0, amount0);
        _pull(p.token1, amount1);
    }

    /// @notice Burns liquidity, crediting the principal as owed.
    function decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        Position storage p = _positions[params.tokenId];
        (amount0, amount1) = _amountsFor(p.tickLower, p.tickUpper, params.liquidity, false);

        p.liquidity -= params.liquidity;
        p.owed0 += uint128(amount0);
        p.owed1 += uint128(amount1);
    }

    /// @notice Withdraws owed tokens.
    function collect(INonfungiblePositionManager.CollectParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        Position storage p = _positions[params.tokenId];

        amount0 = params.amount0Max < p.owed0 ? params.amount0Max : p.owed0;
        amount1 = params.amount1Max < p.owed1 ? params.amount1Max : p.owed1;

        p.owed0 -= uint128(amount0);
        p.owed1 -= uint128(amount1);

        if (amount0 != 0) IERC20(p.token0).safeTransfer(params.recipient, amount0);
        if (amount1 != 0) IERC20(p.token1).safeTransfer(params.recipient, amount1);
    }

    /// @notice Burns an empty position.
    /// @param tokenId The position id.
    function burn(uint256 tokenId) external {
        delete _positions[tokenId];
    }

    /// @notice Credits a position with fees, so compounding has something to fold in.
    /// @param tokenId The position id.
    /// @param fees0   Token0 to credit.
    /// @param fees1   Token1 to credit.
    function creditFees(uint256 tokenId, uint128 fees0, uint128 fees1) external {
        Position storage p = _positions[tokenId];
        p.owed0 += fees0;
        p.owed1 += fees1;
    }

    /// @notice The liquidity a pair of maxima buys, and what it costs.
    function _price(int24 tickLower, int24 tickUpper, uint256 desired0, uint256 desired1)
        private
        view
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(tickUpper);
        uint160 sqrtP = pool.sqrtPriceX96();

        liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtA, sqrtB, desired0, desired1);

        // Charge what the liquidity costs rounded up, exactly as the real pool does. Crediting a
        // withdrawal rounds down, so the manager always holds at least what it owes; pulling the
        // rounded-down amount instead leaves it a wei short after enough round trips.
        (amount0, amount1) = _amountsFor(tickLower, tickUpper, liquidity, true);

        if (amount0 > desired0) amount0 = desired0;
        if (amount1 > desired1) amount1 = desired1;
    }

    /// @notice What a liquidity amount is worth at the pool's price.
    /// @param roundUp True when charging the caller, false when crediting them.
    function _amountsFor(int24 tickLower, int24 tickUpper, uint128 liquidity, bool roundUp)
        private
        view
        returns (uint256 amount0, uint256 amount1)
    {
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(tickUpper);
        uint160 sqrtP = pool.sqrtPriceX96();

        if (sqrtP <= sqrtA) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity, roundUp);
        } else if (sqrtP < sqrtB) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtB, liquidity, roundUp);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtP, liquidity, roundUp);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity, roundUp);
        }
    }

    /// @notice Takes an amount from the caller.
    function _pull(address token, uint256 amount) private {
        if (amount != 0) IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }
}

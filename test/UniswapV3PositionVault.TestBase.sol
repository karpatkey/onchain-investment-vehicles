// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IUniswapV3PositionVault} from "../src/IUniswapV3PositionVault.sol";
import {UniswapV3PositionVault} from "../src/UniswapV3PositionVault.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3Pool.sol";
import {UniswapV3SwapHelper} from "./mocks/UniswapV3SwapHelper.sol";

/// @title  UniswapV3PositionVaultTestBase
/// @author KPK
/// @notice Shared fork fixture for the UniswapV3PositionVault suites.
/// @dev    Unlike the factory suites, this one pins a block. Every assertion here depends on a
///         pool's price, tick and observation history, so an unpinned fork would make expected
///         amounts drift with mainnet and turn real regressions into noise. The pinned block is
///         recent enough that the pools have a full observation buffer, which the manipulation
///         guard needs in order to be exercised at all.
///
///         The pool is chosen by overridable getters rather than fixed, so a suite can point the
///         same fixture at a pool with a different decimal pairing. Amounts are supplied the same
///         way, because a sensible position size in a 6-decimal token is not one in an 8-decimal
///         token.
abstract contract UniswapV3PositionVaultTestBase is Test {
    //
    // Mainnet constants
    //

    /// @dev Pinned so pool state is reproducible across runs.
    uint256 internal constant FORK_BLOCK = 25_930_000;

    address internal constant POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address internal constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    /// @dev USDC/WETH at the 0.05% fee tier: token0 has 6 decimals, token1 has 18.
    address internal constant POOL_USDC_WETH = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;

    /// @dev WBTC/WETH at the 0.3% fee tier: token0 has 8 decimals, token1 has 18.
    address internal constant POOL_WBTC_WETH = 0xCBCdF9626bC03E24f779434178A73a0B4bad62eD;

    //
    // Fixture
    //

    UniswapV3PositionVault internal vault;
    UniswapV3SwapHelper internal swapHelper;

    /// @notice The pool this fixture points at, resolved from the getters below.
    address internal POOL;

    /// @notice That pool's fee tier.
    uint24 internal FEE;

    IERC20 internal token0;
    IERC20 internal token1;

    address internal admin = makeAddr("admin");
    address internal curator = makeAddr("curator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");
    address internal recoverer = makeAddr("recoverer");

    /// @notice An offer high enough not to bind, for the side a test is not about.
    /// @dev    Deliberately not type(uint256).max: a deposit turns each offer into a share count by
    ///         multiplying by the supply, so an offer that large has no representable answer and
    ///         reverts rather than meaning "no limit".
    uint256 internal constant UNBOUNDED = type(uint128).max;

    uint32 internal constant TWAP_PERIOD = 300;
    uint16 internal constant MAX_DEVIATION_BPS = 500;

    //
    // Fixture parameters, overridable per suite
    //

    /// @notice The pool the vault under test provides liquidity to.
    function _poolAddress() internal view virtual returns (address) {
        return POOL_USDC_WETH;
    }

    /// @notice That pool's fee tier.
    function _poolFee() internal view virtual returns (uint24) {
        return 500;
    }

    /// @notice The pool's token0, which must sort below token1.
    function _token0Address() internal view virtual returns (address) {
        return USDC;
    }

    /// @notice The pool's token1.
    function _token1Address() internal view virtual returns (address) {
        return WETH;
    }

    /// @notice A working balance of token0 for each actor.
    function _fundAmount0() internal view virtual returns (uint256) {
        return 5_000_000e6;
    }

    /// @notice A working balance of token1 for each actor.
    function _fundAmount1() internal view virtual returns (uint256) {
        return 5_000e18;
    }

    /// @notice Token0 to trade when accruing fees for the active position.
    function _feeSwapAmount0() internal view virtual returns (uint256) {
        return 200_000e6;
    }

    /// @notice Token1 to trade when accruing fees for the active position.
    function _feeSwapAmount1() internal view virtual returns (uint256) {
        return 50e18;
    }

    /// @notice Token0 balance the price-moving helper needs to shift a deep pool.
    function _whaleAmount0() internal view virtual returns (uint256) {
        return 2_000_000_000e6;
    }

    /// @notice Token1 balance the price-moving helper needs to shift a deep pool.
    function _whaleAmount1() internal view virtual returns (uint256) {
        return 1_000_000e18;
    }

    /// @notice Token0 committed by the default opening position.
    function _openAmount0() internal view virtual returns (uint256) {
        return 100_000e6;
    }

    /// @notice Name and symbol of the share token under test.
    function _vaultName() internal view virtual returns (string memory) {
        return "kpk USDC/WETH Position";
    }

    /// @notice Symbol of the share token under test.
    function _vaultSymbol() internal view virtual returns (string memory) {
        return "kpkUW";
    }

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("MAINNET_URL"), FORK_BLOCK);

        POOL = _poolAddress();
        FEE = _poolFee();
        token0 = IERC20(_token0Address());
        token1 = IERC20(_token1Address());

        _requireUniswapDeployed();

        address implementation = address(new UniswapV3PositionVault());
        vault = UniswapV3PositionVault(
            UnsafeUpgrades.deployUUPSProxy(
                implementation,
                abi.encodeCall(
                    UniswapV3PositionVault.initialize,
                    (IUniswapV3PositionVault.InitParams({
                            name: _vaultName(),
                            symbol: _vaultSymbol(),
                            admin: admin,
                            curator: curator,
                            assetRecoverer: recoverer,
                            positionManager: POSITION_MANAGER,
                            token0: _token0Address(),
                            token1: _token1Address(),
                            fee: FEE,
                            twapPeriod: TWAP_PERIOD,
                            maxTwapDeviationBps: MAX_DEVIATION_BPS
                        }))
                )
            )
        );

        swapHelper = new UniswapV3SwapHelper();

        // The curator holds shares from the opening position, so it must be allowed to hold them.
        vm.startPrank(admin);
        vault.grantRole(vault.INVESTOR(), curator);
        vault.grantRole(vault.INVESTOR(), alice);
        vault.grantRole(vault.INVESTOR(), bob);
        vm.stopPrank();

        _fund(alice);
        _fund(bob);
        _fund(address(swapHelper));

        vm.label(address(vault), "vault");
        vm.label(POOL, "pool");
        vm.label(address(token0), "token0");
        vm.label(address(token1), "token1");
    }

    //
    // Helpers
    //

    /// @notice Fails with a readable message if the fork does not have Uniswap v3 deployed.
    function _requireUniswapDeployed() internal view {
        require(POSITION_MANAGER.code.length != 0, "position manager missing on this fork");
        require(UNISWAP_V3_FACTORY.code.length != 0, "uniswap factory missing on this fork");
        require(POOL.code.length != 0, "pool missing on this fork");
    }

    /// @notice Gives an account a working balance of both pool tokens.
    function _fund(address account) internal {
        deal(address(token0), account, _fundAmount0());
        deal(address(token1), account, _fundAmount1());
        vm.startPrank(account);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Moves tokens into the vault so the curator can open a position with them.
    function _seedVault(uint256 amount0, uint256 amount1) internal {
        deal(address(token0), address(vault), token0.balanceOf(address(vault)) + amount0);
        deal(address(token1), address(vault), token1.balanceOf(address(vault)) + amount1);
    }

    /// @notice The pool's current human price, in the units the vault takes.
    function _spotPrice() internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(POOL).slot0();
        return vault.sqrtPriceX96ToPrice(sqrtPriceX96);
    }

    /// @notice A price range around the current spot price, as a fraction in basis points.
    function _rangeAroundSpot(uint256 widthBps) internal view returns (uint256 lower, uint256 upper) {
        uint256 spot = _spotPrice();
        lower = spot * (10_000 - widthBps) / 10_000;
        upper = spot * (10_000 + widthBps) / 10_000;
    }

    /// @notice Opens a position around the current price funded with the given token0 amount.
    function _openPosition(uint256 amount0) internal returns (uint256 tokenId) {
        (uint256 lower, uint256 upper) = _rangeAroundSpot(1000);
        uint256 need1 = vault.previewCounterAmountForRange(lower, upper, amount0, true);

        _seedVault(amount0, need1 + 1e15);

        vm.prank(curator);
        (tokenId,,,) = vault.createPosition(lower, upper, amount0, true, block.timestamp);
    }

    /// @notice Opens a position with this fixture's default size.
    function _openPosition() internal returns (uint256 tokenId) {
        return _openPosition(_openAmount0());
    }

    /// @notice Trades back and forth through the pool so the active position accrues fees.
    function _accrueFees() internal {
        swapHelper.swap(POOL, true, int256(_feeSwapAmount0()));
        swapHelper.swap(POOL, false, int256(_feeSwapAmount1()));
    }

    /// @notice Pushes the pool price by a fraction of itself, in basis points.
    /// @dev    Used to drive the position out of range and to trip the manipulation guard.
    function _movePriceBps(int256 bps) internal {
        // Moving a deep pool by a visible amount costs far more than the helper's working balance,
        // so top it up first; the swap stops at the price limit and only spends what it needs.
        deal(address(token0), address(swapHelper), _whaleAmount0());
        deal(address(token1), address(swapHelper), _whaleAmount1());

        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(POOL).slot0();
        // The deviation cap is on price, so the sqrt price moves by roughly half as much.
        uint256 target = bps > 0
            ? uint256(sqrtPriceX96) * (20_000 + uint256(bps)) / 20_000
            : uint256(sqrtPriceX96) * (20_000 - uint256(-bps)) / 20_000;
        swapHelper.swapToPrice(POOL, bps < 0, uint160(target));
    }

    /// @notice The active position's liquidity, or zero when there is none.
    function _positionLiquidity() internal view returns (uint128 liquidity) {
        if (vault.activeTokenId() == 0) return 0;
        (,, liquidity,,) = vault.activePosition();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IUniswapV3PositionVault} from "../src/IUniswapV3PositionVault.sol";
import {UniswapV3PositionVault} from "../src/UniswapV3PositionVault.sol";
import {Mock_ERC20} from "./mocks/tokens.sol";
import {MockPositionManager, MockUniswapV3Factory, MockUniswapV3Pool} from "./mocks/ReentrantUniswap.sol";

/// @title  UniswapV3PositionVaultReentrancyTest
/// @author KPK
/// @notice Proves the vault's reentrancy guards actually engage.
/// @dev    Needs no fork. Against real pool tokens there is no way to attempt reentrancy at all,
///         because a standard ERC-20 never calls back into its sender, so the guards can only be
///         exercised through contracts that will. The doubles in ReentrantUniswap.sol re-enter the
///         vault at the two moments it has genuinely handed over control: inside the position
///         manager while liquidity is being added, and inside the pool during a rebalance swap.
contract UniswapV3PositionVaultReentrancyTest is Test {
    UniswapV3PositionVault internal vault;
    MockUniswapV3Factory internal factory;
    MockUniswapV3Pool internal pool;
    MockPositionManager internal manager;

    Mock_ERC20 internal token0;
    Mock_ERC20 internal token1;

    address internal admin = makeAddr("admin");
    address internal curator = makeAddr("curator");
    address internal alice = makeAddr("alice");

    uint24 internal constant FEE = 3000;

    /// @dev Both tokens have 18 decimals and the mock pool sits at tick 0, so its human price is
    ///      exactly 1e18 and a range of a half to double straddles it comfortably.
    uint256 internal constant PRICE_LOWER = 0.5e18;
    uint256 internal constant PRICE_UPPER = 2e18;

    function setUp() public {
        _deploySortedTokens();

        factory = new MockUniswapV3Factory();
        pool = new MockUniswapV3Pool(address(token0), address(token1), FEE);
        factory.setPool(address(pool));

        manager = new MockPositionManager(address(factory));
        manager.setPool(pool);

        address implementation = address(new UniswapV3PositionVault());
        vault = UniswapV3PositionVault(
            UnsafeUpgrades.deployUUPSProxy(
                implementation,
                abi.encodeCall(
                    UniswapV3PositionVault.initialize,
                    (IUniswapV3PositionVault.InitParams({
                            name: "Reentrancy probe",
                            symbol: "PROBE",
                            admin: admin,
                            curator: curator,
                            assetRecoverer: admin,
                            positionManager: address(manager),
                            token0: address(token0),
                            token1: address(token1),
                            fee: FEE,
                            twapPeriod: 300,
                            maxTwapDeviationBps: 500
                        }))
                )
            )
        );

        bytes32 investorRole = vault.INVESTOR();
        vm.startPrank(admin);
        vault.grantRole(investorRole, curator);
        vault.grantRole(investorRole, alice);
        vm.stopPrank();

        // The pool needs an inventory to pay swap output from.
        token0.mint(address(pool), 1_000_000e18);
        token1.mint(address(pool), 1_000_000e18);

        token0.mint(alice, 100_000e18);
        token1.mint(alice, 100_000e18);
        vm.startPrank(alice);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        _openPosition();
    }

    //
    // The probes
    //

    function test_reentrancy_depositCannotReenterFromThePositionManager() public {
        // While the vault is inside deposit and has handed control to the position manager, try to
        // start a second deposit.
        manager.armIncreaseAttack(
            address(vault), abi.encodeCall(vault.deposit, (100e18, 100e18, 0, 0, block.timestamp + 1))
        );

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
        vault.deposit(1000e18, 1000e18, 0, 0, block.timestamp);
    }

    function test_reentrancy_redeemCannotReenterFromThePositionManager() public {
        vm.prank(alice);
        (uint256 shares,,) = vault.deposit(1000e18, 1000e18, 0, 0, block.timestamp);

        // Compounding runs first on a redemption, so the manager gets control before the burn.
        manager.creditFees(vault.activeTokenId(), 50e18, 50e18);
        manager.armIncreaseAttack(address(vault), abi.encodeCall(vault.redeem, (1, 0, 0, block.timestamp + 1)));

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
        vault.redeem(shares, 0, 0, block.timestamp);
    }

    function test_reentrancy_curatorOperationsCannotReenterFromThePositionManager() public {
        manager.creditFees(vault.activeTokenId(), 50e18, 50e18);
        manager.armIncreaseAttack(address(vault), abi.encodeCall(vault.unwindPosition, ()));

        vm.prank(curator);
        vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
        vault.collectFees();
    }

    function test_reentrancy_rebalanceCannotReenterFromTheSwap() public {
        vm.prank(alice);
        vault.deposit(1000e18, 1000e18, 0, 0, block.timestamp);

        // Leave the vault holding only token0, so the rebalance has to swap.
        vm.prank(curator);
        vault.unwindPosition();
        deal(address(token1), address(vault), 0);

        pool.armSwapAttack(address(vault), abi.encodeCall(vault.redeem, (1, 0, 0, block.timestamp + 1)));

        vm.prank(curator);
        vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
        vault.rebalanceWithSwap(PRICE_LOWER, PRICE_UPPER, 500);
    }

    function test_swapCallback_isRefusedOutsideTheVaultsOwnSwap() public {
        // The pool itself cannot drain the vault outside a rebalance.
        vm.prank(address(pool));
        vm.expectRevert(IUniswapV3PositionVault.UnexpectedCallback.selector);
        vault.uniswapV3SwapCallback(1e18, -1e18, "");
    }

    //
    // Helpers
    //

    /// @notice Deploys two 18-decimal tokens, ordered so the first sorts below the second.
    function _deploySortedTokens() private {
        Mock_ERC20 a = new Mock_ERC20("TKA", 18);
        Mock_ERC20 b = new Mock_ERC20("TKB", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
    }

    /// @notice Seeds the vault and opens its first position around the mock pool's price.
    function _openPosition() private {
        token0.mint(address(vault), 10_000e18);
        token1.mint(address(vault), 10_000e18);

        vm.prank(curator);
        vault.createPosition(PRICE_LOWER, PRICE_UPPER, 1000e18, true);
    }
}

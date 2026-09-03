// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {KpkSharesNav} from "../src/KpkSharesNav.sol";
import {IKpkSharesNav} from "../src/IKpkSharesNav.sol";
import {WatermarkFee} from "../src/FeeModules/WatermarkFee.sol";
import {Mock_ERC20} from "./mocks/tokens.sol";
import {MockNavCalculator} from "./mocks/MockNavCalculator.sol";

/// @title kpkSharesNavTestBase
/// @notice Shared fixture for the `KpkSharesNav` suites.
/// @dev A parallel tree rather than an extension of `kpkSharesTestBase`: that base is built around
///      the operator-supplied-price idiom (`processRequests(..., SHARES_PRICE)` repeated across three
///      deploy paths), and this contract's whole point is that no such price exists.
contract kpkSharesNavTestBase is Test {
    bytes32 internal constant OPERATOR = keccak256("OPERATOR");
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    /// @notice $1.00 per share, in the 8-decimal USD scale everything here uses
    uint256 internal constant ONE_USD = 1e8;

    uint64 internal constant SUBSCRIPTION_TTL = 1 days;
    uint64 internal constant REDEMPTION_TTL = 1 days;

    address internal admin = makeAddr("admin");
    address internal ops = makeAddr("ops");
    address internal safe = makeAddr("safe");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    KpkSharesNav internal fund;
    MockNavCalculator internal nav;
    Mock_ERC20 internal usdc;
    WatermarkFee internal perfFeeModule;

    function setUp() public virtual {
        usdc = new Mock_ERC20("USDC", 6);
        nav = new MockNavCalculator();
        perfFeeModule = new WatermarkFee();

        // USDC registered at $1.00, priced with 8 decimals
        nav.registerAsset(address(usdc), 6, int256(ONE_USD), 8);
        nav.setNavAccount(safe);

        fund = _deployFund(0, 0, 0);

        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
        usdc.mint(safe, 1_000_000e6);

        vm.prank(alice);
        usdc.approve(address(fund), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(fund), type(uint256).max);
        // The safe must approve the fund so redemptions can be paid out of it
        vm.prank(safe);
        usdc.approve(address(fund), type(uint256).max);
    }

    /// @notice Deploys a fund behind a UUPS proxy with the given fee rates
    function _deployFund(uint256 mgmtFee, uint256 redemptionFee, uint256 perfFee)
        internal
        returns (KpkSharesNav deployed)
    {
        address impl = address(new KpkSharesNav());
        address proxy = UnsafeUpgrades.deployUUPSProxy(
            impl,
            abi.encodeCall(
                KpkSharesNav.initialize,
                (KpkSharesNav.ConstructorParams({
                        asset: address(usdc),
                        admin: admin,
                        name: "kpk NAV",
                        symbol: "kpkNAV",
                        safe: safe,
                        subscriptionRequestTtl: SUBSCRIPTION_TTL,
                        redemptionRequestTtl: REDEMPTION_TTL,
                        feeReceiver: feeRecipient,
                        managementFeeRate: mgmtFee,
                        redemptionFeeRate: redemptionFee,
                        performanceFeeModule: address(perfFeeModule),
                        performanceFeeRate: perfFee,
                        navCalculator: address(nav),
                        initialSharePrice: ONE_USD
                    }))
            )
        );
        deployed = KpkSharesNav(proxy);

        vm.prank(admin);
        deployed.grantRole(OPERATOR, ops);
    }

    /// @notice Sets the fund's NAV so that one share is worth `priceUsd8`
    /// @dev The fund derives `price = nav * 1e18 / totalSupply`, so this inverts that.
    function _setSharePrice(uint256 priceUsd8) internal {
        uint256 supply = fund.totalSupply();
        nav.setNavValue(int256((priceUsd8 * supply) / 1e18));
    }

    /// @notice Subscribes and settles in one step, returning the shares minted
    function _subscribeAndSettle(address investor, uint256 assets, uint256 minShares)
        internal
        returns (uint256 requestId)
    {
        vm.prank(investor);
        requestId = fund.requestSubscription(assets, minShares, address(usdc), investor);
        _approve(requestId);
    }

    /// @notice Approves a single request as the operator
    function _approve(uint256 requestId) internal {
        uint256[] memory approvals = new uint256[](1);
        approvals[0] = requestId;
        vm.prank(ops);
        fund.processRequests(approvals, new uint256[](0), address(usdc));
    }

    /// @notice Rejects a single request as the operator
    function _reject(uint256 requestId) internal {
        uint256[] memory rejections = new uint256[](1);
        rejections[0] = requestId;
        vm.prank(ops);
        fund.processRequests(new uint256[](0), rejections, address(usdc));
    }

    /// @notice Seeds the fund with a starting supply at $1.00/share
    function _seedFund(address investor, uint256 assets) internal {
        _subscribeAndSettle(investor, assets, 1);
        // NAV now equals the deposited value: assets are 6-decimal, NAV is 8-decimal USD
        nav.setNavValue(int256(assets * 100));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KpkOivFactory} from "src/KpkOivFactory.sol";
import {KpkSharesNav} from "src/KpkSharesNav.sol";
import {KpkSharesNavFactory} from "src/KpkSharesNavFactory.sol";
import {TimelockParams} from "src/interfaces/IKpkTimelockDeployer.sol";
import {IRoles} from "src/interfaces/IRoles.sol";
import {DeployOiv} from "script/DeployOiv.s.sol";
import {OivTestConstants} from "test/OivTestConstants.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {MockNavCalculator} from "test/mocks/MockNavCalculator.sol";

/// @notice `KpkSharesNavFactory` composed against the DEPLOYED `KpkOivFactory` on a mainnet fork.
///         Run with: forge test --match-path test/KpkSharesNavFactory.t.sol (MAINNET_URL set).
contract KpkSharesNavFactoryTest is OivTestConstants {
    bytes32 internal constant OPERATOR = keccak256("OPERATOR");
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    uint256 internal constant ONE_USD = 1e8;
    int256 internal constant ONE_USD_PRICE = 1e8;

    address internal admin = makeAddr("admin");
    address internal managerSigner = makeAddr("managerSigner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal govSafe = makeAddr("govSafe");
    address internal superadminSafe = makeAddr("superadminSafe");
    address internal managerVeto = makeAddr("managerVeto");
    address internal lpVeto = makeAddr("lpVeto");

    KpkOivFactory internal live;
    KpkSharesNav internal mastercopy;
    MockNavCalculator internal nav;
    KpkSharesNavFactory internal navFactory;
    Mock_ERC20 internal baseAsset;
    Mock_ERC20 internal depositOnly;
    Mock_ERC20 internal redeemOnly;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_URL"));

        live = KpkOivFactory(new DeployOiv().FACTORY());
        assertGt(address(live).code.length, 0, "live KpkOivFactory missing on the fork");

        mastercopy = new KpkSharesNav();
        nav = new MockNavCalculator();
        baseAsset = new Mock_ERC20("USDC", 6);
        depositOnly = new Mock_ERC20("DAI", 18);
        redeemOnly = new Mock_ERC20("USDT", 6);
        nav.registerAsset(address(baseAsset), 6, ONE_USD_PRICE, 8);
        nav.registerAsset(address(depositOnly), 18, ONE_USD_PRICE, 8);
        nav.registerAsset(address(redeemOnly), 6, ONE_USD_PRICE, 8);

        navFactory = new KpkSharesNavFactory(address(live), address(mastercopy));
    }

    // ── Fixtures ────────────────────────────────────────────────────────────────

    function _config() internal view returns (KpkSharesNavFactory.NavFundConfig memory c) {
        address[] memory owners = new address[](1);
        owners[0] = managerSigner;
        c.managerSafe = KpkOivFactory.SafeConfig({owners: owners, threshold: 1});
        c.salt = 42;
        c.admin = admin;
        c.sharesParams = KpkSharesNav.ConstructorParams({
            asset: address(baseAsset),
            admin: address(0),
            name: "kpk NAV",
            symbol: "kpkNAV",
            safe: address(0),
            subscriptionRequestTtl: 1 days,
            redemptionRequestTtl: 1 days,
            feeReceiver: feeRecipient,
            managementFeeRate: 100,
            redemptionFeeRate: 0,
            performanceFeeModule: address(0),
            performanceFeeRate: 0,
            navCalculator: address(nav),
            initialSharePrice: ONE_USD
        });
        c.additionalAssets = new KpkOivFactory.AssetConfig[](2);
        c.additionalAssets[0] =
            KpkOivFactory.AssetConfig({asset: address(depositOnly), canDeposit: true, canRedeem: false});
        c.additionalAssets[1] =
            KpkOivFactory.AssetConfig({asset: address(redeemOnly), canDeposit: false, canRedeem: true});
    }

    function _timelockedConfig() internal view returns (KpkSharesNavFactory.NavFundConfig memory c) {
        c = _config();
        c.execTimelock = _timelockParams(1 days);
        c.sharesTimelock = _timelockParams(2 days);
    }

    function _timelockParams(uint256 minDelay) internal view returns (TimelockParams memory p) {
        // The timelock deployer requires strictly ascending role arrays.
        p = TimelockParams({
            minDelay: minDelay,
            proposers: _sortedPair(govSafe, superadminSafe),
            cancellers: _sortedPair(managerVeto, lpVeto)
        });
    }

    function _sortedPair(address a, address b) internal pure returns (address[] memory out) {
        out = new address[](2);
        (out[0], out[1]) = a < b ? (a, b) : (b, a);
    }

    function _assertSame(
        KpkSharesNavFactory.NavFundInstance memory a,
        KpkSharesNavFactory.NavFundInstance memory b,
        string memory ctx
    ) internal pure {
        assertEq(a.avatarSafe, b.avatarSafe, string.concat(ctx, ": avatarSafe"));
        assertEq(a.managerSafe, b.managerSafe, string.concat(ctx, ": managerSafe"));
        assertEq(a.execRolesModifier, b.execRolesModifier, string.concat(ctx, ": execRolesModifier"));
        assertEq(a.subRolesModifier, b.subRolesModifier, string.concat(ctx, ": subRolesModifier"));
        assertEq(a.managerRolesModifier, b.managerRolesModifier, string.concat(ctx, ": managerRolesModifier"));
        assertEq(a.kpkSharesNavImpl, b.kpkSharesNavImpl, string.concat(ctx, ": kpkSharesNavImpl"));
        assertEq(a.kpkSharesNavProxy, b.kpkSharesNavProxy, string.concat(ctx, ": kpkSharesNavProxy"));
        assertEq(a.execTimelock, b.execTimelock, string.concat(ctx, ": execTimelock"));
        assertEq(a.sharesTimelock, b.sharesTimelock, string.concat(ctx, ": sharesTimelock"));
    }

    function _assertMoved(
        KpkSharesNavFactory.NavFundInstance memory a,
        KpkSharesNavFactory.NavFundInstance memory b,
        string memory ctx
    ) internal pure {
        assertTrue(a.kpkSharesNavProxy != b.kpkSharesNavProxy, string.concat(ctx, ": proxy did not move"));
        assertTrue(a.avatarSafe != b.avatarSafe, string.concat(ctx, ": avatar did not move"));
    }

    // ── 1. Predict/deploy parity ────────────────────────────────────────────────

    function test_deployMatchesPrediction_noTimelocks() public {
        KpkSharesNavFactory.NavFundConfig memory c = _config();
        KpkSharesNavFactory.NavFundInstance memory predicted = navFactory.predictNavFund(c, address(this));
        KpkSharesNavFactory.NavFundInstance memory deployed = navFactory.deployNavFund(c);

        _assertSame(predicted, deployed, "no timelocks");
        assertEq(deployed.execTimelock, address(0), "exec timelock must be unset");
        assertEq(deployed.sharesTimelock, address(0), "shares timelock must be unset");
        assertEq(deployed.kpkSharesNavImpl, address(mastercopy), "impl must be the mastercopy");
        assertGt(deployed.kpkSharesNavProxy.code.length, 0, "proxy has no code");
        assertEq(navFactory.navFundCount(), 1, "navFundCount");
        (,,,,,, address recordedProxy,,) = navFactory.navFunds(0);
        assertEq(recordedProxy, deployed.kpkSharesNavProxy, "navFunds[0] not recorded");
    }

    function test_deployMatchesPrediction_withTimelocks() public {
        KpkSharesNavFactory.NavFundConfig memory c = _timelockedConfig();
        KpkSharesNavFactory.NavFundInstance memory predicted = navFactory.predictNavFund(c, address(this));
        KpkSharesNavFactory.NavFundInstance memory deployed = navFactory.deployNavFund(c);

        _assertSame(predicted, deployed, "with timelocks");
        assertGt(deployed.execTimelock.code.length, 0, "exec timelock not deployed");
        assertGt(deployed.sharesTimelock.code.length, 0, "shares timelock not deployed");
    }

    // ── 2. Role handover ────────────────────────────────────────────────────────

    function test_roleHandover_noTimelock() public {
        KpkSharesNavFactory.NavFundInstance memory inst = navFactory.deployNavFund(_config());
        KpkSharesNav fund = KpkSharesNav(inst.kpkSharesNavProxy);

        assertTrue(fund.hasRole(DEFAULT_ADMIN_ROLE, admin), "admin must hold DEFAULT_ADMIN_ROLE");
        assertFalse(fund.hasRole(DEFAULT_ADMIN_ROLE, address(navFactory)), "factory kept DEFAULT_ADMIN_ROLE");
        assertFalse(fund.hasRole(OPERATOR, address(navFactory)), "factory kept OPERATOR");
        assertTrue(fund.hasRole(OPERATOR, inst.managerSafe), "managerSafe must hold OPERATOR");
        assertEq(IRoles(inst.execRolesModifier).owner(), admin, "exec modifier owner must be admin");
    }

    function test_roleHandover_withTimelocks() public {
        KpkSharesNavFactory.NavFundInstance memory inst = navFactory.deployNavFund(_timelockedConfig());
        KpkSharesNav fund = KpkSharesNav(inst.kpkSharesNavProxy);

        assertTrue(fund.hasRole(DEFAULT_ADMIN_ROLE, inst.sharesTimelock), "shares timelock must hold admin");
        assertFalse(fund.hasRole(DEFAULT_ADMIN_ROLE, admin), "admin must NOT hold admin beside the timelock");
        assertFalse(fund.hasRole(DEFAULT_ADMIN_ROLE, address(navFactory)), "factory kept DEFAULT_ADMIN_ROLE");
        assertFalse(fund.hasRole(OPERATOR, address(navFactory)), "factory kept OPERATOR");
        assertTrue(fund.hasRole(OPERATOR, inst.managerSafe), "managerSafe must hold OPERATOR");
        assertEq(IRoles(inst.execRolesModifier).owner(), inst.execTimelock, "exec modifier owner must be exec timelock");
    }

    // ── 3. Fund wiring ──────────────────────────────────────────────────────────

    function test_fundWiring() public {
        KpkSharesNavFactory.NavFundInstance memory inst = navFactory.deployNavFund(_config());
        KpkSharesNav fund = KpkSharesNav(inst.kpkSharesNavProxy);

        assertEq(fund.portfolioSafe(), inst.avatarSafe, "portfolioSafe must be the Avatar Safe");
        assertEq(fund.navCalculator(), address(nav), "navCalculator");
        assertEq(fund.getApprovedAssets().length, 3, "base + two additional assets");

        assertTrue(fund.getApprovedAsset(address(baseAsset)).canDeposit, "base canDeposit");
        assertTrue(fund.getApprovedAsset(address(baseAsset)).canRedeem, "base canRedeem");
        assertEq(fund.getApprovedAsset(address(depositOnly)).asset, address(depositOnly), "depositOnly listed");
        assertTrue(fund.getApprovedAsset(address(depositOnly)).canDeposit, "depositOnly canDeposit");
        assertFalse(fund.getApprovedAsset(address(depositOnly)).canRedeem, "depositOnly canRedeem");
        assertEq(fund.getApprovedAsset(address(redeemOnly)).asset, address(redeemOnly), "redeemOnly listed");
        assertFalse(fund.getApprovedAsset(address(redeemOnly)).canDeposit, "redeemOnly canDeposit");
        assertTrue(fund.getApprovedAsset(address(redeemOnly)).canRedeem, "redeemOnly canRedeem");
    }

    // ── 4. Validation, in deploy AND predict ────────────────────────────────────

    function _expectBothRevert(KpkSharesNavFactory.NavFundConfig memory c, bytes4 selector) internal {
        vm.expectRevert(selector);
        navFactory.deployNavFund(c);
        vm.expectRevert(selector);
        navFactory.predictNavFund(c, address(this));
    }

    function test_validation_zeroAdmin() public {
        KpkSharesNavFactory.NavFundConfig memory c = _config();
        c.admin = address(0);
        // The live factory also rejects a zero `finalOwner` with an identically named error, so the
        // selector alone cannot tell which contract refused. Requiring that the live factory is never
        // reached does.
        vm.expectCall(address(live), abi.encodeWithSelector(KpkOivFactory.deployStack.selector), 0);
        vm.expectCall(address(live), abi.encodeWithSelector(KpkOivFactory.predictStackAddresses.selector), 0);
        _expectBothRevert(c, KpkSharesNavFactory.ZeroAddress.selector);
    }

    function test_validation_adminIsNavFactory() public {
        KpkSharesNavFactory.NavFundConfig memory c = _config();
        c.admin = address(navFactory);
        _expectBothRevert(c, KpkSharesNavFactory.ZeroAddress.selector);
    }

    function test_validation_additionalAssetIsBaseAsset() public {
        KpkSharesNavFactory.NavFundConfig memory c = _config();
        c.additionalAssets[1].asset = address(baseAsset);
        _expectBothRevert(c, KpkSharesNavFactory.DuplicateAsset.selector);
    }

    function test_validation_duplicatedAdditionalAsset() public {
        KpkSharesNavFactory.NavFundConfig memory c = _config();
        c.additionalAssets[1].asset = address(depositOnly);
        _expectBothRevert(c, KpkSharesNavFactory.DuplicateAsset.selector);
    }

    // ── 5. Salt binding ─────────────────────────────────────────────────────────

    function test_saltBinding_readFieldsMoveAddresses() public {
        KpkSharesNavFactory.NavFundConfig memory c = _config();
        KpkSharesNavFactory.NavFundInstance memory ref = navFactory.predictNavFund(c, address(this));

        c.sharesParams.feeReceiver = makeAddr("otherFeeReceiver");
        _assertMoved(ref, navFactory.predictNavFund(c, address(this)), "feeReceiver");

        c = _config();
        c.sharesParams.navCalculator = address(new MockNavCalculator());
        _assertMoved(ref, navFactory.predictNavFund(c, address(this)), "navCalculator");

        c = _config();
        c.admin = makeAddr("otherAdmin");
        _assertMoved(ref, navFactory.predictNavFund(c, address(this)), "admin");
    }

    function test_saltBinding_unreadFieldsMoveNothing() public {
        KpkSharesNavFactory.NavFundConfig memory c = _config();
        KpkSharesNavFactory.NavFundInstance memory ref = navFactory.predictNavFund(c, address(this));

        c.sharesParams.admin = makeAddr("ignoredAdmin");
        _assertSame(ref, navFactory.predictNavFund(c, address(this)), "sharesParams.admin");

        c = _config();
        c.sharesParams.safe = makeAddr("ignoredSafe");
        _assertSame(ref, navFactory.predictNavFund(c, address(this)), "sharesParams.safe");

        // Role arrays under a zero delay: no timelock is deployed, so they are never read.
        c = _config();
        c.execTimelock = _timelockParams(0);
        _assertSame(ref, navFactory.predictNavFund(c, address(this)), "execTimelock arrays at zero delay");

        c = _config();
        c.sharesTimelock = _timelockParams(0);
        _assertSame(ref, navFactory.predictNavFund(c, address(this)), "sharesTimelock arrays at zero delay");

        // The deployed fund agrees with the reference prediction.
        _assertSame(ref, navFactory.deployNavFund(c), "deploy with ignored fields");
    }

    // ── 6. Caller isolation ─────────────────────────────────────────────────────

    function test_callerIsolation_disjointAddressesAndReplayReverts() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        KpkSharesNavFactory.NavFundConfig memory c = _config();

        KpkSharesNavFactory.NavFundInstance memory pa = navFactory.predictNavFund(c, alice);
        KpkSharesNavFactory.NavFundInstance memory pb = navFactory.predictNavFund(c, bob);
        assertTrue(pa.avatarSafe != pb.avatarSafe, "avatarSafe shared across callers");
        assertTrue(pa.managerSafe != pb.managerSafe, "managerSafe shared across callers");
        assertTrue(pa.execRolesModifier != pb.execRolesModifier, "execRolesModifier shared across callers");
        assertTrue(pa.subRolesModifier != pb.subRolesModifier, "subRolesModifier shared across callers");
        assertTrue(pa.managerRolesModifier != pb.managerRolesModifier, "managerRolesModifier shared across callers");
        assertTrue(pa.kpkSharesNavProxy != pb.kpkSharesNavProxy, "proxy shared across callers");

        vm.prank(alice);
        _assertSame(pa, navFactory.deployNavFund(c), "alice");
        vm.prank(bob);
        _assertSame(pb, navFactory.deployNavFund(c), "bob");

        vm.expectRevert(KpkOivFactory.StackAlreadyDeployedHere.selector);
        vm.prank(alice);
        navFactory.deployNavFund(c);
    }

    // ── 7. Approvals ────────────────────────────────────────────────────────────

    function test_approvals_startAtZeroAndAdminGrantsThroughExecModifier() public {
        KpkSharesNavFactory.NavFundInstance memory inst = navFactory.deployNavFund(_config());
        address proxy = inst.kpkSharesNavProxy;
        assertEq(baseAsset.allowance(inst.avatarSafe, proxy), 0, "deploy must not grant an allowance");

        bytes32 roleKey = keccak256("APPROVER");
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = roleKey;
        bool[] memory memberOf = new bool[](1);
        memberOf[0] = true;

        vm.startPrank(admin);
        IRoles(inst.execRolesModifier).assignRoles(admin, keys, memberOf);
        IRoles(inst.execRolesModifier).scopeTarget(roleKey, address(baseAsset));
        IRoles(inst.execRolesModifier).allowFunction(roleKey, address(baseAsset), IERC20.approve.selector, 0);
        bool ok = IRoles(inst.execRolesModifier)
            .execTransactionWithRole(
                address(baseAsset), 0, abi.encodeCall(IERC20.approve, (proxy, type(uint256).max)), 0, roleKey, true
            );
        vm.stopPrank();

        assertTrue(ok, "approve through the exec modifier failed");
        assertEq(baseAsset.allowance(inst.avatarSafe, proxy), type(uint256).max, "allowance must be max");
    }

    // ── 8. Constructor ──────────────────────────────────────────────────────────

    function test_constructor_rejectsZeroFactory() public {
        vm.expectRevert(KpkSharesNavFactory.ZeroAddress.selector);
        new KpkSharesNavFactory(address(0), address(mastercopy));
    }

    function test_constructor_rejectsZeroMastercopy() public {
        vm.expectRevert(KpkSharesNavFactory.ZeroAddress.selector);
        new KpkSharesNavFactory(address(live), address(0));
    }

    function test_constructor_rejectsCodelessFactory() public {
        vm.expectRevert(KpkSharesNavFactory.InvalidMastercopy.selector);
        new KpkSharesNavFactory(makeAddr("codelessFactory"), address(mastercopy));
    }

    function test_constructor_rejectsCodelessMastercopy() public {
        vm.expectRevert(KpkSharesNavFactory.InvalidMastercopy.selector);
        new KpkSharesNavFactory(address(live), makeAddr("codelessMastercopy"));
    }

    function test_constructor_readsTimelockDeployerFromFactory() public view {
        assertEq(navFactory.timelockDeployer(), live.timelockDeployer(), "timelockDeployer");
        assertEq(address(navFactory.factory()), address(live), "factory");
        assertEq(navFactory.kpkSharesNavMastercopy(), address(mastercopy), "mastercopy");
    }
}

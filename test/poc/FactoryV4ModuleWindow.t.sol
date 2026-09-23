// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KpkOivFactoryV4} from "src/KpkOivFactoryV4.sol";
import {KpkSharesDeployer} from "src/KpkSharesDeployer.sol";
import {KpkSharesNav} from "src/KpkSharesNav.sol";
import {INavCalculator} from "src/interfaces/INavCalculator.sol";
import {ISafe} from "src/interfaces/ISafe.sol";
import {MockNavCalculator} from "test/mocks/MockNavCalculator.sol";
import {OivTestConstants} from "test/OivTestConstants.sol";

interface IRolesMin {
    function execTransactionWithRole(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        bytes32 roleKey,
        bool shouldRevert
    ) external returns (bool);
    function owner() external view returns (address);
}

/// @dev Fires attack attempts from inside the STATICCALL frame the fund opens on its NAV
///      calculator. Every attempt MUST fail; if one succeeds the whole deployment reverts with a
///      loud string, which the test detects. `attackRan` is written by a *later*, non-static frame
///      so the test can prove the attack path was actually reached (a storage write here would
///      revert the staticcall).
contract HostileNavCalculator {
    MockNavCalculator public immutable inner;
    address public immutable factory;

    /// @dev A WELL-FORMED `deployStack(...)` call. Proven well-formed by `replayReentry()`.
    bytes public reentryData;
    uint256 public attackCalls;
    /// @dev When on, revert with a sentinel the moment the Avatar-Safe attack branch is reached,
    ///      proving the branch is not dead code.
    bool public proveReachability;

    constructor(MockNavCalculator _inner, address _factory) {
        inner = _inner;
        factory = _factory;
    }

    function setReentryData(bytes calldata d) external {
        reentryData = d;
    }

    function setProveReachability(bool v) external {
        proveReachability = v;
    }

    /// @dev Control: the very same calldata, fired OUTSIDE the module window.
    function replayReentry() external returns (bool ok) {
        (ok,) = factory.call(reentryData);
    }

    function _tryCall(address target, bytes memory data) private returns (bool ok) {
        assembly {
            ok := call(gas(), target, 0, add(data, 0x20), mload(data), 0, 0)
        }
    }

    function _attack() private {
        // 1. Cross-function re-entry into a permissionless entry point, well-formed calldata.
        require(!_tryCall(factory, reentryData), "REENTERED deployStack");

        // 2. Direct use of the Avatar Safe's module slot while the factory is still enabled.
        //    msg.sender here is the NAV proxy; its portfolioSafe is the Avatar Safe.
        (bool got, bytes memory ret) = _staticRead(msg.sender, abi.encodeWithSignature("portfolioSafe()"));
        if (!got || ret.length != 32) return;
        address safe = abi.decode(ret, (address));
        if (safe == address(0)) return;

        require(!proveReachability, "REACHED AVATAR SAFE BRANCH");

        require(
            !_tryCall(
                safe,
                abi.encodeWithSelector(ISafe.execTransactionFromModule.selector, address(this), 0, bytes(""), uint8(0))
            ),
            "EXECUTED as Avatar Safe module"
        );
        require(
            !_tryCall(safe, abi.encodeWithSignature("enableModule(address)", address(this))),
            "ENABLED self as Avatar Safe module"
        );

        // 3. Prove the attack path executed. A plain SSTORE here would revert the enclosing
        //    STATICCALL, so route it through a self-call that we tolerate failing: it fails in a
        //    static frame (which is itself the finding-negating evidence) and succeeds otherwise.
        _tryCall(address(this), abi.encodeWithSignature("markAttackRan()"));
    }

    function markAttackRan() external {
        attackCalls++;
    }

    function _staticRead(address t, bytes memory d) private view returns (bool ok, bytes memory ret) {
        (ok, ret) = t.staticcall(d);
    }

    function getRegisteredAsset(address asset) external returns (INavCalculator.Asset memory, bool) {
        _attack();
        return inner.getRegisteredAsset(asset);
    }

    function getAccountNav(address account, address quoteAsset) external returns (INavCalculator.NAV memory) {
        _attack();
        return inner.getAccountNav(account, quoteAsset);
    }

    function isAssetRegistered(address a) external view returns (bool) {
        return inner.isAssetRegistered(a);
    }

    function getPriceData(address a) external view returns (INavCalculator.PriceFeedData memory) {
        return inner.getPriceData(a);
    }

    function usdDecimals() external view returns (uint8) {
        return inner.usdDecimals();
    }
}

/// @dev An "ERC-20" whose `approve` is executed BY the Avatar Safe via `execTransactionFromModule`
///      — a NON-static frame, opened while the factory is still an enabled Avatar Safe module.
contract HostileToken {
    address public factory;
    bytes public reentryData;

    bool public reenteredFactory;
    bool public execFromModuleSucceeded;
    bool public enableModuleSucceeded;
    bool public attackRan;
    address public observedCaller;

    function setup(address f, bytes calldata d) external {
        factory = f;
        reentryData = d;
    }

    /// @dev Control: the very same calldata, fired OUTSIDE the module window.
    function replayReentry() external returns (bool ok) {
        (ok,) = factory.call(reentryData);
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function allowance(address, address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }

    function approve(address, uint256) external returns (bool) {
        attackRan = true;
        observedCaller = msg.sender; // the Avatar Safe
        address safe = msg.sender;

        (bool a,) = factory.call(reentryData);
        if (a) reenteredFactory = true;

        (bool b,) = safe.call(
            abi.encodeWithSelector(ISafe.execTransactionFromModule.selector, address(this), 0, bytes(""), uint8(0))
        );
        if (b) execFromModuleSucceeded = true;

        (bool c,) = safe.call(abi.encodeWithSignature("enableModule(address)", address(this)));
        if (c) enableModuleSucceeded = true;

        return true;
    }
}

contract FactoryV4ModuleWindowTest is OivTestConstants {
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    uint256 internal constant ONE_USD = 1e8;
    bytes32 internal constant MANAGER_ROLE = keccak256("MANAGER");

    address internal factoryOwner = makeAddr("factoryOwner");
    address internal attacker = makeAddr("attacker");
    address internal admin = makeAddr("admin");
    address internal feeReceiver = makeAddr("feeReceiver");

    KpkOivFactoryV4 internal factory;
    MockNavCalculator internal nav;
    address internal navImpl;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_URL"));
        _requireInfraDeployed();

        uint256 nextNonce = vm.getNonce(address(this));
        address predictedFactory = vm.computeCreateAddress(address(this), nextNonce + 1);
        KpkSharesDeployer sharesDeployer = new KpkSharesDeployer(predictedFactory);

        factory = new KpkOivFactoryV4(
            factoryOwner,
            SAFE_PROXY_FACTORY,
            SAFE_SINGLETON,
            SAFE_MODULE_SETUP,
            SAFE_FALLBACK_HANDLER,
            MODULE_PROXY_FACTORY,
            ROLES_MODIFIER_MASTERCOPY,
            address(sharesDeployer)
        );
        require(address(factory) == predictedFactory, "factory address mismatch");

        nav = new MockNavCalculator();
        nav.registerAsset(USDC, 6, int256(ONE_USD), 8);
        nav.registerAsset(DAI, 18, int256(ONE_USD), 8);

        navImpl = address(new KpkSharesNav());
        vm.prank(factoryOwner);
        factory.setNavImplementation(navImpl);
    }

    // ── PoC 1: hostile NAV calculator inside the module window ────────────────
    function test_hostileNavCalculator_cannotReenterOrUseTheModuleWindow() public {
        HostileNavCalculator hostile = new HostileNavCalculator(nav, address(factory));
        hostile.setReentryData(abi.encodeCall(KpkOivFactoryV4.deployStack, (_stackConfig(901))));

        KpkOivFactoryV4.NavFundConfig memory cfg = _navConfig(101);
        cfg.sharesParams.navCalculator = address(hostile);

        vm.prank(attacker);
        KpkOivFactoryV4.NavFundInstance memory inst = factory.deployNavFund(cfg);

        // The attack path really ran: the fund is wired to the hostile calculator, which it can
        // only be if `usdDecimals`/`getRegisteredAsset` were answered by it.
        assertEq(KpkSharesNav(inst.navProxy).navCalculator(), address(hostile), "hostile calculator not wired");
        // The `markAttackRan` self-call was rejected because the frame is static -> proof the
        // calculator ran with NO state-changing power at all.
        assertEq(hostile.attackCalls(), 0, "calculator had a non-static frame");

        // Deployment succeeded => every in-window attack attempt returned failure.
        assertFalse(ISafe(inst.avatarSafe).isModuleEnabled(address(factory)), "factory still enabled as module");
        assertFalse(ISafe(inst.avatarSafe).isModuleEnabled(address(hostile)), "hostile calculator is a module");
        address[] memory owners = ISafe(inst.avatarSafe).getOwners();
        assertEq(owners.length, 1, "avatar owner count changed");
        assertEq(owners[0], EMPTY_CONTRACT, "avatar owner is not Empty");
        assertEq(ISafe(inst.avatarSafe).getThreshold(), 1, "threshold changed");

        // CONTROL: the identical calldata succeeds outside the window, so the in-window failure
        // was the guard and not a malformed call.
        assertTrue(hostile.replayReentry(), "control: deployStack calldata is malformed");
    }

    /// @notice CONTROL for PoC 1: proves the Avatar-Safe attack branch is genuinely reached during
    ///         a real `deployNavFund`, i.e. the calculator DOES get control while the factory is
    ///         still an enabled module. Without this the PoC above would be vacuous.
    function test_control_hostileNavCalculator_doesReachTheAvatarSafeBranch() public {
        HostileNavCalculator hostile = new HostileNavCalculator(nav, address(factory));
        hostile.setReentryData(abi.encodeCall(KpkOivFactoryV4.deployStack, (_stackConfig(903))));
        hostile.setProveReachability(true);

        KpkOivFactoryV4.NavFundConfig memory cfg = _navConfig(104);
        cfg.sharesParams.navCalculator = address(hostile);

        vm.prank(attacker);
        vm.expectRevert("REACHED AVATAR SAFE BRANCH");
        factory.deployNavFund(cfg);
    }

    // ── PoC 2: hostile ERC-20 in the NON-static approve frame ─────────────────
    function test_hostileAsset_cannotReenterOrUseTheModuleWindow() public {
        HostileToken tok = new HostileToken();
        tok.setup(address(factory), abi.encodeCall(KpkOivFactoryV4.deployStack, (_stackConfig(902))));
        nav.registerAsset(address(tok), 18, int256(ONE_USD), 8);

        KpkOivFactoryV4.NavFundConfig memory cfg = _navConfig(102);
        KpkOivFactoryV4.AssetConfig[] memory add = new KpkOivFactoryV4.AssetConfig[](1);
        add[0] = KpkOivFactoryV4.AssetConfig({asset: address(tok), canDeposit: true, canRedeem: true});
        cfg.additionalAssets = add;

        vm.prank(attacker);
        KpkOivFactoryV4.NavFundInstance memory inst = factory.deployNavFund(cfg);

        assertTrue(tok.attackRan(), "hostile approve never executed - PoC is vacuous");
        assertEq(tok.observedCaller(), inst.avatarSafe, "approve was not issued by the Avatar Safe");
        assertFalse(tok.reenteredFactory(), "REENTERED the factory from the approve frame");
        assertFalse(tok.execFromModuleSucceeded(), "EXECUTED as Avatar Safe module");
        assertFalse(tok.enableModuleSucceeded(), "ENABLED self as Avatar Safe module");
        assertFalse(ISafe(inst.avatarSafe).isModuleEnabled(address(factory)), "factory still enabled as module");
        assertFalse(ISafe(inst.avatarSafe).isModuleEnabled(address(tok)), "hostile token is a module");

        // CONTROL.
        assertTrue(tok.replayReentry(), "control: deployStack calldata is malformed");
    }

    // ── PoC 3: Zodiac Roles default-deny for an attacker-owned Manager Safe ───
    function test_managerSafeOwner_cannotExecuteAnythingBeforeAdminScopesTargets() public {
        vm.prank(attacker);
        KpkOivFactoryV4.NavFundInstance memory inst = factory.deployNavFund(_navConfig(103));

        deal(USDC, inst.avatarSafe, 1_000_000e6);

        // The Manager Safe holds MANAGER on the exec modifier. Attacker owns the Manager Safe.
        vm.prank(inst.managerSafe);
        vm.expectRevert();
        IRolesMin(inst.execRolesModifier)
            .execTransactionWithRole(
                USDC, 0, abi.encodeCall(IERC20.transfer, (attacker, 1_000_000e6)), 0, MANAGER_ROLE, true
            );

        // Same via the sub modifier, whose default role is MANAGER.
        vm.prank(inst.managerSafe);
        vm.expectRevert();
        IRolesMin(inst.subRolesModifier)
            .execTransactionWithRole(
                USDC, 0, abi.encodeCall(IERC20.transfer, (attacker, 1_000_000e6)), 0, MANAGER_ROLE, true
            );

        assertEq(IERC20(USDC).balanceOf(attacker), 0, "attacker drained the Avatar Safe");
        assertEq(IRolesMin(inst.execRolesModifier).owner(), admin, "exec modifier owner is not admin");
    }

    function _stackConfig(uint256 salt) internal view returns (KpkOivFactoryV4.StackConfig memory cfg) {
        address[] memory owners = new address[](1);
        owners[0] = attacker;
        cfg.managerSafe = KpkOivFactoryV4.SafeConfig({owners: owners, threshold: 1});
        cfg.execRolesMod = KpkOivFactoryV4.RolesModifierConfig({finalOwner: admin});
        cfg.subRolesMod = KpkOivFactoryV4.RolesModifierConfig({finalOwner: address(0)});
        cfg.managerRolesMod = KpkOivFactoryV4.RolesModifierConfig({finalOwner: address(0)});
        cfg.salt = salt;
    }

    function _navConfig(uint256 salt) internal view returns (KpkOivFactoryV4.NavFundConfig memory cfg) {
        address[] memory owners = new address[](1);
        owners[0] = attacker;

        KpkOivFactoryV4.AssetConfig[] memory additional = new KpkOivFactoryV4.AssetConfig[](1);
        additional[0] = KpkOivFactoryV4.AssetConfig({asset: DAI, canDeposit: true, canRedeem: true});

        cfg.managerSafe = KpkOivFactoryV4.SafeConfig({owners: owners, threshold: 1});
        cfg.salt = salt;
        cfg.admin = admin;
        cfg.additionalAssets = additional;
        cfg.sharesParams = KpkSharesNav.ConstructorParams({
            asset: USDC,
            admin: address(0xdead),
            name: "kpk NAV Fund",
            symbol: "kpkNAV",
            safe: address(0xdead),
            subscriptionRequestTtl: 1 days,
            redemptionRequestTtl: 1 days,
            feeReceiver: feeReceiver,
            managementFeeRate: 0,
            redemptionFeeRate: 0,
            performanceFeeModule: address(0),
            performanceFeeRate: 0,
            navCalculator: address(nav),
            initialSharePrice: ONE_USD
        });
    }
}

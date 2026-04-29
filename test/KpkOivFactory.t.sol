// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KpkOivFactory} from "src/KpkOivFactory.sol";
import {KpkSharesDeployer} from "src/KpkSharesDeployer.sol";
import {KpkShares} from "src/kpkShares.sol";
import {IkpkShares} from "src/IkpkShares.sol";
import {ISafe} from "src/interfaces/ISafe.sol";
import {IRoles} from "src/interfaces/IRoles.sol";

/// @notice Fork tests for KpkOivFactory against mainnet Safe and Zodiac contracts.
///         Run with: forge test --match-contract KpkOivFactoryTest --fork-url $MAINNET_URL -vvv
contract KpkOivFactoryTest is Test {
    // USDC on mainnet — used as the shares asset in tests.
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Safe v1.4.1
    address constant SAFE_PROXY_FACTORY = 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2;
    address constant SAFE_SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address constant SAFE_MODULE_SETUP = 0x2dd68b007B46fBe91B9A7c3EDa5A7a1063cB5b47;
    address constant SAFE_FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;

    // Zodiac
    address constant MODULE_PROXY_FACTORY = 0x000000000000aDdB49795b0f9bA5BC298cDda236;
    address constant ROLES_MODIFIER_MASTERCOPY = 0x9646fDAD06d3e24444381f44362a3B0eB343D337;

    // ── Test accounts ───────────────────────────────────────────────────────────

    address factoryOwner = makeAddr("factoryOwner");
    address securityCouncil = makeAddr("securityCouncil");
    address managerSigner = makeAddr("managerSigner");
    address admin = makeAddr("admin");
    address feeReceiver = makeAddr("feeReceiver");

    // ── Contracts under test ────────────────────────────────────────────────────

    KpkOivFactory factory;

    KpkOivFactory.OivConfig oivConfig;

    // ── Setup ───────────────────────────────────────────────────────────────────

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_URL"));

        // KpkSharesDeployer is now factory-locked. Pre-compute the factory address so the
        // deployer can be constructed with it: this contract's next nonce produces the
        // deployer, and the one after that produces the factory.
        uint256 nextNonce = vm.getNonce(address(this));
        address predictedFactory = vm.computeCreateAddress(address(this), nextNonce + 1);

        KpkSharesDeployer sharesDeployer = new KpkSharesDeployer(predictedFactory);

        factory = new KpkOivFactory(
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

        oivConfig = _buildOivConfig();
    }

    // ── deployOiv tests ────────────────────────────────────────────────────────

    function test_deployOiv_deploysAllSevenContracts() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertTrue(inst.avatarSafe != address(0), "avatarSafe not deployed");
        assertTrue(inst.managerSafe != address(0), "managerSafe not deployed");
        assertTrue(inst.execRolesModifier != address(0), "execRolesModifier not deployed");
        assertTrue(inst.subRolesModifier != address(0), "subRolesModifier not deployed");
        assertTrue(inst.managerRolesModifier != address(0), "managerRolesModifier not deployed");
        assertTrue(inst.kpkSharesImpl != address(0), "kpkSharesImpl not deployed");
        assertTrue(inst.kpkSharesProxy != address(0), "kpkSharesProxy not deployed");
    }

    function test_avatarSafe_hasExecModifierAsModule() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertTrue(
            ISafe(inst.avatarSafe).isModuleEnabled(inst.execRolesModifier),
            "execRolesModifier not a module of avatarSafe"
        );
    }

    function test_avatarSafe_ownerIsEmptyContract() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        address[] memory owners = ISafe(inst.avatarSafe).getOwners();
        assertEq(owners.length, 1, "avatarSafe should have exactly one owner");
        assertEq(owners[0], factory.EMPTY_CONTRACT(), "avatarSafe owner is not EMPTY_CONTRACT");
    }

    function test_factory_isNotModuleOfAvatarSafeAfterDeploy() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertFalse(
            ISafe(inst.avatarSafe).isModuleEnabled(address(factory)), "factory should not remain a module of avatarSafe"
        );
    }

    function test_managerSafe_hasManagerModifierAsModule() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertTrue(
            ISafe(inst.managerSafe).isModuleEnabled(inst.managerRolesModifier),
            "managerRolesModifier not a module of managerSafe"
        );
    }

    function test_execModifier_avatarIsAvatarSafe() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(IRoles(inst.execRolesModifier).avatar(), inst.avatarSafe, "execMod avatar mismatch");
    }

    function test_execModifier_targetIsAvatarSafe() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(IRoles(inst.execRolesModifier).target(), inst.avatarSafe, "execMod target mismatch");
    }

    function test_subModifier_avatarIsAvatarSafe() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(IRoles(inst.subRolesModifier).avatar(), inst.avatarSafe, "subMod avatar mismatch");
    }

    function test_subModifier_targetIsExecModifier() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(IRoles(inst.subRolesModifier).target(), inst.execRolesModifier, "subMod target mismatch");
    }

    function test_managerModifier_avatarIsManagerSafe() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(IRoles(inst.managerRolesModifier).avatar(), inst.managerSafe, "managerMod avatar mismatch");
    }

    function test_managerModifier_targetIsManagerSafe() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(IRoles(inst.managerRolesModifier).target(), inst.managerSafe, "managerMod target mismatch");
    }

    /// @dev Proves MANAGER role is assigned to managerSafe on execRolesModifier by having
    ///      managerSafe execute a real transaction through it. The Security Council (owner)
    ///      first scopes a target and allows a function for the MANAGER role, then managerSafe
    ///      calls execTransactionWithRole — which succeeds only if managerSafe holds MANAGER.
    function test_execModifier_managerSafeHasManagerRole() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        bytes32 managerRole = bytes32("MANAGER");
        // Scope USDC and allow approve() for the MANAGER role — approving 0 always succeeds.
        bytes4 selector = IERC20.approve.selector;

        vm.startPrank(admin);
        IRoles(inst.execRolesModifier).scopeTarget(managerRole, USDC);
        IRoles(inst.execRolesModifier).allowFunction(managerRole, USDC, selector, 0);
        vm.stopPrank();

        // Manager Safe calls execTransactionWithRole — reverts with NoMembership() if
        // managerSafe does not hold the MANAGER role.
        vm.prank(inst.managerSafe);
        bool success = IRoles(inst.execRolesModifier)
            .execTransactionWithRole(USDC, 0, abi.encodeWithSelector(selector, address(1), 0), 0, managerRole, true);
        assertTrue(success, "managerSafe could not execute with MANAGER role on execRolesModifier");
    }

    function test_execModifier_hasSubModifierAsNestedModule() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertTrue(
            IRoles(inst.execRolesModifier).isModuleEnabled(inst.subRolesModifier),
            "subRolesModifier not enabled in execRolesModifier"
        );
    }

    function test_execModifier_ownerIsAdmin() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(IRoles(inst.execRolesModifier).owner(), admin, "execMod owner is not admin");
    }

    function test_subModifier_ownerIsManagerSafe() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(IRoles(inst.subRolesModifier).owner(), inst.managerSafe, "subMod owner is not managerSafe");
    }

    function test_managerModifier_ownerIsManagerSafe() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(IRoles(inst.managerRolesModifier).owner(), inst.managerSafe, "managerMod owner is not managerSafe");
    }

    function test_sharesProxy_portfolioSafeIsAvatarSafe() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(KpkShares(inst.kpkSharesProxy).portfolioSafe(), inst.avatarSafe, "portfolioSafe mismatch");
    }

    function test_sharesProxy_adminHasDefaultAdminRole() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        KpkShares shares = KpkShares(inst.kpkSharesProxy);
        assertTrue(shares.hasRole(0x00, admin), "admin does not have DEFAULT_ADMIN_ROLE");
    }

    /// @dev The admin arg to deployOiv must be the single source of truth for both
    ///      the exec Roles Modifier owner and DEFAULT_ADMIN_ROLE on the shares proxy.
    function test_deployOiv_adminArgControlsBothExecModOwnerAndSharesAdmin() public {
        address customAdmin = makeAddr("customAdmin");
        KpkOivFactory.OivConfig memory cfg = _buildOivConfig();
        cfg.admin = customAdmin;

        KpkOivFactory.OivInstance memory inst = factory.deployOiv(cfg);

        assertEq(IRoles(inst.execRolesModifier).owner(), customAdmin, "execMod owner must equal admin arg");
        assertTrue(
            KpkShares(inst.kpkSharesProxy).hasRole(0x00, customAdmin), "shares DEFAULT_ADMIN_ROLE must equal admin arg"
        );
        assertEq(
            IRoles(inst.execRolesModifier).owner(),
            customAdmin,
            "execMod owner and shares admin must be the same address"
        );
    }

    function test_sharesProxy_operatorIsManagerSafe() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        KpkShares shares = KpkShares(inst.kpkSharesProxy);
        assertTrue(shares.hasRole(keccak256("OPERATOR"), inst.managerSafe), "managerSafe does not have OPERATOR role");
    }

    function test_sharesProxy_factoryHasNoAdminRole() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        KpkShares shares = KpkShares(inst.kpkSharesProxy);
        assertFalse(shares.hasRole(0x00, address(factory)), "factory still has DEFAULT_ADMIN_ROLE");
    }

    function test_sharesProxy_baseAssetHasInfiniteAllowance() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(
            IERC20(USDC).allowance(inst.avatarSafe, inst.kpkSharesProxy),
            type(uint256).max,
            "base asset allowance is not infinite"
        );
    }

    function test_sharesProxy_cannotReinitialize() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        vm.expectRevert();
        KpkShares(inst.kpkSharesProxy).initialize(oivConfig.sharesParams);
    }

    function test_instanceCount_incrementsOnEachDeploy() public {
        assertEq(factory.instanceCount(), 0);

        factory.deployOiv(oivConfig);
        assertEq(factory.instanceCount(), 1);

        // Deploy a second fund with a different salt to avoid CREATE2 collisions.
        KpkOivFactory.OivConfig memory cfg2 = _buildOivConfig();
        cfg2.salt = 999;

        factory.deployOiv(cfg2);
        assertEq(factory.instanceCount(), 2);
    }

    function test_deployOiv_revertsOnZeroAdmin() public {
        oivConfig.admin = address(0);
        vm.expectRevert(KpkOivFactory.ZeroAddress.selector);
        factory.deployOiv(oivConfig);
    }

    /// @dev Deterministic-CREATE2 deploy pattern: the factory may be constructed with
    ///      `_kpkSharesDeployer == address(0)` so its CREATE2 init-code is independent of the
    ///      (chicken-and-egg) deployer address. Until `setKpkSharesDeployer` wires it,
    ///      `deployOiv` must revert cleanly. `deployStack` is unaffected — it does not touch
    ///      `kpkSharesDeployer`.
    function test_deployOiv_revertsWhenKpkSharesDeployerNotSet() public {
        // Deploy a second factory with kpkSharesDeployer == address(0). No predicted-factory
        // dance needed since we never call `deployOiv` against this factory while wired.
        KpkOivFactory unwired = new KpkOivFactory(
            factoryOwner,
            SAFE_PROXY_FACTORY,
            SAFE_SINGLETON,
            SAFE_MODULE_SETUP,
            SAFE_FALLBACK_HANDLER,
            MODULE_PROXY_FACTORY,
            ROLES_MODIFIER_MASTERCOPY,
            address(0)
        );

        assertEq(unwired.kpkSharesDeployer(), address(0), "expected unwired factory");

        vm.expectRevert(KpkOivFactory.KpkSharesDeployerNotSet.selector);
        unwired.deployOiv(oivConfig);
    }

    /// @dev Companion to the above: once the owner wires the deployer, `deployOiv` works
    ///      without further intervention. Exercises the full deploy-time wiring flow used
    ///      by `script/DeployKpkOivFactory.s.sol`.
    function test_deployOiv_succeedsAfterSetKpkSharesDeployer() public {
        // Pre-compute the unwired factory's address so we can lock the deployer to it before
        // either is deployed (mirrors the on-chain CREATE2 prediction we'll do in the script).
        uint256 nextNonce = vm.getNonce(address(this));
        address predictedUnwired = vm.computeCreateAddress(address(this), nextNonce + 1);

        KpkSharesDeployer freshDeployer = new KpkSharesDeployer(predictedUnwired);

        KpkOivFactory unwired = new KpkOivFactory(
            factoryOwner,
            SAFE_PROXY_FACTORY,
            SAFE_SINGLETON,
            SAFE_MODULE_SETUP,
            SAFE_FALLBACK_HANDLER,
            MODULE_PROXY_FACTORY,
            ROLES_MODIFIER_MASTERCOPY,
            address(0)
        );
        require(address(unwired) == predictedUnwired, "unwired factory address mismatch");

        // Pre-wire reverts.
        vm.expectRevert(KpkOivFactory.KpkSharesDeployerNotSet.selector);
        unwired.deployOiv(oivConfig);

        // Owner wires the deployer.
        vm.prank(factoryOwner);
        unwired.setKpkSharesDeployer(address(freshDeployer));
        assertEq(unwired.kpkSharesDeployer(), address(freshDeployer), "deployer not set");

        // Post-wire succeeds.
        KpkOivFactory.OivInstance memory inst = unwired.deployOiv(oivConfig);
        assertTrue(inst.avatarSafe != address(0), "avatarSafe not deployed post-wire");
    }

    function test_deployOiv_revertsOnEmptyManagerOwners() public {
        oivConfig.managerSafe.owners = new address[](0);
        vm.expectRevert(KpkOivFactory.EmptyOwners.selector);
        factory.deployOiv(oivConfig);
    }

    function test_deployOiv_revertsOnInvalidThreshold() public {
        oivConfig.managerSafe.threshold = 5; // more than 1 owner
        vm.expectRevert(KpkOivFactory.InvalidThreshold.selector);
        factory.deployOiv(oivConfig);
    }

    function test_deployOiv_revertsIfApproveModuleCallFails() public {
        // Make USDC.approve revert so that the Avatar Safe's execTransactionFromModule
        // returns false when the factory tries to grant the shares proxy its allowance.
        vm.mockCallRevert(USDC, abi.encodeWithSelector(IERC20.approve.selector), "");
        vm.expectRevert("KpkOivFactory: approve module call failed");
        factory.deployOiv(oivConfig);
    }

    /// @dev L-05: zero owner is rejected at the factory level (descriptive error) instead of
    ///      surfacing as an opaque GS203 from deep inside Safe `setup()`.
    function test_deployOiv_revertsOnZeroOwner() public {
        oivConfig.managerSafe.owners = new address[](2);
        oivConfig.managerSafe.owners[0] = managerSigner;
        oivConfig.managerSafe.owners[1] = address(0);
        oivConfig.managerSafe.threshold = 1;
        vm.expectRevert(KpkOivFactory.ZeroAddress.selector);
        factory.deployOiv(oivConfig);
    }

    /// @dev L-05: duplicate owner is rejected at the factory level (descriptive error) instead
    ///      of surfacing as an opaque GS204 from deep inside Safe `setup()`.
    function test_deployOiv_revertsOnDuplicateOwner() public {
        oivConfig.managerSafe.owners = new address[](2);
        oivConfig.managerSafe.owners[0] = managerSigner;
        oivConfig.managerSafe.owners[1] = managerSigner;
        oivConfig.managerSafe.threshold = 1;
        vm.expectRevert(KpkOivFactory.DuplicateOwner.selector);
        factory.deployOiv(oivConfig);
    }

    /// @dev M-06 / L-03: `additionalAssets` cannot include the base deposit asset, otherwise
    ///      the second `updateAsset` call would clear `isFeeModuleAsset`, silently disabling
    ///      performance fees.
    function test_deployOiv_revertsWhenAdditionalAssetEqualsBaseAsset() public {
        oivConfig.additionalAssets = new KpkOivFactory.AssetConfig[](1);
        oivConfig.additionalAssets[0] = KpkOivFactory.AssetConfig({asset: USDC, canDeposit: true, canRedeem: true});
        vm.expectRevert(KpkOivFactory.DuplicateAsset.selector);
        factory.deployOiv(oivConfig);
    }

    /// @dev M-06: duplicate `additionalAssets` entries are rejected — without this guard a
    ///      duplicate with `canRedeem=true` would cause a second `approve(MAX)` call which
    ///      reverts on USDT-like tokens, DoS'ing the entire deployment.
    function test_deployOiv_revertsOnDuplicateAdditionalAsset() public {
        address dummy = makeAddr("dummyToken");
        oivConfig.additionalAssets = new KpkOivFactory.AssetConfig[](2);
        oivConfig.additionalAssets[0] = KpkOivFactory.AssetConfig({asset: dummy, canDeposit: true, canRedeem: false});
        oivConfig.additionalAssets[1] = KpkOivFactory.AssetConfig({asset: dummy, canDeposit: false, canRedeem: true});
        vm.expectRevert(KpkOivFactory.DuplicateAsset.selector);
        factory.deployOiv(oivConfig);
    }

    /// @dev L-06: `feeReceiver` is validated at the factory level so misconfiguration fails
    ///      fast instead of surfacing as a deep KpkShares initializer revert.
    function test_deployOiv_revertsOnZeroFeeReceiver() public {
        oivConfig.sharesParams.feeReceiver = address(0);
        vm.expectRevert(KpkOivFactory.InvalidSharesParams.selector);
        factory.deployOiv(oivConfig);
    }

    /// @dev L-06: TTLs are validated at the factory level for the same reason.
    function test_deployOiv_revertsOnZeroSubscriptionTtl() public {
        oivConfig.sharesParams.subscriptionRequestTtl = 0;
        vm.expectRevert(KpkOivFactory.InvalidSharesParams.selector);
        factory.deployOiv(oivConfig);
    }

    function test_deployOiv_revertsOnZeroRedemptionTtl() public {
        oivConfig.sharesParams.redemptionRequestTtl = 0;
        vm.expectRevert(KpkOivFactory.InvalidSharesParams.selector);
        factory.deployOiv(oivConfig);
    }

    // ── Address prediction tests ──────────────────────────────────────────────

    /// @dev `predictStackAddresses` must exactly match the addresses returned by `deployStack`.
    function test_predictStackAddresses_matchesActualDeployment() public {
        KpkOivFactory.StackConfig memory cfg = _buildStackConfig();

        KpkOivFactory.StackInstance memory predicted = factory.predictStackAddresses(cfg, address(this));
        KpkOivFactory.StackInstance memory actual = factory.deployStack(cfg);

        assertEq(predicted.avatarSafe, actual.avatarSafe, "avatarSafe prediction mismatch");
        assertEq(predicted.managerSafe, actual.managerSafe, "managerSafe prediction mismatch");
        assertEq(predicted.execRolesModifier, actual.execRolesModifier, "execMod prediction mismatch");
        assertEq(predicted.subRolesModifier, actual.subRolesModifier, "subMod prediction mismatch");
        assertEq(predicted.managerRolesModifier, actual.managerRolesModifier, "managerMod prediction mismatch");
    }

    /// @dev `predictOivAddresses` must match `deployOiv` for ALL seven contracts. Since the
    ///      KpkShares implementation and ERC-1967 proxy now use CREATE2 (with salts derived from
    ///      `(caller, baseSalt, 5)` and `(caller, baseSalt, 6)`), they are deterministic and the
    ///      prediction must agree byte-for-byte with the actual deployment.
    function test_predictOivAddresses_matchesActualDeployment() public {
        KpkOivFactory.OivInstance memory predicted = factory.predictOivAddresses(oivConfig, address(this));
        KpkOivFactory.OivInstance memory actual = factory.deployOiv(oivConfig);

        assertEq(predicted.avatarSafe, actual.avatarSafe, "avatarSafe prediction mismatch");
        assertEq(predicted.managerSafe, actual.managerSafe, "managerSafe prediction mismatch");
        assertEq(predicted.execRolesModifier, actual.execRolesModifier, "execMod prediction mismatch");
        assertEq(predicted.subRolesModifier, actual.subRolesModifier, "subMod prediction mismatch");
        assertEq(predicted.managerRolesModifier, actual.managerRolesModifier, "managerMod prediction mismatch");
        assertEq(predicted.kpkSharesImpl, actual.kpkSharesImpl, "kpkSharesImpl prediction mismatch");
        assertEq(predicted.kpkSharesProxy, actual.kpkSharesProxy, "kpkSharesProxy prediction mismatch");
        assertTrue(predicted.kpkSharesImpl != address(0), "kpkSharesImpl should be predicted non-zero");
        assertTrue(predicted.kpkSharesProxy != address(0), "kpkSharesProxy should be predicted non-zero");
    }

    /// @dev Cross-flow address invariant: `predictStackAddresses` and `predictOivAddresses` MUST
    ///      produce identical operational-stack addresses for the same `(salt, caller)`. This
    ///      is the entire point of the multichain design — `deployOiv` on mainnet must yield
    ///      the same Avatar Safe address as `deployStack` on every sidechain. Both flows now
    ///      include the factory as a setup-time Avatar Safe module so the setup() initializer
    ///      is byte-identical.
    function test_predict_addressesMatchBetweenStackAndOiv() public {
        KpkOivFactory.StackConfig memory stackCfg = _buildStackConfig();
        // Use the same salt for both predictions to assert cross-flow address agreement.
        stackCfg.salt = oivConfig.salt;

        KpkOivFactory.StackInstance memory stackPred = factory.predictStackAddresses(stackCfg, address(this));
        KpkOivFactory.OivInstance memory oivPred = factory.predictOivAddresses(oivConfig, address(this));

        assertEq(stackPred.avatarSafe, oivPred.avatarSafe, "avatarSafe should match across flows");
        assertEq(stackPred.managerSafe, oivPred.managerSafe, "managerSafe should match");
        assertEq(stackPred.execRolesModifier, oivPred.execRolesModifier, "execMod should match");
        assertEq(stackPred.subRolesModifier, oivPred.subRolesModifier, "subMod should match");
        assertEq(stackPred.managerRolesModifier, oivPred.managerRolesModifier, "managerMod should match");
    }

    /// @dev Cross-flow real-deployment invariant: predictOiv before deploying via deployStack
    ///      must agree on the Avatar Safe address that deployStack actually produces. (We can't
    ///      run both deployStack and deployOiv on the same salt+caller — they'd CREATE2-collide
    ///      — so this test verifies the prediction matches the actual deployment path the user
    ///      will take on the OTHER chain.)
    function test_predictOiv_avatarSafeMatchesDeployStackActualAddress() public {
        // Predict via the deployOiv path for a given salt+caller.
        KpkOivFactory.OivInstance memory oivPred = factory.predictOivAddresses(oivConfig, address(this));

        // Now actually deploy via the deployStack path with the same salt+caller — should
        // produce the same Avatar Safe address as the deployOiv prediction.
        KpkOivFactory.StackConfig memory stackCfg = _buildStackConfig();
        stackCfg.salt = oivConfig.salt;
        KpkOivFactory.StackInstance memory stackActual = factory.deployStack(stackCfg);

        assertEq(stackActual.avatarSafe, oivPred.avatarSafe, "deployStack avatarSafe != deployOiv prediction");
        assertEq(stackActual.managerSafe, oivPred.managerSafe, "managerSafe mismatch");
        assertEq(stackActual.execRolesModifier, oivPred.execRolesModifier, "execMod mismatch");
        assertEq(stackActual.subRolesModifier, oivPred.subRolesModifier, "subMod mismatch");
        assertEq(stackActual.managerRolesModifier, oivPred.managerRolesModifier, "managerMod mismatch");
    }

    /// @dev Symmetrical to the above — predictStack before deploying via deployOiv must agree
    ///      on the Avatar Safe address that deployOiv actually produces.
    function test_predictStack_avatarSafeMatchesDeployOivActualAddress() public {
        KpkOivFactory.StackConfig memory stackCfg = _buildStackConfig();
        stackCfg.salt = oivConfig.salt;
        KpkOivFactory.StackInstance memory stackPred = factory.predictStackAddresses(stackCfg, address(this));

        KpkOivFactory.OivInstance memory oivActual = factory.deployOiv(oivConfig);

        assertEq(oivActual.avatarSafe, stackPred.avatarSafe, "deployOiv avatarSafe != deployStack prediction");
        assertEq(oivActual.managerSafe, stackPred.managerSafe, "managerSafe mismatch");
        assertEq(oivActual.execRolesModifier, stackPred.execRolesModifier, "execMod mismatch");
        assertEq(oivActual.subRolesModifier, stackPred.subRolesModifier, "subMod mismatch");
        assertEq(oivActual.managerRolesModifier, stackPred.managerRolesModifier, "managerMod mismatch");
    }

    /// @dev Cross-flow CREATE2-collision invariant: deployStack followed by deployOiv with the
    ///      same `(caller, salt)` MUST revert. This is the operational consequence of the
    ///      address invariant — both flows compete for the same Avatar Safe / Manager Safe /
    ///      Roles Modifier addresses, so the second one always reverts. Same-address-everywhere
    ///      also means same-CREATE2-collision when both run on the same chain.
    function test_deployStackThenDeployOiv_revertsOnSameCallerAndSalt() public {
        KpkOivFactory.StackConfig memory stackCfg = _buildStackConfig();
        stackCfg.salt = oivConfig.salt;

        factory.deployStack(stackCfg);

        // Same salt, same caller — collides on the already-deployed Avatar Safe (or another
        // CREATE2 contract; the Roles Modifiers actually deploy first and would collide first).
        vm.expectRevert();
        factory.deployOiv(oivConfig);
    }

    /// @dev Symmetrical: deployOiv then deployStack with the same `(caller, salt)` MUST revert.
    function test_deployOivThenDeployStack_revertsOnSameCallerAndSalt() public {
        factory.deployOiv(oivConfig);

        KpkOivFactory.StackConfig memory stackCfg = _buildStackConfig();
        stackCfg.salt = oivConfig.salt;

        vm.expectRevert();
        factory.deployStack(stackCfg);
    }

    /// @dev Sanity check: predicted addresses are uninhabited contracts before deployment, and
    ///      contain code after. Catches any future regression where the predict math drifts
    ///      from the deployment math without surfacing in the matches-actual-deployment tests.
    function test_predictStack_addressesAreEmptyBeforeDeployAndPopulatedAfter() public {
        KpkOivFactory.StackConfig memory cfg = _buildStackConfig();
        KpkOivFactory.StackInstance memory predicted = factory.predictStackAddresses(cfg, address(this));

        assertEq(predicted.avatarSafe.code.length, 0, "avatarSafe should be empty pre-deploy");
        assertEq(predicted.managerSafe.code.length, 0, "managerSafe should be empty pre-deploy");
        assertEq(predicted.execRolesModifier.code.length, 0, "execMod should be empty pre-deploy");
        assertEq(predicted.subRolesModifier.code.length, 0, "subMod should be empty pre-deploy");
        assertEq(predicted.managerRolesModifier.code.length, 0, "managerMod should be empty pre-deploy");

        factory.deployStack(cfg);

        assertGt(predicted.avatarSafe.code.length, 0, "avatarSafe should have code post-deploy");
        assertGt(predicted.managerSafe.code.length, 0, "managerSafe should have code post-deploy");
        assertGt(predicted.execRolesModifier.code.length, 0, "execMod should have code post-deploy");
        assertGt(predicted.subRolesModifier.code.length, 0, "subMod should have code post-deploy");
        assertGt(predicted.managerRolesModifier.code.length, 0, "managerMod should have code post-deploy");
    }

    /// @dev Different callers with the same salt must produce different predicted addresses
    ///      (M-01 salt-squat protection visible from the read API).
    function test_predict_differentCallerYieldsDifferentAddresses() public {
        KpkOivFactory.StackInstance memory predA = factory.predictStackAddresses(_buildStackConfig(), address(this));
        KpkOivFactory.StackInstance memory predB =
            factory.predictStackAddresses(_buildStackConfig(), makeAddr("otherCaller"));

        assertTrue(predA.avatarSafe != predB.avatarSafe, "avatarSafe should differ");
        assertTrue(predA.managerSafe != predB.managerSafe, "managerSafe should differ");
        assertTrue(predA.execRolesModifier != predB.execRolesModifier, "execMod should differ");
    }

    /// @dev L-01: KpkSharesDeployer.deploy() rejects callers other than the factory.
    function test_kpkSharesDeployer_deploy_revertsForNonFactoryCaller() public {
        KpkSharesDeployer deployer = new KpkSharesDeployer(address(this));
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(KpkSharesDeployer.UnauthorizedCaller.selector);
        deployer.deploy(bytes32(uint256(1)));
    }

    /// @dev L-01: KpkSharesDeployer constructor rejects address(0) factory.
    function test_kpkSharesDeployer_constructor_revertsOnZeroFactory() public {
        vm.expectRevert(KpkSharesDeployer.ZeroFactory.selector);
        new KpkSharesDeployer(address(0));
    }

    // ── deployStack tests ───────────────────────────────────────────────────────

    function test_deployStack_deploysFiveContracts() public {
        KpkOivFactory.StackInstance memory inst = factory.deployStack(_buildStackConfig());

        assertTrue(inst.avatarSafe != address(0), "avatarSafe not deployed");
        assertTrue(inst.managerSafe != address(0), "managerSafe not deployed");
        assertTrue(inst.execRolesModifier != address(0), "execRolesModifier not deployed");
        assertTrue(inst.subRolesModifier != address(0), "subRolesModifier not deployed");
        assertTrue(inst.managerRolesModifier != address(0), "managerRolesModifier not deployed");
    }

    function test_deployStack_avatarSafe_ownerIsEmptyContract() public {
        KpkOivFactory.StackInstance memory inst = factory.deployStack(_buildStackConfig());

        address[] memory owners = ISafe(inst.avatarSafe).getOwners();
        assertEq(owners.length, 1, "avatarSafe should have exactly one owner");
        assertEq(owners[0], factory.EMPTY_CONTRACT(), "avatarSafe owner is not EMPTY_CONTRACT");
    }

    /// @dev The factory is enabled as an Avatar Safe module at setup() time (so the setup data
    ///      matches deployOiv and the Avatar Safe address is identical across flows). It MUST
    ///      be disabled before deployStack returns.
    function test_deployStack_factoryIsNotModuleOfAvatarSafeAfterDeploy() public {
        KpkOivFactory.StackInstance memory inst = factory.deployStack(_buildStackConfig());
        assertFalse(
            ISafe(inst.avatarSafe).isModuleEnabled(address(factory)),
            "factory should not remain a module of avatarSafe after deployStack"
        );
    }

    function test_deployStack_wiringMatchesDeployFund() public {
        KpkOivFactory.StackConfig memory stackCfg = _buildStackConfig();

        KpkOivFactory.StackInstance memory inst = factory.deployStack(stackCfg);

        assertTrue(ISafe(inst.avatarSafe).isModuleEnabled(inst.execRolesModifier), "execMod not module of avatarSafe");
        assertTrue(
            ISafe(inst.managerSafe).isModuleEnabled(inst.managerRolesModifier), "managerMod not module of managerSafe"
        );
        assertEq(IRoles(inst.execRolesModifier).avatar(), inst.avatarSafe, "execMod avatar mismatch");
        assertEq(IRoles(inst.execRolesModifier).target(), inst.avatarSafe, "execMod target mismatch");
        assertEq(IRoles(inst.execRolesModifier).owner(), securityCouncil, "execMod owner mismatch");
        assertEq(IRoles(inst.subRolesModifier).avatar(), inst.avatarSafe, "subMod avatar mismatch");
        assertEq(IRoles(inst.subRolesModifier).target(), inst.execRolesModifier, "subMod target mismatch");
        assertEq(IRoles(inst.subRolesModifier).owner(), inst.managerSafe, "subMod owner mismatch");
        assertEq(IRoles(inst.managerRolesModifier).avatar(), inst.managerSafe, "managerMod avatar mismatch");
        assertEq(IRoles(inst.managerRolesModifier).target(), inst.managerSafe, "managerMod target mismatch");
        assertEq(IRoles(inst.managerRolesModifier).owner(), inst.managerSafe, "managerMod owner mismatch");
    }

    function test_deployStack_sameSaltProducesSameAddresses() public {
        KpkOivFactory.StackConfig memory cfg = _buildStackConfig();

        KpkOivFactory.StackInstance memory inst1 = factory.deployStack(cfg);

        // The same caller using the same salt MUST collide (CREATE2 redeploy revert).
        vm.expectRevert();
        factory.deployStack(cfg);

        // A different salt produces different addresses.
        cfg.salt = 999;
        KpkOivFactory.StackInstance memory inst2 = factory.deployStack(cfg);

        assertTrue(inst1.avatarSafe != inst2.avatarSafe, "same avatarSafe address with different salt");
        assertTrue(inst1.execRolesModifier != inst2.execRolesModifier, "same execMod address with different salt");
    }

    /// @dev M-01: a different caller using the same salt produces DIFFERENT addresses,
    ///      preventing salt-squat front-running of deterministic deployment addresses.
    function test_deployStack_differentCallerSameSaltProducesDifferentAddresses() public {
        KpkOivFactory.StackConfig memory cfg = _buildStackConfig();

        KpkOivFactory.StackInstance memory inst1 = factory.deployStack(cfg);

        address otherCaller = makeAddr("otherCaller");
        vm.prank(otherCaller);
        KpkOivFactory.StackInstance memory inst2 = factory.deployStack(cfg);

        assertTrue(inst1.avatarSafe != inst2.avatarSafe, "salt-squat: same avatarSafe across callers");
        assertTrue(inst1.managerSafe != inst2.managerSafe, "salt-squat: same managerSafe across callers");
        assertTrue(inst1.execRolesModifier != inst2.execRolesModifier, "salt-squat: same execMod across callers");
        assertTrue(inst1.subRolesModifier != inst2.subRolesModifier, "salt-squat: same subMod across callers");
        assertTrue(
            inst1.managerRolesModifier != inst2.managerRolesModifier, "salt-squat: same managerMod across callers"
        );
    }

    function test_stackCount_incrementsOnEachDeploy() public {
        assertEq(factory.stackCount(), 0);

        factory.deployStack(_buildStackConfig());
        assertEq(factory.stackCount(), 1);

        KpkOivFactory.StackConfig memory cfg2 = _buildStackConfig();
        cfg2.salt = 999;
        factory.deployStack(cfg2);
        assertEq(factory.stackCount(), 2);
    }

    // ── Permissionless deployment tests ────────────────────────────────────────

    function test_deployOiv_isPermissionless() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertTrue(inst.kpkSharesProxy != address(0), "stranger could not deploy OIV");
    }

    function test_deployStack_isPermissionless() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        KpkOivFactory.StackInstance memory inst = factory.deployStack(_buildStackConfig());

        assertTrue(inst.avatarSafe != address(0), "stranger could not deploy stack");
    }

    // ── Integration tests ───────────────────────────────────────────────────────

    /// @dev End-to-end: factory deploys a USDC fund, an investor submits the first
    ///      subscription request, and the request sits pending for the operator.
    ///      Verifies the full path from factory deployment to investor interaction.
    function test_integration_firstUsdcSubscriptionRequest() public {
        KpkOivFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        KpkShares shares = KpkShares(inst.kpkSharesProxy);
        address investor = makeAddr("investor");
        uint256 subscriptionAmount = 1_000e6; // 1,000 USDC

        deal(USDC, investor, subscriptionAmount);

        vm.prank(investor);
        IERC20(USDC).approve(address(shares), subscriptionAmount);

        // Expected shares at the opening price of 1 USDC = 1e8 NAV
        uint256 sharesPrice = 1e8;
        uint256 minSharesOut = shares.assetsToShares(subscriptionAmount, sharesPrice, USDC);

        uint256 expectedRequestId = shares.requestId() + 1;
        uint256 investorUsdcBefore = IERC20(USDC).balanceOf(investor);

        vm.prank(investor);
        uint256 requestId = shares.requestSubscription(subscriptionAmount, minSharesOut, USDC, investor);

        // ── request ID ──────────────────────────────────────────────────────────
        assertEq(requestId, expectedRequestId, "unexpected request ID");

        // ── USDC moved from investor to the shares proxy ─────────────────────────
        assertEq(IERC20(USDC).balanceOf(investor), investorUsdcBefore - subscriptionAmount, "investor USDC not pulled");
        assertGe(IERC20(USDC).balanceOf(address(shares)), subscriptionAmount, "shares proxy did not receive USDC");

        // ── request state ────────────────────────────────────────────────────────
        IkpkShares.UserRequest memory req = shares.getRequest(requestId);
        assertEq(uint8(req.requestStatus), uint8(IkpkShares.RequestStatus.PENDING), "request not pending");
        assertEq(uint8(req.requestType), uint8(IkpkShares.RequestType.SUBSCRIPTION), "wrong request type");
        assertEq(req.investor, investor, "request investor mismatch");
        assertEq(req.receiver, investor, "request receiver mismatch");
        assertEq(req.asset, USDC, "request asset mismatch");
        assertEq(req.assetAmount, subscriptionAmount, "request assetAmount mismatch");
        assertEq(req.sharesAmount, minSharesOut, "request minSharesOut mismatch");
    }

    // ── Helpers ─────────────────────────────────────────────────────────────────

    function _buildStackConfig() internal view returns (KpkOivFactory.StackConfig memory cfg) {
        address[] memory managerOwners = new address[](1);
        managerOwners[0] = managerSigner;

        cfg.managerSafe = KpkOivFactory.SafeConfig({owners: managerOwners, threshold: 1});
        cfg.execRolesMod = KpkOivFactory.RolesModifierConfig({finalOwner: securityCouncil});
        cfg.subRolesMod = KpkOivFactory.RolesModifierConfig({finalOwner: address(0)});
        cfg.managerRolesMod = KpkOivFactory.RolesModifierConfig({finalOwner: address(0)});
        cfg.salt = 42;
    }

    function _buildOivConfig() internal view returns (KpkOivFactory.OivConfig memory cfg) {
        address[] memory managerOwners = new address[](1);
        managerOwners[0] = managerSigner;

        cfg.managerSafe = KpkOivFactory.SafeConfig({owners: managerOwners, threshold: 1});
        cfg.salt = 42;
        cfg.admin = admin;
        cfg.additionalAssets = new KpkOivFactory.AssetConfig[](0);
        cfg.sharesParams = KpkShares.ConstructorParams({
            asset: USDC,
            admin: address(0), // ignored — overridden by cfg.admin
            name: "Test Fund Shares",
            symbol: "kTEST",
            safe: address(0), // ignored — overridden by factory
            subscriptionRequestTtl: 1 days,
            redemptionRequestTtl: 1 days,
            feeReceiver: feeReceiver,
            managementFeeRate: 100,
            redemptionFeeRate: 50,
            performanceFeeModule: address(0),
            performanceFeeRate: 0
        });
    }
}

/// @notice Exposes internal KpkOivFactory functions for unit testing.
contract KpkOivFactoryHarness is KpkOivFactory {
    constructor(
        address owner,
        address safeProxyFactory,
        address safeSingleton,
        address safeModuleSetup,
        address safeFallbackHandler,
        address moduleProxyFactory,
        address rolesModifierMastercopy,
        address kpkSharesDeployer
    )
        KpkOivFactory(
            owner,
            safeProxyFactory,
            safeSingleton,
            safeModuleSetup,
            safeFallbackHandler,
            moduleProxyFactory,
            rolesModifierMastercopy,
            kpkSharesDeployer
        )
    {}

    function exposed_execApprove(address avatarSafe, address asset, address spender) external {
        _execApprove(avatarSafe, asset, spender);
    }

    function exposed_disableFactoryModule(address avatarSafe) external {
        bool moduleDisabled = ISafe(avatarSafe)
            .execTransactionFromModule(
                avatarSafe, 0, abi.encodeCall(ISafe.disableModule, (address(0x1), address(this))), 0
            );
        require(moduleDisabled, "KpkOivFactory: failed to disable module");
    }
}

/// @notice Pure unit tests for the execTransactionFromModule return-value checks.
///         No fork required — uses vm.mockCall to simulate Safe responses.
contract KpkOivFactoryUnitTest is Test {
    // Safe v1.4.1 — addresses kept so harness constructor is valid; not called in unit tests.
    address constant SAFE_PROXY_FACTORY = 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2;
    address constant SAFE_SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address constant SAFE_MODULE_SETUP = 0x2dd68b007B46fBe91B9A7c3EDa5A7a1063cB5b47;
    address constant SAFE_FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;
    address constant MODULE_PROXY_FACTORY = 0x000000000000aDdB49795b0f9bA5BC298cDda236;
    address constant ROLES_MODIFIER_MASTERCOPY = 0x9646fDAD06d3e24444381f44362a3B0eB343D337;

    KpkOivFactoryHarness harness;

    function setUp() public {
        // KpkSharesDeployer is factory-locked. Pre-compute the harness address so the deployer
        // can be constructed with it: this contract's next nonce produces the deployer,
        // and the one after that produces the harness.
        uint256 nextNonce = vm.getNonce(address(this));
        address predictedHarness = vm.computeCreateAddress(address(this), nextNonce + 1);

        KpkSharesDeployer deployer = new KpkSharesDeployer(predictedHarness);
        harness = new KpkOivFactoryHarness(
            address(this),
            SAFE_PROXY_FACTORY,
            SAFE_SINGLETON,
            SAFE_MODULE_SETUP,
            SAFE_FALLBACK_HANDLER,
            MODULE_PROXY_FACTORY,
            ROLES_MODIFIER_MASTERCOPY,
            address(deployer)
        );
        require(address(harness) == predictedHarness, "harness address mismatch");
    }

    function test_execApprove_revertsIfModuleCallReturnsFalse() public {
        address mockSafe = makeAddr("mockSafe");
        address mockToken = makeAddr("mockToken");
        address spender = makeAddr("spender");

        vm.mockCall(
            mockSafe,
            abi.encodeCall(
                ISafe.execTransactionFromModule,
                (mockToken, 0, abi.encodeCall(IERC20.approve, (spender, type(uint256).max)), 0)
            ),
            abi.encode(false)
        );

        vm.expectRevert("KpkOivFactory: approve module call failed");
        harness.exposed_execApprove(mockSafe, mockToken, spender);
    }

    function test_disableModule_revertsIfModuleCallReturnsFalse() public {
        address mockSafe = makeAddr("mockSafe");

        vm.mockCall(
            mockSafe,
            abi.encodeCall(
                ISafe.execTransactionFromModule,
                (mockSafe, 0, abi.encodeCall(ISafe.disableModule, (address(0x1), address(harness))), 0)
            ),
            abi.encode(false)
        );

        vm.expectRevert("KpkOivFactory: failed to disable module");
        harness.exposed_disableFactoryModule(mockSafe);
    }
}

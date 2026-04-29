// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KpkSharesFactory} from "src/KpkSharesFactory.sol";
import {KpkSharesDeployer} from "src/KpkSharesDeployer.sol";
import {KpkShares} from "src/kpkShares.sol";
import {IkpkShares} from "src/IkpkShares.sol";
import {ISafe} from "src/interfaces/ISafe.sol";
import {IRoles} from "src/interfaces/IRoles.sol";

/// @notice Fork tests for KpkSharesFactory against mainnet Safe and Zodiac contracts.
///         Run with: forge test --match-contract KpkSharesFactoryTest --fork-url $MAINNET_URL -vvv
contract KpkSharesFactoryTest is Test {
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
    address sharesAdmin = makeAddr("sharesAdmin");
    address feeReceiver = makeAddr("feeReceiver");

    // ── Contracts under test ────────────────────────────────────────────────────

    KpkSharesFactory factory;

    KpkSharesFactory.OivConfig oivConfig;

    // ── Setup ───────────────────────────────────────────────────────────────────

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_URL"));

        KpkSharesDeployer sharesDeployer = new KpkSharesDeployer();

        factory = new KpkSharesFactory(
            factoryOwner,
            SAFE_PROXY_FACTORY,
            SAFE_SINGLETON,
            SAFE_MODULE_SETUP,
            SAFE_FALLBACK_HANDLER,
            MODULE_PROXY_FACTORY,
            ROLES_MODIFIER_MASTERCOPY,
            address(sharesDeployer)
        );

        oivConfig = _buildOivConfig();
    }

    // ── deployOiv tests ────────────────────────────────────────────────────────

    function test_deployOiv_deploysAllSixContracts() public {
        KpkSharesFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertTrue(inst.avatarSafe != address(0), "avatarSafe not deployed");
        assertTrue(inst.managerSafe != address(0), "managerSafe not deployed");
        assertTrue(inst.execRolesModifier != address(0), "execRolesModifier not deployed");
        assertTrue(inst.subRolesModifier != address(0), "subRolesModifier not deployed");
        assertTrue(inst.managerRolesModifier != address(0), "managerRolesModifier not deployed");
        assertTrue(inst.kpkSharesProxy != address(0), "kpkSharesProxy not deployed");
    }

    function test_avatarSafe_hasExecModifierAsModule() public {
        KpkSharesFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertTrue(
            ISafe(inst.avatarSafe).isModuleEnabled(inst.execRolesModifier),
            "execRolesModifier not a module of avatarSafe"
        );
    }

    function test_avatarSafe_ownerIsEmptyContract() public {
        KpkSharesFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        address[] memory owners = ISafe(inst.avatarSafe).getOwners();
        assertEq(owners.length, 1, "avatarSafe should have exactly one owner");
        assertEq(owners[0], factory.EMPTY_CONTRACT(), "avatarSafe owner is not EMPTY_CONTRACT");
    }

    function test_factory_isNotModuleOfAvatarSafeAfterDeploy() public {
        KpkSharesFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertFalse(
            ISafe(inst.avatarSafe).isModuleEnabled(address(factory)), "factory should not remain a module of avatarSafe"
        );
    }

    function test_managerSafe_hasManagerModifierAsModule() public {
        KpkSharesFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertTrue(
            ISafe(inst.managerSafe).isModuleEnabled(inst.managerRolesModifier),
            "managerRolesModifier not a module of managerSafe"
        );
    }

    function test_execModifier_avatarIsAvatarSafe() public {
        KpkSharesFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(IRoles(inst.execRolesModifier).avatar(), inst.avatarSafe, "execMod avatar mismatch");
    }

    function test_execModifier_targetIsAvatarSafe() public {
        KpkSharesFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(IRoles(inst.execRolesModifier).target(), inst.avatarSafe, "execMod target mismatch");
    }

    function test_subModifier_avatarIsAvatarSafe() public {
        KpkSharesFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(IRoles(inst.subRolesModifier).avatar(), inst.avatarSafe, "subMod avatar mismatch");
    }

    function test_subModifier_targetIsExecModifier() public {
        KpkSharesFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(IRoles(inst.subRolesModifier).target(), inst.execRolesModifier, "subMod target mismatch");
    }

    function test_managerModifier_avatarIsManagerSafe() public {
        KpkSharesFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(IRoles(inst.managerRolesModifier).avatar(), inst.managerSafe, "managerMod avatar mismatch");
    }

    function test_managerModifier_targetIsManagerSafe() public {
        KpkSharesFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(IRoles(inst.managerRolesModifier).target(), inst.managerSafe, "managerMod target mismatch");
    }

    /// @dev Proves MANAGER role is assigned to managerSafe on execRolesModifier by having
    ///      managerSafe execute a real transaction through it. The Security Council (owner)
    ///      first scopes a target and allows a function for the MANAGER role, then managerSafe
    ///      calls execTransactionWithRole — which succeeds only if managerSafe holds MANAGER.
    function test_execModifier_managerSafeHasManagerRole() public {
        KpkSharesFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        bytes32 managerRole = bytes32("MANAGER");
        // Scope USDC and allow approve() for the MANAGER role — approving 0 always succeeds.
        bytes4 selector = IERC20.approve.selector;

        vm.startPrank(securityCouncil);
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
        KpkSharesFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertTrue(
            IRoles(inst.execRolesModifier).isModuleEnabled(inst.subRolesModifier),
            "subRolesModifier not enabled in execRolesModifier"
        );
    }

    function test_execModifier_ownerIsSecurityCouncil() public {
        KpkSharesFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(IRoles(inst.execRolesModifier).owner(), securityCouncil, "execMod owner is not securityCouncil");
    }

    function test_subModifier_ownerIsManagerSafe() public {
        KpkSharesFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(IRoles(inst.subRolesModifier).owner(), inst.managerSafe, "subMod owner is not managerSafe");
    }

    function test_managerModifier_ownerIsManagerSafe() public {
        KpkSharesFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(IRoles(inst.managerRolesModifier).owner(), inst.managerSafe, "managerMod owner is not managerSafe");
    }

    function test_sharesProxy_portfolioSafeIsAvatarSafe() public {
        KpkSharesFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(KpkShares(inst.kpkSharesProxy).portfolioSafe(), inst.avatarSafe, "portfolioSafe mismatch");
    }

    function test_sharesProxy_adminIsSharesAdmin() public {
        KpkSharesFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        KpkShares shares = KpkShares(inst.kpkSharesProxy);
        assertTrue(shares.hasRole(0x00, sharesAdmin), "sharesAdmin does not have DEFAULT_ADMIN_ROLE");
    }

    function test_sharesProxy_operatorIsManagerSafe() public {
        KpkSharesFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        KpkShares shares = KpkShares(inst.kpkSharesProxy);
        assertTrue(shares.hasRole(keccak256("OPERATOR"), inst.managerSafe), "managerSafe does not have OPERATOR role");
    }

    function test_sharesProxy_factoryHasNoAdminRole() public {
        KpkSharesFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        KpkShares shares = KpkShares(inst.kpkSharesProxy);
        assertFalse(shares.hasRole(0x00, address(factory)), "factory still has DEFAULT_ADMIN_ROLE");
    }

    function test_sharesProxy_baseAssetHasInfiniteAllowance() public {
        KpkSharesFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertEq(
            IERC20(USDC).allowance(inst.avatarSafe, inst.kpkSharesProxy),
            type(uint256).max,
            "base asset allowance is not infinite"
        );
    }

    function test_sharesProxy_cannotReinitialize() public {
        KpkSharesFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        vm.expectRevert();
        KpkShares(inst.kpkSharesProxy).initialize(oivConfig.sharesParams);
    }

    function test_instanceCount_incrementsOnEachDeploy() public {
        assertEq(factory.instanceCount(), 0);

        factory.deployOiv(oivConfig);
        assertEq(factory.instanceCount(), 1);

        // Deploy a second fund with a different salt to avoid CREATE2 collisions.
        KpkSharesFactory.OivConfig memory cfg2 = _buildOivConfig();
        cfg2.stack.salt = 999;

        factory.deployOiv(cfg2);
        assertEq(factory.instanceCount(), 2);
    }

    function test_deployOiv_revertsOnZeroExecModOwner() public {
        oivConfig.stack.execRolesMod.finalOwner = address(0);
        vm.prank(factoryOwner);
        vm.expectRevert(KpkSharesFactory.ZeroAddress.selector);
        factory.deployOiv(oivConfig);
    }

    function test_deployOiv_revertsOnEmptyManagerOwners() public {
        oivConfig.stack.managerSafe.owners = new address[](0);
        vm.prank(factoryOwner);
        vm.expectRevert(KpkSharesFactory.EmptyOwners.selector);
        factory.deployOiv(oivConfig);
    }

    function test_deployOiv_revertsOnInvalidThreshold() public {
        oivConfig.stack.managerSafe.threshold = 5; // more than 1 owner
        vm.prank(factoryOwner);
        vm.expectRevert(KpkSharesFactory.InvalidThreshold.selector);
        factory.deployOiv(oivConfig);
    }

    function test_deployOiv_revertsIfApproveModuleCallFails() public {
        // Make USDC.approve revert so that the Avatar Safe's execTransactionFromModule
        // returns false when the factory tries to grant the shares proxy its allowance.
        vm.mockCallRevert(USDC, abi.encodeWithSelector(IERC20.approve.selector), "");
        vm.expectRevert("KpkSharesFactory: approve module call failed");
        factory.deployOiv(oivConfig);
    }

    // ── deployStack tests ───────────────────────────────────────────────────────

    function test_deployStack_deploysFiveContracts() public {
        KpkSharesFactory.StackInstance memory inst = factory.deployStack(_buildStackConfig());

        assertTrue(inst.avatarSafe != address(0), "avatarSafe not deployed");
        assertTrue(inst.managerSafe != address(0), "managerSafe not deployed");
        assertTrue(inst.execRolesModifier != address(0), "execRolesModifier not deployed");
        assertTrue(inst.subRolesModifier != address(0), "subRolesModifier not deployed");
        assertTrue(inst.managerRolesModifier != address(0), "managerRolesModifier not deployed");
    }

    function test_deployStack_avatarSafe_ownerIsEmptyContract() public {
        KpkSharesFactory.StackInstance memory inst = factory.deployStack(_buildStackConfig());

        address[] memory owners = ISafe(inst.avatarSafe).getOwners();
        assertEq(owners.length, 1, "avatarSafe should have exactly one owner");
        assertEq(owners[0], factory.EMPTY_CONTRACT(), "avatarSafe owner is not EMPTY_CONTRACT");
    }

    function test_deployStack_wiringMatchesDeployFund() public {
        KpkSharesFactory.StackConfig memory stackCfg = _buildStackConfig();

        KpkSharesFactory.StackInstance memory inst = factory.deployStack(stackCfg);

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
        KpkSharesFactory.StackConfig memory cfg = _buildStackConfig();

        KpkSharesFactory.StackInstance memory inst1 = factory.deployStack(cfg);

        // Deploying again with the same salt must revert (CREATE2 collision).
        vm.prank(factoryOwner);
        vm.expectRevert();
        factory.deployStack(cfg);

        // A different salt produces different addresses.
        cfg.salt = 999;
        KpkSharesFactory.StackInstance memory inst2 = factory.deployStack(cfg);

        assertTrue(inst1.avatarSafe != inst2.avatarSafe, "same avatarSafe address with different salt");
        assertTrue(inst1.execRolesModifier != inst2.execRolesModifier, "same execMod address with different salt");
    }

    function test_stackCount_incrementsOnEachDeploy() public {
        assertEq(factory.stackCount(), 0);

        factory.deployStack(_buildStackConfig());
        assertEq(factory.stackCount(), 1);

        KpkSharesFactory.StackConfig memory cfg2 = _buildStackConfig();
        cfg2.salt = 999;
        factory.deployStack(cfg2);
        assertEq(factory.stackCount(), 2);
    }

    // ── Permissionless deployment tests ────────────────────────────────────────

    function test_deployOiv_isPermissionless() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        KpkSharesFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

        assertTrue(inst.kpkSharesProxy != address(0), "stranger could not deploy OIV");
    }

    function test_deployStack_isPermissionless() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        KpkSharesFactory.StackInstance memory inst = factory.deployStack(_buildStackConfig());

        assertTrue(inst.avatarSafe != address(0), "stranger could not deploy stack");
    }

    // ── Integration tests ───────────────────────────────────────────────────────

    /// @dev End-to-end: factory deploys a USDC fund, an investor submits the first
    ///      subscription request, and the request sits pending for the operator.
    ///      Verifies the full path from factory deployment to investor interaction.
    function test_integration_firstUsdcSubscriptionRequest() public {
        KpkSharesFactory.OivInstance memory inst = factory.deployOiv(oivConfig);

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

    function _buildStackConfig() internal view returns (KpkSharesFactory.StackConfig memory cfg) {
        address[] memory managerOwners = new address[](1);
        managerOwners[0] = managerSigner;

        cfg.managerSafe = KpkSharesFactory.SafeConfig({owners: managerOwners, threshold: 1});
        cfg.execRolesMod = KpkSharesFactory.RolesModifierConfig({finalOwner: securityCouncil});
        cfg.subRolesMod = KpkSharesFactory.RolesModifierConfig({finalOwner: address(0)});
        cfg.managerRolesMod = KpkSharesFactory.RolesModifierConfig({finalOwner: address(0)});
        cfg.salt = 42;
    }

    function _buildOivConfig() internal view returns (KpkSharesFactory.OivConfig memory cfg) {
        cfg.stack = _buildStackConfig();
        cfg.additionalAssets = new KpkSharesFactory.AssetConfig[](0);
        cfg.sharesParams = KpkShares.ConstructorParams({
            asset: USDC,
            admin: sharesAdmin,
            name: "Test Fund Shares",
            symbol: "kTEST",
            safe: address(0), // overridden by factory
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

/// @notice Exposes internal KpkSharesFactory functions for unit testing.
contract KpkSharesFactoryHarness is KpkSharesFactory {
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
        KpkSharesFactory(
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
        require(moduleDisabled, "KpkSharesFactory: failed to disable module");
    }
}

/// @notice Pure unit tests for the execTransactionFromModule return-value checks.
///         No fork required — uses vm.mockCall to simulate Safe responses.
contract KpkSharesFactoryUnitTest is Test {
    // Safe v1.4.1 — addresses kept so harness constructor is valid; not called in unit tests.
    address constant SAFE_PROXY_FACTORY = 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2;
    address constant SAFE_SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address constant SAFE_MODULE_SETUP = 0x2dd68b007B46fBe91B9A7c3EDa5A7a1063cB5b47;
    address constant SAFE_FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;
    address constant MODULE_PROXY_FACTORY = 0x000000000000aDdB49795b0f9bA5BC298cDda236;
    address constant ROLES_MODIFIER_MASTERCOPY = 0x9646fDAD06d3e24444381f44362a3B0eB343D337;

    KpkSharesFactoryHarness harness;

    function setUp() public {
        KpkSharesDeployer deployer = new KpkSharesDeployer();
        harness = new KpkSharesFactoryHarness(
            address(this),
            SAFE_PROXY_FACTORY,
            SAFE_SINGLETON,
            SAFE_MODULE_SETUP,
            SAFE_FALLBACK_HANDLER,
            MODULE_PROXY_FACTORY,
            ROLES_MODIFIER_MASTERCOPY,
            address(deployer)
        );
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

        vm.expectRevert("KpkSharesFactory: approve module call failed");
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

        vm.expectRevert("KpkSharesFactory: failed to disable module");
        harness.exposed_disableFactoryModule(mockSafe);
    }
}

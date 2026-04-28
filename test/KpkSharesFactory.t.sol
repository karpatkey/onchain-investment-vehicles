// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {KpkSharesFactory} from "src/KpkSharesFactory.sol";
import {KpkShares} from "src/kpkShares.sol";
import {ISafe} from "src/interfaces/ISafe.sol";
import {IRoles} from "src/interfaces/IRoles.sol";

/// @notice Fork tests for KpkSharesFactory against mainnet Safe and Zodiac contracts.
///         Run with: forge test --match-contract KpkSharesFactoryTest --fork-url $ETH_RPC_URL -vvv
contract KpkSharesFactoryTest is Test {
    // USDC on mainnet — used as the shares asset in tests.
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // ── Test accounts ───────────────────────────────────────────────────────────

    address factoryOwner = makeAddr("factoryOwner");
    address securityCouncil = makeAddr("securityCouncil");
    address managerSigner = makeAddr("managerSigner");
    address avatarSigner = makeAddr("avatarSigner");
    address sharesAdmin = makeAddr("sharesAdmin");
    address sharesOperator = makeAddr("sharesOperator");
    address feeReceiver = makeAddr("feeReceiver");

    // ── Contracts under test ────────────────────────────────────────────────────

    KpkSharesFactory factory;

    KpkSharesFactory.FundConfig fundConfig;

    // ── Setup ───────────────────────────────────────────────────────────────────

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_URL"));

        factory = new KpkSharesFactory(factoryOwner);

        fundConfig = _buildFundConfig();
    }

    // ── deployFund tests ────────────────────────────────────────────────────────

    function test_deployFund_deploysAllSixContracts() public {
        vm.prank(factoryOwner);
        KpkSharesFactory.FundInstance memory inst = factory.deployFund(fundConfig);

        assertTrue(inst.avatarSafe != address(0), "avatarSafe not deployed");
        assertTrue(inst.managerSafe != address(0), "managerSafe not deployed");
        assertTrue(inst.execRolesModifier != address(0), "execRolesModifier not deployed");
        assertTrue(inst.subRolesModifier != address(0), "subRolesModifier not deployed");
        assertTrue(inst.managerRolesModifier != address(0), "managerRolesModifier not deployed");
        assertTrue(inst.kpkSharesProxy != address(0), "kpkSharesProxy not deployed");
    }

    function test_avatarSafe_hasExecModifierAsModule() public {
        vm.prank(factoryOwner);
        KpkSharesFactory.FundInstance memory inst = factory.deployFund(fundConfig);

        assertTrue(
            ISafe(inst.avatarSafe).isModuleEnabled(inst.execRolesModifier),
            "execRolesModifier not a module of avatarSafe"
        );
    }

    function test_managerSafe_hasManagerModifierAsModule() public {
        vm.prank(factoryOwner);
        KpkSharesFactory.FundInstance memory inst = factory.deployFund(fundConfig);

        assertTrue(
            ISafe(inst.managerSafe).isModuleEnabled(inst.managerRolesModifier),
            "managerRolesModifier not a module of managerSafe"
        );
    }

    function test_execModifier_avatarAndTargetAreAvatarSafe() public {
        vm.prank(factoryOwner);
        KpkSharesFactory.FundInstance memory inst = factory.deployFund(fundConfig);

        assertEq(IRoles(inst.execRolesModifier).avatar(), inst.avatarSafe, "execMod avatar mismatch");
    }

    function test_subModifier_targetIsExecModifier() public {
        vm.prank(factoryOwner);
        KpkSharesFactory.FundInstance memory inst = factory.deployFund(fundConfig);

        assertEq(IRoles(inst.subRolesModifier).avatar(), inst.avatarSafe, "subMod avatar mismatch");
    }

    function test_execModifier_hasSubModifierAsNestedModule() public {
        vm.prank(factoryOwner);
        KpkSharesFactory.FundInstance memory inst = factory.deployFund(fundConfig);

        assertTrue(
            IRoles(inst.execRolesModifier).isModuleEnabled(inst.subRolesModifier),
            "subRolesModifier not enabled in execRolesModifier"
        );
    }

    function test_execModifier_ownerIsSecurityCouncil() public {
        vm.prank(factoryOwner);
        KpkSharesFactory.FundInstance memory inst = factory.deployFund(fundConfig);

        assertEq(IRoles(inst.execRolesModifier).owner(), securityCouncil, "execMod owner is not securityCouncil");
    }

    function test_subModifier_ownerIsManagerSafe() public {
        vm.prank(factoryOwner);
        KpkSharesFactory.FundInstance memory inst = factory.deployFund(fundConfig);

        assertEq(IRoles(inst.subRolesModifier).owner(), inst.managerSafe, "subMod owner is not managerSafe");
    }

    function test_managerModifier_ownerIsManagerSafe() public {
        vm.prank(factoryOwner);
        KpkSharesFactory.FundInstance memory inst = factory.deployFund(fundConfig);

        assertEq(IRoles(inst.managerRolesModifier).owner(), inst.managerSafe, "managerMod owner is not managerSafe");
    }

    function test_sharesProxy_portfolioSafeIsAvatarSafe() public {
        vm.prank(factoryOwner);
        KpkSharesFactory.FundInstance memory inst = factory.deployFund(fundConfig);

        assertEq(KpkShares(inst.kpkSharesProxy).portfolioSafe(), inst.avatarSafe, "portfolioSafe mismatch");
    }

    function test_sharesProxy_adminIsSharesAdmin() public {
        vm.prank(factoryOwner);
        KpkSharesFactory.FundInstance memory inst = factory.deployFund(fundConfig);

        KpkShares shares = KpkShares(inst.kpkSharesProxy);
        assertTrue(shares.hasRole(0x00, sharesAdmin), "sharesAdmin does not have DEFAULT_ADMIN_ROLE");
    }

    function test_sharesProxy_operatorIsSharesOperator() public {
        vm.prank(factoryOwner);
        KpkSharesFactory.FundInstance memory inst = factory.deployFund(fundConfig);

        KpkShares shares = KpkShares(inst.kpkSharesProxy);
        assertTrue(shares.hasRole(keccak256("OPERATOR"), sharesOperator), "sharesOperator does not have OPERATOR role");
    }

    function test_sharesProxy_factoryHasNoAdminRole() public {
        vm.prank(factoryOwner);
        KpkSharesFactory.FundInstance memory inst = factory.deployFund(fundConfig);

        KpkShares shares = KpkShares(inst.kpkSharesProxy);
        assertFalse(shares.hasRole(0x00, address(factory)), "factory still has DEFAULT_ADMIN_ROLE");
    }

    function test_sharesProxy_cannotReinitialize() public {
        vm.prank(factoryOwner);
        KpkSharesFactory.FundInstance memory inst = factory.deployFund(fundConfig);

        vm.expectRevert();
        KpkShares(inst.kpkSharesProxy).initialize(fundConfig.sharesParams);
    }

    function test_instanceCount_incrementsOnEachDeploy() public {
        assertEq(factory.instanceCount(), 0);

        vm.prank(factoryOwner);
        factory.deployFund(fundConfig);
        assertEq(factory.instanceCount(), 1);

        // Deploy a second fund with a different salt to avoid CREATE2 collisions.
        KpkSharesFactory.FundConfig memory cfg2 = _buildFundConfig();
        cfg2.stack.salt = 999;

        vm.prank(factoryOwner);
        factory.deployFund(cfg2);
        assertEq(factory.instanceCount(), 2);
    }

    function test_deployFund_revertsIfNotOwner() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        factory.deployFund(fundConfig);
    }

    function test_deployFund_revertsOnZeroExecModOwner() public {
        fundConfig.stack.execRolesMod.finalOwner = address(0);
        vm.prank(factoryOwner);
        vm.expectRevert(KpkSharesFactory.ZeroAddress.selector);
        factory.deployFund(fundConfig);
    }

    function test_deployFund_revertsOnEmptyAvatarOwners() public {
        fundConfig.stack.avatarSafe.owners = new address[](0);
        vm.prank(factoryOwner);
        vm.expectRevert(KpkSharesFactory.EmptyOwners.selector);
        factory.deployFund(fundConfig);
    }

    function test_deployFund_revertsOnInvalidThreshold() public {
        fundConfig.stack.avatarSafe.threshold = 5; // more than 1 owner
        vm.prank(factoryOwner);
        vm.expectRevert(KpkSharesFactory.InvalidThreshold.selector);
        factory.deployFund(fundConfig);
    }

    // ── deployStack tests ───────────────────────────────────────────────────────

    function test_deployStack_deploysFiveContracts() public {
        vm.prank(factoryOwner);
        KpkSharesFactory.StackInstance memory inst = factory.deployStack(_buildStackConfig());

        assertTrue(inst.avatarSafe != address(0), "avatarSafe not deployed");
        assertTrue(inst.managerSafe != address(0), "managerSafe not deployed");
        assertTrue(inst.execRolesModifier != address(0), "execRolesModifier not deployed");
        assertTrue(inst.subRolesModifier != address(0), "subRolesModifier not deployed");
        assertTrue(inst.managerRolesModifier != address(0), "managerRolesModifier not deployed");
    }

    function test_deployStack_wiringMatchesDeployFund() public {
        KpkSharesFactory.StackConfig memory stackCfg = _buildStackConfig();

        vm.prank(factoryOwner);
        KpkSharesFactory.StackInstance memory inst = factory.deployStack(stackCfg);

        assertTrue(ISafe(inst.avatarSafe).isModuleEnabled(inst.execRolesModifier), "execMod not module of avatarSafe");
        assertTrue(
            ISafe(inst.managerSafe).isModuleEnabled(inst.managerRolesModifier), "managerMod not module of managerSafe"
        );
        assertEq(IRoles(inst.execRolesModifier).owner(), securityCouncil, "execMod owner mismatch");
        assertEq(IRoles(inst.subRolesModifier).owner(), inst.managerSafe, "subMod owner mismatch");
        assertEq(IRoles(inst.managerRolesModifier).owner(), inst.managerSafe, "managerMod owner mismatch");
    }

    function test_deployStack_sameSaltProducesSameAddresses() public {
        KpkSharesFactory.StackConfig memory cfg = _buildStackConfig();

        vm.prank(factoryOwner);
        KpkSharesFactory.StackInstance memory inst1 = factory.deployStack(cfg);

        // Deploying again with the same salt must revert (CREATE2 collision).
        vm.prank(factoryOwner);
        vm.expectRevert();
        factory.deployStack(cfg);

        // A different salt produces different addresses.
        cfg.salt = 999;
        vm.prank(factoryOwner);
        KpkSharesFactory.StackInstance memory inst2 = factory.deployStack(cfg);

        assertTrue(inst1.avatarSafe != inst2.avatarSafe, "same avatarSafe address with different salt");
        assertTrue(inst1.execRolesModifier != inst2.execRolesModifier, "same execMod address with different salt");
    }

    function test_stackCount_incrementsOnEachDeploy() public {
        assertEq(factory.stackCount(), 0);

        vm.prank(factoryOwner);
        factory.deployStack(_buildStackConfig());
        assertEq(factory.stackCount(), 1);

        KpkSharesFactory.StackConfig memory cfg2 = _buildStackConfig();
        cfg2.salt = 999;
        vm.prank(factoryOwner);
        factory.deployStack(cfg2);
        assertEq(factory.stackCount(), 2);
    }

    function test_deployStack_revertsIfNotOwner() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        factory.deployStack(_buildStackConfig());
    }

    // ── Helpers ─────────────────────────────────────────────────────────────────

    function _buildStackConfig() internal view returns (KpkSharesFactory.StackConfig memory cfg) {
        address[] memory avatarOwners = new address[](1);
        avatarOwners[0] = avatarSigner;

        address[] memory managerOwners = new address[](1);
        managerOwners[0] = managerSigner;

        cfg.avatarSafe = KpkSharesFactory.SafeConfig({owners: avatarOwners, threshold: 1});
        cfg.managerSafe = KpkSharesFactory.SafeConfig({owners: managerOwners, threshold: 1});
        cfg.execRolesMod = KpkSharesFactory.RolesModifierConfig({finalOwner: securityCouncil});
        cfg.subRolesMod = KpkSharesFactory.RolesModifierConfig({finalOwner: address(0)});
        cfg.managerRolesMod = KpkSharesFactory.RolesModifierConfig({finalOwner: address(0)});
        cfg.salt = 42;
    }

    function _buildFundConfig() internal view returns (KpkSharesFactory.FundConfig memory cfg) {
        cfg.stack = _buildStackConfig();
        cfg.sharesOperator = sharesOperator;
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

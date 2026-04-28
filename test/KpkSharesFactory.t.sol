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
    // ── Known mainnet addresses ─────────────────────────────────────────────────

    address constant SAFE_PROXY_FACTORY = 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2;
    address constant SAFE_SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address constant SAFE_MODULE_SETUP = 0x2dd68b007B46fBe91B9A7c3EDa5A7a1063cB5b47;
    address constant SAFE_FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;
    address constant MODULE_PROXY_FACTORY = 0x000000000000aDdB49795b0f9bA5BC298cDda236;
    address constant ROLES_MODIFIER_MASTERCOPY = 0x9646fDAD06d3e24444381f44362a3B0eB343D337;

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
    address kpkSharesImpl;

    KpkSharesFactory.FundConfig fundConfig;

    // ── Setup ───────────────────────────────────────────────────────────────────

    function setUp() public {
        // Deploy KpkShares implementation once.
        kpkSharesImpl = address(new KpkShares());

        factory = new KpkSharesFactory(
            factoryOwner,
            kpkSharesImpl,
            SAFE_PROXY_FACTORY,
            SAFE_SINGLETON,
            SAFE_MODULE_SETUP,
            SAFE_FALLBACK_HANDLER,
            MODULE_PROXY_FACTORY,
            ROLES_MODIFIER_MASTERCOPY
        );

        fundConfig = _buildFundConfig();
    }

    // ── Deployment tests ────────────────────────────────────────────────────────

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

        // Deploy a second fund with different salts to avoid CREATE2 collisions.
        KpkSharesFactory.FundConfig memory cfg2 = _buildFundConfig();
        cfg2.execRolesMod.salt = 999;
        cfg2.subRolesMod.salt = 998;
        cfg2.managerRolesMod.salt = 997;
        cfg2.avatarSafe.nonce = 100;
        cfg2.managerSafe.nonce = 101;

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
        fundConfig.execRolesMod.finalOwner = address(0);
        vm.prank(factoryOwner);
        vm.expectRevert(KpkSharesFactory.ZeroAddress.selector);
        factory.deployFund(fundConfig);
    }

    function test_deployFund_revertsOnEmptyAvatarOwners() public {
        fundConfig.avatarSafe.owners = new address[](0);
        vm.prank(factoryOwner);
        vm.expectRevert(KpkSharesFactory.EmptyOwners.selector);
        factory.deployFund(fundConfig);
    }

    function test_deployFund_revertsOnInvalidThreshold() public {
        fundConfig.avatarSafe.threshold = 5; // more than 1 owner
        vm.prank(factoryOwner);
        vm.expectRevert(KpkSharesFactory.InvalidThreshold.selector);
        factory.deployFund(fundConfig);
    }

    // ── Helpers ─────────────────────────────────────────────────────────────────

    function _buildFundConfig() internal view returns (KpkSharesFactory.FundConfig memory cfg) {
        address[] memory avatarOwners = new address[](1);
        avatarOwners[0] = avatarSigner;

        address[] memory managerOwners = new address[](1);
        managerOwners[0] = managerSigner;

        cfg.avatarSafe = KpkSharesFactory.SafeConfig({owners: avatarOwners, threshold: 1, nonce: 42});

        cfg.managerSafe = KpkSharesFactory.SafeConfig({owners: managerOwners, threshold: 1, nonce: 43});

        cfg.execRolesMod = KpkSharesFactory.RolesModifierConfig({salt: 1, finalOwner: securityCouncil});

        cfg.subRolesMod = KpkSharesFactory.RolesModifierConfig({salt: 2, finalOwner: address(0)});

        cfg.managerRolesMod = KpkSharesFactory.RolesModifierConfig({salt: 3, finalOwner: address(0)});

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

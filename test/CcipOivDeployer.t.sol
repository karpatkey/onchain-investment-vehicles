// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {KpkOivFactory} from "src/KpkOivFactory.sol";
import {KpkSharesDeployer} from "src/KpkSharesDeployer.sol";
import {KpkShares} from "src/kpkShares.sol";
import {CcipOivDeployer} from "src/CcipOivDeployer.sol";
import {Client} from "chainlink-brownie-contracts/contracts/src/v0.8/ccip/libraries/Client.sol";
import {MockCcipRouter} from "test/mocks/MockCcipRouter.sol";
import {Mock_ERC20} from "test/mocks/tokens.sol";
import {
    IAny2EVMMessageReceiver
} from "chainlink-brownie-contracts/contracts/src/v0.8/ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice Fork tests for `CcipOivDeployer` against mainnet Safe + Zodiac infra (same fork the
///         factory suite uses). CCIP is mocked: the source path records dispatched messages, and
///         the destination path is exercised by calling `ccipReceive` directly with the mock router
///         set as `msg.sender`. The orchestrator is the uniform factory caller, so all address
///         predictions key on `address(orchestrator)`.
///
///         Run with: forge test --match-contract CcipOivDeployerTest --fork-url $MAINNET_URL
contract CcipOivDeployerTest is Test {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Safe v1.4.1
    address constant SAFE_PROXY_FACTORY = 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2;
    address constant SAFE_SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address constant SAFE_MODULE_SETUP = 0x2dd68b007B46fBe91B9A7c3EDa5A7a1063cB5b47;
    address constant SAFE_FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;

    // Zodiac
    address constant MODULE_PROXY_FACTORY = 0x000000000000aDdB49795b0f9bA5BC298cDda236;
    address constant ROLES_MODIFIER_MASTERCOPY = 0x9646fDAD06d3e24444381f44362a3B0eB343D337;

    // CCIP chain selectors (mainnet source, two example destinations).
    uint64 constant MAINNET_SELECTOR = 5009297550715157269;
    uint64 constant ARBITRUM_SELECTOR = 4949039107694359620;
    uint64 constant BASE_SELECTOR = 15971525489660198786;

    uint256 constant GAS_LIMIT = 2_000_000;
    uint256 constant FEE = 1 ether; // 1 LINK per message (mock)

    address factoryOwner = makeAddr("factoryOwner");
    address securityCouncil = makeAddr("securityCouncil");
    address managerSigner = makeAddr("managerSigner");
    address admin = makeAddr("admin");
    address feeReceiver = makeAddr("feeReceiver");
    address stranger = makeAddr("stranger");

    KpkOivFactory factory;
    CcipOivDeployer orchestrator;
    MockCcipRouter router;
    Mock_ERC20 link;

    KpkOivFactory.OivConfig oivConfig;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_URL"));

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

        router = new MockCcipRouter();
        router.setFee(FEE);
        link = new Mock_ERC20("LINK", 18);

        // owner = address(this) so the happy path needs no prank.
        orchestrator = new CcipOivDeployer(address(this), address(factory));
        orchestrator.configure(address(router), address(link), MAINNET_SELECTOR);

        link.mint(address(orchestrator), 100 ether);

        oivConfig = _buildOivConfig();
    }

    // ── Source path: deployEverywhere ────────────────────────────────────────────

    function test_deployEverywhere_deploysLocalOivMatchingPrediction() public {
        KpkOivFactory.OivInstance memory predicted = factory.predictOivAddresses(oivConfig, address(orchestrator));

        uint64[] memory dests = _dests();
        (KpkOivFactory.OivInstance memory inst,) = orchestrator.deployEverywhere(oivConfig, dests, GAS_LIMIT);

        assertEq(inst.avatarSafe, predicted.avatarSafe, "avatarSafe mismatch");
        assertEq(inst.managerSafe, predicted.managerSafe, "managerSafe mismatch");
        assertEq(inst.execRolesModifier, predicted.execRolesModifier, "execMod mismatch");
        assertEq(inst.subRolesModifier, predicted.subRolesModifier, "subMod mismatch");
        assertEq(inst.managerRolesModifier, predicted.managerRolesModifier, "managerMod mismatch");
        assertGt(inst.kpkSharesProxy.code.length, 0, "shares proxy not deployed");
    }

    function test_deployEverywhere_dispatchesOnePerDestinationAndChargesLink() public {
        uint64[] memory dests = _dests();
        uint256 balBefore = link.balanceOf(address(orchestrator));

        (, bytes32[] memory ids) = orchestrator.deployEverywhere(oivConfig, dests, GAS_LIMIT);

        assertEq(ids.length, 2, "two message ids");
        assertEq(router.sentCount(), 2, "two ccipSend calls");
        assertEq(link.balanceOf(address(orchestrator)), balBefore - 2 * FEE, "LINK not charged correctly");
        assertEq(link.balanceOf(address(router)), 2 * FEE, "router did not receive fees");
    }

    function test_deployEverywhere_payloadEncodesDerivedStackConfig() public {
        uint64[] memory dests = _dests();
        orchestrator.deployEverywhere(oivConfig, dests, GAS_LIMIT);

        KpkOivFactory.StackConfig memory sent = abi.decode(router.lastData(), (KpkOivFactory.StackConfig));
        assertEq(sent.salt, oivConfig.salt, "salt mismatch");
        assertEq(sent.execRolesMod.finalOwner, oivConfig.admin, "execMod finalOwner must equal admin");
        assertEq(sent.subRolesMod.finalOwner, address(0), "subMod finalOwner must be zero");
        assertEq(sent.managerRolesMod.finalOwner, address(0), "managerMod finalOwner must be zero");
        assertEq(sent.managerSafe.owners[0], oivConfig.managerSafe.owners[0], "manager owner mismatch");
        assertEq(sent.managerSafe.threshold, oivConfig.managerSafe.threshold, "threshold mismatch");
    }

    function test_deployEverywhere_onlyOwner() public {
        uint64[] memory dests = _dests();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        orchestrator.deployEverywhere(oivConfig, dests, GAS_LIMIT);
    }

    function test_deployEverywhere_revertsWhenNotConfigured() public {
        CcipOivDeployer fresh = new CcipOivDeployer(address(this), address(factory));
        uint64[] memory dests = _dests();
        vm.expectRevert(CcipOivDeployer.NotConfigured.selector);
        fresh.deployEverywhere(oivConfig, dests, GAS_LIMIT);
    }

    function test_deployEverywhere_revertsOnNoDestinations() public {
        uint64[] memory dests = new uint64[](0);
        vm.expectRevert(CcipOivDeployer.NoDestinations.selector);
        orchestrator.deployEverywhere(oivConfig, dests, GAS_LIMIT);
    }

    function test_deployEverywhere_revertsOnInsufficientLink() public {
        orchestrator.withdrawLink(address(this), link.balanceOf(address(orchestrator)));
        uint64[] memory dests = _dests();
        vm.expectRevert(abi.encodeWithSelector(CcipOivDeployer.InsufficientLinkBalance.selector, FEE, 0));
        orchestrator.deployEverywhere(oivConfig, dests, GAS_LIMIT);
    }

    // ── Destination path: ccipReceive ─────────────────────────────────────────────

    /// @dev The load-bearing cross-chain property: a stack deployed via `ccipReceive` (the sidechain
    ///      path) lands at the SAME operational addresses as the mainnet OIV prediction, because the
    ///      orchestrator is the uniform factory caller on every chain.
    function test_ccipReceive_deploysStackMatchingMainnetOivPrediction() public {
        KpkOivFactory.OivInstance memory oivPred = factory.predictOivAddresses(oivConfig, address(orchestrator));

        _deliver(_validMessage());

        // The stack now exists at the predicted operational addresses.
        assertGt(oivPred.avatarSafe.code.length, 0, "avatarSafe should have code");
        assertGt(oivPred.managerSafe.code.length, 0, "managerSafe should have code");
        assertGt(oivPred.execRolesModifier.code.length, 0, "execMod should have code");
        assertGt(oivPred.subRolesModifier.code.length, 0, "subMod should have code");
        assertGt(oivPred.managerRolesModifier.code.length, 0, "managerMod should have code");
        // Shares proxy is NOT deployed on the sidechain (deployStack only).
        assertEq(oivPred.kpkSharesProxy.code.length, 0, "shares proxy must not exist on sidechain");
    }

    function test_ccipReceive_revertsForWrongRouter() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CcipOivDeployer.InvalidRouter.selector, stranger));
        orchestrator.ccipReceive(_validMessage());
    }

    function test_ccipReceive_revertsForWrongSourceChain() public {
        Client.Any2EVMMessage memory m = _validMessage();
        m.sourceChainSelector = 999;
        vm.prank(address(router));
        vm.expectRevert(abi.encodeWithSelector(CcipOivDeployer.InvalidSourceChain.selector, uint64(999)));
        orchestrator.ccipReceive(m);
    }

    function test_ccipReceive_revertsForWrongSourceSender() public {
        Client.Any2EVMMessage memory m = _validMessage();
        m.sender = abi.encode(stranger); // not the sibling orchestrator address
        vm.prank(address(router));
        vm.expectRevert(abi.encodeWithSelector(CcipOivDeployer.InvalidSourceSender.selector, stranger));
        orchestrator.ccipReceive(m);
    }

    // ── Config / treasury / introspection ─────────────────────────────────────────

    function test_configure_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        orchestrator.configure(address(router), address(link), MAINNET_SELECTOR);
    }

    function test_configure_revertsOnZeroRouter() public {
        vm.expectRevert(CcipOivDeployer.ZeroAddress.selector);
        orchestrator.configure(address(0), address(link), MAINNET_SELECTOR);
    }

    function test_constructor_revertsOnZeroFactory() public {
        vm.expectRevert(CcipOivDeployer.ZeroAddress.selector);
        new CcipOivDeployer(address(this), address(0));
    }

    function test_quoteDeployEverywhere_sumsFees() public view {
        uint64[] memory dests = _dests();
        (uint256 total, uint256[] memory per) = orchestrator.quoteDeployEverywhere(oivConfig, dests, GAS_LIMIT);
        assertEq(total, 2 * FEE, "total fee");
        assertEq(per[0], FEE, "per[0]");
        assertEq(per[1], FEE, "per[1]");
    }

    function test_withdrawLink_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        orchestrator.withdrawLink(stranger, 1 ether);
    }

    function test_supportsInterface() public view {
        assertTrue(orchestrator.supportsInterface(type(IAny2EVMMessageReceiver).interfaceId), "IAny2EVM");
        assertTrue(orchestrator.supportsInterface(type(IERC165).interfaceId), "IERC165");
        assertFalse(orchestrator.supportsInterface(0xffffffff), "bad iface");
    }

    // ── Helpers ────────────────────────────────────────────────────────────────

    function _dests() internal pure returns (uint64[] memory dests) {
        dests = new uint64[](2);
        dests[0] = ARBITRUM_SELECTOR;
        dests[1] = BASE_SELECTOR;
    }

    function _validMessage() internal view returns (Client.Any2EVMMessage memory) {
        KpkOivFactory.StackConfig memory stackCfg = KpkOivFactory.StackConfig({
            managerSafe: oivConfig.managerSafe,
            execRolesMod: KpkOivFactory.RolesModifierConfig({finalOwner: oivConfig.admin}),
            subRolesMod: KpkOivFactory.RolesModifierConfig({finalOwner: address(0)}),
            managerRolesMod: KpkOivFactory.RolesModifierConfig({finalOwner: address(0)}),
            salt: oivConfig.salt
        });
        return Client.Any2EVMMessage({
            messageId: keccak256("msg"),
            sourceChainSelector: MAINNET_SELECTOR,
            sender: abi.encode(address(orchestrator)),
            data: abi.encode(stackCfg),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
    }

    function _deliver(Client.Any2EVMMessage memory m) internal {
        vm.prank(address(router));
        orchestrator.ccipReceive(m);
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
            admin: address(0),
            name: "Test Fund Shares",
            symbol: "kTEST",
            safe: address(0),
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

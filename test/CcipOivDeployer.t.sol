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

    // CCIP chain selectors (mainnet source, three example destinations).
    uint64 constant MAINNET_SELECTOR = 5009297550715157269;
    uint64 constant ARBITRUM_SELECTOR = 4949039107694359620;
    uint64 constant BASE_SELECTOR = 15971525489660198786;
    uint64 constant OPTIMISM_SELECTOR = 3734403246176062136;

    // Destination chain IDs — callers target chains by id; the orchestrator resolves each to its CCIP
    // selector via the owner-managed mapping (seeded in setUp).
    uint256 constant ARBITRUM_CHAIN_ID = 42161;
    uint256 constant BASE_CHAIN_ID = 8453;
    uint256 constant OPTIMISM_CHAIN_ID = 10;

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

        // Seed the chainId -> CCIP selector mapping for the destinations used in tests.
        orchestrator.setChainSelector(ARBITRUM_CHAIN_ID, ARBITRUM_SELECTOR);
        orchestrator.setChainSelector(BASE_CHAIN_ID, BASE_SELECTOR);
        orchestrator.setChainSelector(OPTIMISM_CHAIN_ID, OPTIMISM_SELECTOR);

        // LINK is still configured (retained for the withdrawLink sweep), but CCIP fees are now paid
        // in NATIVE gas from the caller's msg.value — so the caller, not the orchestrator, is funded.
        link.mint(address(orchestrator), 100 ether);
        vm.deal(address(this), 1_000 ether);
        vm.deal(stranger, 1_000 ether);

        oivConfig = _buildOivConfig();
    }

    /// @dev Total native fee for `n` destinations at the mock's flat per-message fee.
    function _fee(uint256 n) internal pure returns (uint256) {
        return n * FEE;
    }

    /// @dev Accept native refunds of surplus `msg.value` from the orchestrator.
    receive() external payable {}

    /// @dev Mirrors CcipOivDeployer._effectiveConfig — the config-bound salt the deploy path uses.
    function _effSalt() internal view returns (uint256) {
        return uint256(keccak256(abi.encode(oivConfig)));
    }

    function _effConfig() internal view returns (KpkOivFactory.OivConfig memory eff) {
        eff = oivConfig;
        eff.salt = _effSalt();
    }

    // ── Source path: deployEverywhere ────────────────────────────────────────────

    function test_deployEverywhere_deploysLocalOivMatchingPrediction() public {
        KpkOivFactory.OivInstance memory predicted = orchestrator.predictOiv(oivConfig);

        uint256[] memory dests = _dests();
        (KpkOivFactory.OivInstance memory inst,) =
            orchestrator.deployEverywhere{value: _fee(dests.length)}(oivConfig, dests, GAS_LIMIT);

        assertEq(inst.avatarSafe, predicted.avatarSafe, "avatarSafe mismatch");
        assertEq(inst.managerSafe, predicted.managerSafe, "managerSafe mismatch");
        assertEq(inst.execRolesModifier, predicted.execRolesModifier, "execMod mismatch");
        assertEq(inst.subRolesModifier, predicted.subRolesModifier, "subMod mismatch");
        assertEq(inst.managerRolesModifier, predicted.managerRolesModifier, "managerMod mismatch");
        assertGt(inst.kpkSharesProxy.code.length, 0, "shares proxy not deployed");
    }

    function test_deployEverywhere_dispatchesOnePerDestinationAndChargesNativeFee() public {
        uint256[] memory dests = _dests();
        uint256 routerBalBefore = address(router).balance;

        (, bytes32[] memory ids) = orchestrator.deployEverywhere{value: _fee(dests.length)}(oivConfig, dests, GAS_LIMIT);

        assertEq(ids.length, 2, "two message ids");
        assertEq(router.sentCount(), 2, "two ccipSend calls");
        assertEq(address(router).balance, routerBalBefore + 2 * FEE, "router did not receive native fees");
        assertEq(address(orchestrator).balance, 0, "orchestrator must not retain native");
    }

    function test_deployEverywhere_refundsSurplusValue() public {
        uint256[] memory dests = _dests();
        uint256 overpay = 5 ether;
        uint256 balBefore = address(this).balance;

        orchestrator.deployEverywhere{value: _fee(dests.length) + overpay}(oivConfig, dests, GAS_LIMIT);

        // Only the exact fee should be consumed; the surplus is refunded to the caller.
        assertEq(balBefore - address(this).balance, _fee(dests.length), "surplus not refunded");
        assertEq(address(orchestrator).balance, 0, "orchestrator must not retain native");
    }

    /// @dev The whole point of native, caller-funded fees: anyone — not just the owner — can deploy.
    function test_deployEverywhere_isPermissionless() public {
        uint256[] memory dests = _dests();
        vm.prank(stranger);
        (, bytes32[] memory ids) = orchestrator.deployEverywhere{value: _fee(dests.length)}(oivConfig, dests, GAS_LIMIT);
        assertEq(ids.length, 2, "stranger can deploy + dispatch");
        assertEq(router.sentCount(), 2, "messages dispatched for non-owner caller");
    }

    function test_deployEverywhere_payloadEncodesDerivedStackConfig() public {
        uint256[] memory dests = _dests();
        orchestrator.deployEverywhere{value: _fee(dests.length)}(oivConfig, dests, GAS_LIMIT);

        KpkOivFactory.StackConfig memory sent = abi.decode(router.lastData(), (KpkOivFactory.StackConfig));
        assertEq(sent.salt, _effSalt(), "salt mismatch");
        assertEq(sent.execRolesMod.finalOwner, oivConfig.admin, "execMod finalOwner must equal admin");
        assertEq(sent.subRolesMod.finalOwner, address(0), "subMod finalOwner must be zero");
        assertEq(sent.managerRolesMod.finalOwner, address(0), "managerMod finalOwner must be zero");
        assertEq(sent.managerSafe.owners[0], oivConfig.managerSafe.owners[0], "manager owner mismatch");
        assertEq(sent.managerSafe.threshold, oivConfig.managerSafe.threshold, "threshold mismatch");
    }

    function test_deployEverywhere_revertsWhenNotConfigured() public {
        CcipOivDeployer fresh = new CcipOivDeployer(address(this), address(factory));
        uint256[] memory dests = _dests();
        vm.expectRevert(CcipOivDeployer.NotConfigured.selector);
        fresh.deployEverywhere(oivConfig, dests, GAS_LIMIT);
    }

    function test_deployEverywhere_revertsOnNoDestinations() public {
        uint256[] memory dests = new uint256[](0);
        vm.expectRevert(CcipOivDeployer.NoDestinations.selector);
        orchestrator.deployEverywhere(oivConfig, dests, GAS_LIMIT);
    }

    function test_deployEverywhere_revertsOnInsufficientFee() public {
        uint256[] memory dests = _dests();
        // Aggregate fee across both destinations is checked up front against msg.value.
        vm.expectRevert(abi.encodeWithSelector(CcipOivDeployer.InsufficientFee.selector, 2 * FEE, FEE));
        orchestrator.deployEverywhere{value: FEE}(oivConfig, dests, GAS_LIMIT);
    }

    // ── Destination path: ccipReceive ─────────────────────────────────────────────

    /// @dev The load-bearing cross-chain property: a stack deployed via `ccipReceive` (the sidechain
    ///      path) lands at the SAME operational addresses as the mainnet OIV prediction, because the
    ///      orchestrator is the uniform factory caller on every chain.
    function test_ccipReceive_deploysStackMatchingMainnetOivPrediction() public {
        KpkOivFactory.OivInstance memory oivPred = orchestrator.predictOiv(oivConfig);

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
        // Build the message first — it makes an external call (factory.oivToStackConfig) that would
        // otherwise consume the prank/expectRevert.
        Client.Any2EVMMessage memory m = _validMessage();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CcipOivDeployer.InvalidRouter.selector, stranger));
        orchestrator.ccipReceive(m);
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

    function test_configure_revertsOnZeroSelector() public {
        vm.expectRevert(CcipOivDeployer.ZeroChainSelector.selector);
        orchestrator.configure(address(router), address(link), 0);
    }

    function test_constructor_revertsOnZeroFactory() public {
        vm.expectRevert(CcipOivDeployer.ZeroAddress.selector);
        new CcipOivDeployer(address(this), address(0));
    }

    function test_quoteDeployEverywhere_sumsFees() public view {
        uint256[] memory dests = _dests();
        (uint256 total, uint256[] memory per) = orchestrator.quoteDeployEverywhere(oivConfig, dests, GAS_LIMIT);
        assertEq(total, 2 * FEE, "total fee");
        assertEq(per[0], FEE, "per[0]");
        assertEq(per[1], FEE, "per[1]");
    }

    // ── dispatchTo (recovery / add-a-chain path) ──────────────────────────────────

    function test_dispatchTo_sendsWithoutLocalDeployOiv() public {
        uint256 instancesBefore = factory.instanceCount();
        uint256[] memory dests = _dests();

        uint256 routerBalBefore = address(router).balance;
        bytes32[] memory ids = orchestrator.dispatchTo{value: _fee(dests.length)}(oivConfig, dests, GAS_LIMIT);

        // No local OIV was deployed — only CCIP messages went out.
        assertEq(factory.instanceCount(), instancesBefore, "dispatchTo must not deploy a local OIV");
        assertEq(ids.length, 2, "two message ids");
        assertEq(router.sentCount(), 2, "two ccipSend calls");
        assertEq(address(router).balance, routerBalBefore + 2 * FEE, "router did not receive native fees");
        // Payload is the same factory-derived StackConfig as the deploy path.
        KpkOivFactory.StackConfig memory sent = abi.decode(router.lastData(), (KpkOivFactory.StackConfig));
        assertEq(sent.salt, _effSalt(), "salt mismatch");
        assertEq(sent.execRolesMod.finalOwner, oivConfig.admin, "execMod finalOwner mismatch");
    }

    function test_dispatchTo_isPermissionless() public {
        uint256[] memory dests = _dests();
        vm.prank(stranger);
        bytes32[] memory ids = orchestrator.dispatchTo{value: _fee(dests.length)}(oivConfig, dests, GAS_LIMIT);
        assertEq(ids.length, 2, "non-owner can dispatch");
    }

    function test_dispatchTo_revertsWhenNotConfigured() public {
        CcipOivDeployer fresh = new CcipOivDeployer(address(this), address(factory));
        uint256[] memory dests = _dests();
        vm.expectRevert(CcipOivDeployer.NotConfigured.selector);
        fresh.dispatchTo(oivConfig, dests, GAS_LIMIT);
    }

    /// @dev The recovery / add-a-chain path: after deployEverywhere has run, dispatchTo can fan the
    ///      same fund out to an additional sidechain — without re-running the local deployOiv (which
    ///      would revert on the mainnet CREATE2 collision). (Actual delivery → matching addresses is
    ///      covered by test_ccipReceive_deploysStackMatchingMainnetOivPrediction.)
    function test_dispatchTo_addsNewChainAfterDeployEverywhere() public {
        orchestrator.deployEverywhere{value: _fee(2)}(oivConfig, _dests(), GAS_LIMIT); // Arbitrum + Base
        uint256 sentAfterDeploy = router.sentCount();

        uint256[] memory more = new uint256[](1);
        more[0] = OPTIMISM_CHAIN_ID;
        bytes32[] memory ids = orchestrator.dispatchTo{value: _fee(more.length)}(oivConfig, more, GAS_LIMIT);

        assertEq(ids.length, 1, "one new message");
        assertEq(router.sentCount(), sentAfterDeploy + 1, "dispatchTo adds exactly one more message");
        KpkOivFactory.StackConfig memory sent = abi.decode(router.lastData(), (KpkOivFactory.StackConfig));
        assertEq(sent.salt, _effSalt(), "same fund salt");
    }

    /// @dev The orchestrator's dispatched StackConfig must equal the factory's own deployOiv mapping,
    ///      enforced by both calling factory.oivToStackConfig (single source of truth, finding #3).
    function test_oivToStackConfig_matchesDispatchedPayload() public {
        orchestrator.dispatchTo{value: _fee(2)}(oivConfig, _dests(), GAS_LIMIT);
        KpkOivFactory.StackConfig memory sent = abi.decode(router.lastData(), (KpkOivFactory.StackConfig));
        KpkOivFactory.StackConfig memory expected = factory.oivToStackConfig(_effConfig());
        assertEq(abi.encode(sent), abi.encode(expected), "dispatched payload must equal factory mapping");
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

    // ── chainId → selector registry ───────────────────────────────────────────────

    function test_setChainSelector_storesMapping() public {
        orchestrator.setChainSelector(7777, 12345);
        assertEq(orchestrator.chainSelectorOf(7777), 12345, "selector not stored");
    }

    function test_setChainSelector_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        orchestrator.setChainSelector(7777, 12345);
    }

    function test_setChainSelector_revertsOnZeroChainId() public {
        vm.expectRevert(CcipOivDeployer.ZeroChainId.selector);
        orchestrator.setChainSelector(0, 12345);
    }

    function test_setChainSelector_revertsOnZeroSelector() public {
        vm.expectRevert(CcipOivDeployer.ZeroChainSelector.selector);
        orchestrator.setChainSelector(7777, 0);
    }

    function test_setChainSelectors_batchPopulates() public {
        uint256[] memory ids = new uint256[](2);
        uint64[] memory sels = new uint64[](2);
        (ids[0], sels[0]) = (1111, 11);
        (ids[1], sels[1]) = (2222, 22);
        orchestrator.setChainSelectors(ids, sels);
        assertEq(orchestrator.chainSelectorOf(1111), 11);
        assertEq(orchestrator.chainSelectorOf(2222), 22);
    }

    function test_setChainSelectors_revertsOnLengthMismatch() public {
        uint256[] memory ids = new uint256[](2);
        uint64[] memory sels = new uint64[](1);
        vm.expectRevert(CcipOivDeployer.LengthMismatch.selector);
        orchestrator.setChainSelectors(ids, sels);
    }

    function test_removeChainSelector_clearsMapping() public {
        orchestrator.removeChainSelector(ARBITRUM_CHAIN_ID); // seeded in setUp
        assertEq(orchestrator.chainSelectorOf(ARBITRUM_CHAIN_ID), 0, "not cleared");
    }

    function test_removeChainSelector_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        orchestrator.removeChainSelector(ARBITRUM_CHAIN_ID);
    }

    function test_removeChainSelector_revertsWhenUnknown() public {
        vm.expectRevert(abi.encodeWithSelector(CcipOivDeployer.UnknownChain.selector, uint256(999999)));
        orchestrator.removeChainSelector(999999);
    }

    function test_deployEverywhere_revertsForUnconfiguredChain() public {
        uint256[] memory dests = new uint256[](1);
        dests[0] = 999999; // never mapped
        vm.expectRevert(abi.encodeWithSelector(CcipOivDeployer.UnknownChain.selector, uint256(999999)));
        orchestrator.deployEverywhere{value: _fee(1)}(oivConfig, dests, GAS_LIMIT);
    }

    function test_deployEverywhere_worksAfterRemappingSelector() public {
        // Owner can correct a selector; the new value is what gets used on dispatch.
        orchestrator.setChainSelector(BASE_CHAIN_ID, 99999);
        assertEq(orchestrator.chainSelectorOf(BASE_CHAIN_ID), 99999, "selector not updated");

        uint256[] memory dests = new uint256[](1);
        dests[0] = BASE_CHAIN_ID;
        orchestrator.deployEverywhere{value: _fee(1)}(oivConfig, dests, GAS_LIMIT);

        // MockCcipRouter.Sent = (destChainSelector, receiver, data, feeToken, fee).
        (uint64 destSel,,,,) = router.sent(router.sentCount() - 1);
        assertEq(destSel, 99999, "dispatched with the updated selector");
    }

    // ── Enumerable registry + all-configured fan-out ──────────────────────────────

    function test_getChainIds_returnsConfiguredSet() public view {
        // setUp configured Arbitrum, Base, Optimism.
        uint256[] memory ids = orchestrator.getChainIds();
        assertEq(ids.length, 3, "three configured");
        assertEq(orchestrator.getChainIdCount(), 3, "count getter");
    }

    function test_setChainSelector_updateDoesNotDuplicate() public {
        orchestrator.setChainSelector(BASE_CHAIN_ID, 12345); // already configured in setUp
        assertEq(orchestrator.getChainIdCount(), 3, "update must not grow the set");
        assertEq(orchestrator.chainSelectorOf(BASE_CHAIN_ID), 12345, "selector updated");
    }

    function test_removeChainSelector_shrinksEnumerableSet() public {
        orchestrator.removeChainSelector(BASE_CHAIN_ID);
        assertEq(orchestrator.getChainIdCount(), 2, "set shrank");
        uint256[] memory ids = orchestrator.getChainIds();
        for (uint256 i = 0; i < ids.length; i++) {
            assertTrue(ids[i] != BASE_CHAIN_ID, "removed id still present");
        }
        // Remaining chains still resolve.
        assertEq(orchestrator.chainSelectorOf(ARBITRUM_CHAIN_ID), ARBITRUM_SELECTOR);
        assertEq(orchestrator.chainSelectorOf(OPTIMISM_CHAIN_ID), OPTIMISM_SELECTOR);
    }

    function test_deployEverywhere_allConfigured_fansOutToEveryChain() public {
        // No array: fans out to all configured chains (3 in setUp).
        (, bytes32[] memory ids) = orchestrator.deployEverywhere{value: _fee(3)}(oivConfig, GAS_LIMIT);
        assertEq(ids.length, 3, "one message per configured chain");
        assertEq(router.sentCount(), 3, "dispatched to all configured");
    }

    function test_quoteDeployEverywhere_allConfigured_sumsAllChains() public view {
        (uint256 total, uint256[] memory per) = orchestrator.quoteDeployEverywhere(oivConfig, GAS_LIMIT);
        assertEq(per.length, 3, "per-destination length");
        assertEq(total, 3 * FEE, "total fee across all configured chains");
    }

    function test_deployEverywhere_allConfigured_skipsLocalChain() public {
        // Configuring the local chain (fork is mainnet, id 1) must not cause a self-send.
        orchestrator.setChainSelector(block.chainid, MAINNET_SELECTOR);
        assertEq(orchestrator.getChainIdCount(), 4, "local chain added to set");

        (, bytes32[] memory ids) = orchestrator.deployEverywhere{value: _fee(3)}(oivConfig, GAS_LIMIT);
        assertEq(ids.length, 3, "local chain skipped - still only 3 remote dispatches");
        assertEq(router.sentCount(), 3, "no self-send");
    }

    function test_deployEverywhere_allConfigured_revertsWhenNoneConfigured() public {
        CcipOivDeployer fresh = new CcipOivDeployer(address(this), address(factory));
        fresh.configure(address(router), address(link), MAINNET_SELECTOR); // router set, but no chains
        vm.expectRevert(CcipOivDeployer.NoDestinations.selector);
        fresh.deployEverywhere{value: 0}(oivConfig, GAS_LIMIT);
    }

    // ── Anti-front-running (config-bound salt) + native sweep ─────────────────────

    /// @dev The High-severity fix: because the orchestrator binds the FULL config into the salt,
    ///      changing any field (here `admin`) changes EVERY deployed address — so a permissionless
    ///      caller cannot front-run a victim's salt and land a fund (with their own admin) at the
    ///      victim's intended addresses.
    function test_predictOiv_differentAdminYieldsDifferentAddresses() public {
        KpkOivFactory.OivInstance memory legit = orchestrator.predictOiv(oivConfig);

        KpkOivFactory.OivConfig memory attacker = oivConfig; // same salt, different admin
        attacker.admin = makeAddr("attacker");
        KpkOivFactory.OivInstance memory squat = orchestrator.predictOiv(attacker);

        assertTrue(legit.avatarSafe != squat.avatarSafe, "avatar safe must differ when admin differs");
        assertTrue(legit.execRolesModifier != squat.execRolesModifier, "exec modifier must differ");
        assertTrue(legit.kpkSharesProxy != squat.kpkSharesProxy, "shares proxy must differ");
    }

    /// @dev Determinism: the same config predicts the same addresses (so cross-chain stacks align).
    function test_predictOiv_sameConfigIsStable() public view {
        KpkOivFactory.OivInstance memory a = orchestrator.predictOiv(oivConfig);
        KpkOivFactory.OivInstance memory b = orchestrator.predictOiv(oivConfig);
        assertEq(a.avatarSafe, b.avatarSafe);
        assertEq(a.kpkSharesProxy, b.kpkSharesProxy);
    }

    /// @dev Deployed fund must match predictOiv (the config-bound-salt prediction).
    function test_deployEverywhere_matchesPredictOiv() public {
        KpkOivFactory.OivInstance memory predicted = orchestrator.predictOiv(oivConfig);
        uint256[] memory dests = _dests();
        (KpkOivFactory.OivInstance memory inst,) =
            orchestrator.deployEverywhere{value: _fee(dests.length)}(oivConfig, dests, GAS_LIMIT);
        assertEq(inst.avatarSafe, predicted.avatarSafe);
        assertEq(inst.kpkSharesProxy, predicted.kpkSharesProxy);
    }

    function test_withdrawNative_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        orchestrator.withdrawNative(stranger, 1);
    }

    function test_withdrawNative_sweepsStrayNative() public {
        vm.deal(address(orchestrator), 3 ether);
        uint256 balBefore = address(this).balance;
        orchestrator.withdrawNative(address(this), 3 ether);
        assertEq(address(this).balance - balBefore, 3 ether, "native not swept");
        assertEq(address(orchestrator).balance, 0, "orchestrator balance not cleared");
    }

    // ── Helpers ────────────────────────────────────────────────────────────────

    function _dests() internal pure returns (uint256[] memory dests) {
        dests = new uint256[](2);
        dests[0] = ARBITRUM_CHAIN_ID;
        dests[1] = BASE_CHAIN_ID;
    }

    function _validMessage() internal view returns (Client.Any2EVMMessage memory) {
        // Source the StackConfig from the factory's own mapping — the same single source of truth
        // the orchestrator uses on the send side.
        KpkOivFactory.StackConfig memory stackCfg = factory.oivToStackConfig(_effConfig());
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

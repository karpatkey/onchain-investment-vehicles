// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KpkOivFactory} from "src/KpkOivFactory.sol";
import {KpkTimelockDeployer} from "src/KpkTimelockDeployer.sol";
import {KpkShares} from "src/kpkShares.sol";
import {
    TimelockControllerUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {KpkShares} from "src/kpkShares.sol";
import {CcipOivDeployer} from "src/CcipOivDeployer.sol";
import {OivTestConstants} from "test/OivTestConstants.sol";
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
///         Fork prerequisite: OivInfraConstants.ROLES_MODIFIER_MASTERCOPY (the Roles Modifier v2.1.1
///         mastercopy) must have bytecode at the forked block — the factory has ModuleProxyFactory
///         deploy a proxy against it, which reverts TargetHasNoCode otherwise. It is live on mainnet,
///         so a latest fork is fine; only a fork pinned before its deployment block would fail.
contract CcipOivDeployerTest is OivTestConstants {
    // USDC + Safe/Zodiac infra (SAFE_*, MODULE_PROXY_FACTORY, ROLES_MODIFIER_MASTERCOPY) are inherited
    // from OivTestConstants — the single test-side source.

    // CCIP chain selectors (mainnet source, three example destinations).
    uint64 constant MAINNET_SELECTOR = 5009297550715157269;

    uint256 constant GNOSIS_CHAIN_ID = 100;

    /// @dev A stand-in for "the base asset on another chain" — only its address matters here.
    address constant GNOSIS_ASSET = 0x2a22f9c3b484c3629090FeED35F17Ff8F88f76F0;

    /// @dev Every wired chain is now seeded into the registry by the orchestrator's CONSTRUCTOR, so a
    ///      fresh instance already knows all of them. Tests that used to seed 3 chains and assert
    ///      absolute set sizes assert against this instead. `CcipNetworksSync` pins the number to the
    ///      wired subset of `script/ccip-networks.json`, so this cannot drift silently.
    uint256 constant BAKED_CHAINS = 19;

    /// @dev Destinations reached by the no-array `deployEverywhere` — every baked chain except the
    ///      local one, which is always skipped rather than self-sent.
    uint256 constant BAKED_DESTINATIONS = BAKED_CHAINS - 1;
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
        _requireInfraDeployed();

        // Nonce map: n = timelock deployer, n+1 = shares deployer, n+2 = factory. The timelock
        // deployer must be constructed on its own line — inline in the argument list it would still
        // consume a nonce, but only after this arithmetic had already been done.
        KpkShares sharesMastercopy = new KpkShares();
        KpkTimelockDeployer timelockDeployer = new KpkTimelockDeployer(address(new TimelockControllerUpgradeable()));
        factory = new KpkOivFactory(
            factoryOwner,
            SAFE_PROXY_FACTORY,
            SAFE_SINGLETON,
            SAFE_MODULE_SETUP,
            SAFE_FALLBACK_HANDLER,
            MODULE_PROXY_FACTORY,
            ROLES_MODIFIER_MASTERCOPY,
            address(sharesMastercopy),
            address(timelockDeployer)
        );

        router = new MockCcipRouter();
        router.setFee(FEE);
        link = new Mock_ERC20("LINK", 18);

        // owner = address(this) so the happy path needs no prank.
        orchestrator = new CcipOivDeployer(address(this), address(factory));
        orchestrator.configure(address(router), address(link));

        // No seeding needed: Arbitrum, Base and Optimism — and every other wired chain — are already
        // in the registry from the constructor. Left as an assertion rather than a comment.
        assertEq(orchestrator.getChainIdCount(), BAKED_CHAINS, "constructor must seed every wired chain");
        assertEq(orchestrator.chainSelectorOf(ARBITRUM_CHAIN_ID), ARBITRUM_SELECTOR, "arbitrum seeded");
        assertEq(orchestrator.chainSelectorOf(BASE_CHAIN_ID), BASE_SELECTOR, "base seeded");
        assertEq(orchestrator.chainSelectorOf(OPTIMISM_CHAIN_ID), OPTIMISM_SELECTOR, "optimism seeded");

        // LINK is still configured (retained for the withdrawLink sweep), but CCIP fees are now paid
        // in NATIVE gas from the caller's msg.value — so the caller, not the orchestrator, is funded.
        link.mint(address(orchestrator), 100 ether);
        vm.deal(address(this), 1_000 ether);
        vm.deal(stranger, 1_000 ether);

        oivConfig = _buildOivConfig();
    }

    /// @dev Total native fee for `n` destinations at the mock's flat per-message fee.
    /// @dev The default topology for these tests: the local chain carries the shares, every other
    ///      wired chain receives a stack. Same shape as the 2-arg `deployEverywhere` sugar.
    function _topology() internal view returns (CcipOivDeployer.SharesChain[] memory t) {
        t = new CcipOivDeployer.SharesChain[](1);
        t[0] = CcipOivDeployer.SharesChain({chainId: block.chainid, asset: oivConfig.sharesParams.asset});
    }

    // ── Shares topology: the three defects it exists to close ──────────────────

    /// @notice L-1. The base asset is the one field that legitimately differs per chain, and hashing
    ///         it verbatim made the SAME config file describe a different fund on every chain — while
    ///         the NatSpec claimed the opposite. This is the test that would have caught it.
    function test_topology_saltIsIdenticalAcrossChainsDespitePerChainAssets() public {
        CcipOivDeployer.SharesChain[] memory topology = new CcipOivDeployer.SharesChain[](2);
        topology[0] = CcipOivDeployer.SharesChain({chainId: 1, asset: USDC});
        topology[1] = CcipOivDeployer.SharesChain({chainId: GNOSIS_CHAIN_ID, asset: GNOSIS_ASSET});

        vm.chainId(1);
        oivConfig.sharesParams.asset = USDC;
        uint256 saltOnMainnet = orchestrator.effectiveSalt(oivConfig, topology);
        KpkOivFactory.OivInstance memory onMainnet = orchestrator.predictOiv(oivConfig, topology);

        vm.chainId(GNOSIS_CHAIN_ID);
        oivConfig.sharesParams.asset = GNOSIS_ASSET;
        uint256 saltOnGnosis = orchestrator.effectiveSalt(oivConfig, topology);
        KpkOivFactory.OivInstance memory onGnosis = orchestrator.predictOiv(oivConfig, topology);

        assertEq(saltOnGnosis, saltOnMainnet, "a per-chain asset must not move the salt");
        assertEq(onGnosis.avatarSafe, onMainnet.avatarSafe, "avatar Safe must match across chains");
        assertEq(onGnosis.kpkSharesProxy, onMainnet.kpkSharesProxy, "shares proxy must match across chains");
    }

    /// @notice Pins the headline claim of the mesh change, which was asserted in NatSpec but by no
    ///         test: the ORIGIN chain never enters the address derivation, so a fan-out started from a
    ///         sidechain describes the same fund at the same addresses as one started from Ethereum.
    ///         `worksFromASidechain` only proved it does not revert.
    function test_topology_originChainDoesNotEnterTheDerivation() public {
        CcipOivDeployer.SharesChain[] memory topology = new CcipOivDeployer.SharesChain[](1);
        topology[0] = CcipOivDeployer.SharesChain({chainId: 1, asset: oivConfig.sharesParams.asset});

        vm.chainId(1);
        uint256 saltFromMainnet = orchestrator.effectiveSalt(oivConfig, topology);
        KpkOivFactory.OivInstance memory fromMainnet = orchestrator.predictOiv(oivConfig, topology);

        vm.chainId(8453); // Base initiates the same fund
        assertEq(orchestrator.effectiveSalt(oivConfig, topology), saltFromMainnet, "origin must not move the salt");

        KpkOivFactory.OivInstance memory fromBase = orchestrator.predictOiv(oivConfig, topology);
        assertEq(fromBase.avatarSafe, fromMainnet.avatarSafe, "avatar Safe must not depend on the origin");
        assertEq(fromBase.managerSafe, fromMainnet.managerSafe, "manager Safe must not depend on the origin");
        assertEq(fromBase.execRolesModifier, fromMainnet.execRolesModifier, "exec modifier must not depend on it");
        assertEq(fromBase.kpkSharesProxy, fromMainnet.kpkSharesProxy, "shares proxy must not depend on it");
    }

    /// @dev The flip side: the topology IS bound, so changing it is a different fund. Without this,
    ///      zeroing the asset for the hash could have been mistaken for dropping it entirely.
    function test_topology_mutatingItMovesEveryAddress() public view {
        CcipOivDeployer.SharesChain[] memory a = new CcipOivDeployer.SharesChain[](1);
        a[0] = CcipOivDeployer.SharesChain({chainId: 1, asset: USDC});

        CcipOivDeployer.SharesChain[] memory b = new CcipOivDeployer.SharesChain[](2);
        b[0] = CcipOivDeployer.SharesChain({chainId: 1, asset: USDC});
        b[1] = CcipOivDeployer.SharesChain({chainId: GNOSIS_CHAIN_ID, asset: GNOSIS_ASSET});

        assertTrue(
            orchestrator.effectiveSalt(oivConfig, a) != orchestrator.effectiveSalt(oivConfig, b),
            "adding a shares chain must be a different fund"
        );
        // And so is changing one chain's asset.
        b[1].asset = USDC;
        CcipOivDeployer.SharesChain[] memory c = new CcipOivDeployer.SharesChain[](2);
        c[0] = b[0];
        c[1] = CcipOivDeployer.SharesChain({chainId: GNOSIS_CHAIN_ID, asset: GNOSIS_ASSET});
        assertTrue(
            orchestrator.effectiveSalt(oivConfig, b) != orchestrator.effectiveSalt(oivConfig, c),
            "a topology asset must be bound, not merely declared"
        );
    }

    /// @notice M-1, source side. A shares chain named in an explicit destination list is a caller
    ///         error, not something to skip: a stack landing there would take the addresses that
    ///         chain's own `deployOiv` needs, permanently.
    function test_topology_explicitListRejectsARemoteSharesChain() public {
        CcipOivDeployer.SharesChain[] memory topology = new CcipOivDeployer.SharesChain[](2);
        topology[0] = CcipOivDeployer.SharesChain({chainId: 1, asset: USDC});
        topology[1] = CcipOivDeployer.SharesChain({chainId: GNOSIS_CHAIN_ID, asset: GNOSIS_ASSET});

        uint256[] memory dests = new uint256[](1);
        dests[0] = GNOSIS_CHAIN_ID;

        vm.expectRevert(
            abi.encodeWithSelector(CcipOivDeployer.SharesChainNotAStackDestination.selector, GNOSIS_CHAIN_ID)
        );
        orchestrator.dispatchTo{value: _fee(1)}(oivConfig, topology, dests, GAS_LIMIT);
    }

    /// @notice M-1, receiver side — the half that actually closes it. The source-side exclusion runs
    ///         on whichever chain initiated, and ANY wired chain may now initiate. Without this,
    ///         anyone knowing a fund's config could dispatch a stack at the chain meant to run
    ///         `deployOiv` and deny that fund forever.
    function test_ccipReceive_refusesAStackAimedAtASharesChain() public {
        // Topology names THIS chain, and the message is delivered here. The message is built on its
        // own line: as an argument it would evaluate first and consume the `expectRevert`.
        Client.Any2EVMMessage memory message = _messageFor(_topology());
        vm.expectRevert(CcipOivDeployer.SharesChainRefusesStack.selector);
        _deliver(message);
    }

    /// @notice L-4. The fan-out skips shares chains, so a second shares chain is filled by its own
    ///         local call — at the identical addresses, with its own asset.
    function test_deployLocal_secondSharesChainLandsAtTheSameAddresses() public {
        CcipOivDeployer.SharesChain[] memory topology = new CcipOivDeployer.SharesChain[](2);
        topology[0] = CcipOivDeployer.SharesChain({chainId: 1, asset: USDC});
        topology[1] = CcipOivDeployer.SharesChain({chainId: GNOSIS_CHAIN_ID, asset: GNOSIS_ASSET});

        KpkOivFactory.OivInstance memory predicted = orchestrator.predictOiv(oivConfig, topology);

        // Chain 1 carries shares: deployLocal deploys the fund, not a stack.
        KpkOivFactory.OivInstance memory deployed = orchestrator.deployLocal(oivConfig, topology);
        assertEq(deployed.avatarSafe, predicted.avatarSafe, "avatar Safe must match the prediction");
        assertEq(deployed.kpkSharesProxy, predicted.kpkSharesProxy, "shares proxy must match the prediction");
        assertTrue(deployed.kpkSharesProxy.code.length > 0, "shares proxy must exist");
    }

    /// @dev The topology commits to each chain's asset; this is what makes that binding real rather
    ///      than decorative.
    function test_deployLocal_revertsWhenTheAssetContradictsTheTopology() public {
        CcipOivDeployer.SharesChain[] memory topology = new CcipOivDeployer.SharesChain[](1);
        topology[0] = CcipOivDeployer.SharesChain({chainId: 1, asset: GNOSIS_ASSET});

        vm.expectRevert(abi.encodeWithSelector(CcipOivDeployer.AssetMismatch.selector, GNOSIS_ASSET, USDC));
        orchestrator.deployLocal(oivConfig, topology);
    }

    function test_topology_mustBeAscending() public {
        CcipOivDeployer.SharesChain[] memory bad = new CcipOivDeployer.SharesChain[](2);
        bad[0] = CcipOivDeployer.SharesChain({chainId: GNOSIS_CHAIN_ID, asset: GNOSIS_ASSET});
        bad[1] = CcipOivDeployer.SharesChain({chainId: 1, asset: USDC});

        vm.expectRevert(abi.encodeWithSelector(CcipOivDeployer.SharesChainsNotAscending.selector, uint256(1)));
        orchestrator.predictOiv(oivConfig, bad);
    }

    /// @notice The 2-arg sugar built its topology without validating it, and `_assetFor` returns
    ///         `address(0)` both for "carries no shares" and for "the declared asset is zero". A
    ///         config with a zero base asset therefore took the STACK branch: 18 non-refundable CCIP
    ///         messages went out, no fund was created, and the salt came from a topology that
    ///         validation rejects — so neither `deployLocal` nor `promoteShares` could ever re-derive
    ///         it. The fund was unrecoverable.
    function test_deployEverywhere_sugarRejectsAZeroBaseAsset() public {
        oivConfig.sharesParams.asset = address(0);
        vm.expectRevert(CcipOivDeployer.InvalidSharesChain.selector);
        orchestrator.deployEverywhere{value: _fee(BAKED_DESTINATIONS)}(oivConfig, GAS_LIMIT);
    }

    function test_quoteDeployEverywhere_sugarRejectsAZeroBaseAsset() public {
        oivConfig.sharesParams.asset = address(0);
        vm.expectRevert(CcipOivDeployer.InvalidSharesChain.selector);
        orchestrator.quoteDeployEverywhere(oivConfig, GAS_LIMIT);
    }

    /// @dev `deployLocal` and `promoteShares` make no CCIP call, so gating them on the registry would
    ///      block them on exactly the chains they exist to serve — the registry is baked at
    ///      construction, so an orchestrator on a chain onboarded later lacks its own id.
    function test_localOperationsWorkOnAChainAbsentFromTheRegistry() public {
        vm.chainId(31337); // not a wired chain
        CcipOivDeployer.SharesChain[] memory topology = new CcipOivDeployer.SharesChain[](1);
        topology[0] = CcipOivDeployer.SharesChain({chainId: 31337, asset: oivConfig.sharesParams.asset});

        // Reaches the factory rather than reverting UnknownChain at the door.
        KpkOivFactory.OivInstance memory inst = orchestrator.deployLocal(oivConfig, topology);
        assertGt(inst.avatarSafe.code.length, 0, "a local deploy must not need the chain to be wired");
    }

    /// @dev A successful stack-only local deploy used to return nine zero addresses, so the operator
    ///      script printed nothing useful after a deploy that worked.
    function test_deployLocal_stackBranchReturnsTheStackAddresses() public {
        CcipOivDeployer.SharesChain[] memory topology = _gnosisOnlyTopology();
        KpkOivFactory.OivInstance memory inst = orchestrator.deployLocal(oivConfig, topology);

        assertGt(inst.avatarSafe.code.length, 0, "avatar Safe must be reported");
        assertTrue(inst.managerSafe != address(0), "manager Safe must be reported");
        assertTrue(inst.execRolesModifier != address(0), "exec modifier must be reported");
        assertEq(inst.kpkSharesProxy, address(0), "and the zero shares fields are the branch signal");
    }

    /// @dev A selector shared by two chain ids used to desync `_isKnownSelector`: removing one of
    ///      them cleared the flag while the other still advertised that selector, so a live
    ///      destination silently rejected every inbound stack.
    function test_removeChainSelector_keepsASharedSelectorTrusted() public {
        orchestrator.setChainSelector(4242, BASE_SELECTOR); // same selector as Base, deliberately
        orchestrator.removeChainSelector(4242);

        assertEq(orchestrator.chainSelectorOf(BASE_CHAIN_ID), BASE_SELECTOR, "Base is still registered");
        // Base must still be accepted as a source: a topology naming Optimism keeps this chain a
        // legitimate stack destination, so delivery should succeed rather than revert InvalidSourceChain.
        CcipOivDeployer.SharesChain[] memory remote = new CcipOivDeployer.SharesChain[](1);
        remote[0] = CcipOivDeployer.SharesChain({chainId: OPTIMISM_CHAIN_ID, asset: oivConfig.sharesParams.asset});
        Client.Any2EVMMessage memory message = _messageFor(remote);
        message.sourceChainSelector = BASE_SELECTOR;
        _deliver(message);
    }

    // ── Promotion: adding a shares chain after birth ───────────────────────────

    /// @dev A topology that declares ONLY Gnosis, so the local chain (mainnet on this fork) is a
    ///      stack-only chain and therefore promotable.
    function _gnosisOnlyTopology() internal view returns (CcipOivDeployer.SharesChain[] memory t) {
        t = new CcipOivDeployer.SharesChain[](1);
        t[0] = CcipOivDeployer.SharesChain({chainId: GNOSIS_CHAIN_ID, asset: GNOSIS_ASSET});
    }

    /// @dev The Avatar Safe approves the (predictable) shares proxy, which `promoteShares` now
    ///      requires up front — a promoted fund is immediately subscribable, so the approval cannot
    ///      be a follow-up someone might not make.
    function _approveFromAvatar(CcipOivDeployer.SharesChain[] memory topology) internal {
        KpkOivFactory.OivInstance memory p = orchestrator.predictOiv(oivConfig, topology);
        vm.prank(p.avatarSafe);
        IERC20(oivConfig.sharesParams.asset).approve(p.kpkSharesProxy, type(uint256).max);
    }

    /// @notice The whole point: a chain the topology never declared gains the shares token, at the
    ///         SAME address every declared shares chain would use. Nothing moves.
    function test_promoteShares_landsAtTheCanonicalAddressWithoutMovingAnything() public {
        CcipOivDeployer.SharesChain[] memory topology = _gnosisOnlyTopology();
        KpkOivFactory.OivInstance memory predicted = orchestrator.predictOiv(oivConfig, topology);

        // This chain is undeclared, so deployLocal gives it the stack only.
        orchestrator.deployLocal(oivConfig, topology);
        assertEq(predicted.kpkSharesProxy.code.length, 0, "no shares token before promotion");
        assertGt(predicted.avatarSafe.code.length, 0, "but the stack is live");

        _approveFromAvatar(topology);
        vm.prank(oivConfig.admin);
        KpkOivFactory.OivInstance memory promoted = orchestrator.promoteShares(oivConfig, topology);

        assertEq(promoted.kpkSharesProxy, predicted.kpkSharesProxy, "promoted proxy must be the canonical one");
        assertEq(promoted.avatarSafe, predicted.avatarSafe, "and reuse the existing Avatar Safe");
        assertGt(promoted.kpkSharesProxy.code.length, 0, "shares token now exists");
    }

    /// @notice `_deriveSalts`'s caller-mixing protects only the shares impl and proxy. The Avatar
    ///         Safe, Manager Safe and three Roles Modifiers come from the PERMISSIONLESS
    ///         `safeProxyFactory` / `moduleProxyFactory`, whose salts are public functions of the
    ///         config — so anyone can land those addresses. An earlier version of the guard tested
    ///         code at the Avatar Safe, which is exactly the address an attacker can create, and
    ///         promotion then succeeded against a stack that was four-fifths absent: a shares token at
    ///         the fund's canonical address whose portfolio Safe has no execution path.
    ///
    ///         This etches ONLY the Avatar Safe, so it stops at the `managerSafe.code.length`
    ///         clause and does not reach the `execRolesModifier.avatar()` check — deleting that check
    ///         leaves this test green. The avatar clause is pinned instead by
    ///         `KpkOivFactoryTest.test_deployShares_refusesAPristineSquattedStack`, which squats all
    ///         five components through the real third-party factories so the avatar is what rejects.
    function test_deployShares_revertsOnASquattedButUnwiredStack() public {
        CcipOivDeployer.SharesChain[] memory topology = _gnosisOnlyTopology();
        KpkOivFactory.OivInstance memory predicted = orchestrator.predictOiv(oivConfig, topology);

        // Stand in for a third-party squat: code at the Avatar Safe, nothing wired.
        vm.etch(predicted.avatarSafe, hex"60006000fd");
        assertGt(predicted.avatarSafe.code.length, 0, "Avatar Safe address is occupied");

        _approveFromAvatar(topology);
        vm.prank(oivConfig.admin);
        vm.expectRevert(KpkOivFactory.StackNotDeployed.selector);
        orchestrator.promoteShares(oivConfig, topology);
    }

    /// @notice The gate. The base asset is the one field the salt does not bind, so an open promotion
    ///         would let anyone holding the true config land a hostile-denominated shares token at the
    ///         fund's canonical address.
    function test_promoteShares_rejectsANonAdminCallerWithAGarbageAsset() public {
        CcipOivDeployer.SharesChain[] memory topology = _gnosisOnlyTopology();
        orchestrator.deployLocal(oivConfig, topology);

        // A REAL mainnet ERC-20, deliberately: with a codeless address the deploy would revert inside
        // `initialize` for an unrelated reason, and the test would pass without the gate doing
        // anything. Using DAI means the ONLY thing standing between an attacker and a
        // hostile-denominated shares token at the fund's canonical address is the gate.
        KpkOivFactory.OivConfig memory hostile = oivConfig;
        hostile.sharesParams.asset = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

        address attacker = makeAddr("promotionAttacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(CcipOivDeployer.NotFundAdmin.selector, attacker));
        orchestrator.promoteShares(hostile, topology);
    }

    /// @notice The pre-occupation attack, re-run against promotion. It used to deny a fund a chain
    ///         forever; now the attacker has merely paid for the fund's stack, and the admin promotes
    ///         on top of it.
    function test_promoteShares_survivesAnAttackerPreLandingTheStack() public {
        CcipOivDeployer.SharesChain[] memory topology = _gnosisOnlyTopology();
        KpkOivFactory.OivInstance memory predicted = orchestrator.predictOiv(oivConfig, topology);

        address attacker = makeAddr("preOccupier");
        vm.prank(attacker);
        orchestrator.deployLocal(oivConfig, topology); // permissionless, lands the stack
        assertGt(predicted.avatarSafe.code.length, 0, "attacker paid for the fund's stack");

        _approveFromAvatar(topology);
        vm.prank(oivConfig.admin);
        KpkOivFactory.OivInstance memory promoted = orchestrator.promoteShares(oivConfig, topology);
        assertEq(promoted.kpkSharesProxy, predicted.kpkSharesProxy, "promotion still lands canonically");
    }

    /// @dev A declared chain must go through `deployLocal`, which honours the asset the topology
    ///      committed to. Promotion there would bypass that commitment.
    function test_promoteShares_revertsOnAnAlreadyDeclaredChain() public {
        vm.prank(oivConfig.admin);
        vm.expectRevert(CcipOivDeployer.SharesChainAlreadyDeclared.selector);
        orchestrator.promoteShares(oivConfig, _topology()); // _topology() declares the local chain
    }

    /// @dev The stack is a prerequisite, and that is what makes a pre-landed stack harmless rather
    ///      than a denial. Shares with no Avatar Safe would be a broken fund.
    function test_promoteShares_revertsWhenTheStackIsNotThereYet() public {
        vm.prank(oivConfig.admin);
        vm.expectRevert(KpkOivFactory.StackNotDeployed.selector);
        orchestrator.promoteShares(oivConfig, _gnosisOnlyTopology());
    }

    /// @notice Was `test_promoteShares_leavesTheAvatarAllowanceAtZero`, which PINNED the gap rather
    ///         than closing it. A promoted fund is immediately subscribable — `requestSubscription`
    ///         has no admin, operator or pause gate — while redemption settlement pulls from the
    ///         Avatar Safe, so an investor could be settled in and then be unable to redeem until an
    ///         off-chain admin transaction landed. The approval is now a precondition, and since the
    ///         proxy address is predictable beforehand there is no window at all.
    function test_promoteShares_requiresTheApprovalBeforeItWillPromote() public {
        CcipOivDeployer.SharesChain[] memory topology = _gnosisOnlyTopology();
        orchestrator.deployLocal(oivConfig, topology);

        vm.prank(oivConfig.admin);
        vm.expectRevert(
            abi.encodeWithSelector(CcipOivDeployer.ApprovalNotGranted.selector, oivConfig.sharesParams.asset)
        );
        orchestrator.promoteShares(oivConfig, topology);

        _approveFromAvatar(topology);
        vm.prank(oivConfig.admin);
        KpkOivFactory.OivInstance memory promoted = orchestrator.promoteShares(oivConfig, topology);
        assertGt(promoted.kpkSharesProxy.code.length, 0, "promotion succeeds once the approval exists");
    }

    /// @notice The approval precondition must cover every asset redemption can pull, not just the
    ///         base one. `KpkOivFactory.deployShares` registers `additionalAssets` but grants no
    ///         allowances — only `deployOiv` calls `_grantApprovals` — and settlement transfers
    ///         `request.asset` out of the Avatar Safe. Checking the base asset alone therefore left
    ///         the exact "subscribed but cannot redeem" state the precondition exists to prevent,
    ///         one asset over.
    function test_promoteShares_requiresApprovalForEveryRedeemableAsset() public {
        CcipOivDeployer.SharesChain[] memory topology = _gnosisOnlyTopology();

        // A real mainnet ERC-20, so the only thing that can reject promotion is the missing
        // allowance rather than an incidental failure inside `initialize`.
        address redeemable = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
        KpkOivFactory.OivConfig memory cfg = oivConfig;
        cfg.additionalAssets = new KpkOivFactory.AssetConfig[](1);
        cfg.additionalAssets[0] = KpkOivFactory.AssetConfig({asset: redeemable, canDeposit: false, canRedeem: true});

        orchestrator.deployLocal(cfg, topology);

        KpkOivFactory.OivInstance memory p = orchestrator.predictOiv(cfg, topology);
        vm.prank(p.avatarSafe);
        IERC20(cfg.sharesParams.asset).approve(p.kpkSharesProxy, type(uint256).max);

        // Base asset approved, the redeemable one not.
        vm.prank(cfg.admin);
        vm.expectRevert(abi.encodeWithSelector(CcipOivDeployer.ApprovalNotGranted.selector, redeemable));
        orchestrator.promoteShares(cfg, topology);

        vm.prank(p.avatarSafe);
        IERC20(redeemable).approve(p.kpkSharesProxy, type(uint256).max);

        vm.prank(cfg.admin);
        KpkOivFactory.OivInstance memory promoted = orchestrator.promoteShares(cfg, topology);
        assertGt(promoted.kpkSharesProxy.code.length, 0, "promotes once every redeemable asset is approved");
    }

    function _fee(uint256 n) internal pure returns (uint256) {
        return n * FEE;
    }

    /// @dev Accept native refunds of surplus `msg.value` from the orchestrator.
    receive() external payable {}

    /// @dev Mirrors CcipOivDeployer._effectiveConfig — the config-bound salt the deploy path uses.
    /// @dev Mirrors `CcipOivDeployer._effectiveConfig`: the base asset is zeroed before hashing
    ///      (it is the one field that legitimately differs per chain) and committed to through the
    ///      topology instead. Deliberately a reimplementation rather than a call into the
    ///      orchestrator, so it can disagree with production and fail.
    function _effSalt() internal view returns (uint256) {
        KpkOivFactory.OivConfig memory bare = oivConfig;
        bare.sharesParams.asset = address(0);
        return uint256(keccak256(abi.encode(bare, _topology())));
    }

    function _effConfig() internal view returns (KpkOivFactory.OivConfig memory eff) {
        eff = oivConfig;
        eff.salt = _effSalt();
    }

    /// @dev The topology projected to chain ids, as the CCIP payload carries it.
    function _sharesChainIds() internal view returns (uint256[] memory ids) {
        CcipOivDeployer.SharesChain[] memory t = _topology();
        ids = new uint256[](t.length);
        for (uint256 i = 0; i < t.length; i++) {
            ids[i] = t[i].chainId;
        }
    }

    // ── Source path: deployEverywhere ────────────────────────────────────────────

    function test_deployEverywhere_deploysLocalOivMatchingPrediction() public {
        KpkOivFactory.OivInstance memory predicted = orchestrator.predictOiv(oivConfig, _topology());

        uint256[] memory dests = _dests();
        (KpkOivFactory.OivInstance memory inst,) =
            orchestrator.deployEverywhere{value: _fee(dests.length)}(oivConfig, _topology(), dests, GAS_LIMIT);

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

        (, bytes32[] memory ids) =
            orchestrator.deployEverywhere{value: _fee(dests.length)}(oivConfig, _topology(), dests, GAS_LIMIT);

        assertEq(ids.length, 2, "two message ids");
        assertEq(router.sentCount(), 2, "two ccipSend calls");
        assertEq(address(router).balance, routerBalBefore + 2 * FEE, "router did not receive native fees");
        assertEq(address(orchestrator).balance, 0, "orchestrator must not retain native");
    }

    function test_deployEverywhere_refundsSurplusValue() public {
        uint256[] memory dests = _dests();
        uint256 overpay = 5 ether;
        uint256 balBefore = address(this).balance;

        orchestrator.deployEverywhere{value: _fee(dests.length) + overpay}(oivConfig, _topology(), dests, GAS_LIMIT);

        // Only the exact fee should be consumed; the surplus is refunded to the caller.
        assertEq(balBefore - address(this).balance, _fee(dests.length), "surplus not refunded");
        assertEq(address(orchestrator).balance, 0, "orchestrator must not retain native");
    }

    /// @dev The whole point of native, caller-funded fees: anyone — not just the owner — can deploy.
    function test_deployEverywhere_isPermissionless() public {
        uint256[] memory dests = _dests();
        vm.prank(stranger);
        (, bytes32[] memory ids) =
            orchestrator.deployEverywhere{value: _fee(dests.length)}(oivConfig, _topology(), dests, GAS_LIMIT);
        assertEq(ids.length, 2, "stranger can deploy + dispatch");
        assertEq(router.sentCount(), 2, "messages dispatched for non-owner caller");
    }

    function test_deployEverywhere_payloadEncodesDerivedStackConfig() public {
        uint256[] memory dests = _dests();
        orchestrator.deployEverywhere{value: _fee(dests.length)}(oivConfig, _topology(), dests, GAS_LIMIT);

        (KpkOivFactory.StackConfig memory sent,) = abi.decode(router.lastData(), (KpkOivFactory.StackConfig, uint256[]));
        assertEq(sent.salt, _effSalt(), "salt mismatch");
        assertEq(sent.execRolesMod.finalOwner, oivConfig.admin, "execMod finalOwner must equal admin");
        assertEq(sent.subRolesMod.finalOwner, address(0), "subMod finalOwner must be zero");
        assertEq(sent.managerRolesMod.finalOwner, address(0), "managerMod finalOwner must be zero");
        assertEq(sent.managerSafe.owners[0], oivConfig.managerSafe.owners[0], "manager owner mismatch");
        assertEq(sent.managerSafe.threshold, oivConfig.managerSafe.threshold, "threshold mismatch");
    }

    function test_deployEverywhere_revertsWhenNotConfigured() public {
        CcipOivDeployer fresh = new CcipOivDeployer(address(this), address(factory));
        // Seed the chains in _dests() so resolution succeeds and we hit the router (NotConfigured) check.
        fresh.setChainSelector(ARBITRUM_CHAIN_ID, ARBITRUM_SELECTOR);
        fresh.setChainSelector(BASE_CHAIN_ID, BASE_SELECTOR);
        uint256[] memory dests = _dests();
        vm.expectRevert(CcipOivDeployer.NotConfigured.selector);
        fresh.deployEverywhere(oivConfig, _topology(), dests, GAS_LIMIT);
    }

    /// @notice The headline of the mesh change: a fan-out no longer has to start on Ethereum. These
    ///         three cases previously reverted `NotSourceChain`; the restriction was never load-bearing
    ///         for the address invariant, since the orchestrator is the uniform `msg.sender` into the
    ///         factory on every chain and the salt is composed from the config alone.
    function test_deployEverywhere_worksFromASidechain() public {
        vm.chainId(8453); // Base
        uint256[] memory dests = _dests();
        orchestrator.deployEverywhere{value: _fee(2)}(oivConfig, _topology(), dests, GAS_LIMIT);
    }

    function test_deployEverywhere_allConfigured_worksFromASidechain() public {
        vm.chainId(42161); // Arbitrum
        orchestrator.deployEverywhere{value: _fee(BAKED_DESTINATIONS)}(oivConfig, GAS_LIMIT);
    }

    function test_dispatchTo_worksFromASidechain() public {
        vm.chainId(10); // Optimism
        uint256[] memory dests = _dests();
        orchestrator.dispatchTo{value: _fee(2)}(oivConfig, _topology(), dests, GAS_LIMIT);
    }

    /// @dev The one restriction that remains: a chain absent from the registry cannot initiate, since
    ///      every sibling would reject its messages after the fees had already been paid.
    function test_deployEverywhere_revertsFromAnUnwiredChain() public {
        vm.chainId(1337);
        uint256[] memory dests = _dests();
        vm.expectRevert(abi.encodeWithSelector(CcipOivDeployer.UnknownChain.selector, uint256(1337)));
        orchestrator.deployEverywhere{value: _fee(2)}(oivConfig, _topology(), dests, GAS_LIMIT);
    }

    /// @dev Explicit-list path skips the local chain, same as the all-configured path — never self-sends.
    function test_deployEverywhere_explicitListSkipsLocalChain() public {
        uint256[] memory dests = new uint256[](2);
        dests[0] = ARBITRUM_CHAIN_ID;
        dests[1] = block.chainid; // local (mainnet); must be dropped, not resolved/self-sent
        (, bytes32[] memory ids) =
            orchestrator.deployEverywhere{value: _fee(1)}(oivConfig, _topology(), dests, GAS_LIMIT);
        assertEq(ids.length, 1, "local chain dropped from explicit list");
        assertEq(router.sentCount(), 1, "only the remote chain dispatched");
    }

    function test_deployEverywhere_revertsOnNoDestinations() public {
        uint256[] memory dests = new uint256[](0);
        vm.expectRevert(CcipOivDeployer.NoDestinations.selector);
        orchestrator.deployEverywhere(oivConfig, _topology(), dests, GAS_LIMIT);
    }

    function test_deployEverywhere_revertsOnInsufficientFee() public {
        uint256[] memory dests = _dests();
        // Aggregate fee across both destinations is checked up front against msg.value.
        vm.expectRevert(abi.encodeWithSelector(CcipOivDeployer.InsufficientFee.selector, 2 * FEE, FEE));
        orchestrator.deployEverywhere{value: FEE}(oivConfig, _topology(), dests, GAS_LIMIT);
    }

    // ── Destination path: ccipReceive ─────────────────────────────────────────────

    /// @dev The load-bearing cross-chain property: a stack deployed via `ccipReceive` (the sidechain
    ///      path) lands at the SAME operational addresses as the mainnet OIV prediction, because the
    ///      orchestrator is the uniform factory caller on every chain.
    function test_ccipReceive_deploysStackMatchingMainnetOivPrediction() public {
        // A fund whose shares live on Optimism, so this chain is a legitimate stack destination.
        // With the local chain in the topology the receiver would (correctly) refuse — see
        // `test_ccipReceive_refusesAStackAimedAtAServiceChain`.
        CcipOivDeployer.SharesChain[] memory remote = new CcipOivDeployer.SharesChain[](1);
        remote[0] = CcipOivDeployer.SharesChain({chainId: OPTIMISM_CHAIN_ID, asset: oivConfig.sharesParams.asset});

        KpkOivFactory.OivInstance memory oivPred = orchestrator.predictOiv(oivConfig, remote);
        _deliver(_messageFor(remote));

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
        orchestrator.configure(address(router), address(link));
    }

    function test_configure_revertsOnZeroRouter() public {
        vm.expectRevert(CcipOivDeployer.ZeroAddress.selector);
        orchestrator.configure(address(0), address(link));
    }

    /// @dev Native fees mean LINK is optional: configuring with a zero linkToken must succeed (it just
    ///      disables the withdrawLink sweep). Lets the orchestrator work on lanes without a LINK token.
    function test_configure_allowsZeroLinkToken() public {
        orchestrator.configure(address(router), address(0));
        assertEq(orchestrator.linkToken(), address(0), "zero linkToken accepted");
        // Deploy still works (fees are native, not LINK).
        uint256[] memory dests = _dests();
        (, bytes32[] memory ids) =
            orchestrator.deployEverywhere{value: _fee(2)}(oivConfig, _topology(), dests, GAS_LIMIT);
        assertEq(ids.length, 2, "deploy works without a LINK token");
    }

    function test_constructor_revertsOnZeroFactory() public {
        vm.expectRevert(CcipOivDeployer.ZeroAddress.selector);
        new CcipOivDeployer(address(this), address(0));
    }

    function test_quoteDeployEverywhere_sumsFees() public view {
        uint256[] memory dests = _dests();
        (uint256 total, uint256[] memory per) =
            orchestrator.quoteDeployEverywhere(oivConfig, _topology(), dests, GAS_LIMIT);
        assertEq(total, 2 * FEE, "total fee");
        assertEq(per[0], FEE, "per[0]");
        assertEq(per[1], FEE, "per[1]");
    }

    // ── dispatchTo (recovery / add-a-chain path) ──────────────────────────────────

    function test_dispatchTo_sendsWithoutLocalDeployOiv() public {
        uint256 instancesBefore = factory.instanceCount();
        uint256[] memory dests = _dests();

        uint256 routerBalBefore = address(router).balance;
        bytes32[] memory ids =
            orchestrator.dispatchTo{value: _fee(dests.length)}(oivConfig, _topology(), dests, GAS_LIMIT);

        // No local OIV was deployed — only CCIP messages went out.
        assertEq(factory.instanceCount(), instancesBefore, "dispatchTo must not deploy a local OIV");
        assertEq(ids.length, 2, "two message ids");
        assertEq(router.sentCount(), 2, "two ccipSend calls");
        assertEq(address(router).balance, routerBalBefore + 2 * FEE, "router did not receive native fees");
        // Payload is the same factory-derived StackConfig as the deploy path.
        (KpkOivFactory.StackConfig memory sent,) = abi.decode(router.lastData(), (KpkOivFactory.StackConfig, uint256[]));
        assertEq(sent.salt, _effSalt(), "salt mismatch");
        assertEq(sent.execRolesMod.finalOwner, oivConfig.admin, "execMod finalOwner mismatch");
    }

    function test_dispatchTo_isPermissionless() public {
        uint256[] memory dests = _dests();
        vm.prank(stranger);
        bytes32[] memory ids =
            orchestrator.dispatchTo{value: _fee(dests.length)}(oivConfig, _topology(), dests, GAS_LIMIT);
        assertEq(ids.length, 2, "non-owner can dispatch");
    }

    function test_dispatchTo_revertsWhenNotConfigured() public {
        CcipOivDeployer fresh = new CcipOivDeployer(address(this), address(factory));
        fresh.setChainSelector(ARBITRUM_CHAIN_ID, ARBITRUM_SELECTOR);
        fresh.setChainSelector(BASE_CHAIN_ID, BASE_SELECTOR);
        uint256[] memory dests = _dests();
        vm.expectRevert(CcipOivDeployer.NotConfigured.selector);
        fresh.dispatchTo(oivConfig, _topology(), dests, GAS_LIMIT);
    }

    /// @dev The recovery / add-a-chain path: after deployEverywhere has run, dispatchTo can fan the
    ///      same fund out to an additional sidechain — without re-running the local deployOiv (which
    ///      would revert on the mainnet CREATE2 collision). (Actual delivery → matching addresses is
    ///      covered by test_ccipReceive_deploysStackMatchingMainnetOivPrediction.)
    function test_dispatchTo_addsNewChainAfterDeployEverywhere() public {
        orchestrator.deployEverywhere{value: _fee(2)}(oivConfig, _topology(), _dests(), GAS_LIMIT); // Arbitrum + Base
        uint256 sentAfterDeploy = router.sentCount();

        uint256[] memory more = new uint256[](1);
        more[0] = OPTIMISM_CHAIN_ID;
        bytes32[] memory ids =
            orchestrator.dispatchTo{value: _fee(more.length)}(oivConfig, _topology(), more, GAS_LIMIT);

        assertEq(ids.length, 1, "one new message");
        assertEq(router.sentCount(), sentAfterDeploy + 1, "dispatchTo adds exactly one more message");
        (KpkOivFactory.StackConfig memory sent,) = abi.decode(router.lastData(), (KpkOivFactory.StackConfig, uint256[]));
        assertEq(sent.salt, _effSalt(), "same fund salt");
    }

    /// @dev The orchestrator's dispatched StackConfig must equal the factory's own deployOiv mapping,
    ///      enforced by both calling factory.oivToStackConfig (single source of truth, finding #3).
    function test_oivToStackConfig_matchesDispatchedPayload() public {
        orchestrator.dispatchTo{value: _fee(2)}(oivConfig, _topology(), _dests(), GAS_LIMIT);
        (KpkOivFactory.StackConfig memory sent,) = abi.decode(router.lastData(), (KpkOivFactory.StackConfig, uint256[]));
        KpkOivFactory.StackConfig memory expected = factory.oivToStackConfig(_effConfig());
        assertEq(abi.encode(sent), abi.encode(expected), "dispatched payload must equal factory mapping");
    }

    function test_withdrawLink_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        orchestrator.withdrawLink(stranger, 1 ether);
    }

    function test_withdrawLink_revertsWithNoLinkTokenWhenUnset() public {
        orchestrator.configure(address(router), address(0)); // native fees, no LINK
        vm.expectRevert(CcipOivDeployer.NoLinkToken.selector);
        orchestrator.withdrawLink(address(this), 1);
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
        orchestrator.deployEverywhere{value: _fee(1)}(oivConfig, _topology(), dests, GAS_LIMIT);
    }

    function test_deployEverywhere_worksAfterRemappingSelector() public {
        // Owner can correct a selector; the new value is what gets used on dispatch.
        orchestrator.setChainSelector(BASE_CHAIN_ID, 99999);
        assertEq(orchestrator.chainSelectorOf(BASE_CHAIN_ID), 99999, "selector not updated");

        uint256[] memory dests = new uint256[](1);
        dests[0] = BASE_CHAIN_ID;
        orchestrator.deployEverywhere{value: _fee(1)}(oivConfig, _topology(), dests, GAS_LIMIT);

        // MockCcipRouter.Sent = (destChainSelector, receiver, data, feeToken, fee).
        (uint64 destSel,,,,) = router.sent(router.sentCount() - 1);
        assertEq(destSel, 99999, "dispatched with the updated selector");
    }

    // ── Enumerable registry + all-configured fan-out ──────────────────────────────

    function test_getChainIds_returnsConfiguredSet() public view {
        uint256[] memory ids = orchestrator.getChainIds();
        assertEq(ids.length, BAKED_CHAINS, "every wired chain is in the set");
        assertEq(orchestrator.getChainIdCount(), BAKED_CHAINS, "count getter agrees");
    }

    function test_setChainSelector_updateDoesNotDuplicate() public {
        orchestrator.setChainSelector(BASE_CHAIN_ID, 12345); // already configured in setUp
        assertEq(orchestrator.getChainIdCount(), BAKED_CHAINS, "update must not grow the set");
        assertEq(orchestrator.chainSelectorOf(BASE_CHAIN_ID), 12345, "selector updated");
    }

    function test_removeChainSelector_shrinksEnumerableSet() public {
        orchestrator.removeChainSelector(BASE_CHAIN_ID);
        assertEq(orchestrator.getChainIdCount(), BAKED_CHAINS - 1, "set shrank");
        uint256[] memory ids = orchestrator.getChainIds();
        for (uint256 i = 0; i < ids.length; i++) {
            assertTrue(ids[i] != BASE_CHAIN_ID, "removed id still present");
        }
        // Remaining chains still resolve.
        assertEq(orchestrator.chainSelectorOf(ARBITRUM_CHAIN_ID), ARBITRUM_SELECTOR);
        assertEq(orchestrator.chainSelectorOf(OPTIMISM_CHAIN_ID), OPTIMISM_SELECTOR);
    }

    function test_deployEverywhere_allConfigured_fansOutToEveryChain() public {
        // No array: fans out to every wired chain except the local one.
        (, bytes32[] memory ids) = orchestrator.deployEverywhere{value: _fee(BAKED_DESTINATIONS)}(oivConfig, GAS_LIMIT);
        assertEq(ids.length, BAKED_DESTINATIONS, "one message per configured chain");
        assertEq(router.sentCount(), BAKED_DESTINATIONS, "dispatched to all configured");
    }

    function test_quoteDeployEverywhere_allConfigured_sumsAllChains() public view {
        (uint256 total, uint256[] memory per) = orchestrator.quoteDeployEverywhere(oivConfig, GAS_LIMIT);
        assertEq(per.length, BAKED_DESTINATIONS, "per-destination length");
        assertEq(total, BAKED_DESTINATIONS * FEE, "total fee across all configured chains");
    }

    function test_deployEverywhere_allConfigured_skipsLocalChain() public {
        // The local chain (fork is mainnet, id 1) is itself baked into the registry, so this is no
        // longer a configuration the test has to create — it is the default, and must not self-send.
        assertEq(orchestrator.chainSelectorOf(block.chainid), MAINNET_SELECTOR, "local chain is baked in");
        assertEq(orchestrator.getChainIdCount(), BAKED_CHAINS, "local chain counted in the set");

        (, bytes32[] memory ids) = orchestrator.deployEverywhere{value: _fee(BAKED_DESTINATIONS)}(oivConfig, GAS_LIMIT);
        assertEq(ids.length, BAKED_DESTINATIONS, "local chain skipped");
        assertEq(router.sentCount(), BAKED_DESTINATIONS, "no self-send");
    }

    function test_deployEverywhere_allConfigured_revertsWhenNoneConfigured() public {
        // "None configured" is no longer a fresh instance's state — it has to be emptied on purpose.
        CcipOivDeployer fresh = new CcipOivDeployer(address(this), address(factory));
        fresh.configure(address(router), address(link));

        uint256[] memory all = fresh.getChainIds();
        for (uint256 i = 0; i < all.length; i++) {
            fresh.removeChainSelector(all[i]);
        }
        assertEq(fresh.getChainIdCount(), 0, "registry emptied");

        vm.expectRevert(abi.encodeWithSelector(CcipOivDeployer.UnknownChain.selector, block.chainid));
        fresh.deployEverywhere{value: 0}(oivConfig, GAS_LIMIT);
    }

    // ── Anti-front-running (config-bound salt) + native sweep ─────────────────────

    /// @dev The High-severity fix: because the orchestrator binds the FULL config into the salt,
    ///      changing any field (here `admin`) changes EVERY deployed address — so a permissionless
    ///      caller cannot front-run a victim's salt and land a fund (with their own admin) at the
    ///      victim's intended addresses.
    function test_predictOiv_differentAdminYieldsDifferentAddresses() public {
        KpkOivFactory.OivInstance memory legit = orchestrator.predictOiv(oivConfig, _topology());

        KpkOivFactory.OivConfig memory attacker = oivConfig; // same salt, different admin
        attacker.admin = makeAddr("attacker");
        KpkOivFactory.OivInstance memory squat = orchestrator.predictOiv(attacker, _topology());

        assertTrue(legit.avatarSafe != squat.avatarSafe, "avatar safe must differ when admin differs");
        assertTrue(legit.execRolesModifier != squat.execRolesModifier, "exec modifier must differ");
        assertTrue(legit.kpkSharesProxy != squat.kpkSharesProxy, "shares proxy must differ");
    }

    /// @dev Determinism: the same config predicts the same addresses (so cross-chain stacks align).
    function test_predictOiv_sameConfigIsStable() public view {
        KpkOivFactory.OivInstance memory a = orchestrator.predictOiv(oivConfig, _topology());
        KpkOivFactory.OivInstance memory b = orchestrator.predictOiv(oivConfig, _topology());
        assertEq(a.avatarSafe, b.avatarSafe);
        assertEq(a.kpkSharesProxy, b.kpkSharesProxy);
    }

    /// @dev Deployed fund must match predictOiv (the config-bound-salt prediction).
    function test_deployEverywhere_matchesPredictOiv() public {
        KpkOivFactory.OivInstance memory predicted = orchestrator.predictOiv(oivConfig, _topology());
        uint256[] memory dests = _dests();
        (KpkOivFactory.OivInstance memory inst,) =
            orchestrator.deployEverywhere{value: _fee(dests.length)}(oivConfig, _topology(), dests, GAS_LIMIT);
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

    /// @dev A payload for a fund whose topology names ONLY mainnet, so a sidechain receiving it is
    ///      not a shares chain and accepts the stack.
    function _validMessage() internal view returns (Client.Any2EVMMessage memory) {
        return _messageFor(_topology());
    }

    /// @dev A delivered message for an explicit topology.
    function _messageFor(CcipOivDeployer.SharesChain[] memory topology)
        internal
        view
        returns (Client.Any2EVMMessage memory)
    {
        KpkOivFactory.OivConfig memory eff = oivConfig;
        eff.sharesParams.asset = address(0);
        eff.salt = uint256(keccak256(abi.encode(eff, topology)));
        eff.sharesParams.asset = oivConfig.sharesParams.asset;

        uint256[] memory ids = new uint256[](topology.length);
        for (uint256 i = 0; i < topology.length; i++) {
            ids[i] = topology[i].chainId;
        }
        return Client.Any2EVMMessage({
            messageId: keccak256("msg"),
            sourceChainSelector: MAINNET_SELECTOR,
            sender: abi.encode(address(orchestrator)),
            data: abi.encode(factory.oivToStackConfig(eff), ids),
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

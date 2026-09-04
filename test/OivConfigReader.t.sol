// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {KpkOivFactory} from "src/KpkOivFactory.sol";
import {OivConfigReader} from "script/base/OivConfigReader.sol";
import {DeployOiv} from "script/DeployOiv.s.sol";
import {CcipOivDeployer} from "src/CcipOivDeployer.sol";
import {TimelockParams} from "src/interfaces/IKpkTimelockDeployer.sol";

/// @dev Exposes the reader's internals. The reader is `abstract` and its helpers are `internal`, so
///      without this the only way to observe a parse would be a full fork deployment.
contract ReaderHarness is OivConfigReader {
    function oivConfig(string memory json) external view returns (KpkOivFactory.OivConfig memory) {
        return _buildOivConfig(json);
    }

    function stackConfig(string memory json) external view returns (KpkOivFactory.StackConfig memory) {
        return _buildStackConfig(json);
    }

    function sharesChains(string memory json) external view returns (CcipOivDeployer.SharesChain[] memory) {
        return _buildSharesChains(json);
    }

    function shouldDeployShares(string memory json) external view returns (bool) {
        return _shouldDeployShares(json);
    }

    function timelockParams(string memory json, string memory key) external view returns (TimelockParams memory) {
        return _readTimelockParams(json, key);
    }
}

/// @notice Pins that the deploy path actually carries the timelock, per-chain asset and chain
///         selection into the factory's structs.
///
///         Every one of these would have passed vacuously before: the reader built the structs field
///         by field and simply never assigned the timelock fields, so they stayed zero — and
///         `minDelay == 0` is the factory's "no timelock" sentinel. A fund the operator believed was
///         timelocked deployed with `admin` holding total control, with no error and no warning.
contract OivConfigReaderTest is Test {
    ReaderHarness reader;
    string json;

    address constant GOV = 0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537;
    address constant SUPERADMIN = 0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72;
    address constant VETO = 0x6F2A3D35Ff275d6B76dB47eFB0Da1b2358daf11b;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant GNOSIS_ASSET = 0x2a22f9c3b484c3629090FeED35F17Ff8F88f76F0;

    function setUp() public {
        reader = new ReaderHarness();
        json = vm.readFile("script/oiv-config.example.json");
    }

    function test_oivConfig_carriesBothTimelocks() public view {
        KpkOivFactory.OivConfig memory c = reader.oivConfig(json);

        assertEq(c.execTimelock.minDelay, 2 days, "exec delay");
        assertEq(c.execTimelock.proposers.length, 2, "exec proposers");
        assertEq(c.execTimelock.proposers[0], GOV);
        assertEq(c.execTimelock.proposers[1], SUPERADMIN);
        assertEq(c.execTimelock.cancellers.length, 1, "exec cancellers");
        assertEq(c.execTimelock.cancellers[0], VETO);

        assertEq(c.sharesTimelock.minDelay, 7 days, "shares delay");
        assertEq(c.sharesTimelock.cancellers[0], VETO, "shares canceller");
    }

    /// @dev The sidechain payload must read the SAME block as the mainnet one, or the timelock lands
    ///      at a different address there — its address is a function of these parameters.
    function test_stackConfig_carriesTheSameExecTimelock() public view {
        KpkOivFactory.OivConfig memory oiv = reader.oivConfig(json);
        KpkOivFactory.StackConfig memory stack = reader.stackConfig(json);

        assertEq(stack.execTimelock.minDelay, oiv.execTimelock.minDelay, "delay must match");
        assertEq(stack.execTimelock.proposers.length, oiv.execTimelock.proposers.length, "proposers must match");
        assertEq(stack.execTimelock.cancellers[0], oiv.execTimelock.cancellers[0], "cancellers must match");
    }

    function test_asset_usesThePerChainOverrideWhenPresent() public {
        vm.chainId(1);
        assertEq(reader.oivConfig(json).sharesParams.asset, USDC, "mainnet falls back to the default asset");

        vm.chainId(100);
        assertEq(reader.oivConfig(json).sharesParams.asset, GNOSIS_ASSET, "gnosis uses its override");

        vm.chainId(42161);
        assertEq(reader.oivConfig(json).sharesParams.asset, USDC, "a chain with no override falls back");
    }

    function test_sharesChains_selectsWhichChainsGetShares() public {
        vm.chainId(1);
        assertTrue(reader.shouldDeployShares(json), "mainnet is listed");
        vm.chainId(100);
        assertTrue(reader.shouldDeployShares(json), "gnosis is listed");
        vm.chainId(42161);
        assertFalse(reader.shouldDeployShares(json), "arbitrum is not listed - stack only");
    }

    /// @notice The CCIP path must NOT default the topology to "the chain this happens to run on":
    ///         that makes the salt origin-dependent, which is the very defect the salt-bound topology
    ///         exists to remove. The direct factory path has no such problem and keeps its default.
    function test_buildSharesChains_requiresAnExplicitTopology() public {
        string memory legacy = vm.readFile("script/ccip-test-fund-config.json");
        vm.expectRevert(
            bytes(
                "config: .sharesChains is required for the CCIP path - a per-chain default would make the salt origin-dependent"
            )
        );
        reader.sharesChains(legacy);
    }

    /// @dev A config predating these fields must keep deploying exactly as it did.
    function test_absentBlocksMeanNoTimelockAndNoRestriction() public {
        string memory legacy = vm.readFile("script/ccip-test-fund-config.json");
        KpkOivFactory.OivConfig memory c = reader.oivConfig(legacy);

        assertEq(c.execTimelock.minDelay, 0, "absent block is the no-timelock sentinel");
        assertEq(c.sharesTimelock.minDelay, 0, "absent block is the no-timelock sentinel");
        assertEq(c.execTimelock.proposers.length, 0);
        vm.chainId(42161);
        assertTrue(reader.shouldDeployShares(legacy), "absent sharesChains leaves the choice to the caller");
    }

    // ── Malformed-config guards ─────────────────────────────────────────────────
    //
    // Each of these rejections previously had no test, so any of them could have been deleted
    // without a failure — which for a parser is the same as not having it: the whole point is that a
    // wrong config is refused rather than deployed.

    /// @dev The guard this PR added. `minDelay` is the factory's "no timelock" sentinel, so a block
    ///      present without it means the operator asked for governance and silently got none.
    function test_timelock_revertsWhenMinDelayKeyIsMissing() public {
        string memory bad = '{"oiv":{"execTimelock":{"proposers":["0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537"]}}}';
        vm.expectRevert(
            bytes("config: .oiv.execTimelock exists but has no minDelay - a timelock would be silently skipped")
        );
        reader.timelockParams(bad, ".oiv.execTimelock");
    }

    /// @dev Same silent skip, expressed as a value rather than an omission — a placeholder left
    ///      unfilled, or seconds/days confused.
    function test_timelock_revertsWhenMinDelayIsZero() public {
        string memory bad =
            '{"oiv":{"execTimelock":{"minDelay":0,"proposers":["0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537"]}}}';
        vm.expectRevert(
            bytes("config: .oiv.execTimelock.minDelay is 0 - omit the block entirely to deploy without a timelock")
        );
        reader.timelockParams(bad, ".oiv.execTimelock");
    }

    /// @dev A MISSING `proposers` key parsed as zero proposers, and zero proposers is a timelock that
    ///      can never schedule anything — whatever it governs is frozen with no recovery. So a typo
    ///      like "proposer" bricked the fund at deploy time with no error.
    function test_timelock_revertsWhenProposersKeyIsMissing() public {
        string memory bad = '{"oiv":{"execTimelock":{"minDelay":172800,"cancellers":[]}}}';
        // The MESSAGE is pinned, not merely the revert: without the ternary default a missing key
        // reaches `readAddressArray` and reverts on its own, so a bare `expectRevert` would pass with
        // the guard deleted and assert nothing about it. What the guard adds is an operator-legible
        // reason in place of a raw stdJson parse failure.
        vm.expectRevert(
            bytes(
                "config: .oiv.execTimelock exists but has no proposers - state [] explicitly to accept a frozen timelock"
            )
        );
        reader.timelockParams(bad, ".oiv.execTimelock");
    }

    /// @dev But an EXPLICITLY empty list stays legal: zero proposers is a permitted choice on-chain,
    ///      and the factory deliberately imposes no floor. The guard above distinguishes a choice
    ///      from an omission, which is the whole distinction it exists to draw.
    function test_timelock_allowsAnExplicitlyEmptyProposerList() public view {
        string memory ok = '{"oiv":{"execTimelock":{"minDelay":172800,"proposers":[],"cancellers":[]}}}';
        TimelockParams memory p = reader.timelockParams(ok, ".oiv.execTimelock");
        assertEq(p.minDelay, 2 days, "delay parsed");
        assertEq(p.proposers.length, 0, "an empty list is accepted as stated");
    }

    /// @dev `.execRolesModFinalOwner` and `.oiv.admin` describe the same role — the factory derives
    ///      `finalOwner := admin`. Because `deploy` picks either branch per chain from one config,
    ///      letting them differ would leave the stack-only chains under a different exec-modifier
    ///      owner than the shares chains, with every address still matching.
    function test_stackConfig_revertsWhenFinalOwnerDisagreesWithAdmin() public {
        string memory bad = string.concat(
            '{"managerSafe":{"owners":["',
            vm.toString(GOV),
            '"],"threshold":1},',
            '"execRolesModFinalOwner":"',
            vm.toString(GOV),
            '",',
            '"salt":42,"oiv":{"admin":"',
            vm.toString(SUPERADMIN),
            '"}}'
        );
        vm.expectRevert(bytes("config: .execRolesModFinalOwner must equal .oiv.admin - they are the same role"));
        reader.stackConfig(bad);
    }

    /// @dev And agreeing is accepted, so the guard is not simply rejecting everything.
    function test_stackConfig_acceptsAgreeingOwnerAndAdmin() public view {
        string memory ok = string.concat(
            '{"managerSafe":{"owners":["',
            vm.toString(GOV),
            '"],"threshold":1},',
            '"execRolesModFinalOwner":"',
            vm.toString(SUPERADMIN),
            '",',
            '"salt":42,"oiv":{"admin":"',
            vm.toString(SUPERADMIN),
            '"}}'
        );
        KpkOivFactory.StackConfig memory c = reader.stackConfig(ok);
        assertEq(c.execRolesMod.finalOwner, SUPERADMIN, "owner carried through");
    }

    /// @notice Script-level coverage for the auto-branching entry point, which the helper tests
    ///         cannot give: `_shouldDeployShares` answers "true" for a config with no
    ///         `.sharesChains`, which is the right default for the explicit `deployOiv` /
    ///         `deployStack` paths and the wrong one for `deploy`. Run across 19 chains with a
    ///         silent config — and the repo ships one, `script/ccip-test-fund-config.json` — it
    ///         would have put a live shares token on every chain, which is precisely the outcome
    ///         chain selection exists to prevent. The guard fires before any broadcast.
    function test_deploy_refusesAConfigThatDoesNotSayWhichChainsGetShares() public {
        DeployOiv script = new DeployOiv();
        string memory path = "script/ccip-test-fund-config.json";

        // Guard the premise: if this file ever gains a `.sharesChains` key, this test would pass
        // vacuously, so assert the condition it depends on.
        assertFalse(vm.keyExists(vm.readFile(path), ".sharesChains"), "fixture must have no .sharesChains");

        vm.expectRevert(
            bytes(
                "config: deploy(configPath) requires .sharesChains - use deployOiv or deployStack to choose per chain"
            )
        );
        script.deploy(path);
    }

    /// @notice The other half of the branch contract: `deployOiv` must refuse a chain the topology
    ///         does not list, rather than quietly creating a shares token nobody asked for. Like the
    ///         test above, this fires before any broadcast, so it needs no RPC.
    function test_deployOiv_refusesAChainOutsideTheTopology() public {
        DeployOiv script = new DeployOiv();

        // The example config declares [1, 100]; assert this chain really is outside it, so the test
        // cannot pass for the wrong reason if the fixture changes.
        assertFalse(reader.shouldDeployShares(json), "this chain must be outside the example topology");

        vm.expectRevert(bytes("config: this chain is not in .sharesChains - use deployStack, or fix the config"));
        script.deployOiv("script/oiv-config.example.json");
    }
}

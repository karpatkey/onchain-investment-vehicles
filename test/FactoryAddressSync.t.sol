// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {DeployOiv} from "script/DeployOiv.s.sol";
import {OivChainDeploy} from "script/base/OivChainDeploy.sol";

/// @notice Pins the hardcoded factory address in the fund-deploy script to the address the infra
///         deploy path actually produces.
/// @dev    `script/DeployOiv.s.sol` hardcodes `FACTORY` because it has no access to the deployer
///         EOA at prediction time, while `script/base/OivChainDeploy.sol` derives the same address
///         from the factory's creation code. Nothing connected the two, so the constant silently
///         rotted: it sat at `LEGACY_FACTORY` (`0x0d94…d420`, the pre-v2.1.1 build embedding the
///         vulnerable Roles Modifier v2.1.0) straight through the salt-v2 rollout. Any fund
///         deployed with that script would have been built on the vulnerable factory.
///
///         Asserting the two agree turns "the factory bytecode changed and someone forgot to update
///         the constant" — which is guaranteed to happen again, since the address is a function of
///         the bytecode — into a CI failure rather than a production incident. The constant is read
///         off a real `DeployOiv` instance, not mirrored here, so the test cannot pass against a
///         stale copy of itself.
contract FactoryAddressSyncTest is Test, OivChainDeploy {
    /// @dev The deployer EOA every production rollout has used. It is baked into the factory's
    ///      constructor args and therefore into its CREATE2 address, so the prediction is only
    ///      meaningful for this account.
    address internal constant CANONICAL_EOA_OWNER = 0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72;

    DeployOiv internal deployScript;

    function setUp() public {
        deployScript = new DeployOiv();
    }

    function test_deployOivFactoryConstantMatchesDeployPath() public view {
        assertEq(
            deployScript.FACTORY(),
            _predictFactory(CANONICAL_EOA_OWNER),
            "DeployOiv.FACTORY does not match the address OivChainDeploy would deploy - update the constant"
        );
    }

    /// @dev The fund-deploy script must never point at the abandoned pre-v2.1.1 build.
    function test_deployOivFactoryConstantIsNotTheLegacyFactory() public view {
        assertTrue(
            deployScript.FACTORY() != LEGACY_FACTORY,
            "DeployOiv.FACTORY points at the legacy factory (vulnerable Roles Modifier v2.1.0)"
        );
    }

    // ── Documented salt-v4 predictions ─────────────────────────────────────────
    //
    // GENERATION NOTE. These are salt-v4 values and are NOT DEPLOYED ANYWHERE YET. Adding the
    // timelock arguments to `deployOiv` changed `KpkOivFactory`'s runtime, which moved its CREATE2
    // address, which moved `KpkSharesDeployer` (factory address is a constructor argument) and
    // `CcipOivDeployer` (factory address is an immutable) with it. The salts were bumped 3 -> 4 to
    // make the generation explicit. Re-derive from a FRESH CLONE before the rollout — a drifted
    // working tree silently produces different bytecode and therefore different addresses.
    //
    // docs/DEPLOYED_ADDRESSES.md publishes all three predicted addresses, but only the factory was
    // pinned — and all three shipped stale once already, moved by a metadata-hash change from a
    // NatSpec edit. These pin the other two so the published table cannot rot silently before a
    // 19-chain rollout. When they fail, re-derive from a CLEAN CLONE (a drifted working tree
    // produces different values) and update both the constants here and the doc table.

    address internal constant DOCUMENTED_SHARES_DEPLOYER = 0x1f5a33DdAC720874664d13a7804Cd1c43A33Ba41;
    address internal constant DOCUMENTED_ORCHESTRATOR = 0x918E20DC102424364A72be3d9341C34f74Dbc556;

    /// @dev `KpkTimelockDeployer` takes no constructor arguments, so unlike the other three its
    ///      address is independent of the deployer EOA — the same on every chain for anyone.
    address internal constant DOCUMENTED_TIMELOCK_DEPLOYER = 0x0F21F72dA90F61D29fBF98dA31C51C871815d129;

    function test_documentedSharesDeployerAddressMatchesDeployPath() public pure {
        address factory = _predictFactory(CANONICAL_EOA_OWNER);
        assertEq(
            _create2Address(SALT_DEPLOYER, _deployerInitCode(factory)),
            DOCUMENTED_SHARES_DEPLOYER,
            "KpkSharesDeployer prediction drifted from docs/DEPLOYED_ADDRESSES.md - re-derive from a clean clone"
        );
    }

    function test_documentedOrchestratorAddressMatchesDeployPath() public pure {
        address factory = _predictFactory(CANONICAL_EOA_OWNER);
        assertEq(
            _create2Address(SALT_CCIP, _orchestratorInitCode(CANONICAL_EOA_OWNER, factory)),
            DOCUMENTED_ORCHESTRATOR,
            "CcipOivDeployer prediction drifted from docs/DEPLOYED_ADDRESSES.md - re-derive from a clean clone"
        );
    }

    function test_documentedTimelockDeployerAddressMatchesDeployPath() public pure {
        assertEq(
            DOCUMENTED_TIMELOCK_DEPLOYER,
            _predictTimelockDeployer(),
            "KpkTimelockDeployer prediction drifted - re-derive from a clean clone"
        );
    }
}

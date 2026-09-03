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

    address internal constant DOCUMENTED_SHARES_MASTERCOPY = 0x729Fb58a61a6f8349657fBc9f17BA4D36C9e72fC;
    address internal constant DOCUMENTED_TIMELOCK_MASTERCOPY = 0x9760280fED9e760668186334f88b6d763A7d976E;
    address internal constant DOCUMENTED_ORCHESTRATOR = 0xf355E4E73daA5B7CA8BB99BdD071755f32C0B6e3;

    /// @dev The two mastercopies take no constructor arguments and `KpkTimelockDeployer`'s only
    ///      argument is one of them, so unlike the factory and orchestrator these three are
    ///      independent of the deployer EOA — the same on every chain for anyone.
    address internal constant DOCUMENTED_TIMELOCK_DEPLOYER = 0x55A36009e4cf19FF8F92cE071afCb94B27f5E4Fc;

    function test_documentedSharesMastercopyAddressMatchesDeployPath() public pure {
        assertEq(
            _create2Address(SALT_SHARES_MASTERCOPY, _sharesMastercopyInitCode()),
            DOCUMENTED_SHARES_MASTERCOPY,
            "KpkShares mastercopy prediction drifted from docs/DEPLOYED_ADDRESSES.md - re-derive from a clean clone"
        );
    }

    function test_documentedTimelockMastercopyAddressMatchesDeployPath() public pure {
        assertEq(
            _create2Address(SALT_TIMELOCK_MASTERCOPY, _timelockMastercopyInitCode()),
            DOCUMENTED_TIMELOCK_MASTERCOPY,
            "Timelock mastercopy prediction drifted from docs/DEPLOYED_ADDRESSES.md - re-derive from a clean clone"
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

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
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {OivChainDeploy} from "../script/base/OivChainDeploy.sol";
import {OivInfraConstants} from "src/OivInfraConstants.sol";

/// @dev Exposes the internal onboarding helpers so the replay can be exercised without a broadcast.
contract RolesBootstrapHarness is OivChainDeploy {
    function initCode() external view returns (bytes memory) {
        return _rolesModifierInitCode();
    }

    function ensure() external {
        _ensureRolesMastercopy();
    }

    function singletonFactory() external pure returns (address) {
        return SINGLETON_FACTORY;
    }

    function codehash() external pure returns (bytes32) {
        return ROLES_MODIFIER_CODEHASH;
    }
}

/// @title  RolesMastercopyBootstrapTest
/// @notice Pins the data file that lets a chain without the patched Roles v2.1.1 mastercopy be
///         onboarded (X Layer is the first). The blob in `script/data/roles-modifier-v2.1.1.json` is
///         the only thing standing between "deploy the canonical mastercopy" and "deploy a stranger's
///         contract at an address the factory clones for every fund", so it is checked three ways:
///         it must hash to the pin, the pin must reproduce the canonical ADDRESS through the EIP-2470
///         SingletonFactory, and deploying it must yield the canonical RUNTIME — neutered.
contract RolesMastercopyBootstrapTest is Test {
    RolesBootstrapHarness internal harness;

    function setUp() public {
        harness = new RolesBootstrapHarness();
    }

    /// @dev The address is `CREATE2(SingletonFactory, salt 0, keccak(initCode))`, so this is the
    ///      check that couples the data file to `OivInfraConstants.ROLES_MODIFIER_MASTERCOPY`:
    ///      substituting the blob moves the address and fails here, before any chain sees it.
    function test_pinnedInitCodeReproducesTheCanonicalAddress() public view {
        bytes memory initCode = harness.initCode(); // reverts unless it matches the pinned hash
        address predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), harness.singletonFactory(), bytes32(0), keccak256(initCode))
                    )
                )
            )
        );
        assertEq(
            predicted,
            OivInfraConstants.ROLES_MODIFIER_MASTERCOPY,
            "pinned Roles creation code no longer reproduces the canonical mastercopy address"
        );
    }

    /// @dev Deploy the blob for real (plain CREATE — the factory only fixes the address) and assert
    ///      the runtime is the one `deploy-chain.sh` asserts on-chain, and that the mastercopy is born
    ///      neutered: owner/avatar/target == address(1). A build whose constructor left a live owner
    ///      would be a Roles Modifier under someone else's control at a kpk-published address.
    function test_pinnedInitCodeDeploysTheCanonicalNeuteredRuntime() public {
        bytes memory initCode = harness.initCode();
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        assertTrue(deployed != address(0), "Roles creation code failed to deploy");
        assertEq(deployed.codehash, harness.codehash(), "deployed runtime is not the canonical mastercopy runtime");

        assertEq(_addr(deployed, "owner()"), address(1), "mastercopy owner is not address(1)");
        assertEq(_addr(deployed, "avatar()"), address(1), "mastercopy avatar is not address(1)");
        assertEq(_addr(deployed, "target()"), address(1), "mastercopy target is not address(1)");
    }

    /// @dev End-to-end on the chain this exists for: X Layer has the SingletonFactory but not the
    ///      mastercopy, so the preflight must land it at the canonical address through a real
    ///      EIP-2470 call. Skipped when XLAYER_URL is unset (same convention as DeployedKitSync).
    function test_preflightOnboardsTheMastercopyOnXLayer() public {
        try vm.envString("XLAYER_URL") returns (string memory url) {
            vm.createSelectFork(url);
        } catch {
            vm.skip(true);
        }
        assertEq(block.chainid, 196, "XLAYER_URL does not point at X Layer (196)");
        assertEq(
            OivInfraConstants.ROLES_MODIFIER_MASTERCOPY.code.length,
            0,
            "mastercopy already on X Layer - the onboarding path this test covers is spent"
        );

        harness = new RolesBootstrapHarness();
        harness.ensure();

        assertEq(
            OivInfraConstants.ROLES_MODIFIER_MASTERCOPY.codehash,
            harness.codehash(),
            "preflight did not land the canonical mastercopy on X Layer"
        );
    }

    function _addr(address target, string memory sig) internal view returns (address) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(sig));
        require(ok, string.concat("staticcall failed: ", sig));
        return abi.decode(ret, (address));
    }
}

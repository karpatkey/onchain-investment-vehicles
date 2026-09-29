// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {KpkOivFactory} from "src/KpkOivFactory.sol";
import {OivChainDeploy} from "../script/base/OivChainDeploy.sol";

/// @dev Exposes the factory's internal `EXPECTED_EMPTY_CODEHASH` for cross-checking. The constructor
///      rejects a zero OR codeless value for all EIGHT infrastructure arguments, so every placeholder
///      below has to be a real contract — an earlier version of this comment said they "only need to
///      be non-zero", which is why the `Coded` stub exists at all.
/// @dev Smallest thing with code. Used for all eight infrastructure args, not two.
contract Coded {}

contract FactoryCodehashExposer is KpkOivFactory {
    constructor()
        KpkOivFactory(
            // Nine args: owner, then the six Safe/Zodiac infra addresses, then the shares mastercopy
            // and timelock deployer (constructor-mandatory, no setters). The constructor rejects a
            // CODELESS value for all eight infra args, so every one gets a real (empty) contract.
            // This exposer never calls any of them.
            address(new Coded()), // owner
            address(new Coded()), // safeProxyFactory
            address(new Coded()), // safeSingleton
            address(new Coded()), // safeModuleSetup
            address(new Coded()), // safeFallbackHandler
            address(new Coded()), // moduleProxyFactory
            address(new Coded()), // rolesModifierMastercopy
            address(new Coded()), // kpkSharesMastercopy
            address(new Coded()) //  timelockDeployer
        )
    {}

    function expectedEmptyCodehash() external pure returns (bytes32) {
        return EXPECTED_EMPTY_CODEHASH;
    }
}

/// @dev Exposes the deploy tooling's canonical `Empty` runtime + create-calldata for cross-checking.
contract EmptyRuntimeExposer is OivChainDeploy {
    function canonicalEmptyCodehash() external pure returns (bytes32) {
        return keccak256(EMPTY_RUNTIME);
    }

    function createCalldata() external pure returns (bytes memory) {
        return EMPTY_CREATE_CALLDATA;
    }

    /// @dev True iff the canonical `Empty` runtime appears verbatim inside the create-calldata, so the
    ///      two constants (and thus the bytes actually deployed on-chain) cannot drift independently.
    function calldataEmbedsRuntime() external pure returns (bool) {
        bytes memory hay = EMPTY_CREATE_CALLDATA;
        bytes memory needle = EMPTY_RUNTIME;
        if (needle.length == 0 || hay.length < needle.length) return false;
        for (uint256 i = 0; i <= hay.length - needle.length; i++) {
            bool matched = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (hay[i + j] != needle[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }
}

/// @title  EmptyCodehashSyncTest
/// @notice Fork-independent guards against drift between the copies of the canonical `Empty` bytecode:
///         the codehash `KpkOivFactory` asserts at deploy time (`EXPECTED_EMPTY_CODEHASH`), the runtime
///         the deploy tooling reproduces (`OivChainDeploy.EMPTY_RUNTIME`), the create-calldata that
///         actually lands it (`EMPTY_CREATE_CALLDATA`), and the registry's copy of that calldata
///         (`script/ccip-networks.json:infra.emptyDeployCalldata`). If any one is edited without the
///         others, `deployOiv`/`deployStack` (incl. CCIP `ccipReceive`) would revert
///         `EmptyContractMissing` at runtime — these tests fail in CI first instead.
contract EmptyCodehashSyncTest is Test {
    /// @dev Factory's baked codehash == keccak256 of the runtime the deploy tooling reproduces.
    function test_factoryExpectedCodehashMatchesCanonicalEmptyRuntime() public {
        bytes32 fromFactory = new FactoryCodehashExposer().expectedEmptyCodehash();
        bytes32 fromRuntime = new EmptyRuntimeExposer().canonicalEmptyCodehash();
        assertEq(fromFactory, fromRuntime, "EXPECTED_EMPTY_CODEHASH out of sync with OivChainDeploy.EMPTY_RUNTIME");
    }

    /// @dev The runtime embedded in the create-calldata == the standalone EMPTY_RUNTIME constant, so the
    ///      bytes deployed on-chain match the runtime the codehash is derived from.
    function test_deployCalldataEmbedsCanonicalRuntime() public {
        assertTrue(
            new EmptyRuntimeExposer().calldataEmbedsRuntime(),
            "EMPTY_CREATE_CALLDATA does not embed EMPTY_RUNTIME verbatim"
        );
    }

    /// @dev The registry's `infra.emptyDeployCalldata` == the deploy script's `EMPTY_CREATE_CALLDATA`.
    function test_registryCalldataMatchesDeployScript() public {
        bytes memory fromScript = new EmptyRuntimeExposer().createCalldata();
        bytes memory fromRegistry =
            vm.parseJsonBytes(vm.readFile("script/ccip-networks.json"), ".infra.emptyDeployCalldata");
        assertEq(
            keccak256(fromRegistry),
            keccak256(fromScript),
            "ccip-networks.json emptyDeployCalldata out of sync with OivChainDeploy.EMPTY_CREATE_CALLDATA"
        );
    }
}

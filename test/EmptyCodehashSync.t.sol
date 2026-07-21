// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {KpkOivFactory} from "src/KpkOivFactory.sol";
import {OivChainDeploy} from "../script/base/OivChainDeploy.sol";

/// @dev Exposes the factory's internal `EXPECTED_EMPTY_CODEHASH` for cross-checking. Constructor args
///      only need to be non-zero (never called), so placeholders suffice.
contract FactoryCodehashExposer is KpkOivFactory {
    constructor()
        KpkOivFactory(
            address(0x1),
            address(0x2),
            address(0x3),
            address(0x4),
            address(0x5),
            address(0x6),
            address(0x7),
            address(0x8)
        )
    {}

    function expectedEmptyCodehash() external pure returns (bytes32) {
        return EXPECTED_EMPTY_CODEHASH;
    }
}

/// @dev Exposes the hash of the canonical `Empty` runtime the deploy tooling actually lands.
contract EmptyRuntimeExposer is OivChainDeploy {
    function canonicalEmptyCodehash() external pure returns (bytes32) {
        return keccak256(EMPTY_RUNTIME);
    }
}

/// @title  EmptyCodehashSyncTest
/// @notice Fork-independent guard against drift between the two authoritative copies of the canonical
///         `Empty` bytecode: the codehash `KpkOivFactory` asserts against at deploy time
///         (`EXPECTED_EMPTY_CODEHASH`) and the runtime the deploy tooling reproduces
///         (`OivChainDeploy.EMPTY_RUNTIME`). If `Empty` is ever recompiled and only one side updated,
///         every `deployOiv`/`deployStack` (incl. CCIP `ccipReceive`) would revert `EmptyContractMissing`
///         at runtime — this test fails in CI first instead.
contract EmptyCodehashSyncTest is Test {
    function test_factoryExpectedCodehashMatchesCanonicalEmptyRuntime() public {
        bytes32 fromFactory = new FactoryCodehashExposer().expectedEmptyCodehash();
        bytes32 fromRuntime = new EmptyRuntimeExposer().canonicalEmptyCodehash();
        assertEq(fromFactory, fromRuntime, "EXPECTED_EMPTY_CODEHASH out of sync with OivChainDeploy.EMPTY_RUNTIME");
    }
}

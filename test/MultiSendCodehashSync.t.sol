// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {KpkOivFactoryHarness} from "test/KpkOivFactory.t.sol";
import {OivChainDeploy} from "script/base/OivChainDeploy.sol";
import {OivInfraConstants} from "src/OivInfraConstants.sol";

/// @notice Pins the MultiSend-unwrapping codehash constants that exist in TWO places.
/// @dev    `KpkOivFactory` asserts them at fund-deploy time; `OivChainDeploy` asserts them at infra
///         preflight. The script-side copies were hand-transcribed and nothing read them, so a typo
///         or a one-sided update (say, when Safe redeploys MultiSend) would leave CI fully green and
///         only surface at broadcast, aborting every per-chain deploy with "MultiSend
///         missing/non-canonical on this chain" — or, worse, accepting a value the factory rejects.
///
///         The comparison is against the constants the FACTORY actually compiles in, read through
///         `KpkOivFactoryHarness`, not against a third transcription of the same literals — a sync
///         test that mirrors the value it is checking proves nothing. The factory side is in turn
///         tied to real chain code by `KpkOivFactoryTest.test_multiSendConstantsMatchOnChainCode`,
///         so the chain → factory → script chain is complete.
///
///         This file is fork-independent and needs no RPC: the harness is deployed with dummy infra
///         addresses because only its `pure` constant accessor is used.
contract MultiSendCodehashSyncTest is Test, OivChainDeploy {
    KpkOivFactoryHarness internal harness;

    function setUp() public {
        harness = new KpkOivFactoryHarness(
            address(this), address(1), address(2), address(3), address(4), address(5), address(6), address(7), address(8)
        );
    }

    function test_scriptCodehashConstantsMatchFactory() public view {
        (bytes32 multiSend, bytes32 callsOnly, bytes32 unwrapper) = harness.exposed_expectedMultiSendCodehashes();

        assertEq(
            MULTI_SEND_CODEHASH,
            multiSend,
            "OivChainDeploy.MULTI_SEND_CODEHASH drifted from KpkOivFactory.EXPECTED_MULTI_SEND_CODEHASH"
        );
        assertEq(
            MULTI_SEND_CALLS_ONLY_CODEHASH,
            callsOnly,
            "OivChainDeploy.MULTI_SEND_CALLS_ONLY_CODEHASH drifted from the factory's constant"
        );
        assertEq(
            MULTISEND_UNWRAPPER_CODEHASH,
            unwrapper,
            "OivChainDeploy.MULTISEND_UNWRAPPER_CODEHASH drifted from the factory's constant"
        );
    }

    /// @dev The addresses must agree too — a codehash pinned to the wrong address proves nothing.
    function test_scriptAddressesMatchInfraConstants() public pure {
        assertEq(MULTI_SEND, OivInfraConstants.MULTI_SEND, "MULTI_SEND drift");
        assertEq(MULTI_SEND_CALLS_ONLY, OivInfraConstants.MULTI_SEND_CALLS_ONLY, "MULTI_SEND_CALLS_ONLY drift");
        assertEq(MULTISEND_UNWRAPPER, OivInfraConstants.MULTISEND_UNWRAPPER, "MULTISEND_UNWRAPPER drift");
    }
}

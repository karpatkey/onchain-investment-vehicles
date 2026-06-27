// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OivChainDeploy} from "../base/OivChainDeploy.sol";

/// @title  Deploy_Mantle
/// @notice Per-chain OIV infra deploy for mantle (chainId 5000, verdict READY-AFTER-EMPTY).
///         Runs Empty preflight -> KpkOivFactory + KpkSharesDeployer -> CcipOivDeployer (+configure),
///         all deterministic. CCIP router/LINK below were resolved + verified on-chain and are kept
///         in sync with script/ccip-networks.json by test/CcipNetworksSync.t.sol; CHAIN_ID is guarded
///         against block.chainid in _runChain so a wrong --rpc-url cannot misconfigure the orchestrator.
///
/// Usage:
///   source .env && forge script script/chains/Deploy_Mantle.s.sol:Deploy_Mantle \
///     --rpc-url mantle --private-key $PRIVATE_KEY --broadcast \
///     --sig "run(address,address)" <eoaOwner> <finalOwner>
contract Deploy_Mantle is OivChainDeploy {
    uint256 public constant CHAIN_ID = 5000;
    address public constant CCIP_ROUTER = 0x670052635a9850bb45882Cb2eCcF66bCff0F41B7;
    address public constant LINK_TOKEN = 0xfe36cF0B43aAe49fBc5cFC5c0AF22a623114E043;

    function run(address eoaOwner, address finalOwner) external {
        _runChain(CHAIN_ID, eoaOwner, finalOwner, CCIP_ROUTER, LINK_TOKEN);
    }
}

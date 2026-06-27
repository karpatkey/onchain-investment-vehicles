// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OivChainDeploy} from "../base/OivChainDeploy.sol";

/// @title  Deploy_Ethereum
/// @notice Per-chain OIV infra deploy for ethereum (chainId 1, verdict READY).
///         Runs Empty preflight -> KpkOivFactory + KpkSharesDeployer -> CcipOivDeployer (+configure),
///         all deterministic. CCIP router/LINK below were resolved + verified on-chain and are kept
///         in sync with script/ccip-networks.json by test/CcipNetworksSync.t.sol; CHAIN_ID is guarded
///         against block.chainid in _runChain so a wrong --rpc-url cannot misconfigure the orchestrator.
///
/// Usage:
///   source .env && forge script script/chains/Deploy_Ethereum.s.sol:Deploy_Ethereum \
///     --rpc-url ethereum --private-key $PRIVATE_KEY --broadcast \
///     --sig "run(address,address)" <eoaOwner> <finalOwner>
contract Deploy_Ethereum is OivChainDeploy {
    uint256 public constant CHAIN_ID = 1;
    address public constant CCIP_ROUTER = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D;
    address public constant LINK_TOKEN = 0x514910771AF9Ca656af840dff83E8264EcF986CA;

    function run(address eoaOwner, address finalOwner) external {
        _runChain(CHAIN_ID, eoaOwner, finalOwner, CCIP_ROUTER, LINK_TOKEN);
    }
}

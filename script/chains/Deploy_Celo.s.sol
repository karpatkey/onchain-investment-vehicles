// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OivChainDeploy} from "../base/OivChainDeploy.sol";

/// @title  Deploy_Celo
/// @notice Per-chain OIV infra deploy for celo (chainId 42220, verdict READY-AFTER-EMPTY).
///         Runs Empty preflight -> KpkOivFactory + KpkSharesDeployer -> CcipOivDeployer (+configure),
///         all deterministic. CCIP router/LINK below were resolved + verified on-chain and are kept
///         in sync with script/ccip-networks.json by test/CcipNetworksSync.t.sol; CHAIN_ID is guarded
///         against block.chainid in _runChain so a wrong --rpc-url cannot misconfigure the orchestrator.
///
/// Usage:
///   source .env && forge script script/chains/Deploy_Celo.s.sol:Deploy_Celo \
///     --rpc-url celo --private-key $PRIVATE_KEY --broadcast \
///     --sig "run(address,address)" <eoaOwner> <finalOwner>
contract Deploy_Celo is OivChainDeploy {
    uint256 public constant CHAIN_ID = 42220;
    address public constant CCIP_ROUTER = 0xfB48f15480926A4ADf9116Dca468bDd2EE6C5F62;
    address public constant LINK_TOKEN = 0xd07294e6E917e07dfDcee882dd1e2565085C2ae0;

    function run(address eoaOwner, address finalOwner) external {
        _runChain(CHAIN_ID, eoaOwner, finalOwner, CCIP_ROUTER, LINK_TOKEN);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OivChainDeploy} from "../base/OivChainDeploy.sol";

/// @title  Deploy_Avalanche
/// @notice Per-chain OIV infra deploy for avalanche (chainId 43114, verdict READY-AFTER-EMPTY).
///         Runs Empty preflight -> KpkOivFactory + KpkSharesDeployer -> CcipOivDeployer (+configure),
///         all deterministic. CCIP router/LINK below were resolved + verified on-chain and are kept
///         in sync with script/ccip-networks.json by test/CcipNetworksSync.t.sol; CHAIN_ID is guarded
///         against block.chainid in _runChain so a wrong --rpc-url cannot misconfigure the orchestrator.
///
/// Usage:
///   source .env && forge script script/chains/Deploy_Avalanche.s.sol:Deploy_Avalanche \
///     --rpc-url avalanche --private-key $PRIVATE_KEY --broadcast \
///     --sig "run(address,address)" <eoaOwner> <finalOwner>
contract Deploy_Avalanche is OivChainDeploy {
    uint256 public constant CHAIN_ID = 43114;
    address public constant CCIP_ROUTER = 0xF4c7E640EdA248ef95972845a62bdC74237805dB;
    address public constant LINK_TOKEN = 0x5947BB275c521040051D82396192181b413227A3;

    function run(address eoaOwner, address finalOwner) external {
        _runChain(CHAIN_ID, eoaOwner, finalOwner, CCIP_ROUTER, LINK_TOKEN);
    }
}

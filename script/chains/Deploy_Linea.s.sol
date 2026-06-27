// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OivChainDeploy} from "../base/OivChainDeploy.sol";

/// @title  Deploy_Linea
/// @notice Per-chain OIV infra deploy for linea (chainId 59144, verdict READY-AFTER-EMPTY).
///         Runs Empty preflight -> KpkOivFactory + KpkSharesDeployer -> CcipOivDeployer (+configure),
///         all deterministic. CCIP router/LINK below were resolved + verified on-chain and are kept
///         in sync with script/ccip-networks.json by test/CcipNetworksSync.t.sol; CHAIN_ID is guarded
///         against block.chainid in _runChain so a wrong --rpc-url cannot misconfigure the orchestrator.
///
/// Usage:
///   source .env && forge script script/chains/Deploy_Linea.s.sol:Deploy_Linea \
///     --rpc-url linea --private-key $PRIVATE_KEY --broadcast \
///     --sig "run(address,address)" <eoaOwner> <finalOwner>
contract Deploy_Linea is OivChainDeploy {
    uint256 public constant CHAIN_ID = 59144;
    address public constant CCIP_ROUTER = 0x549FEB73F2348F6cD99b9fc8c69252034897f06C;
    address public constant LINK_TOKEN = 0x5B16228B94b68C7cE33AF2ACc5663eBdE4dCFA2d;

    function run(address eoaOwner, address finalOwner) external {
        _runChain(CHAIN_ID, eoaOwner, finalOwner, CCIP_ROUTER, LINK_TOKEN);
    }
}

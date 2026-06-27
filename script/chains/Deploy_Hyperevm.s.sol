// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OivChainDeploy} from "../base/OivChainDeploy.sol";

/// @title  Deploy_Hyperevm
/// @notice Per-chain OIV infra deploy for hyperevm (chainId 999, verdict READY-AFTER-EMPTY).
///         Runs Empty preflight -> KpkOivFactory + KpkSharesDeployer -> CcipOivDeployer (+configure),
///         all deterministic. CCIP router/LINK below were resolved + verified on-chain and are kept
///         in sync with script/ccip-networks.json by test/CcipNetworksSync.t.sol; CHAIN_ID is guarded
///         against block.chainid in _runChain so a wrong --rpc-url cannot misconfigure the orchestrator.
///
/// Usage:
///   source .env && forge script script/chains/Deploy_Hyperevm.s.sol:Deploy_Hyperevm \
///     --rpc-url hyperevm --private-key $PRIVATE_KEY --broadcast \
///     --sig "run(address,address)" <eoaOwner> <finalOwner>
contract Deploy_Hyperevm is OivChainDeploy {
    uint256 public constant CHAIN_ID = 999;
    address public constant CCIP_ROUTER = 0x13b3332b66389B1467CA6eBd6fa79775CCeF65ec;
    address public constant LINK_TOKEN = 0x1AC2EE68b8d038C982C1E1f73F596927dd70De59;

    function run(address eoaOwner, address finalOwner) external {
        _runChain(CHAIN_ID, eoaOwner, finalOwner, CCIP_ROUTER, LINK_TOKEN);
    }
}

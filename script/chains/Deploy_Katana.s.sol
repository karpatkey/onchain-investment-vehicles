// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OivChainDeploy} from "../base/OivChainDeploy.sol";

/// @title  Deploy_Katana
/// @notice Per-chain OIV infra deploy for katana (chainId 747474, verdict READY-AFTER-EMPTY).
///         Runs Empty preflight -> KpkOivFactory + KpkSharesDeployer -> CcipOivDeployer (+configure),
///         all deterministic. CCIP router/LINK below were resolved + verified on-chain and are kept
///         in sync with script/ccip-networks.json by test/CcipNetworksSync.t.sol; CHAIN_ID is guarded
///         against block.chainid in _runChain so a wrong --rpc-url cannot misconfigure the orchestrator.
///
/// Usage:
///   source .env && forge script script/chains/Deploy_Katana.s.sol:Deploy_Katana \
///     --rpc-url katana --private-key $PRIVATE_KEY --broadcast \
///     --sig "run(address,address)" <eoaOwner> <finalOwner>
contract Deploy_Katana is OivChainDeploy {
    uint256 public constant CHAIN_ID = 747474;
    address public constant CCIP_ROUTER = 0x7c19b79D2a054114Ab36ad758A36e92376e267DA;
    address public constant LINK_TOKEN = 0xc2C447b04e0ED3476DdbDae8E9E39bE7159d27b6;

    function run(address eoaOwner, address finalOwner) external {
        _runChain(CHAIN_ID, eoaOwner, finalOwner, CCIP_ROUTER, LINK_TOKEN);
    }
}

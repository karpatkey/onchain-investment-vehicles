// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OivChainDeploy} from "../base/OivChainDeploy.sol";

/// @title  Deploy_Plasma
/// @notice Per-chain OIV infra deploy for plasma (chainId 9745, verdict READY-AFTER-EMPTY).
///         Runs Empty preflight -> KpkOivFactory + KpkSharesDeployer -> CcipOivDeployer (+configure),
///         all deterministic. CCIP router/LINK below were resolved + verified on-chain and are kept
///         in sync with script/ccip-networks.json by test/CcipNetworksSync.t.sol; CHAIN_ID is guarded
///         against block.chainid in _runChain so a wrong --rpc-url cannot misconfigure the orchestrator.
///
/// Usage:
///   source .env && forge script script/chains/Deploy_Plasma.s.sol:Deploy_Plasma \
///     --rpc-url plasma --private-key $PRIVATE_KEY --broadcast \
///     --sig "run(address,address)" <eoaOwner> <finalOwner>
contract Deploy_Plasma is OivChainDeploy {
    uint256 public constant CHAIN_ID = 9745;
    address public constant CCIP_ROUTER = 0xcDca5D374e46A6DDDab50bD2D9acB8c796eC35C3;
    address public constant LINK_TOKEN = 0x76a443768A5e3B8d1AED0105FC250877841Deb40;

    function run(address eoaOwner, address finalOwner) external {
        _runChain(CHAIN_ID, eoaOwner, finalOwner, CCIP_ROUTER, LINK_TOKEN);
    }
}

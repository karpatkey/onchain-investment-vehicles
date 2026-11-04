// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OivChainDeploy} from "../base/OivChainDeploy.sol";

/// @title  Deploy_Arc
/// @notice Per-chain OIV infra deploy for arc (chainId 5042, verdict READY-AFTER-EMPTY).
///         Runs Empty preflight -> KpkOivFactory + mastercopies + KpkTimelockDeployer -> CcipOivDeployer (+configure),
///         all deterministic. CCIP router/LINK below were resolved + verified on-chain and are kept
///         in sync with script/ccip-networks.json by test/CcipNetworksSync.t.sol; CHAIN_ID is guarded
///         against block.chainid in _runChain so a wrong --rpc-url cannot misconfigure the orchestrator.
///         Arc's gas token is native USDC (18 decimals), so the deployer pays gas and CCIP fees in USDC.
///
/// Usage:
///   source .env && forge script script/chains/Deploy_Arc.s.sol:Deploy_Arc \
///     --rpc-url arc --private-key $PRIVATE_KEY --broadcast \
///     --sig "run(address,address)" <eoaOwner> <finalOwner>
contract Deploy_Arc is OivChainDeploy {
    uint256 public constant CHAIN_ID = 5042;
    address public constant CCIP_ROUTER = 0xB79791184973589c38e114D43Eb8E4588C283A18;
    address public constant LINK_TOKEN = 0x76a443768A5e3B8d1AED0105FC250877841Deb40;

    function run(address eoaOwner, address finalOwner) external {
        _runChain(CHAIN_ID, eoaOwner, finalOwner, CCIP_ROUTER, LINK_TOKEN);
    }
}

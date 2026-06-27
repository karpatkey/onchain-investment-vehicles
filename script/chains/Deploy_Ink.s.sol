// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OivChainDeploy} from "../base/OivChainDeploy.sol";

/// @title  Deploy_Ink
/// @notice Per-chain OIV infra deploy for ink (chainId 57073, verdict READY-AFTER-EMPTY).
///         Runs Empty preflight -> KpkOivFactory + KpkSharesDeployer -> CcipOivDeployer (+configure),
///         all deterministic. CCIP router/LINK below were resolved + verified on-chain and are kept
///         in sync with script/ccip-networks.json by test/CcipNetworksSync.t.sol; CHAIN_ID is guarded
///         against block.chainid in _runChain so a wrong --rpc-url cannot misconfigure the orchestrator.
///
/// Usage:
///   source .env && forge script script/chains/Deploy_Ink.s.sol:Deploy_Ink \
///     --rpc-url ink --private-key $PRIVATE_KEY --broadcast \
///     --sig "run(address,address)" <eoaOwner> <finalOwner>
contract Deploy_Ink is OivChainDeploy {
    uint256 public constant CHAIN_ID = 57073;
    address public constant CCIP_ROUTER = 0xca7c90A52B44E301AC01Cb5EB99b2fD99339433A;
    address public constant LINK_TOKEN = 0x71052BAe71C25C78E37fD12E5ff1101A71d9018F;

    function run(address eoaOwner, address finalOwner) external {
        _runChain(CHAIN_ID, eoaOwner, finalOwner, CCIP_ROUTER, LINK_TOKEN);
    }
}

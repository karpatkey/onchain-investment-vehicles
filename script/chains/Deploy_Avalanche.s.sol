// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OivChainDeploy} from "../base/OivChainDeploy.sol";

/// @title  Deploy_Avalanche
/// @notice Per-chain OIV infra deploy for avalanche (chainId 43114, verdict READY-AFTER-EMPTY).
///         Runs Empty preflight -> KpkOivFactory + KpkSharesDeployer -> CcipOivDeployer (+configure),
///         all deterministic. CCIP router/LINK below were resolved + verified on-chain.
///
/// Usage:
///   source .env && forge script script/chains/Deploy_Avalanche.s.sol:Deploy_Avalanche \
///     --rpc-url avalanche --private-key $PRIVATE_KEY --broadcast \
///     --sig "run(address,address)" <eoaOwner> <finalOwner>
contract Deploy_Avalanche is OivChainDeploy {
    address internal constant CCIP_ROUTER = 0xF4c7E640EdA248ef95972845a62bdC74237805dB;
    address internal constant LINK_TOKEN = 0x5947BB275c521040051D82396192181b413227A3;

    function run(address eoaOwner, address finalOwner) external {
        _runChain(eoaOwner, finalOwner, CCIP_ROUTER, LINK_TOKEN);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OivChainDeploy} from "../base/OivChainDeploy.sol";

/// @title  Deploy_Arbitrum
/// @notice Per-chain OIV infra deploy for arbitrum (chainId 42161, verdict READY).
///         Runs Empty preflight -> KpkOivFactory + KpkSharesDeployer -> CcipOivDeployer (+configure),
///         all deterministic. CCIP router/LINK below were resolved + verified on-chain.
///
/// Usage:
///   source .env && forge script script/chains/Deploy_Arbitrum.s.sol:Deploy_Arbitrum \
///     --rpc-url arbitrum --private-key $PRIVATE_KEY --broadcast \
///     --sig "run(address,address)" <eoaOwner> <finalOwner>
contract Deploy_Arbitrum is OivChainDeploy {
    address internal constant CCIP_ROUTER = 0x141fa059441E0ca23ce184B6A78bafD2A517DdE8;
    address internal constant LINK_TOKEN = 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4;

    function run(address eoaOwner, address finalOwner) external {
        _runChain(eoaOwner, finalOwner, CCIP_ROUTER, LINK_TOKEN);
    }
}

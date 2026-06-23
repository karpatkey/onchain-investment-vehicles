// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OivChainDeploy} from "../base/OivChainDeploy.sol";

/// @title  Deploy_Optimism
/// @notice Per-chain OIV infra deploy for optimism (chainId 10, verdict READY).
///         Runs Empty preflight -> KpkOivFactory + KpkSharesDeployer -> CcipOivDeployer (+configure),
///         all deterministic. CCIP router/LINK below were resolved + verified on-chain.
///
/// Usage:
///   source .env && forge script script/chains/Deploy_Optimism.s.sol:Deploy_Optimism \
///     --rpc-url optimism --private-key $PRIVATE_KEY --broadcast \
///     --sig "run(address,address)" <eoaOwner> <finalOwner>
contract Deploy_Optimism is OivChainDeploy {
    address internal constant CCIP_ROUTER = 0x3206695CaE29952f4b0c22a169725a865bc8Ce0f;
    address internal constant LINK_TOKEN = 0x350a791Bfc2C21F9Ed5d10980Dad2e2638ffa7f6;

    function run(address eoaOwner, address finalOwner) external {
        _runChain(eoaOwner, finalOwner, CCIP_ROUTER, LINK_TOKEN);
    }
}

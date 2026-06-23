// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OivChainDeploy} from "../base/OivChainDeploy.sol";

/// @title  Deploy_Worldchain
/// @notice Per-chain OIV infra deploy for worldchain (chainId 480, verdict READY-AFTER-EMPTY).
///         Runs Empty preflight -> KpkOivFactory + KpkSharesDeployer -> CcipOivDeployer (+configure),
///         all deterministic. CCIP router/LINK below were resolved + verified on-chain.
///
/// Usage:
///   source .env && forge script script/chains/Deploy_Worldchain.s.sol:Deploy_Worldchain \
///     --rpc-url worldchain --private-key $PRIVATE_KEY --broadcast \
///     --sig "run(address,address)" <eoaOwner> <finalOwner>
contract Deploy_Worldchain is OivChainDeploy {
    address internal constant CCIP_ROUTER = 0x5fd9E4986187c56826A3064954Cfa2Cf250cfA0f;
    address internal constant LINK_TOKEN = 0x915b648e994d5f31059B38223b9fbe98ae185473;

    function run(address eoaOwner, address finalOwner) external {
        _runChain(eoaOwner, finalOwner, CCIP_ROUTER, LINK_TOKEN);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OivChainDeploy} from "../base/OivChainDeploy.sol";

/// @title  Deploy_Sonic
/// @notice Per-chain OIV infra deploy for sonic (chainId 146, verdict READY-AFTER-EMPTY).
///         Runs Empty preflight -> KpkOivFactory + KpkSharesDeployer -> CcipOivDeployer (+configure),
///         all deterministic. CCIP router/LINK below were resolved + verified on-chain.
///
/// Usage:
///   source .env && forge script script/chains/Deploy_Sonic.s.sol:Deploy_Sonic \
///     --rpc-url sonic --private-key $PRIVATE_KEY --broadcast \
///     --sig "run(address,address)" <eoaOwner> <finalOwner>
contract Deploy_Sonic is OivChainDeploy {
    address internal constant CCIP_ROUTER = 0xB4e1Ff7882474BB93042be9AD5E1fA387949B860;
    address internal constant LINK_TOKEN = 0x71052BAe71C25C78E37fD12E5ff1101A71d9018F;

    function run(address eoaOwner, address finalOwner) external {
        _runChain(eoaOwner, finalOwner, CCIP_ROUTER, LINK_TOKEN);
    }
}

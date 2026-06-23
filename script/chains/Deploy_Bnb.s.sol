// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OivChainDeploy} from "../base/OivChainDeploy.sol";

/// @title  Deploy_Bnb
/// @notice Per-chain OIV infra deploy for bnb (chainId 56, verdict READY-AFTER-EMPTY).
///         Runs Empty preflight -> KpkOivFactory + KpkSharesDeployer -> CcipOivDeployer (+configure),
///         all deterministic. CCIP router/LINK below were resolved + verified on-chain.
///
/// Usage:
///   source .env && forge script script/chains/Deploy_Bnb.s.sol:Deploy_Bnb \
///     --rpc-url bnb --private-key $PRIVATE_KEY --broadcast \
///     --sig "run(address,address)" <eoaOwner> <finalOwner>
contract Deploy_Bnb is OivChainDeploy {
    address internal constant CCIP_ROUTER = 0x34B03Cb9086d7D758AC55af71584F81A598759FE;
    address internal constant LINK_TOKEN = 0x404460C6A5EdE2D891e8297795264fDe62ADBB75;

    function run(address eoaOwner, address finalOwner) external {
        _runChain(eoaOwner, finalOwner, CCIP_ROUTER, LINK_TOKEN);
    }
}

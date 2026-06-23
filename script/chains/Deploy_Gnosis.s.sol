// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OivChainDeploy} from "../base/OivChainDeploy.sol";

/// @title  Deploy_Gnosis
/// @notice Per-chain OIV infra deploy for gnosis (chainId 100, verdict READY).
///         Runs Empty preflight -> KpkOivFactory + KpkSharesDeployer -> CcipOivDeployer (+configure),
///         all deterministic. CCIP router/LINK below were resolved + verified on-chain.
///
/// Usage:
///   source .env && forge script script/chains/Deploy_Gnosis.s.sol:Deploy_Gnosis \
///     --rpc-url gnosis --private-key $PRIVATE_KEY --broadcast \
///     --sig "run(address,address)" <eoaOwner> <finalOwner>
contract Deploy_Gnosis is OivChainDeploy {
    address internal constant CCIP_ROUTER = 0x4aAD6071085df840abD9Baf1697d5D5992bDadce;
    address internal constant LINK_TOKEN = 0xE2e73A1c69ecF83F464EFCE6A5be353a37cA09b2;

    function run(address eoaOwner, address finalOwner) external {
        _runChain(eoaOwner, finalOwner, CCIP_ROUTER, LINK_TOKEN);
    }
}

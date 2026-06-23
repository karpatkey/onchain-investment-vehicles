// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OivChainDeploy} from "../base/OivChainDeploy.sol";

/// @title  Deploy_Celo
/// @notice Per-chain OIV infra deploy for celo (chainId 42220, verdict READY-AFTER-EMPTY).
///         Runs Empty preflight -> KpkOivFactory + KpkSharesDeployer -> CcipOivDeployer (+configure),
///         all deterministic. CCIP router/LINK below were resolved + verified on-chain.
///
/// Usage:
///   source .env && forge script script/chains/Deploy_Celo.s.sol:Deploy_Celo \
///     --rpc-url celo --private-key $PRIVATE_KEY --broadcast \
///     --sig "run(address,address)" <eoaOwner> <finalOwner>
contract Deploy_Celo is OivChainDeploy {
    address internal constant CCIP_ROUTER = 0xfB48f15480926A4ADf9116Dca468bDd2EE6C5F62;
    address internal constant LINK_TOKEN = 0xd07294e6E917e07dfDcee882dd1e2565085C2ae0;

    function run(address eoaOwner, address finalOwner) external {
        _runChain(eoaOwner, finalOwner, CCIP_ROUTER, LINK_TOKEN);
    }
}

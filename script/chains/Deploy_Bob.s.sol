// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OivChainDeploy} from "../base/OivChainDeploy.sol";

/// @title  Deploy_Bob
/// @notice Per-chain OIV infra deploy for bob (chainId 60808, verdict READY-AFTER-EMPTY).
///         Runs Empty preflight -> KpkOivFactory + KpkSharesDeployer -> CcipOivDeployer (+configure),
///         all deterministic. CCIP router/LINK below were resolved + verified on-chain.
///
/// Usage:
///   source .env && forge script script/chains/Deploy_Bob.s.sol:Deploy_Bob \
///     --rpc-url bob --private-key $PRIVATE_KEY --broadcast \
///     --sig "run(address,address)" <eoaOwner> <finalOwner>
contract Deploy_Bob is OivChainDeploy {
    address internal constant CCIP_ROUTER = 0x827716e74F769AB7b6bb374A29235d9c2156932C;
    address internal constant LINK_TOKEN = 0x5aB885CDa7216b163fb6F813DEC1E1532516c833;

    function run(address eoaOwner, address finalOwner) external {
        _runChain(eoaOwner, finalOwner, CCIP_ROUTER, LINK_TOKEN);
    }
}

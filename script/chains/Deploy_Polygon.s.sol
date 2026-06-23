// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OivChainDeploy} from "../base/OivChainDeploy.sol";

/// @title  Deploy_Polygon
/// @notice Per-chain OIV infra deploy for polygon (chainId 137, verdict READY-AFTER-EMPTY).
///         Runs Empty preflight -> KpkOivFactory + KpkSharesDeployer -> CcipOivDeployer (+configure),
///         all deterministic. CCIP router/LINK below were resolved + verified on-chain.
///
/// Usage:
///   source .env && forge script script/chains/Deploy_Polygon.s.sol:Deploy_Polygon \
///     --rpc-url polygon --private-key $PRIVATE_KEY --broadcast \
///     --sig "run(address,address)" <eoaOwner> <finalOwner>
contract Deploy_Polygon is OivChainDeploy {
    address internal constant CCIP_ROUTER = 0x849c5ED5a80F5B408Dd4969b78c2C8fdf0565Bfe;
    address internal constant LINK_TOKEN = 0xb0897686c545045aFc77CF20eC7A532E3120E0F1;

    function run(address eoaOwner, address finalOwner) external {
        _runChain(eoaOwner, finalOwner, CCIP_ROUTER, LINK_TOKEN);
    }
}

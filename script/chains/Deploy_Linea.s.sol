// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OivChainDeploy} from "../base/OivChainDeploy.sol";

/// @title  Deploy_Linea
/// @notice Per-chain OIV infra deploy for linea (chainId 59144, verdict READY-AFTER-EMPTY).
///         Runs Empty preflight -> KpkOivFactory + KpkSharesDeployer -> CcipOivDeployer (+configure),
///         all deterministic. CCIP router/LINK below were resolved + verified on-chain.
///
/// Usage:
///   source .env && forge script script/chains/Deploy_Linea.s.sol:Deploy_Linea \
///     --rpc-url linea --private-key $PRIVATE_KEY --broadcast \
///     --sig "run(address,address)" <eoaOwner> <finalOwner>
contract Deploy_Linea is OivChainDeploy {
    address internal constant CCIP_ROUTER = 0x549FEB73F2348F6cD99b9fc8c69252034897f06C;
    address internal constant LINK_TOKEN = 0x5B16228B94b68C7cE33AF2ACc5663eBdE4dCFA2d;

    function run(address eoaOwner, address finalOwner) external {
        _runChain(eoaOwner, finalOwner, CCIP_ROUTER, LINK_TOKEN);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OivChainDeploy} from "../base/OivChainDeploy.sol";

/// @title  Deploy_Base
/// @notice Per-chain OIV infra deploy for base (chainId 8453, verdict READY).
///         Runs Empty preflight -> KpkOivFactory + KpkSharesDeployer -> CcipOivDeployer (+configure),
///         all deterministic. CCIP router/LINK below were resolved + verified on-chain.
///
/// Usage:
///   source .env && forge script script/chains/Deploy_Base.s.sol:Deploy_Base \
///     --rpc-url base --private-key $PRIVATE_KEY --broadcast \
///     --sig "run(address,address)" <eoaOwner> <finalOwner>
contract Deploy_Base is OivChainDeploy {
    address internal constant CCIP_ROUTER = 0x881e3A65B4d4a04dD529061dd0071cf975F58bCD;
    address internal constant LINK_TOKEN = 0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196;

    function run(address eoaOwner, address finalOwner) external {
        _runChain(eoaOwner, finalOwner, CCIP_ROUTER, LINK_TOKEN);
    }
}

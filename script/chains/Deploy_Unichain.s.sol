// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OivChainDeploy} from "../base/OivChainDeploy.sol";

/// @title  Deploy_Unichain
/// @notice Per-chain OIV infra deploy for unichain (chainId 130, verdict READY-AFTER-EMPTY).
///         Runs Empty preflight -> KpkOivFactory + KpkSharesDeployer -> CcipOivDeployer (+configure),
///         all deterministic. CCIP router/LINK below were resolved + verified on-chain.
///
/// Usage:
///   source .env && forge script script/chains/Deploy_Unichain.s.sol:Deploy_Unichain \
///     --rpc-url unichain --private-key $PRIVATE_KEY --broadcast \
///     --sig "run(address,address)" <eoaOwner> <finalOwner>
contract Deploy_Unichain is OivChainDeploy {
    address internal constant CCIP_ROUTER = 0x68891f5F96695ECd7dEdBE2289D1b73426ae7864;
    address internal constant LINK_TOKEN = 0xEF66491eab4bbB582c57b14778afd8dFb70D8A1A;

    function run(address eoaOwner, address finalOwner) external {
        _runChain(eoaOwner, finalOwner, CCIP_ROUTER, LINK_TOKEN);
    }
}

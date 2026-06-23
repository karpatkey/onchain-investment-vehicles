// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OivChainDeploy} from "../base/OivChainDeploy.sol";

/// @title  Deploy_Berachain
/// @notice Per-chain OIV infra deploy for berachain (chainId 80094, verdict READY-AFTER-EMPTY).
///         Runs Empty preflight -> KpkOivFactory + KpkSharesDeployer -> CcipOivDeployer (+configure),
///         all deterministic. CCIP router/LINK below were resolved + verified on-chain.
///
/// Usage:
///   source .env && forge script script/chains/Deploy_Berachain.s.sol:Deploy_Berachain \
///     --rpc-url berachain --private-key $PRIVATE_KEY --broadcast \
///     --sig "run(address,address)" <eoaOwner> <finalOwner>
contract Deploy_Berachain is OivChainDeploy {
    address internal constant CCIP_ROUTER = 0x71a275704c283486fBa26dad3dd0DB78804426eF;
    address internal constant LINK_TOKEN = 0x71052BAe71C25C78E37fD12E5ff1101A71d9018F;

    function run(address eoaOwner, address finalOwner) external {
        _runChain(eoaOwner, finalOwner, CCIP_ROUTER, LINK_TOKEN);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OivChainDeploy} from "../base/OivChainDeploy.sol";

/// @title  Deploy_Scroll
/// @notice Per-chain OIV infra deploy for scroll (chainId 534352, verdict READY-AFTER-EMPTY).
///         Runs Empty preflight -> KpkOivFactory + KpkSharesDeployer -> CcipOivDeployer (+configure),
///         all deterministic. CCIP router/LINK below were resolved + verified on-chain.
///
/// Usage:
///   source .env && forge script script/chains/Deploy_Scroll.s.sol:Deploy_Scroll \
///     --rpc-url scroll --private-key $PRIVATE_KEY --broadcast \
///     --sig "run(address,address)" <eoaOwner> <finalOwner>
contract Deploy_Scroll is OivChainDeploy {
    address internal constant CCIP_ROUTER = 0x9a55E8Cab6564eb7bbd7124238932963B8Af71DC;
    address internal constant LINK_TOKEN = 0x548C6944cba02B9D1C0570102c89de64D258d3Ac;

    function run(address eoaOwner, address finalOwner) external {
        _runChain(eoaOwner, finalOwner, CCIP_ROUTER, LINK_TOKEN);
    }
}

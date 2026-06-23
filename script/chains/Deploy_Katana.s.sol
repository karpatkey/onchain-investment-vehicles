// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OivChainDeploy} from "../base/OivChainDeploy.sol";

/// @title  Deploy_Katana
/// @notice Per-chain OIV infra deploy for katana (chainId 747474, verdict READY-AFTER-EMPTY).
///         Runs Empty preflight -> KpkOivFactory + KpkSharesDeployer -> CcipOivDeployer (+configure),
///         all deterministic. CCIP router/LINK below were resolved + verified on-chain.
///
/// Usage:
///   source .env && forge script script/chains/Deploy_Katana.s.sol:Deploy_Katana \
///     --rpc-url katana --private-key $PRIVATE_KEY --broadcast \
///     --sig "run(address,address)" <eoaOwner> <finalOwner>
contract Deploy_Katana is OivChainDeploy {
    address internal constant CCIP_ROUTER = 0x7c19b79D2a054114Ab36ad758A36e92376e267DA;
    address internal constant LINK_TOKEN = 0xc2C447b04e0ED3476DdbDae8E9E39bE7159d27b6;

    function run(address eoaOwner, address finalOwner) external {
        _runChain(eoaOwner, finalOwner, CCIP_ROUTER, LINK_TOKEN);
    }
}

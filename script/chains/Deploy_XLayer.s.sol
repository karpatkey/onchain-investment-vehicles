// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OivChainDeploy} from "../base/OivChainDeploy.sol";

/// @title  Deploy_XLayer
/// @notice Per-chain OIV infra deploy for xlayer (chainId 196, verdict READY-AFTER-EMPTY).
///         Runs Roles v2.1.1 + Empty preflight -> KpkOivFactory + mastercopies + KpkTimelockDeployer
///         -> CcipOivDeployer (+configure), all deterministic. CCIP router/LINK below were resolved +
///         verified on-chain (FeeQuoter 2.0.0 `getFeeTokens()` lists LINK) and are kept in sync with
///         script/ccip-networks.json by test/CcipNetworksSync.t.sol; CHAIN_ID is guarded against
///         block.chainid in _runChain so a wrong --rpc-url cannot misconfigure the orchestrator.
///
///         X Layer is the first chain onboarded without the Roles v2.1.1 mastercopy already present;
///         `_ensureRolesMastercopy` replays it through EIP-2470 in the same broadcast. The chain is
///         `excluded` in the registry — 196 is outside the orchestrator's constructor-baked topology,
///         so fan-out needs a Security Council `setChainSelector(196, 3016212468291539606)` here and
///         on each counterpart chain. Use script/deploy-chain.sh with ALLOW_EXCLUDED=1.
///
///         `_runChain` refuses a codeless finalOwner, which is satisfiable here: the Security Council
///         Safe 0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537 already exists on 196 with the same 8
///         owners and 5-of-8 threshold as on Ethereum (read back on-chain 2026-10-13).
///
/// Usage:
///   source .env && forge script script/chains/Deploy_XLayer.s.sol:Deploy_XLayer \
///     --rpc-url xlayer --private-key $PRIVATE_KEY --broadcast \
///     --sig "run(address,address)" <eoaOwner> <finalOwner>
contract Deploy_XLayer is OivChainDeploy {
    uint256 public constant CHAIN_ID = 196;
    address public constant CCIP_ROUTER = 0xF2b6Cb7867EB5502C3249dD37D7bc1Cc148e5232;
    address public constant LINK_TOKEN = 0x8aF9711B44695a5A081F25AB9903DDB73aCf8FA9;

    function run(address eoaOwner, address finalOwner) external {
        _runChain(CHAIN_ID, eoaOwner, finalOwner, CCIP_ROUTER, LINK_TOKEN);
    }
}

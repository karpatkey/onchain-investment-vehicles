// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console} from "forge-std/Script.sol";
import {OivChainDeploy} from "./base/OivChainDeploy.sol";

/// @title  DeployEmpty
/// @notice Onboards the `Empty` contract to a chain at its canonical address
///         `0xA4703438f8cc4fc2C2503a7e43935Da16BA74652` — the address `KpkOivFactory` bakes in as a
///         constant (`EMPTY_CONTRACT`, the Avatar Safe's sole signer). Every chain MUST host `Empty`
///         there or `deployOiv`/`deployStack` revert with `EmptyContractMissing`.
///
/// @dev    The onboarding logic + the exact creation calldata live in `OivChainDeploy._ensureEmpty`
///         (single source of truth — also used by the per-chain scripts). Idempotent: skips if
///         already deployed; reverts if it cannot land `Empty` at the canonical address.
///
/// Usage (per chain):
///   source .env && forge script script/DeployEmpty.s.sol:DeployEmpty \
///     --rpc-url <chain> --private-key $PRIVATE_KEY --broadcast
contract DeployEmpty is OivChainDeploy {
    function run() external {
        if (EMPTY.code.length > 0) {
            console.log("[SKIP] Empty already deployed at", EMPTY);
            return;
        }
        vm.startBroadcast();
        _ensureEmpty();
        vm.stopBroadcast();
        console.log("[OK] Empty deployed at", EMPTY);
    }
}

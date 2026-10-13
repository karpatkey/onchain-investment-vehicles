// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console} from "forge-std/Script.sol";
import {OivChainDeploy} from "./base/OivChainDeploy.sol";

/// @title  DeployRolesMastercopy
/// @notice Onboards the PATCHED Zodiac Roles Modifier v2.1.1 mastercopy to a chain at its canonical
///         address `0xF2964CE6161ce0e75964Fe7927cE114cb0B283D5` — the address `KpkOivFactory` bakes
///         into its init code and clones for every fund. A chain without it accepts the whole infra
///         deploy and then mints Roles proxies that delegate to nothing, so this is the promotion
///         step for a chain the registry marks `rolesV211Present: false` (X Layer was one).
///
/// @dev    The replay logic and the integrity pin live in `OivChainDeploy._ensureRolesMastercopy`
///         (single source of truth — the per-chain scripts run it as a preflight). Idempotent:
///         skips when the canonical codehash is already there, reverts if it cannot land it.
///
///         GAS: the creation code is 25,458 bytes (~5.6M gas). `forge script` estimates this
///         correctly, but a manual `cast send` MUST pass an explicit `--gas-limit`: the EIP-2470
///         SingletonFactory swallows a failed inner CREATE2, so an under-gassed deploy returns a
///         status-1 receipt with no contract.
///
/// Usage (per chain):
///   source .env && forge script script/DeployRolesMastercopy.s.sol:DeployRolesMastercopy \
///     --rpc-url <chain> --account $DEPLOYER_NAME --broadcast
contract DeployRolesMastercopy is OivChainDeploy {
    function run() external {
        // Hash-check the pinned creation code BEFORE broadcasting: a tampered or truncated data file
        // would otherwise be discovered only after paying for a deploy at the wrong address.
        require(_rolesModifierInitCode().length > 0, "Roles mastercopy init code is empty");

        vm.startBroadcast();
        _ensureRolesMastercopy();
        vm.stopBroadcast();

        console.log("[OK] Roles v2.1.1 mastercopy present at", ROLES_MODIFIER_MASTERCOPY);
    }
}

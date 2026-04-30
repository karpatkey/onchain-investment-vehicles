// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {KpkOivFactory} from "../src/KpkOivFactory.sol";

/// @title  DeployKpkUsdProductionStack
/// @notice Sidechain companion to DeployKpkUsdProductionOiv. Deploys ONLY the 5-contract
///         operational stack (Avatar Safe + Manager Safe + 3 Roles Modifiers) — no KpkShares.
///         Run on Optimism, Gnosis, Base, and Arbitrum so the kUSD Avatar Safe exists at the
///         same address on every chain (per the KpkOivFactory cross-flow invariant — see
///         KpkOivFactory.sol:44–50).
///
/// @dev    The constants below MUST match the mainnet DeployKpkUsdProductionOiv script exactly.
///         Any drift breaks the cross-chain Avatar Safe address invariant. The script also
///         asserts predicted addresses match the mainnet predictions before broadcast as a
///         safety net against config drift / wrong factory bytecode / wrong infrastructure
///         addresses on the target chain.
///
/// Usage (dry run on a sidechain):
///   source .env
///   forge script script/DeployKpkUsdProductionStack.s.sol:DeployKpkUsdProductionStack \
///     --rpc-url optimism \
///     --sender 0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72
///
/// Usage (real broadcast on each sidechain):
///   source .env
///   forge script script/DeployKpkUsdProductionStack.s.sol:DeployKpkUsdProductionStack \
///     --rpc-url <optimism|gnosis|base|arbitrum> \
///     --broadcast --verify \
///     --account $MAINNET_DEPLOYER_NAME \
///     --sender 0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72
contract DeployKpkUsdProductionStack is Script {
    // ── MUST match DeployKpkUsdProductionOiv exactly ─────────────────────────

    address internal constant FACTORY = 0x0d94255fdE65D302616b02A2F070CdB21190d420;
    address internal constant DEPLOYER = 0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72;
    uint256 internal constant MANAGER_SAFE_THRESHOLD = 1;
    uint256 internal constant SALT = uint256(keccak256("kpk-USD-Alpha-Fund-prod-v1"));

    function _managerSafeOwners() internal pure returns (address[] memory owners) {
        owners = new address[](5);
        owners[0] = 0x524075B4d1C91F91F27893f4640ca980785d1e58;
        owners[1] = 0xAc12293749b4D9e7bb4c33608d39E089135E3521;
        owners[2] = 0x9F230218cf7FDe6A9246e6f8CB0b888377E92639;
        owners[3] = 0x4102E0743DA668EB2f55E90c96ef8EF4e621879c;
        owners[4] = 0xE2679499b74cCc5dfd4AA78462FB7A1D4Be386E5;
    }

    // ── Sidechain-specific ────────────────────────────────────────────────────

    /// @notice Staging Sec Council Safe — owns the exec Roles Modifier on every chain.
    ///         Pre-flight verified to exist at this address on Op/Gnosis/Base/Arbitrum with
    ///         the same owners + threshold as mainnet (cast-checked 2026-04-30).
    address internal constant STAGING_SEC_COUNCIL_SAFE = 0x9D73C053afcbF6CD5c8986C3f049fD2Ce005730C;

    // ── Expected addresses — locked from the mainnet OIV dry-run ──────────────
    //
    // The cross-flow invariant guarantees these are identical on every chain for the same
    // (caller, salt). Asserting them here catches: wrong factory bytecode, wrong infrastructure
    // addresses (Safe singleton / Zodiac mastercopy / etc.), wrong caller, wrong salt — any of
    // which would produce an Avatar Safe that doesn't match mainnet.

    address internal constant EXPECTED_AVATAR_SAFE = 0x38F6a1B46144fAEe6a6D9F79D8dE264C18e23848;
    address internal constant EXPECTED_MANAGER_SAFE = 0x7Bb5e307eDf80630f153BD28789b4365eFe4cce3;
    address internal constant EXPECTED_EXEC_ROLES_MOD = 0xd8e63D2ca7A098E2B939BF4733e94C5768D3B966;
    address internal constant EXPECTED_SUB_ROLES_MOD = 0xB15400Bb735CF9d91E09d097f2dA588ebe760D49;
    address internal constant EXPECTED_MANAGER_ROLES_MOD = 0x988A15711CCDF16C06010bb41AaEBF39e407cD7F;

    // ── Entry point ───────────────────────────────────────────────────────────

    function run() external {
        // Allow only the 4 sidechains. Mainnet has its own deployOiv script.
        uint256 cid = block.chainid;
        require(
            cid == 10 || cid == 100 || cid == 8453 || cid == 42161,
            "DeployKpkUsdProductionStack: chain must be Optimism (10), Gnosis (100), Base (8453), or Arbitrum (42161)"
        );
        require(FACTORY.code.length > 0, "DeployKpkUsdProductionStack: factory not deployed at expected address");
        require(
            STAGING_SEC_COUNCIL_SAFE.code.length > 0,
            "DeployKpkUsdProductionStack: staging Sec Council Safe not deployed on this chain"
        );

        KpkOivFactory.StackConfig memory config = KpkOivFactory.StackConfig({
            managerSafe: KpkOivFactory.SafeConfig({owners: _managerSafeOwners(), threshold: MANAGER_SAFE_THRESHOLD}),
            execRolesMod: KpkOivFactory.RolesModifierConfig({finalOwner: STAGING_SEC_COUNCIL_SAFE}),
            subRolesMod: KpkOivFactory.RolesModifierConfig({finalOwner: address(0)}), // factory ignores; transfers to Manager Safe
            managerRolesMod: KpkOivFactory.RolesModifierConfig({finalOwner: address(0)}), // factory ignores; transfers to Manager Safe
            salt: SALT
        });

        // Pre-flight: predict, then assert addresses match the mainnet sentinels.
        KpkOivFactory.StackInstance memory predicted = KpkOivFactory(FACTORY).predictStackAddresses(config, DEPLOYER);

        require(predicted.avatarSafe == EXPECTED_AVATAR_SAFE, "Avatar Safe prediction != mainnet sentinel");
        require(predicted.managerSafe == EXPECTED_MANAGER_SAFE, "Manager Safe prediction != mainnet sentinel");
        require(predicted.execRolesModifier == EXPECTED_EXEC_ROLES_MOD, "Exec Roles Mod prediction != mainnet sentinel");
        require(predicted.subRolesModifier == EXPECTED_SUB_ROLES_MOD, "Sub Roles Mod prediction != mainnet sentinel");
        require(
            predicted.managerRolesModifier == EXPECTED_MANAGER_ROLES_MOD,
            "Manager Roles Mod prediction != mainnet sentinel"
        );

        _logConfig(config);
        _logPredicted(predicted);

        vm.startBroadcast();
        KpkOivFactory.StackInstance memory deployed = KpkOivFactory(FACTORY).deployStack(config);
        vm.stopBroadcast();

        _logDeployed(deployed);

        // Defensive: post-deploy must equal pre-deploy prediction.
        require(deployed.avatarSafe == predicted.avatarSafe, "avatarSafe deploy mismatch");
        require(deployed.managerSafe == predicted.managerSafe, "managerSafe deploy mismatch");
        require(deployed.execRolesModifier == predicted.execRolesModifier, "execRolesModifier deploy mismatch");
        require(deployed.subRolesModifier == predicted.subRolesModifier, "subRolesModifier deploy mismatch");
        require(deployed.managerRolesModifier == predicted.managerRolesModifier, "managerRolesModifier deploy mismatch");
    }

    // ── Logging ───────────────────────────────────────────────────────────────

    function _logConfig(KpkOivFactory.StackConfig memory c) internal view {
        console.log("==========================================");
        console.log("StackConfig (chainid:", block.chainid, ")");
        console.log("==========================================");
        console.log("salt (uint256):", c.salt);
        console.log("execRolesMod.finalOwner (staging Sec Council):", c.execRolesMod.finalOwner);
        console.log("managerSafe.threshold:", c.managerSafe.threshold);
        for (uint256 i = 0; i < c.managerSafe.owners.length; i++) {
            console.log("managerSafe.owners[", i, "]:", c.managerSafe.owners[i]);
        }
    }

    function _logPredicted(KpkOivFactory.StackInstance memory p) internal pure {
        console.log("==========================================");
        console.log("Predicted addresses (asserted == mainnet sentinels)");
        console.log("==========================================");
        console.log("Avatar Safe:           ", p.avatarSafe);
        console.log("Manager Safe:          ", p.managerSafe);
        console.log("Exec Roles Modifier:   ", p.execRolesModifier);
        console.log("Sub Roles Modifier:    ", p.subRolesModifier);
        console.log("Manager Roles Modifier:", p.managerRolesModifier);
    }

    function _logDeployed(KpkOivFactory.StackInstance memory d) internal pure {
        console.log("==========================================");
        console.log("DEPLOYED");
        console.log("==========================================");
        console.log("Avatar Safe:           ", d.avatarSafe);
        console.log("Manager Safe:          ", d.managerSafe);
        console.log("Exec Roles Modifier:   ", d.execRolesModifier);
        console.log("Sub Roles Modifier:    ", d.subRolesModifier);
        console.log("Manager Roles Modifier:", d.managerRolesModifier);
    }
}

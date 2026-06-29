// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {KpkOivFactory} from "../src/KpkOivFactory.sol";
import {CcipOivDeployer} from "../src/CcipOivDeployer.sol";
import {OivConfigReader} from "./base/OivConfigReader.sol";

/**
 * Purpose: Drive an already-deployed `CcipOivDeployer` to deploy a full OIV on mainnet and fan the
 *          operational stack out to sidechains over Chainlink CCIP, from a JSON config file.
 * Inputs:  The orchestrator address, a config path (same format as DeployOiv), destination CHAIN IDs
 *          (resolved to CCIP selectors by the orchestrator), and a destination gas limit. PRIVATE_KEY
 *          env var for broadcasting.
 * Entry points:
 *   - predict(orchestrator, configPath): view. Prints the 7 OIV addresses the orchestrator would
 *     produce. CALLER IS THE ORCHESTRATOR (not the EOA) — it is the factory's msg.sender on every
 *     chain — so this is the correct prediction for the CCIP flow.
 *   - quote(orchestrator, configPath, destChainIds, gasLimit): view. Prints total + per-destination
 *     NATIVE fee, to size the msg.value to send.
 *   - deployEverywhere(orchestrator, configPath, destChainIds, gasLimit): broadcast. Deploys the full
 *     OIV locally (intended for mainnet) and dispatches one CCIP message per destination chain.
 * Notes:
 *   - The config parsing lives in the shared OivConfigReader base (same as DeployOiv).
 *   - deployEverywhere is PERMISSIONLESS; any PRIVATE_KEY can broadcast it (no owner requirement).
 *   - CCIP fees are paid in NATIVE gas from msg.value; this script quotes the fee and forwards it
 *     (with a small buffer) automatically, so the broadcasting EOA just needs enough native balance.
 *     Surplus is refunded to that EOA.
 */
contract CcipDeployEverywhere is OivConfigReader {
    using stdJson for string;

    // ── Entry points ───────────────────────────────────────────────────────────

    function predict(address orchestrator, string calldata configPath) external view {
        KpkOivFactory.OivConfig memory config = _buildOivConfig(vm.readFile(configPath));
        CcipOivDeployer orch = CcipOivDeployer(payable(orchestrator));
        KpkOivFactory factory = orch.factory();
        // Use the orchestrator's predictOiv (applies the config-bound salt the deploy path uses), NOT
        // the factory's raw predictOivAddresses, which would key on the un-derived config.salt.
        KpkOivFactory.OivInstance memory predicted = orch.predictOiv(config);

        console.log("============================================================");
        console.log("  Predicted OIV addresses (caller = orchestrator)");
        console.log("============================================================");
        console.log("  Orchestrator:         ", orchestrator);
        console.log("  Factory:              ", address(factory));
        _logInstance(predicted);
        console.log("  NOTE: addresses are bound to this exact config (salt = keccak256(config)) and are");
        console.log("        identical on every chain for this orchestrator. Changing any field moves them.");
        console.log("============================================================");
    }

    function quote(address orchestrator, string calldata configPath, uint256[] calldata destChainIds, uint256 gasLimit)
        external
        view
    {
        KpkOivFactory.OivConfig memory config = _buildOivConfig(vm.readFile(configPath));
        CcipOivDeployer orch = CcipOivDeployer(payable(orchestrator));
        (uint256 totalFee, uint256[] memory feePerDestination) =
            orch.quoteDeployEverywhere(config, destChainIds, gasLimit);

        console.log("============================================================");
        console.log("  CCIP fan-out NATIVE fee quote");
        console.log("============================================================");
        console.log("  Orchestrator:         ", orchestrator);
        console.log("  Gas limit per dest:   ", gasLimit);
        for (uint256 i = 0; i < destChainIds.length; i++) {
            console.log("  chainId / fee (native wei):", destChainIds[i], feePerDestination[i]);
        }
        console.log("  TOTAL fee (native wei):", totalFee);
        console.log("  >>> Send at least this as msg.value to deployEverywhere; surplus is refunded.");
        console.log("============================================================");
    }

    function deployEverywhere(
        address orchestrator,
        string calldata configPath,
        uint256[] calldata destChainIds,
        uint256 gasLimit
    ) external {
        KpkOivFactory.OivConfig memory config = _buildOivConfig(vm.readFile(configPath));
        CcipOivDeployer orch = CcipOivDeployer(payable(orchestrator));

        // Size the native fee now and send it as msg.value, with a buffer so a fee increase between
        // this quote and the broadcast tx doesn't revert. The orchestrator refunds any surplus to the
        // broadcasting EOA. Buffer is operator-tunable via FEE_BUFFER_PCT (default 10%); raise it on
        // volatile L1 fan-outs.
        (uint256 totalFee,) = orch.quoteDeployEverywhere(config, destChainIds, gasLimit);
        uint256 bufferPct = vm.envOr("FEE_BUFFER_PCT", uint256(10));
        uint256 valueToSend = totalFee + (totalFee * bufferPct) / 100;

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        (KpkOivFactory.OivInstance memory instance, bytes32[] memory messageIds) =
            orch.deployEverywhere{value: valueToSend}(config, destChainIds, gasLimit);
        vm.stopBroadcast();

        console.log("============================================================");
        console.log("  deployEverywhere complete (local OIV deployed, CCIP dispatched)");
        console.log("============================================================");
        _logInstance(instance);
        console.log("------------------------------------------------------------");
        for (uint256 i = 0; i < messageIds.length; i++) {
            console.log("  CCIP messageId for chainId:", destChainIds[i]);
            console.logBytes32(messageIds[i]);
        }
        console.log("  Track delivery at https://ccip.chain.link");
        console.log("============================================================");
    }

    /// @notice Owner helper: seed the orchestrator's chainId → CCIP-selector mapping from the canonical
    ///         `script/ccip-networks.json` registry, for every wired DESTINATION chain (verdict READY /
    ///         READY-AFTER-EMPTY). Broadcasts `setChainSelectors` from PRIVATE_KEY, which must be the
    ///         orchestrator owner. Run only on the SOURCE orchestrator (typically mainnet) — the chain
    ///         you will call `deployEverywhere` on; sidechains resolve nothing locally (they receive a
    ///         `StackConfig` over CCIP), so they never need this mapping.
    function setChainSelectors(address orchestrator, string calldata registryPath) external {
        string memory json = vm.readFile(registryPath);

        // Single traversal into max-size scratch buffers (the registry is well under 256 entries),
        // then copy out the exact-length arrays. One pass = no count/fill drift between two loops.
        uint256[] memory idsBuf = new uint256[](256);
        uint64[] memory selBuf = new uint64[](256);
        uint256 count;
        for (uint256 i = 0; i < 256; i++) {
            string memory base = string.concat(".networks[", vm.toString(i), "]");
            if (!vm.keyExists(json, string.concat(base, ".verdict"))) break;
            if (!_seedable(json, base)) continue;
            idsBuf[count] = json.readUint(string.concat(base, ".chainId"));
            // ccipChainSelector is stored as a string in the registry. Bounds-check before the uint64
            // cast so a malformed registry value can't silently truncate into a wrong selector.
            uint256 selector = vm.parseUint(json.readString(string.concat(base, ".ccipChainSelector")));
            require(selector <= type(uint64).max, "ccipChainSelector exceeds uint64");
            selBuf[count] = uint64(selector);
            count++;
        }

        uint256[] memory chainIds = new uint256[](count);
        uint64[] memory selectors = new uint64[](count);
        for (uint256 i = 0; i < count; i++) {
            chainIds[i] = idsBuf[i];
            selectors[i] = selBuf[i];
        }

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        CcipOivDeployer(payable(orchestrator)).setChainSelectors(chainIds, selectors);
        vm.stopBroadcast();

        console.log("============================================================");
        console.log("  Seeded chainId -> CCIP selector mapping");
        console.log("============================================================");
        for (uint256 i = 0; i < chainIds.length; i++) {
            console.log("  chainId / selector:", chainIds[i], selectors[i]);
        }
        console.log("  Count:", chainIds.length);
        console.log("============================================================");
    }

    /// @dev A registry entry is seedable into the chain mapping when it is wired AND a CCIP
    ///      destination (the source chain is deployed to locally, never via CCIP).
    function _seedable(string memory json, string memory base) internal view returns (bool) {
        string memory verdict = json.readString(string.concat(base, ".verdict"));
        if (!_isWired(verdict)) return false;
        string memory role = json.readString(string.concat(base, ".role"));
        return keccak256(bytes(role)) == keccak256(bytes("destination"));
    }

    function _isWired(string memory verdict) internal pure returns (bool) {
        return keccak256(bytes(verdict)) == keccak256(bytes("READY"))
            || keccak256(bytes(verdict)) == keccak256(bytes("READY-AFTER-EMPTY"));
    }
}

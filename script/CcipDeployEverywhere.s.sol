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
 * Inputs:  The orchestrator address, a config path (same format as DeployOiv), CCIP destination
 *          selectors, and a destination gas limit. PRIVATE_KEY env var for broadcasting.
 * Entry points:
 *   - predict(orchestrator, configPath): view. Prints the 7 OIV addresses the orchestrator would
 *     produce. CALLER IS THE ORCHESTRATOR (not the EOA) — it is the factory's msg.sender on every
 *     chain — so this is the correct prediction for the CCIP flow.
 *   - quote(orchestrator, configPath, selectors, gasLimit): view. Prints total + per-destination
 *     NATIVE fee, to size the msg.value to send.
 *   - deployEverywhere(orchestrator, configPath, selectors, gasLimit): broadcast. Deploys the full
 *     OIV locally (intended for mainnet) and dispatches one CCIP message per selector.
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
        CcipOivDeployer orch = CcipOivDeployer(orchestrator);
        KpkOivFactory factory = orch.factory();
        KpkOivFactory.OivInstance memory predicted = factory.predictOivAddresses(config, orchestrator);

        console.log("============================================================");
        console.log("  Predicted OIV addresses (caller = orchestrator)");
        console.log("============================================================");
        console.log("  Orchestrator:         ", orchestrator);
        console.log("  Factory:              ", address(factory));
        console.log("  Avatar Safe:          ", predicted.avatarSafe);
        console.log("  Manager Safe:         ", predicted.managerSafe);
        console.log("  execRolesModifier:    ", predicted.execRolesModifier);
        console.log("  subRolesModifier:     ", predicted.subRolesModifier);
        console.log("  managerRolesModifier: ", predicted.managerRolesModifier);
        console.log("  kpkShares impl:       ", predicted.kpkSharesImpl);
        console.log("  kpkShares proxy:      ", predicted.kpkSharesProxy);
        console.log("  NOTE: stack addresses are identical on every chain for this orchestrator+salt.");
        console.log("============================================================");
    }

    function quote(address orchestrator, string calldata configPath, uint256[] calldata destChainIds, uint256 gasLimit)
        external
        view
    {
        KpkOivFactory.OivConfig memory config = _buildOivConfig(vm.readFile(configPath));
        CcipOivDeployer orch = CcipOivDeployer(orchestrator);
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
        CcipOivDeployer orch = CcipOivDeployer(orchestrator);

        // Size the native fee now and send it as msg.value, with a 10% buffer so a small fee increase
        // between this quote and the broadcast tx doesn't revert. The orchestrator refunds any surplus
        // to the broadcasting EOA.
        (uint256 totalFee,) = orch.quoteDeployEverywhere(config, destChainIds, gasLimit);
        uint256 valueToSend = totalFee + totalFee / 10;

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        (KpkOivFactory.OivInstance memory instance, bytes32[] memory messageIds) =
            orch.deployEverywhere{value: valueToSend}(config, destChainIds, gasLimit);
        vm.stopBroadcast();

        console.log("============================================================");
        console.log("  deployEverywhere complete (local OIV deployed, CCIP dispatched)");
        console.log("============================================================");
        console.log("  Avatar Safe:          ", instance.avatarSafe);
        console.log("  Manager Safe:         ", instance.managerSafe);
        console.log("  execRolesModifier:    ", instance.execRolesModifier);
        console.log("  subRolesModifier:     ", instance.subRolesModifier);
        console.log("  managerRolesModifier: ", instance.managerRolesModifier);
        console.log("  kpkShares impl:       ", instance.kpkSharesImpl);
        console.log("  kpkShares proxy:      ", instance.kpkSharesProxy);
        console.log("------------------------------------------------------------");
        for (uint256 i = 0; i < messageIds.length; i++) {
            console.log("  CCIP messageId for chainId:", destChainIds[i]);
            console.logBytes32(messageIds[i]);
        }
        console.log("  Track delivery at https://ccip.chain.link");
        console.log("============================================================");
    }

    /// @notice Owner helper: seed the orchestrator's chainId → CCIP-selector mapping from the canonical
    ///         `script/ccip-networks.json` registry, for every wired chain (verdict READY /
    ///         READY-AFTER-EMPTY). Broadcasts `setChainSelectors` from PRIVATE_KEY, which must be the
    ///         orchestrator owner. Run once per chain after deploying the orchestrator there.
    function setChainSelectors(address orchestrator, string calldata registryPath) external {
        string memory json = vm.readFile(registryPath);

        // Two passes (array length is not known up front): count wired networks, then fill.
        uint256 count;
        for (uint256 i = 0; i < 256; i++) {
            string memory verdictKey = string.concat(".networks[", vm.toString(i), "].verdict");
            if (!vm.keyExists(json, verdictKey)) break;
            if (_isWired(json.readString(verdictKey))) count++;
        }

        uint256[] memory chainIds = new uint256[](count);
        uint64[] memory selectors = new uint64[](count);
        uint256 w;
        for (uint256 i = 0; i < 256; i++) {
            string memory base = string.concat(".networks[", vm.toString(i), "]");
            if (!vm.keyExists(json, string.concat(base, ".verdict"))) break;
            if (!_isWired(json.readString(string.concat(base, ".verdict")))) continue;
            chainIds[w] = json.readUint(string.concat(base, ".chainId"));
            // ccipChainSelector is stored as a string in the registry.
            selectors[w] = uint64(vm.parseUint(json.readString(string.concat(base, ".ccipChainSelector"))));
            w++;
        }

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        CcipOivDeployer(orchestrator).setChainSelectors(chainIds, selectors);
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

    function _isWired(string memory verdict) internal pure returns (bool) {
        return keccak256(bytes(verdict)) == keccak256(bytes("READY"))
            || keccak256(bytes(verdict)) == keccak256(bytes("READY-AFTER-EMPTY"));
    }
}

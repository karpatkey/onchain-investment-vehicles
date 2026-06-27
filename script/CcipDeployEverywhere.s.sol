// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
 *   - quote(orchestrator, configPath, selectors, gasLimit): view. Prints total + per-destination LINK
 *     fee and the orchestrator's current LINK balance, to size pre-funding.
 *   - deployEverywhere(orchestrator, configPath, selectors, gasLimit): broadcast. Deploys the full
 *     OIV locally (intended for mainnet) and dispatches one CCIP message per selector.
 * Notes:
 *   - The config parsing lives in the shared OivConfigReader base (same as DeployOiv).
 *   - deployEverywhere is onlyOwner on the orchestrator; PRIVATE_KEY must be the orchestrator owner.
 *   - CCIP fees are paid in LINK from the orchestrator's balance; fund it before broadcasting.
 */
contract CcipDeployEverywhere is OivConfigReader {
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

    function quote(address orchestrator, string calldata configPath, uint64[] calldata selectors, uint256 gasLimit)
        external
        view
    {
        KpkOivFactory.OivConfig memory config = _buildOivConfig(vm.readFile(configPath));
        CcipOivDeployer orch = CcipOivDeployer(orchestrator);
        (uint256 totalFee, uint256[] memory feePerDestination) = orch.quoteDeployEverywhere(config, selectors, gasLimit);

        uint256 linkBalance = IERC20(orch.linkToken()).balanceOf(orchestrator);

        console.log("============================================================");
        console.log("  CCIP fan-out LINK quote");
        console.log("============================================================");
        console.log("  Orchestrator:         ", orchestrator);
        console.log("  Gas limit per dest:   ", gasLimit);
        for (uint256 i = 0; i < selectors.length; i++) {
            console.log("  selector / fee (LINK wei):", selectors[i], feePerDestination[i]);
        }
        console.log("  TOTAL fee (LINK wei): ", totalFee);
        console.log("  Orchestrator LINK bal:", linkBalance);
        if (linkBalance < totalFee) {
            console.log("  >>> UNDERFUNDED: send at least", totalFee - linkBalance, "more LINK wei to orchestrator");
        } else {
            console.log("  >>> Funded sufficiently.");
        }
        console.log("============================================================");
    }

    function deployEverywhere(
        address orchestrator,
        string calldata configPath,
        uint64[] calldata selectors,
        uint256 gasLimit
    ) external {
        KpkOivFactory.OivConfig memory config = _buildOivConfig(vm.readFile(configPath));
        CcipOivDeployer orch = CcipOivDeployer(orchestrator);

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        (KpkOivFactory.OivInstance memory instance, bytes32[] memory messageIds) =
            orch.deployEverywhere(config, selectors, gasLimit);
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
            console.log("  CCIP messageId for selector:", selectors[i]);
            console.logBytes32(messageIds[i]);
        }
        console.log("  Track delivery at https://ccip.chain.link");
        console.log("============================================================");
    }
}

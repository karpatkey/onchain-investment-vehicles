// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console} from "forge-std/Script.sol";
import {OivChainDeploy} from "./base/OivChainDeploy.sol";
import {KpkOivFactory} from "../src/KpkOivFactory.sol";

/// @title  DeployKpkOivFactory
/// @notice Deploys the `KpkShares` mastercopy and `KpkOivFactory` deterministically across every chain via
///         the canonical CREATE2 deployer, producing identical addresses on every chain. The
///         address-critical constants/salts/init-code live in `OivChainDeploy` (the single source of
///         truth shared with the per-chain scripts), so the standalone and per-chain paths can never
///         drift to different factory addresses. The factory bakes in the PATCHED Roles Modifier
///         v2.1.1 mastercopy (`0xF2964CE6…83D5`).
///
/// @dev    Flow: pre-compute predicted addresses → CREATE2 factory (idempotent) → CREATE2 deployer
///         (idempotent) → `setKpkSharesMastercopy` → `transferOwnership(finalOwner)`.
///
/// Usage (per chain):
///   source .env && forge script script/DeployKpkOivFactory.s.sol:DeployKpkOivFactory \
///     --rpc-url <chain> --account $DEPLOYER_NAME --broadcast --verify \
///     --sig "run(address,address)" <eoaOwner> <finalOwner>
///
/// `<eoaOwner>` MUST equal the broadcasting account (it calls the onlyOwner setters and is baked
/// into the factory's CREATE2 init-code — enforced below).
contract DeployKpkOivFactory is OivChainDeploy {
    function run(address eoaOwner, address finalOwner) external {
        require(eoaOwner != address(0), "eoaOwner is zero");
        require(finalOwner != address(0), "finalOwner is zero");
        require(msg.sender == eoaOwner, "broadcasting sender must equal eoaOwner");

        bytes memory factoryInitCode = _factoryInitCode(eoaOwner);
        address predictedFactory = _create2Address(SALT_FACTORY, factoryInitCode);
        bytes memory deployerInitCode = _sharesMastercopyInitCode();
        address predictedDeployer = _create2Address(SALT_SHARES_MASTERCOPY, deployerInitCode);

        console.log("==========================================");
        console.log("Predicted KpkOivFactory:    ", predictedFactory);
        console.log("Predicted KpkShares mastercopy:", predictedDeployer);
        console.log("EOA owner (during deploy):  ", eoaOwner);
        console.log("Final owner (post-deploy):  ", finalOwner);
        console.log("==========================================");

        vm.startBroadcast();

        // Same preflight `_runChain` performs. This standalone path is documented in README.md as a
        // per-chain onboarding entry point, so without these a chain can be wired with a working
        // factory and no `Empty` / MultiSendUnwrapper — every later fund deploy on it then reverts,
        // including a CCIP fan-out delivery whose fee was already spent on the source chain.
        _ensureEmpty();
        _ensureMultiSendUnwrapper();

        if (predictedFactory.code.length == 0) {
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(SALT_FACTORY, factoryInitCode));
            require(ok, "factory CREATE2 deploy failed");
            console.log("[OK]   KpkOivFactory deployed at:    ", predictedFactory);
        } else {
            console.log("[SKIP] KpkOivFactory already at:     ", predictedFactory);
        }

        if (predictedDeployer.code.length == 0) {
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(SALT_SHARES_MASTERCOPY, deployerInitCode));
            require(ok, "deployer CREATE2 deploy failed");
            console.log("[OK]   KpkShares mastercopy deployed at:", predictedDeployer);
        } else {
            console.log("[SKIP] KpkShares mastercopy already at: ", predictedDeployer);
        }

        KpkOivFactory factory = KpkOivFactory(predictedFactory);
        if (factory.kpkSharesMastercopy() == address(0)) {
            factory.setKpkSharesMastercopy(predictedDeployer);
            console.log("[OK]   factory.kpkSharesMastercopy set");
        } else if (factory.kpkSharesMastercopy() == predictedDeployer) {
            console.log("[SKIP] factory.kpkSharesMastercopy already wired");
        } else {
            revert("factory.kpkSharesMastercopy is set to an unexpected address");
        }

        // Checked BEFORE the handover, which is the only irreversible step here. This script wires
        // the shares mastercopy but never `timelockDeployer` — only the per-chain
        // `script/chains/Deploy_<Chain>.s.sol` scripts (via OivChainDeploy) do — so a chain onboarded
        // through this script alone looks healthy and then reverts `TimelockDeployerNotSet` on every
        // timelocked fund, and in a CCIP fan-out the destination reverts with the source-chain fee
        // already spent.
        //
        // Position matters more than it looks. A plain `forge script --broadcast` simulates the whole
        // body first, so a revert anywhere aborts before anything is sent; but a run whose BROADCAST
        // phase fails part-way and is resumed with `--resume` replays the saved transactions without
        // re-running this body. Placing the refusal ahead of `transferOwnership` means that in that
        // case the saved set cannot contain the handover, so ownership never reaches the Safe and
        // `setTimelockDeployer` — `onlyOwner` — is still reachable from the deployer EOA.
        require(
            factory.timelockDeployer() != address(0),
            "timelockDeployer not wired - use script/chains/Deploy_<Chain>.s.sol, not this script"
        );

        if (factory.owner() == eoaOwner && eoaOwner != finalOwner) {
            factory.transferOwnership(finalOwner);
            console.log("[OK]   transferOwnership ->", finalOwner);
        } else if (factory.owner() == finalOwner) {
            console.log("[SKIP] factory already owned by:     ", finalOwner);
        } else if (factory.owner() != eoaOwner) {
            revert("factory.owner is unexpected; refusing to handoff");
        }

        vm.stopBroadcast();

        require(KpkOivFactory(predictedFactory).owner() == finalOwner, "post-flight: owner mismatch");
        // Backstop only — the in-broadcast check above fires first and before the handover. Kept
        // because this one also covers a run that reached here by some path the other did not.
        require(
            KpkOivFactory(predictedFactory).timelockDeployer() != address(0),
            "post-flight: timelockDeployer not wired - use script/chains/Deploy_<Chain>.s.sol, not this script"
        );
        require(
            KpkOivFactory(predictedFactory).kpkSharesMastercopy() == predictedDeployer,
            "post-flight: kpkSharesMastercopy mismatch"
        );
        require(predictedDeployer.code.length != 0, "post-flight: shares mastercopy has no code");

        console.log("==========================================");
        console.log("[OK] Deployment verified");
        console.log("KpkOivFactory:     ", predictedFactory);
        console.log("KpkShares mastercopy: ", predictedDeployer);
        console.log("Owner:             ", finalOwner);
        console.log("==========================================");
    }
}

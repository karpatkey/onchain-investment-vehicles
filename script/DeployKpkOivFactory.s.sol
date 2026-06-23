// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console} from "forge-std/Script.sol";
import {OivChainDeploy} from "./base/OivChainDeploy.sol";
import {KpkOivFactory} from "../src/KpkOivFactory.sol";
import {KpkSharesDeployer} from "../src/KpkSharesDeployer.sol";

/// @title  DeployKpkOivFactory
/// @notice Deploys `KpkSharesDeployer` and `KpkOivFactory` deterministically across every chain via
///         the canonical CREATE2 deployer, producing identical addresses on every chain. The
///         address-critical constants/salts/init-code live in `OivChainDeploy` (the single source of
///         truth shared with the per-chain scripts), so the standalone and per-chain paths can never
///         drift to different factory addresses. The factory bakes in the PATCHED Roles Modifier
///         v2.1.1 mastercopy (`0xF2964CE6…83D5`).
///
/// @dev    Flow: pre-compute predicted addresses → CREATE2 factory (idempotent) → CREATE2 deployer
///         (idempotent) → `setKpkSharesDeployer` → `transferOwnership(finalOwner)`.
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
        bytes memory deployerInitCode = _deployerInitCode(predictedFactory);
        address predictedDeployer = _create2Address(SALT_DEPLOYER, deployerInitCode);

        console.log("==========================================");
        console.log("Predicted KpkOivFactory:    ", predictedFactory);
        console.log("Predicted KpkSharesDeployer:", predictedDeployer);
        console.log("EOA owner (during deploy):  ", eoaOwner);
        console.log("Final owner (post-deploy):  ", finalOwner);
        console.log("==========================================");

        vm.startBroadcast();

        if (predictedFactory.code.length == 0) {
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(SALT_FACTORY, factoryInitCode));
            require(ok, "factory CREATE2 deploy failed");
            console.log("[OK]   KpkOivFactory deployed at:    ", predictedFactory);
        } else {
            console.log("[SKIP] KpkOivFactory already at:     ", predictedFactory);
        }

        if (predictedDeployer.code.length == 0) {
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(SALT_DEPLOYER, deployerInitCode));
            require(ok, "deployer CREATE2 deploy failed");
            console.log("[OK]   KpkSharesDeployer deployed at:", predictedDeployer);
        } else {
            console.log("[SKIP] KpkSharesDeployer already at: ", predictedDeployer);
        }

        KpkOivFactory factory = KpkOivFactory(predictedFactory);
        if (factory.kpkSharesDeployer() == address(0)) {
            factory.setKpkSharesDeployer(predictedDeployer);
            console.log("[OK]   factory.kpkSharesDeployer set");
        } else if (factory.kpkSharesDeployer() == predictedDeployer) {
            console.log("[SKIP] factory.kpkSharesDeployer already wired");
        } else {
            revert("factory.kpkSharesDeployer is set to an unexpected address");
        }

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
        require(
            KpkOivFactory(predictedFactory).kpkSharesDeployer() == predictedDeployer,
            "post-flight: kpkSharesDeployer mismatch"
        );
        require(
            KpkSharesDeployer(predictedDeployer).factory() == predictedFactory, "post-flight: deployer.factory mismatch"
        );

        console.log("==========================================");
        console.log("[OK] Deployment verified");
        console.log("KpkOivFactory:     ", predictedFactory);
        console.log("KpkSharesDeployer: ", predictedDeployer);
        console.log("Owner:             ", finalOwner);
        console.log("==========================================");
    }
}

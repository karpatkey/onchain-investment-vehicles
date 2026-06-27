// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console} from "forge-std/Script.sol";
import {OivChainDeploy} from "./base/OivChainDeploy.sol";
import {CcipOivDeployer} from "../src/CcipOivDeployer.sol";

/// @title  DeployCcipOivDeployer
/// @notice Deploys `CcipOivDeployer` deterministically (same address on every chain — mandatory, as
///         destination-side `ccipReceive` trusts a source sender equal to its own address), then
///         `configure`s per-chain CCIP params and hands off ownership. The CREATE2 salt + init-code
///         builder live in `OivChainDeploy` (shared single source of truth).
///
/// @dev    Only `_owner` and the factory address are baked into the orchestrator's creation code, so
///         the CCIP Router/LINK (which differ per chain) are wired post-deploy via `configure`.
///         `factory` MUST be the redeployed v2.1.1 factory address (NOT the legacy `0x0d94…d420` —
///         guarded below — whose Roles proxies are vulnerable and whose address diverges from the
///         per-chain `OivChainDeploy` path). Take it from the `DeployKpkOivFactory` run that precedes
///         this one.
///
/// Usage (per chain):
///   source .env && forge script script/DeployCcipOivDeployer.s.sol:DeployCcipOivDeployer \
///     --rpc-url <chain> --account $DEPLOYER_NAME --broadcast \
///     --sig "run(address,address,address,address,address,uint64)" \
///     <eoaOwner> <finalOwner> <factory> <ccipRouter> <linkToken> 5009297550715157269
contract DeployCcipOivDeployer is OivChainDeploy {
    function run(
        address eoaOwner,
        address finalOwner,
        address factory,
        address ccipRouter,
        address linkToken,
        uint64 mainnetSelector
    ) external {
        require(eoaOwner != address(0), "eoaOwner is zero");
        require(finalOwner != address(0), "finalOwner is zero");
        require(factory != address(0), "factory is zero");
        require(factory != LEGACY_FACTORY, "factory is the legacy pre-v2.1.1 build; use the redeployed v2.1.1 factory");
        // The orchestrator's CREATE2 address depends on the factory baked into its init-code, so the
        // factory MUST be the canonical v2.1.1 build for this eoaOwner — otherwise the orchestrator
        // lands at a different address than the per-chain `_runChain` path and cross-chain
        // `ccipReceive` (which trusts a source sender equal to its own address) rejects messages.
        // This also guarantees the patched Roles v2.1.1 mastercopy is the one baked in.
        require(
            factory == _predictFactory(eoaOwner),
            "factory is not the canonical v2.1.1 CREATE2 factory for this eoaOwner"
        );
        require(ccipRouter != address(0), "ccipRouter is zero");
        require(linkToken != address(0), "linkToken is zero");
        require(mainnetSelector != 0, "mainnetSelector is zero");
        require(factory.code.length > 0, "KpkOivFactory not deployed on this chain");
        require(msg.sender == eoaOwner, "broadcasting sender must equal eoaOwner");

        bytes memory initCode = _orchestratorInitCode(eoaOwner, factory);
        address predicted = _create2Address(SALT_CCIP, initCode);

        console.log("==========================================");
        console.log("Predicted CcipOivDeployer:", predicted);
        console.log("KpkOivFactory:            ", factory);
        console.log("EOA owner (during deploy):", eoaOwner);
        console.log("Final owner (post-deploy):", finalOwner);
        console.log("CCIP router:              ", ccipRouter);
        console.log("LINK token:               ", linkToken);
        console.log("Mainnet selector:         ", mainnetSelector);
        console.log("==========================================");

        vm.startBroadcast();

        if (predicted.code.length == 0) {
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(SALT_CCIP, initCode));
            require(ok, "CcipOivDeployer CREATE2 deploy failed");
            console.log("[OK]   CcipOivDeployer deployed at:", predicted);
        } else {
            console.log("[SKIP] CcipOivDeployer already at: ", predicted);
        }

        CcipOivDeployer orchestrator = CcipOivDeployer(predicted);

        if (orchestrator.owner() == eoaOwner) {
            if (
                orchestrator.router() != ccipRouter || orchestrator.linkToken() != linkToken
                    || orchestrator.mainnetChainSelector() != mainnetSelector
            ) {
                orchestrator.configure(ccipRouter, linkToken, mainnetSelector);
                console.log("[OK]   configure() done");
            } else {
                console.log("[SKIP] already configured");
            }
            if (eoaOwner != finalOwner) {
                orchestrator.transferOwnership(finalOwner);
                console.log("[OK]   transferOwnership ->", finalOwner);
            }
        } else if (orchestrator.owner() == finalOwner) {
            console.log("[SKIP] already owned by finalOwner; configure via the owner directly");
        } else {
            revert("orchestrator.owner is unexpected; refusing to proceed");
        }

        vm.stopBroadcast();

        require(address(orchestrator.factory()) == factory, "post-flight: factory mismatch");

        bool configured = orchestrator.router() == ccipRouter && orchestrator.linkToken() == linkToken
            && orchestrator.mainnetChainSelector() == mainnetSelector;

        console.log("==========================================");
        if (configured) {
            console.log("[OK] CcipOivDeployer ready at:", predicted);
        } else if (orchestrator.owner() == finalOwner) {
            console.log("[WARN] deployed but NOT fully configured; finalOwner must call configure() with:");
            console.log("  router:  ", ccipRouter);
            console.log("  link:    ", linkToken);
            console.log("  selector:", mainnetSelector);
        } else {
            revert("post-flight: orchestrator not configured as expected");
        }
        console.log("==========================================");
    }
}

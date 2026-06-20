// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {CcipOivDeployer} from "../src/CcipOivDeployer.sol";

/// @title  DeployCcipOivDeployer
/// @notice Deploys `CcipOivDeployer` deterministically across every chain via the canonical CREATE2
///         deployer (`0x4e59b44847b379578588920cA78FbF26c0B4956C`), then wires the per-chain CCIP
///         parameters and hands off ownership. Producing an IDENTICAL orchestrator address on every
///         chain is mandatory: the orchestrator is the uniform `KpkOivFactory` caller, and the
///         destination-side `ccipReceive` trusts a source sender equal to its own address.
///
/// @dev    Determinism rule: only `_owner` and the `KpkOivFactory` address (both identical on every
///         chain) are baked into the creation code. The CCIP Router and LINK token differ per chain,
///         so they are NOT constructor args — they are wired post-deploy via `configure(...)` while
///         the broadcasting EOA still owns the contract, before ownership is handed off.
///
///         Steps (idempotent):
///           1. Pre-compute the orchestrator's CREATE2 address (chain-identical by construction).
///           2. Deploy it via the canonical CREATE2 deployer (skipped if already deployed).
///           3. `configure(router, linkToken, mainnetSelector)` with the operator-supplied,
///              pre-verified per-chain values.
///           4. `transferOwnership(finalOwner)`.
///
///         CCIP router / LINK / chain-selector values per chain live in `script/ccip-networks.json`
///         (the operator reference — 23 READY mainnets). They are passed to this script as args
///         precisely so no unverified infra is hard-coded in Solidity. VERIFY the values you pass
///         against https://docs.chain.link/ccip/directory/mainnet immediately before broadcasting;
///         entries flagged `linkVerified: false` in the registry MUST be confirmed first.
///         See `docs/CCIP_CROSS_CHAIN_DEPLOY.md` for the full network table and the checklist for
///         onboarding a new chain.
///
///         `mainnetSelector` is the SAME on every chain (the trusted source = Ethereum mainnet =
///         5009297550715157269), regardless of which chain you are deploying to.
///
/// Usage (per chain — example: Base):
///
///   source .env && forge script script/DeployCcipOivDeployer.s.sol:DeployCcipOivDeployer \
///     --rpc-url base \
///     --account $DEPLOYER_NAME \
///     --broadcast \
///     --sig "run(address,address,address,address,uint64)" \
///     <eoaOwner> <finalOwner> <ccipRouter> <linkToken> 5009297550715157269
contract DeployCcipOivDeployer is Script {
    /// @notice Arachnid-style canonical CREATE2 deployer, present at the same address on every
    ///         major EVM chain. Calldata: `salt (32 bytes) || init_code (N bytes)`.
    address internal constant CANONICAL_CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice `KpkOivFactory` — deployed at the same address on every chain, so it is safe to bake
    ///         into the orchestrator's creation code without breaking address determinism.
    ///         WARNING: the orchestrator calls `factory.oivToStackConfig` at runtime, which the
    ///         factory build at this published address does NOT expose. That helper changes the
    ///         factory's creation code and therefore its CREATE2 address, so the factory must be
    ///         redeployed and THIS constant updated to the new address before deploying the
    ///         orchestrator. (Bump this and `SALT` together if the factory address changes.)
    address internal constant FACTORY = 0x0d94255fdE65D302616b02A2F070CdB21190d420;

    /// @dev Bump the version uint to redeploy at a fresh address.
    bytes32 internal constant SALT = keccak256(abi.encodePacked("CcipOivDeployer", uint256(1)));

    /// @param eoaOwner        Initial owner — MUST equal the broadcasting EOA (it calls `configure`
    ///                        and `transferOwnership`). Baked into the creation code, so the same
    ///                        EOA must be used on every chain for an identical orchestrator address.
    /// @param finalOwner      Address that receives ownership after wiring (a governance multisig).
    /// @param ccipRouter      CCIP Router on THIS chain (verify against the CCIP directory).
    /// @param linkToken       LINK token used for CCIP fees on THIS chain.
    /// @param mainnetSelector CCIP chain selector of Ethereum mainnet (same value on every chain).
    function run(address eoaOwner, address finalOwner, address ccipRouter, address linkToken, uint64 mainnetSelector)
        external
    {
        require(eoaOwner != address(0), "eoaOwner is zero");
        require(finalOwner != address(0), "finalOwner is zero");
        require(ccipRouter != address(0), "ccipRouter is zero");
        require(linkToken != address(0), "linkToken is zero");
        require(mainnetSelector != 0, "mainnetSelector is zero");
        require(FACTORY.code.length > 0, "KpkOivFactory not deployed on this chain");

        bytes memory initCode = abi.encodePacked(type(CcipOivDeployer).creationCode, abi.encode(eoaOwner, FACTORY));
        address predicted = _computeCreate2(SALT, initCode);

        console.log("==========================================");
        console.log("Predicted CcipOivDeployer:", predicted);
        console.log("KpkOivFactory:            ", FACTORY);
        console.log("EOA owner (during deploy):", eoaOwner);
        console.log("Final owner (post-deploy):", finalOwner);
        console.log("CCIP router:              ", ccipRouter);
        console.log("LINK token:               ", linkToken);
        console.log("Mainnet selector:         ", mainnetSelector);
        console.log("==========================================");

        vm.startBroadcast();

        // ── 1. Deploy at predicted address (idempotent) ──
        if (predicted.code.length == 0) {
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(SALT, initCode));
            require(ok, "CcipOivDeployer CREATE2 deploy failed");
            console.log("[OK]   CcipOivDeployer deployed at:", predicted);
        } else {
            console.log("[SKIP] CcipOivDeployer already at: ", predicted);
        }

        CcipOivDeployer orchestrator = CcipOivDeployer(predicted);

        // ── 2. Wire per-chain CCIP config (while EOA still owns it) ──
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

            // ── 3. Hand off ownership ──
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

        // ── 4. Post-flight verification ──
        require(address(orchestrator.factory()) == FACTORY, "post-flight: factory mismatch");

        bool configured = orchestrator.router() == ccipRouter && orchestrator.linkToken() == linkToken
            && orchestrator.mainnetChainSelector() == mainnetSelector;

        console.log("==========================================");
        if (configured) {
            console.log("[OK] CcipOivDeployer ready at:", predicted);
        } else if (orchestrator.owner() == finalOwner) {
            // Ownership was already handed to finalOwner (e.g. a prior partial run) but the config is
            // incomplete. This script can no longer call configure() — finalOwner must do it. Don't
            // revert: the deploy itself succeeded; surface the remaining step instead.
            console.log("[WARN] deployed but NOT fully configured; finalOwner must call configure() with:");
            console.log("  router:  ", ccipRouter);
            console.log("  link:    ", linkToken);
            console.log("  selector:", mainnetSelector);
        } else {
            // EOA still owns it, so step 2 should have configured it — a mismatch here is a real bug.
            revert("post-flight: orchestrator not configured as expected");
        }
        console.log("==========================================");
    }

    /// @dev Mirrors `keccak256(0xff || deployer || salt || keccak256(initCode))[12:]`.
    function _computeCreate2(bytes32 salt, bytes memory initCode) internal pure returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), CANONICAL_CREATE2_DEPLOYER, salt, keccak256(initCode)))
                )
            )
        );
    }
}

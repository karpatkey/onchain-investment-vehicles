// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {KpkOivFactory} from "../../src/KpkOivFactory.sol";
import {KpkSharesDeployer} from "../../src/KpkSharesDeployer.sol";
import {CcipOivDeployer} from "../../src/CcipOivDeployer.sol";

/// @title  OivChainDeploy
/// @notice Shared deploy logic for the per-chain scripts in `script/chains/`. In one broadcast it:
///           1. ensures the `Empty` contract is at its canonical address (onboards it if missing),
///           2. deploys `KpkOivFactory` + `KpkSharesDeployer` deterministically (idempotent),
///           3. deploys + `configure`s the `CcipOivDeployer` orchestrator deterministically.
///         All three produce identical addresses on every chain (CREATE2 + caller-mixing handled by
///         the contracts themselves), so the only per-chain inputs are the CCIP router + LINK token.
///
/// @dev    Mirrors `script/DeployKpkOivFactory.s.sol` and `script/DeployCcipOivDeployer.s.sol`
///         byte-for-byte for the init-code (same salts, same constructor args incl. the PATCHED
///         Roles v2.1.1 mastercopy) so the per-chain path yields the same factory/orchestrator
///         addresses as the standalone scripts. Broadcasts with the CLI `--private-key`/`--account`
///         sender, which MUST equal `eoaOwner`.
abstract contract OivChainDeploy is Script {
    // ── Canonical infra (same address on every chain) ──────────────────────────
    address internal constant CANONICAL_CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant SAFE_PROXY_FACTORY = 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2;
    address internal constant SAFE_SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address internal constant SAFE_MODULE_SETUP = 0x2dd68b007B46fBe91B9A7c3EDa5A7a1063cB5b47;
    address internal constant SAFE_FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;
    address internal constant MODULE_PROXY_FACTORY = 0x000000000000aDdB49795b0f9bA5BC298cDda236;
    // Roles Modifier v2.1.1 (PATCHED — v2.1.0 0x9646fDAD... had the June-2026 ERC-1271 auth-bypass).
    address internal constant ROLES_MODIFIER_MASTERCOPY = 0xF2964CE6161ce0e75964Fe7927cE114cb0B283D5;

    // ── Empty onboarding ───────────────────────────────────────────────────────
    address internal constant EMPTY = 0xA4703438f8cc4fc2C2503a7e43935Da16BA74652;
    address internal constant EMPTY_HELPER_FACTORY = 0x7cbB62EaA69F79e6873cD1ecB2392971036cFAa4;
    bytes internal constant EMPTY_CREATE_CALLDATA =
        hex"4847be6f00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000060307831313933333333333331393235323536383234373334353633343131000000000000000000000000000000000000000000000000000000000000000000586080604052348015600e575f5ffd5b50603e80601a5f395ff3fe60806040525f5ffdfea2646970667358221220dddfa414d3e674246761d7c4ce7ba241adbe729cb02d75a50b9cac1086c72cdf64736f6c634300081b00330000000000000000";

    // ── Deterministic salts ────────────────────────────────────────────────────
    bytes32 internal constant SALT_FACTORY = keccak256(abi.encodePacked("KpkOivFactory", uint256(1)));
    bytes32 internal constant SALT_DEPLOYER = keccak256(abi.encodePacked("KpkSharesDeployer", uint256(1)));
    bytes32 internal constant SALT_CCIP = keccak256(abi.encodePacked("CcipOivDeployer", uint256(1)));

    /// @notice CCIP selector of Ethereum mainnet — the trusted source on every chain.
    uint64 internal constant MAINNET_SELECTOR = 5009297550715157269;

    /// @notice Full per-chain deploy: Empty preflight → factory → orchestrator, in one broadcast.
    /// @param eoaOwner   Initial owner (MUST equal the broadcasting sender; baked into init-code).
    /// @param finalOwner Owner after handoff (pass == eoaOwner to keep control, e.g. for testing).
    /// @param ccipRouter CCIP Router on THIS chain.
    /// @param linkToken  CCIP LINK fee token on THIS chain.
    function _runChain(address eoaOwner, address finalOwner, address ccipRouter, address linkToken) internal {
        require(eoaOwner != address(0) && finalOwner != address(0), "owner is zero");
        require(ccipRouter != address(0) && linkToken != address(0), "ccip arg is zero");

        // ── Predict addresses (chain-identical) ──
        bytes memory factoryInitCode = abi.encodePacked(
            type(KpkOivFactory).creationCode,
            abi.encode(
                eoaOwner,
                SAFE_PROXY_FACTORY,
                SAFE_SINGLETON,
                SAFE_MODULE_SETUP,
                SAFE_FALLBACK_HANDLER,
                MODULE_PROXY_FACTORY,
                ROLES_MODIFIER_MASTERCOPY,
                address(0)
            )
        );
        address factory = _create2Address(SALT_FACTORY, factoryInitCode);
        bytes memory deployerInitCode = abi.encodePacked(type(KpkSharesDeployer).creationCode, abi.encode(factory));
        address deployer = _create2Address(SALT_DEPLOYER, deployerInitCode);
        bytes memory ccipInitCode = abi.encodePacked(type(CcipOivDeployer).creationCode, abi.encode(eoaOwner, factory));
        address orchestrator = _create2Address(SALT_CCIP, ccipInitCode);

        console.log("==========================================");
        console.log("Chain id:                ", block.chainid);
        console.log("Predicted KpkOivFactory: ", factory);
        console.log("Predicted KpkSharesDeployer:", deployer);
        console.log("Predicted CcipOivDeployer:", orchestrator);
        console.log("CCIP router:             ", ccipRouter);
        console.log("LINK token:              ", linkToken);
        console.log("==========================================");

        vm.startBroadcast();

        // ── 1. Empty preflight ──
        if (EMPTY.code.length == 0) {
            require(EMPTY_HELPER_FACTORY.code.length > 0, "Empty helper factory missing on this chain");
            (bool eok,) = EMPTY_HELPER_FACTORY.call(EMPTY_CREATE_CALLDATA);
            require(eok, "Empty deploy failed");
            require(EMPTY.code.length > 0, "Empty not at canonical address");
            console.log("[OK]   Empty deployed at:            ", EMPTY);
        } else {
            console.log("[SKIP] Empty already at:             ", EMPTY);
        }

        // ── 2. Factory + deployer ──
        if (factory.code.length == 0) {
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(SALT_FACTORY, factoryInitCode));
            require(ok, "factory CREATE2 deploy failed");
            console.log("[OK]   KpkOivFactory deployed at:    ", factory);
        } else {
            console.log("[SKIP] KpkOivFactory already at:     ", factory);
        }
        if (deployer.code.length == 0) {
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(SALT_DEPLOYER, deployerInitCode));
            require(ok, "deployer CREATE2 deploy failed");
            console.log("[OK]   KpkSharesDeployer deployed at:", deployer);
        } else {
            console.log("[SKIP] KpkSharesDeployer already at: ", deployer);
        }

        KpkOivFactory f = KpkOivFactory(factory);
        if (f.kpkSharesDeployer() == address(0)) {
            f.setKpkSharesDeployer(deployer);
            console.log("[OK]   factory.kpkSharesDeployer set");
        } else {
            require(f.kpkSharesDeployer() == deployer, "factory deployer mismatch");
        }
        if (f.owner() == eoaOwner && eoaOwner != finalOwner) {
            f.transferOwnership(finalOwner);
        }

        // ── 3. Orchestrator + configure ──
        if (orchestrator.code.length == 0) {
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(SALT_CCIP, ccipInitCode));
            require(ok, "orchestrator CREATE2 deploy failed");
            console.log("[OK]   CcipOivDeployer deployed at:  ", orchestrator);
        } else {
            console.log("[SKIP] CcipOivDeployer already at:   ", orchestrator);
        }
        CcipOivDeployer orch = CcipOivDeployer(orchestrator);
        if (orch.owner() == eoaOwner) {
            if (
                orch.router() != ccipRouter || orch.linkToken() != linkToken
                    || orch.mainnetChainSelector() != MAINNET_SELECTOR
            ) {
                orch.configure(ccipRouter, linkToken, MAINNET_SELECTOR);
                console.log("[OK]   orchestrator configured");
            }
            if (eoaOwner != finalOwner) orch.transferOwnership(finalOwner);
        }

        vm.stopBroadcast();

        // ── Post-flight ──
        require(KpkOivFactory(factory).kpkSharesDeployer() == deployer, "post: deployer not wired");
        require(address(CcipOivDeployer(orchestrator).factory()) == factory, "post: orch factory mismatch");
        console.log("[OK] Chain ready. Factory + orchestrator deployed & configured.");
    }

    /// @dev keccak256(0xff || deployer || salt || keccak256(initCode))[12:].
    function _create2Address(bytes32 salt, bytes memory initCode) internal pure returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), CANONICAL_CREATE2_DEPLOYER, salt, keccak256(initCode)))
                )
            )
        );
    }
}

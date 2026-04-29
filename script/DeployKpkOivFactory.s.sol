// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {KpkOivFactory} from "../src/KpkOivFactory.sol";
import {KpkSharesDeployer} from "../src/KpkSharesDeployer.sol";

/// @title  DeployKpkOivFactory
/// @notice Deploys `KpkSharesDeployer` and `KpkOivFactory` deterministically across every chain
///         via the canonical CREATE2 deployer (`0x4e59b44847b379578588920cA78FbF26c0B4956C`),
///         producing identical addresses on Mainnet, Arbitrum, Base, Optimism, Gnosis (and
///         any future EVM chain that exposes the canonical deployer).
///
/// @dev    Threading the circular dependency:
///         - `KpkSharesDeployer.factory` is `immutable` — it must know the factory address at
///           construction time.
///         - `KpkOivFactory._kpkSharesDeployer` is a constructor argument (mutable state) that
///           is normally set to a non-zero deployer address.
///
///         To break the circular dependency *and* keep the factory's CREATE2 init-code
///         independent of the deployer address (so the factory's address is identical on every
///         chain), this script:
///           1. Pre-computes the factory address with `_kpkSharesDeployer = address(0)`.
///              Every other constructor arg (owner + 6 Safe/Zodiac infra constants) is the same
///              on every chain, so the factory's CREATE2 address is identical everywhere.
///           2. Pre-computes the deployer address with `factory = predictedFactory`. The deployer
///              address is therefore also identical everywhere (same salt, same creation code,
///              same constructor arg).
///           3. Calls the canonical CREATE2 deployer to deploy the factory at its predicted
///              address (skipped if already deployed — idempotent).
///           4. Calls the canonical CREATE2 deployer to deploy the `KpkSharesDeployer` at its
///              predicted address (skipped if already deployed).
///           5. Calls `factory.setKpkSharesDeployer(predictedDeployer)` from the broadcasting
///              EOA (the current `owner`) to wire the now-known deployer into the factory.
///           6. Calls `factory.transferOwnership(finalOwner)` to hand the factory off to the
///              long-term owner (typically a multi-sig / OIV Safe). After this, the EOA holds
///              no privileged role on the factory.
///
///         The factory's `deployOiv` reverts with `KpkSharesDeployerNotSet` between steps 3
///         and 5 — `deployOiv` is unreachable until the deployer is wired. `deployStack` is
///         unaffected and remains callable throughout.
///
/// Usage (per chain):
///
///   source .env && forge script script/DeployKpkOivFactory.s.sol:DeployKpkOivFactory \
///     --rpc-url mainnet \
///     --account $MAINNET_DEPLOYER_NAME \
///     --broadcast \
///     --verify \
///     --sig "run(address,address)" <eoaOwner> <finalOwner>
///
/// `<eoaOwner>` MUST equal the address derived from `--account $MAINNET_DEPLOYER_NAME`. It is
/// passed in the constructor's `_owner` argument; for cross-chain address determinism the same
/// EOA must be used on every chain.
contract DeployKpkOivFactory is Script {
    /// @notice Arachnid-style canonical CREATE2 deployer, present at the same address on every
    ///         major EVM chain (deployed via a one-time presigned tx). Calldata format:
    ///         `salt (32 bytes) || init_code (N bytes)`.
    address internal constant CANONICAL_CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // ── Safe v1.4.1 (canonical, same address on every EVM chain) ──────────────
    address constant SAFE_PROXY_FACTORY = 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2;
    address constant SAFE_SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address constant SAFE_MODULE_SETUP = 0x2dd68b007B46fBe91B9A7c3EDa5A7a1063cB5b47;
    address constant SAFE_FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;

    // ── Zodiac (canonical, same address on every EVM chain) ───────────────────
    address constant MODULE_PROXY_FACTORY = 0x000000000000aDdB49795b0f9bA5BC298cDda236;
    address constant ROLES_MODIFIER_MASTERCOPY = 0x9646fDAD06d3e24444381f44362a3B0eB343D337;

    // ── CREATE2 salts ─────────────────────────────────────────────────────────
    /// @dev Bump the version uint to redeploy at a fresh address (e.g. after a constructor or
    ///      bytecode change that requires displacing the existing canonical deployment).
    bytes32 internal constant SALT_FACTORY = keccak256(abi.encodePacked("KpkOivFactory", uint256(1)));
    bytes32 internal constant SALT_DEPLOYER = keccak256(abi.encodePacked("KpkSharesDeployer", uint256(1)));

    /// @notice Deploys the factory + deployer pair deterministically on the current chain and
    ///         hands ownership off to `finalOwner`.
    /// @param eoaOwner   Initial owner of the factory. MUST equal the broadcasting EOA — that
    ///                   EOA needs to call `setKpkSharesDeployer` and `transferOwnership` after
    ///                   the contracts are deployed. The `eoaOwner` value is also baked into the
    ///                   factory's CREATE2 init-code, so for identical factory addresses across
    ///                   chains the same EOA must be used everywhere.
    /// @param finalOwner Address that receives `Ownable.transferOwnership` after wiring is
    ///                   complete. Recommended: a multi-sig (e.g. the OIV Safe) — never an EOA
    ///                   in production, per the audit guidance documented on the factory.
    function run(address eoaOwner, address finalOwner) external {
        require(eoaOwner != address(0), "eoaOwner is zero");
        require(finalOwner != address(0), "finalOwner is zero");

        // ── 1. Pre-compute predicted addresses (same on every chain by construction) ──
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
                address(0) // placeholder — wired post-deploy via `setKpkSharesDeployer`
            )
        );
        address predictedFactory = _computeCreate2(SALT_FACTORY, factoryInitCode);

        bytes memory deployerInitCode =
            abi.encodePacked(type(KpkSharesDeployer).creationCode, abi.encode(predictedFactory));
        address predictedDeployer = _computeCreate2(SALT_DEPLOYER, deployerInitCode);

        console.log("==========================================");
        console.log("Predicted KpkOivFactory:    ", predictedFactory);
        console.log("Predicted KpkSharesDeployer:", predictedDeployer);
        console.log("EOA owner (during deploy):  ", eoaOwner);
        console.log("Final owner (post-deploy):  ", finalOwner);
        console.log("==========================================");

        vm.startBroadcast();

        // ── 2. Deploy KpkOivFactory at predicted address (idempotent) ──
        if (predictedFactory.code.length == 0) {
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(SALT_FACTORY, factoryInitCode));
            require(ok, "factory CREATE2 deploy failed");
            console.log("[OK]   KpkOivFactory deployed at:    ", predictedFactory);
        } else {
            console.log("[SKIP] KpkOivFactory already at:     ", predictedFactory);
        }

        // ── 3. Deploy KpkSharesDeployer at predicted address (idempotent) ──
        if (predictedDeployer.code.length == 0) {
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(SALT_DEPLOYER, deployerInitCode));
            require(ok, "deployer CREATE2 deploy failed");
            console.log("[OK]   KpkSharesDeployer deployed at:", predictedDeployer);
        } else {
            console.log("[SKIP] KpkSharesDeployer already at: ", predictedDeployer);
        }

        // ── 4. Wire the deployer into the factory ──
        KpkOivFactory factory = KpkOivFactory(predictedFactory);
        if (factory.kpkSharesDeployer() == address(0)) {
            factory.setKpkSharesDeployer(predictedDeployer);
            console.log("[OK]   factory.kpkSharesDeployer set");
        } else if (factory.kpkSharesDeployer() == predictedDeployer) {
            console.log("[SKIP] factory.kpkSharesDeployer already wired");
        } else {
            revert("factory.kpkSharesDeployer is set to an unexpected address");
        }

        // ── 5. Hand off ownership ──
        if (factory.owner() == eoaOwner && eoaOwner != finalOwner) {
            factory.transferOwnership(finalOwner);
            console.log("[OK]   transferOwnership ->", finalOwner);
        } else if (factory.owner() == finalOwner) {
            console.log("[SKIP] factory already owned by:     ", finalOwner);
        } else if (factory.owner() != eoaOwner) {
            revert("factory.owner is unexpected; refusing to handoff");
        }

        vm.stopBroadcast();

        // ── 6. Post-flight verification ──
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

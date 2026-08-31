// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console} from "forge-std/Script.sol";
import {OivChainDeploy} from "./base/OivChainDeploy.sol";
import {KpkOivFactoryV4} from "../src/KpkOivFactoryV4.sol";
import {KpkSharesDeployer} from "../src/KpkSharesDeployer.sol";
import {KpkSharesNav} from "../src/KpkSharesNav.sol";

/// @title  DeployKpkOivFactoryV4
/// @notice Deploys the UNIFIED factory — the one that deploys both `KpkShares` funds and NAV-priced
///         `KpkSharesNav` funds — together with its own `KpkSharesDeployer` and a `KpkSharesNav`
///         implementation, then wires and hands over ownership.
///
/// @dev    RELATIONSHIP TO THE LIVE salt-v3 STACK
///         This SUPERSEDES the live `KpkOivFactory` rather than modifying it. Salt v4 gives a new
///         address on every chain; the v3 factory, its deployer and the CCIP orchestrator stay
///         exactly where they are, and every fund already deployed through them keeps working —
///         funds are independent contracts and do not call back into the factory that made them.
///
///         `src/KpkOivFactory.sol` is deliberately untouched by all of this, so
///         `test/FactoryAddressSync.t.sol` keeps reproducing the live v3 addresses. Do NOT delete
///         it once v4 is rolled out: it is the only record from which the deployed stack can be
///         re-derived and re-verified.
///
///         WHAT IS AND IS NOT ADDRESS-DETERMINISTIC
///         The factory and its shares deployer go through the canonical CREATE2 deployer with
///         versioned salts, so they land on identical addresses on every chain — which the
///         `KpkShares` fund type needs, because its CCIP fan-out addresses sibling stacks by
///         construction. The `KpkSharesNav` IMPLEMENTATION is deployed with plain CREATE and its
///         address therefore differs per chain. That is deliberate and harmless: a NAV fund values
///         one account on one chain, so there is nothing for its implementation address to line up
///         with. It also sidesteps embedding `type(KpkSharesNav).creationCode` — 24,704 bytes,
///         already over EIP-170 — in anything.
///
///         ORDERING
///         The factory's CREATE2 address must not depend on the shares deployer's, and the shares
///         deployer is locked to the factory. So the factory is constructed with a zero deployer
///         placeholder and wired afterwards, exactly as `DeployKpkOivFactory` does for v3.
///
/// Usage (per chain):
///   source .env && forge script script/DeployKpkOivFactoryV4.s.sol:DeployKpkOivFactoryV4 \
///     --rpc-url <chain> --account $DEPLOYER_NAME --broadcast --verify \
///     --sig "run(address,address)" <eoaOwner> <finalOwner>
///
/// `<eoaOwner>` MUST equal the broadcasting account: it calls the onlyOwner setters below and is
/// baked into the factory's CREATE2 init-code, so a mismatch silently changes the address.
contract DeployKpkOivFactoryV4 is OivChainDeploy {
    /// @notice Salt v4. Same scheme as v3's `keccak256("KpkOivFactory" || 3)`, bumped.
    bytes32 internal constant SALT_FACTORY_V4 = keccak256(abi.encodePacked("KpkOivFactory", uint256(4)));

    /// @notice The v4 shares deployer's salt. A distinct deployer is REQUIRED, not tidiness: the
    ///         live one is locked to the v3 factory and rejects every call from v4.
    bytes32 internal constant SALT_DEPLOYER_V4 = keccak256(abi.encodePacked("KpkSharesDeployer", uint256(4)));

    function _factoryV4InitCode(address eoaOwner) internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(KpkOivFactoryV4).creationCode,
            abi.encode(
                eoaOwner,
                SAFE_PROXY_FACTORY,
                SAFE_SINGLETON,
                SAFE_MODULE_SETUP,
                SAFE_FALLBACK_HANDLER,
                MODULE_PROXY_FACTORY,
                ROLES_MODIFIER_MASTERCOPY,
                address(0) // placeholder — wired post-deploy via setKpkSharesDeployer
            )
        );
    }

    function predictFactoryV4(address eoaOwner) public pure returns (address) {
        return _create2Address(SALT_FACTORY_V4, _factoryV4InitCode(eoaOwner));
    }

    function predictDeployerV4(address eoaOwner) public pure returns (address) {
        return _create2Address(SALT_DEPLOYER_V4, _deployerInitCode(predictFactoryV4(eoaOwner)));
    }

    function run(address eoaOwner, address finalOwner)
        external
        returns (address factory, address sharesDeployer, address navImplementation)
    {
        require(eoaOwner != address(0), "eoaOwner is zero");
        require(finalOwner != address(0), "finalOwner is zero");
        require(msg.sender == eoaOwner, "broadcasting sender must equal eoaOwner");

        // The owner can point every FUTURE NAV fund at an implementation of its choosing via
        // `setNavImplementation`. Leaving that on the deploying key fails silently — nothing
        // reverts, and it only shows up in the next fund minted. Hand it to a Safe.
        require(finalOwner != eoaOwner, "finalOwner must not be the deploying key");

        bytes memory factoryInitCode = _factoryV4InitCode(eoaOwner);
        factory = _create2Address(SALT_FACTORY_V4, factoryInitCode);
        bytes memory deployerInitCode = _deployerInitCode(factory);
        sharesDeployer = _create2Address(SALT_DEPLOYER_V4, deployerInitCode);

        console.log("==========================================");
        console.log("Predicted KpkOivFactoryV4:  ", factory);
        console.log("Predicted KpkSharesDeployer:", sharesDeployer);
        console.log("EOA owner (during deploy):  ", eoaOwner);
        console.log("Final owner (post-deploy):  ", finalOwner);
        console.log("==========================================");

        // Broadcast explicitly AS `eoaOwner` rather than relying on the ambient default. Under
        // `forge script` the two are the same account — the require above enforces it — but being
        // explicit means the owner-only setters below are provably called by the address baked into
        // the factory's CREATE2 init-code, rather than by whichever sender the runner happened to
        // pick. Getting that wrong deploys a factory nobody present can wire.
        vm.startBroadcast(eoaOwner);

        // Same preflight the v3 path performs. Without these a chain can end up with a working
        // factory and no `Empty` / MultiSendUnwrapper, and then every fund deploy on it reverts.
        _ensureEmpty();
        _ensureMultiSendUnwrapper();

        if (factory.code.length == 0) {
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(SALT_FACTORY_V4, factoryInitCode));
            require(ok, "factory CREATE2 deploy failed");
            console.log("[OK]   KpkOivFactoryV4 deployed at:  ", factory);
        } else {
            console.log("[SKIP] KpkOivFactoryV4 already at:   ", factory);
        }

        if (sharesDeployer.code.length == 0) {
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(SALT_DEPLOYER_V4, deployerInitCode));
            require(ok, "shares deployer CREATE2 deploy failed");
            console.log("[OK]   KpkSharesDeployer deployed at:", sharesDeployer);
        } else {
            console.log("[SKIP] KpkSharesDeployer already at: ", sharesDeployer);
        }

        KpkOivFactoryV4 f = KpkOivFactoryV4(factory);

        // Every wiring step below is three-way idempotent — do it / already done / unexpected, the
        // last one refusing loudly. Re-running this script is a NORMAL operational act during a
        // 19-chain rollout (a retry after a dropped or reverted transaction), and under
        // `forge script` each call is its own broadcast TRANSACTION. So a step that is merely
        // "unconditional plus an onlyOwner call" does not fail atomically on a rerun: the earlier
        // transactions land and only the owner-gated one reverts, leaving debris behind.
        if (f.kpkSharesDeployer() == address(0)) {
            f.setKpkSharesDeployer(sharesDeployer);
            console.log("[OK]   kpkSharesDeployer wired");
        } else if (f.kpkSharesDeployer() == sharesDeployer) {
            console.log("[SKIP] kpkSharesDeployer already wired");
        } else {
            revert("kpkSharesDeployer is set to an unexpected address");
        }

        // Reuse the configured implementation if there is one. Deploying unconditionally would, on a
        // rerun after ownership handover, broadcast a fresh implementation (which LANDS, and is then
        // orphaned) before `setNavImplementation` reverts as a non-owner. Plain CREATE — see the
        // header on why this one is not address-deterministic.
        navImplementation = f.navImplementation();
        if (navImplementation == address(0)) {
            navImplementation = address(new KpkSharesNav());
            f.setNavImplementation(navImplementation);
            console.log("[OK]   KpkSharesNav implementation:  ", navImplementation);
        } else {
            console.log("[SKIP] KpkSharesNav implementation already set:", navImplementation);
        }

        if (f.owner() == eoaOwner) {
            f.transferOwnership(finalOwner);
            console.log("[OK]   ownership transferred");
        } else if (f.owner() == finalOwner) {
            console.log("[SKIP] already owned by the final owner");
        } else {
            revert("factory.owner is unexpected; refusing to hand off");
        }

        vm.stopBroadcast();

        // Post-conditions.
        //
        // CORRECTION: an earlier version of this comment claimed these "run OUTSIDE the broadcast,
        // against the deployed state". That is wrong under `forge script --broadcast`. The whole
        // `run()` body — these `require`s included — executes during SIMULATION, before any
        // transaction is sent; `vm.stopBroadcast()` ends the recording of calls, it does not
        // execute them. So these assert against simulated state, which catches an argument-order
        // or wiring mistake in this script but does NOT prove anything about the chain afterwards.
        // They are real post-conditions only in the fork test that calls `run()` directly.
        // Confirm a live rollout by reading the logged addresses back on-chain.
        require(f.kpkSharesDeployer() == sharesDeployer, "kpkSharesDeployer not wired");
        require(f.navImplementation() == navImplementation, "navImplementation not set");
        require(f.owner() == finalOwner, "ownership not transferred");
        require(KpkSharesDeployer(sharesDeployer).factory() == factory, "shares deployer locked to a different factory");

        console.log("==========================================");
        console.log("Ownership transferred to:   ", finalOwner);
        console.log("deployOiv     -> KpkShares fund (operator-priced, multi-chain capable)");
        console.log("deployNavFund -> KpkSharesNav fund (NAV-priced, SINGLE-CHAIN ONLY)");
        console.log("deployStack   -> the five-contract stack alone");
        console.log("==========================================");
        console.log("NOTE: the live salt-v3 factory is NOT touched by this deploy. Funds already");
        console.log("  deployed through it keep working; src/KpkOivFactory.sol must stay in the repo");
        console.log("  as the only record its addresses can be re-derived from.");
        console.log("REMINDER: synchronous deposits start DISABLED on every NAV fund. Seed the fund");
        console.log("  with an operator-approved subscription before enabling them.");
    }
}

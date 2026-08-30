// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {KpkOivFactory} from "../src/KpkOivFactory.sol";
import {KpkSharesNav} from "../src/KpkSharesNav.sol";
import {KpkSharesNavFactory} from "../src/KpkSharesNavFactory.sol";
import {DeployOiv} from "./DeployOiv.s.sol";

/**
 * @title DeployKpkSharesNavFactory
 * @notice Deploys the `KpkSharesNav` implementation and the `KpkSharesNavFactory` that mints funds
 *         from it, on ONE chain.
 *
 * Purpose:
 *   `KpkSharesNavFactory.deployNavFund` needs two things to exist first: the live `KpkOivFactory`
 *   (whose permissionless `deployStack` builds the Safes and Roles Modifiers) and a pre-deployed
 *   `KpkSharesNav` implementation. This script deploys the implementation and wires both into a new
 *   factory in one run.
 *
 * Why no CREATE2 / no cross-chain address determinism:
 *   `KpkSharesNav` values ONE account on ONE chain. There is deliberately no multichain story here,
 *   so there is nothing to gain from matching addresses across chains and no salt to keep in step —
 *   unlike `DeployKpkOivFactory`, whose whole design exists to produce identical addresses on 19
 *   chains. Plain `CREATE` keeps this script free of the address-drift class that has bitten this
 *   repo twice.
 *
 * Ownership:
 *   The factory is constructed with `factoryOwner` already in place and the implementation already
 *   set, so there is no transient-owner window and no post-deploy handover to get wrong. The owner's
 *   only power is `setNavImplementation`, which affects FUTURE funds only — deployed proxies each
 *   hold their own implementation pointer and are never migrated by it.
 *
 * Inputs:
 *   - `factoryOwner`: receives ownership. MUST NOT be the broadcasting key (see the require below).
 *   - `oivFactory` (3-arg form): the `KpkOivFactory` to compose. Zero means the canonical address
 *     published by `DeployOiv.FACTORY`, which `test/FactoryAddressSync.t.sol` pins to the address
 *     the infra deploy path actually produces. Read from that constant rather than mirrored here,
 *     so this script cannot rot away from it.
 *   - `existingImpl` (3-arg form): reuse an already-deployed `KpkSharesNav` implementation instead
 *     of deploying a fresh one. Zero deploys a fresh one.
 *
 * Outputs:
 *   The implementation and factory addresses, logged.
 *
 * Assumptions:
 *   - `NavPricingLib` is deployed and linked by forge automatically as part of this script.
 *   - The `KpkOivFactory` on this chain is the patched v2.1.1 build. The legacy pre-v2.1.1 factory
 *     (vulnerable Roles Modifier v2.1.0) is refused by address below.
 *
 * Usage:
 *   # canonical factory, fresh implementation
 *   forge script script/DeployKpkSharesNavFactory.s.sol:DeployKpkSharesNavFactory \
 *     --rpc-url $ETH_RPC_URL --account $DEPLOYER_NAME --broadcast --verify \
 *     --sig "run(address)" <factoryOwner>
 *
 *   # explicit factory and/or a reused implementation (zero = default)
 *   forge script script/DeployKpkSharesNavFactory.s.sol:DeployKpkSharesNavFactory \
 *     --rpc-url $ETH_RPC_URL --account $DEPLOYER_NAME --broadcast --verify \
 *     --sig "run(address,address,address)" <factoryOwner> <oivFactory> <existingImpl>
 */
contract DeployKpkSharesNavFactory is Script {
    /// @notice The pre-v2.1.1 factory, embedding the vulnerable Roles Modifier v2.1.0.
    /// @dev A blocklist entry, not a record. Every fund minted through a factory composing this one
    ///      would inherit the vulnerable modifier, and nothing else in this script would notice: it
    ///      has code and answers every probe below exactly like the good one.
    address internal constant LEGACY_FACTORY = 0x0d94255fdE65D302616b02A2F070CdB21190d420;

    /// @notice Deploys against the canonical `KpkOivFactory` with a freshly deployed implementation.
    function run(address factoryOwner) external returns (address implementation, address navFactory) {
        return run(factoryOwner, address(0), address(0));
    }

    /// @notice Full form.
    /// @param factoryOwner Receives ownership of the new factory.
    /// @param oivFactory   `KpkOivFactory` to compose; zero uses `DeployOiv.FACTORY`.
    /// @param existingImpl `KpkSharesNav` implementation to reuse; zero deploys a fresh one.
    function run(address factoryOwner, address oivFactory, address existingImpl)
        public
        returns (address implementation, address navFactory)
    {
        require(factoryOwner != address(0), "factoryOwner is zero");

        // The owner can point every FUTURE fund at an implementation of its choosing, so leaving
        // that power on a hot deploying key is the same class of mistake as leaving a fund adminless
        // — quieter, because nothing reverts and the weakness only shows up in the next fund minted.
        // Configure a Safe, not the deploying account.
        require(factoryOwner != msg.sender, "factoryOwner must not be the broadcasting key");

        if (oivFactory == address(0)) {
            // Read from the pinned constant rather than mirroring the literal. `FactoryAddressSync`
            // asserts it matches what the infra deploy path produces, so this script inherits that
            // guarantee instead of adding a second copy that can silently go stale — which is
            // exactly how the constant rotted to the legacy factory once already.
            oivFactory = new DeployOiv().FACTORY();
        }

        require(oivFactory != LEGACY_FACTORY, "oivFactory is the legacy pre-v2.1.1 factory");
        require(oivFactory.code.length > 0, "oivFactory is not a contract on this chain");

        // Liveness probe. A wrong-but-deployed address — another factory, or one whose infra setters
        // were never run — would otherwise only surface when the first `deployNavFund` reverted
        // somewhere inside Safe deployment.
        require(
            KpkOivFactory(oivFactory).safeProxyFactory() != address(0),
            "oivFactory has no Safe proxy factory configured - wrong address or unwired factory"
        );

        if (existingImpl != address(0)) {
            require(existingImpl.code.length > 0, "existingImpl is not a contract");
        }

        vm.startBroadcast();

        implementation = existingImpl == address(0) ? address(new KpkSharesNav()) : existingImpl;
        navFactory = address(new KpkSharesNavFactory(oivFactory, implementation, factoryOwner));

        vm.stopBroadcast();

        // Post-conditions. Cheap, and they catch a constructor whose argument order was changed
        // under this script without it being updated.
        KpkSharesNavFactory deployed = KpkSharesNavFactory(navFactory);
        require(address(deployed.oivFactory()) == oivFactory, "oivFactory not wired");
        require(deployed.navImplementation() == implementation, "implementation not set");
        require(deployed.owner() == factoryOwner, "ownership not assigned");

        console.log("==========================================");
        console.log("KpkSharesNav implementation:", implementation);
        console.log(existingImpl == address(0) ? "  (freshly deployed)" : "  (reused)");
        console.log("KpkSharesNavFactory:        ", navFactory);
        console.log("Composed KpkOivFactory:     ", oivFactory);
        console.log("Factory owner:              ", factoryOwner);
        console.log("==========================================");
        console.log("Next: deployNavFund(config) mints a fund with its own Safes and Roles Modifiers.");
        console.log("REMINDER: this factory CANNOT grant the Avatar Safe's token approvals.");
        console.log("  deployStack disables the factory as an Avatar Safe module before returning,");
        console.log("  so redemptions revert on payout until the Avatar Safe approves the fund proxy");
        console.log("  for every redeemable asset, via a transaction through the exec Roles Modifier.");
        console.log("REMINDER: synchronous deposits start DISABLED on every fund. Seed the fund with");
        console.log("  an operator-approved subscription before enabling them.");
    }
}

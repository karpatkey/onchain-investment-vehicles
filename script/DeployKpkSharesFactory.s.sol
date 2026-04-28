// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {KpkSharesFactory} from "../src/KpkSharesFactory.sol";

/// @notice Deploys KpkSharesFactory.
///         Infrastructure addresses (Safe v1.4.1, Zodiac) are hardcoded as defaults in the
///         contract and can be updated by the owner post-deployment via the setter functions.
///         The KpkShares implementation is deployed automatically for each fund via deployFund().
///
/// Usage:
///   forge script script/DeployKpkSharesFactory.s.sol:DeployKpkSharesFactory \
///     --rpc-url $ETH_RPC_URL \
///     --broadcast \
///     --verify \
///     --sig "run(address)" <ownerAddress>
contract DeployKpkSharesFactory is Script {
    function run(address owner) external {
        require(owner != address(0), "owner cannot be zero");

        vm.startBroadcast();

        KpkSharesFactory factory = new KpkSharesFactory(owner);

        vm.stopBroadcast();

        console.log("==========================================");
        console.log("KpkSharesFactory deployed at:", address(factory));
        console.log("Owner:             ", owner);
        console.log("SafeProxyFactory:  ", factory.safeProxyFactory());
        console.log("SafeSingleton:     ", factory.safeSingleton());
        console.log("SafeModuleSetup:   ", factory.safeModuleSetup());
        console.log("FallbackHandler:   ", factory.safeFallbackHandler());
        console.log("ModuleProxyFactory:", factory.moduleProxyFactory());
        console.log("RolesMastercopy:   ", factory.rolesModifierMastercopy());
        console.log("==========================================");
    }
}

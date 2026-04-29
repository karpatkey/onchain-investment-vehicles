// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {KpkOivFactory} from "../src/KpkOivFactory.sol";
import {KpkSharesDeployer} from "../src/KpkSharesDeployer.sol";

/// @notice Deploys KpkSharesDeployer and KpkOivFactory with hardcoded Safe v1.4.1
///         and Zodiac infrastructure addresses.
///         Infrastructure addresses can be updated by the owner post-deployment via the setter functions.
///         Each fund deployed via deployOiv() gets a fresh KpkShares implementation from KpkSharesDeployer.
///
/// Usage (import key first with `cast wallet import $MAINNET_DEPLOYER_NAME --interactive`):
///
///   # Mainnet
///   source .env && forge script script/DeployKpkOivFactory.s.sol:DeployKpkOivFactory \
///     --rpc-url mainnet \
///     --account $MAINNET_DEPLOYER_NAME \
///     --broadcast \
///     --verify \
///     --sig "run(address)" <ownerAddress>
///
///   # Sepolia
///   source .env && forge script script/DeployKpkOivFactory.s.sol:DeployKpkOivFactory \
///     --rpc-url sepolia \
///     --account $SEPOLIA_DEPLOYER_NAME \
///     --broadcast \
///     --verify \
///     --sig "run(address)" <ownerAddress>
contract DeployKpkOivFactory is Script {
    // Safe v1.4.1
    address constant SAFE_PROXY_FACTORY = 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2;
    address constant SAFE_SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address constant SAFE_MODULE_SETUP = 0x2dd68b007B46fBe91B9A7c3EDa5A7a1063cB5b47;
    address constant SAFE_FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;

    // Zodiac
    address constant MODULE_PROXY_FACTORY = 0x000000000000aDdB49795b0f9bA5BC298cDda236;
    address constant ROLES_MODIFIER_MASTERCOPY = 0x9646fDAD06d3e24444381f44362a3B0eB343D337;

    function run(address owner) external {
        require(owner != address(0), "owner cannot be zero");

        vm.startBroadcast();

        KpkSharesDeployer sharesDeployer = new KpkSharesDeployer();

        KpkOivFactory factory = new KpkOivFactory(
            owner,
            SAFE_PROXY_FACTORY,
            SAFE_SINGLETON,
            SAFE_MODULE_SETUP,
            SAFE_FALLBACK_HANDLER,
            MODULE_PROXY_FACTORY,
            ROLES_MODIFIER_MASTERCOPY,
            address(sharesDeployer)
        );

        vm.stopBroadcast();

        console.log("==========================================");
        console.log("KpkSharesDeployer deployed at:", address(sharesDeployer));
        console.log("KpkOivFactory deployed at: ", address(factory));
        console.log("Owner:             ", owner);
        console.log("SafeProxyFactory:  ", factory.safeProxyFactory());
        console.log("SafeSingleton:     ", factory.safeSingleton());
        console.log("SafeModuleSetup:   ", factory.safeModuleSetup());
        console.log("FallbackHandler:   ", factory.safeFallbackHandler());
        console.log("ModuleProxyFactory:", factory.moduleProxyFactory());
        console.log("RolesMastercopy:   ", factory.rolesModifierMastercopy());
        console.log("KpkSharesDeployer: ", factory.kpkSharesDeployer());
        console.log("==========================================");
    }
}

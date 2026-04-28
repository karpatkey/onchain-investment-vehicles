// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {KpkSharesFactory} from "../src/KpkSharesFactory.sol";
import {KpkShares} from "../src/kpkShares.sol";

/// @notice Deploys KpkSharesFactory (and KpkShares implementation if needed).
///
/// Usage (mainnet):
///   forge script script/DeployKpkSharesFactory.s.sol:DeployKpkSharesFactory \
///     --rpc-url $ETH_RPC_URL \
///     --broadcast \
///     --verify \
///     --sig "run(address,address)" <ownerAddress> <existingImplOrZero>
///
/// Pass address(0) as the second argument to deploy a fresh KpkShares implementation.
contract DeployKpkSharesFactory is Script {
    // ── Known addresses (same across most EVM chains for Safe v1.4.1 + Zodiac) ──

    address private constant SAFE_PROXY_FACTORY = 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2;
    address private constant SAFE_SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address private constant SAFE_MODULE_SETUP = 0x2dd68b007B46fBe91B9A7c3EDa5A7a1063cB5b47;
    address private constant SAFE_FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;
    address private constant MODULE_PROXY_FACTORY = 0x000000000000aDdB49795b0f9bA5BC298cDda236;
    address private constant ROLES_MODIFIER_MASTERCOPY = 0x9646fDAD06d3e24444381f44362a3B0eB343D337;

    function run(address owner, address existingImpl) external {
        require(owner != address(0), "owner cannot be zero");

        vm.startBroadcast();

        address impl = existingImpl;
        if (impl == address(0)) {
            impl = address(new KpkShares());
            console.log("KpkShares implementation deployed at:", impl);
        } else {
            console.log("Reusing existing KpkShares implementation:", impl);
        }

        KpkSharesFactory factory = new KpkSharesFactory(
            owner,
            impl,
            SAFE_PROXY_FACTORY,
            SAFE_SINGLETON,
            SAFE_MODULE_SETUP,
            SAFE_FALLBACK_HANDLER,
            MODULE_PROXY_FACTORY,
            ROLES_MODIFIER_MASTERCOPY
        );

        vm.stopBroadcast();

        console.log("==========================================");
        console.log("KpkSharesFactory deployed at:", address(factory));
        console.log("Owner:", owner);
        console.log("KpkShares implementation:", impl);
        console.log("==========================================");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console} from "forge-std/Script.sol";
import {OivChainDeploy} from "./base/OivChainDeploy.sol";
import {DeployOiv} from "./DeployOiv.s.sol";
import {KpkOivFactory} from "../src/KpkOivFactory.sol";
import {KpkSharesNav} from "../src/KpkSharesNav.sol";
import {KpkSharesNavFactory} from "../src/KpkSharesNavFactory.sol";
import {KpkSharesNavLens} from "../src/periphery/KpkSharesNavLens.sol";

/// @title  DeployKpkSharesNavFactory
/// @notice Deploys the NAV-fund kit on one chain through the canonical CREATE2 deployer: the
///         `KpkSharesNav` mastercopy, `KpkSharesNavFactory` (composing the live `KpkOivFactory` at
///         `DeployOiv.FACTORY`), and `KpkSharesNavLens`. Idempotent: a contract whose predicted address
///         already has code is skipped.
///
///         `KpkSharesNav` links `NavPricingLib`, so the mastercopy's init code, and therefore its address,
///         depends on the library address forge links in.
///
/// Usage:
///   Dry run (no transactions):
///     forge script script/DeployKpkSharesNavFactory.s.sol:DeployKpkSharesNavFactory --fork-url $MAINNET_URL
///   Deploy:
///     source .env && forge script script/DeployKpkSharesNavFactory.s.sol:DeployKpkSharesNavFactory \
///       --rpc-url mainnet --private-key $PRIVATE_KEY --broadcast
contract DeployKpkSharesNavFactory is OivChainDeploy {
    bytes32 internal constant SALT_NAV_MASTERCOPY = keccak256(abi.encodePacked("KpkSharesNavMastercopy", uint256(1)));
    bytes32 internal constant SALT_NAV_FACTORY = keccak256(abi.encodePacked("KpkSharesNavFactory", uint256(1)));
    bytes32 internal constant SALT_NAV_LENS = keccak256(abi.encodePacked("KpkSharesNavLens", uint256(1)));

    function run() external returns (address mastercopy, address navFactory, address lens) {
        // `DeployOiv.FACTORY`, read through an instance because Solidity does not expose another
        // contract's constant by type name. Created before the broadcast, so it is never sent.
        address liveFactory = new DeployOiv().FACTORY();
        // The NAV factory's constructor reads `timelockDeployer()` from it, so it must exist first.
        require(liveFactory.code.length > 0, "KpkOivFactory is not deployed on this chain");

        bytes memory mastercopyInitCode = type(KpkSharesNav).creationCode;
        mastercopy = _create2Address(SALT_NAV_MASTERCOPY, mastercopyInitCode);
        bytes memory factoryInitCode =
            abi.encodePacked(type(KpkSharesNavFactory).creationCode, abi.encode(liveFactory, mastercopy));
        navFactory = _create2Address(SALT_NAV_FACTORY, factoryInitCode);
        bytes memory lensInitCode = type(KpkSharesNavLens).creationCode;
        lens = _create2Address(SALT_NAV_LENS, lensInitCode);

        console.log("==========================================");
        console.log("KpkOivFactory (live):         ", liveFactory);
        console.log("Predicted KpkSharesNav mc:    ", mastercopy);
        console.log("Predicted KpkSharesNavFactory:", navFactory);
        console.log("Predicted KpkSharesNavLens:   ", lens);
        console.log("==========================================");

        vm.startBroadcast();
        // Mastercopy before the factory: the factory's constructor rejects a codeless mastercopy.
        _deploy("KpkSharesNav mastercopy", SALT_NAV_MASTERCOPY, mastercopyInitCode, mastercopy);
        _deploy("KpkSharesNavFactory", SALT_NAV_FACTORY, factoryInitCode, navFactory);
        _deploy("KpkSharesNavLens", SALT_NAV_LENS, lensInitCode, lens);
        vm.stopBroadcast();

        // Post-flight, outside the broadcast so it records nothing.
        require(mastercopy.code.length > 0, "KpkSharesNav mastercopy has no code");
        require(navFactory.code.length > 0, "KpkSharesNavFactory has no code");
        require(lens.code.length > 0, "KpkSharesNavLens has no code");
        KpkSharesNavFactory f = KpkSharesNavFactory(navFactory);
        require(address(f.factory()) == liveFactory, "NAV factory: factory mismatch");
        require(f.kpkSharesNavMastercopy() == mastercopy, "NAV factory: mastercopy mismatch");
        require(
            f.timelockDeployer() == KpkOivFactory(liveFactory).timelockDeployer(),
            "NAV factory: timelockDeployer mismatch"
        );
        console.log("[OK]   post-flight passed");
    }

    function _deploy(string memory label, bytes32 salt, bytes memory initCode, address predicted) internal {
        if (predicted.code.length != 0) {
            console.log(string.concat("[SKIP] ", label, " already at:"), predicted);
            return;
        }
        (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        require(ok, string.concat(label, " CREATE2 deploy failed"));
        console.log(string.concat("[OK]   ", label, " deployed at:"), predicted);
    }
}

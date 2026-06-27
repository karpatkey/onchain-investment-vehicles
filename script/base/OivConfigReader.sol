// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {KpkOivFactory} from "../../src/KpkOivFactory.sol";

/// @title  OivConfigReader
/// @notice Single source of truth for parsing an OIV fund config JSON (the format produced by the
///         `/deploy-oiv` skill) into the factory's `OivConfig` / `StackConfig` structs. `DeployOiv`
///         and `CcipDeployEverywhere` both inherit this so the parsing logic — and the asset-count
///         bound — exist in exactly one place and cannot drift.
abstract contract OivConfigReader is Script {
    using stdJson for string;

    /// @dev Hard upper bound on `additionalAssets` entries the reader will scan. Sized well above any
    ///      realistic fund; if a config ever exceeds it the reader REVERTS rather than silently
    ///      truncating (which would deploy a fund missing assets, with no error at deploy time).
    uint256 internal constant MAX_ADDITIONAL_ASSETS = 100;

    function _buildOivConfig(string memory json) internal view returns (KpkOivFactory.OivConfig memory config) {
        config.managerSafe.owners = json.readAddressArray(".managerSafe.owners");
        config.managerSafe.threshold = json.readUint(".managerSafe.threshold");
        config.salt = json.readUint(".salt");
        config.admin = json.readAddress(".oiv.admin");

        config.sharesParams.asset = json.readAddress(".oiv.sharesParams.asset");
        config.sharesParams.name = json.readString(".oiv.sharesParams.name");
        config.sharesParams.symbol = json.readString(".oiv.sharesParams.symbol");
        config.sharesParams.subscriptionRequestTtl = uint64(json.readUint(".oiv.sharesParams.subscriptionRequestTtl"));
        config.sharesParams.redemptionRequestTtl = uint64(json.readUint(".oiv.sharesParams.redemptionRequestTtl"));
        config.sharesParams.feeReceiver = json.readAddress(".oiv.sharesParams.feeReceiver");
        config.sharesParams.managementFeeRate = json.readUint(".oiv.sharesParams.managementFeeRate");
        config.sharesParams.redemptionFeeRate = json.readUint(".oiv.sharesParams.redemptionFeeRate");
        config.sharesParams.performanceFeeModule = json.readAddress(".oiv.sharesParams.performanceFeeModule");
        config.sharesParams.performanceFeeRate = json.readUint(".oiv.sharesParams.performanceFeeRate");

        config.additionalAssets = _readAdditionalAssets(json);
    }

    function _buildStackConfig(string memory json) internal view returns (KpkOivFactory.StackConfig memory config) {
        config.managerSafe.owners = json.readAddressArray(".managerSafe.owners");
        config.managerSafe.threshold = json.readUint(".managerSafe.threshold");
        config.execRolesMod.finalOwner = json.readAddress(".execRolesModFinalOwner");
        config.salt = json.readUint(".salt");
    }

    function _readAdditionalAssets(string memory json)
        internal
        view
        returns (KpkOivFactory.AssetConfig[] memory assets)
    {
        uint256 count = 0;
        while (count < MAX_ADDITIONAL_ASSETS) {
            if (!vm.keyExists(json, string.concat(".oiv.additionalAssets[", vm.toString(count), "].asset"))) break;
            count++;
        }
        // If we hit the cap AND another entry still exists, the config has more assets than we scan —
        // refuse rather than deploy a fund silently missing the surplus.
        require(
            count < MAX_ADDITIONAL_ASSETS
                || !vm.keyExists(json, string.concat(".oiv.additionalAssets[", vm.toString(count), "].asset")),
            "additionalAssets exceeds MAX_ADDITIONAL_ASSETS"
        );

        assets = new KpkOivFactory.AssetConfig[](count);
        for (uint256 i = 0; i < count; i++) {
            string memory base = string.concat(".oiv.additionalAssets[", vm.toString(i), "]");
            assets[i].asset = json.readAddress(string.concat(base, ".asset"));
            assets[i].canDeposit = json.readBool(string.concat(base, ".canDeposit"));
            assets[i].canRedeem = json.readBool(string.concat(base, ".canRedeem"));
        }
    }
}

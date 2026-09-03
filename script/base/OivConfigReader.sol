// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {KpkOivFactory} from "../../src/KpkOivFactory.sol";
import {TimelockParams} from "../../src/interfaces/IKpkTimelockDeployer.sol";
import {CcipOivDeployer} from "../../src/CcipOivDeployer.sol";

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

    /// @dev Logs an OIV instance in a consistent format. Shared by the predict / deploy entry points
    ///      of `DeployOiv` and `CcipDeployEverywhere` so the label block lives in one place.
    ///
    ///      The timelock rows print `0x0` when none was configured, and that is deliberately visible
    ///      rather than omitted: a fund the operator believes is timelocked but is not is the exact
    ///      failure this file previously made silent.
    function _logInstance(KpkOivFactory.OivInstance memory inst) internal pure {
        console.log("  Avatar Safe:          ", inst.avatarSafe);
        console.log("  Manager Safe:         ", inst.managerSafe);
        console.log("  execRolesModifier:    ", inst.execRolesModifier);
        console.log("  subRolesModifier:     ", inst.subRolesModifier);
        console.log("  managerRolesModifier: ", inst.managerRolesModifier);
        console.log("  kpkShares impl:       ", inst.kpkSharesImpl);
        console.log("  kpkShares proxy:      ", inst.kpkSharesProxy);
        console.log("  exec timelock:        ", inst.execTimelock);
        console.log("  shares timelock:      ", inst.sharesTimelock);
    }

    function _buildOivConfig(string memory json) internal view returns (KpkOivFactory.OivConfig memory config) {
        config.managerSafe.owners = json.readAddressArray(".managerSafe.owners");
        config.managerSafe.threshold = json.readUint(".managerSafe.threshold");
        config.salt = json.readUint(".salt");
        config.admin = json.readAddress(".oiv.admin");

        config.sharesParams.asset = _assetForThisChain(json);
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
        config.execTimelock = _readTimelockParams(json, ".oiv.execTimelock");
        config.sharesTimelock = _readTimelockParams(json, ".oiv.sharesTimelock");
    }

    function _buildStackConfig(string memory json) internal view returns (KpkOivFactory.StackConfig memory config) {
        config.managerSafe.owners = json.readAddressArray(".managerSafe.owners");
        config.managerSafe.threshold = json.readUint(".managerSafe.threshold");
        config.execRolesMod.finalOwner = json.readAddress(".execRolesModFinalOwner");
        config.salt = json.readUint(".salt");
        // Read from the SAME `.oiv.execTimelock` block `_buildOivConfig` uses. A sidechain configured
        // from a different block would produce a different timelock address there, since the address
        // is a function of these parameters — leaving the fund timelocked at inconsistent addresses.
        config.execTimelock = _readTimelockParams(json, ".oiv.execTimelock");
    }

    /// @dev Reads one `{ minDelay, proposers, cancellers }` block. An ABSENT block yields a zeroed
    ///      struct, and `minDelay == 0` is the factory's "no timelock" sentinel — so a config that
    ///      says nothing about timelocks keeps the pre-timelock behaviour exactly.
    ///
    ///      `minDelay` is required whenever the block exists: a block carrying proposers and
    ///      cancellers but no delay would silently deploy no timelock at all, which is the one
    ///      misreading with no visible symptom.
    function _readTimelockParams(string memory json, string memory key)
        internal
        view
        returns (TimelockParams memory params)
    {
        if (!vm.keyExists(json, key)) return params;

        require(
            vm.keyExists(json, string.concat(key, ".minDelay")),
            string.concat("config: ", key, " exists but has no minDelay - a timelock would be silently skipped")
        );
        params.minDelay = json.readUint(string.concat(key, ".minDelay"));
        params.proposers = vm.keyExists(json, string.concat(key, ".proposers"))
            ? json.readAddressArray(string.concat(key, ".proposers"))
            : new address[](0);
        params.cancellers = vm.keyExists(json, string.concat(key, ".cancellers"))
            ? json.readAddressArray(string.concat(key, ".cancellers"))
            : new address[](0);
    }

    /// @dev The base asset for the chain this script is running on. Funds use a different stablecoin
    ///      per chain, so `.oiv.assetOverrides.<chainId>` wins over `.oiv.sharesParams.asset` when
    ///      present.
    ///
    ///      This does not move a fund's address on EITHER path, but for two different reasons, and an
    ///      earlier version of this comment got the second one wrong. On the direct factory path the
    ///      shares proxy's address simply does not depend on its initialization parameters. On the
    ///      CCIP path the orchestrator hashes the whole config into its salt, so a per-chain asset
    ///      DID move all seven addresses — the same config file produced a different fund on every
    ///      chain. `CcipOivDeployer._effectiveConfig` now zeroes the asset before hashing and commits
    ///      to it through the `sharesChains` topology instead, which is identical everywhere.
    function _assetForThisChain(string memory json) internal view returns (address) {
        string memory key = string.concat(".oiv.assetOverrides.", vm.toString(block.chainid));
        return vm.keyExists(json, key) ? json.readAddress(key) : json.readAddress(".oiv.sharesParams.asset");
    }

    /// @dev Whether this chain should receive the shares token as well as the operational stack.
    ///      An absent `.sharesChains` means "no opinion" and leaves the choice with whichever entry
    ///      point the operator invoked, which is how this worked before the list existed.
    /// @dev The fund's cross-chain topology, as the orchestrator wants it: `(chainId, asset)` for
    ///      every chain in `.sharesChains`, ascending, with each chain's own asset resolved from
    ///      `.oiv.assetOverrides` exactly as `_assetForThisChain` would resolve it there.
    ///
    ///      Required by every orchestrator entry point, because the topology is salt-bound: it decides
    ///      which chains run `deployOiv`, which receive stacks, and which refuse them. An absent
    ///      `.sharesChains` yields the single-chain topology for the chain the script is running on,
    ///      matching the direct-script default.
    function _buildSharesChains(string memory json) internal view returns (CcipOivDeployer.SharesChain[] memory out) {
        if (!vm.keyExists(json, ".sharesChains")) {
            out = new CcipOivDeployer.SharesChain[](1);
            out[0] = CcipOivDeployer.SharesChain({chainId: block.chainid, asset: _assetForThisChain(json)});
            return out;
        }

        uint256[] memory ids = json.readUintArray(".sharesChains");
        out = new CcipOivDeployer.SharesChain[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            // Ascending is the orchestrator's contract, not a preference: the topology is hashed, so
            // two orderings would be two funds. Fail here with the offending id rather than letting
            // the revert surface from inside the orchestrator.
            require(i == 0 || ids[i] > ids[i - 1], "config: .sharesChains must be strictly ascending by chain id");
            string memory key = string.concat(".oiv.assetOverrides.", vm.toString(ids[i]));
            address asset =
                vm.keyExists(json, key) ? json.readAddress(key) : json.readAddress(".oiv.sharesParams.asset");
            out[i] = CcipOivDeployer.SharesChain({chainId: ids[i], asset: asset});
        }
    }

    function _shouldDeployShares(string memory json) internal view returns (bool) {
        if (!vm.keyExists(json, ".sharesChains")) return true;
        uint256[] memory ids = json.readUintArray(".sharesChains");
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == block.chainid) return true;
        }
        return false;
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

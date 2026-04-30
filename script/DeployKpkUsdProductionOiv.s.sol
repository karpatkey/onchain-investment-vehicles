// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {KpkOivFactory} from "../src/KpkOivFactory.sol";
import {KpkShares} from "../src/kpkShares.sol";

/// @title  DeployKpkUsdProductionOiv
/// @notice One-shot script: deploys the production kUSD fund via KpkOivFactory.deployOiv.
///         Atomically deploys 7 contracts (Avatar Safe, Manager Safe, 3 Roles Modifiers,
///         KpkShares impl + proxy) in a single transaction from the kpk deployer EOA.
///
/// @dev    Deploy-specific choices are hardcoded at the top of this contract so they show up
///         in the PR diff for review. Shares params (asset, name, fees, TTLs, additionalAssets)
///         are read from script/vaults.json — keeping the audited param set in one place.
///
/// Usage (dry run — simulates against mainnet, no broadcast):
///   source .env
///   forge script script/DeployKpkUsdProductionOiv.s.sol:DeployKpkUsdProductionOiv \
///     --rpc-url mainnet \
///     --sender 0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72
///
/// Usage (real broadcast — verifies on Etherscan v2 automatically):
///   source .env
///   forge script script/DeployKpkUsdProductionOiv.s.sol:DeployKpkUsdProductionOiv \
///     --rpc-url mainnet \
///     --broadcast --verify \
///     --account $MAINNET_DEPLOYER_NAME \
///     --sender 0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72
contract DeployKpkUsdProductionOiv is Script {
    using stdJson for string;

    // ── Hardcoded for this deploy — visible in PR diff ────────────────────────

    /// @notice Mainnet KpkOivFactory (per docs/DEPLOYED_ADDRESSES.md, identical on every chain).
    address internal constant FACTORY = 0x0d94255fdE65D302616b02A2F070CdB21190d420;

    /// @notice kpk deployer EOA — must match `--sender` on the forge command.
    ///         Predict and broadcast both use this as the calling address; if `--sender` differs,
    ///         the predicted Manager/Avatar Safe addresses won't match what gets deployed
    ///         (caller is mixed into salt derivation per KpkOivFactory.sol _deriveSalts).
    address internal constant DEPLOYER = 0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72;

    /// @notice Manager Safe threshold. Owners list in `_managerSafeOwners()` below.
    ///         WARNING: threshold=1 means any single owner can re-wire sub + manager Roles
    ///         Modifiers (KpkOivFactory.sol:186–195). Each owner must be trusted at the
    ///         same level as `admin` (the staging Sec Council Safe).
    uint256 internal constant MANAGER_SAFE_THRESHOLD = 1;

    /// @notice Base salt — drives all 5 stack-address derivations + 2 shares-address derivations.
    ///         Caller is mixed in, so the same `(DEPLOYER, SALT)` on the same factory yields
    ///         identical Avatar Safe / Manager Safe addresses on every EVM chain.
    uint256 internal constant SALT = uint256(keccak256("kpk-USD-Alpha-Fund-prod-v1"));

    // ── Wired constants (don't change per deploy) ─────────────────────────────

    uint256 private constant MAINNET_CHAIN_ID = 1;
    string private constant VAULTS_JSON_PATH = "script/vaults.json";
    string private constant VAULT_NAME = "kUSD";
    string private constant VAULT_ENVIRONMENT = "production";

    function _managerSafeOwners() internal pure returns (address[] memory owners) {
        owners = new address[](5);
        owners[0] = 0x524075B4d1C91F91F27893f4640ca980785d1e58;
        owners[1] = 0xAc12293749b4D9e7bb4c33608d39E089135E3521;
        owners[2] = 0x9F230218cf7FDe6A9246e6f8CB0b888377E92639;
        owners[3] = 0x4102E0743DA668EB2f55E90c96ef8EF4e621879c;
        owners[4] = 0xE2679499b74cCc5dfd4AA78462FB7A1D4Be386E5;
    }

    // ── Entry point ──────────────────────────────────────────────────────────

    function run() external {
        require(block.chainid == MAINNET_CHAIN_ID, "DeployKpkUsdProductionOiv: not mainnet");
        require(FACTORY.code.length > 0, "DeployKpkUsdProductionOiv: factory not deployed at expected address");

        // 1. Read shares params + admin from vaults.json.
        (KpkShares.ConstructorParams memory sharesParams, KpkOivFactory.AssetConfig[] memory additionalAssets, address admin) =
            _loadFromJson();

        // 2. Build OivConfig with feeReceiver = address(0) initially. We'll fill it in after
        //    we predict the Manager Safe. feeReceiver does not enter the Manager/Avatar Safe
        //    address derivation (only managerSafe.owners + threshold + salt + caller do — see
        //    KpkOivFactory.sol _predictStack), so changing it post-prediction does not invalidate
        //    the predicted stack addresses. It DOES affect the predicted shares-proxy address
        //    (since _predictSharesProxy hashes sharesParams), so we re-predict after setting it.
        KpkOivFactory.OivConfig memory config = KpkOivFactory.OivConfig({
            managerSafe: KpkOivFactory.SafeConfig({owners: _managerSafeOwners(), threshold: MANAGER_SAFE_THRESHOLD}),
            salt: SALT,
            admin: admin,
            sharesParams: sharesParams,
            additionalAssets: additionalAssets
        });

        // 3. Predict to learn the Manager Safe address.
        KpkOivFactory.OivInstance memory predicted = KpkOivFactory(FACTORY).predictOivAddresses(config, DEPLOYER);

        // 4. Set feeReceiver to the predicted Manager Safe — matches the original spec
        //    ("operator and fee receiver are the deployed Manager Safe").
        config.sharesParams.feeReceiver = predicted.managerSafe;

        // 5. Re-predict to get the correct shares impl/proxy addresses (they depend on the full
        //    sharesParams, including feeReceiver).
        predicted = KpkOivFactory(FACTORY).predictOivAddresses(config, DEPLOYER);

        _logConfig(config);
        _logPredicted(predicted);

        // 6. Broadcast.
        vm.startBroadcast();
        KpkOivFactory.OivInstance memory deployed = KpkOivFactory(FACTORY).deployOiv(config);
        vm.stopBroadcast();

        _logDeployed(deployed);

        // 7. Defensive: deployed addresses MUST match predicted (caller-mixed CREATE2).
        require(deployed.avatarSafe == predicted.avatarSafe, "avatarSafe mismatch");
        require(deployed.managerSafe == predicted.managerSafe, "managerSafe mismatch");
        require(deployed.execRolesModifier == predicted.execRolesModifier, "execRolesModifier mismatch");
        require(deployed.subRolesModifier == predicted.subRolesModifier, "subRolesModifier mismatch");
        require(deployed.managerRolesModifier == predicted.managerRolesModifier, "managerRolesModifier mismatch");
        require(deployed.kpkSharesImpl == predicted.kpkSharesImpl, "kpkSharesImpl mismatch");
        require(deployed.kpkSharesProxy == predicted.kpkSharesProxy, "kpkSharesProxy mismatch");
    }

    // ── JSON loader ──────────────────────────────────────────────────────────

    function _loadFromJson()
        internal
        view
        returns (
            KpkShares.ConstructorParams memory params,
            KpkOivFactory.AssetConfig[] memory additionalAssets,
            address admin
        )
    {
        string memory json = vm.readFile(VAULTS_JSON_PATH);
        require(json.readUint(".mainnet.chain.id") == MAINNET_CHAIN_ID, "vaults.json: mainnet chain id mismatch");

        uint256 idx = _findVaultIndex(json);
        string memory base = string.concat(".mainnet.chain.vaults[", vm.toString(idx), "]");

        // sharesParams. Note: `params.admin` and `params.safe` are ignored by the factory
        // (overridden internally), so we leave them at zero. `params.feeReceiver` is set later
        // in run() after we predict the Manager Safe.
        params.asset = json.readAddress(string.concat(base, ".asset"));
        params.admin = address(0);
        params.name = json.readString(string.concat(base, ".name"));
        params.symbol = json.readString(string.concat(base, ".symbol"));
        params.safe = address(0);
        params.subscriptionRequestTtl = uint64(json.readUint(string.concat(base, ".subscriptionRequestTtl")));
        params.redemptionRequestTtl = uint64(json.readUint(string.concat(base, ".redemptionRequestTtl")));
        params.feeReceiver = address(0);
        params.managementFeeRate = json.readUint(string.concat(base, ".managementFeeRate"));
        params.redemptionFeeRate = json.readUint(string.concat(base, ".redemptionFeeRate"));
        params.performanceFeeModule = json.readAddress(string.concat(base, ".performanceFeeModule"));
        params.performanceFeeRate = json.readUint(string.concat(base, ".performanceFeeRate"));

        admin = json.readAddress(string.concat(base, ".admin"));

        // additionalAssets — every entry deploys with canDeposit + canRedeem true
        // (matches the existing DeployKpkShares.s.sol convention: updateAsset(addr, false, true, true)).
        address[] memory raw = json.readAddressArray(string.concat(base, ".additionalAssets"));
        additionalAssets = new KpkOivFactory.AssetConfig[](raw.length);
        for (uint256 i = 0; i < raw.length; i++) {
            additionalAssets[i] = KpkOivFactory.AssetConfig({asset: raw[i], canDeposit: true, canRedeem: true});
        }
    }

    function _findVaultIndex(string memory json) internal view returns (uint256) {
        string memory vaultsPath = ".mainnet.chain.vaults";
        require(json.keyExists(vaultsPath), "vaults.json: vaults array missing");
        for (uint256 i = 0; i < 100; i++) {
            string memory entry = string.concat(vaultsPath, "[", vm.toString(i), "]");
            if (!json.keyExists(entry)) break;
            if (
                keccak256(bytes(json.readString(string.concat(entry, ".vaultName")))) == keccak256(bytes(VAULT_NAME))
                    && keccak256(bytes(json.readString(string.concat(entry, ".environment"))))
                        == keccak256(bytes(VAULT_ENVIRONMENT))
            ) {
                return i;
            }
        }
        revert("vaults.json: production kUSD entry not found");
    }

    // ── Logging ──────────────────────────────────────────────────────────────

    function _logConfig(KpkOivFactory.OivConfig memory config) internal pure {
        console.log("==========================================");
        console.log("OivConfig");
        console.log("==========================================");
        console.log("salt (uint256):", config.salt);
        console.log("admin (DEFAULT_ADMIN_ROLE on shares + execRolesModifier owner):", config.admin);
        console.log("managerSafe.threshold:", config.managerSafe.threshold);
        for (uint256 i = 0; i < config.managerSafe.owners.length; i++) {
            console.log("managerSafe.owners[", i, "]:", config.managerSafe.owners[i]);
        }
        console.log("sharesParams.asset:", config.sharesParams.asset);
        console.log("sharesParams.name:", config.sharesParams.name);
        console.log("sharesParams.symbol:", config.sharesParams.symbol);
        console.log("sharesParams.subscriptionRequestTtl:", config.sharesParams.subscriptionRequestTtl);
        console.log("sharesParams.redemptionRequestTtl:", config.sharesParams.redemptionRequestTtl);
        console.log("sharesParams.feeReceiver (= predicted Manager Safe):", config.sharesParams.feeReceiver);
        console.log("sharesParams.managementFeeRate (bps):", config.sharesParams.managementFeeRate);
        console.log("sharesParams.redemptionFeeRate (bps):", config.sharesParams.redemptionFeeRate);
        console.log("sharesParams.performanceFeeModule:", config.sharesParams.performanceFeeModule);
        console.log("sharesParams.performanceFeeRate (bps):", config.sharesParams.performanceFeeRate);
        for (uint256 i = 0; i < config.additionalAssets.length; i++) {
            console.log("additionalAssets[", i, "].asset:", config.additionalAssets[i].asset);
        }
    }

    function _logPredicted(KpkOivFactory.OivInstance memory p) internal pure {
        console.log("==========================================");
        console.log("Predicted addresses");
        console.log("==========================================");
        console.log("Avatar Safe:           ", p.avatarSafe);
        console.log("Manager Safe:          ", p.managerSafe);
        console.log("Exec Roles Modifier:   ", p.execRolesModifier);
        console.log("Sub Roles Modifier:    ", p.subRolesModifier);
        console.log("Manager Roles Modifier:", p.managerRolesModifier);
        console.log("KpkShares impl:        ", p.kpkSharesImpl);
        console.log("KpkShares proxy:       ", p.kpkSharesProxy);
    }

    function _logDeployed(KpkOivFactory.OivInstance memory d) internal pure {
        console.log("==========================================");
        console.log("DEPLOYED");
        console.log("==========================================");
        console.log("Avatar Safe:           ", d.avatarSafe);
        console.log("Manager Safe:          ", d.managerSafe);
        console.log("Exec Roles Modifier:   ", d.execRolesModifier);
        console.log("Sub Roles Modifier:    ", d.subRolesModifier);
        console.log("Manager Roles Modifier:", d.managerRolesModifier);
        console.log("KpkShares impl:        ", d.kpkSharesImpl);
        console.log("KpkShares proxy:       ", d.kpkSharesProxy);
    }
}

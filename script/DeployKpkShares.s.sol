// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {KpkShares} from "../src/kpkShares.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

/**
 * @title DeployKpkShares
 * @notice Deployment script for kpkShares contract using UUPS proxy pattern
 * @dev This script deploys the kpkShares implementation and a UUPS proxy
 *      Constructor parameters are loaded from a JSON file in the script folder
 *
 * Usage:
 *   forge script script/DeployKpkShares.s.sol:DeployKpkShares \
 *     --rpc-url $ETH_RPC_URL \
 *     --broadcast \
 *     --verify \
 *     --sig "run(string)" "vault1"
 *
 */
contract DeployKpkShares is Script {
    using stdJson for string;

    /// @notice Mainnet chain ID
    uint256 private constant MAINNET_CHAIN_ID = 1;

    /// @notice Default JSON file path
    string private constant VAULTS_JSON_PATH = "script/vaults.json";

    /// @notice OPERATOR role identifier
    bytes32 private constant OPERATOR = keccak256("OPERATOR");

    /// @notice DEFAULT_ADMIN_ROLE identifier
    bytes32 private constant DEFAULT_ADMIN_ROLE = 0x00;

    /**
     * @notice Deploy a specific vault from JSON configuration
     * @param vaultName Name of the vault to deploy (from JSON). Must be non-empty
     */
    function run(string memory vaultName) external {
        // Verify we're on mainnet
        require(block.chainid == MAINNET_CHAIN_ID, "This script is only for Ethereum mainnet");

        // Require vault name to be specified
        require(bytes(vaultName).length > 0, "Vault name must be specified");

        // Read JSON configuration
        string memory json = vm.readFile(VAULTS_JSON_PATH);

        // Deploy the specified vault
        _deployVault(json, vaultName);
    }

    /**
     * @notice Deploy a specific vault from JSON configuration
     * @param json The JSON string containing vault configurations
     * @param vaultName The name of the vault to deploy
     */
    function _deployVault(string memory json, string memory vaultName) internal {
        string memory vaultPath = string.concat(".", vaultName);

        // Check if vault exists in JSON
        require(json.keyExists(vaultPath), "Vault not found in JSON configuration");

        // Parse vault parameters from JSON
        address asset = json.readAddress(string.concat(vaultPath, ".asset"));
        address admin = json.readAddress(string.concat(vaultPath, ".admin"));
        address operator = json.readAddress(string.concat(vaultPath, ".operator"));
        string memory name = json.readString(string.concat(vaultPath, ".name"));
        string memory symbol = json.readString(string.concat(vaultPath, ".symbol"));
        address safe = json.readAddress(string.concat(vaultPath, ".safe"));
        uint64 subscriptionTtl = uint64(json.readUint(string.concat(vaultPath, ".subscriptionRequestTtl")));
        uint64 redemptionTtl = uint64(json.readUint(string.concat(vaultPath, ".redemptionRequestTtl")));
        address feeReceiver = json.readAddress(string.concat(vaultPath, ".feeReceiver"));
        uint256 managementFeeRate = json.readUint(string.concat(vaultPath, ".managementFeeRate"));
        uint256 redemptionFeeRate = json.readUint(string.concat(vaultPath, ".redemptionFeeRate"));


        // Performance fee module is optional (can be address(0))
        address performanceFeeModule = address(0);
        if (json.keyExists(string.concat(vaultPath, ".performanceFeeModule"))) {
            address perfModule = json.readAddress(string.concat(vaultPath, ".performanceFeeModule"));
            if (perfModule != address(0)) {
                performanceFeeModule = perfModule;
            }
        }

        uint256 performanceFeeRate = json.readUint(string.concat(vaultPath, ".performanceFeeRate"));

        // Validate required parameters
        require(asset != address(0), "Asset address cannot be zero");
        require(safe != address(0), "Safe address cannot be zero");
        require(feeReceiver != address(0), "Fee receiver address cannot be zero");
        require(subscriptionTtl > 0, "Subscription TTL must be greater than 0");
        require(redemptionTtl > 0, "Redemption TTL must be greater than 0");
        require(managementFeeRate <= 2000, "Management fee rate cannot exceed 2000 bps (20%)");
        require(redemptionFeeRate <= 2000, "Redemption fee rate cannot exceed 2000 bps (20%)");
        require(performanceFeeRate <= 2000, "Performance fee rate cannot exceed 2000 bps (20%)");

        console.log("==========================================");
        console.log("Deploying kpkShares Vault:", vaultName);
        console.log("==========================================");

        vm.startBroadcast();


        address deployerAddress = vm.addr(vm.envUint("PRIVATE_KEY"));

        // Prepare initialization parameters
        KpkShares.ConstructorParams memory params = KpkShares.ConstructorParams({
            asset: asset,
            admin: deployerAddress,
            name: name,
            symbol: symbol,
            safe: safe,
            subscriptionRequestTtl: subscriptionTtl,
            redemptionRequestTtl: redemptionTtl,
            feeReceiver: feeReceiver,
            managementFeeRate: managementFeeRate,
            redemptionFeeRate: redemptionFeeRate,
            performanceFeeModule: performanceFeeModule,
            performanceFeeRate: performanceFeeRate
        });

        // Deploy implementation contract
        address implementation = address(new KpkShares());

        // Encode the initializer call
        bytes memory initializerData = abi.encodeCall(KpkShares.initialize, (params));

        // Deploy UUPS proxy using OpenZeppelin Foundry Upgrades (UnsafeUpgrades skips validation)
        address proxy = UnsafeUpgrades.deployUUPSProxy(implementation, initializerData);

        KpkShares proxyContract = KpkShares(proxy);
        proxyContract.grantRole(OPERATOR, operator);
        proxyContract.grantRole(DEFAULT_ADMIN_ROLE, admin);
        proxyContract.revokeRole(DEFAULT_ADMIN_ROLE, deployerAddress);

        vm.stopBroadcast();

        // Log deployment information
        console.log("==========================================");
        console.log("kpkShares Deployment Complete");
        console.log("=========================================="); 
        console.log("Vault Name:", vaultName);
        console.log("Proxy Address:", proxy);
        console.log("Admin:", admin);
        console.log("Asset:", asset);
        console.log("Name:", name);
        console.log("Symbol:", symbol);
        console.log("Safe:", safe);
        console.log("Subscription TTL:", subscriptionTtl);
        console.log("Redemption TTL:", redemptionTtl);
        console.log("Fee Receiver:", feeReceiver);
        console.log("Management Fee Rate (bps):", managementFeeRate);
        console.log("Redemption Fee Rate (bps):", redemptionFeeRate);
        console.log("Performance Fee Module:", performanceFeeModule);
        console.log("Performance Fee Rate (bps):", performanceFeeRate);
        console.log("Chain ID:", block.chainid);
        console.log("==========================================");
    }
}


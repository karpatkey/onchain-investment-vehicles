// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {KpkSharesNav} from "../src/KpkSharesNav.sol";
import {INavCalculator} from "../src/interfaces/INavCalculator.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

/**
 * @title DeployKpkSharesNav
 * @notice Deployment script for the NAV-priced fund, behind a UUPS proxy.
 *
 * Purpose:
 *   Deploys a `KpkSharesNav` implementation and its ERC-1967 UUPS proxy, then hands the roles over
 *   to the configured operator and admin. Unlike `KpkShares`, this contract is NOT deployed through
 *   `KpkOivFactory`/`KpkSharesDeployer` and uses no CREATE2 salt — it is a standalone sibling, so
 *   deploying it cannot disturb the live salt-v3 stack's addresses.
 *
 * Inputs:
 *   - `script/vaults-nav.json`, selected by vault name (see `_readParams`).
 *   - `PRIVATE_KEY` in the environment; that account deploys and is the transient admin.
 *
 * Outputs:
 *   - The proxy address, logged. That is the fund.
 *
 * Logic:
 *   1. Read and validate config, including a live check that the configured NAV calculator answers
 *      `usdDecimals()` with 8. Catching a wrong or superseded NAV address here is much cheaper than
 *      discovering it when the first batch fails to settle.
 *   2. Deploy implementation + proxy, initializing with the deployer as admin.
 *   3. Grant OPERATOR to the operator, DEFAULT_ADMIN_ROLE to the real admin, renounce the
 *      deployer's admin, and assert it is gone.
 *
 * Assumptions:
 *   - `NavPricingLib` is deployed and linked by forge automatically as part of this script.
 *   - The portfolio safe has approved (or will approve) the proxy to spend every redeemable asset;
 *     without that, redemptions revert on payout. There is no factory here to do it for you.
 *   - Synchronous deposits start DISABLED. Seed the fund through an operator-approved subscription
 *     before enabling them, so the first deposit is not priced against a bootstrap supply.
 *
 * Known limitations:
 *   - Only the base asset is listed at initialization; additional assets must be added afterwards
 *     with `updateAsset`, and each must already be registered and priceable in the NAV calculator.
 *
 * Usage:
 *   forge script script/DeployKpkSharesNav.s.sol:DeployKpkSharesNav \
 *     --rpc-url $ETH_RPC_URL \
 *     --broadcast \
 *     --verify \
 *     --sig "run(string)" "vault1"
 */
contract DeployKpkSharesNav is Script {
    using stdJson for string;

    /// @notice Default JSON configuration path
    string private constant CONFIG_PATH = "script/vaults-nav.json";

    /// @notice OPERATOR role identifier
    bytes32 private constant OPERATOR = keccak256("OPERATOR");

    /// @notice DEFAULT_ADMIN_ROLE identifier
    bytes32 private constant DEFAULT_ADMIN_ROLE = 0x00;

    /// @notice The USD scale this fund's arithmetic assumes of the NAV calculator
    uint8 private constant EXPECTED_USD_DECIMALS = 8;

    /// @notice Deploys one vault from the JSON configuration
    /// @param vaultName Name of the vault to deploy; must be non-empty
    function run(string memory vaultName) external returns (address proxy) {
        require(bytes(vaultName).length > 0, "Vault name must be specified");

        string memory json = vm.readFile(CONFIG_PATH);
        string memory base = string.concat(".vaults.", vaultName);

        uint256 configuredChainId = json.readUint(string.concat(base, ".chainId"));
        require(configuredChainId == block.chainid, "Config chainId does not match the connected chain");

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address operator = json.readAddress(string.concat(base, ".operator"));
        address finalAdmin = json.readAddress(string.concat(base, ".admin"));

        KpkSharesNav.ConstructorParams memory params = _readParams(json, base, deployer);
        _validate(params, operator, finalAdmin);

        vm.startBroadcast(deployerKey);

        address implementation = address(new KpkSharesNav());
        proxy = UnsafeUpgrades.deployUUPSProxy(implementation, abi.encodeCall(KpkSharesNav.initialize, (params)));

        _setupRoles(proxy, operator, finalAdmin, deployer);

        vm.stopBroadcast();

        console.log("KpkSharesNav implementation:", implementation);
        console.log("KpkSharesNav proxy (the fund):", proxy);
        console.log("NAV calculator:", params.navCalculator);
        console.log("Portfolio safe:", params.safe);
        console.log("Operator:", operator);
        console.log("Admin:", finalAdmin);
        console.log("Synchronous deposits: DISABLED (enable only after seeding the fund)");
        console.log("REMINDER: the portfolio safe must approve the proxy for every redeemable asset");
    }

    /// @notice Reads the initialization parameters from the config
    /// @param json The loaded configuration
    /// @param base The JSON path prefix for this vault
    /// @param deployer The account that will hold admin until the handover completes
    /// @return params The initialization parameters
    function _readParams(string memory json, string memory base, address deployer)
        private
        view
        returns (KpkSharesNav.ConstructorParams memory params)
    {
        params.asset = json.readAddress(string.concat(base, ".asset"));
        // The deployer must be admin at init so it can complete the role handover below
        params.admin = deployer;
        params.name = json.readString(string.concat(base, ".name"));
        params.symbol = json.readString(string.concat(base, ".symbol"));
        params.safe = json.readAddress(string.concat(base, ".safe"));
        params.subscriptionRequestTtl = uint64(json.readUint(string.concat(base, ".subscriptionRequestTtl")));
        params.redemptionRequestTtl = uint64(json.readUint(string.concat(base, ".redemptionRequestTtl")));
        params.feeReceiver = json.readAddress(string.concat(base, ".feeReceiver"));
        params.managementFeeRate = json.readUint(string.concat(base, ".managementFeeRate"));
        params.redemptionFeeRate = json.readUint(string.concat(base, ".redemptionFeeRate"));
        params.performanceFeeModule = json.readAddress(string.concat(base, ".performanceFeeModule"));
        params.performanceFeeRate = json.readUint(string.concat(base, ".performanceFeeRate"));
        params.navCalculator = json.readAddress(string.concat(base, ".navCalculator"));
        params.initialSharePrice = json.readUint(string.concat(base, ".initialSharePrice"));
    }

    /// @notice Validates the configuration before spending gas on a deployment
    /// @param params The initialization parameters
    /// @param operator The address that will hold OPERATOR
    /// @param finalAdmin The address that will hold DEFAULT_ADMIN_ROLE
    /// @dev The NAV calculator is probed live. A wrong address — most plausibly the superseded proxy
    ///      `0x80eD5cc6…`, which still answers — would otherwise only surface once the fund was
    ///      deployed and mispricing against an abandoned stack.
    function _validate(KpkSharesNav.ConstructorParams memory params, address operator, address finalAdmin)
        private
        view
    {
        require(params.asset != address(0), "asset must be set");
        require(params.safe != address(0), "safe must be set");
        require(params.feeReceiver != address(0), "feeReceiver must be set");
        require(params.navCalculator != address(0), "navCalculator must be set");
        require(operator != address(0), "operator must be set");
        require(finalAdmin != address(0), "admin must be set");
        require(params.initialSharePrice > 0, "initialSharePrice must be non-zero");
        require(params.managementFeeRate <= 2000, "managementFeeRate exceeds 20%");
        require(params.redemptionFeeRate <= 2000, "redemptionFeeRate exceeds 20%");
        require(params.performanceFeeRate <= 2000, "performanceFeeRate exceeds 20%");

        require(params.navCalculator.code.length > 0, "navCalculator is not a contract");
        require(
            INavCalculator(params.navCalculator).usdDecimals() == EXPECTED_USD_DECIMALS,
            "navCalculator does not report 8-decimal USD"
        );
        require(
            INavCalculator(params.navCalculator).isAssetRegistered(params.asset),
            "base asset is not registered in the NAV calculator"
        );
    }

    /// @notice Hands OPERATOR and DEFAULT_ADMIN_ROLE to their real holders and drops the deployer's
    /// @param proxy The deployed fund
    /// @param operator The address that will hold OPERATOR
    /// @param finalAdmin The address that will hold DEFAULT_ADMIN_ROLE
    /// @param deployer The transient admin to remove
    function _setupRoles(address proxy, address operator, address finalAdmin, address deployer) private {
        KpkSharesNav fund = KpkSharesNav(proxy);

        fund.grantRole(OPERATOR, operator);
        fund.grantRole(DEFAULT_ADMIN_ROLE, finalAdmin);
        fund.renounceRole(DEFAULT_ADMIN_ROLE, deployer);

        require(!fund.hasRole(DEFAULT_ADMIN_ROLE, deployer), "deployer still holds admin");
    }
}

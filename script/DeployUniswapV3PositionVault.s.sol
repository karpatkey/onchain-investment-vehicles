// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IUniswapV3PositionVault} from "../src/IUniswapV3PositionVault.sol";
import {UniswapV3PositionVault} from "../src/UniswapV3PositionVault.sol";

/// @title  DeployUniswapV3PositionVault
/// @author KPK
/// @notice Deploys one UniswapV3PositionVault behind an ERC-1967 proxy.
///
/// Purpose:  Stand up a share vault for a single Uniswap v3 pool, with its roles handed to their
///           final holders and the deploying key left with no authority over it.
/// Inputs:   PRIVATE_KEY in the environment, and a named entry in script/uniswap-vaults.json giving
///           the token pair, fee tier, position manager, role holders and manipulation-guard
///           settings. Set `openToEveryone` to grant INVESTOR to the zero address, which opens
///           deposits, redemptions and transfers to anyone.
/// Outputs:  The implementation and proxy addresses, logged. Nothing is written to disk; record the
///           proxy in script/deployed-infra.json and docs/DEPLOYED_ADDRESSES.md if the vault ships.
/// Logic:    Deploy the implementation, deploy the proxy with the deployer as temporary admin so it
///           can grant the remaining roles, then grant the configured admin and renounce. A
///           post-flight block asserts the end state before the script returns.
/// Assumptions: The pool already exists for the configured pair and fee tier; initialization
///           resolves it through the position manager's own factory and reverts if it does not.
///           The vault links UniswapV3VaultMath, which forge deploys and links automatically.
/// Known limitations: Plain CREATE, so the address depends on the deployer's nonce. This is a
///           per-fund instance rather than shared infrastructure, so it deliberately does not use
///           the CREATE2 salt scheme in script/base/OivChainDeploy.sol.
///
/// Usage:
///   source .env && forge script script/DeployUniswapV3PositionVault.s.sol:DeployUniswapV3PositionVault \
///     --rpc-url mainnet --broadcast --sig "run(string)" usdc-weth-mainnet
contract DeployUniswapV3PositionVault is Script {
    using stdJson for string;

    /// @notice Deploys the vault named by `vaultName` in script/uniswap-vaults.json.
    /// @param vaultName Key of the configuration entry to deploy.
    /// @return proxy The deployed vault proxy.
    function run(string memory vaultName) external returns (address proxy) {
        IUniswapV3PositionVault.InitParams memory params = _readConfig(vaultName);
        bool openToEveryone = _readBool(vaultName, ".openToEveryone");

        address finalAdmin = params.admin;
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // The deployer holds the admin role only for as long as it takes to grant the real one.
        params.admin = deployer;

        vm.startBroadcast(deployerKey);

        address implementation = address(new UniswapV3PositionVault());
        proxy = address(new ERC1967Proxy(implementation, abi.encodeCall(UniswapV3PositionVault.initialize, (params))));

        UniswapV3PositionVault vault = UniswapV3PositionVault(proxy);
        if (openToEveryone) vault.grantRole(vault.INVESTOR(), address(0));
        vault.grantRole(vault.DEFAULT_ADMIN_ROLE(), finalAdmin);
        vault.renounceRole(vault.DEFAULT_ADMIN_ROLE(), deployer);

        vm.stopBroadcast();

        _assertEndState(vault, finalAdmin, params.curator, deployer, openToEveryone);

        console.log("implementation:", implementation);
        console.log("vault proxy:   ", proxy);
        console.log("admin:         ", finalAdmin);
        console.log("curator:       ", params.curator);
        console.log("pool:          ", address(vault.pool()));
    }

    /// @notice Reads one vault's configuration out of script/uniswap-vaults.json.
    /// @param vaultName Key of the configuration entry.
    /// @return params The initialization parameters.
    function _readConfig(string memory vaultName)
        internal
        view
        returns (IUniswapV3PositionVault.InitParams memory params)
    {
        string memory json = vm.readFile("script/uniswap-vaults.json");
        string memory key = string.concat(".", vaultName);

        params = IUniswapV3PositionVault.InitParams({
            name: json.readString(string.concat(key, ".name")),
            symbol: json.readString(string.concat(key, ".symbol")),
            admin: json.readAddress(string.concat(key, ".admin")),
            curator: json.readAddress(string.concat(key, ".curator")),
            assetRecoverer: json.readAddress(string.concat(key, ".assetRecoverer")),
            positionManager: json.readAddress(string.concat(key, ".positionManager")),
            token0: json.readAddress(string.concat(key, ".token0")),
            token1: json.readAddress(string.concat(key, ".token1")),
            fee: uint24(json.readUint(string.concat(key, ".fee"))),
            twapPeriod: uint32(json.readUint(string.concat(key, ".twapPeriod"))),
            maxTwapDeviationBps: uint16(json.readUint(string.concat(key, ".maxTwapDeviationBps")))
        });
    }

    /// @notice Reads a boolean field for a vault entry.
    /// @param vaultName Key of the configuration entry.
    /// @param field     The dot-prefixed field name.
    /// @return The field's value.
    function _readBool(string memory vaultName, string memory field) internal view returns (bool) {
        string memory json = vm.readFile("script/uniswap-vaults.json");
        return json.readBool(string.concat(".", vaultName, field));
    }

    /// @notice Asserts the deployment ended in the intended state.
    /// @dev Runs after the broadcast, so a misconfigured hand-off fails the script rather than
    ///      leaving a vault the deploying key still controls.
    /// @param vault          The deployed vault.
    /// @param finalAdmin     The address that should hold the admin role.
    /// @param curator        The address that should hold the curator role.
    /// @param deployer       The deploying key, which should hold nothing.
    /// @param openToEveryone Whether the vault should be open to all investors.
    function _assertEndState(
        UniswapV3PositionVault vault,
        address finalAdmin,
        address curator,
        address deployer,
        bool openToEveryone
    ) internal view {
        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();
        require(vault.hasRole(adminRole, finalAdmin), "admin role not granted");
        require(!vault.hasRole(adminRole, deployer), "deployer still admin");
        require(vault.hasRole(vault.CURATOR(), curator), "curator role not granted");
        require(vault.isInvestor(address(1)) == openToEveryone, "investor gate misconfigured");
        require(address(vault.pool()) != address(0), "pool not resolved");
        require(vault.activeTokenId() == 0, "vault should start with no position");
    }
}

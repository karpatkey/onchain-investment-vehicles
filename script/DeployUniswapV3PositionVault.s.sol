// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IUniswapV3PositionVault} from "../src/IUniswapV3PositionVault.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3Pool.sol";
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
///           The library is built twice. Restricting the vault to the size-favouring profile pulls
///           its imports in with it, so out/ carries both UniswapV3VaultMath.json (the repository
///           default, optimizer_runs = 2000) and UniswapV3VaultMath.vault-size.json (runs = 60).
///           They behave identically but are different bytecode. Before verifying the deployed
///           library, compare its on-chain runtime against both artifacts and use the settings of
///           whichever matches; assuming the repository default will silently fail to verify.
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

        // The vault's own zero-address check never sees this value, because the line below swaps in
        // the deployer before initialize runs. Without this the shipped template's placeholder admin
        // would be granted the role and the deployer would then renounce, leaving a vault nobody can
        // administer, upgrade or configure. The post-flight assertion would pass, because the zero
        // address really does hold the role.
        require(finalAdmin != address(0), "admin must be set in the config");
        require(params.curator != address(0), "curator must be set in the config");
        require(params.assetRecoverer != address(0), "assetRecoverer must be set in the config");

        // The deployer holds the admin role only for as long as it takes to grant the real one.
        params.admin = deployer;

        vm.startBroadcast(deployerKey);

        address implementation = address(new UniswapV3PositionVault());
        proxy = address(new ERC1967Proxy(implementation, abi.encodeCall(UniswapV3PositionVault.initialize, (params))));

        UniswapV3PositionVault vault = UniswapV3PositionVault(proxy);
        if (openToEveryone) vault.grantRole(vault.INVESTOR(), address(0));
        // The first position mints the opening share supply to whoever opened it, and a mint is a
        // transfer the investor gate checks. Without this a closed vault deploys unable to open a
        // position at all, and the admin has to notice and grant the role before anything works.
        vault.grantRole(vault.INVESTOR(), params.curator);
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
            fee: uint24(_readBounded(json, key, ".fee", type(uint24).max)),
            twapPeriod: uint32(_readBounded(json, key, ".twapPeriod", type(uint32).max)),
            maxTwapDeviationBps: uint16(_readBounded(json, key, ".maxTwapDeviationBps", type(uint16).max))
        });
    }

    /// @notice Reads a numeric field and refuses one too large for the type it is destined for.
    /// @dev    A narrowing cast keeps the low bits, so a mistyped configuration does not fail, it
    ///         quietly becomes a different valid one: a fee of 2**24 + 500 reads as 500 and deploys
    ///         against a real pool that nobody chose. The initializer cannot catch it, because by
    ///         then the value it validates is the truncated one.
    /// @param json  The configuration document.
    /// @param key   The vault's key within it.
    /// @param field The dot-prefixed field name.
    /// @param max   The largest value the destination type holds.
    /// @return The field's value, guaranteed to survive the cast.
    function _readBounded(string memory json, string memory key, string memory field, uint256 max)
        internal
        pure
        returns (uint256)
    {
        uint256 value = json.readUint(string.concat(key, field));
        require(value <= max, string.concat("config value out of range:", field));
        return value;
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
        require(vault.isInvestor(curator), "curator cannot receive the opening shares");
        require(vault.isInvestor(address(1)) == openToEveryone, "investor gate misconfigured");
        require(address(vault.pool()) != address(0), "pool not resolved");
        require(vault.activeTokenId() == 0, "vault should start with no position");

        // A pool whose observation buffer is too short to answer the configured window reverts every
        // price-sensitive call, which would brick the vault until a third party grows the pool's
        // cardinality. Ask the pool now, so a bad pairing fails the deployment rather than the first
        // operation.
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = vault.twapPeriod();
        secondsAgos[1] = 0;
        IUniswapV3Pool(address(vault.pool())).observe(secondsAgos);
    }
}

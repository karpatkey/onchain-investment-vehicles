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
/// Inputs:   A signer supplied by forge itself, and a named entry in script/uniswap-vaults.json giving
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
///   First vault on a chain, deploying its implementation too:
///
///   forge script script/DeployUniswapV3PositionVault.s.sol:DeployUniswapV3PositionVault \
///     --rpc-url mainnet --account <keystore-name> --sender <that-account-address> \
///     --broadcast --sig "run(string)" usdc-weth-mainnet
///
///   Every vault after it, reusing the implementation the first one logged. The implementation is
///   code only — it holds nothing and every call runs against the proxy's own storage — so the
///   vaults stay independent, and the 6.8M gas and the explorer verification are paid once:
///
///   forge script script/DeployUniswapV3PositionVault.s.sol:DeployUniswapV3PositionVault \
///     --rpc-url mainnet --account <keystore-name> --sender <that-account-address> \
///     --broadcast --sig "run(string,address)" usdc-weth-mainnet 0xTheImplementation
///
///   forge prompts for the keystore password on stdin, so run it from an interactive shell and do
///   not put the password in a file, an environment variable or the command line. Drop --broadcast
///   first for a dry run: it simulates the whole script, including the post-flight assertions.
contract DeployUniswapV3PositionVault is Script {
    using stdJson for string;

    /// @notice Deploys the vault named by `vaultName`, on a fresh implementation of its own.
    /// @dev    Equivalent to passing the zero address to the two-argument form. Use that one for the
    ///         second and later vaults on a chain, so they share the implementation this deploys.
    /// @param vaultName Key of the configuration entry to deploy.
    /// @return proxy The deployed vault proxy.
    function run(string memory vaultName) external returns (address proxy) {
        return _deploy(vaultName, address(0));
    }

    /// @notice Deploys the vault named by `vaultName` behind an implementation that already exists.
    /// @dev    The implementation is code and nothing else: it holds no funds, no roles and no
    ///         storage, because every call a proxy forwards executes against the PROXY's storage.
    ///         So several vaults sharing one costs them no independence — different pools, different
    ///         balances, separate admins, and each upgradeable on its own later — while the 6.8M gas
    ///         to deploy it, and the work of verifying it on the explorer, are paid once.
    ///
    ///         Pass the zero address to deploy a fresh one. Anything else is checked for code and
    ///         interrogated below, because the one way this argument goes badly wrong is a proxy
    ///         pointed at an address that is not this contract: initialize would revert, or worse
    ///         succeed against something else's code.
    /// @param vaultName      Key of the configuration entry to deploy.
    /// @param implementation Existing UniswapV3PositionVault implementation, or zero to deploy one.
    /// @return proxy The deployed vault proxy.
    function run(string memory vaultName, address implementation) external returns (address proxy) {
        return _deploy(vaultName, implementation);
    }

    /// @notice The deployment itself, shared by both entry points.
    /// @param vaultName        Key of the configuration entry to deploy.
    /// @param existingImplementation Implementation to reuse, or zero to deploy a fresh one.
    /// @return proxy The deployed vault proxy.
    function _deploy(string memory vaultName, address existingImplementation) internal returns (address proxy) {
        IUniswapV3PositionVault.InitParams memory params = _readConfig(vaultName);
        bool openToEveryone = _readBool(vaultName, ".openToEveryone");

        address finalAdmin = params.admin;
        // The signer comes from forge rather than from the environment, so this works with an
        // encrypted keystore (--account), a hardware wallet (--ledger, --trezor) or a raw key
        // (--private-key) without the script knowing which. msg.sender is the address forge will
        // broadcast from; pass --sender alongside --account if forge cannot infer it.
        address deployer = msg.sender;
        require(deployer != address(0), "no broadcaster: pass --account, --ledger or --private-key");

        // The vault's own zero-address check never sees this value, because the line below swaps in
        // the deployer before initialize runs. Without this the shipped template's placeholder admin
        // would be granted the role and the deployer would then renounce, leaving a vault nobody can
        // administer, upgrade or configure. The post-flight assertion would pass, because the zero
        // address really does hold the role.
        require(finalAdmin != address(0), "admin must be set in the config");
        require(params.curator != address(0), "curator must be set in the config");
        require(params.assetRecoverer != address(0), "assetRecoverer must be set in the config");

        // The vault does not police these: how tight or loose the guard should be is a judgement
        // about the pool, and one implementation serves pools with very different characters. What
        // it cannot survive is a value that is not a setting at all, and the config is now the only
        // place either is ever written, so a typo here is permanent short of an upgrade.
        require(params.twapPeriod != 0, "twapPeriod of zero divides by zero in the guard");
        require(params.maxTwapDeviationBps != 0, "a zero deviation cap refuses every guarded call");
        require(params.maxTwapDeviationBps <= 10_000, "a deviation cap above 100% is not a bound");

        // The deployer holds the admin role only for as long as it takes to grant the real one.
        params.admin = deployer;

        // Checked before broadcasting, so a wrong address costs nothing. Code alone is too weak a
        // test — any contract has code — so the candidate is asked for two constants this contract
        // defines. A UUPS implementation also answers proxiableUUID; a PROXY deliberately does not,
        // which is what catches the likeliest mistake of all, pasting another vault's proxy address
        // here and chaining one vault's storage behind another.
        if (existingImplementation != address(0)) {
            require(existingImplementation.code.length != 0, "implementation has no code");
            _requireReturns(
                existingImplementation,
                bytes4(keccak256("CURATOR()")),
                keccak256("CURATOR"),
                "not a UniswapV3PositionVault: CURATOR"
            );
            _requireReturns(
                existingImplementation,
                bytes4(keccak256("INVESTOR()")),
                keccak256("INVESTOR"),
                "not a UniswapV3PositionVault: INVESTOR"
            );
            _requireReturns(
                existingImplementation,
                bytes4(keccak256("proxiableUUID()")),
                0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc,
                "that address is a proxy, not an implementation"
            );
        }

        vm.startBroadcast();

        address implementation =
            existingImplementation == address(0) ? address(new UniswapV3PositionVault()) : existingImplementation;
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

        console.log(existingImplementation == address(0) ? "implementation:  (new)" : "implementation:  (reused)");
        console.log("implementation:", implementation);
        console.log("vault proxy:   ", proxy);
        console.log("admin:         ", finalAdmin);
        console.log("curator:       ", params.curator);
        console.log("pool:          ", address(vault.pool()));
    }

    /// @notice Reverts with a readable message unless a static call returns exactly `expected`.
    /// @dev    A plain typed call cannot do this job. Calling CURATOR() on something that does not
    ///         have it reverts, or returns nothing, and the ABI decoder fails on the empty return
    ///         before any require of ours runs — so the operator sees "EvmError: Revert" with no
    ///         indication of which address was wrong or why. Measured against this chain's pool and
    ///         its Safe, both plausible things to paste by mistake. The low-level call keeps the
    ///         failure ours to describe.
    /// @param target   Address to interrogate.
    /// @param selector Zero-argument, bytes32-returning function to call.
    /// @param expected The only acceptable answer.
    /// @param message  What to say when it is not the answer.
    function _requireReturns(address target, bytes4 selector, bytes32 expected, string memory message) internal view {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSelector(selector));
        require(ok && ret.length == 32 && abi.decode(ret, (bytes32)) == expected, message);
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

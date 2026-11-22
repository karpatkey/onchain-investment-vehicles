// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {KpkSharesRouter} from "../src/periphery/KpkSharesRouter.sol";
import {IKpkSharesRouter} from "../src/periphery/IKpkSharesRouter.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title  DeployKpkSharesRouter
 * @notice Deploys one KpkSharesRouter for an existing KpkShares fund.
 * @dev    The script only deploys. Every wiring step needs a role the deployer does not and should not
 *         hold, so it prints the exact follow-up calls for the owning Safes instead of attempting them.
 *
 *         Wiring is deliberately NOT folded into KpkOivFactory: that factory's address is a pure
 *         function of its bytecode and is pinned across 19 chains by test/FactoryAddressSync.t.sol, so
 *         touching it would force a salt-v4 re-rollout of the whole infrastructure set.
 *
 * Usage:
 *   forge script script/DeployKpkSharesRouter.s.sol:DeployKpkSharesRouter \
 *     --rpc-url $MAINNET_URL \
 *     --broadcast \
 *     --verify \
 *     --sig "run(string)" "kUSD"
 *
 *   Dry run (no --broadcast) prints the follow-up calls without deploying.
 */
contract DeployKpkSharesRouter is Script {
    using stdJson for string;

    uint256 private constant MAINNET_CHAIN_ID = 1;
    string private constant ROUTERS_JSON_PATH = "script/routers.json";
    string private constant ROUTERS_ARRAY_PATH = ".mainnet.chain.routers";

    /// @notice `OPERATOR` on KpkShares — what the router needs, granted by the fund's admin.
    bytes32 private constant OPERATOR = keccak256("OPERATOR");

    struct RouterConfig {
        string fundName;
        address shares;
        address admin;
        address guardian;
    }

    /**
     * @notice Deploys the router for one fund from `script/routers.json`.
     * @param fundName The `fundName` key to deploy, e.g. "kUSD".
     */
    function run(string memory fundName) external {
        require(block.chainid == MAINNET_CHAIN_ID, "KpkShares proxies live on mainnet only");
        require(bytes(fundName).length > 0, "Fund name must be specified");

        string memory json = vm.readFile(ROUTERS_JSON_PATH);
        uint256 index = _findRouterIndex(json, fundName);
        string memory base = string.concat(ROUTERS_ARRAY_PATH, "[", vm.toString(index), "]");

        RouterConfig memory config = RouterConfig({
            fundName: fundName,
            shares: json.readAddress(string.concat(base, ".shares")),
            admin: json.readAddress(string.concat(base, ".admin")),
            guardian: json.readAddress(string.concat(base, ".guardian"))
        });

        _validate(config);

        vm.startBroadcast();
        KpkSharesRouter router = new KpkSharesRouter(config.shares, config.admin, config.guardian);
        vm.stopBroadcast();

        console.log("");
        console.log("=== KpkSharesRouter deployed ===");
        console.log("  fund       :", config.fundName);
        console.log("  router     :", address(router));
        console.log("  shares     :", config.shares);
        console.log("  admin      :", config.admin);
        console.log("  guardian   :", config.guardian);
        console.log("  domainSep  :", vm.toString(router.DOMAIN_SEPARATOR()));

        _printWiringSteps(json, base, config, address(router));
    }

    /// @dev Fails early on the mistakes that are cheap to catch here and expensive to catch later.
    function _validate(RouterConfig memory config) internal view {
        require(config.shares != address(0), "shares is zero");
        require(config.admin != address(0), "admin is zero");
        require(config.guardian != address(0), "guardian is zero");
        require(config.shares.code.length > 0, "shares is not a contract");

        // The configured admin must actually be able to grant OPERATOR, or the router can never settle.
        // Worth catching here: on the live stack DEFAULT_ADMIN_ROLE is mid-handover between Security
        // Council Safes, so a stale routers.json would otherwise produce an unwireable deployment.
        require(
            IAccessControl(config.shares).hasRole(bytes32(0), config.admin),
            "configured admin does not hold DEFAULT_ADMIN_ROLE on the fund"
        );
    }

    /// @dev Prints the calls the owning Safes must execute. Nothing here can be done by the deployer.
    function _printWiringSteps(string memory json, string memory base, RouterConfig memory config, address router)
        internal
        view
    {
        console.log("");
        console.log("=== Step 1: from the fund admin Safe", config.admin, "===");
        console.log("  target :", config.shares);
        console.log("  call   : grantRole(OPERATOR, router)");
        console.log("  data   :", vm.toString(abi.encodeWithSignature("grantRole(bytes32,address)", OPERATOR, router)));
        console.log("  note   : the Manager Safe KEEPS OPERATOR, so manual settlement stays available.");

        console.log("");
        console.log("=== Step 2: from the router admin Safe", config.admin, "===");
        console.log("  target :", router);
        console.log("  grantRole(NAV_SIGNER_ROLE, <pricing service key>)");
        console.log("  grantRole(RELAYER_ROLE,    <automation bot>)");
        console.log("  grantRole(GUARDIAN_ROLE,   <ops hot key>)   // second pauser, fast reaction");

        console.log("");
        console.log("=== Step 3: setAssetConfig per asset, from the router admin Safe ===");
        uint256 assetCount = _assetCount(json, base);
        for (uint256 i = 0; i < assetCount; i++) {
            _printAssetConfigCall(json, string.concat(base, ".assets[", vm.toString(i), "]"));
        }

        console.log("");
        console.log("=== Step 4: verify ===");
        console.log("  kpkShares.hasRole(OPERATOR, router) == true");
        console.log("  allowance(AvatarSafe, kpkShares) == max for every redeemable asset");
        console.log("  router.SHARES() ==", config.shares);
        console.log("  record the router address and DOMAIN_SEPARATOR in docs/DEPLOYED_ADDRESSES.md");
        console.log("");
        console.log("  Assets enabled on the fund AFTER its deployment have no Avatar Safe allowance to");
        console.log("  the shares proxy (the factory only grants at deploy time). Redemption in such an");
        console.log("  asset reverts until the Safe approves it via the exec Roles Modifier.");
    }

    /// @dev Split out of the loop in `_printWiringSteps` to keep the stack shallow enough for via-IR.
    function _printAssetConfigCall(string memory json, string memory assetPath) internal view {
        address asset = json.readAddress(string.concat(assetPath, ".address"));
        IKpkSharesRouter.AssetConfig memory config = _readAssetConfig(json, assetPath);
        bytes memory data = abi.encodeCall(IKpkSharesRouter.setAssetConfig, (asset, config));

        console.log("  ---");
        console.log("  symbol :", json.readString(string.concat(assetPath, ".symbol")));
        console.log("  asset  :", asset);
        console.log("  data   :", vm.toString(data));
    }

    function _readAssetConfig(string memory json, string memory assetPath)
        internal
        view
        returns (IKpkSharesRouter.AssetConfig memory)
    {
        return IKpkSharesRouter.AssetConfig({
            subscribeEnabled: json.readBool(string.concat(assetPath, ".subscribeEnabled")),
            redeemEnabled: json.readBool(string.concat(assetPath, ".redeemEnabled")),
            maxNavTtl: uint64(json.readUint(string.concat(assetPath, ".maxNavTtl"))),
            minHoldingPeriod: uint64(json.readUint(string.concat(assetPath, ".minHoldingPeriod"))),
            maxDeviationBps: uint16(json.readUint(string.concat(assetPath, ".maxDeviationBps"))),
            maxFeeDilutionBps: uint16(json.readUint(string.concat(assetPath, ".maxFeeDilutionBps"))),
            priceFloor: vm.parseUint(json.readString(string.concat(assetPath, ".priceFloor"))),
            priceCeil: vm.parseUint(json.readString(string.concat(assetPath, ".priceCeil"))),
            maxAssetsInPerTx: vm.parseUint(json.readString(string.concat(assetPath, ".maxAssetsInPerTx"))),
            maxSharesInPerTx: vm.parseUint(json.readString(string.concat(assetPath, ".maxSharesInPerTx"))),
            maxSharesMintedPerDay: vm.parseUint(json.readString(string.concat(assetPath, ".maxSharesMintedPerDay"))),
            maxAssetsOutPerDay: vm.parseUint(json.readString(string.concat(assetPath, ".maxAssetsOutPerDay")))
        });
    }

    /// @dev Locates a fund by name so the JSON can be reordered without breaking callers.
    ///      Walks indices with `keyExists` rather than a `[*]` wildcard, matching
    ///      `DeployKpkShares._findVaultIndex`: the wildcard does not reliably yield an array.
    function _findRouterIndex(string memory json, string memory fundName) internal view returns (uint256) {
        require(json.keyExists(ROUTERS_ARRAY_PATH), "routers array not found in routers.json");

        for (uint256 i = 0; i < 100; i++) {
            string memory path = string.concat(ROUTERS_ARRAY_PATH, "[", vm.toString(i), "]");
            if (!json.keyExists(path)) break;

            string memory name = json.readString(string.concat(path, ".fundName"));
            if (keccak256(bytes(name)) == keccak256(bytes(fundName))) return i;
        }
        revert(string.concat("Fund not found in routers.json: ", fundName));
    }

    /// @dev Counts an entry's configured assets by index probing, for the same reason as above.
    function _assetCount(string memory json, string memory base) internal view returns (uint256 count) {
        for (uint256 i = 0; i < 100; i++) {
            if (!json.keyExists(string.concat(base, ".assets[", vm.toString(i), "]"))) break;
            count++;
        }
    }
}

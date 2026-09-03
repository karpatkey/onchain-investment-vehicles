// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {OivInfraConstants} from "src/OivInfraConstants.sol";
import {Deploy_Ethereum} from "../script/chains/Deploy_Ethereum.s.sol";
import {Deploy_Optimism} from "../script/chains/Deploy_Optimism.s.sol";
import {Deploy_Gnosis} from "../script/chains/Deploy_Gnosis.s.sol";
import {Deploy_Base} from "../script/chains/Deploy_Base.s.sol";
import {Deploy_Arbitrum} from "../script/chains/Deploy_Arbitrum.s.sol";
import {Deploy_Bnb} from "../script/chains/Deploy_Bnb.s.sol";
import {Deploy_Polygon} from "../script/chains/Deploy_Polygon.s.sol";
import {Deploy_Avalanche} from "../script/chains/Deploy_Avalanche.s.sol";
import {Deploy_Celo} from "../script/chains/Deploy_Celo.s.sol";
import {Deploy_Linea} from "../script/chains/Deploy_Linea.s.sol";
import {Deploy_Scroll} from "../script/chains/Deploy_Scroll.s.sol";
import {Deploy_Sonic} from "../script/chains/Deploy_Sonic.s.sol";
import {Deploy_Unichain} from "../script/chains/Deploy_Unichain.s.sol";
import {Deploy_Worldchain} from "../script/chains/Deploy_Worldchain.s.sol";
import {Deploy_Hyperevm} from "../script/chains/Deploy_Hyperevm.s.sol";
import {Deploy_Mantle} from "../script/chains/Deploy_Mantle.s.sol";
import {Deploy_Plasma} from "../script/chains/Deploy_Plasma.s.sol";
import {Deploy_Ink} from "../script/chains/Deploy_Ink.s.sol";
import {Deploy_Bob} from "../script/chains/Deploy_Bob.s.sol";
import {Deploy_Berachain} from "../script/chains/Deploy_Berachain.s.sol";
import {Deploy_Katana} from "../script/chains/Deploy_Katana.s.sol";
import {CcipOivDeployer} from "src/CcipOivDeployer.sol";

/// @title  CcipNetworksSyncTest
/// @notice Guards against drift between the hardcoded per-chain CCIP_ROUTER / LINK_TOKEN / CHAIN_ID
///         constants and script/ccip-networks.json (the operator registry). deploy-chain.sh reads the
///         JSON only for verdict gating + chain resolution, while the Solidity scripts bake the values
///         in — so without this test the two sources can silently disagree. Fails CI if any per-chain
///         constant != its registry entry, or if the wired-chain count drifts from the scripts.
contract CcipNetworksSyncTest is Test {
    using stdJson for string;

    string internal json;

    function setUp() public {
        json = vm.readFile("script/ccip-networks.json");
    }

    /// @dev Per-chain scripts expose CHAIN_ID/CCIP_ROUTER/LINK_TOKEN as public constants; read them
    ///      back via the OivChainDeploy-derived instance and assert they equal the registry entry.
    function _assertWired(string memory name, address script) internal {
        (uint256 chainId, address router, address link) = _scriptConstants(script);

        for (uint256 i = 0; i < 64; i++) {
            string memory nameKey = string.concat(".networks[", vm.toString(i), "].name");
            if (!vm.keyExists(json, nameKey)) break;
            if (keccak256(bytes(json.readString(nameKey))) != keccak256(bytes(name))) continue;

            string memory base = string.concat(".networks[", vm.toString(i), "]");
            assertEq(json.readUint(string.concat(base, ".chainId")), chainId, string.concat(name, ": chainId drift"));
            assertEq(
                json.readAddress(string.concat(base, ".ccipRouter")), router, string.concat(name, ": router drift")
            );
            assertEq(json.readAddress(string.concat(base, ".linkToken")), link, string.concat(name, ": LINK drift"));
            string memory verdict = json.readString(string.concat(base, ".verdict"));
            assertTrue(
                keccak256(bytes(verdict)) == keccak256(bytes("READY"))
                    || keccak256(bytes(verdict)) == keccak256(bytes("READY-AFTER-EMPTY")),
                string.concat(name, ": has a per-chain script but registry verdict is not deployable")
            );
            return;
        }
        revert(string.concat("registry entry missing for wired chain ", name));
    }

    /// @dev Reads the three public constants off a per-chain script via low-level staticcalls, so this
    ///      helper does not need to know each concrete Deploy_<Chain> type.
    function _scriptConstants(address script) internal view returns (uint256 chainId, address router, address link) {
        chainId = abi.decode(_get(script, "CHAIN_ID()"), (uint256));
        router = abi.decode(_get(script, "CCIP_ROUTER()"), (address));
        link = abi.decode(_get(script, "LINK_TOKEN()"), (address));
    }

    function _get(address script, string memory sig) internal view returns (bytes memory) {
        (bool ok, bytes memory ret) = script.staticcall(abi.encodeWithSignature(sig));
        require(ok, string.concat("staticcall failed: ", sig));
        return ret;
    }

    function test_perChainConstantsMatchRegistry() public {
        _assertWired("ethereum", address(new Deploy_Ethereum()));
        _assertWired("optimism", address(new Deploy_Optimism()));
        _assertWired("gnosis", address(new Deploy_Gnosis()));
        _assertWired("base", address(new Deploy_Base()));
        _assertWired("arbitrum", address(new Deploy_Arbitrum()));
        _assertWired("bnb", address(new Deploy_Bnb()));
        _assertWired("polygon", address(new Deploy_Polygon()));
        _assertWired("avalanche", address(new Deploy_Avalanche()));
        _assertWired("celo", address(new Deploy_Celo()));
        _assertWired("linea", address(new Deploy_Linea()));
        _assertWired("scroll", address(new Deploy_Scroll()));
        _assertWired("sonic", address(new Deploy_Sonic()));
        _assertWired("unichain", address(new Deploy_Unichain()));
        _assertWired("worldchain", address(new Deploy_Worldchain()));
        _assertWired("hyperevm", address(new Deploy_Hyperevm()));
        _assertWired("mantle", address(new Deploy_Mantle()));
        _assertWired("plasma", address(new Deploy_Plasma()));
        _assertWired("ink", address(new Deploy_Ink()));
        _assertWired("bob", address(new Deploy_Bob()));
        _assertWired("berachain", address(new Deploy_Berachain()));
        _assertWired("katana", address(new Deploy_Katana()));
    }

    /// @dev Independently count deployable registry entries and assert it equals the number of
    ///      per-chain scripts this test covers — so adding a wired chain without a script (or vice
    ///      versa) fails here instead of going unnoticed.
    function test_wiredChainCountMatchesScripts() public {
        uint256 wired = 0;
        for (uint256 i = 0; i < 64; i++) {
            string memory verdictKey = string.concat(".networks[", vm.toString(i), "].verdict");
            if (!vm.keyExists(json, verdictKey)) break;
            string memory v = json.readString(verdictKey);
            if (
                keccak256(bytes(v)) == keccak256(bytes("READY"))
                    || keccak256(bytes(v)) == keccak256(bytes("READY-AFTER-EMPTY"))
            ) wired++;
        }
        assertEq(wired, 21, "wired-chain count in registry drifted from per-chain scripts");
    }

    /// @dev The registry's `.infra` block is a hand-maintained second copy of the canonical infra
    ///      addresses whose Solidity single source is `OivInfraConstants` (baked into CREATE2
    ///      init-code by the deploy path). Nothing else cross-checks them, so a one-sided edit — e.g.
    ///      bumping the Roles mastercopy in the library but not the JSON, or vice versa — would let
    ///      the operator registry silently advertise a stale address. Assert they stay in lockstep.
    function test_infraAddressesMatchLibrary() public view {
        assertEq(
            json.readAddress(".infra.safeProxyFactory"),
            OivInfraConstants.SAFE_PROXY_FACTORY,
            "infra.safeProxyFactory drift (ccip-networks.json vs OivInfraConstants)"
        );
        assertEq(
            json.readAddress(".infra.safeSingleton"),
            OivInfraConstants.SAFE_SINGLETON,
            "infra.safeSingleton drift (ccip-networks.json vs OivInfraConstants)"
        );
        assertEq(
            json.readAddress(".infra.safeModuleSetup"),
            OivInfraConstants.SAFE_MODULE_SETUP,
            "infra.safeModuleSetup drift (ccip-networks.json vs OivInfraConstants)"
        );
        assertEq(
            json.readAddress(".infra.safeFallbackHandler"),
            OivInfraConstants.SAFE_FALLBACK_HANDLER,
            "infra.safeFallbackHandler drift (ccip-networks.json vs OivInfraConstants)"
        );
        assertEq(
            json.readAddress(".infra.moduleProxyFactory"),
            OivInfraConstants.MODULE_PROXY_FACTORY,
            "infra.moduleProxyFactory drift (ccip-networks.json vs OivInfraConstants)"
        );
        assertEq(
            json.readAddress(".infra.rolesModifierMastercopy"),
            OivInfraConstants.ROLES_MODIFIER_MASTERCOPY,
            "infra.rolesModifierMastercopy drift (ccip-networks.json vs OivInfraConstants)"
        );
        assertEq(
            json.readAddress(".infra.multiSend"),
            OivInfraConstants.MULTI_SEND,
            "infra.multiSend drift (ccip-networks.json vs OivInfraConstants)"
        );
        assertEq(
            json.readAddress(".infra.multiSendCallsOnly"),
            OivInfraConstants.MULTI_SEND_CALLS_ONLY,
            "infra.multiSendCallsOnly drift (ccip-networks.json vs OivInfraConstants)"
        );
        assertEq(
            json.readAddress(".infra.multiSendUnwrapper"),
            OivInfraConstants.MULTISEND_UNWRAPPER,
            "infra.multiSendUnwrapper drift (ccip-networks.json vs OivInfraConstants)"
        );
    }

    /// @dev The factory registers the unwrap adapter against `multiSend(bytes)` on every Roles
    ///      Modifier it deploys. Pin the selector so a mistyped signature in the library cannot
    ///      silently register the adapter under a key nothing ever calls — the failure mode would
    ///      only surface in production, as a fund whose batched transactions all revert.
    function test_multiSendSelectorMatchesSignature() public pure {
        assertEq(
            OivInfraConstants.MULTI_SEND_SELECTOR,
            bytes4(keccak256("multiSend(bytes)")),
            "MULTI_SEND_SELECTOR is not bytes4(keccak256('multiSend(bytes)'))"
        );
    }

    /// @notice `CcipOivDeployer._seedKnownChains` bakes the wired topology into the orchestrator's
    ///         constructor, so a fresh instance needs no owner seeding. That list is a hand-written
    ///         copy of the wired subset of this registry, which makes it exactly the kind of thing
    ///         that rots: editing the JSON without editing the constructor would leave every
    ///         orchestrator silently missing a chain, or fanning out to one with no infrastructure and
    ///         burning non-refundable CCIP fees on messages whose delivery reverts.
    ///
    ///         Asserts both directions — every wired chain is baked with the right selector, and
    ///         nothing is baked that the registry does not list as wired.
    function test_bakedTopologyMatchesRegistry() public {
        string memory json = vm.readFile("script/ccip-networks.json");
        CcipOivDeployer orch = new CcipOivDeployer(address(this), address(this));

        uint256 wired;
        for (uint256 i = 0;; i++) {
            string memory base = string.concat(".networks[", vm.toString(i), "]");
            if (!vm.keyExists(json, string.concat(base, ".chainId"))) break;

            string memory name = json.readString(string.concat(base, ".name"));
            uint256 chainId = json.readUint(string.concat(base, ".chainId"));
            string memory verdict = json.readString(string.concat(base, ".verdict"));
            bool excluded =
                vm.keyExists(json, string.concat(base, ".excluded")) && json.readBool(string.concat(base, ".excluded"));
            bool isWired = !excluded
                && (keccak256(bytes(verdict)) == keccak256(bytes("READY"))
                    || keccak256(bytes(verdict)) == keccak256(bytes("READY-AFTER-EMPTY")));

            uint64 baked = orch.chainSelectorOf(chainId);
            if (isWired) {
                wired++;
                assertEq(
                    baked,
                    uint64(json.readUint(string.concat(base, ".ccipChainSelector"))),
                    string.concat(name, ": wired in the registry but not baked with that selector")
                );
            } else {
                assertEq(baked, 0, string.concat(name, ": not wired in the registry but baked anyway"));
            }
        }

        assertEq(orch.getChainIdCount(), wired, "baked set size must equal the registry's wired count");
    }
}

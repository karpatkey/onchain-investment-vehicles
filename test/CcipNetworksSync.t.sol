// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
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
}

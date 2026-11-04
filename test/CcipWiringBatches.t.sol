// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, Vm} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

/// @title  CcipWiringBatchesTest
/// @notice Guards the committed Security Council wiring batches (script/safe-txs/ccip-wire-<chain>/,
///         written by script/wire-chain.sh) against the registry. `setChainSelector` refuses only a
///         zero selector or one another chain id already holds, so a wrong value lands on-chain. A
///         selector the local router does not support silently drops the chain from fan-outs (an
///         explicit destination reverts `LaneNotSupported` before any fee). A supported one that
///         belongs to another chain sends a paid stack there. Either way, the chain's own messages stay
///         refused (`InvalidSourceChain`). Every entry must call `setChainSelector(uint256,uint64)` on
///         the canonical orchestrator, from the recorded owner, with the selector
///         script/ccip-networks.json holds for that chain id.
contract CcipWiringBatchesTest is Test {
    using stdJson for string;

    string internal registry;
    address internal orchestrator;
    address internal owner;

    function setUp() public {
        registry = vm.readFile("script/ccip-networks.json");
        string memory infra = vm.readFile("script/deployed-infra.json");
        orchestrator = infra.readAddress(".canonical.ccipOivDeployer");
        owner = infra.readAddress(".finalOwner");
    }

    function test_wiringBatchesMatchTheRegistry() public view {
        uint256 checked;
        Vm.DirEntry[] memory dirs = vm.readDir("script/safe-txs");
        for (uint256 d = 0; d < dirs.length; d++) {
            if (!dirs[d].isDir || !_isWiringDir(dirs[d].path)) continue;
            Vm.DirEntry[] memory files = vm.readDir(dirs[d].path);
            for (uint256 f = 0; f < files.length; f++) {
                checked += _checkBatch(files[f].path);
            }
        }
        assertGt(checked, 0, "no wiring batch found under script/safe-txs/ccip-wire-*");
    }

    function _checkBatch(string memory path) internal view returns (uint256 txs) {
        string memory batch = vm.readFile(path);
        uint256 batchChain = vm.parseUint(batch.readString(".chainId"));
        assertTrue(_selectorOf(batchChain) != 0, string.concat(path, ": chain not in the registry"));
        assertEq(batch.readAddress(".meta.createdFromSafeAddress"), owner, string.concat(path, ": not the owner"));

        for (; vm.keyExists(batch, string.concat(".transactions[", vm.toString(txs), "]")); txs++) {
            string memory t = string.concat(".transactions[", vm.toString(txs), "]");
            assertEq(batch.readAddress(string.concat(t, ".to")), orchestrator, string.concat(path, ": wrong target"));
            assertEq(batch.readString(string.concat(t, ".value")), "0", string.concat(path, ": sends value"));
            assertEq(
                batch.readString(string.concat(t, ".contractMethod.name")),
                "setChainSelector",
                string.concat(path, ": not setChainSelector")
            );
            // The Transaction Builder encodes from these inputs: any other type is another selector.
            _assertInput(batch, path, t, 0, "chainId", "uint256");
            _assertInput(batch, path, t, 1, "ccipChainSelector", "uint64");
            assertFalse(
                vm.keyExists(batch, string.concat(t, ".contractMethod.inputs[2]")), string.concat(path, ": extra input")
            );
            uint256 chainId = vm.parseUint(batch.readString(string.concat(t, ".contractInputsValues.chainId")));
            uint256 selector =
                vm.parseUint(batch.readString(string.concat(t, ".contractInputsValues.ccipChainSelector")));
            uint256 expected = _selectorOf(chainId);
            assertTrue(expected != 0, string.concat(path, ": chain id not in the registry"));
            assertEq(selector, expected, string.concat(path, ": selector differs from the registry"));
        }
        assertGt(txs, 0, string.concat(path, ": empty batch"));
    }

    function _assertInput(
        string memory batch,
        string memory path,
        string memory t,
        uint256 i,
        string memory name,
        string memory solType
    ) internal pure {
        string memory input = string.concat(t, ".contractMethod.inputs[", vm.toString(i), "]");
        assertEq(batch.readString(string.concat(input, ".name")), name, string.concat(path, ": input name"));
        assertEq(batch.readString(string.concat(input, ".type")), solType, string.concat(path, ": input type"));
        assertEq(batch.readString(string.concat(input, ".internalType")), solType, string.concat(path, ": input type"));
    }

    function _isWiringDir(string memory path) internal pure returns (bool) {
        return vm.contains(path, "/ccip-wire-");
    }

    /// @dev The registry's selector for `chainId`, or 0 when the registry has no such chain.
    function _selectorOf(uint256 chainId) internal view returns (uint256) {
        for (uint256 i = 0; i < 64; i++) {
            string memory base = string.concat(".networks[", vm.toString(i), "]");
            if (!vm.keyExists(registry, string.concat(base, ".chainId"))) break;
            if (registry.readUint(string.concat(base, ".chainId")) != chainId) continue;
            return vm.parseUint(registry.readString(string.concat(base, ".ccipChainSelector")));
        }
        return 0;
    }
}

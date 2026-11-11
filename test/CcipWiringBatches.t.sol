// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, Vm} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

/// @title  CcipWiringBatchesTest
/// @notice Guards the committed Security Council wiring batches (script/safe-txs/ccip-wire-<chain>/,
///         written by script/wire-chain.sh) against the registry and against the execution order.
///
///         `setChainSelector` refuses only a zero selector or one another chain id already holds, so a
///         wrong value lands on-chain. A selector the local router does not support silently drops the
///         chain from fan-outs (an explicit destination reverts `LaneNotSupported` before any fee). A
///         supported one that belongs to another chain sends a paid stack there. Either way, the chain's
///         own messages stay refused (`InvalidSourceChain`).
///
///         The files are numbered in execution order, and each step has one role:
///         - `1-<chain>.json`: on the chain itself, entries for counterparts (never its own id);
///         - `2-<counterpart>.json`: on a counterpart, exactly one entry, for the wired chain;
///         - `3-<chain>.json`: on the chain itself, exactly one entry, its own id. Last, because it opens
///           `onlyWiredChain` origination to anyone, and a counterpart not yet wired would reject the
///           stack after its CCIP fee is paid.
///         `manifest.json` lists exactly the batch files present, so a lost or extra file fails here.
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

    // ── The committed batches ────────────────────────────────────────────────────────────────────

    function test_wiringBatchesMatchTheRegistryAndTheOrder() public view {
        uint256 checked;
        Vm.DirEntry[] memory dirs = vm.readDir("script/safe-txs");
        for (uint256 d = 0; d < dirs.length; d++) {
            if (!dirs[d].isDir || !vm.contains(dirs[d].path, "/ccip-wire-")) continue;
            string memory wired = vm.replace(_lastSegment(dirs[d].path), "ccip-wire-", "");
            Vm.DirEntry[] memory entries = vm.readDir(dirs[d].path);
            string[] memory names = new string[](entries.length);
            for (uint256 f = 0; f < entries.length; f++) {
                names[f] = _lastSegment(entries[f].path);
            }
            string memory manifest = vm.readFile(string.concat(dirs[d].path, "/manifest.json"));
            this.checkManifest(wired, manifest, names);
            this.checkComplete(wired, names);
            for (uint256 f = 0; f < entries.length; f++) {
                if (_eq(names[f], "manifest.json")) continue;
                checked += this.checkBatch(wired, names[f], vm.readFile(entries[f].path));
            }
        }
        // The Robinhood and Arc batches are the reviewed record of what the Council signs: they stay
        // committed after execution, so their absence is a lost record, not a finished wiring.
        assertTrue(vm.isDir("script/safe-txs/ccip-wire-robinhood"), "ccip-wire-robinhood is missing");
        assertTrue(vm.isDir("script/safe-txs/ccip-wire-arc"), "ccip-wire-arc is missing");
        assertGt(checked, 0, "no wiring batch found under script/safe-txs/ccip-wire-*");
        // The counterpart sets are the CCIP lanes read on-chain when the batches were reviewed (both
        // routers' isChainSupported): a dropped 2-<counterpart>.json plus a matching manifest edit would
        // otherwise pass every per-file check.
        string[] memory rh = new string[](8);
        rh[0] = "2-arbitrum.json";
        rh[1] = "2-avalanche.json";
        rh[2] = "2-base.json";
        rh[3] = "2-bnb.json";
        rh[4] = "2-ethereum.json";
        rh[5] = "2-hyperevm.json";
        rh[6] = "2-polygon.json";
        rh[7] = "3-robinhood.json";
        _assertFiles("robinhood", rh);
        string[] memory arc = new string[](4);
        arc[0] = "2-base.json";
        arc[1] = "2-ethereum.json";
        arc[2] = "2-polygon.json";
        arc[3] = "3-arc.json";
        _assertFiles("arc", arc);
    }

    function _assertFiles(string memory wired, string[] memory expected) internal view {
        string memory dir = string.concat("script/safe-txs/ccip-wire-", wired);
        string[] memory listed = vm.readFile(string.concat(dir, "/manifest.json")).readStringArray(".files");
        assertEq(listed.length, expected.length, string.concat("ccip-wire-", wired, ": counterpart set changed"));
        for (uint256 i = 0; i < expected.length; i++) {
            assertTrue(
                vm.isFile(string.concat(dir, "/", expected[i])),
                string.concat("ccip-wire-", wired, ": missing ", expected[i])
            );
        }
    }

    // ── Negative controls (synthetic batches, independent of what is committed) ───────────────────

    /// @dev The Transaction Builder executes a batch on its top-level `chainId`, so a batch named for
    ///      Base but carrying Ethereum's id would land on Ethereum and leave Base unwired.
    function test_rejectsABatchForAnotherChain() public {
        string memory b = _batch("1", _entry("4663", "6180753054346818345"));
        vm.expectRevert(bytes("2-base.json: chainId is not the chain its file names"));
        this.checkBatch("robinhood", "2-base.json", b);
    }

    /// @dev A counterpart batch that wires some other chain (with that chain's correct selector) is
    ///      registry-consistent but leaves the wired chain out.
    function test_rejectsACounterpartWiringAnotherChain() public {
        string memory b = _batch("8453", _entry("10", _selectorString(10)));
        vm.expectRevert(bytes("2-base.json: step 2 must wire the chain its directory names"));
        this.checkBatch("robinhood", "2-base.json", b);
    }

    /// @dev The origin entry must not ride with anything else, or be executed before the counterparts.
    function test_rejectsTheOriginEntryOutsideStep3() public {
        string memory b = _batch("4663", _entry("4663", "6180753054346818345"));
        vm.expectRevert(bytes("1-robinhood.json: step 1 must not set the chain's own id"));
        this.checkBatch("robinhood", "1-robinhood.json", b);
    }

    function test_rejectsStep3WithMoreThanTheOriginEntry() public {
        string memory origin = _entry("4663", "6180753054346818345");
        string memory two = string.concat(origin, ",", origin);
        vm.expectRevert(bytes("3-robinhood.json: step 3 must hold exactly one entry"));
        this.checkBatch("robinhood", "3-robinhood.json", _batch("4663", two));
    }

    function test_rejectsRawCalldata() public {
        string memory e = vm.replace(_entry("4663", "6180753054346818345"), '"data": null', '"data": "0xdeadbeef"');
        vm.expectRevert(bytes("2-base.json: raw data beside contractMethod"));
        this.checkBatch("robinhood", "2-base.json", _batch("8453", e));
    }

    function test_rejectsFalsyRawCalldata() public {
        string memory e = vm.replace(
            _entry("4663", "6180753054346818345"),
            '"data": null',
            '"data": "0x0000000000000000000000000000000000000000000000000000000000000000"'
        );
        vm.expectRevert(bytes("2-base.json: raw data beside contractMethod"));
        this.checkBatch("robinhood", "2-base.json", _batch("8453", e));
    }

    function test_rejectsAStepOnTheWrongChain() public {
        string memory b = _batch("4663", _entry("4663", "6180753054346818345"));
        vm.expectRevert(bytes("2-robinhood.json: steps 1 and 3 run on the wired chain, 2 elsewhere"));
        this.checkBatch("robinhood", "2-robinhood.json", b);
    }

    function test_rejectsASelectorOffTheRegistry() public {
        string memory b = _batch("8453", _entry("4663", "6180753054346818346"));
        vm.expectRevert(
            bytes("2-base.json: selector differs from the registry: 6180753054346818346 != 6180753054346818345")
        );
        this.checkBatch("robinhood", "2-base.json", b);
    }

    function test_rejectsAnotherOwner() public {
        string memory b = vm.replace(
            _batch("8453", _entry("4663", "6180753054346818345")),
            vm.toString(owner),
            "0x000000000000000000000000000000000000dEaD"
        );
        vm.expectRevert(
            bytes(
                "2-base.json: not the owner: 0x000000000000000000000000000000000000dEaD != 0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537"
            )
        );
        this.checkBatch("robinhood", "2-base.json", b);
    }

    function test_rejectsAManifestNamingAnotherFile() public {
        string[] memory names = new string[](3);
        names[0] = "2-base.json";
        names[1] = "3-robinhood.json";
        names[2] = "manifest.json";
        vm.expectRevert(bytes("ccip-wire-robinhood: manifest and files differ"));
        this.checkManifest("robinhood", _manifest('"2-ethereum.json","3-robinhood.json"'), names);
    }

    function test_rejectsAManifestMissingAFile() public {
        string[] memory names = new string[](3);
        names[0] = "2-base.json";
        names[1] = "3-robinhood.json";
        names[2] = "manifest.json";
        string memory manifest = _manifest('"2-base.json","2-ethereum.json","3-robinhood.json"');
        vm.expectRevert(bytes("ccip-wire-robinhood: manifest and files differ"));
        this.checkManifest("robinhood", manifest, names);
    }

    function test_rejectsAFileTheManifestDoesNotList() public {
        string[] memory names = new string[](3);
        names[0] = "2-base.json";
        names[1] = "3-robinhood.json";
        names[2] = "manifest.json";
        vm.expectRevert(bytes("ccip-wire-robinhood: manifest and files differ"));
        this.checkManifest("robinhood", _manifest('"3-robinhood.json"'), names);
    }

    function test_rejectsAWiringWithoutItsFinalStep() public {
        string[] memory names = new string[](3);
        names[0] = "2-base.json";
        names[1] = "2-ethereum.json";
        names[2] = "manifest.json";
        vm.expectRevert(bytes("ccip-wire-arc: needs exactly one 3-arc.json"));
        this.checkComplete("arc", names);
    }

    function test_rejectsAWiringWithoutCounterparts() public {
        string[] memory names = new string[](2);
        names[0] = "3-arc.json";
        names[1] = "manifest.json";
        vm.expectRevert(bytes("ccip-wire-arc: no step-2 counterpart batch"));
        this.checkComplete("arc", names);
    }

    // ── Checks (external so negative controls can expect their reverts) ───────────────────────────

    /// @dev Every wiring ends with its own step 3 (the chain's id, alone, LAST) and has at least one
    ///      counterpart; without step 3 the chain never originates, without a step 2 nothing accepts it.
    function checkComplete(string memory wired, string[] memory names) external pure {
        string memory dir = string.concat("ccip-wire-", wired);
        string memory last = string.concat("3-", wired, ".json");
        uint256 finals;
        uint256 counterparts;
        for (uint256 i = 0; i < names.length; i++) {
            if (_eq(names[i], last)) finals++;
            else if (bytes(names[i]).length > 2 && bytes(names[i])[0] == "2" && bytes(names[i])[1] == "-") counterparts++;
        }
        require(finals == 1, string.concat(dir, ": needs exactly one ", last));
        require(counterparts > 0, string.concat(dir, ": no step-2 counterpart batch"));
    }

    function checkManifest(string memory wired, string memory manifest, string[] memory names) external view {
        string memory dir = string.concat("ccip-wire-", wired);
        assertEq(manifest.readString(".chain"), wired, string.concat(dir, ": manifest names another chain"));
        uint256 id = manifest.readUint(".chainId");
        assertEq(id, _chainIdNamed(wired), string.concat(dir, ": manifest chain id"));
        assertEq(
            vm.parseUint(manifest.readString(".ccipChainSelector")),
            _selectorOf(id),
            string.concat(dir, ": manifest selector")
        );
        assertEq(manifest.readAddress(".orchestrator"), orchestrator, string.concat(dir, ": manifest orchestrator"));
        string[] memory listed = manifest.readStringArray(".files");
        // Every name present (bar the manifest itself) is listed, and the counts agree, so the sets match.
        assertTrue(listed.length + 1 == names.length, string.concat(dir, ": manifest and files differ"));
        for (uint256 i = 0; i < names.length; i++) {
            if (_eq(names[i], "manifest.json")) continue;
            bool found;
            for (uint256 j = 0; j < listed.length; j++) {
                if (_eq(listed[j], names[i])) found = true;
            }
            assertTrue(found, string.concat(dir, ": manifest and files differ"));
        }
    }

    function checkBatch(string memory wired, string memory file, string memory batch)
        external
        view
        returns (uint256 txs)
    {
        // "2-base.json" -> step 2, executed on "base".
        string[] memory parts = vm.split(vm.replace(file, ".json", ""), "-");
        assertEq(parts.length, 2, string.concat(file, ": not <step>-<chain>.json"));
        uint256 step = vm.parseUint(parts[0]);
        string memory on = parts[1];
        assertTrue(step >= 1 && step <= 3, string.concat(file, ": step must be 1, 2 or 3"));
        assertTrue(
            (step == 2) != _eq(on, wired), string.concat(file, ": steps 1 and 3 run on the wired chain, 2 elsewhere")
        );

        uint256 wiredId = _chainIdNamed(wired);
        assertTrue(wiredId != 0, string.concat(file, ": wired chain not in the registry"));
        assertTrue(
            vm.parseUint(batch.readString(".chainId")) == _chainIdNamed(on),
            string.concat(file, ": chainId is not the chain its file names")
        );
        assertEq(batch.readAddress(".meta.createdFromSafeAddress"), owner, string.concat(file, ": not the owner"));

        for (; vm.keyExists(batch, string.concat(".transactions[", vm.toString(txs), "]")); txs++) {
            uint256 chainId = _checkEntry(batch, file, string.concat(".transactions[", vm.toString(txs), "]"));
            if (step == 1) {
                assertTrue(chainId != wiredId, string.concat(file, ": step 1 must not set the chain's own id"));
            } else {
                assertTrue(
                    chainId == wiredId,
                    string.concat(
                        file,
                        step == 2
                            ? ": step 2 must wire the chain its directory names"
                            : ": step 3 sets the chain's own id only"
                    )
                );
            }
        }
        assertGt(txs, 0, string.concat(file, ": empty batch"));
        // The Builder sends a truthy `data` as raw calldata instead of encoding `contractMethod`, and
        // the JSON cheatcodes read null, false and "0x00…" alike, so pin the text: every entry carries
        // exactly `"data": null`, as wire-chain.sh writes it.
        assertTrue(
            vm.split(batch, '"data"').length == txs + 1 && vm.split(batch, '"data": null').length == txs + 1,
            string.concat(file, ": raw data beside contractMethod")
        );
        if (step != 1) assertTrue(txs == 1, string.concat(file, ": step ", parts[0], " must hold exactly one entry"));
    }

    /// @dev One `setChainSelector(uint256,uint64)` entry on the canonical orchestrator with the
    ///      registry's selector; returns the chain id it wires.
    function _checkEntry(string memory batch, string memory file, string memory t) internal view returns (uint256) {
        assertEq(batch.readAddress(string.concat(t, ".to")), orchestrator, string.concat(file, ": wrong target"));
        assertEq(batch.readString(string.concat(t, ".value")), "0", string.concat(file, ": sends value"));
        assertEq(
            batch.readString(string.concat(t, ".contractMethod.name")),
            "setChainSelector",
            string.concat(file, ": not setChainSelector")
        );
        // The Transaction Builder encodes from these inputs: any other type is another selector.
        _assertInput(batch, file, t, 0, "chainId", "uint256");
        _assertInput(batch, file, t, 1, "ccipChainSelector", "uint64");
        assertFalse(
            vm.keyExists(batch, string.concat(t, ".contractMethod.inputs[2]")), string.concat(file, ": extra input")
        );
        uint256 chainId = vm.parseUint(batch.readString(string.concat(t, ".contractInputsValues.chainId")));
        uint256 selector = vm.parseUint(batch.readString(string.concat(t, ".contractInputsValues.ccipChainSelector")));
        uint256 expected = _selectorOf(chainId);
        assertTrue(expected != 0, string.concat(file, ": chain id not in the registry"));
        assertEq(selector, expected, string.concat(file, ": selector differs from the registry"));
        return chainId;
    }

    function _assertInput(
        string memory batch,
        string memory file,
        string memory t,
        uint256 i,
        string memory name,
        string memory solType
    ) internal pure {
        string memory input = string.concat(t, ".contractMethod.inputs[", vm.toString(i), "]");
        assertEq(batch.readString(string.concat(input, ".name")), name, string.concat(file, ": input name"));
        assertEq(batch.readString(string.concat(input, ".type")), solType, string.concat(file, ": input type"));
        assertEq(batch.readString(string.concat(input, ".internalType")), solType, string.concat(file, ": input type"));
    }

    // ── Helpers ──────────────────────────────────────────────────────────────────────────────────

    function _lastSegment(string memory path) internal pure returns (string memory) {
        string[] memory parts = vm.split(path, "/");
        return parts[parts.length - 1];
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// @dev The registry's chain id for `name`, or 0 when the registry has no such chain.
    function _chainIdNamed(string memory name) internal view returns (uint256) {
        for (uint256 i = 0; i < 64; i++) {
            string memory base = string.concat(".networks[", vm.toString(i), "]");
            if (!vm.keyExists(registry, string.concat(base, ".name"))) break;
            if (!_eq(registry.readString(string.concat(base, ".name")), name)) continue;
            return registry.readUint(string.concat(base, ".chainId"));
        }
        return 0;
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

    function _selectorString(uint256 chainId) internal view returns (string memory) {
        return vm.toString(_selectorOf(chainId));
    }

    function _entry(string memory chainId, string memory selector) internal view returns (string memory) {
        return string.concat(
            '{"to": "',
            vm.toString(orchestrator),
            '", "value": "0", "data": null, "contractMethod": {"inputs": [',
            '{"internalType": "uint256", "name": "chainId", "type": "uint256"},',
            '{"internalType": "uint64", "name": "ccipChainSelector", "type": "uint64"}',
            '], "name": "setChainSelector", "payable": false}, "contractInputsValues": {"chainId": "',
            chainId,
            '", "ccipChainSelector": "',
            selector,
            '"}}'
        );
    }

    function _batch(string memory chainId, string memory entries) internal view returns (string memory) {
        return string.concat(
            '{"version": "1.0", "chainId": "',
            chainId,
            '", "meta": {"createdFromSafeAddress": "',
            vm.toString(owner),
            '"}, "transactions": [',
            entries,
            "]}"
        );
    }

    function _manifest(string memory files) internal view returns (string memory) {
        return string.concat(
            '{"chain": "robinhood", "chainId": 4663, "ccipChainSelector": "6180753054346818345", "orchestrator": "',
            vm.toString(orchestrator),
            '", "files": [',
            files,
            "]}"
        );
    }
}

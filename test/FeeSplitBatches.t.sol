// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, Vm} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IkpkShares} from "src/IkpkShares.sol";
import {Split} from "src/interfaces/IPushSplit.sol";
import {IPushSplitFactory} from "src/interfaces/IPushSplitFactory.sol";

/// @title  FeeSplitBatchesTest
/// @notice Offline guard (no RPC) for the committed Crossbow fee-split batches in
///         script/safe-txs/fee-split-crossbow/. The batches are what three Safes will sign, and
///         nothing on-chain checks them before they land, so this pins each one to the manifest:
///         target, Safe, chain, value, and the exact calldata those parameters produce.
///
///         The files are numbered in execution order:
///         1. Governance Safe: `createSplitDeterministic` on the Splits v2.2 PushSplitFactory;
///         2. Security Council Safe: `schedule` of `setFeeReceiver(split)` on the shares timelock;
///         3. Governance Safe (any address may send it): `execute` of that same operation, after the delay.
///
///         The same batches are replayed against Robinhood Chain state in FeeSplitCrossbowFork.t.sol.
contract FeeSplitBatchesTest is Test {
    using stdJson for string;

    string internal constant DIR = "script/safe-txs/fee-split-crossbow";

    string internal manifest;
    address internal factory;
    address internal governance;
    address internal council;
    address internal timelock;
    address internal shares;
    address internal splitAddr;
    bytes32 internal feeReceiverSalt;
    uint256 internal delay;

    function setUp() public {
        manifest = vm.readFile(string.concat(DIR, "/manifest.json"));
        factory = manifest.readAddress(".splitsV2.pushSplitFactory");
        governance = manifest.readAddress(".safes.governance");
        council = manifest.readAddress(".safes.securityCouncil");
        timelock = manifest.readAddress(".feeReceiverOperation.timelock");
        shares = manifest.readAddress(".feeReceiverOperation.shares");
        splitAddr = manifest.readAddress(".split.predictedAddress");
        feeReceiverSalt = manifest.readBytes32(".feeReceiverOperation.salt");
        delay = manifest.readUint(".feeReceiverOperation.delaySeconds");
    }

    // ── Manifest ─────────────────────────────────────────────────────────────────────────────────

    /// @dev A lost or extra batch file must fail here, and so must a reordered list: the order is the
    ///      execution order.
    function test_manifestListsExactlyTheFilesPresent() public view {
        string[] memory listed = manifest.readStringArray(".files");
        assertEq(listed.length, 3, "expected exactly three batches");
        assertEq(listed[0], "1-governance-create-split.json");
        assertEq(listed[1], "2-council-schedule-fee-receiver.json");
        assertEq(listed[2], "3-execute-fee-receiver.json");

        Vm.DirEntry[] memory entries = vm.readDir(DIR);
        uint256 present;
        for (uint256 i = 0; i < entries.length; i++) {
            string memory name = _lastSegment(entries[i].path);
            if (_eq(name, "manifest.json")) continue;
            present++;
            bool found;
            for (uint256 j = 0; j < listed.length; j++) {
                if (_eq(listed[j], name)) found = true;
            }
            assertTrue(found, string.concat("file not in manifest: ", name));
        }
        assertEq(present, listed.length, "manifest lists a file that is missing");
    }

    function test_manifestSaltsAreTheHashOfTheirLabels() public view {
        assertEq(manifest.readBytes32(".split.salt"), keccak256(bytes(manifest.readString(".split.saltLabel"))));
        assertEq(feeReceiverSalt, keccak256(bytes(manifest.readString(".feeReceiverOperation.saltLabel"))));
    }

    // ── Batch 1: create the split ────────────────────────────────────────────────────────────────

    function test_batch1CreatesTheManifestSplitWithNoOwner() public view {
        string memory b = vm.readFile(string.concat(DIR, "/1-governance-create-split.json"));
        _assertEnvelope(b, governance, factory);

        Split memory s = _manifestSplit();
        uint256 sum;
        for (uint256 i = 0; i < s.allocations.length; i++) {
            sum += s.allocations[i];
        }
        assertEq(sum, s.totalAllocation, "allocations must sum to totalAllocation");
        assertEq(s.recipients.length, s.allocations.length, "recipients and allocations differ in length");
        assertEq(manifest.readAddress(".split.owner"), address(0), "the recorded instance has no owner");

        // The whole calldata, not just the arguments: a wrong selector or a stray byte fails too.
        this.assertCreateCalldata(_data(b));
    }

    /// @dev External so the negative control can `expectRevert` it.
    function assertCreateCalldata(bytes calldata data) external view {
        bytes memory expected = abi.encodeCall(
            IPushSplitFactory.createSplitDeterministic,
            (_manifestSplit(), address(0), governance, manifest.readBytes32(".split.salt"))
        );
        require(keccak256(data) == keccak256(expected), "batch 1 calldata does not match the manifest split");
    }

    // ── Batches 2 and 3: schedule and execute setFeeReceiver(split) ──────────────────────────────

    function test_batch2SchedulesSetFeeReceiverOnTheSharesTimelock() public view {
        string memory b = vm.readFile(string.concat(DIR, "/2-council-schedule-fee-receiver.json"));
        _assertEnvelope(b, council, timelock);
        assertEq(delay, 259200, "the shares timelock delay is 3 days");

        bytes memory expected = abi.encodeCall(
            TimelockController.schedule, (shares, 0, _setFeeReceiverData(), bytes32(0), feeReceiverSalt, delay)
        );
        assertEq(_data(b), expected, "batch 2 is not schedule(shares, 0, setFeeReceiver(split), 0, salt, delay)");
    }

    function test_batch3ExecutesTheSameOperation() public view {
        string memory b = vm.readFile(string.concat(DIR, "/3-execute-fee-receiver.json"));
        _assertEnvelope(b, governance, timelock);

        bytes memory expected =
            abi.encodeCall(TimelockController.execute, (shares, 0, _setFeeReceiverData(), bytes32(0), feeReceiverSalt));
        assertEq(_data(b), expected, "batch 3 is not execute of the operation batch 2 schedules");
    }

    /// @dev The operation id is what the timelock reports for batch 2's arguments (OpenZeppelin
    ///      `hashOperation`), so the id in the manifest is the one a reviewer can look up on-chain.
    function test_operationIdMatchesTheCalldata() public view {
        bytes32 id = keccak256(abi.encode(shares, uint256(0), _setFeeReceiverData(), bytes32(0), feeReceiverSalt));
        assertEq(
            id, manifest.readBytes32(".feeReceiverOperation.operationId"), "operation id drifted from the calldata"
        );
    }

    // ── Negative controls: the checks above must be able to fail ─────────────────────────────────

    function test_envelopeRejectsAnotherChain() public {
        string memory b = vm.readFile(string.concat(DIR, "/1-governance-create-split.json"));
        b = vm.replace(b, "\"chainId\": \"4663\"", "\"chainId\": \"1\"");
        vm.expectRevert(bytes("chainId is not Robinhood Chain (4663)"));
        this.assertEnvelope(b, governance, factory);
    }

    function test_envelopeRejectsAnotherSafe() public {
        string memory b = vm.readFile(string.concat(DIR, "/1-governance-create-split.json"));
        vm.expectRevert(bytes("batch is built for another Safe"));
        this.assertEnvelope(b, council, factory);
    }

    /// @dev A split whose first recipient has one more allocation unit is a different split at a
    ///      different address; the check must see it.
    function test_batch1CalldataCheckRejectsAChangedAllocation() public {
        Split memory s = _manifestSplit();
        s.allocations[0] = s.allocations[0] + 1;
        bytes memory tampered = abi.encodeCall(
            IPushSplitFactory.createSplitDeterministic, (s, address(0), governance, manifest.readBytes32(".split.salt"))
        );
        vm.expectRevert(bytes("batch 1 calldata does not match the manifest split"));
        this.assertCreateCalldata(tampered);
    }

    /// @dev A split that keeps an owner can be re-pointed and swept; the check must see it.
    function test_batch1CalldataCheckRejectsAnOwner() public {
        bytes memory tampered = abi.encodeCall(
            IPushSplitFactory.createSplitDeterministic,
            (_manifestSplit(), governance, governance, manifest.readBytes32(".split.salt"))
        );
        vm.expectRevert(bytes("batch 1 calldata does not match the manifest split"));
        this.assertCreateCalldata(tampered);
    }

    // ── Helpers ──────────────────────────────────────────────────────────────────────────────────

    function _setFeeReceiverData() internal view returns (bytes memory) {
        return abi.encodeCall(IkpkShares.setFeeReceiver, (splitAddr));
    }

    function _manifestSplit() internal view returns (Split memory s) {
        s.recipients = manifest.readAddressArray(".split.recipients");
        s.allocations = manifest.readUintArray(".split.allocations");
        s.totalAllocation = manifest.readUint(".split.totalAllocation");
        s.distributionIncentive = uint16(manifest.readUint(".split.distributionIncentive"));
    }

    function _assertEnvelope(string memory batch, address safe, address to) internal view {
        this.assertEnvelope(batch, safe, to);
    }

    /// @dev External so the negative controls can `expectRevert` it. One transaction, no native value,
    ///      built for the right chain and Safe, aimed at the right contract.
    function assertEnvelope(string memory batch, address safe, address to) external view {
        require(_eq(batch.readString(".chainId"), "4663"), "chainId is not Robinhood Chain (4663)");
        require(batch.readAddress(".meta.createdFromSafeAddress") == safe, "batch is built for another Safe");
        require(
            batch.keyExists(".transactions[0]") && !batch.keyExists(".transactions[1]"),
            "batch must hold exactly one transaction"
        );
        require(batch.readAddress(".transactions[0].to") == to, "batch targets the wrong contract");
        require(_eq(batch.readString(".transactions[0].value"), "0"), "batch must send no native value");
    }

    function _data(string memory batch) internal pure returns (bytes memory) {
        return batch.readBytes(".transactions[0].data");
    }

    function _lastSegment(string memory path) internal pure returns (string memory) {
        bytes memory p = bytes(path);
        uint256 i = p.length;
        while (i > 0 && p[i - 1] != "/") i--;
        bytes memory out = new bytes(p.length - i);
        for (uint256 j = 0; j < out.length; j++) {
            out[j] = p[i + j];
        }
        return string(out);
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}

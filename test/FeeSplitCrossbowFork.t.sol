// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IkpkShares} from "src/IkpkShares.sol";
import {IPushSplit, Split, Call} from "src/interfaces/IPushSplit.sol";
import {IPushSplitFactory} from "src/interfaces/IPushSplitFactory.sol";

/// @title  FeeSplitCrossbowForkTest
/// @notice Replays the three committed Crossbow batches (script/safe-txs/fee-split-crossbow/) against
///         Robinhood Chain (4663) state at a pinned block, from the Safes that will sign them, and
///         follows a real fee from `processRequests` to the recipients.
///
///         Needs chain state, which the offline guard (FeeSplitBatches.t.sol) lacks: that the canonical
///         0xSplits factory and implementation are what we think, that the split lands at the manifest
///         address, and that the fee path pays what docs/FEE_SPLIT.md says. Skipped when `RH_URL` is
///         unset, like DeployedKitSync. Run with
///         `RH_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-contract FeeSplitCrossbowForkTest`
///         (needs an archive node; the public RPC is one).
///
/// @dev    Pinned at block 120858887 (2026-11-22T19:47:19Z). At that block the split was not deployed,
///         xbUSDG `feeReceiver()` was the KPK fee Safe, the timelock operation was unscheduled and
///         xbUSDG `totalSupply()` was 0. That is the state the batches are written for, so the test
///         proves what executing them would do, not what they did. Nothing is sent to any chain.
contract FeeSplitCrossbowForkTest is Test {
    using stdJson for string;

    uint256 internal constant FORK_BLOCK = 120858887;
    string internal constant DIR = "script/safe-txs/fee-split-crossbow";

    // Splits v2.2 (0xSplits), canonical on Ethereum and 4663.
    address internal constant FACTORY = 0x8E8eB0cC6AE34A38B67D5Cf91ACa38f60bc3Ecf4;
    address internal constant IMPLEMENTATION = 0x1e2086A7e84a32482ac03000D56925F607CCB708;
    address internal constant WAREHOUSE = 0x8fb66F38cF86A3d5e8768f8F1754A24A6c661Fb8;
    bytes32 internal constant FACTORY_CODEHASH = 0x7289581fdbc21ec0b07d4f34c870a5548a03564691d6e24ef9c770134f8e95fb;
    bytes32 internal constant IMPLEMENTATION_CODEHASH_4663 =
        0xe2dfdf9b01f082ac22a1a4d91a2887eea93ffeaa6431ed262f8efcf4de1291f7;
    bytes32 internal constant WAREHOUSE_CODEHASH_4663 =
        0x816de1e108ecca3ab0a28b281c6e2443659ef372235d6a9bb72b101c784eebb1;

    // Crossbow USDG Liquidity fund (xbUSDG) on 4663.
    address internal constant SHARES = 0x622609130ae8fCe48c80EEc4DB95759a76737c03;
    address internal constant TIMELOCK = 0x4F96c1FE0Af339Ce11a9c621b73Bbd201d2f8109;
    address internal constant GOVERNANCE = 0x2F0d561B9a8CD981e6E73069592BDeA4e48A8bec;
    address internal constant COUNCIL = 0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537;
    address internal constant MANAGER = 0x74d7aFCf8d44ec6932afA4Cb4B6e2b799C1d4b84;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant KPK_FEE_SAFE = 0x9F230218cf7FDe6A9246e6f8CB0b888377E92639;
    address internal constant CROSSBOW = 0x8680f51Da765288EA163Cd971f0D535A41e37851;
    address internal constant PREDICTED_SPLIT = 0x581A8f9d85269f6Da997a9375b51752E564D1aeA;
    bytes32 internal constant SPLIT_SALT = 0x16cc1a8ad3b23e6995b5b9364d9b8559f81ef1b55c20ef26640e79290df83a9c;
    bytes32 internal constant OPERATION_ID = 0xf6e395b1b9138e3ac239fe1f6b5958c88629aca7f3d0de948f131dbc2dc85821;
    uint256 internal constant DELAY = 259200;

    string internal batch1;
    string internal batch2;
    string internal batch3;

    function setUp() public {
        try vm.envString("RH_URL") returns (string memory url) {
            vm.createSelectFork(url, FORK_BLOCK);
        } catch {
            vm.skip(true);
        }
        batch1 = vm.readFile(string.concat(DIR, "/1-governance-create-split.json"));
        batch2 = vm.readFile(string.concat(DIR, "/2-council-schedule-fee-receiver.json"));
        batch3 = vm.readFile(string.concat(DIR, "/3-execute-fee-receiver.json"));
    }

    // ── The canonical 0xSplits contracts are what the docs say ───────────────────────────────────

    function test_factoryAndImplementationAreTheCanonicalSplitsV22() public view {
        assertEq(FACTORY.codehash, FACTORY_CODEHASH, "factory codehash");
        assertEq(IPushSplitFactory(FACTORY).SPLIT_WALLET_IMPLEMENTATION(), IMPLEMENTATION, "implementation address");
        assertEq(IMPLEMENTATION.code.length, 10300, "implementation size");
        assertEq(IMPLEMENTATION.codehash, IMPLEMENTATION_CODEHASH_4663, "implementation codehash on 4663");
        assertEq(WAREHOUSE.code.length, 12146, "warehouse size");
        assertEq(WAREHOUSE.codehash, WAREHOUSE_CODEHASH_4663, "warehouse codehash on 4663");
    }

    function test_theBatchesStartFromTheRecordedState() public view {
        (address predicted, bool exists) = IPushSplitFactory(FACTORY).isDeployed(_split(), address(0), SPLIT_SALT);
        assertEq(predicted, PREDICTED_SPLIT, "predicted address");
        assertFalse(exists, "the split must not exist yet at the pinned block");
        assertEq(IkpkShares(SHARES).feeReceiver(), KPK_FEE_SAFE, "fee receiver before");
        assertEq(IERC20(SHARES).totalSupply(), 0, "xbUSDG supply before");
        assertEq(TimelockController(payable(TIMELOCK)).getTimestamp(OPERATION_ID), 0, "operation unscheduled");
        assertEq(TimelockController(payable(TIMELOCK)).getMinDelay(), DELAY, "shares timelock delay");
    }

    // ── Batch 1 ──────────────────────────────────────────────────────────────────────────────────

    function test_batch1CreatesTheSplitAtTheManifestAddressWithNoOwner() public {
        address split = _createSplit();
        assertEq(split, PREDICTED_SPLIT, "split address");
        assertGt(split.code.length, 0, "split has code");
        assertEq(IPushSplit(split).owner(), address(0), "owner");
        assertFalse(IPushSplit(split).paused(), "paused");
        assertEq(IPushSplit(split).splitHash(), keccak256(abi.encode(_split())), "split hash");
    }

    /// @dev `createSplitDeterministic` is permissionless and its address ignores the caller and
    ///      `creator`, so a stranger creating the split first gives the same address, and the
    ///      Governance Safe's batch then returns that address instead of reverting.
    function test_aThirdPartyCreatingTheSplitFirstChangesNothing() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        address first = IPushSplitFactory(FACTORY).createSplitDeterministic(_split(), address(0), stranger, SPLIT_SALT);
        assertEq(first, PREDICTED_SPLIT, "a stranger gets the same address");
        assertEq(IPushSplit(first).owner(), address(0), "owner is still zero");

        assertEq(_createSplit(), PREDICTED_SPLIT, "the Governance Safe's batch still succeeds");
        assertEq(IPushSplit(first).splitHash(), keccak256(abi.encode(_split())), "split unchanged");
    }

    /// @dev With no owner nobody is the owner: not even the Safe that created the split.
    function test_noAddressCanChangePauseOrSweepAnOwnerlessSplit() public {
        address split = _createSplit();
        Call[] memory calls = new Call[](1);
        calls[0] = Call({to: KPK_FEE_SAFE, value: 0, data: ""});
        address[3] memory callers = [GOVERNANCE, COUNCIL, makeAddr("anyone")];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.startPrank(callers[i]);
            vm.expectRevert(IPushSplit.Unauthorized.selector);
            IPushSplit(split).updateSplit(_split());
            vm.expectRevert(IPushSplit.Unauthorized.selector);
            IPushSplit(split).setPaused(true);
            vm.expectRevert(IPushSplit.Unauthorized.selector);
            IPushSplit(split).execCalls(calls);
            vm.stopPrank();
        }
    }

    // ── Batches 2 and 3 ──────────────────────────────────────────────────────────────────────────

    function test_onlyTheCouncilCanSchedule() public {
        address[3] memory others = [GOVERNANCE, MANAGER, makeAddr("anyone")];
        for (uint256 i = 0; i < others.length; i++) {
            vm.prank(others[i]);
            (bool ok,) = TIMELOCK.call(_data(batch2));
            assertFalse(ok, "only the Council may schedule");
        }
        vm.prank(COUNCIL);
        (bool scheduled,) = TIMELOCK.call(_data(batch2));
        assertTrue(scheduled, "the Council's batch 2 schedules");
        assertTrue(TimelockController(payable(TIMELOCK)).isOperationPending(OPERATION_ID), "operation pending");
    }

    function test_executeRevertsBeforeTheDelayAndWorksFromAnyAddressAfter() public {
        _createSplit();
        vm.prank(COUNCIL);
        (bool ok,) = TIMELOCK.call(_data(batch2));
        assertTrue(ok, "schedule");
        uint256 readyAt = TimelockController(payable(TIMELOCK)).getTimestamp(OPERATION_ID);
        assertEq(readyAt, block.timestamp + DELAY, "ready after exactly the delay");

        vm.warp(readyAt - 1);
        vm.prank(makeAddr("anyone"));
        (ok,) = TIMELOCK.call(_data(batch3));
        assertFalse(ok, "execute must revert before the delay");
        assertEq(IkpkShares(SHARES).feeReceiver(), KPK_FEE_SAFE, "fee receiver unchanged before the delay");

        vm.warp(readyAt);
        vm.prank(makeAddr("anyone"));
        (ok,) = TIMELOCK.call(_data(batch3));
        assertTrue(ok, "execute works from any address after the delay");
        assertTrue(TimelockController(payable(TIMELOCK)).isOperationDone(OPERATION_ID), "operation done");
        assertEq(IkpkShares(SHARES).feeReceiver(), PREDICTED_SPLIT, "fee receiver is the split");
    }

    // ── A real fee, end to end ───────────────────────────────────────────────────────────────────

    /// @dev Subscribe 1000 USDG, settle at 1.00 (seeds the watermark), settle at 1.10 seven days later
    ///      (the performance fee is minted to `feeReceiver`), then a third party distributes.
    function test_aRealFeeIsMintedToTheSplitAndPaidToBothRecipients() public {
        address split = _createSplit();
        vm.prank(COUNCIL);
        (bool ok,) = TIMELOCK.call(_data(batch2));
        assertTrue(ok, "schedule");
        vm.warp(block.timestamp + DELAY);
        vm.prank(makeAddr("anyone"));
        (ok,) = TIMELOCK.call(_data(batch3));
        assertTrue(ok, "execute");

        address lp = makeAddr("lp");
        deal(USDG, lp, 1000e6);
        vm.startPrank(lp);
        IERC20(USDG).approve(SHARES, 1000e6);
        uint256 id = IkpkShares(SHARES).requestSubscription(1000e6, 1, USDG, lp);
        vm.stopPrank();
        uint256[] memory approve = new uint256[](1);
        approve[0] = id;
        uint256[] memory none = new uint256[](0);
        vm.prank(MANAGER);
        IkpkShares(SHARES).processRequests(approve, none, USDG, 1e8);
        assertEq(IERC20(SHARES).balanceOf(split), 0, "no fee at the first settlement");

        vm.warp(block.timestamp + 7 days);
        vm.prank(MANAGER);
        IkpkShares(SHARES).processRequests(none, none, USDG, 1.1e8);

        uint256 fee = IERC20(SHARES).balanceOf(split);
        assertGt(fee, 0, "the fee was minted to the split");
        assertEq(IERC20(SHARES).balanceOf(KPK_FEE_SAFE), 0, "nothing was minted to the KPK fee Safe");

        address keeper = makeAddr("keeper");
        vm.prank(keeper);
        IPushSplit(split).distribute(_split(), SHARES, keeper);

        uint256 crossbow = IERC20(SHARES).balanceOf(CROSSBOW);
        uint256 kpk = IERC20(SHARES).balanceOf(KPK_FEE_SAFE);
        assertGt(crossbow, 0, "Crossbow was paid");
        assertEq(crossbow, kpk, "equal halves");
        assertEq(IERC20(SHARES).balanceOf(keeper), 0, "no incentive was configured");
        uint256 left = IERC20(SHARES).balanceOf(split);
        assertLe(left, 1, "at most 1 wei stays in the split");
        assertEq(crossbow + kpk + left, fee, "every share is accounted for");

        // Fund shares are ordinary shares: the recipient redeems them like any holder.
        vm.prank(CROSSBOW);
        uint256 requestId = IkpkShares(SHARES).requestRedemption(crossbow, 1, USDG, CROSSBOW);
        assertGt(requestId, 0, "Crossbow can request a redemption");
        assertEq(IERC20(SHARES).balanceOf(CROSSBOW), 0, "the shares moved into escrow");
    }

    // ── Helpers ──────────────────────────────────────────────────────────────────────────────────

    function _createSplit() internal returns (address split) {
        vm.prank(GOVERNANCE);
        (bool ok, bytes memory ret) = FACTORY.call(_data(batch1));
        assertTrue(ok, "batch 1 from the Governance Safe");
        split = abi.decode(ret, (address));
    }

    function _split() internal pure returns (Split memory s) {
        s.recipients = new address[](2);
        s.recipients[0] = CROSSBOW;
        s.recipients[1] = KPK_FEE_SAFE;
        s.allocations = new uint256[](2);
        s.allocations[0] = 500000;
        s.allocations[1] = 500000;
        s.totalAllocation = 1000000;
        s.distributionIncentive = 0;
    }

    function _data(string memory batch) internal pure returns (bytes memory) {
        return batch.readBytes(".transactions[0].data");
    }
}

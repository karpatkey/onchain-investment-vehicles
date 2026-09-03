// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {kpkSharesTestBase} from "test/kpkShares.TestBase.sol";
import {OPERATOR} from "test/constants.sol";
import {KpkSharesSettler} from "src/periphery/KpkSharesSettler.sol";
import {IkpkShares} from "src/IkpkShares.sol";

/// @notice Stand-in for a Manager Safe, laid out with the same first six storage slots as Safe v1.4.1
///         so the storage-safety test can prove the helper writes none of them.
contract MockManagerSafe {
    address internal singleton; // slot 0 — the real Safe's implementation pointer
    mapping(address => address) internal modules; // slot 1
    mapping(address => address) internal owners; // slot 2
    uint256 internal ownerCount; // slot 3
    uint256 internal threshold; // slot 4
    uint256 internal nonce; // slot 5

    constructor() {
        singleton = address(0xBEEF);
        ownerCount = 3;
        threshold = 2;
        nonce = 42;
    }

    /// @notice Mirrors `execTransactionFromModule(..., operation = 1)`.
    function execDelegateCall(address target, bytes calldata data) external returns (bool ok, bytes memory ret) {
        // solhint-disable-next-line avoid-low-level-calls
        (ok, ret) = target.delegatecall(data);
    }
}

/// @notice Stand-in for the manager Roles Modifier, whose avatar and target are both the Manager Safe
///         (`KpkOivFactory._wireManagerModifier`), so a scoped bot's call executes AS the Safe.
contract MockManagerRolesModifier {
    MockManagerSafe public immutable AVATAR;
    address public immutable BOT;

    error NotPermitted();

    constructor(MockManagerSafe avatar, address bot) {
        AVATAR = avatar;
        BOT = bot;
    }

    function execTransactionWithRole(address target, bytes calldata data) external returns (bool ok) {
        if (msg.sender != BOT) revert NotPermitted();
        (ok,) = AVATAR.execDelegateCall(target, data);
    }
}

/// @notice The stateless settlement helper: delegatecall-only, zero storage, zero privilege.
contract KpkSharesSettlerTest is kpkSharesTestBase {
    KpkSharesSettler internal settler;
    MockManagerSafe internal managerSafe;
    MockManagerRolesModifier internal rolesModifier;

    address internal bot = makeAddr("automationBot");

    uint256 internal constant MIN_PRICE = 0.5e8;
    uint256 internal constant MAX_PRICE = 2e8;
    uint16 internal constant MAX_DEVIATION_BPS = 500;

    function setUp() public virtual override {
        super.setUp();

        settler = new KpkSharesSettler();
        managerSafe = new MockManagerSafe();
        rolesModifier = new MockManagerRolesModifier(managerSafe, bot);

        // The Manager Safe is the fund's operator, exactly as the factory wires it in production.
        vm.prank(admin);
        kpkSharesContract.grantRole(OPERATOR, address(managerSafe));

        vm.label(address(settler), "KpkSharesSettler");
        vm.label(address(managerSafe), "ManagerSafe");
    }

    // ============================================================================
    // Execution model
    // ============================================================================

    function test_settle_revertsWhenCalledDirectly() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;

        vm.expectRevert(KpkSharesSettler.MustDelegateCall.selector);
        settler.settle(
            address(kpkSharesContract),
            address(usdc),
            SHARES_PRICE,
            MIN_PRICE,
            MAX_PRICE,
            MAX_DEVIATION_BPS,
            ids,
            new uint256[](0)
        );
    }

    /// @notice The full production path: bot -> Roles Modifier -> Manager Safe -> delegatecall -> fund.
    ///         Only the Safe holds OPERATOR, so a settlement landing proves `msg.sender` at the fund was
    ///         the Safe rather than the bot or the helper.
    function test_botSettlesThroughRolesModifierAsTheManagerSafe() public {
        uint256 requestId = _request(alice, _usdcAmount(1000), 1);

        uint256[] memory approve = new uint256[](1);
        approve[0] = requestId;

        vm.prank(bot);
        bool ok = rolesModifier.execTransactionWithRole(address(settler), _settleCalldata(approve, new uint256[](0)));

        assertTrue(ok, "delegatecall through the modifier must succeed");
        assertEq(
            uint8(kpkSharesContract.getRequest(requestId).requestStatus),
            uint8(IkpkShares.RequestStatus.PROCESSED),
            "request settled"
        );
        assertEq(kpkSharesContract.balanceOf(alice), _sharesAmount(1000), "shares minted to the investor");
    }

    /// @notice The investor stays the request's investor, so escrow and TTL cancellation rights are
    ///         untouched — the helper never inserts itself into custody.
    function test_investorRemainsTheRequestInvestor() public {
        uint256 requestId = _request(alice, _usdcAmount(100), 1);
        assertEq(kpkSharesContract.getRequest(requestId).investor, alice, "investor is the user, not the Safe");

        _settle(_ids(requestId), new uint256[](0));

        assertEq(usdc.balanceOf(address(settler)), 0, "helper holds nothing");
        assertEq(usdc.balanceOf(address(managerSafe)), 0, "Safe holds nothing");
    }

    /// @notice The helper confers no authority: a Safe without OPERATOR settles nothing.
    function test_settle_grantsNoPrivilegeToASafeWithoutOperator() public {
        MockManagerSafe outsider = new MockManagerSafe();
        uint256 requestId = _request(alice, _usdcAmount(100), 1);

        (bool ok, bytes memory ret) =
            outsider.execDelegateCall(address(settler), _settleCalldata(_ids(requestId), new uint256[](0)));
        assertTrue(ok, "the helper itself does not revert; the inner calls do");

        (uint256 settled, uint256 failed) = abi.decode(ret, (uint256, uint256));
        assertEq(settled, 0, "nothing settled without OPERATOR");
        assertEq(failed, 1, "the request was attempted and failed");
        assertEq(
            uint8(kpkSharesContract.getRequest(requestId).requestStatus),
            uint8(IkpkShares.RequestStatus.PENDING),
            "request untouched"
        );
    }

    // ============================================================================
    // Storage safety — the property that makes delegatecall survivable
    // ============================================================================

    /// @notice Under delegatecall every SSTORE would land in the Safe. Safe v1.4.1 keeps its singleton
    ///         pointer at slot 0 and modules/owners/ownerCount/threshold/nonce at slots 1-5, so a single
    ///         state variable in the helper would corrupt the multisig. This proves none are written.
    function test_settle_writesNoStorageInTheSafe() public {
        uint256 requestId = _request(alice, _usdcAmount(1000), 1);

        bytes32[6] memory before;
        for (uint256 i = 0; i < 6; i++) {
            before[i] = vm.load(address(managerSafe), bytes32(i));
        }

        _settle(_ids(requestId), new uint256[](0));

        for (uint256 i = 0; i < 6; i++) {
            assertEq(vm.load(address(managerSafe), bytes32(i)), before[i], "Safe storage slot was written");
        }

        // Slot 0 is the one that would brick the Safe outright.
        assertEq(uint256(before[0]), uint256(uint160(address(0xBEEF))), "singleton pointer intact");
    }

    function test_settle_writesNoStorageDuringIsolationPass() public {
        (uint256[] memory ids,) = _threeRequestsOneUnsatisfiable();

        bytes32[6] memory before;
        for (uint256 i = 0; i < 6; i++) {
            before[i] = vm.load(address(managerSafe), bytes32(i));
        }

        _settle(ids, new uint256[](0));

        for (uint256 i = 0; i < 6; i++) {
            assertEq(vm.load(address(managerSafe), bytes32(i)), before[i], "Safe storage slot was written");
        }
    }

    // ============================================================================
    // The point of the contract: one bad request must not brick the run
    // ============================================================================

    /// @notice `processRequests` reverts the WHOLE batch when any approved request's min-out is unmet
    ///         (`kpkShares.sol:776`). Confirms the failure this contract exists to contain is real.
    function test_directBatchRevertsEntirelyOnOneBadRequest() public {
        (uint256[] memory ids,) = _threeRequestsOneUnsatisfiable();

        vm.prank(ops);
        vm.expectRevert();
        kpkSharesContract.processRequests(ids, new uint256[](0), address(usdc), SHARES_PRICE);

        assertEq(kpkSharesContract.balanceOf(alice), 0, "nothing settled at all");
    }

    function test_settle_isolatesTheBadRequestAndSettlesTheRest() public {
        (uint256[] memory ids, uint256 badId) = _threeRequestsOneUnsatisfiable();

        (uint256 settled, uint256 failed) = _settle(ids, new uint256[](0));

        assertEq(settled, 2, "the two good requests settled");
        assertEq(failed, 1, "the bad one was skipped, not fatal");

        assertEq(kpkSharesContract.balanceOf(alice), _sharesAmount(1000), "alice settled");
        assertEq(kpkSharesContract.balanceOf(carol), _sharesAmount(1000), "carol settled");
        assertEq(kpkSharesContract.balanceOf(bob), 0, "bob's unsatisfiable request minted nothing");

        assertEq(
            uint8(kpkSharesContract.getRequest(badId).requestStatus),
            uint8(IkpkShares.RequestStatus.PENDING),
            "bad request left pending for the operator to revisit"
        );
    }

    function test_settle_happyPathUsesTheSingleBatchCall() public {
        uint256 a = _request(alice, _usdcAmount(100), 1);
        uint256 b = _request(bob, _usdcAmount(100), 1);

        uint256[] memory ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;

        (uint256 settled, uint256 failed) = _settle(ids, new uint256[](0));

        assertEq(settled, 2, "both settled");
        assertEq(failed, 0, "no fallback needed");
    }

    function test_settle_rejectsRequests() public {
        uint256 requestId = _request(alice, _usdcAmount(100), 1);
        uint256 balanceBefore = usdc.balanceOf(alice);

        (uint256 settled,) = _settle(new uint256[](0), _ids(requestId));

        assertEq(settled, 1, "rejection settled");
        assertEq(
            uint8(kpkSharesContract.getRequest(requestId).requestStatus),
            uint8(IkpkShares.RequestStatus.REJECTED),
            "request rejected"
        );
        assertEq(usdc.balanceOf(alice) - balanceBefore, _usdcAmount(100), "investor refunded directly");
    }

    // ============================================================================
    // Price guards — meaningful only because the Roles Modifier can pin them
    // ============================================================================

    function test_settle_revertsBelowMinPrice() public {
        uint256 requestId = _request(alice, _usdcAmount(100), 1);

        (bool ok, bytes memory ret) = managerSafe.execDelegateCall(
            address(settler),
            abi.encodeCall(
                KpkSharesSettler.settle,
                (
                    address(kpkSharesContract),
                    address(usdc),
                    MIN_PRICE - 1,
                    MIN_PRICE,
                    MAX_PRICE,
                    MAX_DEVIATION_BPS,
                    _ids(requestId),
                    new uint256[](0)
                )
            )
        );

        assertFalse(ok, "must revert");
        assertEq(bytes4(ret), KpkSharesSettler.PriceOutOfBounds.selector, "PriceOutOfBounds");
    }

    function test_settle_revertsAbovePriceCeiling() public {
        uint256 requestId = _request(alice, _usdcAmount(100), 1);

        (bool ok, bytes memory ret) = managerSafe.execDelegateCall(
            address(settler),
            abi.encodeCall(
                KpkSharesSettler.settle,
                (
                    address(kpkSharesContract),
                    address(usdc),
                    MAX_PRICE + 1,
                    MIN_PRICE,
                    MAX_PRICE,
                    MAX_DEVIATION_BPS,
                    _ids(requestId),
                    new uint256[](0)
                )
            )
        );

        assertFalse(ok, "must revert");
        assertEq(bytes4(ret), KpkSharesSettler.PriceOutOfBounds.selector, "PriceOutOfBounds");
    }

    function test_settle_revertsOutsideDeviationBand() public {
        // Establish an anchor at $1.
        uint256 first = _request(alice, _usdcAmount(10), 1);
        _settle(_ids(first), new uint256[](0));
        assertEq(kpkSharesContract.getLastSettledPrice(address(usdc)), SHARES_PRICE, "anchor set");

        uint256 second = _request(bob, _usdcAmount(10), 1);

        (bool ok, bytes memory ret) = managerSafe.execDelegateCall(
            address(settler),
            abi.encodeCall(
                KpkSharesSettler.settle,
                (
                    address(kpkSharesContract),
                    address(usdc),
                    1.06e8, // 600 bps, above the 500 allowed
                    MIN_PRICE,
                    MAX_PRICE,
                    MAX_DEVIATION_BPS,
                    _ids(second),
                    new uint256[](0)
                )
            )
        );

        assertFalse(ok, "must revert");
        assertEq(bytes4(ret), KpkSharesSettler.PriceDeviationTooLarge.selector, "PriceDeviationTooLarge");
    }

    function test_deviationBps_isZeroBeforeAnySettlement() public view {
        assertEq(settler.deviationBps(address(kpkSharesContract), address(usdc), 1.5e8), 0, "no anchor yet");
    }

    function test_deviationBps_matchesTheEnforcedBand() public {
        uint256 first = _request(alice, _usdcAmount(10), 1);
        _settle(_ids(first), new uint256[](0));

        assertEq(settler.deviationBps(address(kpkSharesContract), address(usdc), 1.03e8), 300, "3% = 300 bps");
    }

    function test_settle_revertsOnEmptyBatch() public {
        (bool ok, bytes memory ret) =
            managerSafe.execDelegateCall(address(settler), _settleCalldata(new uint256[](0), new uint256[](0)));

        assertFalse(ok, "must revert");
        assertEq(bytes4(ret), KpkSharesSettler.EmptyBatch.selector, "EmptyBatch");
    }

    function test_settle_revertsOnInvertedBounds() public {
        uint256 requestId = _request(alice, _usdcAmount(100), 1);

        (bool ok, bytes memory ret) = managerSafe.execDelegateCall(
            address(settler),
            abi.encodeCall(
                KpkSharesSettler.settle,
                (
                    address(kpkSharesContract),
                    address(usdc),
                    SHARES_PRICE,
                    MAX_PRICE,
                    MIN_PRICE, // inverted
                    MAX_DEVIATION_BPS,
                    _ids(requestId),
                    new uint256[](0)
                )
            )
        );

        assertFalse(ok, "must revert");
        assertEq(bytes4(ret), KpkSharesSettler.InvalidBounds.selector, "InvalidBounds");
    }

    // ============================================================================
    // Helpers
    // ============================================================================

    function _request(address who, uint256 assetsIn, uint256 minSharesOut) internal returns (uint256) {
        vm.prank(who);
        return kpkSharesContract.requestSubscription(assetsIn, minSharesOut, address(usdc), who);
    }

    function _ids(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _settleCalldata(uint256[] memory approve, uint256[] memory reject) internal view returns (bytes memory) {
        return abi.encodeCall(
            KpkSharesSettler.settle,
            (
                address(kpkSharesContract),
                address(usdc),
                SHARES_PRICE,
                MIN_PRICE,
                MAX_PRICE,
                MAX_DEVIATION_BPS,
                approve,
                reject
            )
        );
    }

    function _settle(uint256[] memory approve, uint256[] memory reject)
        internal
        returns (uint256 settled, uint256 failed)
    {
        (bool ok, bytes memory ret) = managerSafe.execDelegateCall(address(settler), _settleCalldata(approve, reject));
        require(ok, "settle reverted");

        return abi.decode(ret, (uint256, uint256));
    }

    /// @dev Three subscriptions where the middle one demands more shares than the price can deliver, so
    ///      a single batched `processRequests` reverts for everyone.
    function _threeRequestsOneUnsatisfiable() internal returns (uint256[] memory ids, uint256 badId) {
        uint256 good1 = _request(alice, _usdcAmount(1000), 1);
        badId = _request(bob, _usdcAmount(1000), _sharesAmount(5000)); // needs 5x what $1 delivers
        uint256 good2 = _request(carol, _usdcAmount(1000), 1);

        ids = new uint256[](3);
        ids[0] = good1;
        ids[1] = badId;
        ids[2] = good2;
    }
}

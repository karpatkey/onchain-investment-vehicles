// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IkpkShares} from "../IkpkShares.sol";

/// @title  KpkSharesSettler
/// @author kpk
/// @notice Stateless settlement helper for `KpkShares` funds, executed by **delegatecall from a fund's
///         Manager Safe**. Settles a batch of requests and, if the batch reverts, retries them one at a
///         time so a single bad request cannot brick an operator's whole settlement run.
///
/// @dev    ## Execution model
///
///         This contract is never called directly and holds no role on any fund. The Manager Safe —
///         which already holds `OPERATOR` — delegatecalls it, so `msg.sender` at `KpkShares` is the
///         Manager Safe itself. Automations reach it the same way: a bot with a scoped role on the
///         manager Roles Modifier calls `execTransactionWithRole`, and because that modifier's avatar
///         and target are both the Manager Safe (`KpkOivFactory._wireManagerModifier`), the call
///         arrives as the Safe.
///
///         Consequences, all deliberate:
///
///         - **It grants no new authority.** Anything this contract can do, the Manager Safe could
///           already do by calling `processRequests` directly. It is a convenience and a guard rail,
///           never a privilege boundary.
///         - **No role grant is needed on any fund**, so it works for any fund with no registration, no
///           Security Council transaction, and no cross-fund blast radius — a fund that never
///           delegatecalls here cannot be affected by a bug here.
///         - **It never moves user funds.** Investors create their own requests through
///           `KpkShares.requestSubscription` / `requestRedemption`, which keeps `investor` set to the
///           real user, preserves their escrow and TTL cancellation rights, and means no user ever
///           grants an allowance to anything for this flow.
///
///         ## Why it must be stateless
///
///         Under delegatecall every `SSTORE` writes to the **Manager Safe's** storage. Safe v1.4.1 keeps
///         its singleton pointer at slot 0 and its modules, owners, ownerCount, threshold and nonce at
///         slots 1-5, so a single state variable here would corrupt the multisig. This contract
///         therefore declares **no storage whatsoever** — only `immutable`, which lives in bytecode.
///         Any future change that adds a state variable is a critical bug, not a feature.
///
///         For the same reason there is deliberately no pause, no config, no replay protection and no
///         access control in this contract: all of them need storage, and none of them are needed once
///         the caller is already the fund's operator.
///
///         ## Where the numeric guards live
///
///         `minPrice`, `maxPrice` and `maxDeviationBps` arrive as calldata rather than stored config.
///         That is not a weakness to be apologised for — it is what lets the **Roles Modifier** pin
///         them. Scope the bot's role so those three parameters are fixed, and a compromised automation
///         cannot widen its own bounds. The limit then lives in the permission layer, which is the
///         right place for it and needs no storage.
///
///         ## Delegatecall discipline
///
///         A delegatecall target runs with the Safe's full authority. This contract therefore exposes
///         **no arbitrary-call surface**, is immutable and non-upgradeable, and touches nothing but the
///         `KpkShares` fund named in its arguments. The Roles grant must be scoped to
///         `(target = this, selector = settle, operation = delegatecall)` and no wider: a delegatecall
///         permission with loose calldata scoping is equivalent to handing the bot the Safe.
contract KpkSharesSettler {
    //
    // Errors
    //

    /// @notice Thrown when the contract is called directly instead of delegatecalled.
    /// @dev    Called directly it would run in its own context with no operator role and no authority,
    ///         so this is a guard against misconfiguration rather than a security boundary.
    error MustDelegateCall();

    /// @notice Thrown when a zero address is supplied for the fund or asset.
    error ZeroAddress();

    /// @notice Thrown when nothing was passed to settle.
    error EmptyBatch();

    /// @notice Thrown when the price falls outside the absolute bounds supplied by the caller.
    /// @dev    Pin `minPrice`/`maxPrice` in the Roles scoping to make this a real constraint on a bot.
    error PriceOutOfBounds(uint256 sharesPrice, uint256 minPrice, uint256 maxPrice);

    /// @notice Thrown when the price deviates from the fund's last settled price by more than allowed.
    error PriceDeviationTooLarge(uint256 sharesPrice, uint256 lastSettled, uint16 maxDeviationBps);

    /// @notice Thrown when the caller-supplied bounds are themselves nonsensical.
    error InvalidBounds();

    //
    // Events
    //

    /// @notice Emitted when the whole batch settled in one `processRequests` call.
    /// @dev    Emitted from the Manager Safe's context, so the log's `address` is the Safe — which is
    ///         the correct attribution for who settled.
    event BatchSettled(
        address indexed fund, address indexed asset, uint256 sharesPrice, uint256 approved, uint256 rejected
    );

    /// @notice Emitted when the batch reverted and the helper fell back to settling one at a time.
    event BatchFellBackToIsolation(address indexed fund, address indexed asset, bytes reason);

    /// @notice Emitted for each request settled individually during the isolation pass.
    event RequestSettled(address indexed fund, uint256 indexed requestId, bool approved);

    /// @notice Emitted for each request that failed during the isolation pass and was skipped.
    /// @dev    This is the point of the contract: the failure is recorded and the run continues, rather
    ///         than one investor's stale bound reverting every other settlement in the batch.
    event RequestFailed(address indexed fund, uint256 indexed requestId, bool approved, bytes reason);

    /// @notice Emitted at the end of an isolation pass with the tally.
    event IsolationComplete(address indexed fund, address indexed asset, uint256 settled, uint256 failed);

    //
    // Immutables
    //

    /// @dev This contract's own address, captured at construction. Immutables are baked into bytecode
    ///      rather than storage, so reading this under delegatecall is safe and yields the helper's
    ///      address while `address(this)` yields the Safe's.
    address private immutable _SELF;

    uint256 private constant _PRECISION_BPS = 10_000;

    constructor() {
        _SELF = address(this);
    }

    /// @dev Reverts unless we are executing inside someone else's context.
    modifier onlyDelegateCall() {
        if (address(this) == _SELF) revert MustDelegateCall();
        _;
    }

    //
    // Settlement
    //

    /// @notice Settles a batch of requests for one fund and asset, falling back to per-request
    ///         isolation if the batch reverts.
    ///
    /// @dev    `KpkShares.processRequests` fails the **entire** batch if any single approved request's
    ///         min-out is unmet (`kpkShares.sol:856` / `:776`) or if the payout transfer from the
    ///         portfolio Safe reverts (`:867`). One investor whose bound went stale can therefore brick
    ///         an operator's whole settlement run. This tries the cheap batched path first and only pays
    ///         the per-request gas premium when something actually fails.
    ///
    ///         Re-running `processRequests` once per request is safe: the conversion math depends only
    ///         on `(amount, price, decimals)` and never reads `totalSupply`, the fee charge is gated on
    ///         the fund's own six-hour timer so only the first call in the pass can charge, and
    ///         `_lastSettledPrice` is idempotent when the same price is passed each time.
    ///
    /// @param fund             The `KpkShares` proxy to settle against. The Safe delegatecalling this
    ///                         must hold `OPERATOR` on it, or the inner call reverts.
    /// @param asset            Asset the batch is denominated in. `processRequests` silently skips
    ///                         requests naming a different asset, so this must match.
    /// @param sharesPrice      Price per share, 8-decimal normalised USD.
    /// @param minPrice         Absolute lower bound on `sharesPrice`. Pin this in the Roles scoping.
    /// @param maxPrice         Absolute upper bound on `sharesPrice`. Pin this in the Roles scoping.
    /// @param maxDeviationBps  Maximum deviation from the fund's last settled price for this asset.
    ///                         Ignored when the fund has never settled this asset.
    /// @param approveRequests  Request ids to approve.
    /// @param rejectRequests   Request ids to reject.
    /// @return settled         Number of requests that ended up settled.
    /// @return failed          Number skipped because they reverted individually.
    function settle(
        address fund,
        address asset,
        uint256 sharesPrice,
        uint256 minPrice,
        uint256 maxPrice,
        uint16 maxDeviationBps,
        uint256[] calldata approveRequests,
        uint256[] calldata rejectRequests
    ) external onlyDelegateCall returns (uint256 settled, uint256 failed) {
        if (fund == address(0) || asset == address(0)) revert ZeroAddress();
        if (approveRequests.length == 0 && rejectRequests.length == 0) revert EmptyBatch();

        _checkPrice(fund, asset, sharesPrice, minPrice, maxPrice, maxDeviationBps);

        // Cheap path: one call for the whole batch, so the fee charge and the last-settled-price write
        // happen exactly once.
        try IkpkShares(fund).processRequests(approveRequests, rejectRequests, asset, sharesPrice) {
            emit BatchSettled(fund, asset, sharesPrice, approveRequests.length, rejectRequests.length);
            return (approveRequests.length + rejectRequests.length, 0);
        } catch (bytes memory reason) {
            emit BatchFellBackToIsolation(fund, asset, reason);
        }

        // Isolation pass: one request per call, so a single failure costs only that request.
        (uint256 a, uint256 af) = _settleEach(fund, asset, sharesPrice, approveRequests, true);
        (uint256 r, uint256 rf) = _settleEach(fund, asset, sharesPrice, rejectRequests, false);

        settled = a + r;
        failed = af + rf;

        emit IsolationComplete(fund, asset, settled, failed);
    }

    //
    // Views
    //

    /// @notice The deviation of `sharesPrice` from the fund's last settled price for `asset`, in bps.
    /// @dev    Returns zero when the fund has never settled this asset, matching how `settle` treats it.
    ///         Intended for the operator's pre-flight checks; safe to call directly.
    function deviationBps(address fund, address asset, uint256 sharesPrice) public view returns (uint256) {
        uint256 lastSettled = IkpkShares(fund).getLastSettledPrice(asset);
        if (lastSettled == 0) return 0;

        uint256 delta = sharesPrice > lastSettled ? sharesPrice - lastSettled : lastSettled - sharesPrice;
        return (delta * _PRECISION_BPS) / lastSettled;
    }

    /// @notice This contract's own address, for verifying a Roles grant points at the right target.
    function self() external view returns (address) {
        return _SELF;
    }

    //
    // Internal
    //

    /// @dev Validates the price against caller-supplied absolute bounds and the fund's own anchor.
    function _checkPrice(
        address fund,
        address asset,
        uint256 sharesPrice,
        uint256 minPrice,
        uint256 maxPrice,
        uint16 maxDeviationBps
    ) private view {
        if (minPrice == 0 || maxPrice < minPrice) revert InvalidBounds();
        if (sharesPrice < minPrice || sharesPrice > maxPrice) {
            revert PriceOutOfBounds(sharesPrice, minPrice, maxPrice);
        }

        uint256 lastSettled = IkpkShares(fund).getLastSettledPrice(asset);
        if (lastSettled == 0) return;

        uint256 delta = sharesPrice > lastSettled ? sharesPrice - lastSettled : lastSettled - sharesPrice;
        if ((delta * _PRECISION_BPS) / lastSettled > maxDeviationBps) {
            revert PriceDeviationTooLarge(sharesPrice, lastSettled, maxDeviationBps);
        }
    }

    /// @dev Settles `ids` one at a time, recording rather than propagating individual failures.
    function _settleEach(address fund, address asset, uint256 sharesPrice, uint256[] calldata ids, bool approve)
        private
        returns (uint256 settled, uint256 failed)
    {
        uint256[] memory one = new uint256[](1);
        uint256[] memory none = new uint256[](0);

        for (uint256 i = 0; i < ids.length; i++) {
            one[0] = ids[i];

            try IkpkShares(fund).processRequests(approve ? one : none, approve ? none : one, asset, sharesPrice) {
                settled++;
                emit RequestSettled(fund, ids[i], approve);
            } catch (bytes memory reason) {
                failed++;
                emit RequestFailed(fund, ids[i], approve, reason);
            }
        }
    }
}

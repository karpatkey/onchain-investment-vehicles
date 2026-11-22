// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice The parameters of a Splits v2 split: who is paid and in what proportion.
/// @dev    Same field order and types as the `Split` struct in the Splits v2 ABI, because the contract
///         identifies a split by `keccak256(abi.encode(split))`.
/// @param recipients            Payees. The factory's validation requires matching lengths with
///                              `allocations`; this interface does not re-check it.
/// @param allocations           One weight per recipient. Must sum to `totalAllocation`.
/// @param totalAllocation       Denominator of every recipient's share.
/// @param distributionIncentive Share of each distribution paid to the caller of `distribute`, in
///                              parts per 1e6 (1e6 = 100%). Zero pays the caller nothing.
struct Split {
    address[] recipients;
    uint256[] allocations;
    uint256 totalAllocation;
    uint16 distributionIncentive;
}

/// @notice One call executed by an owner-controlled split through `execCalls`.
/// @param to    Call target.
/// @param value Native value sent.
/// @param data  Calldata. Must be empty when `to` has no code.
struct Call {
    address to;
    uint256 value;
    bytes data;
}

/// @title  IPushSplit
/// @author KPK
/// @notice Minimal interface for a 0xSplits "PushSplit" (Splits v2.2): a clone that pays its recipients
///         directly when anyone calls `distribute`.
/// @dev    Credit: the contract behind this interface is 0xSplits' work, deployed and operated by
///         0xSplits (https://splits.org). Upstream:
///         https://github.com/0xSplits/splits-contracts-monorepo, package `packages/splits-v2`.
///         The files this interface was written against, at commit
///         23e9ef64c918205214fc23b2ff89fa590a32efc2:
///         - splitters/push/PushSplit.sol
///         - splitters/SplitWalletV2.sol
///         - utils/Wallet.sol, utils/Ownable.sol, utils/Pausable.sol
///         under https://github.com/0xSplits/splits-contracts-monorepo/blob/23e9ef64c918205214fc23b2ff89fa590a32efc2/packages/splits-v2/src/
///
///         License: upstream is GPL-3.0-or-later. THIS FILE IS AN INDEPENDENT INTERFACE, written from
///         the public ABI (function, event and error signatures and the `Split` struct layout). It
///         contains no upstream source, NatSpec, comments or tests, and imports none. This repository
///         deploys no 0xSplits code: it only calls the contracts 0xSplits already deployed. See the
///         "Attribution and license" section of docs/FEE_SPLIT.md.
///
///         Canonical deployment on Ethereum (1) and Robinhood Chain (4663): the PushSplit
///         implementation is 0x1e2086A7e84a32482ac03000D56925F607CCB708; each split is a clone of it
///         made by the PushSplitFactory (see IPushSplitFactory).
///
///         Only the functions this repository's tests and docs use are listed.
interface IPushSplit {
    /// @notice The caller is not allowed to run the function (owner-only, or no owner at all).
    error Unauthorized();

    /// @notice The `Split` passed in does not hash to the stored `splitHash`.
    error InvalidSplit();

    /// @notice The split is paused, so `distribute` is blocked.
    error Paused();

    /// @notice The split's owner, or the zero address for a split that can never be changed.
    /// @dev    Fixed at creation. With no owner, `updateSplit`, `setPaused`, `transferOwnership` and
    ///         `execCalls` are unreachable for every address.
    function owner() external view returns (address);

    /// @notice True while the owner has paused `distribute`.
    function paused() external view returns (bool);

    /// @notice `keccak256(abi.encode(split))` for the current recipients and allocations.
    function splitHash() external view returns (bytes32);

    /// @notice Pay out the whole balance of `token` held by the split, minus 1 wei, to the recipients.
    /// @dev    Callable by anyone. `split` must be the exact struct that hashes to `splitHash`. Each
    ///         recipient gets `amount * allocation / totalAllocation`; `distributor` gets
    ///         `amount * distributionIncentive / 1e6`. One failing transfer reverts the whole call.
    /// @param split       The current split parameters.
    /// @param token       ERC-20 to distribute.
    /// @param distributor Address that earns the distribution incentive.
    function distribute(Split calldata split, address token, address distributor) external;

    /// @notice Replace the recipients and allocations. Owner only.
    function updateSplit(Split calldata split) external;

    /// @notice Pause or unpause `distribute`. Owner only.
    function setPaused(bool paused) external;

    /// @notice Run arbitrary calls from the split, which lets the owner sweep its balances. Owner only.
    /// @return blockNumber Block of execution.
    /// @return returnData  Return data of each call.
    function execCalls(Call[] calldata calls) external payable returns (uint256 blockNumber, bytes[] memory returnData);
}

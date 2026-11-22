// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Split} from "./IPushSplit.sol";

/// @title  IPushSplitFactory
/// @author KPK
/// @notice Minimal interface for the 0xSplits PushSplitFactory (Splits v2.2), which makes PushSplit
///         clones at addresses fixed by (split parameters, owner, salt).
/// @dev    Credit: the factory behind this interface is 0xSplits' work, deployed and operated by
///         0xSplits (https://splits.org). Upstream:
///         https://github.com/0xSplits/splits-contracts-monorepo, package `packages/splits-v2`.
///         The files this interface was written against, at commit
///         23e9ef64c918205214fc23b2ff89fa590a32efc2:
///         - splitters/push/PushSplitFactory.sol
///         - splitters/SplitFactoryV2.sol
///         under https://github.com/0xSplits/splits-contracts-monorepo/blob/23e9ef64c918205214fc23b2ff89fa590a32efc2/packages/splits-v2/src/
///
///         License: upstream is GPL-3.0-or-later. THIS FILE IS AN INDEPENDENT INTERFACE, written from
///         the public ABI (function and event signatures and the `Split` struct layout). It contains no
///         upstream source, NatSpec, comments or tests, and imports none. This repository deploys no
///         0xSplits code: it only calls the contracts 0xSplits already deployed. See the "Attribution
///         and license" section of docs/FEE_SPLIT.md.
///
///         Canonical deployment, same address on Ethereum (1) and Robinhood Chain (4663):
///         PushSplitFactory v2.2 0x8E8eB0cC6AE34A38B67D5Cf91ACa38f60bc3Ecf4.
///
///         Only the functions this repository's tests and docs use are listed.
interface IPushSplitFactory {
    /// @notice Emitted when a split is created, with the parameters it was created from.
    /// @dev    `creator` is whatever the caller passed; it is not authenticated and does not affect the
    ///         address.
    event SplitCreated(address indexed split, Split splitParams, address owner, address creator, bytes32 salt);

    /// @notice The PushSplit implementation every split from this factory is a clone of.
    function SPLIT_WALLET_IMPLEMENTATION() external view returns (address);

    /// @notice Create the split at its deterministic address, or return it if it already exists.
    /// @dev    Callable by anyone. The address depends on `splitParams`, `owner` and `salt` only, not on
    ///         the caller or `creator`, so a split created first by a third party is the same split.
    /// @param splitParams Recipients, allocations, total and incentive.
    /// @param owner       Split owner, or the zero address for a split that can never be changed.
    /// @param creator     Recorded in the event only.
    /// @param salt        Free-form 32 bytes that tells otherwise identical splits apart.
    /// @return split      Address of the split.
    function createSplitDeterministic(Split calldata splitParams, address owner, address creator, bytes32 salt)
        external
        returns (address split);

    /// @notice Address `createSplitDeterministic` would use for these arguments.
    function predictDeterministicAddress(Split calldata splitParams, address owner, bytes32 salt)
        external
        view
        returns (address);

    /// @notice The predicted address and whether it already has code.
    function isDeployed(Split calldata splitParams, address owner, bytes32 salt)
        external
        view
        returns (address split, bool exists);
}

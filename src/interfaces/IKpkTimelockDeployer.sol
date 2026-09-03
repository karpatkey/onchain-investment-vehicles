// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Effective configuration of a `TimelockController` deployed by `KpkTimelockDeployer`.
/// @dev    Declared in its own file so `KpkOivFactory` can reference the struct without importing
///         `KpkTimelockDeployer` (which imports `TimelockController` and would pull its creation
///         bytecode into the factory's runtime, exceeding EIP-170). Same rationale as the local
///         `IKpkSharesDeployer` interface in `KpkOivFactory.sol`.
///
///         `executors` and `admin` are absent by design: the deployer forces open execution and
///         self-administration respectively, and neither is caller-controllable.
struct TimelockParams {
    /// @notice Minimum delay, in seconds, between scheduling and executing an operation.
    ///
    ///         **Zero means "no timelock".** `KpkOivFactory` treats a zero delay as "do not deploy
    ///         one for this fund" and leaves the corresponding authority with its plain owner/admin.
    ///         Any non-zero value must lie within the deployer's `[MIN_DELAY_FLOOR, MIN_DELAY_CAP]`
    ///         band, so zero can never be confused with a real configuration.
    ///
    ///         Size it to the slowest canceller's worst-case reaction time: a canceller cannot block
    ///         an operation it did not see inside the window.
    uint256 minDelay;
    /// @notice Addresses receiving `PROPOSER_ROLE`. OpenZeppelin also grants each of these
    ///         `CANCELLER_ROLE`. Entries must be non-zero and distinct.
    address[] proposers;
    /// @notice Addresses receiving `CANCELLER_ROLE` (the veto) without receiving proposal rights.
    ///         Entries must be non-zero, distinct, and absent from `proposers` — OpenZeppelin already
    ///         grants every proposer `CANCELLER_ROLE`, so listing one here would be a no-op grant that
    ///         still changed the salt, yielding two different addresses for one effective role set.
    address[] cancellers;
}

/// @notice Minimal view of `KpkTimelockDeployer` used by `KpkOivFactory`.
interface IKpkTimelockDeployer {
    /// @notice Deploys (or returns the existing) timelock intended to own `execRolesModifier`.
    function deployExecTimelock(address execRolesModifier, TimelockParams calldata params)
        external
        returns (address);

    /// @notice Deploys (or returns the existing) timelock intended to hold `DEFAULT_ADMIN_ROLE`
    ///         on `sharesProxy`.
    function deploySharesTimelock(address sharesProxy, TimelockParams calldata params)
        external
        returns (address);

    /// @notice Returns the address `deployExecTimelock` would produce.
    function predictExecTimelock(address execRolesModifier, TimelockParams calldata params)
        external
        view
        returns (address);

    /// @notice Returns the address `deploySharesTimelock` would produce.
    function predictSharesTimelock(address sharesProxy, TimelockParams calldata params)
        external
        view
        returns (address);
}

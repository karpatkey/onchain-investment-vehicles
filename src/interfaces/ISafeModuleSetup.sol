// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title  ISafeModuleSetup
/// @author KPK
/// @notice Delegatecall target used in Safe's setup() to enable modules during initialization.
/// @dev    Deployed at a deterministic address by Safe as part of their v1.4.1 contracts.
///         KpkOivFactory encodes a delegatecall to `enableModules` inside the Safe
///         `setup()` initializer so that modules are pre-enabled at proxy creation time,
///         avoiding the need for a post-deployment owner transaction.
interface ISafeModuleSetup {
    /// @notice Enables a list of modules on the Safe being initialized.
    /// @dev    Must be called via delegatecall from within Safe.setup(); calling it directly
    ///         has no effect because it writes to `msg.sender`'s (i.e. the Safe's) storage.
    ///         The modules are inserted into the linked list in reverse order:
    ///         `enableModules([A, B])` results in SENTINEL → B → A → SENTINEL.
    /// @param modules  Ordered list of module addresses to enable. Must be non-empty.
    function enableModules(address[] calldata modules) external;
}

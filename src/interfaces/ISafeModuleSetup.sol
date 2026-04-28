// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Delegatecall target used in Safe's setup() to enable modules during initialization.
///         Deployed at a deterministic address by Safe as part of their v1.4.1 contracts.
interface ISafeModuleSetup {
    function enableModules(address[] calldata modules) external;
}

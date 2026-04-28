// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Minimal contract with no logic, deployed at the same address on every chain via
///         CREATE2. Used as the sole signer of Avatar Safes so no EOA or multisig can execute
///         transactions directly on the Safe — all execution must go through the Roles Modifiers.
contract Empty {}

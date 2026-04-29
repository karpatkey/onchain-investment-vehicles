// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title  IRoles
/// @notice Minimal interface for the Zodiac Roles Modifier v2.
/// @dev    Only the functions used by KpkSharesFactory (and its tests) are included.
///         setUp encodes (address owner, address avatar, address target).
///         enableModule requires msg.sender == avatar.
///         All other configuration functions require msg.sender == owner.
interface IRoles {
    /// @notice One-time initializer called by ModuleProxyFactory after proxy creation.
    /// @param initParams ABI-encoded (address owner, address avatar, address target).
    function setUp(bytes memory initParams) external;

    /// @notice Returns the avatar address — the Safe whose assets the modifier guards.
    function avatar() external view returns (address);

    /// @notice Returns the target address — the contract that executions are forwarded to.
    /// @dev    Usually equals avatar. For nested modifiers, this is the parent modifier.
    function target() external view returns (address);

    /// @notice Updates the avatar address.
    /// @dev    Callable only by the current owner.
    /// @param _avatar New avatar address.
    function setAvatar(address _avatar) external;

    /// @notice Updates the target address.
    /// @dev    Callable only by the current owner.
    /// @param _target New target address.
    function setTarget(address _target) external;

    /// @notice Returns the current owner of this Roles Modifier.
    function owner() external view returns (address);

    /// @notice Transfers ownership to `newOwner`.
    /// @dev    Callable only by the current owner.
    /// @param newOwner Address that will become the new owner.
    function transferOwnership(address newOwner) external;

    /// @notice Assigns or revokes roles for `module`.
    /// @dev    Callable only by the current owner.
    ///         `roleKeys` and `memberOf` must have the same length.
    /// @param module    Address whose role membership is being updated.
    /// @param roleKeys  Array of role identifiers.
    /// @param memberOf  Parallel array: true to grant, false to revoke.
    function assignRoles(address module, bytes32[] calldata roleKeys, bool[] calldata memberOf) external;

    /// @notice Sets the default role for `module`.
    /// @dev    Callable only by the current owner. The default role is used when
    ///         execTransactionWithRole is called without specifying a role.
    /// @param module   Address whose default role is being set.
    /// @param roleKey  Role to assign as the default.
    function setDefaultRole(address module, bytes32 roleKey) external;

    /// @notice Enables this modifier as a module on the avatar Safe.
    /// @dev    Callable only by the avatar (i.e. the Safe itself, or an enabled module of it).
    /// @param module Address to enable as a module.
    function enableModule(address module) external;

    /// @notice Returns whether `module` is enabled on this Roles Modifier.
    /// @param module Address to check.
    /// @return       True if the module is enabled.
    function isModuleEnabled(address module) external view returns (bool);

    /// @notice Marks `targetAddress` as a scoped target for `roleKey`.
    /// @dev    Callable only by the current owner. Functions must be allowed via
    ///         allowFunction before they can be called by role holders.
    /// @param roleKey       Role to configure.
    /// @param targetAddress Contract address to scope.
    function scopeTarget(bytes32 roleKey, address targetAddress) external;

    /// @notice Allows `selector` on `targetAddress` for `roleKey`.
    /// @dev    Callable only by the current owner.
    ///         `options` controls additional execution constraints (e.g. value allowed).
    /// @param roleKey       Role to configure.
    /// @param targetAddress Contract address where the function lives.
    /// @param selector      4-byte function selector to allow.
    /// @param options       Execution options bitmask (0 = none, 1 = send, 2 = delegatecall, 3 = both).
    function allowFunction(bytes32 roleKey, address targetAddress, bytes4 selector, uint8 options) external;

    /// @notice Executes a transaction through the modifier if the caller holds `roleKey`.
    /// @dev    Forwards the call to target if all role checks pass.
    ///         If `shouldRevert` is true the call reverts on inner failure; otherwise it returns false.
    /// @param to           Destination address.
    /// @param value        ETH value to forward.
    /// @param data         Calldata to send.
    /// @param operation    0 = CALL, 1 = DELEGATECALL.
    /// @param roleKey      Role the caller must hold.
    /// @param shouldRevert Whether to revert on failure rather than returning false.
    /// @return success     Whether the inner execution succeeded.
    function execTransactionWithRole(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        bytes32 roleKey,
        bool shouldRevert
    ) external returns (bool success);
}

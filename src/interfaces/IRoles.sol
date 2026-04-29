// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Minimal interface for Zodiac Roles Modifier v2.
///         setUp encodes (address owner, address avatar, address target).
///         enableModule requires msg.sender == avatar.
///         All other configuration functions require msg.sender == owner.
interface IRoles {
    function setUp(bytes memory initParams) external;

    function avatar() external view returns (address);

    function target() external view returns (address);

    function setAvatar(address _avatar) external;

    function setTarget(address _target) external;

    function owner() external view returns (address);

    function transferOwnership(address newOwner) external;

    function assignRoles(address module, bytes32[] calldata roleKeys, bool[] calldata memberOf) external;

    function setDefaultRole(address module, bytes32 roleKey) external;

    /// @notice Requires msg.sender == avatar
    function enableModule(address module) external;

    function isModuleEnabled(address module) external view returns (bool);

    function scopeTarget(bytes32 roleKey, address targetAddress) external;

    function allowFunction(bytes32 roleKey, address targetAddress, bytes4 selector, uint8 options) external;

    function execTransactionWithRole(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        bytes32 roleKey,
        bool shouldRevert
    ) external returns (bool success);
}

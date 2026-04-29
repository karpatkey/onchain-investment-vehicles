// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title  ISafe
/// @author KPK
/// @notice Minimal interface for a Gnosis Safe proxy (v1.4.1).
/// @dev    Only the functions used by KpkOivFactory are included.
interface ISafe {
    /// @notice One-time initializer called by SafeProxyFactory immediately after proxy creation.
    /// @dev    Must be called exactly once. `to` and `data` form an optional delegatecall
    ///         executed during setup (e.g. SafeModuleSetup.enableModules).
    /// @param _owners          Initial set of owner accounts.
    /// @param _threshold       Number of owner signatures required to execute a transaction.
    /// @param to               Delegatecall target executed during setup, or address(0) to skip.
    /// @param data             Calldata for the delegatecall, or empty bytes to skip.
    /// @param fallbackHandler  Contract to handle ERC-165 / ERC-1271 fallback calls.
    /// @param paymentToken     Token used to reimburse the relayer, or address(0) for ETH.
    /// @param payment          Amount paid to the relayer, or 0 for none.
    /// @param paymentReceiver  Recipient of the relayer payment, or address(0) for msg.sender.
    function setup(
        address[] calldata _owners,
        uint256 _threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;

    /// @notice Returns whether `module` is currently enabled on this Safe.
    /// @param module  Address to check.
    /// @return        True if the module is in the enabled-modules linked list.
    function isModuleEnabled(address module) external view returns (bool);

    /// @notice Returns the current list of Safe owner addresses.
    function getOwners() external view returns (address[] memory);

    /// @notice Returns the current signature threshold.
    function getThreshold() external view returns (uint256);

    /// @notice Executes a call or delegatecall on behalf of this Safe without collecting signatures.
    /// @dev    Callable only by an enabled module.
    ///         `operation` 0 = CALL, 1 = DELEGATECALL.
    /// @param to        Destination address.
    /// @param value     ETH value to forward.
    /// @param data      Calldata to send.
    /// @param operation Operation type (0 = CALL, 1 = DELEGATECALL).
    /// @return success  Whether the inner call succeeded.
    function execTransactionFromModule(address to, uint256 value, bytes memory data, uint8 operation)
        external
        returns (bool success);

    /// @notice Removes `module` from the enabled-modules linked list.
    /// @dev    Callable only by the Safe itself (i.e. via an executed Safe transaction or module).
    ///         `prevModule` must be the entry that points to `module` in the linked list.
    ///         Pass `SENTINEL_MODULES` (0x0000...0001) as `prevModule` when `module` is the head.
    /// @param prevModule  The module that precedes `module` in the linked list.
    /// @param module      The module to disable.
    function disableModule(address prevModule, address module) external;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title  ISafeProxyFactory
/// @author KPK
/// @notice Minimal interface for the Gnosis SafeProxyFactory (v1.4.1).
/// @dev    Only the function used by KpkOivFactory is included.
interface ISafeProxyFactory {
    /// @notice Deploys a new Safe proxy that delegates to `_singleton` and executes the
    ///         provided `initializer` on the newly created proxy immediately after creation.
    /// @dev    CREATE2 salt = keccak256(abi.encodePacked(keccak256(initializer), saltNonce)).
    ///         The same `_singleton`, `initializer`, and `saltNonce` combination will always
    ///         produce the same proxy address on a given factory/chain.
    /// @param _singleton  The Safe implementation (singleton) the proxy delegates to.
    /// @param initializer ABI-encoded `ISafe.setup(...)` call executed on the new proxy.
    /// @param saltNonce   Unique nonce mixed into the CREATE2 salt for address derivation.
    /// @return proxy      Address of the newly deployed Safe proxy.
    function createProxyWithNonce(address _singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

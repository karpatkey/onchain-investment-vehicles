// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title  IModuleProxyFactory
/// @notice Minimal interface for the Zodiac ModuleProxyFactory.
/// @dev    Deploys EIP-1167 minimal proxies for Zodiac modules (e.g. Roles Modifier) via CREATE2.
///         Only the function used by KpkSharesFactory is included.
interface IModuleProxyFactory {
    /// @notice Deploys a new EIP-1167 minimal proxy pointing at `masterCopy` and calls
    ///         `masterCopy.setUp(initializer)` on the proxy immediately after creation.
    /// @dev    CREATE2 salt = keccak256(abi.encodePacked(keccak256(initializer), saltNonce)).
    ///         The same `masterCopy`, `initializer`, and `saltNonce` produce the same proxy
    ///         address on any chain, enabling deterministic cross-chain deployments.
    /// @param masterCopy  The Zodiac module implementation all proxies delegate to.
    /// @param initializer ABI-encoded `setUp(...)` call executed on the new proxy.
    /// @param saltNonce   Unique nonce mixed into the CREATE2 salt for address derivation.
    /// @return proxy      Address of the newly deployed module proxy.
    function deployModule(address masterCopy, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

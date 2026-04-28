// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Zodiac ModuleProxyFactory: deploys EIP-1167 minimal proxies for Zodiac modules via CREATE2.
///         CREATE2 salt = keccak256(abi.encodePacked(keccak256(initializer), saltNonce))
interface IModuleProxyFactory {
    function deployModule(address masterCopy, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

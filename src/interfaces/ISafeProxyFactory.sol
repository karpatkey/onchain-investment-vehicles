// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ISafeProxyFactory {
    function createProxyWithNonce(address _singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

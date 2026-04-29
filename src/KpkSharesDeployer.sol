// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {KpkShares} from "./kpkShares.sol";

/// @title  KpkSharesDeployer
/// @author KPK
/// @notice Standalone deployer for KpkShares implementations.
/// @dev    Lives in a separate contract so KpkOivFactory does not embed the
///         KpkShares creation bytecode in its own runtime, which would exceed the
///         EIP-170 24,576-byte limit.
///         KpkOivFactory calls deploy() once per fund to get a fresh, isolated
///         KpkShares implementation so upgrades are scoped per fund, not shared
///         across the entire protocol.
///
///         `deploy()` is restricted to a single authorised caller (the factory). This
///         prevents arbitrary callers from spawning uninitialised KpkShares
///         implementations and bloating chain state. The authorised caller is set
///         once in the constructor and is immutable thereafter — to point a factory
///         at a different deployer instance, deploy a new `KpkSharesDeployer` and
///         call `KpkOivFactory.setKpkSharesDeployer`.
contract KpkSharesDeployer {
    /// @notice Address authorised to call `deploy()`. Set once at construction; immutable.
    address public immutable factory;

    /// @notice Thrown when the constructor receives `address(0)` for the factory.
    error ZeroFactory();

    /// @notice Thrown when `deploy()` is called by any address other than `factory`.
    error UnauthorizedCaller();

    /// @param _factory The KpkOivFactory address that is permitted to call `deploy()`.
    ///                 Must not be zero. The factory address can be pre-computed via CREATE2
    ///                 and passed here before the factory itself is deployed, OR this
    ///                 deployer can be deployed in the same transaction as the factory and
    ///                 the factory's predicted address (e.g. from
    ///                 `vm.computeCreateAddress` / `keccak256(rlp(deployer, nonce))`)
    ///                 supplied here.
    constructor(address _factory) {
        if (_factory == address(0)) revert ZeroFactory();
        factory = _factory;
    }

    /// @notice Deploys a new KpkShares implementation contract.
    /// @dev    Each call produces an independent implementation instance.
    ///         No constructor arguments are required — KpkShares uses initializers
    ///         on the proxy side.
    ///         Restricted to `factory` to prevent arbitrary callers from spawning
    ///         uninitialised KpkShares implementations.
    /// @return impl Address of the freshly deployed KpkShares implementation.
    function deploy() external returns (address impl) {
        if (msg.sender != factory) revert UnauthorizedCaller();
        return address(new KpkShares());
    }
}

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

    /// @notice Deploys a new KpkShares implementation contract via CREATE2.
    /// @dev    Each call produces an independent implementation instance whose address is
    ///         deterministic from `(this deployer, salt, type(KpkShares).creationCode)`.
    ///         The factory threads a salt derived from `(caller, baseSalt, index)` so each OIV's
    ///         impl address is predictable in advance via `predictImpl`.
    ///         No constructor arguments are required — KpkShares uses initializers
    ///         on the proxy side.
    ///         Restricted to `factory` to prevent arbitrary callers from spawning
    ///         uninitialised KpkShares implementations.
    /// @param  salt CREATE2 salt; forwarded by the factory from its salt-derivation routine.
    /// @return impl Address of the freshly deployed KpkShares implementation.
    function deploy(bytes32 salt) external returns (address impl) {
        if (msg.sender != factory) revert UnauthorizedCaller();
        return address(new KpkShares{salt: salt}());
    }

    /// @notice Predicts the address `deploy(salt)` will produce on this chain.
    /// @dev    Pure CREATE2 calculation — does not check whether the address is already deployed.
    ///         Lives on this contract (not on the factory) so importers don't pull in
    ///         `type(KpkShares).creationCode` and exceed EIP-170 — same rationale as the
    ///         deployer's own existence.
    /// @param  salt CREATE2 salt the factory would pass to `deploy`.
    /// @return predicted The CREATE2 address `deploy(salt)` would write to.
    function predictImpl(bytes32 salt) external view returns (address predicted) {
        predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(type(KpkShares).creationCode))
                    )
                )
            )
        );
    }
}

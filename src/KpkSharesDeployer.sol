// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {KpkShares} from "./kpkShares.sol";

/// @title  KpkSharesDeployer
/// @author KPK
/// @notice Standalone deployer for KpkShares implementations.
/// @dev    Lives in a separate contract so KpkSharesFactory does not embed the
///         KpkShares creation bytecode in its own runtime, which would exceed the
///         EIP-170 24,576-byte limit.
///         KpkSharesFactory calls deploy() once per fund to get a fresh, isolated
///         KpkShares implementation so upgrades are scoped per fund, not shared
///         across the entire protocol.
contract KpkSharesDeployer {
    /// @notice Deploys a new KpkShares implementation contract.
    /// @dev    Each call produces an independent implementation instance.
    ///         No constructor arguments are required — KpkShares uses initializers
    ///         on the proxy side.
    /// @return impl Address of the freshly deployed KpkShares implementation.
    function deploy() external returns (address impl) {
        return address(new KpkShares());
    }
}

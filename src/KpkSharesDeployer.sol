// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {KpkShares} from "./kpkShares.sol";

/// @notice Standalone deployer for KpkShares implementations.
///         Lives in a separate contract so KpkSharesFactory does not embed the
///         KpkShares creation bytecode in its own runtime (which would exceed EIP-170).
///         KpkSharesFactory calls deploy() once per fund to get a fresh, isolated
///         implementation so upgrades are scoped per fund.
contract KpkSharesDeployer {
    function deploy() external returns (address) {
        return address(new KpkShares());
    }
}

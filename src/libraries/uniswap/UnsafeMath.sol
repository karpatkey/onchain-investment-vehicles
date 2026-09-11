// SPDX-License-Identifier: GPL-2.0-or-later
// Vendored from Uniswap/v3-core@6562c52e8f75f0c10f9deaf44861847585fc8129 (branch `0.8`), contracts/libraries/UnsafeMath.sol
// Changes: none (this provenance header only).
// Vendored instead of installed as a dependency: a new remapping changes solc metadata,
// which would shift this repo pinned CREATE2 addresses (see test/FactoryAddressSync.t.sol).
pragma solidity >=0.5.0;

/// @title Math functions that do not check inputs or outputs
/// @notice Contains methods that perform common math functions but do not do any overflow or underflow checks
library UnsafeMath {
    /// @notice Returns ceil(x / y)
    /// @dev division by 0 has unspecified behavior, and must be checked externally
    /// @param x The dividend
    /// @param y The divisor
    /// @return z The quotient, ceil(x / y)
    function divRoundingUp(uint256 x, uint256 y) internal pure returns (uint256 z) {
        assembly {
            z := add(div(x, y), gt(mod(x, y), 0))
        }
    }
}

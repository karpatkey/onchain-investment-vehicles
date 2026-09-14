// SPDX-License-Identifier: GPL-2.0-or-later
// Vendored from Uniswap/v3-core@6562c52e8f75f0c10f9deaf44861847585fc8129 (branch `0.8`), contracts/libraries/FixedPoint96.sol
// Changes: none (this provenance header only).
// Vendored instead of installed as a dependency: a new remapping changes solc metadata,
// which would shift this repo pinned CREATE2 addresses (see test/FactoryAddressSync.t.sol).
pragma solidity >=0.4.0;

/// @title FixedPoint96
/// @notice A library for handling binary fixed point numbers, see https://en.wikipedia.org/wiki/Q_(number_format)
/// @dev Used in SqrtPriceMath.sol
library FixedPoint96 {
    uint8 internal constant RESOLUTION = 96;
    uint256 internal constant Q96 = 0x1000000000000000000000000;
}

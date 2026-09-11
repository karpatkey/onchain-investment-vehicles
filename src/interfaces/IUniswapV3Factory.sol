// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title  IUniswapV3Factory
/// @author KPK
/// @notice Minimal interface for the Uniswap v3 factory.
/// @dev    Only the functions used by UniswapV3PositionVault are included. The vault resolves its
///         pool through this registry rather than by computing the CREATE2 address locally, because
///         the pool init-code hash is not identical on every chain that hosts a v3 deployment.
interface IUniswapV3Factory {
    /// @notice Returns the pool for the given token pair and fee tier, or address(0) if none exists.
    /// @dev    The token order does not matter; the factory sorts them internally.
    /// @param tokenA One of the two pool tokens.
    /// @param tokenB The other pool token.
    /// @param fee    The pool fee in hundredths of a basis point (e.g. 3000 for 0.3%).
    /// @return pool  The pool address, or address(0) when the pair and fee tier are not deployed.
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

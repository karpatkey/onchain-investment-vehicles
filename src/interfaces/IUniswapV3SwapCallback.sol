// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title  IUniswapV3SwapCallback
/// @author KPK
/// @notice Callback that IUniswapV3Pool.swap invokes on its caller to collect the input token.
/// @dev    Mirrors the upstream Uniswap v3 core interface of the same name. Implementers MUST verify
///         that msg.sender is the expected pool: the pool address is the only proof that the deltas
///         being reported are real, since anyone can call this function directly.
interface IUniswapV3SwapCallback {
    /// @notice Called by the pool after a swap so the caller can pay what it owes.
    /// @dev    Exactly one of the two deltas is positive (owed to the pool) and the other is
    ///         negative (paid out to the recipient). The implementation must transfer the positive
    ///         amount of that token to msg.sender before returning, or the swap reverts.
    /// @param amount0Delta Change in the pool's token0 balance; positive means the caller owes it.
    /// @param amount1Delta Change in the pool's token1 balance; positive means the caller owes it.
    /// @param data         Arbitrary payload forwarded verbatim from the swap call.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

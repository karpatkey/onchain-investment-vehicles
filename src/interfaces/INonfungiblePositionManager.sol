// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title  INonfungiblePositionManager
/// @author KPK
/// @notice Minimal interface for the Uniswap v3 NonfungiblePositionManager.
/// @dev    Only the functions used by UniswapV3PositionVault are included. Struct field order and
///         function signatures are copied verbatim from the upstream periphery interface so the ABI
///         encoding matches exactly; the upstream contract is compiled with solc 0.7.6 and cannot be
///         built from source here, so the vault talks to the deployed instance through this
///         hand-written interface.
interface INonfungiblePositionManager {
    /// @notice Parameters for minting a new position NFT.
    /// @param token0         The first pool token, sorted by address.
    /// @param token1         The second pool token, sorted by address.
    /// @param fee            The pool fee tier.
    /// @param tickLower      Lower tick boundary, a multiple of the pool's tick spacing.
    /// @param tickUpper      Upper tick boundary, a multiple of the pool's tick spacing.
    /// @param amount0Desired Maximum token0 the caller is willing to supply.
    /// @param amount1Desired Maximum token1 the caller is willing to supply.
    /// @param amount0Min     Minimum token0 that must be consumed, or the call reverts.
    /// @param amount1Min     Minimum token1 that must be consumed, or the call reverts.
    /// @param recipient      Address that receives the position NFT.
    /// @param deadline       Timestamp after which the call reverts.
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    /// @notice Parameters for adding liquidity to an existing position.
    /// @param tokenId        The position NFT id.
    /// @param amount0Desired Maximum token0 the caller is willing to supply.
    /// @param amount1Desired Maximum token1 the caller is willing to supply.
    /// @param amount0Min     Minimum token0 that must be consumed, or the call reverts.
    /// @param amount1Min     Minimum token1 that must be consumed, or the call reverts.
    /// @param deadline       Timestamp after which the call reverts.
    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    /// @notice Parameters for removing liquidity from an existing position.
    /// @dev    Removed principal is credited to the position's tokensOwed balances; a separate
    ///         collect call is required to move it out of the position manager.
    /// @param tokenId    The position NFT id.
    /// @param liquidity  Amount of liquidity to burn.
    /// @param amount0Min Minimum token0 that must be released, or the call reverts.
    /// @param amount1Min Minimum token1 that must be released, or the call reverts.
    /// @param deadline   Timestamp after which the call reverts.
    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    /// @notice Parameters for withdrawing owed tokens from a position.
    /// @dev    Owed tokens are the sum of accrued swap fees and any principal released by a prior
    ///         decreaseLiquidity call, so the maxima decide which of the two is withdrawn.
    /// @param tokenId    The position NFT id.
    /// @param recipient  Address that receives the tokens.
    /// @param amount0Max Upper bound on the token0 withdrawn.
    /// @param amount1Max Upper bound on the token1 withdrawn.
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    /// @notice The Uniswap v3 factory this position manager was deployed against.
    /// @return The factory address.
    function factory() external view returns (address);

    /// @notice Reads the full state of a position NFT.
    /// @param tokenId The position NFT id.
    /// @return nonce                    Permit nonce, unused by the vault.
    /// @return operator                 Approved operator, unused by the vault.
    /// @return token0                   The position's token0.
    /// @return token1                   The position's token1.
    /// @return fee                      The position's fee tier.
    /// @return tickLower                Lower tick boundary.
    /// @return tickUpper                Upper tick boundary.
    /// @return liquidity                Liquidity currently held by the position.
    /// @return feeGrowthInside0LastX128 Fee growth checkpoint for token0.
    /// @return feeGrowthInside1LastX128 Fee growth checkpoint for token1.
    /// @return tokensOwed0              Token0 currently withdrawable via collect.
    /// @return tokensOwed1              Token1 currently withdrawable via collect.
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    /// @notice Creates a new position NFT and supplies it with liquidity.
    /// @param params The mint parameters.
    /// @return tokenId   Id of the newly minted position NFT.
    /// @return liquidity Liquidity added to the position.
    /// @return amount0   Token0 actually consumed.
    /// @return amount1   Token1 actually consumed.
    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice Adds liquidity to an existing position.
    /// @param params The increase parameters.
    /// @return liquidity Liquidity added.
    /// @return amount0   Token0 actually consumed.
    /// @return amount1   Token1 actually consumed.
    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice Removes liquidity from an existing position, crediting the principal as owed tokens.
    /// @param params The decrease parameters.
    /// @return amount0 Token0 released into the position's owed balance.
    /// @return amount1 Token1 released into the position's owed balance.
    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    /// @notice Withdraws owed tokens from a position.
    /// @param params The collect parameters.
    /// @return amount0 Token0 transferred to the recipient.
    /// @return amount1 Token1 transferred to the recipient.
    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);

    /// @notice Burns a position NFT.
    /// @dev    Requires the position to hold no liquidity and no owed tokens.
    /// @param tokenId The position NFT id.
    function burn(uint256 tokenId) external payable;

    /// @notice Returns the owner of a position NFT.
    /// @param tokenId The position NFT id.
    /// @return The owner address.
    function ownerOf(uint256 tokenId) external view returns (address);
}

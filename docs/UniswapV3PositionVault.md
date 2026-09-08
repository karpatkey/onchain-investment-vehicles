# UniswapV3PositionVault

## Overview

`UniswapV3PositionVault` is an ERC-20 share token whose entire backing is a single Uniswap v3
liquidity position on a single pool. A **curator** opens, moves and closes that position. **Investors**
buy in at the position's own token ratio and redeem for a pro-rata slice of it, paid out in both
tokens. Fees earned by the position are compounded back into it rather than distributed.

The vault is deliberately narrow: one pool, one position at a time, no swaps except the one that a
rebalance needs, and no path by which the curator can move value out of the vault.

## Contract Architecture

### Inheritance chain

```
UniswapV3PositionVault
├── Initializable, UUPSUpgradeable        upgrade mechanism, admin-gated
├── AccessControlUpgradeable              ADMIN / CURATOR / INVESTOR roles
├── ERC20Upgradeable                      the share token
├── ReentrancyGuardUpgradeable            every state-changing entry point
├── IUniswapV3PositionVault               errors, events, structs
├── IUniswapV3SwapCallback                pays for the rebalance swap
├── IERC721Receiver                       rejects every NFT it did not mint
└── RecoverFunds                          sweeps stray tokens, never the pool's two
```

### Key components

| Component | Role |
|---|---|
| `src/UniswapV3PositionVault.sol` | State, roles, and every interaction with the pool and position manager. |
| `src/IUniswapV3PositionVault.sol` | The error, event and struct surface, declared once for callers. |
| `src/libraries/UniswapV3VaultMath.sol` | All pure math. Deployed as a linked library. |
| `src/libraries/uniswap/` | Uniswap's own libraries, vendored verbatim. |
| `src/interfaces/` | Minimal hand-written interfaces for the pool, factory and position manager. |

## Dependencies

### Vendored Uniswap libraries

`TickMath`, `SqrtPriceMath`, `LiquidityAmounts`, `FullMath`, `FixedPoint96`, `SafeCast` and
`UnsafeMath` are copied verbatim from the upstream `0.8` branches of `Uniswap/v3-core` and
`Uniswap/v3-periphery`. Each file records its source repository and commit in a header, and the
only edit is the import paths in `LiquidityAmounts`.

They are vendored rather than installed as a dependency because this repository leaves
`bytecode_hash` at its default. Every remapping therefore feeds into solc metadata, and adding one
would move the pinned CREATE2 addresses that `test/FactoryAddressSync.t.sol` guards. The vendored
directory is excluded from `forge fmt` so it stays byte-identical to upstream and can be diffed
against the pinned commit.

### External contracts

The Uniswap v3 `NonfungiblePositionManager` custodies the position NFT. The pool itself is resolved
at initialization through the position manager's own factory, never by computing a CREATE2 address,
because the pool init-code hash is not identical on every chain hosting a v3 deployment.

## Access Control and Authorities

### Role hierarchy

```
DEFAULT_ADMIN_ROLE
├── grants and revokes every role, including its own
├── sets the manipulation-guard configuration
├── sets the recipient of recovered tokens
└── authorises upgrades

CURATOR
└── opens, moves, tops up, trims and closes the position

INVESTOR
└── may hold, receive, buy and redeem shares
    (granting it to address(0) opens the vault to everyone)
```

### Permission matrix

| Function | ADMIN | CURATOR | INVESTOR | Public |
|---|:---:|:---:|:---:|:---:|
| `deposit` | | | ✅ | |
| `redeem` | | | ✅ | |
| `transfer` / `transferFrom` | | | ✅ | |
| `createPosition` | | ✅ | | |
| `rebalance` | | ✅ | | |
| `unwindPosition` | | ✅ | | |
| `addLiquidity` / `removeLiquidity` | | ✅ | | |
| `collectFees` | | ✅ | | |
| `setTwapConfig` | ✅ | | | |
| `setAssetRecoverer` | ✅ | | | |
| `upgradeToAndCall` | ✅ | | | |
| `grantRole` / `revokeRole` | ✅ | | | |
| `recoverAssets` | | | | ✅ |
| all view functions | | | | ✅ |

The admin does not inherit the curator's powers, and the curator has no admin powers. The investor
gate is enforced in a single place, the ERC-20 `_update` hook, so minting checks the recipient,
burning checks the holder and a transfer checks both. `deposit` and `redeem` additionally check the
caller up front, so a rejected account is turned away before its tokens are touched.

## Core Capabilities

### 1. Opening a position

`createPosition(priceLower, priceUpper, amount, isAmount0)` opens the vault's only position. The
curator names a price range and how much of **one** token to commit; the vault derives the other
side from the pool's current price. Both amounts must already be sitting in the vault.

When the vault has no shares outstanding, the liquidity minted here becomes the opening share
supply, credited to the caller. Shares and liquidity therefore start one-to-one.

### 2. Depositing

`deposit(amount0Desired, amount1Desired, amount0Min, amount1Min, deadline)` mirrors
`NonfungiblePositionManager.increaseLiquidity`. The investor names the most they will supply of each
token, and the vault takes only what the position's current ratio needs. Amounts are pulled exactly,
and the wei-level remainder left by the pool's rounding is returned in the same call.

### 3. Redeeming

`redeem(shares, amount0Min, amount1Min, deadline)` burns shares and withdraws the caller's share of
the position's liquidity plus their share of any idle balance, paying out in both tokens. Only the
principal released by this redemption is collected from the position, so a redemption can never
sweep fees belonging to the remaining holders.

### 4. Rebalancing

`rebalance(priceLower, priceUpper, sqrtPriceLimitX96)` collects fees, closes the current position,
swaps inside the same pool so the balances match the new range's ratio, and mints the largest
position those balances support. See **Rebalance algorithm** below.

### 5. Maintenance

`collectFees` collects and reinvests in one step. `addLiquidity` puts idle balances back to work.
`removeLiquidity` trims the position into idle balances. `unwindPosition` closes it entirely,
leaving everything idle and `activeTokenId()` at zero.

### 6. Reading

`activeTokenId()` returns the current NFT id, or zero when there is none; it changes every time a
position is opened or closed, so integrators must read it rather than cache it. `activePosition()`
returns the range and liquidity. `previewCounterAmount(tokenId, amount, isAmount0)` answers "if I
supply this much of one token, how much of the other does the position need?" for any position id,
and `previewCounterAmountForRange` does the same for a range that does not exist yet.
`previewDeposit` and `previewRedeem` price a deposit or redemption.

## Accounting model

A share is a pro-rata claim on **everything the vault owns**: the position's liquidity *and* any
idle token balances. Both move together on every deposit and redemption, so tokens waiting to be
folded back into the position are never given to, or taken from, a single investor.

Every deposit and redemption begins by collecting the position's fees and folding all idle balances
back in. That is what makes fees accrue to the holders who were present when they were earned,
before a new holder is priced.

### Rounding

| Quantity | Direction | Why |
|---|---|---|
| Shares minted | down | The depositor never receives more claim than they paid for. |
| Tokens taken on deposit | up | The vault is never short of what the pool charges. |
| Tokens paid on redemption | down | The vault never pays out more than the position releases. |
| Liquidity burned on redemption | down | Same. |
| Preview counter amount | up | Supplying exactly the preview is always enough. |
| Snapped tick lower / upper | down / up | The range always covers the prices that were asked for. |

A deposit's cost has two components that each round up, so the share count is sized against the
caller's maximum less that headroom. A final check refuses any deposit that would still take more
than the caller authorised.

## Price format

Ranges are given as **human prices**: token1 per token0, decimal-adjusted, scaled by 1e18. For the
mainnet USDC/WETH pool, token0 is USDC and token1 is WETH, so a price of 3000 USDC per ETH is
supplied as roughly `3.33e14`, being one three-thousandth of a WETH per USDC.

Conversion to Uniswap's Q64.96 sqrt ratio uses two regimes. Below a raw ratio of 2^64 the shift is
applied before the square root, which is exact to the last bit. Above it, where pairs of very
differently priced tokens live, the shift is split around the square root, costing at most 64 low
bits of a result larger than 2^128 and so keeping the relative error under 2^-64.

Ticks are snapped outward: the lower bound rounds down and the upper bound rounds up, so the minted
position always contains the requested range rather than a subset of it.

## Rebalance algorithm

1. Check the pool's spot price against its own time-weighted average.
2. Snap the requested range to the pool's tick spacing.
3. Collect fees, burn all liquidity, collect the principal and burn the NFT.
4. Size the swap that maximises mintable liquidity in the new range.
5. Execute it against the pool, paying through `uniswapV3SwapCallback`.
6. Check the price against the average again.
7. Re-read the pool and mint the largest position the balances now support.

### Sizing the swap

The search runs over the **post-swap price**, not the input amount. Within the current
initialized-tick interval the pool's liquidity is constant, so the input needed to reach any
candidate price has a closed form, and the two liquidity caps move strictly in opposite directions
as that price slides across the range: the cap funded by the token being sold falls while the cap
funded by the token being bought rises. Their crossing is the optimum, which makes a monotone
predicate and a plain bisection sufficient rather than a search for a maximum.

The interval is clipped to the prices reachable with the balances at hand and to the range's own
boundaries, so an optimum outside it becomes the corresponding endpoint: sell everything when the
range sits wholly on one side of the price, sell nothing when the balances are already in ratio. The
result is compared against not swapping at all, so a swap can never leave the vault worse off.

The model is exact while the swap stays inside the current tick interval, which is the normal case.
If it crosses an initialized tick the realised price differs slightly, which is why step 7 re-reads
the pool and mints against the balances actually held. The residue stays idle, is still owned
pro-rata, and is folded back in by the next compounding.

## Safety Considerations

### 1. Price manipulation

Every price-sensitive operation compares the pool's spot price against its own time-weighted average
over an admin-configured window and refuses to proceed beyond an admin-configured tolerance. A
rebalance checks before **and** after its swap. A pool whose observation history is too short to
answer the window reverts rather than proceeding unguarded.

The swap also takes a price limit. Passing zero defaults it to the edge of the same tolerance band,
so an oversized swap fills partially instead of reverting. A caller-supplied limit must lie on the
far side of the current price, so it can only ever tighten the swap.

### 2. Callbacks

`uniswapV3SwapCallback` requires both that the caller is the vault's own pool and that the vault is
inside its own swap, so it cannot be invoked out of band even by the real pool.
`onERC721Received` accepts a token only from the position manager and only during a mint, so an
unsolicited NFT is rejected rather than silently custodied.

### 3. Reentrancy

Every state-changing external function carries `nonReentrant`. Balances are read after the position
manager has been called and shares are burned before tokens are paid out.

### 4. Curator trust

The curator chooses ranges and when to move, so a careless or hostile curator can lose value to
impermanent loss, swap fees and repeated rebalancing. The curator **cannot** move tokens out of the
vault: the position is always minted to the vault, collected amounts always land in the vault, and
the only transfer to an outside address is a swap payment to the vault's own pool.

### 5. Recovery

`recoverAssets` reports zero recoverable for both pool tokens, so they can never be swept away from
shareholders. Any other token that reaches the vault has no claim against it and can be swept in
full to the admin-configured recipient.

### 6. Upgrades

Upgrades are authorised by the admin alone. Storage is plain and append-only, followed by a
50-slot gap.

### 7. Unsupported tokens

Tokens that do not transfer their full stated amount, such as fee-on-transfer and rebasing tokens,
are not supported and must not be configured. The exact-pull accounting means such a token makes the
position manager call revert rather than silently mis-accounting.

## Configuration Parameters

| Parameter | Set at | Notes |
|---|---|---|
| `token0`, `token1`, `fee` | initialization | Immutable in practice; the pool is resolved from them. |
| `twapPeriod` | initialization, admin | Manipulation-guard window in seconds. Must be non-zero. |
| `maxTwapDeviationBps` | initialization, admin | Tolerance in basis points. Must be in (0, 10000]. |
| `assetRecoverer` | initialization, admin | Recipient of swept tokens. |

Both pool tokens must report 18 decimals or fewer, which the price scaling relies on.

## Events

| Event | Emitted when |
|---|---|
| `Deposit` | An investor mints shares. |
| `Redeem` | An investor burns shares. |
| `PositionCreated` | A position is opened, by `createPosition` or `rebalance`. |
| `PositionUnwound` | A position is closed and its NFT burned. |
| `Compounded` | Fees are collected and idle balances folded back in. |
| `LiquidityRemoved` | The curator trims the position. |
| `Rebalanced` | A rebalance completes, reporting the swap and the residue. |
| `TwapConfigUpdate`, `AssetRecovererUpdate` | The admin changes configuration. |

## Deployment

`script/DeployUniswapV3PositionVault.s.sol` deploys the implementation and an ERC-1967 proxy from a
named entry in `script/uniswap-vaults.json`. The deploying key holds the admin role only long enough
to grant the configured one, then renounces; a post-flight block asserts that end state.

The vault links `UniswapV3VaultMath`, which forge deploys and links automatically. Because
`optimizer_runs` is tuned repository-wide for runtime gas rather than code size, this one file is
compiled with a size-favouring setting declared in `foundry.toml`; no other contract is affected, so
no existing CREATE2 address moves.

Set `openToEveryone` to grant `INVESTOR` to the zero address at deployment, which opens deposits,
redemptions and transfers to anyone.

## Testing

| Suite | Needs a fork | Covers |
|---|---|---|
| `test/UniswapV3PositionVault.Math.t.sol` | no | Price conversion, tick snapping, share math, swap sizing, including fuzz tests that sweep the solver against every alternative. |
| `test/UniswapV3PositionVault.t.sol` | yes | Initialization, access control, the investor gate, position operations, deposits, redemptions, compounding, callbacks, recovery, upgrades. |
| `test/UniswapV3PositionVault.Rebalance.t.sol` | yes | Rebalancing in and out of range, single-sided balances, price limits, residue bounds, holder value across a move. |

The fork suites pin a mainnet block, unlike the factory suites. Every assertion depends on a pool's
price, tick and observation history, so an unpinned fork would make expected amounts drift with
mainnet and turn real regressions into noise. They read `MAINNET_URL` from the environment.

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
| `rebalance` / `rebalanceWithSwap` | | ✅ | | |
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

Two variants, differing only in whether the balances are traded into the new range's ratio first.
Both collect fees, close the current position and mint the largest position the balances then
support, and both work whether or not a position is already open.

`rebalance(priceLower, priceUpper)` does not trade. Whichever token the new range needs less of is
left over: the mint consumes one side entirely and the surplus of the other stays idle. This avoids
the swap's price impact and fee, at the cost of leaving part of the vault unproductive.

`rebalanceWithSwap(priceLower, priceUpper, maxPriceImpactBps)` swaps inside the same pool so that
almost the whole balance ends up as liquidity. The cap is how far the curator will let that trade
move the pool's price, in basis points of the price it starts at, so 100 is one percent. It must be
between 1 and 10000. A swap that would move the price further stops at the cap and fills partially,
leaving the rest idle, rather than reverting. See **Rebalance algorithm** below.

Choosing between them is a real trade-off. Trading costs the pool fee and moves the price against
the vault; not trading leaves capital idle. The surplus a no-swap rebalance leaves behind cannot be
put back to work on its own, because adding to a position in range needs both tokens, so it sits
until the curator trades it or the price moves far enough that the position becomes single-sided on
that same side.

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

Steps 1 to 3 and step 7 are shared by both variants; only `rebalanceWithSwap` runs steps 4 to 6.

1. Check the pool's spot price against its own time-weighted average.
2. Snap the requested range to the pool's tick spacing.
3. Collect fees, burn all liquidity, collect the principal and burn the NFT.
4. Size the swap that maximises mintable liquidity in the new range.
5. Execute it against the pool, paying through `uniswapV3SwapCallback`.
6. Check the price against the average again.
7. Re-read the pool and mint the largest position the balances now support.

The no-swap variant still checks the price in step 1, because step 7 prices both sides at the
current price even though nothing is traded.

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

The swap carries a second, separate bound: the curator's price-impact cap. The two do different
jobs. The impact cap is the curator's own limit on how far this particular trade may move the pool,
measured from the price the swap starts at, and a swap that would move further simply stops there
and fills partially. The manipulation guard is the vault's limit, measured against the pool's own
recent average, and it reverts outright. One is slippage control, the other is a defence against
acting on a price someone else has moved.

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
| `Rebalanced` | A rebalance completes, reporting the swap, if any, and the residue. The no-swap variant reports zero amounts. |
| `TwapConfigUpdate`, `AssetRecovererUpdate` | The admin changes configuration. |

## Deployment

`script/DeployUniswapV3PositionVault.s.sol` deploys the implementation and an ERC-1967 proxy from a
named entry in `script/uniswap-vaults.json`. The deploying key holds the admin role only long enough
to grant the configured one, then renounces; a post-flight block asserts that end state.

The vault links `UniswapV3VaultMath`, which forge deploys and links automatically. Because
`optimizer_runs` is tuned repository-wide for runtime gas rather than code size, this one file is
compiled with a size-favouring setting declared in `foundry.toml`; no other contract is affected, so
no existing CREATE2 address moves.

The vault sits a few hundred bytes under the EIP-170 limit. Adding an external function to it will
need either another reduction in that setting or more of its logic moved into the math library,
which has ample room. `forge build --sizes` reports the current margin.

Set `openToEveryone` to grant `INVESTOR` to the zero address at deployment, which opens deposits,
redemptions and transfers to anyone.

## Testing

| Suite | Needs a fork | Covers |
|---|---|---|
| `UniswapV3PositionVault.Math.t.sol` | no | Price conversion, tick snapping, share accounting, the price band and swap sizing, including fuzz tests that sweep the solver against every alternative. |
| `UniswapV3PositionVault.Reentrancy.t.sol` | no | Genuine re-entry attempts against every guarded entry point, driven by hostile stand-ins for the pool and position manager. |
| `UniswapV3PositionVault.t.sol` | yes | Initialization, access control, the investor gate, position operations, deposits, redemptions, compounding, callbacks, recovery, upgrades. |
| `UniswapV3PositionVault.Rebalance.t.sol` | yes | Both rebalance variants: in and out of range, single-sided balances, the surplus the non-trading one leaves, price-impact caps, residue bounds, holder value across a move. |
| `UniswapV3PositionVault.Decimals.t.sol` | yes | The same core flows against WBTC/WETH, where token0 has 8 decimals rather than 6. |
| `UniswapV3PositionVault.Invariant.t.sol` | yes | Properties that must survive any reachable sequence of deposits, redemptions, rebalances, trims, donations and pool trades. |

The fork suites pin a mainnet block, unlike the factory suites. Every assertion depends on a pool's
price, tick and observation history, so an unpinned fork would make expected amounts drift with
mainnet and turn real regressions into noise. They read `MAINNET_URL` from the environment.

### Why reentrancy needs mocks

A standard ERC-20 never calls back into its sender, so against the real USDC, WETH and WBTC there is
no way to attempt reentrancy at all. The stand-ins in `test/mocks/ReentrantUniswap.sol` create the
opportunity: each can be told to call back into the vault at the exact moment the vault has handed
over control, inside the position manager while liquidity is being added and inside the pool during
a rebalance swap. That is what turns `nonReentrant` from an assertion by inspection into a tested
property.

### Invariants

Each holds after any reachable sequence the handler can produce:

- The vault owns the position it reports as active.
- Shares outstanding are never a claim on nothing.
- No allowance is ever left standing to the position manager.
- Every share in existence is held by an account permitted to hold shares.
- Redeeming the entire supply never claims more than the vault owns.

A run also prints how many deposits, redemptions, rebalances, unwinds and creations it actually
reached, because an invariant suite whose calls all revert passes without testing anything.

### Coverage

Measured over the vault's own suites:

| File | Lines | Branches | Functions |
|---|---|---|---|
| `src/UniswapV3PositionVault.sol` | 85.99% | 71.01% | 93.88% |
| `src/libraries/UniswapV3VaultMath.sol` | 48.86% | 32.61% | 48.48% |

Reproduce with:

```bash
forge coverage --ir-minimum --match-path 'test/UniswapV3PositionVault*' \
  --no-match-coverage '(^script/|^test/|libraries/uniswap/)' --report summary
```

The library figure understates reality and should not be read as a gap. The vault cannot be compiled
for coverage without `--ir-minimum`, which fails with a stack-too-deep error otherwise, and that
mode produces degraded source maps; the library is also reached by delegatecall, which coverage
attributes poorly. Every one of the library's external entry points is exercised, several of them by
fuzz tests. The vault's own figures are the meaningful ones.

The uncovered branches in the vault are dominated by defensive paths that a correct counterparty
never triggers, such as the clamps applied when the pool charges less than the plan allowed for.

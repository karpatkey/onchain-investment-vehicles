# KpkSharesRouter

Periphery contract that creates **and settles** a `KpkShares` subscription or redemption in a single
transaction, pricing it from an off-chain NAV quote passed as calldata.

`src/kpkShares.sol` is unchanged. The router is a new contract that holds the `OPERATOR` role on one
fund.

## Why it exists

Today settlement is two steps separated in time: an investor calls `requestSubscription`
(permissionless), and later an `OPERATOR` — the Manager Safe multisig — calls `processRequests` with
the NAV-derived share price as an argument. The kpk-app already computes that price by aggregating the
per-chain `NAVCalculator` deployments in `onchain-accounting` off-chain.

The router collapses each flow to one call: shares are minted, or assets paid, in the same transaction
that creates the request.

Two properties of the audited contract make this possible without touching it:

1. **No minimum settlement delay exists.** There are no `block.number` checks in `kpkShares.sol`. The
   only timestamp gates are the 7-day `expiryAt` upper bound (`:726`) and the investor-side cancel TTL
   (`:280`, `:393`). Same-transaction create-and-settle already works.
2. **Pricing is independent of supply.** `assetsToShares` (`:536`) and `sharesToAssets` (`:558`) are
   pure functions of `(amount, price, decimals)`; `totalSupply()` appears only in the two fee functions
   (`:977`, `:994`). So the fee shares `_chargeFees` mints earlier in the same `processRequests` call
   cannot shift the share count. The router precomputes the exact output and passes it as the request's
   own `minSharesOut`, so the audited guard at `:776` holds at precise equality. This is pinned by
   `test_subscribe_feeMintDoesNotChangeSharesOut`.

## The security consequence you must understand before wiring this

The guards at `kpkShares.sol:776` and `:856` have teeth in the two-step flow only because the investor
authors `minSharesOut` at one time and the operator authors the price later. **When one call authors
both, they pass by construction.**

The residual asymmetry matters: a price *worse* for the transacting user reverts, a price *better*
succeeds and dilutes everyone else. So the audited per-request guards protect only the party who is
never at risk. After this change, the protection for continuing shareholders is entirely the router's:

| Guard | What it stops | Strength |
|---|---|---|
| EIP-712 `NavAttestation` from `NAV_SIGNER_ROLE` | The investor choosing their own price, even though they broadcast | Hard |
| `priceFloor` / `priceCeil` — absolute, admin-set | A walked or fat-fingered price | Hard; the only bound that does not track a mutable anchor |
| `navRound` monotonic, **router-wide** | Cherry-picking an older-but-unexpired quote from a published strip | Hard |
| `maxNavTtl` — bounds quote life **and price age** | The stale-NAV free option; doubles as the kill switch | Hard, and the primary economic lever |
| Per-tx caps | Size of any single settlement | Hard |
| Per-day caps | Blast radius of a mispriced or compromised quote inside one monitoring interval | Hard, but the true bound is **2×** — see below |
| `maxDeviationBps` vs `getLastSettledPrice` | Drift from the fund's last settlement | **Advisory** — see below |
| `maxFeeDilutionBps` | Uncharged **performance**-fee dilution only | **Partial** — see below |
| `minHoldingPeriod` | Automated round-tripping | **Weak** — see below |

### Why `maxNavTtl` checks two things

It bounds `validUntil` forward (`<= now + maxNavTtl`) **and** the price's age backward
(`now - issuedAt <= maxNavTtl`). The forward bound alone is not sufficient: a quote signed a week ago
with `validUntil = now + 60` satisfies it during its final `maxNavTtl` seconds and would settle at a
week-old NAV — making the headline anti-stale-NAV control vacuous and `issuedAt` decorative despite being
signed. Both halves are needed for the "Hard" rating above to be true.

### Why the round counter is router-wide, and why the admin can reset it

`sharesPrice` is a fund-wide USD-per-share figure; the asset only selects the decimals used to convert
it. A per-asset counter therefore left a superseded quote live on any sibling asset that happened not to
transact — settle USDC at round N after a price drop and the pre-drop round N-1 quote was still usable on
USDT. One counter for the whole router closes that.

`lastNavRound` is also the only irreversible state in the contract, ratcheting from an unbounded
`uint256` that arrives inside a signed quote. A single attestation carrying an absurd round — a
compromised signer, or a pricing service emitting milliseconds, a hash, or a `u64::MAX` sentinel — would
otherwise exhaust the sequence permanently, with no upgrade path and no recovery short of redeploying and
having every user re-approve. `resetNavRound` (admin) is the lever, and it is safe to expose because the
round is a replay-ordering device rather than a price control: rewinding it cannot change what a quote is
worth, since `priceFloor`, `priceCeil`, `maxDeviationBps` and `validUntil` all still bind.

### Why the daily caps are really 2×, and per asset

`_dailyUsage` buckets on `block.timestamp / 1 days` — a fixed window that resets at a publicly known
instant. A full budget can be spent at 23:59 and another at 00:00, so the true bound on any rolling
24 hours is twice the configured value. To bound a rolling day at X, configure X/2. The budget is also
**per asset**, so a fund with two enabled assets has twice that again in aggregate. `routers.json`'s
starting values are written with this in mind; re-derive them if you change the asset set.

### Why `maxFeeDilutionBps` is only partial

It mirrors `WatermarkFee.calculatePerformanceFee` and therefore bounds **performance**-fee dilution only.
Two gaps are deliberate and must be understood before relying on it:

- **Management-fee dilution is not covered.** It accrues on every asset with no fee-module gate, and the
  fund's `_managementFeeLastUpdate` is `private` with no getter, so the router cannot compute it. On a
  fund with no performance-fee module — **the live kUSD configuration** — this guard is entirely inert
  while management fees still mint ahead of pricing. At kUSD's 300 bps annual rate a one-day settlement
  gap is ~0.8 bps but a 30-day gap is ~25 bps, landing on whichever single user crosses the fund's
  six-hour fee gate. This is bounded operationally, by settlement cadence, not on-chain.
- **It fails open** on a fee module that does not expose `highWatermark(address)`. That is a deliberate
  availability choice: failing closed would brick the router the moment an admin swapped in a legitimate
  module of a different shape. It does not widen admin power, since an admin who can set the fee module
  can already cause `KpkShares._chargePerformanceFee` to mint an uncapped amount regardless of what this
  router does.

### Why `maxDeviationBps` is advisory

`processRequests` rewrites `_lastSettledPrice[asset]` unconditionally at `kpkShares.sol:428`, including
when both request arrays are empty. The 30% band is therefore a per-call ratchet — roughly 52 calls
walk it from `1e8` to `1`, and they fit in one block. Any band anchored on that value inherits the
weakness. On this deployment the Manager Safe **retains** `OPERATOR`, so it can move the anchor outside
the router entirely. That is why `priceFloor`/`priceCeil` are absolute and not optional.

### Why `minHoldingPeriod` is weak

Shares are freely transferable, so a determined arbitrageur can move them to a fresh address whose
clock is unset and redeem immediately. Conversely, anyone can subscribe dust to a third party's address
and reset their clock. Neither is a lock-out: `KpkShares.requestRedemption` stays permissionless and
unaffected, so a griefed user can always exit via the fund's own two-step path. Treat the holding
period as a cost on automated loops, not a barrier. `maxNavTtl` and the volume caps do the real work.

### The free option

Atomic settlement on both sides means the price is known before the investor commits, which is a
repeatable option on stale NAV. Rough cost, per subscription: ~0.2 bps at a 120 s quote for a
stable-yield fund; ~2.5 bps for a 30%-vol directional fund, and around 2.5%/yr of AUM if round-tripped
10×/day on 10% of AUM. This is why every limit is per-fund configurable and why the quote lifetime
should be as short as the app can tolerate.

## What the router deliberately does not do

- **No `updateAsset` passthrough and no generic call forwarder.** The `OPERATOR` role also gates
  `KpkShares.updateAsset`, whose add branch (`kpkShares.sol:1041-1060`) registers an arbitrary token
  from nothing but `symbol()`/`decimals()`, and whose first settlement skips the deviation guard
  entirely (`:903`) — a three-call path to an unbounded mint. Keeping that behind the Manager Safe
  multisig is the point of letting the two `OPERATOR` holders coexist.
- **No on-chain `NAVCalculator` read.** `onchain-accounting`'s ADR 0017 values LP positions at
  instantaneous reserves on the explicit condition that no atomic on-chain NAV consumer exists, with a
  revisit trigger for exactly this case. Passing the price as signed calldata keeps that condition
  satisfied. A per-chain read would also bound only one chain's slice of a ~25-chain portfolio.
- **No upgradeability.** Users grant the router ERC-20 allowances; an upgradeable contract holding
  those would make its proxy admin an unconditional custodian.

## Roles

| Role | Holder | Purpose |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | The same Safe that holds `DEFAULT_ADMIN_ROLE` on the fund | Config, unpause, rescue. It is the only party that can grant or revoke the router's `OPERATOR`, so splitting these creates a state nobody can unwind |
| `NAV_SIGNER_ROLE` | Pricing service key (KMS/HSM) | Signs `NavAttestation` |
| `RELAYER_ROLE` | Automation bot | Triggers redemptions once liquidity has landed in the Safe |
| `GUARDIAN_ROLE` | Manager Safe + an ops hot key | Pause only. Atomic settlement leaves no window between a bad price becoming visible and it applying, so pausing must not need a multisig round trip |

An attestation is required on the **redemption** path too, with a signer key distinct from the relayer
key, so neither key alone can settle at a price of its choosing.

## Allowance topology

| Approver | Token | Spender | Amount |
|---|---|---|---|
| Investor | Subscription asset | **Router** | Per action — never infinite |
| Router | Subscription asset | Shares proxy | Exactly `assetsIn`, transient, asserted back to 0 |
| Share owner | **Shares** | **Router** | Per action — never infinite |
| Router | Shares | Shares proxy | **None needed** |
| Avatar Safe | Redemption assets | Shares proxy | `max` — **already exists** |

The shares row needs no allowance to the fund because `requestRedemption` escrows with an internal
`_transfer` from `msg.sender` (`kpkShares.sol:342`) — the router must *own* the shares, not be approved
for them. The Avatar Safe row already exists via `KpkOivFactory._execApprove` (`:1250-1263`) and needs
nothing new: the payout at `:867` is made by the proxy, exactly as for a manager-settled request.

Request **exact-amount** approvals in the app. Nothing on-chain can scope an ERC-20 allowance, so a
standing infinite share allowance to a relayer-drivable contract means a compromised relayer plus one
bug in the intent check drains every approving user. Per-action approvals shrink that to users with a
live pending approval.

## The atomicity invariant

**No request the router creates may outlive the transaction in a non-`PROCESSED` state.**

On a router-created request `investor == router`, so every refund path (`:293`, `:809`, `:404`, `:882`)
pays the router rather than the user. The reachable failure is not a revert but a silent skip:
`_processApproved` does `if (request.asset != asset) continue;` (`:723`), so a mismatched asset makes
`processRequests` return successfully while leaving the request `PENDING` with the user's principal
escrowed and unattributed.

The router therefore reads back `getRequest(id).requestStatus` and reverts unless it is `PROCESSED`,
plus asserts its own asset balance, share balance and transient allowance all return to their starting
values. Because the request was created in the same transaction, reverting deletes it — the violation
is made impossible rather than recovered from. `test_noRequestSurvivesAnyRevertingSubscribe` and
`test_redeemBatch_oneBadIntentRevertsAllAndCreatesNoRequest` pin this.

`rescue(token, to, amount)` is admin-gated and destination-explicit, deliberately unlike the repo's
`RecoverFunds` pattern which sweeps permissionlessly to the portfolio Safe. On a router any stranded
balance is one user's in-flight principal; sweeping it into the fund would socialise it into NAV, and
anyone could trigger that.

## Performance-fee boundary

`_chargeFees` runs before `_processApproved` (`:423`), minting fee shares while the pricing service's
quote was computed from a pre-mint supply. In the daily-batch flow that dilution spreads across a
batch; settling one user at a time concentrates it on whoever crosses the fund's six-hour gate — up to
about 1% for a performance-fee crossing.

The fund's fee clocks are `private` with no getter (`:109`, `:112`), so the router cannot tell whether
the gate will trip. It instead mirrors `WatermarkFee.calculatePerformanceFee` exactly, reads the public
`highWatermark`, and refuses to settle when the potential dilution exceeds `maxFeeDilutionBps`
(`FeeSettlementRequired`).

**The remedy is a fee-only settlement, but only once the fund's six-hour gate has reopened.** That
qualifier is load-bearing and easy to get wrong: `_chargeFees` charges — and only then advances the
watermark — when `perfTimeElapsed > MIN_TIME_ELAPSED`, and `_performanceFeeLastUpdate` is written only
inside that branch (`kpkShares.sol:943-948`). A fee-only settlement attempted earlier mints nothing,
moves no watermark, and leaves the block in place.

So `FeeSettlementRequired` can persist for up to six hours in **both** directions, and the router arms it
itself: a router settlement charges the fee, resets the fund's clock, and any subsequent price move past
`maxFeeDilutionBps` blocks until the gate reopens. It is availability only — no fund loss, and
`KpkShares.requestRedemption` stays permissionless so nobody is locked out of the fund — but the timing
is adverse, because the block fires exactly when NAV has moved sharply and redeemers most want out. The
only lever that shortens it today is an admin `setAssetConfig` widening the tolerance, i.e. relaxing the
control that is blocking. **An operator escape hatch that does not require loosening the control is an
open design question** — see the PR discussion.

Keep a scheduled fee-only settlement spaced just over `MIN_TIME_ELAPSED` (6 h) so investor traffic almost
never crosses the gate. On a fund with `performanceFeeModule == address(0)` — the live kUSD configuration
— this guard never fires, which also means management-fee dilution there is unguarded; see the
`maxFeeDilutionBps` note above.

## Wiring

```bash
forge script script/DeployKpkSharesRouter.s.sol:DeployKpkSharesRouter \
  --rpc-url $MAINNET_URL --broadcast --verify --sig "run(string)" "kUSD"
```

The script only deploys; every wiring step needs a role the deployer should not hold, so it prints the
exact calldata for the owning Safes. Config lives in `script/routers.json` and is validated in CI by
`test/DeployKpkSharesRouter.t.sol`.

1. From the fund's `DEFAULT_ADMIN_ROLE` holder: `kpkShares.grantRole(OPERATOR, router)`. The Manager
   Safe keeps `OPERATOR`, so manual settlement stays available as a fallback. Note the live stack's
   admin is mid-handover between Security Council Safes (`docs/DEPLOYED_ADDRESSES.md`) — sequence
   against whichever holds the role at the time.
2. On the router: grant `NAV_SIGNER_ROLE`, `RELAYER_ROLE`, `GUARDIAN_ROLE`.
3. `setAssetConfig` per asset. The values in `routers.json` are **starting values, not decided risk
   policy** — they are the fund's only economic protection once this is live.
4. Verify `hasRole(OPERATOR, router)`, the Avatar Safe allowances, `router.SHARES()`, and record the
   router address and `DOMAIN_SEPARATOR()` in `docs/DEPLOYED_ADDRESSES.md`.

One router per fund, `SHARES` immutable. Not wired into `KpkOivFactory`: that factory's address is a
pure function of its bytecode and is pinned across 19 chains by `test/FactoryAddressSync.t.sol`, so
touching it would force a salt-v4 re-rollout.

### Signer discipline — not enforceable on-chain

The router cannot see the NAV struct's staleness flags, so the entire staleness defence lives in the
signer. Refuse to sign whenever any chain reports `stalePriceAssets.length > 0`,
`irregularPriceAssets.length > 0`, `sequencerDown`, `quoteAssetStale`, or `value <= 0`.
Publish-and-halt, never publish-a-guess. Because quotes expire, a signer that stops signing is a
working kill switch.

### Monitoring — not optional

Alert on: any `processRequests` not from the router or the Manager Safe; `_lastSettledPrice` moving
beyond a bps/hour threshold; multiple settlements in one block; any `AssetAdd` event; `totalSupply`
jumps; every settled price reconciled against an independently computed NAV; any nonzero router token
or share balance at rest; `feeReceiver` balance jumps.

Note that `SubscriptionRequest.investor` records the **router**, not the subscriber, so indexers must
read the router's own `Subscribed` / `Redeemed` events for attribution.

## Known asymmetry: batch delivery verification

`redeem` verifies what the receiver **actually** received against the quoted `assetsOut`, which is the
only check on a token that delivers less than it reports — `KpkShares` compares only numbers it computed
itself (`:856`). `redeemBatch` omits that check, because all payouts land in one `processRequests` and
two intents sharing a receiver make their individual deltas inseparable.

The practical consequence is that **fee-on-transfer and rebasing assets are unsupported as redemption
assets on the batch path**. They already break the fund's own accounting, and the admin controls which
assets are redeemable, so the exposure is a configuration error rather than an attack. If such an asset
is ever enabled, route it through single `redeem` only.

## Contract size

24,131 bytes runtime against the EIP-170 limit of 24,576 — **about 445 bytes of margin**. This is tight:
essentially any new external function or error will overflow it. Adding surface here requires a
`forge build --sizes` check, and note some chains apply lower limits than mainnet.

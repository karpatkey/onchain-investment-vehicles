# KpkSharesNav — NAV-oracle-priced shares for a single-chain fund

> **Read this first — the plan below is a historical record, and implementation disproved parts of it.**
> It is kept as written so the reasoning survives, but two claims in it are now known to be FALSE and
> one section describes an API that was never shipped. Corrections, with the corrected source of
> truth in each case:
>
> 1. **"An appended NAV field makes decoding revert"** (risks section) — **false, verified by test.**
>    An appended field decodes cleanly and is silently dropped, so a newly appended NAV *health
>    signal* would simply not be gated. The reverse direction (this mirror ahead of the deployment)
>    does not reliably revert either. See `src/interfaces/INavCalculator.sol` for the corrected
>    explanation and `test/kpkSharesNav.Drift.t.sol` for the proof. The fork test therefore asserts
>    encoded LENGTH, not decodability.
> 2. **`assetsToShares` / `sharesToAssets` as external views** (external surface section) — **not
>    shipped.** Both were cut to fit EIP-170; they were exactly redundant with `previewSubscription`
>    and `previewRedemption`, which are the supported entry points. Do not integrate against them.
> 3. **"Fees are minted after the price snapshot, so a batch settles pre-dilution"** — changed during
>    review. Batches now settle at the POST-fee price via `_repriceAfterFees`, because the pre-fee
>    price short-changed a subscriber by up to ~9% when a performance fee landed in the batch.
>
> The full list of what pre-merge review changed is in PR #45's description.

## Context

Today `KpkShares` has no on-chain price source. The operator passes a share price as a raw calldata
argument to `processRequests` (`src/kpkShares.sol:414-429`), and the only guard rails are a ±30 %
deviation check against the last settled price and each request's own slippage bound. That means the
operator is trusted to price the fund correctly on every batch.

For a **single-chain** fund this is now avoidable: karpatkey's `NAVCalculator`
(`karpatkey/onchain-accounting`) can value the fund's Safe on-chain, so the contract can derive the
share price itself from `NAV / totalSupply` and stop trusting an operator-supplied number entirely.

This plan adds a new contract that does that, gates asset listing on the NAV registry, adds an
admin-toggleable synchronous deposit path, and drops the 30 % deviation constraint (which exists to
bound operator error and is meaningless once the contract derives the price itself).

**Design produced by the Fable model; every load-bearing claim below was re-verified against the
code and against remote `main` of the NAV repo.**

## Decisions already taken

1. **New standalone contract** — `src/kpkShares.sol`, `IkpkShares.sol`, `KpkSharesDeployer.sol` and
   `KpkOivFactory.sol` stay **byte-identical**. Not wired into the factory in this change.
2. **Bootstrap** via an `initialSharePrice` init param (8-dec USD), used whenever `totalSupply() == 0`.
3. **NAV health: strictest, fail-closed.**
4. **NAV account = `portfolioSafe`.**

## Why the bytecode freeze is absolute

`src/KpkSharesDeployer.sol:59,76` hardcodes `type(KpkShares).creationCode`, and `KpkOivFactory`
embeds `KpkShares.ConstructorParams`. `bytecode_hash` sits at the solc default, so **any** edit to
`kpkShares.sol` — NatSpec included — moves the deployer's and factory's CREATE2 addresses and reddens
`test/FactoryAddressSync.t.sol`. That test's own comment records that these "shipped stale once
already, moved by a metadata-hash change from a NatSpec edit". The salt-v3 stack is live and
Safe-owned on 19 chains. Extracting a shared base with the old contract is therefore **out of scope**,
not merely undesirable.

## The core design

### Price unit: one USD share price + per-asset conversion

The existing `sharesPriceInAsset` is **asset-per-share × 1e8**, despite NatSpec calling it USD
(verified numerically against `assetsToShares`/`sharesToAssets` at `src/kpkShares.sol:536-580`). The
new contract instead snapshots a single USD share price per pricing event:

```
sharePriceUsd8 = navUsd8 * 1e18 / totalSupply()
```

and converts each asset through its own USD price from `getPriceData(asset)`, normalising with the
struct's own `decimals` field (never assumed to be 8):

```solidity
shares = assetAmount.mulDiv(assetPriceUsd8 * 1e18, (10 ** assetDec) * sharePriceUsd8, Math.Rounding.Floor);
assets = shares.mulDiv(sharePriceUsd8 * (10 ** assetDec), 1e18 * assetPriceUsd8, Math.Rounding.Floor);
```

Why not quote the NAV directly in the asset (`getAccountNav(safe, asset)`)? It costs a **full adapter
scan per asset**, and it walks into the documented trap where `quoteAssetStale == true` makes `value`
silently fall back to USD-8dp while `quoteAsset` stays non-zero. One USD scan plus a cheap feed read
per asset is cheaper and has no silent unit flip. A single USD price also keeps two same-block batches
in different assets from implying different share prices.

*Worked example — WBTC (8 dec) at $60,000, share price $1.05:* subscribing `5e7` (0.5 WBTC) yields
`5e7 * (6e12 * 1e18) / (1e8 * 1.05e8) ≈ 2.857e22` = 28,571.43 shares, matching $30,000 / $1.05.

### Pricing sequence (per event)

1. `getAccountNav(portfolioSafe, address(0))` — one scan, USD 8dp.
2. **Health gate** — revert `NavUnhealthy()` on `sequencerDown || quoteAssetStale ||
   quoteAssetIrregular || stalePriceAssets.length != 0 || irregularPriceAssets.length != 0 ||
   monitorsUnhealthyPriceAssets.length != 0`. Note `stalePriceAssets` is scoped to assets the
   account's positions actually touch, so an unrelated stale registry asset does not halt the fund.
3. **Supply / NAV** — `totalSupply() == 0` → `initialSharePrice`; `nav.value <= 0` with non-zero
   supply → `NavNotPositive()`; computed price `0` → `SharePriceZero()`. The `int256` is gated
   **before** any `uint256` cast. This replaces the old silent `return 0` price paths
   (`src/kpkShares.sol:541,563`) — a zero price must never reach a mint or burn.
4. `getPriceData(asset)` (the with-divergence variant; `getPriceDataNoDivergence` leaves `irregular`
   at default, which contradicts the strict policy). Revert `AssetPriceUnhealthy()` on
   `stale || sequencerDown || irregular || price <= 0`.
5. `_chargeFees(sharePriceUsd)` — after the snapshot, before processing (parity with `:423`).
6. Process all requests against that one snapshot.
7. Record `lastSharePriceUsd` / `lastPricedAt` and emit `SharePriceSettlement` — **observability
   only**; nothing reads it back as a pricing input.

**Liveness carve-out:** steps 1–5 run only when `approveRequests.length != 0`, so a pure-rejection
call still refunds escrow while the fund is unpriceable. Cancellations already need no price.

### Two deliberate behaviour changes beyond the literal ask

- **Slippage failure skips instead of reverting the batch.** Today an unmet bound reverts everything
  (`:776`, `:856`). That was tenable when the operator could re-price; with a NAV-derived price a
  single unsatisfiable request would permanently brick every batch containing it. It now `continue`s,
  leaving the request PENDING to be rejected or to expire. User bounds still bind absolutely.
- **`isFeeModuleAsset` is deleted.** It exists only to restrict performance fees to a USD-pegged
  asset because the price fed to `WatermarkFee` is asset-denominated while the module documents it as
  USD (verified: `_chargeFees` gates on it at `src/kpkShares.sol:943`, and `_setPerformanceFeeRate`
  passes `_lastSettledPrice[usdAsset]` at `:1130`). A genuine USD share price makes the high-watermark
  one coherent series across all assets, so the flag and the `setPerformanceFeeRate(rate, usdAsset)`
  second parameter both go away.

## Files

**New:**
- `src/interfaces/INavCalculator.sol` — minimal hand-mirrored interface (the NAV repo is not a
  submodule). Verified field order, which is ABI-load-bearing:
  `NAV { int256 value; Asset quoteAsset; uint64 timestamp; Asset[] stalePriceAssets; bool
  sequencerDown; bool quoteAssetStale; Asset[] irregularPriceAssets; bool quoteAssetIrregular;
  Asset[] monitorsUnhealthyPriceAssets; }`. Declare `priceType` as `uint8` (the ABI-canonical type of
  the enum) to avoid vendoring `IPrices`. Pin the source commit in the header.
- `src/IKpkSharesNav.sol`, `src/KpkSharesNav.sol`
- `test/mocks/MockNavCalculator.sol`, `test/kpkSharesNav.TestBase.sol` + domain files aggregated by
  `test/kpkSharesNav.Main.sol`
- `script/DeployKpkSharesNav.s.sol`

**Read-only templates (must not change):** `src/kpkShares.sol`, `src/IkpkShares.sol`,
`src/KpkSharesDeployer.sol`, `src/KpkOivFactory.sol`.

Inheritance mirrors `src/kpkShares.sol:22-29` **plus `ReentrancyGuardUpgradeable`** (storage-based,
not transient — EIP-1153 support is unproven across all target chains). `RecoverFunds` stays the last
base so its `__gap` holds slots 0–49; unlike the old contract, end with `uint256[50] private __gap;`.
New state packs into one slot: `address navCalculator; bool syncDepositsEnabled; uint64 lastPricedAt;`
plus `uint256 initialSharePrice; uint256 lastSharePriceUsd;`.

## External surface (delta vs `IkpkShares`)

```solidity
// changed — price parameters gone
function processRequests(uint256[] calldata approve, uint256[] calldata reject, address asset) external;
function previewSubscription(uint256 assets, address asset) external view returns (uint256);
function previewRedemption(uint256 shares, address asset) external view returns (uint256);
// NOT SHIPPED - both were cut for EIP-170; they duplicated the two preview functions above:
// function assetsToShares(uint256 assetAmount, address asset) external view returns (uint256);
// function sharesToAssets(uint256 shares, address asset) external view returns (uint256);
function updateAsset(address asset, bool canDeposit, bool canRedeem) external;   // NAV gate; isFeeModuleAsset dropped
function setPerformanceFeeRate(uint256 newRate) external;                        // usdAsset dropped

// new
function subscribe(uint256 assetsIn, uint256 minSharesOut, address asset, address receiver)
    external returns (uint256 sharesOut);
function setSyncDepositsEnabled(bool enabled) external;   // isAdmin
function setNavCalculator(address newNavCalculator) external; // isAdmin
function getSharePriceUsd() external view returns (uint256);  // live, health-gated
```

`ConstructorParams` gains `address navCalculator` and `uint256 initialSharePrice`.
`syncDepositsEnabled` starts **false**.

**New errors:** `NavUnhealthy`, `NavNotPositive`, `SharePriceZero`, `AssetNotRegisteredInNav`,
`AssetNotPriceable`, `AssetPriceUnhealthy`, `SyncDepositsDisabled`, `InvalidNavCalculator`,
`SlippageBoundNotMet`.
**Removed:** `PriceDeviationTooLarge`, `NoStoredPrice`, `MAX_PRICE_DEVIATION_BPS`,
`_validatePriceDeviation`, `_lastSettledPrice`, `getLastSettledPrice`.
**New events:** `NavCalculatorUpdate`, `SyncDepositsEnabledUpdate`, `SharePriceSettlement`,
`SyncSubscription`. `AssetUpdate` loses its `isFeeModuleAsset` field.

### Listing gate (in `_updateAsset`, analogue of `src/kpkShares.sol:1009-1061`)

Whenever `canDeposit || canRedeem` would become true: `getRegisteredAsset(asset)` must report
`found` (O(1), non-reverting — **not** `getAssetInfo`, which is a fail-closed probe that reverts);
the NAV's `decimals` must equal `IERC20Metadata(asset).decimals()`; and `getPriceData(asset)` must
return healthy inside a `try/catch`. Delisting (`false, false`) skips the gate so an asset can always
be removed.

### `setNavCalculator` must validate

Non-zero, `code.length != 0`, `usdDecimals() == 8`, **and every currently listed asset is registered
on the new NAV** — otherwise the admin can brick the fund by pointing it at a NAV that cannot price
its own assets.

## Synchronous deposit

```solidity
function subscribe(...) external nonReentrant returns (uint256 sharesOut) {
    if (!syncDepositsEnabled) revert SyncDepositsDisabled();
    _requireValidRequestParams(assetsIn, minSharesOut, receiver);   // minSharesOut != 0 is mandatory
    if (!_approvedAssetsMap[asset].canDeposit) revert NotAnApprovedAsset();

    uint256 sharePriceUsd = _settleSharePrice();     // NAV read BEFORE any token movement
    uint256 assetPriceUsd = _assetPriceUsd(asset);
    _chargeFees(sharePriceUsd);

    sharesOut = _assetsToShares(assetsIn, assetPriceUsd, sharePriceUsd, dec);
    if (sharesOut < minSharesOut) revert SlippageBoundNotMet();

    IERC20(asset).safeTransferFrom(msg.sender, portfolioSafe, assetsIn);  // straight to Safe, no escrow
    _mint(receiver, sharesOut);
    emit SyncSubscription(...);
}
```

Ordering is the invariant that matters: pricing **precedes** the transfer, so the deposit is never
counted in the NAV it is priced against. Escrow accounting is untouched — no `UserRequest`, no
`requestId`, no `subscriptionAssets` or `_pendingRequestsCount` mutation — which also preserves
`_assetRecoverableAmount` semantics (verified at `src/kpkShares.sol:610-629`). Fees **are** charged:
skipping them would price deposits off a supply that understates accrued fees, and a sync-only fund
would never accrue at all. Only the pure math and `_settleSharePrice`/`_chargeFees` are shared with
`_approveSubscriptionRequest`; the two flows keep separate bodies.

No synchronous redemption — async operator-gated redemption is what prevents an atomic
manipulate-deposit-redeem round trip.

## Risks to carry into implementation

- **Donation / first-depositor.** `minSharesOut != 0` blocks round-to-zero theft. Residual: with dust
  supply a donor moves the price for existing holders. Mitigated operationally — `syncDepositsEnabled`
  defaults false; seed the fund via an operator-approved request first. Same hazard recurs if supply
  is ever fully redeemed while the Safe still holds assets; document it.
- **Gas.** `getAccountNav` is a full adapter scan — the NAV docs cite 6.27 M gas for one 50-token
  Balancer instance at 43 registered assets. Fine amortised over a batch; **ticket-size-sensitive for
  a per-user sync deposit on L1.** Measure on a fork against the real Safe before enabling the toggle.
  Do **not** build a cached-snapshot-with-max-age fallback — it reintroduces the stale price the
  design exists to eliminate, and `nav.timestamp` is just the read's own `block.timestamp`.
- **EIP-170.** Decoding `NAV memory` (three dynamic `Asset[]` carrying strings) is codegen-heavy under
  `via_ir`. If over 24,576 bytes, cut in this order: live conversion/preview views, then
  `getSharePriceUsd`, then move the math to a linked library.
- **Interface drift.** ~~An appended NAV field makes decoding of the shorter struct revert rather than
  corrupt — fail-closed, but it halts the fund.~~ **CORRECTED: this was wrong.** An appended field
  decodes cleanly and is silently dropped, so a new health signal would go ungated. Pin the commit
  and add a fork test that compares the live response's ENCODED LENGTH against a canonical
  re-encode — decodability alone proves nothing.
- **Trust.** `setNavCalculator` is mint-anything power, but the admin already holds `_authorizeUpgrade`.
  Separately, the NAV `MANAGER` role is still a deployer EOA (handoff to the security-council Safe is
  deferred) — document as a launch-checklist item, not a code fix.
- **Fail-closed liveness.** Strict health means any stale touched feed halts minting and burning.
  Escrow stays refundable throughout. If reverts prove routine in practice,
  `monitorsUnhealthyPriceAssets` is the weakest signal and the first to demote.

## Work order

1. `git submodule update --init --recursive` — **`lib/` is empty in this worktree; nothing compiles
   until this runs** (verified: all four submodules show `-`).
2. `src/interfaces/INavCalculator.sol`
3. `src/IKpkSharesNav.sol`
4. `src/KpkSharesNav.sol`, running `forge build --sizes` early to catch EIP-170 before tests exist.
5. `test/mocks/MockNavCalculator.sol` — settable NAV value, each health flag independently,
   push/clear the three asset arrays, revert-on-nav (simulating `AdapterGasExhausted`), an asset
   registry, per-asset price + `decimals` + `stale`/`sequencerDown`/`irregular`, revert-on-price,
   `usdDecimals() == 8`.
6. New parallel test tree (the existing `kpkSharesTestBase` is welded to the operator-price idiom
   across three deploy paths and dozens of 4-arg `processRequests` call sites, so forking is cleaner
   than retrofitting): `Initialization`, `Pricing`, `Subscriptions`, `SyncDeposit`, `Redemptions`,
   `Assets`, `Admin`, `Fees`, `Integration`, aggregated with the `override(...)` pattern of
   `test/kpkShares.Main.sol:36`.
7. `script/DeployKpkSharesNav.s.sol` + config carrying the NAV proxy per chain.

**Deferred:** sync redemption, a per-tx USD cap, a sync-depositor whitelist, factory/deployer wiring,
any ERC-4626 façade.

## Verification

- `forge build --sizes` — new contract must stay under 24,576 bytes.
- `forge fmt --check` and `forge test -vvv` — the three CI gates (Foundry pinned 1.7.1).
- **`test/FactoryAddressSync.t.sol` must still pass**, proving the existing deployed stack's CREATE2
  addresses did not move. This is the single most important regression check in the change.
- Unit coverage against `MockNavCalculator`: the full health-gate matrix (each flag independently
  halts), `totalSupply() == 0` bootstrap, negative and zero NAV, decimal fuzzing across 6/8/18-dec and
  non-USD-pegged assets, floor-rounding round-trips, the listing gate (unregistered, decimals
  mismatch, unpriceable, delisting still permitted), `setNavCalculator`'s validation matrix, the sync
  toggle, and the pricing-before-transfer ordering.
- One **fork test** against the live proxy `0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214` (verified
  today on remote `main`; the local NAV clone is stale and still names the abandoned
  `0x80eD5cc6…`) that calls `getAccountNav` and asserts a sane decode — this is what catches
  interface drift.
- Measure real `getAccountNav` gas on a fork against the intended Safe **before** enabling
  `syncDepositsEnabled`.

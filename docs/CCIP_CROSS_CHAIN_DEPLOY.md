# Cross-Chain OIV Deployment via Chainlink CCIP

`CcipOivDeployer` lets a **single transaction on any wired chain** deploy this chain's part of an
OIV and fan out the matching operational stack to every other wired chain over Chainlink CCIP —
producing the **same** Avatar Safe / Manager Safe / Roles Modifier addresses on every chain.

The local half is conditional: the full OIV when the origin appears in `sharesChains`, the
operational stack alone when it does not.

It is an external orchestrator: **all CCIP, fee, and router logic lives outside `KpkOivFactory`.**
The only factory change is exposing `oivToStackConfig` (a `pure` helper `deployOiv` already uses
internally); the factory's deployment logic and invariants are otherwise untouched.

## Why an orchestrator (and not CCIP inside the factory)

`KpkOivFactory` mixes `msg.sender` into every CREATE2 salt (`_deriveSalts`). Its cross-chain address
invariant therefore holds only when the **same caller** invokes the factory on every chain. A raw
CCIP integration breaks this — on the destination chain the factory's caller would be the CCIP
Router, not the account that originated the fan-out.

`CcipOivDeployer` solves it by being the single, uniform caller of the factory on every chain.
Because it is deployed at the **same address on all chains** (deterministic CREATE2, identical
creation code), the factory observes one identical `msg.sender` everywhere, so the address invariant
is preserved without putting any CCIP logic into the factory's deployment path.

```
                    origin chain (ANY wired chain)
   user ──deployEverywhere(config, sharesChains, [...])──▶ CcipOivDeployer
                                                               │
                          ┌────────────────────────────────────┤
                          ▼                                     ▼ (×N, shares chains excluded)
     origin IS in sharesChains:                        router.ccipSend(stackConfig)
         factory.deployOiv(config)                              │
     origin is NOT:                                             ▼  ~15 min, async
         factory.deployStack(stackConfig)     destination  CcipOivDeployer.ccipReceive
                                                                │
                                                                ▼
                                                    factory.deployStack(stackConfig)
                                                    (same Avatar/Manager/Roles addrs)
```

## Deterministic-address constraint

The orchestrator's creation code must be byte-identical across chains, so **no constructor argument
may differ per chain**. The CCIP Router and LINK token *do* differ per chain — so, unlike
Chainlink's stock `CCIPReceiver` (which stores the router as a constructor `immutable`), they live
in mutable storage set post-deploy via `configure(...)`. Only `_owner` and the `KpkOivFactory`
address (identical everywhere) are constructor arguments. The `onlyRouter` / source-chain /
source-sender checks are re-implemented against that storage router.

The orchestrator derives each sidechain's `StackConfig` by calling **`factory.oivToStackConfig(config)`
at runtime** — the same `pure` helper `deployOiv` uses internally — so the mapping can never drift
between the two and fragment a fund's addresses. **This requires a factory build that exposes
`oivToStackConfig`** (added in this change). The previously-published factory at
`0x0d94255fdE65D302616b02A2F070CdB21190d420` predates it, so this changes the factory's creation
code and therefore its CREATE2 address: the factory must be **redeployed** (new address). The
orchestrator deploy script takes that factory address as a `run` argument (pass the SAME address on
every chain), so it needs no edit — but the following operator-facing references to the old
`0x0d94…` factory MUST be updated to the redeployed address before use, or deployments will target
the deprecated factory:

- `script/DeployOiv.s.sol` — the `FACTORY` constant.
- `script/base/OivChainDeploy.sol` — bump the salt generation (`SALT_FACTORY`,
  `SALT_SHARES_MASTERCOPY`, `SALT_TIMELOCK_MASTERCOPY`, `SALT_TIMELOCK`, `SALT_CCIP` — all currently
  generation 4) if redeploying at fresh addresses. The script logs every address it produces.
- `DEPLOYMENT.md` and `docs/DEPLOYED_ADDRESSES.md` — the deployed-address tables.

## Security model

`ccipReceive` accepts a message only when all three hold:

1. `msg.sender` is the configured CCIP Router.
2. `message.sourceChainSelector` is **any selector in the orchestrator's registry** (`_isKnownSelector`)
   — not a single designated source. The registry is seeded at construction with the same chains on
   every deployment, so every orchestrator accepts every other one.
3. The decoded source sender equals `address(this)` — the sibling orchestrator on whichever chain
   initiated, which is the same address everywhere.

**Check (3) is the load-bearing one**, and it is worth being precise about why, because check (2)
looks stronger than it is. Only a contract deployed at *this* address can be the source sender, and
that address is a deterministic function of the orchestrator's creation code. Check (2) narrows the
set further, to the chains actually wired — without it, anyone could CREATE2 the same bytecode on any
CCIP-supported chain and send from there. So (2) is defence in depth over (3), not a substitute for
it, and loosening (2) from "mainnet only" to "any registered chain" does not weaken the model.

What these guards do **not** buy: they do not stop a third party from pre-occupying a fund's five
stack addresses. Those are deployed by the permissionless `safeProxyFactory` / `moduleProxyFactory`,
whose salts are `keccak256(keccak256(initializer), nonce)` — public functions of the config — so
anyone can land them. That is no longer a denial of service, because `KpkOivFactory` **adopts**
pristine pre-landed components instead of colliding with them (CREATE2 binds each address to the
factory's own initializer, so a squatter is forced into it). What the factory refuses is a stack that
has already been *wired*. `deployEverywhere` and `dispatchTo` are **permissionless** —
the caller pays the CCIP fees in **native gas** via `msg.value`, so there is no shared balance to
drain.

**Anti-front-running (config-bound salt).** The factory mixes its caller into every CREATE2 salt to
stop salt-squatting, but the orchestrator is the factory's *uniform* caller on every chain, which would
neutralise that protection now that deploy is permissionless. To restore it the orchestrator derives
the salt from the **whole config and the fund's shares topology**, with the base asset excluded because it legitimately differs per chain — `salt = keccak256(abi.encode(config-with-zeroed-asset, sharesChains))`. Any other config difference
(notably `admin`) changes *every* deployed address, so an attacker cannot land a fund at another
config's addresses; an identical config still yields identical addresses on every chain. **Off-chain
code must predict via the orchestrator's `predictOiv(config, sharesChains)`** (which applies this derivation), not
the factory's raw `predictOivAddresses`.

**Any wired chain.** `deployEverywhere` / `dispatchTo` originate the fan-out from whichever chain you
call them on, provided that chain is in the orchestrator's registry (`onlyWiredChain`). There is no
designated source chain: `SOURCE_CHAIN_ID` and `NotSourceChain` are gone. Pre-occupation of the
deterministic stack addresses — the reason the old restriction existed — is handled at the factory
instead, which adopts pristine pre-landed components and refuses only a stack that has already been
wired. The orchestrator never holds a privileged role on any deployed fund — the exec Roles Modifier
(owned by `config.admin`) remains the authoritative gatekeeper of Avatar Safe execution.

**The local half is conditional, and this is the easy thing to get wrong.** `_deployEverywhere` runs
`factory.deployOiv` only when the origin chain appears in `sharesChains`; when it does not, it runs
`factory.deployStack` and returns an instance whose shares fields are zero. So initiating from Base
with an Ethereum-only topology deploys a **stack** on Base, not a Base shares token — which is
correct, and is not what "deploy everywhere from any chain" sounds like.

## Operational model (important)

- **Asynchronous, not atomic.** The origin tx confirms once messages are dispatched. Each destination
  stack materialises later (after the ORIGIN chain's finality — ~15 min from Ethereum, and different
  on every other origin) when CCIP delivers to `ccipReceive`.
- **Partial failure is possible.** A destination message can fail (e.g. gas underestimate, missing
  `EMPTY_CONTRACT` on that chain). It then enters CCIP's FAILED state and can be **manually
  re-executed** within its retry window. Monitor delivery on the [CCIP Explorer](https://ccip.chain.link).
- **Recovery / add-a-chain.** `deployEverywhere` is for the first, atomic fan-out and cannot be
  re-run with the same config (the local `deployOiv` would collide on its CREATE2 addresses). To
  extend a fund to a sidechain that was not in the original set — or to send a fresh message to one
  whose prior delivery permanently failed — use
  **`dispatchTo(config, sharesChains, destChainIds, gasLimit)`**, which performs the CCIP fan-out
  only (no local OIV). Pass the SAME `config` and `sharesChains` (notably the same `salt`) so the
  stack lands at the fund's existing addresses. Re-dispatching to a chain whose stack is already
  WIRED reverts `StackAlreadyDeployedHere` on arrival and the source-chain fee is spent anyway; a
  chain where only some components exist is fine, since the factory adopts them.
- **Native fees, caller-funded.** CCIP fees are paid in the source chain's **native gas** from the
  caller's `msg.value` — the orchestrator holds no fee balance. Use
  `quoteDeployEverywhere(config, sharesChains, destChainIds, gasLimit)` to size the `msg.value`; any
  surplus is refunded to the caller. (The `CcipDeployEverywhere` script quotes and forwards this
  automatically, with a small buffer.)
- **Gas limit.** `gasLimit` must cover the destination's WHOLE `ccipReceive` frame, and the floor depends on the
  config far more than the older advice implied. Measured on this branch with the worst timelock
  `KpkTimelockDeployer.MAX_ROLE_MEMBERS` permits, `deployStack` ALONE costs:
  
  | manager owners | `deployStack` gas |
  |---|---|
  | 1  | 2,608,449 |
  | 10 (`MAX_CCIP_MANAGER_OWNERS`) | 2,778,274 |
  | 20 (refused) | 3,072,264 |
  
  plus roughly 80k for the `ccipReceive` frame around it, against CCIP's **3,000,000** destination cap.
  So a timelocked fund at the maximum role set needs ~2.7M even with a single owner, and ~2.86M at the
  owner bound — **pass 3,000,000 for any timelocked fund**. The older "2.0M / 2.2M-2.5M / 2.5M-2.8M"
  figures were measured on small role sets and are below the floor for a max-timelock fund at any owner
  count; following them spends every lane's non-refundable fee and reverts out-of-gas on arrival.
  A fund with no exec timelock is far cheaper (~1.58M measured) and 2.0M remains ample.
  
  `_price` does not enforce a minimum `gasLimit` — it bounds the owner count only — so this is on the
  caller. Quote first, and prefer over-sizing: the surplus is refunded, an under-size is not.

  katana), verified against the live router: `getFee` reverts above it. Unspent gas is **not**
  refunded. The timelock is an EIP-1167 clone rather than a full `TimelockController` deployment
  precisely so a timelocked stack stays inside that ceiling; deployed outright it cost ~1.45M more
  and put the call over the cap on those 10 chains.
  (The figure was ~1.38M before the factory began registering MultiSend unwrap adapters — six
  `setTransactionUnwrapper` writes across the three Roles Modifiers, ~155k gas.)
- **`EMPTY_CONTRACT` precondition.** `deployStack` reverts with `EmptyContractMissing` unless the
  `Empty` contract (`0xA470…4652`) is predeployed on the target chain — ensure this first.
- **MultiSend-unwrapping precondition.** `deployStack` also reverts with `MultiSendUnwrapperMissing`
  or `MultiSendMissing` unless the Zodiac `MultiSendUnwrapper` (`0xB4Cd…9efD`) and both Safe v1.4.1
  MultiSend contracts (`0x3886…B526`, `0x9641…02e2`) are present with their canonical bytecode.
  `_ensureMultiSendUnwrapper` onboards the unwrapper during infra deploy (permissionless, via the
  EIP-2470 SingletonFactory), so this is only a live risk on a chain wired without running that
  preflight. It matters most for fan-out: the CCIP fee is spent on the source chain regardless, so a
  destination missing this reverts on delivery and the fund exists everywhere except there.
- **New funds only.** Addresses are keyed to the orchestrator. Funds previously deployed directly by
  an EOA cannot be retro-extended through this path; every fund using it must enter via the
  orchestrator from the start.

## Supported networks

A chain qualifies only when **all** prerequisites exist at canonical (same-on-every-chain)
addresses: Safe v1.4.1 stack, Zodiac ModuleProxyFactory + **Roles Modifier v2.1.1 (patched —
`0xF2964CE6…83D5`)**, the canonical CREATE2 deployer (`0x4e59b448…`), the `Empty` contract
(`0xA470…4652`, or its deployer factory so it can be onboarded), and a live CCIP arbitrary-messaging
lane **from Ethereum mainnet**. Modifying `KpkOivFactory` does **not** widen this set — the limiter is
external infra, and same-address determinism only holds where that infra is canonical.

> Fees are paid in **native gas** (not LINK), so a chain no longer needs a LINK CCIP fee token to be
> wired. The `LINK fee token` column below is retained as on-chain reference only; it is not a
> requirement. The wired set is unchanged — both excluded chains fail on the Roles v2.1.1 prerequisite.

> **Security note (Roles v2.1.1).** The factory deploys Roles Modifier *proxies* delegating to the
> patched **v2.1.1** mastercopy. v2.1.0 (`0x9646fDAD…D337`) is vulnerable to the June-2026 ERC-1271
> authorization bypass when a Safe using the CompatibilityFallbackHandler is a role member — exactly
> this architecture. A chain is wired only if v2.1.1 is present on it.

The per-chain data lives in the machine-readable registry **`script/ccip-networks.json`** — the
operator reference, and the input `script/deploy-chain.sh` reads for verdict gating and chain-name
resolution. Note it is **not** read by the Solidity scripts at runtime: the per-chain scripts in
`script/chains/` hardcode the `CCIP_ROUTER`/`LINK_TOKEN` constants, which must be kept in sync with
the registry (editing the JSON alone does not change what gets deployed). Every `linkToken` was
resolved **on-chain** from each chain's
CCIP `onRamp → feeQuoter.getFeeTokens()` and confirmed via `symbol() == "LINK"` (Avalanche: `LINK.e`,
bridged). The **21 wired chains** below are the verified target set; the two `NOT-READY` rows are
excluded. Sorted by chain ID:

| Chain | Chain ID | CCIP chain selector | LINK fee token (on-chain) | Verdict |
|---|---|---|---|---|
| Ethereum | 1 | `5009297550715157269` | `0x5149…986CA` | READY |
| Optimism | 10 | `3734403246176062136` | `0x350a…a7f6` | READY |
| BNB Smart Chain | 56 | `11344663589394136015` | `0x4044…BB75` | READY-AFTER-EMPTY |
| Gnosis | 100 | `465200170687744372` | `0xE2e7…09b2` | READY |
| Unichain | 130 | `1923510103922296319` | `0xEF66…8A1A` | READY-AFTER-EMPTY |
| Polygon PoS | 137 | `4051577828743386545` | `0xb089…E0F1` | READY-AFTER-EMPTY |
| Sonic | 146 | `1673871237479749969` | `0x7105…018F` | READY-AFTER-EMPTY |
| World Chain | 480 | `2049429975587534727` | `0x915b…5473` | READY-AFTER-EMPTY |
| HyperEVM | 999 | `2442541497099098535` | `0x1AC2…De59` | READY-AFTER-EMPTY |
| Sei | 1329 | `9027416829622342829` | — | **NOT-READY** |
| Mantle | 5000 | `1556008542357238666` | `0xfe36…E043` | READY-AFTER-EMPTY |
| Base | 8453 | `15971525489660198786` | `0x88Fb…e196` | READY |
| Plasma | 9745 | `9335212494177455608` | `0x76a4…eb40` | READY-AFTER-EMPTY |
| Mode | 34443 | `7264351850409363825` | `0x183E…1F54` | **NOT-READY** |
| Arbitrum One | 42161 | `4949039107694359620` | `0xf97f…9FB4` | READY |
| Celo | 42220 | `1346049177634351622` | `0xd072…2ae0` | READY-AFTER-EMPTY |
| Avalanche | 43114 | `6433500567565415381` | `0x5947…27A3` (LINK.e) | READY-AFTER-EMPTY |
| Ink | 57073 | `3461204551265785888` | `0x7105…018F` | READY-AFTER-EMPTY |
| Linea | 59144 | `4627098889531055414` | `0x5B16…FA2d` | READY-AFTER-EMPTY |
| Bob | 60808 | `3849287863852499584` | `0x5aB8…c833` | READY-AFTER-EMPTY |
| Berachain | 80094 | `1294465214383781161` | `0x7105…018F` | READY-AFTER-EMPTY |
| Scroll | 534352 | `13204309965629103672` | `0x548C…d3Ac` | READY-AFTER-EMPTY |
| Katana | 747474 | `2459028469735686113` | `0xc2C4…27b6` | READY-AFTER-EMPTY |

**Verdict** meanings: `READY` = every prerequisite incl. `Empty` already present; `READY-AFTER-EMPTY`
= everything present and `Empty` is onboarded automatically at deploy preflight (absent on these
chains but reproducible at its canonical address — see below); `NOT-READY` = a hard blocker, not
wired. Full router + LINK addresses live in `script/ccip-networks.json`. Callers pass plain **chain
IDs** to `deployEverywhere` / `dispatchTo`; the orchestrator resolves each to its CCIP chain selector
via an owner-managed `chainSelectorOf` mapping (see below), so the selector is never hand-passed.

Excluded / not wired:

| Verdict | Chains | Why |
|---|---|---|
| **NOT-READY (no Roles v2.1.1)** | Sei, Mode | Patched Roles v2.1.1 mastercopy absent on-chain. Deploy it via the zodiac singleton factory (`0xce0042B8…`) to promote; Sei additionally exposes no LINK CCIP fee token (native-only). |
| **NEEDS-ZODIAC** | Metis, Soneium | Full Safe + CCIP, but Zodiac Roles + ModuleProxyFactory absent. |
| **NO-CCIP** | Blast, Polygon zkEVM, Flare | Safe/Zodiac present but no live CCIP lane from Ethereum. |
| **EXCLUDED** | zkSync Era | Non-EVM-bytecode-equivalent: different Safe addresses, no canonical CREATE2 deployer. |

### The `Empty` contract (READY-AFTER-EMPTY)

The factory bakes `EMPTY_CONTRACT = 0xA470…4652` in as a constant (the Avatar Safe's sole signer), so
every chain must host `Empty` at exactly that address. It was originally deployed via the CREATE2
helper factory `0x7cbB62…CFAa4` (present on every wired chain); replaying that fixed creation call
reproduces the same address regardless of caller (verified caller-independent on a fork). The deploy
tooling does this automatically as a **preflight** — `script/DeployEmpty.s.sol` standalone, or inlined
in the per-chain scripts and the runner.

### Onboarding / deploying a chain (tooling)

Use the config-driven runner (reads `script/ccip-networks.json`):

```bash
source .env && script/deploy-chain.sh <chain>      # e.g. polygon — Empty → factory → orchestrator
source .env && script/deploy-all.sh                # every wired chain, then prints the fan-out cmd
```

Or run the per-chain Solidity script directly (`script/chains/Deploy_<Chain>.s.sol`). Both perform,
in one broadcast: `Empty` preflight → `MultiSendUnwrapper` → `KpkOivFactory` → the `KpkShares` and
`TimelockController` mastercopies (the latter's initializer claimed immediately — **best effort, not
a guarantee**: the CREATE2 and the `initialize` are separate broadcast transactions, so a searcher
can claim the published address in between, after which the claim reverts and a re-run reports
`[SKIP]`. The post-flight assertions catch a claimer who gave themselves a delay or open execution;
they do **not** catch one who claimed it inert while holding `PROPOSER_ROLE`. Closing this properly
means a wrapper whose constructor calls `_disableInitializers()`, which moves the mastercopy address
and every timelock address with it — a rollout-scale change. Clones are unaffected either way, since
each has its own storage; what is at stake is a kpk-published address under a stranger's control)
→ `KpkTimelockDeployer` → wire both into the factory → `CcipOivDeployer` + `configure`. To onboard a brand-new chain not yet in the registry: confirm the prerequisites on-chain
(Safe stack, Roles v2.1.1, ModuleProxyFactory, CREATE2 deployer, CCIP router + LINK fee token,
`Empty` helper factory), add a verified row to `script/ccip-networks.json`, generate its
`script/chains/Deploy_*` script, and add its RPC alias to `foundry.toml` + `.env.sample`.

## Deploying the orchestrator

Deploy at the same address on every chain via `script/DeployCcipOivDeployer.s.sol`, then wire each
chain's CCIP config. **Verify the router/LINK/selector values against the
[CCIP directory](https://docs.chain.link/ccip/directory/mainnet) immediately before broadcasting** —
the script takes them as arguments precisely so no unverified infra is hard-coded. The
machine-readable reference of published router / LINK / selector values per chain is
`script/ccip-networks.json`.

```bash
source .env && forge script script/DeployCcipOivDeployer.s.sol:DeployCcipOivDeployer \
  --rpc-url base \
  --account $DEPLOYER_NAME \
  --broadcast \
  --sig "run(address,address,address,address,address)" \
  <eoaOwner> <finalOwner> <factory> <ccipRouter> <linkToken>
```

There is no trusted-source argument any more. The orchestrator accepts a message from any chain in
its registry, and that registry is baked in at construction.

### Destination chain registry ("selected chains")

Callers target chains by **chain ID**; the origin chain's orchestrator resolves each id to its CCIP selector
via an owner-managed, **enumerable** registry:

- `setChainSelector(chainId, ccipChainSelector)` / `setChainSelectors(chainIds[], selectors[])` — owner
  adds or corrects entries (e.g. a selector migration, or a newly-wired chain).
- `removeChainSelector(chainId)` — owner removes a chain.
- `getChainIds()` / `getChainIdCount()` — read the current selected set (e.g. on a block explorer).

The set defines the "selected chains" the no-array `deployEverywhere(config, gasLimit)` fans out to.
An unmapped chain id reverts `UnknownChain(chainId)`, so a fund can never be dispatched to a chain the
owner hasn't approved.

## Usage — from a block explorer (no script needed)

Everything is a direct contract call on the orchestrator of whichever wired chain you originate
from; no Foundry script is required.

1. Deploy + configure the orchestrator on the origin and all target chains (above), and ensure
   `EMPTY_CONTRACT` is present on every target chain.
2. Nothing to seed. The orchestrator bakes the `chainId → CCIP selector` registry into its
   CONSTRUCTOR, so a freshly deployed instance already knows every wired chain — confirm with
   **Read** `getChainIds()`. Calling `setChainSelectors` afterwards is redundant, not dangerous:
   the repo helper `CcipDeployEverywhere.setChainSelectors(address,string)` filters
   `script/ccip-networks.json` through
   `_seedable`, which rejects rows marked `excluded: true`, so `bob` and `katana` are never emitted
   — pinned by `test/SelectorSeedScope.t.sol`. What IS dangerous is supplying an unfiltered array
   by hand: adding those two makes the no-array `deployEverywhere` spend non-refundable fees on two
   dead lanes. An earlier version of this step attributed that hazard to the helper itself.
3. **Anyone**: **Read** `quoteDeployEverywhere(config, sharesChains, gasLimit)` to get the total
   native fee.
4. **Anyone**: **Write** `deployEverywhere(config, sharesChains, gasLimit)` — set the call's payable
   value (ETH) to the quoted fee (a little extra is fine; surplus is refunded). This deploys the
   origin chain's part of the fund — full OIV if the origin appears in `sharesChains`, stack only if
   not — and fans the stack out to every wired chain in one transaction. To target only a subset, add
   an explicit chain-ID array: `deployEverywhere(config, sharesChains, destChainIds, gasLimit)`.

   **Pass the topology explicitly, as above.** The two-argument sugar
   `deployEverywhere(config, gasLimit)` does NOT read a topology — it CONSTRUCTS one naming this
   chain as the sole shares chain (`_localTopology`). That is a different fund: the topology is
   salt-bound, so the sugar lands a different salt and a different address set than the config you
   intended, and the "stack only if not" case above cannot arise through it at all. The sugar is for
   the single-shares-chain-here case and nothing else. To fill a declared shares chain, or add one later, use `deployLocal` /
   `promoteShares` on that chain — both are documented in `DEPLOYMENT.md`.
5. Watch the [CCIP Explorer](https://ccip.chain.link); manually re-execute any failed destination
   message. To add a chain later (or re-send a permanently-failed one), call `dispatchTo`.

> A Foundry script (`script/CcipDeployEverywhere.s.sol`) is still provided for CLI users — it can seed
> the registry from `ccip-networks.json` and quote+forward the fee automatically — but it is optional;
> the steps above are entirely explorer-driven.

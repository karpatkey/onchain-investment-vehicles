# Cross-Chain OIV Deployment via Chainlink CCIP

`CcipOivDeployer` lets a **single mainnet transaction** deploy a full OIV on mainnet and fan out
the matching operational stack to multiple sidechains over Chainlink CCIP — producing the **same**
Avatar Safe / Manager Safe / Roles Modifier addresses on every chain.

It is an external orchestrator: **all CCIP, fee, and router logic lives outside `KpkOivFactory`.**
The only factory change is exposing `oivToStackConfig` (a `pure` helper `deployOiv` already uses
internally); the factory's deployment logic and invariants are otherwise untouched.

## Why an orchestrator (and not CCIP inside the factory)

`KpkOivFactory` mixes `msg.sender` into every CREATE2 salt (`_deriveSalts`). Its cross-chain address
invariant therefore holds only when the **same caller** invokes the factory on every chain. A raw
CCIP integration breaks this — on the destination chain the factory's caller would be the CCIP
Router, not the original mainnet account.

`CcipOivDeployer` solves it by being the single, uniform caller of the factory on every chain.
Because it is deployed at the **same address on all chains** (deterministic CREATE2, identical
creation code), the factory observes one identical `msg.sender` everywhere, so the address invariant
is preserved without putting any CCIP logic into the factory's deployment path.

```
                          mainnet
   user ──deployEverywhere(config, [arb, base, op, gnosis])──▶ CcipOivDeployer
                                                               │
                          ┌────────────────────────────────────┤
                          ▼                                     ▼ (×N)
                 factory.deployOiv(config)            router.ccipSend(stackConfig)
                 (full OIV: stack + shares)                     │
                                                                ▼  ~15 min, async
                                            sidechain  CcipOivDeployer.ccipReceive
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
- `script/DeployKpkOivFactory.s.sol` — bump `SALT_FACTORY`/`SALT_DEPLOYER` if redeploying at a fresh
  address (the script logs the address it produces).
- `DEPLOYMENT.md` and `docs/DEPLOYED_ADDRESSES.md` — the deployed-address tables.

## Security model

`ccipReceive` accepts a message only when all three hold:

1. `msg.sender` is the configured CCIP Router.
2. `message.sourceChainSelector` is the configured Ethereum-mainnet selector.
3. The decoded source sender equals `address(this)` — i.e. the sibling orchestrator on mainnet
   (same address everywhere).

Check (3) blocks a forged message from pre-occupying the deterministic CREATE2 addresses for a salt
and griefing the legitimate deployment. `deployEverywhere` and `dispatchTo` are **permissionless** —
the caller pays the CCIP fees in **native gas** via `msg.value`, so there is no shared balance to
drain. Fund addresses are fixed by the orchestrator (the uniform factory caller) + salt + config, not
by who calls, so a permissionless caller cannot change where a fund lands. The orchestrator never
holds a privileged role on any deployed fund — the exec Roles Modifier (owned by `config.admin`)
remains the authoritative gatekeeper of Avatar Safe execution.

## Operational model (important)

- **Asynchronous, not atomic.** The mainnet tx confirms once messages are dispatched. Each sidechain
  stack materialises later (after Ethereum finality, ~15 min) when CCIP delivers to `ccipReceive`.
- **Partial failure is possible.** A destination message can fail (e.g. gas underestimate, missing
  `EMPTY_CONTRACT` on that chain). It then enters CCIP's FAILED state and can be **manually
  re-executed** within its retry window. Monitor delivery on the [CCIP Explorer](https://ccip.chain.link).
- **Recovery / add-a-chain.** `deployEverywhere` is for the first, atomic fan-out and cannot be
  re-run with the same config (the local `deployOiv` would collide on its CREATE2 addresses). To
  extend a fund to a sidechain that was not in the original set — or to send a fresh message to one
  whose prior delivery permanently failed — use **`dispatchTo(config, destChainIds, gasLimit)`**,
  which performs the CCIP fan-out only (no local OIV). Pass the SAME `config` (notably the same
  `salt`) so the stack lands at the fund's existing addresses; never re-dispatch to a chain that
  already has the stack (its message would revert on the CREATE2 collision).
- **Native fees, caller-funded.** CCIP fees are paid in the source chain's **native gas** from the
  caller's `msg.value` — the orchestrator holds no fee balance. Use
  `quoteDeployEverywhere(config, destChainIds, gasLimit)` to size the `msg.value` to send; any
  surplus is refunded to the caller. (The `CcipDeployEverywhere` script quotes and forwards this
  automatically, with a small buffer.)
- **Gas limit.** `deployStack` measures at ~1.45M gas; pass `gasLimit` of ~1.8M–2.0M. CCIP caps
  destination execution at 3M, so there is comfortable headroom. Unspent gas is **not** refunded.
- **`EMPTY_CONTRACT` precondition.** `deployStack` reverts with `EmptyContractMissing` unless the
  `Empty` contract (`0xA470…4652`) is predeployed on the target chain — ensure this first.
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
in one broadcast: `Empty` preflight → `KpkOivFactory` + `KpkSharesDeployer` → `CcipOivDeployer` +
`configure`. To onboard a brand-new chain not yet in the registry: confirm the prerequisites on-chain
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
  --sig "run(address,address,address,address,address,uint64)" \
  <eoaOwner> <finalOwner> <factory> <ccipRouter> <linkToken> 5009297550715157269
```

`mainnetSelector` (`5009297550715157269`) is the same on every chain — it identifies the trusted
*source* (Ethereum mainnet), not the chain being deployed to.

### Destination chain registry

Callers target chains by **chain ID**; the mainnet orchestrator resolves each id to its CCIP selector
via the owner-managed `chainSelectorOf` mapping:

- `setChainSelector(chainId, ccipChainSelector)` / `setChainSelectors(chainIds[], selectors[])` — owner
  adds or corrects entries (e.g. a selector migration, or a newly-wired chain).
- `removeChainSelector(chainId)` — owner removes a chain.
- Seed it from the canonical registry in one call:
  `forge script script/CcipDeployEverywhere.s.sol:CcipDeployEverywhere --rpc-url ethereum --broadcast
  --sig "setChainSelectors(address,string)" <ORCHESTRATOR> script/ccip-networks.json` (owner key).

An unmapped chain id reverts `UnknownChain(chainId)`, so a fund can never be dispatched to a chain the
owner hasn't approved.

## Usage

1. Deploy + configure the orchestrator on mainnet and all target sidechains (above).
2. Seed the mainnet orchestrator's chain registry (`setChainSelectors` from `ccip-networks.json`).
3. Size the native fee via `quoteDeployEverywhere` (no pre-funding — the caller pays from `msg.value`).
4. Ensure `EMPTY_CONTRACT` is present on every target chain.
5. From any account, call `deployEverywhere(oivConfig, destChainIds, gasLimit)` on mainnet (chain IDs,
   not selectors), sending the quoted native fee as `msg.value` (surplus is refunded).
6. Watch CCIP Explorer; manually re-execute any failed destination message.

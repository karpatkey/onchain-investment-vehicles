# OIV Fund Deployment

This repo contains the tools to deploy new OIV funds via `KpkOivFactory` without needing to write or understand Solidity.

The factory contract is already deployed at the same address on all supported chains. This tooling deploys individual funds through it.

> **Security + multi-chain update (June 2026).** New deployments use the **patched Zodiac Roles
> Modifier v2.1.1** mastercopy (`0xF2964CE6…83D5`); v2.1.0 had the June-2026 ERC-1271 authorization
> bypass. This changes `KpkOivFactory`'s CREATE2 address, so it must be **redeployed** per chain (the
> previously-published `0x0d94…d420` is the old, pre-patch build). Cross-chain deployment now covers
> **21 verified chains** — see `docs/CCIP_CROSS_CHAIN_DEPLOY.md` and the config-driven runner
> `script/deploy-chain.sh` / `script/deploy-all.sh` (single source of truth: `script/ccip-networks.json`).

---

## How it works

Deploying a fund involves three layers:

```
/deploy-oiv (Claude Code skill)
    Guides you through the configuration via conversation.
    Writes script/<fund-name>-config.json with all parameters.
            |
            v
script/DeployOiv.s.sol  (Foundry script)
    Reads the JSON config.
    Builds the Solidity structs the factory expects.
    Calls factory.deployOiv() or factory.deployStack().
            |
            v
KpkOivFactory (on-chain, already deployed)
    Deploys the fund contracts in a single transaction.
    Returns the addresses of all deployed contracts.
```

**You never need to write Solidity or encode ABI calls manually.**
The skill handles the configuration, and `DeployOiv.s.sol` handles the on-chain execution.

---

## What gets deployed

### Full OIV (`deployOiv`) — mainnet
Deploys seven contracts wired together:
- **Avatar Safe** — holds fund assets. Cannot execute transactions directly; all execution flows through the Roles Modifiers.
- **Manager Safe** — operational multisig used by fund managers.
- **execRolesModifier** — primary execution layer in front of the Avatar Safe.
- **subRolesModifier** — nested layer for automated/bot permissions.
- **managerRolesModifier** — guards actions by the Manager Safe itself.
- **kpkShares implementation** — isolated per-fund so upgrades don't affect other funds.
- **kpkShares proxy** — the fund's ERC-20 shares token. Investors hold these.

### Operational stack only (`deployStack`) — sidechains
Deploys the same five infrastructure contracts (Avatar Safe through managerRolesModifier), without the shares token. Used to extend an existing mainnet fund to additional chains.

**Cross-chain address invariant:** for the same deployer account and the same `salt`, `deployOiv` and `deployStack` produce identical Avatar Safe, Manager Safe, and Roles Modifier addresses on every chain. This means the fund has a single Avatar Safe address across all chains.

---

## Quickstart

### Prerequisites

- [Claude Code](https://claude.ai/code) installed
- Git

### Steps

1. Clone this repository and open it in Claude Code:
   ```bash
   git clone https://github.com/karpatkey/onchain-investment-vehicles
   cd onchain-investment-vehicles
   claude
   ```

2. Run the deployment skill:
   ```
   /deploy-oiv
   ```

Claude will guide you through everything else, including installing Foundry if needed.

---

## The `/deploy-oiv` skill

A Claude Code slash command that guides you step by step through a fund deployment.

### What it does

**Phase 1 — Environment setup**
- Verifies that `forge` and `cast` are installed. If not, offers to install Foundry automatically.
- Checks that the project compiles (`forge build`).
- Sets up the `.env` file with your deployer private key and RPC URLs.
- If you don't have a deployer wallet, generates one with `cast wallet new` and shows you the address to fund with gas.

**Phase 2 — Fund configuration**
Asks one question at a time, in plain language:
- Deployment type: full OIV or infrastructure only
- Which chains to deploy to
- Fund name and token symbol
- Manager Safe signers (owners) and signature threshold
- Admin address (defaults to the Security Council Safe)
- Base asset (USDC, USDT, WETH, or a custom address)
- Additional accepted assets for deposits and redemptions
- Fee structure: management fee, redemption fee, performance fee (expressed as percentages — the skill converts to basis points internally)
- Fee receiver address
- Subscription and redemption cancellation periods (in days — the skill converts to seconds)
- Deployment salt (defaults to 0)

**Phase 3 — Review and deploy**
- Generates `script/<fund-name>-config.json` with all parameters.
- Shows a human-readable summary for review.
- Calls `predict` to show the expected contract addresses before any transaction is sent.
- Offers to execute the deployment chain by chain, or generate a shell script with all commands for manual execution later.

### What the deployer account needs

- ETH (or the native token) on each chain you're deploying to, to pay for gas.
- **The deployer retains no privileged role after deployment.** All authority is transferred to the `admin` address and the Manager Safe you configure.
- **The same deployer account must be used across all chains** to ensure identical contract addresses (cross-chain determinism).

---

## Adopting a pre-existing Safe

**Read this before a fund goes live on a chain where deployment reported an existing contract.**

A fund's five operational contracts sit at addresses derived from its public config, so they are
predictable before they exist — and the factories that create them (Gnosis `SafeProxyFactory`,
Zodiac `ModuleProxyFactory`) are permissionless. Anyone can therefore create a fund's contracts
before the fund does. They cannot create *different* ones: the address is a function of the setup
data, so whoever gets there first is forced to use your configuration, with your operators as the
owners.

The factory **adopts** such a contract rather than failing. That is deliberate. Colliding instead
would let any anonymous party permanently block a fund from a chain for the cost of gas, and
recovery would mean changing the config — which moves every address the fund has, on every chain.

### What is checked, and what cannot be

Before adopting a Safe, the factory verifies its owners, threshold, exact module set, guard and
fallback handler against the configuration its address encodes, and rejects any mismatch
(`AdoptedSafeMismatch`).

Two of the three component kinds genuinely cannot have changed. The Roles Modifiers are
factory-owned with no modules, so nobody else can touch them. The Avatar Safe's only owner is the
always-reverting `Empty` contract, so no signature for it can ever exist.

**The Manager Safe is different, and the check does not fully bind it.** Its owners are your
operators' live keys, so a pre-created Manager Safe is a working multisig from the moment it exists.
A Safe answers every question through a pointer it stores to its own implementation, and its signers
can move that pointer — a supported Safe operation, with a first-party tool for it. Code behind a
moved pointer can answer every check above with exactly what the config says while behaving
differently. No on-chain check survives that, including a check of the pointer itself.

### Why this is accepted

Performing it requires threshold-many manager signatures. `OivConfig.managerSafe` already carries a
security note requiring those owners to be trusted at the same level as `admin`, because a hostile
manager quorum can damage the fund by other routes regardless. So this sits inside the trust model
the system already documents, and closing it would trade an insider risk for a denial-of-service any
stranger could mount.

**Decision recorded 2026-09-15.** Accepted knowingly, on the trade-off above, after it was found by
a security review of the adoption path.

### ⚠️ If you are building or refactoring the deployer UI — read this

**The UI can verify what the contract cannot, and it is the only layer that can.** This is the single
most important consequence of the accepted risk above, so treat it as a requirement rather than a
nice-to-have.

The contract is defeated because every question it asks the Safe is a *call*, and calls run whatever
code the Safe's `singleton` pointer designates — including code chosen by an attacker. A UI is not
limited that way: `eth_getStorageAt` is served by the node from the account's storage trie and
**executes no contract code**, so nothing can fake it.

#### The requirement

When a deployment **adopts** a component (the address already had code) rather than creating it,
surface that fact, and for the **Manager Safe** verify it as follows, in this order:

1. **`eth_getStorageAt(managerSafe, 0x0, "latest")`** → must equal the chain's canonical Safe
   singleton. For Safe v1.4.1 as wired here that is `0x41675C099F32341bf84BFc5382aF534df5C7461a`
   (`OivInfraConstants.SAFE_SINGLETON`). **This check is the one that matters** — everything else is
   only meaningful once it passes.
2. Guard slot **`0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8`**
   (`keccak256("guard_manager.guard.address")`) → must be zero.
3. Fallback-handler slot **`0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5`**
   (`keccak256("fallback_manager.handler.address")`) → must equal the configured
   `safeFallbackHandler`.
4. **Only after step 1 passes**, `getOwners()`, `getThreshold()` and `getModulesPaginated()` are
   trustworthy — the code answering them is then the genuine Safe — and should be compared against
   the fund's config.

#### Do not

- **Do not use `masterCopy()`** to check the pointer. It is a *call*, so a hostile implementation
  answers it. It will return the right value on an honest Safe and a lie on a poisoned one, which is
  the worst possible property for a check.
- **Do not rely on `getOwners()` / `getThreshold()` alone.** Same reason. They are sound *after*
  step 1 and meaningless before it.
- **Do not replicate these checks in a contract.** They cannot work there: a contract cannot read
  another account's storage, so it must call — which is precisely the hole. This is a UI/off-chain
  responsibility by construction, not by preference.

#### Scope

This applies to the **Manager Safe only**. An adopted Avatar Safe or Roles Modifier needs no such
check: the Avatar Safe's sole owner is the always-reverting `Empty`, so no signature for it can
exist, and the Roles Modifiers are factory-owned with no modules enabled, so every mutator is closed.
Surfacing "this was adopted" for those is informative; for the Manager Safe it is load-bearing.

### What this costs you, and what to do about it

Before adoption existed, a pre-created Manager Safe made deployment fail loudly. It now succeeds
quietly. That lost signal is the real cost, and it is an operational one:

- **Watch for `ComponentAdopted`.** The factory emits it whenever a component was already at its
  predicted address and was adopted rather than created, with `kind` of `"safe"` or
  `"roles-modifier"`. Index it and alert on it. It exists specifically because the fund path is
  otherwise silent — both adopt branches return early, and `OivDeployed` looks identical either way.
  (The `[SKIP]` lines printed during deployment come from the INFRASTRUCTURE scripts — `Empty`,
  MultiSendUnwrapper, the factory, the mastercopies, the orchestrator — and say nothing about a
  fund's own components.)
- On any chain where the Manager Safe already existed, **confirm before funding** that its
  implementation pointer is the canonical Safe singleton for that chain and that its owners and
  threshold match the config, using a Safe UI or explorer rather than an on-chain call.
- This applies to the Manager Safe only. An existing Avatar Safe or Roles Modifier needs no such
  check — neither can have been altered.

## `script/DeployOiv.s.sol`

A reusable Foundry script with four entry points. All four read from a JSON config file generated by the skill.

### `predict(configPath)`

Calls `KpkOivFactory.predictOivAddresses()` — a view function — without sending any transaction. Shows the expected addresses for the Avatar Safe, Manager Safe, and Roles Modifiers.

Requires `--rpc-url` pointing to a chain where the factory is deployed. Does not require `--broadcast`.

```bash
forge script script/DeployOiv.s.sol \
  --sig "predict(string)" "script/my-fund-config.json" \
  --rpc-url mainnet
```

**Note:** The `kpkShares` implementation and proxy are deployed via `CREATE2`, so their addresses are deterministic from the deployer, salt, and config. The `predict` entry point prints them, and `KpkOivFactory.predictOivAddresses()` returns them (`kpkSharesImpl` and `kpkSharesProxy`).

### `deploy(configPath)` — the multichain entry point

Deploys whichever a chain is configured for, per `.sharesChains`: the full fund on the chains listed there, the operational stack alone on every other chain. Run the **identical command on every chain** — the config decides.

`.sharesChains` is **required** by this entry point and has no default. A config that omits it would put a live shares token on every chain you ran the command against, which is the opposite of what chain selection is for; `deployOiv` and `deployStack` keep the permissive default because there you have already chosen the branch by hand. An empty `[]` is **refused**. It reads as a deliberate statement but behaves as a trap: `keyExists`
answers true for it, so it satisfies every presence check, and then every chain — including the one
meant to carry the fund — takes the stack-only branch. Those stacks are wired, so a corrected re-run
reverts `StackAlreadyDeployedHere` and the canonical addresses are gone. An earlier version of this
document suggested recovering such a fund with `promoteShares`; that is not possible. `promoteShares`
lives on `CcipOivDeployer` and calls the factory as the **orchestrator** with the topology-bound salt,
so every address it computes differs from one deployed through this script.

```bash
forge script script/DeployOiv.s.sol \
  --sig "deploy(string)" "script/my-fund-config.json" \
  --rpc-url <chain> --broadcast
```

`deployOiv` and `deployStack` remain available for a deliberate override, but `deployOiv` **refuses** to run on a chain your config left out of `.sharesChains` — deploying shares where none were intended creates a fund nobody asked for, at an address that then cannot be reused for the stack-only deployment the config did specify.

### `deployOiv(configPath)`

Calls `factory.deployOiv()`. Deploys the full fund: infrastructure + shares token. Intended for mainnet.

```bash
forge script script/DeployOiv.s.sol \
  --sig "deployOiv(string)" "script/my-fund-config.json" \
  --rpc-url mainnet \
  --broadcast
```

### `deployStack(configPath)`

Calls `factory.deployStack()`. Deploys infrastructure only (no shares token). Intended for sidechains.

```bash
forge script script/DeployOiv.s.sol \
  --sig "deployStack(string)" "script/my-fund-config.json" \
  --rpc-url arbitrum \
  --broadcast
```

### Environment variables

| Variable       | Required for                  |
|----------------|-------------------------------|
| `PRIVATE_KEY`  | All operations                |
| `MAINNET_URL`  | Mainnet deployment or predict |
| `ARBITRUM_URL` | Arbitrum deployment           |
| `BASE_URL`     | Base deployment               |
| `OP_URL`       | Optimism deployment           |
| `GNOSIS_URL`   | Gnosis deployment             |

Set these in a `.env` file at the project root (already in `.gitignore`); copy `.env.sample` as a
starting point. `foundry.toml` maps each chain-name alias (`mainnet`, `arbitrum`, `base`, `optimism`,
`gnosis`, …) to its `*_URL` variable, so the `--rpc-url <chain>` flags above resolve automatically.

---

## Config file format

Generated by the skill. Reference structure for a full OIV deployment:

```json
{
  "fundName": "kpk USD Beta Fund",
  "managerSafe": {
    "owners": ["0xAddress1", "0xAddress2", "0xAddress3"],
    "threshold": 2
  },
  "salt": "0",
  "execRolesModFinalOwner": "0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537",
  "oiv": {
    "admin": "0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537",
    "sharesParams": {
      "asset": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
      "name": "kpk USD Beta Fund",
      "symbol": "kUSDB",
      "subscriptionRequestTtl": 86400,
      "redemptionRequestTtl": 86400,
      "feeReceiver": "0xFeeReceiverAddress",
      "managementFeeRate": 200,
      "redemptionFeeRate": 100,
      "performanceFeeModule": "0x0000000000000000000000000000000000000000",
      "performanceFeeRate": 0
    },
    "additionalAssets": [
      {
        "asset": "0xdAC17F958D2ee523a2206206994597C13D831ec7",
        "canDeposit": true,
        "canRedeem": true
      }
    ]
  },
  "sidechains": ["arbitrum", "base"]
}
```
#### Multi-chain shares: the fan-out skips shares chains on purpose

`sharesChains` is **salt-bound**, so it is part of the fund's identity: the orchestrator uses it to
decide which chains run `deployOiv`, which receive stacks, and which **refuse** them.

`deployEverywhere` deploys this chain's part of the fund locally — the full OIV if this chain is in
`sharesChains`, the operational stack alone if it is not — and sends stacks to every wired chain that
does *not* carry shares. It skips the other shares chains deliberately — a stack landing on one would
permanently occupy the addresses that chain's own `deployOiv` needs. Each additional shares chain is
filled by its own call:

```bash
# on the first shares chain — local fund + stacks everywhere else
forge script script/CcipDeployEverywhere.s.sol --sig "deployEverywhere(address,string,uint256[],uint256)" \
  <orchestrator> script/my-fund.json "[10,8453]" 3000000 --rpc-url ethereum --broadcast

# on every other shares chain — local fund only, no CCIP
forge script script/CcipDeployEverywhere.s.sol --sig "deployLocal(address,string)" \
  <orchestrator> script/my-fund.json --rpc-url gnosis --broadcast
```

Ordering does not matter, and because the whole config is salt-bound the result is byte-identical
whoever pays the gas. Shares never travel over CCIP: `deployOiv` measures ~2.88M gas against a
3,000,000 destination cap on half the lanes, which one extra timelock member would erase.

> **Declare what you know; promote for the rest.** The topology is hashed into the salt, so the
> declared set is fixed at birth — but where shares can *live* is not. A chain the topology never
> declared can gain the shares token later via `promoteShares`, at the **same address** every declared
> shares chain uses, because the shares proxy's address depends only on `(factory, proxySalt, impl)`
> and never on the stack. Nothing moves.
>
> Declaring a chain up front is still preferable where you can: a declared chain is filled
> permissionlessly by `deployLocal` with the asset the topology committed to. Promotion is gated to the
> fund's `admin` or its exec timelock, because a promoted chain's asset has no such commitment and an
> open promotion would let anyone land a hostile-denominated shares token at the canonical address.
>
> Note a declared-but-undeployed chain is **not** free of consequence: it is skipped by the stack
> fan-out and refuses inbound stacks, so it is shares-or-nothing until its `deployOiv` runs. Declare
> the chains you intend to use; promote the ones you could not have known about.
>
> **Promotion does not grant the Avatar Safe's asset approvals.** That needs the factory to be an
> enabled Safe module, and re-enabling it would give a module unrestricted execution over a live,
> funded Safe. Grant them BEFORE promoting — `promoteShares` now requires a maximum allowance from the
> Avatar Safe to the shares proxy for the base asset AND every `additionalAssets` entry with
> `canRedeem`, and reverts `ApprovalNotGranted(asset)` otherwise. Approve through the exec Roles
> Modifier with a scoped `approve(sharesProxy, max)` on each. The proxy address is predictable before
> promotion, so there is no window in which the fund is subscribable but not redeemable.

#### Optional: timelocks, per-chain assets, and which chains get shares

All three blocks are optional. Omit them and a fund deploys exactly as it did before they existed.

```jsonc
{
  // Chains that get the shares token. Every other chain gets the operational stack only.
  // Omit entirely and the choice is left to whichever entry point you invoke.
  "sharesChains": [1, 100],

  "oiv": {
    // A fund uses a different base asset per chain. The override wins over
    // sharesParams.asset on the chain whose id keys it, and does not move the fund's
    // addresses on either path — but for two different reasons. Direct factory path:
    // the shares proxy address does not depend on its initialization parameters. CCIP
    // path: the orchestrator zeroes the asset before hashing its config-bound salt and
    // commits to it through `sharesChains` instead. Before that fix the CCIP path DID
    // move all seven addresses, so the same file described a different fund per chain.
    "assetOverrides": { "100": "0x2a22f9c3b484c3629090FeED35F17Ff8F88f76F0" },

    // Owns the exec Roles Modifier. Deployed on EVERY chain, at one address, so its
    // parameters must be identical everywhere — which they are, being read from here.
    "execTimelock": {
      "minDelay": 172800,
      "proposers":  ["0x…governance", "0x…superadmin"],
      "cancellers": ["0x…veto"]
    },

    // Holds DEFAULT_ADMIN_ROLE on the shares proxy INSTEAD of `oiv.admin`. Mainnet-side
    // only, and a separate instance from execTimelock.
    "sharesTimelock": {
      "minDelay": 604800,
      "proposers":  ["0x…governance", "0x…superadmin"],
      "cancellers": ["0x…veto"]
    }
  }
}
```

`minDelay` is required whenever a timelock block is present, and must be non-zero: `minDelay: 0` is the factory's "no timelock" sentinel, so a block listing proposers and cancellers but no delay — or a placeholder zero — would silently deploy no timelock at all. The reader rejects **both** the missing key and an explicit `0`. To deploy without a timelock, omit the block entirely.

`proposers` is required too, for a sharper reason: the factory deliberately imposes no floor on it, so a *missing* key defaulting to an empty list would produce a timelock that can never schedule anything, freezing whatever it governs with no recovery and no error. An explicitly empty `[]` is still accepted — zero proposers is a permitted choice, but it must be a choice. (`cancellers` may be omitted; no cancellers simply means no veto.)

**`minDelay` must be between 12 hours and 30 days** (`MIN_DELAY_FLOOR` / `MIN_DELAY_CAP`); anything
outside reverts `DelayOutOfBounds` at deploy time. The reader accepts `1`, `43199` and `2592001`
happily — they fail on-chain, mid-rollout, like the ordering rules below.

**Member arrays must be strictly ascending by address value, contain no zero and no duplicates, and `cancellers` must be disjoint from `proposers`.** `KpkTimelockDeployer` enforces all four (`MembersNotAscending`, `ZeroAddress`, `DuplicateRoleMember`), so a list written in governance-priority order reverts mid-rollout. Sort by numeric address value, not by role. The ordering is also load-bearing beyond validation: the arrays are hashed into the timelock's salt, so the same members in a different order would place the timelock at a different address on one chain while every other address still matched.

A complete worked example lives in [`script/oiv-config.example.json`](script/oiv-config.example.json), which `test/OivConfigReader.t.sol` parses on every CI run — so it cannot drift from the parser.


Fee rates are in basis points (100 bps = 1%). The skill handles the conversion from percentages automatically.

---

## Deployed factory addresses

The current **salt-v3** build, deployed at the same address on every chain via the canonical CREATE2 deployer (2026-07-24):

| Contract         | Address                                      |
|------------------|----------------------------------------------|
| `KpkOivFactory`  | `0xbafbca1804B6e46D4c54Cac0A0273F5B2A8F677F` |
| `KpkSharesDeployer` | `0xea084E763F8535CBe28759b990F963BeDf60be9a` |
| `CcipOivDeployer` | `0x6F2A3D35Ff275d6B76dB47eFB0Da1b2358daf11b` |
| `Empty` | `0xA4703438f8cc4fc2C2503a7e43935Da16BA74652` |

Deployed on 19 chains, owned by the OIV governance Safe (`owner() == Safe` verified on-chain on all 19).

> ### ⚠️ Deploy only through the addresses above
>
> Earlier factory generations are still live on-chain, and **only the salt-v3 addresses above are safe to deploy through**. The salt-v2 build predates the MultiSend unwrap-adapter fix, so **every fund deployed through it gets Roles Modifiers that reject batched `multiSend` calls** — repairable only by multisig afterwards, because ownership is handed over during the deploy. The older `0x0d94…d420` build additionally embeds the vulnerable Roles Modifier v2.1.0; `script/DeployCcipOivDeployer.s.sol` hard-refuses that one (`OivChainDeploy.LEGACY_FACTORY`, pinned by `test/FactoryAddressSync.t.sol`).
>
> Superseded addresses are intentionally not listed in this repo — it records the current infra plus the stack the live kUSD fund runs on. If you need an old generation's address, take it from git history rather than re-adding it here.

For the authoritative per-chain address / tx / block record see [`docs/DEPLOYED_ADDRESSES.md`](docs/DEPLOYED_ADDRESSES.md) and [`script/deployed-infra.json`](script/deployed-infra.json).

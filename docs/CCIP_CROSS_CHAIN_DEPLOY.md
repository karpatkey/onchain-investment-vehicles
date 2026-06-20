# Cross-Chain OIV Deployment via Chainlink CCIP

`CcipOivDeployer` lets a **single mainnet transaction** deploy a full OIV on mainnet and fan out
the matching operational stack to multiple sidechains over Chainlink CCIP — producing the **same**
Avatar Safe / Manager Safe / Roles Modifier addresses on every chain.

It is an external orchestrator: **`KpkOivFactory` is not modified.**

## Why an orchestrator (and not a factory change)

`KpkOivFactory` mixes `msg.sender` into every CREATE2 salt (`_deriveSalts`). Its cross-chain address
invariant therefore holds only when the **same caller** invokes the factory on every chain. A raw
CCIP integration breaks this — on the destination chain the factory's caller would be the CCIP
Router, not the original mainnet account.

`CcipOivDeployer` solves it by being the single, uniform caller of the factory on every chain.
Because it is deployed at the **same address on all chains** (deterministic CREATE2, identical
creation code), the factory observes one identical `msg.sender` everywhere, and the address
invariant is preserved with the audited factory left untouched.

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
every chain), and the `DEPLOYMENT.md` address table should be updated to match.

## Security model

`ccipReceive` accepts a message only when all three hold:

1. `msg.sender` is the configured CCIP Router.
2. `message.sourceChainSelector` is the configured Ethereum-mainnet selector.
3. The decoded source sender equals `address(this)` — i.e. the sibling orchestrator on mainnet
   (same address everywhere).

Check (3) blocks a forged message from pre-occupying the deterministic CREATE2 addresses for a salt
and griefing the legitimate deployment. `deployEverywhere` is `onlyOwner` because it spends the
orchestrator's pre-funded LINK. The orchestrator never holds a privileged role on any deployed
fund — the exec Roles Modifier (owned by `config.admin`) remains the authoritative gatekeeper of
Avatar Safe execution.

## Operational model (important)

- **Asynchronous, not atomic.** The mainnet tx confirms once messages are dispatched. Each sidechain
  stack materialises later (after Ethereum finality, ~15 min) when CCIP delivers to `ccipReceive`.
- **Partial failure is possible.** A destination message can fail (e.g. gas underestimate, missing
  `EMPTY_CONTRACT` on that chain). It then enters CCIP's FAILED state and can be **manually
  re-executed** within its retry window. Monitor delivery on the [CCIP Explorer](https://ccip.chain.link).
- **Recovery / add-a-chain.** `deployEverywhere` is for the first, atomic fan-out and cannot be
  re-run with the same config (the local `deployOiv` would collide on its CREATE2 addresses). To
  extend a fund to a sidechain that was not in the original set — or to send a fresh message to one
  whose prior delivery permanently failed — use **`dispatchTo(config, destSelectors, gasLimit)`**,
  which performs the CCIP fan-out only (no local OIV). Pass the SAME `config` (notably the same
  `salt`) so the stack lands at the fund's existing addresses; never re-dispatch to a chain that
  already has the stack (its message would revert on the CREATE2 collision).
- **Pre-fund LINK.** CCIP fees are paid in LINK from the orchestrator's balance. Use
  `quoteDeployEverywhere(config, destSelectors, gasLimit)` to size funding before broadcasting.
- **Gas limit.** `deployStack` measures at ~1.45M gas; pass `gasLimit` of ~1.8M–2.0M. CCIP caps
  destination execution at 3M, so there is comfortable headroom. Unspent gas is **not** refunded.
- **`EMPTY_CONTRACT` precondition.** `deployStack` reverts with `EmptyContractMissing` unless the
  `Empty` contract (`0xA470…4652`) is predeployed on the target chain — ensure this first.
- **New funds only.** Addresses are keyed to the orchestrator. Funds previously deployed directly by
  an EOA cannot be retro-extended through this path; every fund using it must enter via the
  orchestrator from the start.

## Supported networks

A chain qualifies only when **all four** prerequisites exist at canonical (same-on-every-chain)
addresses: Safe v1.4.1 stack, Zodiac ModuleProxyFactory + Roles v2 mastercopy, the canonical
CREATE2 deployer (`0x4e59b448…`), and a live CCIP arbitrary-messaging lane **from Ethereum
mainnet**. Modifying `KpkOivFactory` does **not** widen this set — the limiter is external infra,
and same-address determinism only holds where that infra is canonical.

The machine-readable registry is **`script/ccip-networks.json`** (router / LINK / selector per
chain). **23 READY mainnets** (on-chain verified):

Ethereum, Optimism, BNB Smart Chain, Gnosis, Unichain, Polygon PoS, World Chain, HyperEVM, Sei,
Sonic, Mantle, Base, Plasma, Mode, Arbitrum One, Celo, Avalanche, Ink, Linea, Bob, Berachain,
Scroll, Katana.

Near-misses and exclusions:

| Verdict | Chains | Why |
|---|---|---|
| **NEEDS-ZODIAC** | Metis, Soneium | Full Safe + CCIP, but Zodiac Roles v2 / ModuleProxyFactory absent. Deploy Zodiac (CREATE2 via the zodiac-core singleton factory → same `0x9646fDAD…` address) to promote to READY, then confirm a live CCIP lane from Ethereum. |
| **NO-CCIP** | Blast, Polygon zkEVM, Flare | Safe/Zodiac present but no live CCIP lane from Ethereum (Polygon zkEVM also lacks SafeModuleSetup). |
| **EXCLUDED** | zkSync Era | Non-EVM-bytecode-equivalent: different Safe addresses, no canonical CREATE2 deployer → same-address determinism impossible. |

> **Verify before broadcast.** Registry entries flagged `linkVerified: false` (Unichain, World
> Chain, HyperEVM, Sei, Mantle, Plasma, Mode, Ink, Bob, Berachain, Katana) have a CCIP **router**
> confirmed but their **LINK** address unconfirmed — pull it from the CCIP directory first. Also
> confirm the repo's `SAFE_PROXY_FACTORY` (`0xa6B71E26…`, the widely-deployed Safe v1.3.0 factory)
> and the Zodiac mastercopy are actually present on any chain before its first deployment.

### Onboarding a new chain

1. Confirm all four prerequisites at canonical addresses (Safe stack, Zodiac, CREATE2 deployer, CCIP
   lane). If `verdict` is NEEDS-ZODIAC, deploy Zodiac there first.
2. Predeploy the `Empty` contract (`0xA470…4652`) via the canonical CREATE2 deployer.
3. Deploy `KpkSharesDeployer` + `KpkOivFactory` (`script/DeployKpkOivFactory.s.sol`) — same address
   as every other chain.
4. Deploy + `configure` the orchestrator (`script/DeployCcipOivDeployer.s.sol`) with the chain's
   verified CCIP router / LINK.
5. Add the chain's verified row to `script/ccip-networks.json`.

## Deploying the orchestrator

Deploy at the same address on every chain via `script/DeployCcipOivDeployer.s.sol`, then wire each
chain's CCIP config. **Verify the router/LINK/selector values against the
[CCIP directory](https://docs.chain.link/ccip/directory/mainnet) immediately before broadcasting** —
the script takes them as arguments precisely so no unverified infra is hard-coded. A reference table
of published values for Mainnet / Arbitrum / Base / Optimism / Gnosis is in the script's NatSpec.

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

## Usage

1. Deploy + configure the orchestrator on mainnet and all target sidechains (above).
2. Fund the mainnet orchestrator with LINK (size via `quoteDeployEverywhere`).
3. Ensure `EMPTY_CONTRACT` is present on every target chain.
4. From the owner, call `deployEverywhere(oivConfig, destSelectors, gasLimit)` on mainnet.
5. Watch CCIP Explorer; manually re-execute any failed destination message.

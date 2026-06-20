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
- **Pre-fund LINK.** CCIP fees are paid in LINK from the orchestrator's balance. Use
  `quoteDeployEverywhere(config, destSelectors, gasLimit)` to size funding before broadcasting.
- **Gas limit.** `deployStack` measures at ~1.45M gas; pass `gasLimit` of ~1.8M–2.0M. CCIP caps
  destination execution at 3M, so there is comfortable headroom. Unspent gas is **not** refunded.
- **`EMPTY_CONTRACT` precondition.** `deployStack` reverts with `EmptyContractMissing` unless the
  `Empty` contract (`0xA470…4652`) is predeployed on the target chain — ensure this first.
- **New funds only.** Addresses are keyed to the orchestrator. Funds previously deployed directly by
  an EOA cannot be retro-extended through this path; every fund using it must enter via the
  orchestrator from the start.

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
  --sig "run(address,address,address,address,uint64)" \
  <eoaOwner> <finalOwner> <ccipRouter> <linkToken> 5009297550715157269
```

`mainnetSelector` (`5009297550715157269`) is the same on every chain — it identifies the trusted
*source* (Ethereum mainnet), not the chain being deployed to.

## Usage

1. Deploy + configure the orchestrator on mainnet and all target sidechains (above).
2. Fund the mainnet orchestrator with LINK (size via `quoteDeployEverywhere`).
3. Ensure `EMPTY_CONTRACT` is present on every target chain.
4. From the owner, call `deployEverywhere(oivConfig, destSelectors, gasLimit)` on mainnet.
5. Watch CCIP Explorer; manually re-execute any failed destination message.

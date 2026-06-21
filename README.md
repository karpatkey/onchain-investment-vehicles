# kpk On-Chain Investment Vehicles (OIVs)

Tooling and smart contracts for deploying **tokenized funds ("OIVs") entirely on-chain** — and giving each fund the **same identity (same addresses) across every supported EVM chain**.

A fund is not a single contract. It is a small stack of Safe + [Zodiac Roles](https://www.zodiac.wiki/documentation/roles-modifier) contracts plus an ERC-20 shares token, wired together. This repo provides:

- **`KpkOivFactory`** — an on-chain factory that deploys and wires a complete fund stack in **one transaction**, at deterministic addresses.
- **`CcipOivDeployer`** — a Chainlink CCIP orchestrator that, from **one mainnet transaction**, fans the operational stack out to multiple sidechains so the fund lands at the **same addresses everywhere**.
- **`kpkShares`** — the fund's ERC-20 shares token (request-based subscribe/redeem, fees, multi-asset). This is the externally-audited core; its detailed reference lives in **[docs/KpkShares.md](docs/KpkShares.md)**.

---

## The fund stack

Every fund the factory deploys is the same five-to-seven-contract stack:

```
                    ┌─────────────────────────────────────────────┐
                    │                Avatar Safe                  │  holds all fund assets;
                    │     (sole signer = Empty contract — no       │  cannot execute directly
                    │      EOA/multisig can execute directly)      │
                    └───────────────▲─────────────────────────────┘
                                    │ execTransactionFromModule
                    ┌───────────────┴───────────┐
                    │     exec Roles Modifier    │  primary execution gate (owned by admin /
                    └───────▲───────────▲────────┘  Security Council)
                            │           │
              ┌─────────────┴──┐   ┌────┴───────────────┐
              │ sub Roles Mod  │   │   Manager Safe     │  operational multisig (fund managers)
              │ (bots/automation)  │  + manager Roles Mod │
              └────────────────┘   └────────────────────┘

                    ┌─────────────────────────────────────────────┐
                    │   kpkShares (UUPS proxy) + per-fund impl     │  the ERC-20 investors hold
                    └─────────────────────────────────────────────┘
```

- **Avatar Safe** — holds the assets. Its only signer is the `Empty` contract (same address on every chain via CREATE2), so **no key can execute on it directly**; all execution must flow through the Roles Modifiers.
- **exec / sub / manager Roles Modifiers** — Zodiac Roles v2 instances that gate what can be executed, by whom, against the Avatar and Manager Safes.
- **Manager Safe** — the operators' multisig.
- **kpkShares** — the fund's shares token; investors subscribe/redeem against it. See [docs/KpkShares.md](docs/KpkShares.md).

---

## `KpkOivFactory` — one-transaction fund deployment

`KpkOivFactory` deploys and fully wires that stack via CREATE2, so the addresses are **deterministic** and reproducible across chains. Two permissionless entry points:

| Entry point | Deploys | Typical use |
|---|---|---|
| `deployOiv(config)` | the full fund: the 5-contract operational stack **+** a per-fund `kpkShares` implementation and UUPS proxy, with asset allowances and operator wiring | **mainnet** |
| `deployStack(config)` | the 5-contract operational stack only (no shares token) | **sidechains** |

Key properties:

- **Cross-chain address invariant.** For the same `(caller, salt)`, `deployOiv` and `deployStack` produce **identical** Avatar Safe / Manager Safe / Roles Modifier addresses on every EVM chain — so a fund has one Avatar Safe address everywhere. The caller is mixed into the salt to prevent front-running of deterministic addresses.
- **`oivToStackConfig(config)`** is the single source of truth for the `OivConfig → StackConfig` mapping that both `deployOiv` and off-chain orchestrators use, so sidechain addresses can't drift from mainnet.
- **`predictOivAddresses` / `predictStackAddresses`** return, read-only, the addresses a deployment would produce (including the CREATE2-derived `kpkShares` impl/proxy).
- **Trust model.** Deployment entry points are permissionless; only infrastructure setters are owner-gated, and the owner **must** be a TimelockController/governance multisig (never an EOA) — a compromised owner could backdoor future deployments.

Full reference: **[docs/KpkOivFactory.md](docs/KpkOivFactory.md)**.

---

## Cross-chain deployment via Chainlink CCIP

`CcipOivDeployer` extends a fund across chains in a single mainnet transaction, preserving the address invariant.

Because `KpkOivFactory` mixes `msg.sender` into its salts, identical addresses across chains require the **same caller** on every chain. The orchestrator is deployed at **one identical address on all chains** (deterministic CREATE2, chain-identical creation code) and is therefore the uniform factory caller everywhere — without putting any CCIP logic into the factory's deployment path.

- **`deployEverywhere(config, destSelectors, gasLimit)`** — deploys the full OIV locally (mainnet) and CCIP-sends the derived `StackConfig` to each destination chain, where the sibling orchestrator's `ccipReceive` calls `deployStack`. Result: the same Avatar/Manager/Roles addresses on every chain.
- **`dispatchTo(...)`** — CCIP-only fan-out (no local deploy) to add a fund to a new chain, or re-send after a failed delivery, without changing the salt.
- **Security.** `ccipReceive` accepts a message only from the configured router, the mainnet source chain, and a source sender equal to its own (sibling) address.
- **Fees.** Paid in LINK from the orchestrator's balance; size with `quoteDeployEverywhere`.
- **Async, not atomic.** Sidechain stacks land after Ethereum finality (~15 min); a failed CCIP message is manually re-executable.

**Supported networks:** 23 on-chain-verified mainnets where the full prerequisite stack exists at canonical addresses (Safe v1.4.1 ∩ Zodiac Roles v2 ∩ canonical CREATE2 deployer ∩ a live CCIP lane from Ethereum). The machine-readable registry is **[`script/ccip-networks.json`](script/ccip-networks.json)**.

Full reference, the supported-network table, and the new-chain onboarding checklist: **[docs/CCIP_CROSS_CHAIN_DEPLOY.md](docs/CCIP_CROSS_CHAIN_DEPLOY.md)**.

---

## `kpkShares` — the shares token

`kpkShares` is the externally-audited ERC-20 each fund issues. It implements request-based subscriptions and redemptions with operator approval, management/performance/redemption fees, multi-asset support, and a UUPS upgrade path. The optional performance fee is computed by a pluggable module (`WatermarkFee`, a high-watermark implementation).

Full reference: **[docs/KpkShares.md](docs/KpkShares.md)**.

---

## Deploying a fund

You don't need to write Solidity. The **`/deploy-oiv`** Claude Code skill walks you through configuration and writes a JSON config; the Foundry script `script/DeployOiv.s.sol` reads it and calls the factory:

- `predict(configPath)` — show the expected addresses (no transaction).
- `deployOiv(configPath)` — full fund (mainnet).
- `deployStack(configPath)` — operational stack only (sidechains).

Step-by-step guide, config format, and environment setup: **[DEPLOYMENT.md](DEPLOYMENT.md)**.

> **Note on deployed addresses.** Current production addresses are tracked in **[docs/DEPLOYED_ADDRESSES.md](docs/DEPLOYED_ADDRESSES.md)** and [DEPLOYMENT.md](DEPLOYMENT.md). The CCIP work added `oivToStackConfig` to the factory, which changes its bytecode and therefore its CREATE2 address — the factory must be **redeployed** (and the address tables updated) before the CCIP path is used. See the redeploy checklist in [docs/CCIP_CROSS_CHAIN_DEPLOY.md](docs/CCIP_CROSS_CHAIN_DEPLOY.md).

---

## Repository layout

```
src/
  KpkOivFactory.sol        on-chain factory: deployOiv / deployStack
  CcipOivDeployer.sol      Chainlink CCIP cross-chain orchestrator
  KpkSharesDeployer.sol    deploys a per-fund kpkShares implementation
  kpkShares.sol            the fund's ERC-20 shares token (audited)
  IkpkShares.sol           kpkShares interface
  FeeModules/              WatermarkFee (perf fee) + IPerfFeeModule
  interfaces/              Safe + Zodiac interfaces used by the factory
  utils/                   Empty (Avatar Safe signer), RecoverFunds
script/
  DeployOiv.s.sol          deploy a fund via the factory
  DeployKpkOivFactory.s.sol deterministic factory + deployer deployment
  DeployCcipOivDeployer.s.sol deterministic orchestrator deployment
  ccip-networks.json       CCIP router / LINK / selector registry (23 chains)
docs/
  KpkShares.md             kpkShares contract reference
  KpkOivFactory.md         factory reference
  CCIP_CROSS_CHAIN_DEPLOY.md cross-chain deployment design + networks
  DEPLOYED_ADDRESSES.md    production addresses
test/                      Foundry tests (fork-based for factory/CCIP)
```

## Build & test

```bash
forge build
forge test                                   # unit tests
forge test --fork-url $MAINNET_URL           # factory + CCIP tests run against a mainnet fork
```

The `KpkOivFactory`, `CcipOivDeployer`, and several `kpkShares` suites fork mainnet to use the canonical Safe/Zodiac infrastructure; set `MAINNET_URL` (see `.env.sample`). Coverage is summarized in [COVERAGE_REPORT.md](COVERAGE_REPORT.md).

## Security

`kpkShares` has been audited; reports are in `audit-reports/`:

- `cantina-kpk-oivs-oct-2025.pdf` — Cantina (October 2025)
- `team-omega-kpk-oivs-oct-2025.pdf` — Team Omega (October 2025)

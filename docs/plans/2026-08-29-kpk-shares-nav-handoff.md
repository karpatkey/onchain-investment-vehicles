# Handoff — KpkSharesNav (PR #45)

**Written 2026-08-29.** Everything below is pushed; nothing of value lives only on the machine that
wrote this. Safe to shut down.

---

## 1. Where things are

| | |
|---|---|
| **PR** | https://github.com/karpatkey/onchain-investment-vehicles/pull/45 — **OPEN, not merged** |
| **Branch** | `feat/kpk-shares-nav-oracle` → `main` |
| **HEAD** | `83f66ed` (8 commits, +5467/−1 across 22 files) |
| **Worktree** | `/home/sgzerbo/github-projects/onchain-investment-vehicles-feat-kpk-shares-nav-oracle` |
| **Tests** | 787 local (3 fail without an RPC — see §3), **902 in CI, 0 fail** |
| **Size** | `KpkSharesNav` 24,358 / 24,576 bytes — **218 spare** |

Design plan: `docs/plans/2026-08-28-kpk-shares-nav.md` — **read its correction banner first**; it is a
pre-implementation record and three of its claims were disproved during the work.

## 2. What this is, in one paragraph

`KpkSharesNav` is a new, standalone fund contract whose share price is derived on-chain from
karpatkey's `NAVCalculator` (`NAV / totalSupply`) instead of being passed in by an operator. It adds
NAV-registry-gated asset listing, an admin-toggleable synchronous deposit path, and removes the ±30%
price-deviation guard — which existed only to bound an operator-supplied price that no longer exists.
It is a **sibling** of `kpkShares.sol`, not a replacement: that contract is byte-frozen and live on 19
chains, so nothing pre-existing is modified.

## 3. Resuming on a fresh machine

```bash
cd /home/sgzerbo/github-projects/onchain-investment-vehicles-feat-kpk-shares-nav-oracle
git submodule update --init --recursive     # lib/ is empty in a fresh worktree; nothing builds without this
export PATH="$HOME/.foundry/bin:$PATH"      # foundry is NOT on the default PATH here
forge build --sizes                         # confirm KpkSharesNav is still under 24,576
forge test                                  # expect 787 pass / 3 fail
```

**The 3 local failures are expected and pre-existing**: `KpkOivFactory.t.sol`,
`CcipOivDeployer.t.sol` and `test/poc/MultiSendUnwrapperSurface.t.sol` all fail with
`vm.envString: MAINNET_URL not found` in `setUp()`. They are mainnet-fork suites; CI supplies the
secret and they pass there. Set `MAINNET_URL` to run them locally.

If the worktree is gone entirely, the branch is on the remote — re-create with
`git worktree add <path> feat/kpk-shares-nav-oracle`.

## 4. State of review

Two full `/fable-review` rounds have run. **19 defects found and fixed in round 1** (plus 6 more in
round 1's own fixes), **11 in round 2 — none violating an invariant.** That trajectory is the reason
for the recommendation in §6.

Gates that ran, and their honest status:

| Gate | Round 1 | Round 2 |
|---|---|---|
| Fable review plan | ✅ | ✅ verdict: **converging** |
| Vigilo security audit | ✅ | ❌ **died on the weekly Opus limit**; its 9 probes were salvaged and run manually |
| Correctness / mutation review | ✅ (agent substitute) | ⚠️ re-run on **Sonnet**, narrowed to mutation testing |
| Copilot | ✅ 4 findings | ✅ 4 more that had been **missed** in round 1 |

All 8 Copilot threads are answered and resolved. The workflow-backed reviewer the skill normally uses
is **not registered in this environment** (only `deep-research` is), so that slot was an agent with the
same brief — a substitution, not a pass. Copilot's effort level is **unknown**: it is UI-only and not
exposed by the API.

> **The Opus subagent quota was exhausted on 2026-08-29 and resets Sep 1.** If you want round 2's two
> degraded gates re-run at full strength, that is the thing to do after Sep 1 — see §6 for whether it
> is worth it.

## 5. Open items that need a human

### Decisions
1. **Off-chain monitoring in place of a price bound.** You decided the NAV calculator is trusted for
   correctness — no sanity band, no deviation cap (recorded in the contract header, `2691507`). The
   compensating control both Fable and the fee findings point to is an **alert on
   `SharePriceSettlement` deviation > N% from the prior event**. It costs no bytecode. Someone needs
   to decide whether that is acceptable at the intended TVL, and then build it.
2. **External audit, gated on TVL rather than on merge** — and scoped to include the NAV stack, which
   no review of this repo can reach.

### Pre-deployment checklist (none of these block merge; all block real money)
- [ ] **Do not enable `syncDepositsEnabled` on L1.** `getAccountNav` measured at **~14.8M gas** on
      mainnet in CI, for an account with *no* positions. A per-user deposit carrying that is half a
      block. It defaults to `false`; leave it there on mainnet.
- [ ] **Size `processRequests` batches against the block gas limit** before the first real batch —
      14.8M against 30M leaves less settlement room than "amortised over a batch" suggests.
- [ ] **Launch with `performanceFeeRate = 0`** (`script/vaults-nav.json` already does). Both round-2
      fee findings live in that subsystem; it is admin-enableable later.
- [ ] **Seed the fund through an operator-approved subscription before opening sync deposits.**
      `subscribe` refuses to bootstrap (`BootstrapRequiresOperator`), but the async path can, and the
      bootstrap branch reads no NAV at all.
- [ ] **The portfolio Safe must approve the proxy** for every redeemable asset — there is no factory
      here to do it.
- [ ] **NAV `MANAGER` is still a deployer EOA upstream.** Given the trust decision, that role is
      effectively this fund's admin. Complete the handoff to the security-council Safe.
- [ ] **Record the deployed `NavPricingLib` address** from the broadcast artifacts. It is a linked
      library baked into the implementation, needed for verification and any future re-link.
- [ ] **Re-point `script/vaults-nav.json`** at the real config. It currently carries the example vault
      with zero addresses. The NAV proxy is `0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214` — the
      superseded `0x80eD5cc6…` still answers but is abandoned.

### Accepted limitations (documented in code, no action needed — listed so nobody re-litigates)
- The performance fee is **path-dependent** (+14.3% from 8 samples vs 1) and a 1-unit `subscribe` can
  force a fee event once sync deposits are open. Inherent to share-denominated high-watermark fees in
  the unchanged `WatermarkFee`.
- The fee base excludes the receiver's *balance* but not its *escrow*, so a fee receiver with a
  redemption pending is charged on its own shares (~0.8%).
- `NavPricingLib._normalize` floors when down-scaling >8-decimal feeds — a listing-policy constraint
  for sub-cent assets.
- `_setManagementFeeRate` can mint while the NAV is unreadable (time-based, nothing mispriced).
- A failed refund (blocklisted investor) reverts a whole reject batch; the operator excludes the id.
- Previews are **pre-fee-accrual**: a `minAssetsOut` taken from `previewRedemption` is skipped when a
  fee lands in the settling batch. Pad the bound. Cannot be fixed in-contract —
  `IPerfFeeModule.calculatePerformanceFee` is non-view and that interface is shared with the frozen
  contract.

## 6. Recommendation

**Merge on the current evidence; do not run a third review round.** Round 1 found invariant-breaking
defects, round 2 found tests that did not test. That is convergence, and the residual risk has moved
out of this repo — into the NAV stack (explicitly trusted), the gas trajectory, and first-upgrade
process, none of which another read of this diff will improve.

The one thing that would change that: re-running round 2's two degraded gates at full strength after
Sep 1. If either surfaces an **invariant-violating** defect, the convergence call was wrong and a
third round is justified. Second-order findings would instead confirm it.

## 7. Gotchas that cost real time — do not rediscover these

- **`via_ir` common-subexpression-eliminates `block.timestamp`.** Two `vm.warp(block.timestamp + X)`
  calls in one test function warp to the *same* timestamp. Use `vm.getBlockTimestamp()`. This silently
  produced a "contract is broken" result that was actually a broken test.
- **Any edit to `kpkShares.sol` / `IkpkShares.sol` / `KpkSharesDeployer.sol` / `KpkOivFactory.sol` —
  NatSpec included — moves live CREATE2 addresses.** `test/FactoryAddressSync.t.sol` is the guard;
  it must stay green. This is why the new contract shares no code with the old one.
- **Subagents doing mutation testing leave `src/` mutated if they die.** Always `git diff` before
  committing. One left `Math.Rounding.Ceil` in `assetsToShares` — a silent value leak had it landed.
- **Copilot can post more than one review.** Check `pulls/N/reviews` *and* re-fetch inline threads;
  a review body saying "generated 4 comments" is not the total. Four findings were missed this way.
- **Contract size headroom is 218 bytes.** Measure before adding anything to `KpkSharesNav`. The
  biggest single saving found was dropping a `string` field (~1KB); library `internal` functions
  inline and save nothing — only `external` ones move code out.
- **This is a git worktree.** The stash stack is shared with the main checkout; never use bare
  `git stash`.

## 8. Memory

Persistent notes for this project are in
`~/.claude/projects/-home-sgzerbo-github-projects-onchain-investment-vehicles/memory/`, indexed in
`MEMORY.md`. Relevant entries: `project_kpk_shares_nav.md`, `project_nav_trust_assumption.md`,
`project_via_ir_warp_cse.md`, `project_create2_address_drift.md`.

# KpkOivFactoryV4 — round-6 review plan and residual risk

**Date:** 2026-08-31
**Commit reviewed:** `5c1e165`; fixes landed in `fb55397` and the commit adding this file.
**Question it answered:** the unified factory (`deployOiv` + `deployNavFund` + `deployStack` from one
address) is about to merge and a mispriced or hijackable fund is expensive. Where should a reviewer
look that a diff-scoped gate structurally cannot, and *how does this end*?

Plan produced by the Fable model. Every load-bearing claim below was re-verified against the code or
by probe; where a claim did not survive that check, the correction is recorded rather than the
original.

---

## The situation the plan had to reason about

`KpkOivFactoryV4` is a byte-for-byte copy of the frozen, audited `src/KpkOivFactory.sol` plus exactly
four diff hunks (verified by normalized diff): the `KpkSharesNav` import; `_validateOivConfig`
`pure` → `view`; a 7-line `AdminIsFactory` guard; and the 226-line NAV block.

That shape is what makes the review tractable and is also its trap. A gate sees 2,106 added lines and
reviews them as new code, but ~1,340 of them are audited code whose *behaviour may change purely
because of its new context*: a second entry point now drives it, it shares a salt space and a
registry namespace with a second fund type, and its module window now runs caller-supplied
calculator code that it never ran before.

## Recommendation, and why the alternatives lose

**Freeze the contract bytes. Close the residual risk with tests only.**

The round-5 HIGH lived in a fix written during round-4's review. At this point on the curve
(19 → 11 → 6 → 3 → 1 findings across rounds), edits are expected to introduce risk faster than
review discovers it. Every item left open was an external-behaviour dependency, a silent-compile
hazard, or an unexercised window — all of which a fork test pins better than new Solidity does.

Alternatives considered and rejected:

- *More on-chain assertions* — duplicates checks that already exist (`_disableFactoryAsAvatarModule`
  post-condition, `RoleHandoverFailed`), spends the 2,659-byte EIP-170 margin, and is itself new
  code, which is the class that produced the last HIGH.
- *Refactor the two validators into shared code* — destroys the "frozen bytes + 4 hunks" property
  that made this PR reviewable, for zero behavioural gain.
- *Another generative round* — the marginal find rate is now below the marginal fix-induced risk.

**Outcome: `src/` was not modified at all this round.** Only the deploy script and tests changed.

## What the plan claimed, and what verification actually found

| Claim | Verdict after probing |
|---|---|
| Same `(caller, salt)` across entry points targets the same five stack addresses; only external CREATE2 revert prevents a NAV fund adopting an existing fund's Avatar Safe | **Mechanism confirmed, outcome safe.** All three orderings revert with Zodiac `TakenAddress(address)` from `ModuleProxyFactory`, which deploys before the Safe. Not a defect. Pinned by test, because the guarantee lives in third-party bytecode and was asserted nowhere in this repo. |
| `updateAsset` flag order could be swapped invisibly | **Order is correct**; the concern is purely coverage. Confirmed the old listing test still passes under a deliberate swap while the new asymmetric-flag test fails. |
| The module window now runs caller-supplied calculator code and needs an adversarial pin | **Correct to flag; window is closed.** Vigilo proved the calculator frame is a STATICCALL (every `INavCalculator` method is `external view`), so it cannot even write its own storage. The genuinely non-static in-window frame is `_execApprove`'s call into a caller-supplied ERC-20 — closed by `nonReentrant`, and now pinned. |
| Script rerun after handover is "harmless / fails loud", deferrable | **Wrong, and fixed.** Under `forge script` each call is its own broadcast transaction, so the orphan implementation deploy *lands* and only the setter reverts. Copilot and Vigilo flagged the same path independently. |

## What is pinned now

`test/KpkOivFactoryV4.t.sol` (26 tests) and `test/poc/FactoryV4ModuleWindow.t.sol` (4 tests, adopted
from the Vigilo audit). All revert-probed against a deliberately broken subject:

- cross-entry-point salt reuse reverts, in all three orderings;
- `canDeposit` / `canRedeem` are threaded independently, and only redeemables are approved;
- an unpriceable base or additional asset aborts the deployment;
- the factory is not still an enabled Avatar Safe module afterwards;
- end to end — subscribe, then redeem paid out of the Avatar Safe through the factory-granted
  allowance (without `_grantApprovals` this fails with `ERC20: transfer amount exceeds allowance`,
  which is exactly what the superseded standalone factory would have shipped);
- the deploy script is idempotent on rerun;
- a hostile NAV calculator reaches the fund but cannot re-enter, use the module window, or write its
  own storage; a hostile ERC-20 reaches the approve frame and cannot re-enter (removing
  `nonReentrant` from `deployStack` breaks this — the guard is load-bearing, not decorative);
- a Manager Safe owner can move nothing until an admin scopes targets on the Roles Modifier.

## Residual risk — accepted, not solved

1. **The cross-entry-point address guarantee is external.** It rests on the deployed
   `ModuleProxyFactory` reverting `TakenAddress`, not on anything in this repo, and the factory
   codehash-checks `EMPTY_CONTRACT` and the MultiSends but not the module or Safe proxy factories.
   The pin measures mainnet only. If any of the 19 target chains hosts a module factory that
   overwrites instead of reverting, the pin does not transfer. *Mitigation if wanted: run that test
   against each target chain's fork, or diff the factory codehashes per chain once.*
2. **`_validateNavCalculator` never probes `getAccountNav`** (Copilot, suppressed). A calculator that
   answers `usdDecimals` but whose NAV response is missing, malformed or append-drifted is accepted,
   and `deployNavFund` is permissionless. Not fixed: the harm is self-inflicted and bounded (the
   caller's own fund cannot price; escrow stays refundable; no other fund is affected), the fix means
   editing `KpkSharesNav`, which has 103 bytes spare and was audited over five rounds, and the drift
   class is already covered by the CI mainnet fork test and the drift suite.
3. **The single-chain invariant for NAV funds is not enforceable on-chain** (Vigilo I-2). The Avatar
   Safe address is deterministic across chains by design — that is the `KpkShares` multichain
   feature. Nothing stops the same caller from later running `deployStack` with the same salt on a
   second chain and obtaining a sibling Safe at the identical address, whose assets `getAccountNav`
   would not see on the home chain. No attacker path; an operational hazard the deterministic
   addressing makes easy to hit by accident.
4. **Trusted factory owner.** `setNavImplementation` decides what every FUTURE NAV fund delegates to.
   The deploy script refuses `finalOwner == eoaOwner` so it cannot be left on a hot key.
5. **Trusted NAV calculator** — adjudicated separately and unchanged.

## Termination

Merge when the 26 V4 tests plus the 4 window PoCs are green on a fork, the untouched 72-test
`KpkOivFactoryTest` suite passes, `FactoryAddressSync` is 4/4, and `forge build --sizes` confirms V4
under 24,576. **Then stop.** The honest next step is not round 7 but a posture change: at most one
time-boxed external pass scoped to the four diff hunks and the two privilege windows, and explicit
acceptance of the residual risk above. Further generative rounds are expected to introduce risk via
fixes faster than they discover it. If a pin ever fails, fix it and review only the fix.

---
name: code-review
description: Review checklist for the on-chain investment vehicles contracts — what to look for, and the specific defect shapes that have actually shipped here.
---

# Code review

Read `.github/copilot-instructions.md` first; it has the system's invariants. This file is the
review procedure and a list of defects that have genuinely reached a PR in this repository. Each
entry is here because it was found late, not because it is theoretically possible.

## Order of work

1. **Check the claims before the code.** List every added or edited comment containing `cannot`,
   `never`, `always`, `only`, `necessarily`, `by construction`, `verbatim`, `already`, `for free`,
   `the same way`. For each, decide whether the hunk in front of you still makes it true. This has
   been the single largest category of real findings, and every instance was false in the direction
   that makes the code look safer than it is.
2. **Then check address determinism.** Does the change touch a salt, a predictor, a constructor
   argument, an import, or a compiler setting? If so, which addresses move, and is that intended?
3. **Then check the tests.** For every new rule, find the test that fails when the rule is deleted.
4. **Then correctness in the ordinary sense.**

## Defect shapes that have shipped here

**The half-applied fix.** A change is applied to one call site, one struct field, or one of two
symmetric paths. Look for: a validation added to `deployOiv` but not `deployShares`; a field added
to a salt in the factory but not the orchestrator; a deploy path changed without its predictor.

**The comment that outlived its code.** Deleting a setter and leaving its NatSpec; adding a
replacement paragraph and leaving the stale one directly above it; a doc instructing operators to
call a function that no longer exists. Sweep with `git grep`, and include `docs/` — the onboarding
order and the pinned addresses both live there, and a fix applied to one doc and not its sibling is
the most common way this class survives review.

**The vacuous test.** Shapes seen repeatedly:
- `assertGt(logs.length, 0)` instead of decoding the event payload.
- A bare `vm.expectRevert()` that keeps passing after the revert it targeted is removed — a correct
  cleanup silently invalidates a correct probe.
- A rule with no test in its failing direction. One ordering rule landed and 961 tests passed on the
  first run; it could have been deleted with nothing going red.
- A test asserting only that things are *ignored*. It cannot fail when everything is ignored, so it
  needs a sibling asserting that the live fields still bind.

**Memory-struct aliasing in tests.** `b = a` on two memory structs copies the **pointer**, so
mutating `b` mutates `a`. A forged-payload test built this way compares a payload against itself and
fails with "next call did not revert", which reads exactly like the fix not working. Decode or build
independently.

**Cost claims nobody measured.** "Collapses O(n²) to O(n), which matters for the gas budget" was
false here — 190 comparisons at n=20 sits inside the measurement noise. A gas or byte claim in a
comment should carry a number and a date, or be deleted.

**Stale measurements.** Byte margins, gas figures and the CCIP frame size appear in comments. When a
change moves them, refresh them; when it does not, say which run they came from.

## Specific things to verify

- **Salt membership.** For each field added to or removed from a salt: is it read at deploy time? Is
  it overwritten downstream? Can it legitimately differ per chain? The three answers decide whether
  it belongs.
- **Predictor parity.** `predictOivAddresses` / `predictStackAddresses` / `predictOiv` must refuse
  everything the deploy path refuses. A source-side pre-check that is laxer than the destination
  burns non-refundable fees.
- **CCIP destination budget.** Anything on `ccipReceive`'s happy path is measured against a hard
  3,000,000 gas cap. Work placed in the `catch` branch is free; work before the `try` is not.
- **EIP-170.** Quote the `KpkOivFactoryHarness` row from `forge build --sizes`, not the factory's.
- **`src/KpkTimelockDeployer.sol`.** Deployed. Any diff to it or its import graph forks the live kit
  and must be called out as such, whatever the diff is.
- **Error selectors.** `ccipReceive` re-throws by selector comparison; an out-of-gas returns empty
  data and cannot match. Check that a new absorbed error is genuinely the only one absorbed.

## Out of scope

Style, naming, gas micro-optimisations, and refactors — unless the PR asks for them. Accepting a bad
suggestion in a contract that cannot be upgraded is worse than declining a good one.

Two decisions are settled and should not be re-raised: adopting a pre-existing Manager Safe cannot
bind a malicious quorum (accepted 2026-09-15, documented not fixed), and the timelock proposer and
canceller lists may both be empty.

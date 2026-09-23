# Repository instructions

On-chain investment vehicles: a Foundry/Solidity system that deploys fund "stacks" — a Gnosis Safe
v1.4.1 Avatar Safe and Manager Safe, three Zodiac Roles Modifier v2.1.1 instances, an ERC-1967
`KpkShares` proxy, and OpenZeppelin `TimelockController` clones — deterministically, at the **same
addresses on every EVM chain**, optionally fanned out over Chainlink CCIP.

Almost everything unusual about this codebase follows from that one requirement. Read the rest of
this file as consequences of it.

## The constraints that actually bite

**CREATE2 determinism is the product.** A fund's addresses must be identical on all 19 wired chains.
Solidity hashes source text and compiler settings into metadata, and metadata is in the bytecode, so
**a comment-only edit moves a contract's CREATE2 address**. So does a change to anything in its
import graph, or to a global setting (`evm_version`, `optimizer_runs`, `bytecode_hash`).

- `src/KpkTimelockDeployer.sol` and `src/interfaces/IKpkTimelockDeployer.sol` are **deployed**, with
  live timelock clones governing real funds. Do not edit them, including comments, without treating
  it as a deliberate decision to fork the deployed kit. `test/DeployedKitSync.t.sol` forks mainnet and
  fails when you do.
- `KpkOivFactory` and `CcipOivDeployer` are not yet deployed and are free to move; their pinned
  addresses in `script/DeployOiv.s.sol`, `test/FactoryAddressSync.t.sol` and
  `docs/DEPLOYED_ADDRESSES.md` are re-derived after a change, not defended.

**EIP-170 (24,576 B) is a live budget, not a theoretical one.** `KpkOivFactoryHarness` sits ~227
bytes above `KpkOivFactory`, so **the harness row is the binding constraint** — read margins off
`forge build --sizes` for the harness, not the factory. Suggestions that add code need a byte cost.

**Predict/deploy parity.** Every deployment path has a predictor (`predictOivAddresses`,
`predictStackAddresses`, `predictOiv`). `CcipOivDeployer` uses prediction as its source-chain
pre-check, so a validation that exists in the deploy path but not the predictor spends every lane's
**non-refundable** CCIP fee and then reverts on arrival. Any change to one must be mirrored in the
other.

**Salt binding.** A field hashed into a fund's salt decides its addresses. Two rules pull in opposite
directions and both matter:
- A field that is *read* and security-relevant must be bound, or someone can land the fund's
  canonical addresses with different economics or governance.
- A field that is *overwritten or never read* must NOT be bound, or two configs that deploy a
  byte-identical fund land on different addresses.
- A field that legitimately differs per chain (the base asset) must be excluded, or the
  same-address-everywhere invariant breaks.

**Address-bearing arrays must be canonical.** `managerSafe.owners` and the timelock role arrays are
hashed into CREATE2 salts, so `[A,B]` and `[B,A]` produce different contracts from the same signer
set. Both are required strictly ascending.

## Repo mechanics worth knowing

- `docs/` is listed in `.gitignore` but the files are **tracked**. Plain `grep -r` silently skips it;
  use `git grep` for any sweep, and `git add -f` to stage a doc change.
- `via_ir` common-subexpression-eliminates `block.timestamp`, so two `vm.warp(block.timestamp + X)`
  calls in one test warp to the **same** time. Use `vm.getBlockTimestamp()`.
- The Avatar Safe's sole signer is the always-reverting `Empty` contract — no key executes on it.
  Execution goes through the exec Roles Modifier.
- CCIP destinations have a hard 3,000,000-gas cap, exact on half the lanes. Anything added to
  `ccipReceive`'s happy path is measured against it by `test/poc/CcipDestinationBudget.t.sol`.
- Foundry lives at `~/.foundry/bin`.

## What good review comments look like here

Rank by whether the issue can reach a deployed fund's money or addresses:

1. **Correctness against the invariants above** — a salt that binds the wrong set, a validation
   missing from a predictor, an address-bearing field left uncanonicalised, an assumption that a
   config field cannot differ across chains.
2. **Prose that is false.** This repo's comments carry load-bearing security claims, and the dominant
   defect found in review after review is a comment that states the opposite of what the code now
   does — always in the reassuring direction. Treat `cannot`, `never`, `always`, `necessarily`, `by
   construction`, `already` and `for free` as claims to check against the hunk, not as documentation.
3. **Tests that cannot fail.** A guard with no negative control, an `expectRevert` that would pass
   for the wrong reason, an assertion like `assertGt(logs.length, 0)`. A new rule with no test in its
   *failing* direction is the common shape.

Do **not** report gas micro-optimisations, style, or refactors unless asked. Do not propose changes
to `src/KpkTimelockDeployer.sol` without acknowledging the fork cost.

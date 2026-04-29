# KpkOivFactory — Production Deployment Addresses

Production deployment of `KpkOivFactory` and `KpkSharesDeployer` via the canonical CREATE2 deployer (`0x4e59b44847b379578588920cA78FbF26c0B4956C`). Both contracts deploy at identical addresses on every EVM chain by construction (same canonical deployer, same salt, same constructor args).

Source of truth: each chain's commit on this branch lists addresses, broadcast tx hashes, and explorer links. Once all chains are merged, this doc reflects the final state.

---

## Common (CREATE2 — same address on every chain)

These two contracts have identical bytecode + constructor arguments on every chain, so CREATE2 places them at the same address everywhere.

| Component | Address |
|---|---|
| `KpkOivFactory` | _pending_ |
| `KpkSharesDeployer` | _pending_ |

The salt scheme: `keccak256(abi.encodePacked("KpkOivFactory", uint256(1)))` and `keccak256(abi.encodePacked("KpkSharesDeployer", uint256(1)))`. Bump the version uint to redeploy at a fresh address (e.g. after a constructor or bytecode change).

---

## Roles (final state on every factory, post-deploy handoff)

| Role | Holder | Type |
|---|---|---|
| `Ownable.owner` (final) | `0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537` | OIV Safe (5/N threshold, same address on every chain) |
| Deployer EOA (post-handoff) | `0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72` | EOA — holds **no** privileged role on any factory after `transferOwnership` lands. |

The deploy flow is per-chain via `script/DeployKpkOivFactory.s.sol` and matches the NAV v2 pattern: factory + deployer deployed via canonical CREATE2 deployer with the EOA as initial owner, then `setKpkSharesDeployer` wires the deployer in, then `transferOwnership` hands the factory to the OIV Safe.

---

## Per-chain status

| Chain | ID | Status |
|---|---|---|
| Ethereum Mainnet | 1 | ⏳ pending |
| Optimism | 10 | ⏳ pending |
| Gnosis | 100 | ⏳ pending |
| Base | 8453 | ⏳ pending |
| Arbitrum | 42161 | ⏳ pending |

Each per-chain entry below is filled in as the deploy lands on that chain.

### Ethereum Mainnet (chainId `1`)

_pending_

### Optimism (chainId `10`)

_pending_

### Gnosis Chain (chainId `100`)

_pending_

### Base (chainId `8453`)

_pending_

### Arbitrum One (chainId `42161`)

_pending_

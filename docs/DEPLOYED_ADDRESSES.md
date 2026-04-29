# KpkOivFactory — Production Deployment Addresses

Production deployment of `KpkOivFactory` and `KpkSharesDeployer` via the canonical CREATE2 deployer (`0x4e59b44847b379578588920cA78FbF26c0B4956C`). Both contracts deploy at identical addresses on every EVM chain by construction (same canonical deployer, same salt, same constructor args).

Source of truth: each chain's commit on this branch lists addresses, broadcast tx hashes, and explorer links. Once all chains are merged, this doc reflects the final state.

---

## Common (CREATE2 — same address on every chain)

These two contracts have identical bytecode + constructor arguments on every chain, so CREATE2 places them at the same address everywhere.

| Component | Address |
|---|---|
| `KpkOivFactory` | `0x0d94255fdE65D302616b02A2F070CdB21190d420` |
| `KpkSharesDeployer` | `0xA4B485Efe30F2b1D277b7A2279310239B26775F0` |

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
| Gnosis | 100 | ✅ deployed |
| Base | 8453 | ⏳ pending |
| Arbitrum | 42161 | ⏳ pending |

Each per-chain entry below is filled in as the deploy lands on that chain.

### Ethereum Mainnet (chainId `1`)

_pending_

### Optimism (chainId `10`)

_pending_

### Gnosis Chain (chainId `100`)

| Component | Address |
|---|---|
| `KpkOivFactory` | [`0x0d94255fdE65D302616b02A2F070CdB21190d420`](https://gnosisscan.io/address/0x0d94255fdE65D302616b02A2F070CdB21190d420) |
| `KpkSharesDeployer` | [`0xA4B485Efe30F2b1D277b7A2279310239B26775F0`](https://gnosisscan.io/address/0xA4B485Efe30F2b1D277b7A2279310239B26775F0) |
| Owner (final) | [`0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537`](https://gnosisscan.io/address/0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537) (OIV Safe) |

Deployed in block [`45925261`](https://gnosisscan.io/block/45925261). Transactions:

| Step | Tx hash |
|---|---|
| Factory CREATE2 deploy | [`0x1caecc6f743ea12273606867ef2e02f0e598c9c21b99bca4d2b69b2ae62074ab`](https://gnosisscan.io/tx/0x1caecc6f743ea12273606867ef2e02f0e598c9c21b99bca4d2b69b2ae62074ab) |
| Deployer CREATE2 deploy | [`0x8e1419239e8256d5a0899272850057a9374a47bb5dd7a1a3a76b7afed2cab5f7`](https://gnosisscan.io/tx/0x8e1419239e8256d5a0899272850057a9374a47bb5dd7a1a3a76b7afed2cab5f7) |
| `setKpkSharesDeployer` | [`0x535754b20a4c0b444eb51d310e550f9ba6b396224588beef73fe05416c9a0786`](https://gnosisscan.io/tx/0x535754b20a4c0b444eb51d310e550f9ba6b396224588beef73fe05416c9a0786) |
| `transferOwnership` → OIV Safe | [`0x7640681a925d69cc3a8f54d8114ff89a7d8d4ac0607c0fe539d3ffb886eec01b`](https://gnosisscan.io/tx/0x7640681a925d69cc3a8f54d8114ff89a7d8d4ac0607c0fe539d3ffb886eec01b) |

Independent on-chain verification (post-deploy):
- `factory.owner()` = OIV Safe ✓
- `factory.kpkSharesDeployer()` = `0xA4B485Ef...75F0` ✓
- `KpkSharesDeployer.factory()` = `0x0d94255f...d420` ✓

### Base (chainId `8453`)

_pending_

### Arbitrum One (chainId `42161`)

_pending_

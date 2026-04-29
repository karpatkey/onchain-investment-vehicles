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
| Optimism | 10 | ✅ deployed |
| Gnosis | 100 | ✅ deployed |
| Base | 8453 | ✅ deployed |
| Arbitrum | 42161 | ✅ deployed |

Each per-chain entry below is filled in as the deploy lands on that chain.

### Ethereum Mainnet (chainId `1`)

_pending_

### Optimism (chainId `10`)

| Component | Address |
|---|---|
| `KpkOivFactory` | [`0x0d94255fdE65D302616b02A2F070CdB21190d420`](https://optimistic.etherscan.io/address/0x0d94255fdE65D302616b02A2F070CdB21190d420) |
| `KpkSharesDeployer` | [`0xA4B485Efe30F2b1D277b7A2279310239B26775F0`](https://optimistic.etherscan.io/address/0xA4B485Efe30F2b1D277b7A2279310239B26775F0) |
| Owner (final) | [`0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537`](https://optimistic.etherscan.io/address/0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537) (OIV Safe) |

Deployed in block [`150953232`](https://optimistic.etherscan.io/block/150953232). Transactions:

| Step | Tx hash |
|---|---|
| Factory CREATE2 deploy | [`0x3c8b951ccfac37199811b401ac43067e220d281e4d517c69a20f31a1829ec845`](https://optimistic.etherscan.io/tx/0x3c8b951ccfac37199811b401ac43067e220d281e4d517c69a20f31a1829ec845) |
| Deployer CREATE2 deploy | [`0x298c3a4310181c68a28b55ac096100ce69a95f0ebf9d429f592ab19e5c439d2d`](https://optimistic.etherscan.io/tx/0x298c3a4310181c68a28b55ac096100ce69a95f0ebf9d429f592ab19e5c439d2d) |
| `setKpkSharesDeployer` | [`0x439d7e9ce77ebbca2e3111adb7b868fde4a73cd62840a42ec4f3473de5780d1a`](https://optimistic.etherscan.io/tx/0x439d7e9ce77ebbca2e3111adb7b868fde4a73cd62840a42ec4f3473de5780d1a) |
| `transferOwnership` → OIV Safe | [`0xc19f706eaf71e207395c17170d0ee8fbe3c56662d0c3474c5f6bb56b17c6e73f`](https://optimistic.etherscan.io/tx/0xc19f706eaf71e207395c17170d0ee8fbe3c56662d0c3474c5f6bb56b17c6e73f) |

Independent on-chain verification (post-deploy):
- `factory.owner()` = OIV Safe ✓
- `factory.kpkSharesDeployer()` = `0xA4B485Ef...75F0` ✓
- `KpkSharesDeployer.factory()` = `0x0d94255f...d420` ✓

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

| Component | Address |
|---|---|
| `KpkOivFactory` | [`0x0d94255fdE65D302616b02A2F070CdB21190d420`](https://basescan.org/address/0x0d94255fdE65D302616b02A2F070CdB21190d420) |
| `KpkSharesDeployer` | [`0xA4B485Efe30F2b1D277b7A2279310239B26775F0`](https://basescan.org/address/0xA4B485Efe30F2b1D277b7A2279310239B26775F0) |
| Owner (final) | [`0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537`](https://basescan.org/address/0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537) (OIV Safe) |

Deployed in block [`45358023`](https://basescan.org/block/45358023). Transactions:

| Step | Tx hash |
|---|---|
| Factory CREATE2 deploy | [`0x21b9fd03ae9d8c2b1865464e615163e54c035e2a18cac7ad6e8891b962fc79bf`](https://basescan.org/tx/0x21b9fd03ae9d8c2b1865464e615163e54c035e2a18cac7ad6e8891b962fc79bf) |
| Deployer CREATE2 deploy | [`0x1e6c9efd6c506fa19ecdba60458285059b71bcd150e94468fe7e6d8cff93c51a`](https://basescan.org/tx/0x1e6c9efd6c506fa19ecdba60458285059b71bcd150e94468fe7e6d8cff93c51a) |
| `setKpkSharesDeployer` | [`0x1042824163532c1f44d1fcd9c09c0e24a9637ee599c0e8da486e2e510884849e`](https://basescan.org/tx/0x1042824163532c1f44d1fcd9c09c0e24a9637ee599c0e8da486e2e510884849e) |
| `transferOwnership` → OIV Safe | [`0x7bf3e24f79be3f3b19733b8e82212143d692db63d470559db0dc2ef3a6e2e237`](https://basescan.org/tx/0x7bf3e24f79be3f3b19733b8e82212143d692db63d470559db0dc2ef3a6e2e237) |

Independent on-chain verification (post-deploy):
- `factory.owner()` = OIV Safe ✓
- `factory.kpkSharesDeployer()` = `0xA4B485Ef...75F0` ✓
- `KpkSharesDeployer.factory()` = `0x0d94255f...d420` ✓

### Arbitrum One (chainId `42161`)

| Component | Address |
|---|---|
| `KpkOivFactory` | [`0x0d94255fdE65D302616b02A2F070CdB21190d420`](https://arbiscan.io/address/0x0d94255fdE65D302616b02A2F070CdB21190d420) |
| `KpkSharesDeployer` | [`0xA4B485Efe30F2b1D277b7A2279310239B26775F0`](https://arbiscan.io/address/0xA4B485Efe30F2b1D277b7A2279310239B26775F0) |
| Owner (final) | [`0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537`](https://arbiscan.io/address/0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537) (OIV Safe) |

Deployed in blocks `457733433`-`457733445` (Arbitrum sequencer split the 4 txs across 4 sequential blocks). Transactions:

| Step | Tx hash |
|---|---|
| Factory CREATE2 deploy | [`0x355ca8d5c0f8bd7cb3fb28342be0f22f30af122ec67bdbdb3439de1912e306b0`](https://arbiscan.io/tx/0x355ca8d5c0f8bd7cb3fb28342be0f22f30af122ec67bdbdb3439de1912e306b0) |
| Deployer CREATE2 deploy | [`0x8b994fbf5a133e0e8802ea5672de9e99f69bc2ea9ae6a5c6421f91ec96e83a2a`](https://arbiscan.io/tx/0x8b994fbf5a133e0e8802ea5672de9e99f69bc2ea9ae6a5c6421f91ec96e83a2a) |
| `setKpkSharesDeployer` | [`0xec16b7d01b9dc30d853ea722446d4302665e43f1dbe9586af66f070a0dbd7b12`](https://arbiscan.io/tx/0xec16b7d01b9dc30d853ea722446d4302665e43f1dbe9586af66f070a0dbd7b12) |
| `transferOwnership` → OIV Safe | [`0x36e17f7f6f5ad1aad344c5eef9c922cae400e8e0a54da3ae14a96935a0a1b5eb`](https://arbiscan.io/tx/0x36e17f7f6f5ad1aad344c5eef9c922cae400e8e0a54da3ae14a96935a0a1b5eb) |

Independent on-chain verification (post-deploy):
- `factory.owner()` = OIV Safe ✓
- `factory.kpkSharesDeployer()` = `0xA4B485Ef...75F0` ✓
- `KpkSharesDeployer.factory()` = `0x0d94255f...d420` ✓

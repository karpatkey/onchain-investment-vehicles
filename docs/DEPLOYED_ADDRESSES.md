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
| Ethereum Mainnet | 1 | ✅ deployed |
| Optimism | 10 | ✅ deployed |
| Gnosis | 100 | ✅ deployed |
| Base | 8453 | ✅ deployed |
| Arbitrum | 42161 | ✅ deployed |

Each per-chain entry below is filled in as the deploy lands on that chain.

### Ethereum Mainnet (chainId `1`)

| Component | Address |
|---|---|
| `KpkOivFactory` | [`0x0d94255fdE65D302616b02A2F070CdB21190d420`](https://etherscan.io/address/0x0d94255fdE65D302616b02A2F070CdB21190d420) |
| `KpkSharesDeployer` | [`0xA4B485Efe30F2b1D277b7A2279310239B26775F0`](https://etherscan.io/address/0xA4B485Efe30F2b1D277b7A2279310239B26775F0) |
| Owner (final) | [`0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537`](https://etherscan.io/address/0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537) (OIV Safe) |

Deployed in block [`24989059`](https://etherscan.io/block/24989059). Transactions:

| Step | Tx hash |
|---|---|
| Factory CREATE2 deploy | [`0x9fb4d24bea8f94c64e68ff32046c7e9f37584308fb15825cac43a4db5db76386`](https://etherscan.io/tx/0x9fb4d24bea8f94c64e68ff32046c7e9f37584308fb15825cac43a4db5db76386) |
| Deployer CREATE2 deploy | [`0x1711067f4b9c24219767273caa303ac0506b18b06ac17b9d0dda6d1c77c4ee0b`](https://etherscan.io/tx/0x1711067f4b9c24219767273caa303ac0506b18b06ac17b9d0dda6d1c77c4ee0b) |
| `setKpkSharesDeployer` | [`0x02c6c83007d362d099b70d95a04128770f77e06a615d46cf1a1cf87279ca695c`](https://etherscan.io/tx/0x02c6c83007d362d099b70d95a04128770f77e06a615d46cf1a1cf87279ca695c) |
| `transferOwnership` → OIV Safe | [`0xdd69ec06df380d21af75192db643d38e3aac4372f5a4384cbffa878b59d6aaa4`](https://etherscan.io/tx/0xdd69ec06df380d21af75192db643d38e3aac4372f5a4384cbffa878b59d6aaa4) |

Independent on-chain verification (post-deploy):
- `factory.owner()` = OIV Safe ✓
- `factory.kpkSharesDeployer()` = `0xA4B485Ef...75F0` ✓
- `KpkSharesDeployer.factory()` = `0x0d94255f...d420` ✓

---

# kpk USD Alpha Fund (kUSD) — first fund deployed via the factory

Deployed 2026-04-30 from caller `0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72` via:
- `KpkOivFactory.deployOiv(...)` on mainnet — deploys all 7 contracts (5-contract operational stack + KpkShares impl + KpkShares proxy).
- `KpkOivFactory.deployStack(...)` on each sidechain — deploys the 5-contract stack only. The KpkShares fund lives on mainnet; sidechains hold bridged portfolio assets in the matching Avatar Safe.

Salt: `uint256(keccak256("kpk-USD-Alpha-Fund-prod-v1"))`. Caller is mixed into salt derivation, so re-running this deploy from any other EOA would produce different addresses.

Scripts: [`script/DeployKpkUsdProductionOiv.s.sol`](../script/DeployKpkUsdProductionOiv.s.sol) (mainnet), [`script/DeployKpkUsdProductionStack.s.sol`](../script/DeployKpkUsdProductionStack.s.sol) (sidechains).

## Common (CREATE2 — same address on every chain)

The cross-flow invariant in `KpkOivFactory` produces identical addresses for the 5-contract stack on every chain when `(caller, salt, managerSafe.owners, threshold)` match. The KpkShares impl + proxy live only on mainnet.

| Component | Address |
|---|---|
| **Avatar Safe** (portfolioSafe — holds fund assets) | [`0x38F6a1B46144fAEe6a6D9F79D8dE264C18e23848`](https://etherscan.io/address/0x38F6a1B46144fAEe6a6D9F79D8dE264C18e23848) |
| **Manager Safe** (operational multisig — holds OPERATOR + receives fees) | [`0x7Bb5e307eDf80630f153BD28789b4365eFe4cce3`](https://etherscan.io/address/0x7Bb5e307eDf80630f153BD28789b4365eFe4cce3) |
| Exec Roles Modifier | [`0xd8e63D2ca7A098E2B939BF4733e94C5768D3B966`](https://etherscan.io/address/0xd8e63D2ca7A098E2B939BF4733e94C5768D3B966) |
| Sub Roles Modifier | [`0xB15400Bb735CF9d91E09d097f2dA588ebe760D49`](https://etherscan.io/address/0xB15400Bb735CF9d91E09d097f2dA588ebe760D49) |
| Manager Roles Modifier | [`0x988A15711CCDF16C06010bb41AaEBF39e407cD7F`](https://etherscan.io/address/0x988A15711CCDF16C06010bb41AaEBF39e407cD7F) |

## Mainnet only

| Component | Address |
|---|---|
| KpkShares implementation | [`0x18b97206ca50982d51E9943ff53Cb9d8A238e939`](https://etherscan.io/address/0x18b97206ca50982d51E9943ff53Cb9d8A238e939) |
| **KpkShares UUPS proxy (the kUSD fund)** | [**`0x6D1a4C0878aD24793b1655ae1f78Cfa4522Ba765`**](https://etherscan.io/address/0x6D1a4C0878aD24793b1655ae1f78Cfa4522Ba765) |

## Configuration

| Field | Value |
|---|---|
| Base asset | USDC `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| Additional assets | USDT `0xdAC17F958D2ee523a2206206994597C13D831ec7` (canDeposit + canRedeem) |
| Subscription request TTL | 259200 s (3 days) |
| Redemption request TTL | 259200 s (3 days) |
| Management fee rate | 300 bps (3%) |
| Redemption fee rate | 150 bps (1.5%) |
| Performance fee module | `address(0)` (disabled) |
| Performance fee rate | 0 |

## Roles (post-deploy state on every chain)

| Role | Holder |
|---|---|
| `DEFAULT_ADMIN_ROLE` on KpkShares (mainnet) | Staging Sec Council Safe `0x9D73C053afcbF6CD5c8986C3f049fD2Ce005730C` (1/4) — to be transferred to the production Sec Council once policies are configured |
| `OPERATOR` on KpkShares (mainnet) | Manager Safe `0x7Bb5…cce3` (auto-wired by factory) |
| Exec Roles Modifier owner | Staging Sec Council Safe `0x9D73…730C` |
| Sub Roles Modifier owner | Manager Safe `0x7Bb5…cce3` |
| Manager Roles Modifier owner | Manager Safe `0x7Bb5…cce3` |
| Avatar Safe → KpkShares allowance (mainnet) | USDC + USDT both at `type(uint256).max` |
| Deployer EOA `0xAa5A…4F72` (post-deploy) | No role on any deployed contract — factory renounced its temporary `DEFAULT_ADMIN_ROLE` and self-disabled as Avatar Safe module before each broadcast returned |

## Manager Safe configuration

5 owners, threshold 1 (raise later as ergonomics allow):
- `0x524075B4d1C91F91F27893f4640ca980785d1e58`
- `0xAc12293749b4D9e7bb4c33608d39E089135E3521`
- `0x9F230218cf7FDe6A9246e6f8CB0b888377E92639`
- `0x4102E0743DA668EB2f55E90c96ef8EF4e621879c`
- `0xE2679499b74cCc5dfd4AA78462FB7A1D4Be386E5`

## Per-chain status

| Chain | ID | Entry point | Block | Tx hash |
|---|---|---|---|---|
| Ethereum Mainnet | 1 | `deployOiv` | [`24994108`](https://etherscan.io/block/24994108) | [`0x92787688bf6dc99ff5cb557d831fb7c26031a96c1c26a0828d9dd8535d34635e`](https://etherscan.io/tx/0x92787688bf6dc99ff5cb557d831fb7c26031a96c1c26a0828d9dd8535d34635e) |
| Optimism | 10 | `deployStack` | [`150984640`](https://optimistic.etherscan.io/block/150984640) | [`0x7e604682e009f49566d846179fe566de838c53444bbb44e82750891d494970e1`](https://optimistic.etherscan.io/tx/0x7e604682e009f49566d846179fe566de838c53444bbb44e82750891d494970e1) |
| Gnosis Chain | 100 | `deployStack` | [`45937391`](https://gnosisscan.io/block/45937391) | [`0x8b14740890a9dfca92d1d1f01fcfbd770367a220bedb8f40ace4f16f1f33a0a2`](https://gnosisscan.io/tx/0x8b14740890a9dfca92d1d1f01fcfbd770367a220bedb8f40ace4f16f1f33a0a2) |
| Base | 8453 | `deployStack` | [`45389247`](https://basescan.org/block/45389247) | [`0xa2ffe561b745fac6c0b578e88f5b1f1332e91bc5ceb93c9331b374ed0cb71e6e`](https://basescan.org/tx/0xa2ffe561b745fac6c0b578e88f5b1f1332e91bc5ceb93c9331b374ed0cb71e6e) |
| Arbitrum One | 42161 | `deployStack` | [`457981364`](https://arbiscan.io/block/457981364) | [`0xdc40da0d78a9e3ad8bf700f7490067f488432c86d9f9fc0684264b36cdfed3a0`](https://arbiscan.io/tx/0xdc40da0d78a9e3ad8bf700f7490067f488432c86d9f9fc0684264b36cdfed3a0) |

## Verification status

All 25 stack contracts (5 components × 5 chains) are auto-recognised on Etherscan v2 via similar-bytecode match against the canonical Gnosis Safe v1.4.1 singleton (`0x4167…461a`) and the Zodiac Roles Modifier mastercopy. The `KpkShares` implementation on mainnet is verified via the same standard-json bundle that was accepted for `KpkSharesDeployer`. The ERC1967Proxy at `0x6D1a…a765` is auto-tagged as a proxy pointing at the verified impl, so the kUSD address renders the audited KpkShares ABI in Read/Write-as-Proxy.

## Independent on-chain verification (post-deploy, mainnet)

```
hasRole(DEFAULT_ADMIN_ROLE, stagingSC)             = true
hasRole(OPERATOR, ManagerSafe)                     = true
hasRole(DEFAULT_ADMIN_ROLE, factory)               = false  (factory renounced)
portfolioSafe()                                    = AvatarSafe
feeReceiver()                                      = ManagerSafe
subscriptionRequestTtl()                           = 259200
redemptionRequestTtl()                             = 259200
managementFeeRate() / redemptionFeeRate()          = 300 / 150
performanceFeeRate() / performanceFeeModule()      = 0 / 0x0
USDC.allowance(AvatarSafe, KpkShares)              = uint256.max
USDT.allowance(AvatarSafe, KpkShares)              = uint256.max
AvatarSafe.isModuleEnabled(factory)                = false  (factory self-disabled)
AvatarSafe.isModuleEnabled(execRolesModifier)      = true
execRolesModifier.owner()                          = stagingSC
execRolesModifier.avatar() / target()              = AvatarSafe / AvatarSafe
subRolesModifier.owner()                           = ManagerSafe
subRolesModifier.target()                          = execRolesModifier
managerRolesModifier.owner() / avatar() / target() = ManagerSafe / ManagerSafe / ManagerSafe
```

## Phase-2 handoff (when policies are ready)

From the staging Sec Council Safe `0x9D73…730C`:

1. `execRolesModifier.transferOwnership(<prodSecCouncil>)`
2. `kpkShares.grantRole(DEFAULT_ADMIN_ROLE, <prodSecCouncil>)` — must precede revoke
3. `kpkShares.revokeRole(DEFAULT_ADMIN_ROLE, 0x9D73…730C)`

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

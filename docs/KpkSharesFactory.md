# KpkSharesFactory

`KpkSharesFactory` deploys kpk fund infrastructure in a single transaction. Only the factory owner can call either entry point.

Two entry points:

- **`deployStack`** — deploys the five-contract operational stack (two Safes + three Roles Modifiers). Intended for multichain deployments; the same `salt` on the same factory produces identical addresses on every chain.
- **`deployOiv`** — deploys the operational stack **and** a `KpkShares` UUPS proxy. Additionally grants infinite asset allowances from the Avatar Safe to the shares proxy and configures additional assets. Typically called on mainnet only.

---

## Deployment flow

The factory avoids the `SafeProxyOwner` workaround by deploying the Roles Modifiers first (with itself as temporary owner/avatar/target), embedding the modifier addresses into the Safe `setup()` delegatecall data, and only then fixing up the final configuration.

```
1. Deploy execRolesModifier    (factory = owner / avatar / target)
2. Deploy subRolesModifier     (factory = owner / avatar / target)
3. Deploy managerRolesModifier (factory = owner / avatar / target)
4. Deploy Avatar Safe          (EMPTY_CONTRACT as sole signer;
                                execRolesModifier + factory pre-enabled as modules)
5. Deploy Manager Safe         (managerRolesModifier pre-enabled as module)
6. Wire execRolesModifier      → avatar = avatarSafe, target = avatarSafe
                               → assign MANAGER role to managerSafe
                               → enable subRolesModifier as nested module
                               → assign MANAGER role + default role to subRolesModifier
                               → transfer ownership to execRolesMod.finalOwner
7. Wire subRolesModifier       → avatar = avatarSafe, target = execRolesModifier
                               → transfer ownership to managerSafe
8. Wire managerRolesModifier   → avatar = managerSafe, target = managerSafe
                               → transfer ownership to managerSafe

── deployStack stops here ──────────────────────────────────────────────────

9.  Deploy fresh KpkShares implementation via KpkSharesDeployer (one per fund)
10. Deploy KpkShares UUPS proxy (factory temporarily holds DEFAULT_ADMIN_ROLE)
                               → register additional assets (factory temporarily holds OPERATOR)
                               → grant OPERATOR to sharesOperator
                               → grant DEFAULT_ADMIN_ROLE to sharesParams.admin
                               → factory renounces DEFAULT_ADMIN_ROLE
11. Grant infinite allowance from Avatar Safe to shares proxy for:
                               → base asset (sharesParams.asset)
                               → every additional asset with canRedeem = true
12. Remove factory as module from Avatar Safe

── deployOiv stops here ───────────────────────────────────────────────────
```

### Salt derivation

A single `uint256 salt` in `StackConfig` controls all five deployment addresses. The factory derives independent per-component values by hashing the base salt with a fixed index:

| Index | Component              |
|-------|------------------------|
| 0     | `execRolesModifier`    |
| 1     | `subRolesModifier`     |
| 2     | `managerRolesModifier` |
| 3     | Avatar Safe nonce      |
| 4     | Manager Safe nonce     |

Providing the same `salt` on the same factory (same constructor arguments) on any chain produces identical addresses for all five contracts.

---

## Factory constructor parameters

Fixed at factory deployment and apply to every stack deployed through it.

| Parameter                  | Description                                              |
|----------------------------|----------------------------------------------------------|
| `owner`                    | Address allowed to call `deployStack` and `deployOiv`  |
| `safeProxyFactory`         | Gnosis `SafeProxyFactory` — deploys Safe proxies         |
| `safeSingleton`            | Gnosis Safe singleton (implementation)                   |
| `safeModuleSetup`          | Gnosis `SafeModuleSetup` — delegatecalled during `setup()` to pre-enable modules |
| `safeFallbackHandler`      | Safe fallback handler set on every deployed Safe         |
| `moduleProxyFactory`       | Zodiac `ModuleProxyFactory` — deploys Roles Modifier proxies |
| `rolesModifierMastercopy`  | Zodiac Roles Modifier mastercopy all modifiers point to  |
| `kpkSharesDeployer`        | `KpkSharesDeployer` contract — called once per `deployOiv` to produce a fresh, isolated `KpkShares` implementation |

All infrastructure addresses are owner-updatable after deployment via the corresponding `setXxx` setter functions.

---

## `deployStack` input: `StackConfig`

### Avatar Safe

The Avatar Safe is always deployed with the `EMPTY_CONTRACT` (`0xA4703438f8cc4fc2C2503a7e43935Da16BA74652`) as its sole signer. This contract has no logic and is deployed at the same address on every chain via CREATE2, making it impossible to execute transactions directly on the Avatar Safe — all execution must flow through the Roles Modifiers.

There is no `SafeConfig` for the Avatar Safe in `StackConfig`.

### `managerSafe` — `SafeConfig`

The operational Safe used by fund managers.

| Field       | Description                                             |
|-------------|---------------------------------------------------------|
| `owners`    | Signer addresses of the Manager Safe. Must be non-empty |
| `threshold` | Number of signatures required. Must be `> 0` and `<= owners.length` |

### `execRolesMod` — `RolesModifierConfig`

Primary execution layer. Sits in front of the Avatar Safe and enforces role-based transaction permissions.

| Field        | Description                                              |
|--------------|----------------------------------------------------------|
| `finalOwner` | Address that receives ownership after wiring — **must not be zero** (typically the Security Council multisig) |

### `subRolesMod` — `RolesModifierConfig`

Sub-layer Roles Modifier nested inside `execRolesModifier`. Routes calls through the exec layer, allowing finer-grained permission scoping.

| Field        | Description                                              |
|--------------|----------------------------------------------------------|
| `finalOwner` | Ignored — ownership is always transferred to `managerSafe` |

### `managerRolesMod` — `RolesModifierConfig`

Guards actions performed by the Manager Safe itself.

| Field        | Description                                              |
|--------------|----------------------------------------------------------|
| `finalOwner` | Ignored — ownership is always transferred to `managerSafe` |

### `salt` — `uint256`

Single value that determines all five deployment addresses. See [Salt derivation](#salt-derivation) above.

---

## `deployOiv` input: `OivConfig`

`OivConfig` embeds a `StackConfig stack` (all fields above) plus the following shares-specific fields.

### `sharesParams` — `KpkShares.ConstructorParams`

Initialization parameters for the `KpkShares` UUPS proxy.

| Field                    | Description                                                          |
|--------------------------|----------------------------------------------------------------------|
| `asset`                  | Base ERC20 asset. Registered with deposit and redemption enabled. The Avatar Safe grants infinite allowance to the proxy for this asset |
| `admin`                  | Address granted `DEFAULT_ADMIN_ROLE`. The factory holds it temporarily, then grants it here and renounces |
| `name`                   | ERC20 token name for the shares                                      |
| `symbol`                 | ERC20 token symbol for the shares                                    |
| `safe`                   | **Overridden by the factory** with the deployed `avatarSafe` address — any value supplied is ignored |
| `subscriptionRequestTtl` | Minimum time (seconds) before an investor can cancel a pending subscription. Capped at 7 days |
| `redemptionRequestTtl`   | Minimum time (seconds) before an investor can cancel a pending redemption. Capped at 7 days |
| `feeReceiver`            | Address receiving management fees (minted shares), redemption fees (transferred shares), and performance fees (minted shares) |
| `managementFeeRate`      | Annual management fee in basis points. Max 2000 (20%)                |
| `redemptionFeeRate`      | Per-redemption fee in basis points, deducted from shares before conversion. Max 2000 (20%) |
| `performanceFeeModule`   | Address of the performance fee module. `address(0)` to disable       |
| `performanceFeeRate`     | Performance fee in basis points. Max 2000 (20%)                      |

### `additionalAssets` — `AssetConfig[]`

Optional list of assets to enable on the shares proxy beyond the base asset. The factory temporarily holds `OPERATOR` to register each asset, then revokes it before granting `OPERATOR` to `sharesOperator`.

| Field        | Description                                                         |
|--------------|---------------------------------------------------------------------|
| `asset`      | ERC20 token address. Must not be zero                               |
| `canDeposit` | Whether the asset can be used for subscriptions                     |
| `canRedeem`  | Whether the asset can be used for redemptions. If true, the Avatar Safe also grants infinite allowance to the proxy for this asset |

---

## Post-deployment state

### Avatar Safe

| Property         | Value                                    |
|------------------|------------------------------------------|
| Signers          | `EMPTY_CONTRACT` (sole signer, fixed)    |
| Threshold        | `1`                                      |
| Enabled modules  | `execRolesModifier`                      |
| Fallback handler | `safeFallbackHandler`                    |

### Manager Safe

| Property         | Value                                    |
|------------------|------------------------------------------|
| Signers          | `managerSafe.owners`                     |
| Threshold        | `managerSafe.threshold`                  |
| Enabled modules  | `managerRolesModifier`                   |
| Fallback handler | `safeFallbackHandler`                    |

### Exec Roles Modifier

| Property                               | Value                                    |
|----------------------------------------|------------------------------------------|
| Avatar                                 | `avatarSafe`                             |
| Target                                 | `avatarSafe`                             |
| Owner                                  | `execRolesMod.finalOwner` (Security Council) |
| MANAGER role                           | Assigned to `managerSafe` and `subRolesModifier` |
| Default role of `subRolesModifier`     | `MANAGER`                                |
| Enabled modules                        | `subRolesModifier`                       |

### Sub Roles Modifier

| Property | Value                  |
|----------|------------------------|
| Avatar   | `avatarSafe`           |
| Target   | `execRolesModifier`    |
| Owner    | `managerSafe`          |

Calls routed through `subRolesModifier` are forwarded to `execRolesModifier` (not directly to `avatarSafe`), which applies its own role checks before reaching the Safe.

### Manager Roles Modifier

| Property | Value          |
|----------|----------------|
| Avatar   | `managerSafe`  |
| Target   | `managerSafe`  |
| Owner    | `managerSafe`  |

### KpkShares Proxy (`deployOiv` only)

| Property                    | Value                                                                  |
|-----------------------------|------------------------------------------------------------------------|
| Implementation              | Fresh `KpkShares` instance deployed by `KpkSharesDeployer` (one per fund — upgrades are isolated per fund) |
| `portfolioSafe`             | `avatarSafe`                                                           |
| `DEFAULT_ADMIN_ROLE`        | `sharesParams.admin`                                                   |
| `OPERATOR`                  | `managerSafe` (automatically wired — no separate input required)       |
| Base asset                  | `sharesParams.asset` — deposit + redeem enabled                        |
| Base asset allowance        | `type(uint256).max` from `avatarSafe`                                  |
| Additional assets           | Each entry in `additionalAssets` registered via `updateAsset`; assets with `canRedeem = true` also receive `type(uint256).max` allowance from `avatarSafe` |
| `subscriptionRequestTtl`    | `sharesParams.subscriptionRequestTtl`                                  |
| `redemptionRequestTtl`      | `sharesParams.redemptionRequestTtl`                                    |
| `feeReceiver`               | `sharesParams.feeReceiver`                                             |
| `managementFeeRate`         | `sharesParams.managementFeeRate`                                       |
| `redemptionFeeRate`         | `sharesParams.redemptionFeeRate`                                       |
| `performanceFeeModule`      | `sharesParams.performanceFeeModule`                                    |
| `performanceFeeRate`        | `sharesParams.performanceFeeRate`                                      |

---

## Validation rules

`deployStack` and `deployOiv` revert on invalid `StackConfig`:

- `managerSafe.owners` is empty (`EmptyOwners`)
- `managerSafe.threshold == 0` or `threshold > owners.length` (`InvalidThreshold`)
- `execRolesMod.finalOwner` is `address(0)` (`ZeroAddress`)

`deployOiv` additionally reverts if:

- `sharesParams.admin` is `address(0)` (`ZeroAddress`)
- `sharesParams.asset` is `address(0)` (`ZeroAddress`)
- Any `additionalAssets[i].asset` is `address(0)` (`ZeroAddress`)

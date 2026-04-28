# KpkSharesFactory

`KpkSharesFactory` deploys kpk fund infrastructure in a single transaction. Only the factory owner can call either entry point.

Two entry points:

- **`deployStack`** — deploys the five-contract operational stack (two Safes + three Roles Modifiers). Intended for multichain deployments; the same `salt` on the same factory produces identical addresses on every chain.
- **`deployFund`** — deploys the operational stack **and** a `KpkShares` UUPS proxy. Typically called on mainnet only.

---

## Deployment flow

The factory avoids the `SafeProxyOwner` workaround by deploying the Roles Modifiers first (with itself as temporary owner/avatar/target), embedding the modifier addresses into the Safe `setup()` delegatecall data, and only then fixing up the final configuration.

```
1. Deploy execRolesModifier    (factory = owner / avatar / target)
2. Deploy subRolesModifier     (factory = owner / avatar / target)
3. Deploy managerRolesModifier (factory = owner / avatar / target)
4. Deploy Avatar Safe          (execRolesModifier pre-enabled as module)
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

9. Deploy KpkShares proxy      (factory temporarily holds DEFAULT_ADMIN_ROLE)
                               → grant OPERATOR to sharesOperator
                               → grant DEFAULT_ADMIN_ROLE to sharesParams.admin
                               → factory renounces DEFAULT_ADMIN_ROLE

── deployFund stops here ───────────────────────────────────────────────────
```

### Salt derivation

A single `uint256 salt` in `StackConfig` controls all five deployment addresses. The factory derives independent per-component values by hashing the base salt with a fixed index:

| Index | Component            |
|-------|----------------------|
| 0     | `execRolesModifier`  |
| 1     | `subRolesModifier`   |
| 2     | `managerRolesModifier` |
| 3     | Avatar Safe nonce    |
| 4     | Manager Safe nonce   |

Providing the same `salt` on the same factory (same constructor arguments) on any chain produces identical addresses for all five contracts.

---

## Factory constructor parameters

Fixed at factory deployment and apply to every stack deployed through it.

| Parameter                  | Description                                              |
|----------------------------|----------------------------------------------------------|
| `owner`                    | Address allowed to call `deployStack` and `deployFund`  |
| `kpkSharesImpl`            | Shared `KpkShares` implementation all proxies point to   |
| `safeProxyFactory`         | Gnosis `SafeProxyFactory` — deploys Safe proxies         |
| `safeSingleton`            | Gnosis Safe singleton (implementation)                   |
| `safeModuleSetup`          | Gnosis `SafeModuleSetup` — delegatecalled during `setup()` to pre-enable modules |
| `safeFallbackHandler`      | Safe fallback handler set on every deployed Safe         |
| `moduleProxyFactory`       | Zodiac `ModuleProxyFactory` — deploys Roles Modifier proxies |
| `rolesModifierMastercopy`  | Zodiac Roles Modifier mastercopy all modifiers point to  |

---

## `deployStack` input: `StackConfig`

### `avatarSafe` — `SafeConfig`

The primary portfolio Safe. Assets held by the fund live here.

| Field      | Description                                              |
|------------|----------------------------------------------------------|
| `owners`   | Signer addresses of the Avatar Safe                      |
| `threshold`| Number of signatures required to execute a transaction  |

### `managerSafe` — `SafeConfig`

The operational Safe used by fund managers.

| Field      | Description                                              |
|------------|----------------------------------------------------------|
| `owners`   | Signer addresses of the Manager Safe                     |
| `threshold`| Number of signatures required to execute a transaction  |

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

## `deployFund` input: `FundConfig`

`FundConfig` embeds a `StackConfig stack` (all fields above) plus the following shares-specific fields.

### `sharesParams` — `KpkShares.ConstructorParams`

Initialization parameters for the `KpkShares` UUPS proxy.

| Field                    | Description                                                          |
|--------------------------|----------------------------------------------------------------------|
| `asset`                  | Base ERC20 asset. Registered as the fee-module asset (`isFeeModuleAsset = true`) with deposit and redemption enabled |
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

### `sharesOperator` — `address`

Address granted the `OPERATOR` role on the `KpkShares` proxy. The operator calls `processRequests` and `updateAsset`. Must not be zero.

---

## Post-deployment state

### Avatar Safe

| Property          | Value                                    |
|-------------------|------------------------------------------|
| Signers           | `avatarSafe.owners`                      |
| Threshold         | `avatarSafe.threshold`                   |
| Enabled modules   | `execRolesModifier`                      |
| Fallback handler  | `safeFallbackHandler`                    |

### Manager Safe

| Property          | Value                                    |
|-------------------|------------------------------------------|
| Signers           | `managerSafe.owners`                     |
| Threshold         | `managerSafe.threshold`                  |
| Enabled modules   | `managerRolesModifier`                   |
| Fallback handler  | `safeFallbackHandler`                    |

### Exec Roles Modifier

| Property          | Value                                    |
|-------------------|------------------------------------------|
| Avatar            | `avatarSafe`                             |
| Target            | `avatarSafe`                             |
| Owner             | `execRolesMod.finalOwner` (Security Council) |
| MANAGER role      | Assigned to `managerSafe` and `subRolesModifier` |
| Default role of `subRolesModifier` | `MANAGER`              |
| Enabled modules   | `subRolesModifier`                       |

### Sub Roles Modifier

| Property          | Value                                    |
|-------------------|------------------------------------------|
| Avatar            | `avatarSafe`                             |
| Target            | `execRolesModifier`                      |
| Owner             | `managerSafe`                            |

Calls routed through `subRolesModifier` are forwarded to `execRolesModifier` (not directly to `avatarSafe`), which applies its own role checks before reaching the Safe.

### Manager Roles Modifier

| Property          | Value                                    |
|-------------------|------------------------------------------|
| Avatar            | `managerSafe`                            |
| Target            | `managerSafe`                            |
| Owner             | `managerSafe`                            |

### KpkShares Proxy (`deployFund` only)

| Property                  | Value                                    |
|---------------------------|------------------------------------------|
| `portfolioSafe`           | `avatarSafe`                             |
| `DEFAULT_ADMIN_ROLE`      | `sharesParams.admin`                     |
| `OPERATOR`                | `sharesOperator`                         |
| `asset` (base)            | `sharesParams.asset` — deposit + redeem enabled, used as fee-module asset |
| `subscriptionRequestTtl`  | `sharesParams.subscriptionRequestTtl` (≤ 7 days) |
| `redemptionRequestTtl`    | `sharesParams.redemptionRequestTtl` (≤ 7 days) |
| `feeReceiver`             | `sharesParams.feeReceiver`               |
| `managementFeeRate`       | `sharesParams.managementFeeRate`         |
| `redemptionFeeRate`       | `sharesParams.redemptionFeeRate`         |
| `performanceFeeModule`    | `sharesParams.performanceFeeModule`      |
| `performanceFeeRate`      | `sharesParams.performanceFeeRate`        |
| Implementation            | `kpkSharesImpl` (shared across all factory-deployed funds) |

---

## Validation rules

Both `deployStack` and `deployFund` revert on invalid `StackConfig`:

- Either Safe has an empty `owners` array (`EmptyOwners`)
- Either Safe has `threshold == 0` or `threshold > owners.length` (`InvalidThreshold`)
- `execRolesMod.finalOwner` is `address(0)` (`ZeroAddress`)

`deployFund` additionally reverts if:

- `sharesOperator` is `address(0)` (`ZeroAddress`)
- `sharesParams.admin` is `address(0)` (`ZeroAddress`)
- `sharesParams.asset` is `address(0)` (`ZeroAddress`)

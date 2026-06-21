# OIV Fund Deployment Flow (direct, via `KpkOivFactory`)

How a **new OIV fund** is deployed through the already-deployed `KpkOivFactory`. This covers the
direct, per-chain path: `deployOiv` for the full fund (typically mainnet) and `deployStack` for the
operational stack on additional chains. For the one-transaction multichain path, see
[CCIP_FUND_DEPLOYMENT_FLOW.md](CCIP_FUND_DEPLOYMENT_FLOW.md).

> **Assumed already deployed** (same address on every supported chain): `KpkOivFactory`,
> `KpkSharesDeployer`, the `Empty` contract (Avatar Safe signer), and the canonical Safe v1.4.1 +
> Zodiac infrastructure. See [DEPLOYED_ADDRESSES.md](DEPLOYED_ADDRESSES.md). This doc is only about
> deploying a **fund** through them.

## End-to-end overview

```mermaid
flowchart TD
    A["Operator runs /deploy-oiv skill"] --> B["script/&lt;fund&gt;-config.json"]
    B --> C{"Deployment type?"}
    C -->|"Full fund (mainnet)"| D["forge script DeployOiv.s.sol --sig deployOiv(string)"]
    C -->|"Stack only (sidechain)"| E["forge script DeployOiv.s.sol --sig deployStack(string)"]
    B -.->|"preview, no tx"| P["--sig predict(string)"]
    D --> F["KpkOivFactory.deployOiv"]
    E --> G["KpkOivFactory.deployStack"]
    F --> H["7 contracts: stack + kpkShares impl & proxy"]
    G --> I["5 contracts: operational stack only"]
    P -.-> Q["prints expected addresses"]
```

The same deployer account (same `msg.sender`) and the same `salt` must be used on every chain — the
factory mixes both into its CREATE2 salts, so this is what makes the fund's Avatar Safe / Manager
Safe / Roles Modifier addresses identical across chains.

## `deployOiv` — full fund (mainnet)

```mermaid
sequenceDiagram
    autonumber
    actor Op as Operator
    participant Fg as forge (DeployOiv.s.sol)
    participant F as KpkOivFactory
    participant Z as Zodiac ModuleProxyFactory
    participant S as Safe ProxyFactory
    participant D as KpkSharesDeployer
    participant Av as Avatar Safe

    Op->>Fg: deployOiv(configPath)
    Fg->>F: deployOiv(config)
    Note over F: validate config, reserve instance id,<br/>stackConfig = oivToStackConfig(config)
    F->>Z: deploy exec / sub / manager Roles Modifiers (CREATE2)
    F->>S: create Avatar Safe (signer = Empty, modules [exec, factory])
    F->>S: create Manager Safe (owners + threshold, module [manager])
    Note over F: wire exec/sub/manager modifiers<br/>(assign roles, set avatar/target, transfer ownership)
    F->>D: deploy(implSalt) → kpkShares implementation
    F->>F: new ERC1967Proxy(impl, initialize) → shares proxy
    Note over F: register additional assets, grant OPERATOR to Manager Safe,<br/>grant admin to admin, renounce factory's own admin
    F->>Av: approve shares proxy for base + redeemable assets (via module call)
    F->>Av: disable factory module
    F-->>Fg: OivInstance (7 addresses) + emit OivDeployed
    Fg-->>Op: log deployed addresses
```

**Result — the deployed fund:**

```mermaid
flowchart TD
    subgraph Fund
        Av["Avatar Safe<br/>(holds assets; signer = Empty,<br/>no direct execution)"]
        Ex["exec Roles Modifier<br/>(owner = admin)"]
        Sub["sub Roles Modifier<br/>(automation)"]
        Mgr["Manager Safe<br/>(operators)"]
        MgrMod["manager Roles Modifier"]
        Px["kpkShares proxy<br/>(+ per-fund impl)"]
    end
    Ex -->|"execTransactionFromModule"| Av
    Sub --> Ex
    Mgr --> Ex
    MgrMod --> Mgr
    Px -->|"pulls assets on redemption<br/>(infinite allowance)"| Av
    Mgr -.->|"OPERATOR role"| Px
```

## `deployStack` — operational stack on a sidechain

Run on each additional chain with the **same deployer and same salt** so the addresses match the
mainnet fund. Identical to `deployOiv` minus the `kpkShares` token.

```mermaid
sequenceDiagram
    autonumber
    actor Op as Operator
    participant Fg as forge (DeployOiv.s.sol)
    participant F as KpkOivFactory
    participant Z as Zodiac ModuleProxyFactory
    participant S as Safe ProxyFactory
    participant Av as Avatar Safe

    Op->>Fg: deployStack(configPath)
    Fg->>F: deployStack(config)
    Note over F: validate config, reserve stack id
    F->>Z: deploy exec / sub / manager Roles Modifiers (CREATE2)
    F->>S: create Avatar Safe (signer = Empty, modules [exec, factory])
    F->>S: create Manager Safe (owners + threshold, module [manager])
    Note over F: wire all three modifiers
    F->>Av: disable factory module
    F-->>Fg: StackInstance (5 addresses) + emit StackDeployed
    Fg-->>Op: log deployed addresses
```

The five operational-stack addresses are byte-for-byte identical to those `deployOiv` produced on
mainnet for the same `(deployer, salt)`, so the fund shares one Avatar Safe address across all chains.

## Notes

- **Preview first.** `--sig "predict(string)"` calls the factory's view functions and prints the
  expected addresses (including the CREATE2-derived `kpkShares` impl/proxy) without sending a
  transaction.
- **`Empty` must be present** on the target chain, or `deployStack`/`deployOiv` revert with
  `EmptyContractMissing` (the Avatar Safe's sole signer is the `Empty` contract).
- **Deployer holds no privileged role afterwards** — authority is transferred to the configured
  `admin` (exec Roles Modifier owner + shares admin) and the Manager Safe.
- Step-by-step operator instructions and the config format are in [DEPLOYMENT.md](../DEPLOYMENT.md);
  the factory reference is in [KpkOivFactory.md](KpkOivFactory.md).

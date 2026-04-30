# /deploy-oiv — Guided OIV fund deployment

This skill walks the user through deploying a new OIV fund via `KpkOivFactory` step by step.
The factory is already deployed on all supported chains. This process deploys the fund itself.

Minimal technical context:
- `deployOiv` (mainnet): deploys the full fund infrastructure + the shares token (ERC-20).
- `deployStack` (sidechains): deploys only the operational backbone (no shares token).
- Both functions are permissionless. The deployer retains no privileged role after deployment.
- The same `salt` + same `caller` (deployer address) produces identical infrastructure addresses on every chain. This is critical for cross-chain consistency.

---

## Instructions for Claude

Follow these steps in order. Ask **one question at a time**, wait for the user's answer, and validate before continuing.
Use English in all interactions. If the user provides an invalid answer, explain the problem and ask them to correct it.

---

### PHASE 1 — Environment setup

**Step 1.1: Check Foundry**

Run `forge --version` and `cast --version`.

- If either fails: inform the user that Foundry is not installed and ask if they want to install it now.
  - If yes: run `curl -L https://foundry.paradigm.xyz | bash` and then `foundryup`. Let them know they may need to restart their terminal.
  - If no: let them know Foundry is required to continue and end the skill.
- If both are present: confirm the version and continue.

**Step 1.2: Check project dependencies**

Run `forge build` to verify the project compiles.

- If it fails with dependency errors: run `forge install` and retry.
- If it fails for another reason: show the full error and ask for manual help.
- If it compiles: continue.

**Step 1.3: Check the `.env` file**

Check if a `.env` file exists at the project root.

If it does not exist, create it empty and inform the user. Then check that `.env` is in `.gitignore`:
- If it is not: add it to `.gitignore` before continuing.

**Step 1.4: Set up the deployer private key**

Ask:

> "To deploy, you need an account with ETH to pay for gas.
> Do you already have a deployer private key, or would you like to generate a new wallet?"

**If they already have one:**
- Ask them to enter it (only to write it to `.env` — never display it).
- Write it to `.env` as `PRIVATE_KEY=0x<the_key>`.
- Show the public address: run `cast wallet address --private-key $PRIVATE_KEY`.
- Confirm that is the account that will deploy.

**If they want to generate a new one:**
- Run `cast wallet new` and capture the output.
- Write only the private key to `.env` as `PRIVATE_KEY=0x<the_key>`.
- Show the user **only the public address** with this message:
  > "Wallet generated. Deployer address: `<address>`
  > This account needs ETH on each chain you deploy to in order to pay for gas.
  > The deployer retains no privileged role after deployment — all authority transfers
  > to the admin address and Manager Safe you configure below.
  > Please fund it before continuing."
- Ask: "Have you funded the account, or do you need time to do it?"
  - If they need time: let them know they can resume later with `/deploy-oiv` and end the skill.

**Step 1.5: Check RPC URLs**

Ask which chains they plan to deploy to (mainnet, arbitrum, base, optimism, gnosis).
Based on the answer, check whether the corresponding environment variables are set in `.env`:

| Chain     | Required variable     |
|-----------|-----------------------|
| Mainnet   | `MAINNET_RPC_URL`     |
| Arbitrum  | `ARBITRUM_RPC_URL`    |
| Base      | `BASE_RPC_URL`        |
| Optimism  | `OPTIMISM_RPC_URL`    |
| Gnosis    | `GNOSIS_RPC_URL`      |

For each selected chain missing an RPC URL, ask the user to add it to `.env`.
You can suggest Alchemy (alchemy.com) or Infura (infura.io) as free providers.
Do not continue until all required RPC URLs are configured.

---

### PHASE 2 — Deployment type

Ask:

> "What type of deployment do you want to do?
> 1. **Full OIV** — deploys the fund infrastructure + shares token on mainnet, and the infrastructure on the selected sidechains.
> 2. **Infrastructure only** — deploys the operational backbone (no shares token) on the selected chains. Useful for adding a new chain to an existing fund."

Store the answer as `deployment_type` (values: `full_oiv` or `stack_only`).

If they chose `full_oiv`, ask which sidechains in addition to mainnet (can be none):
> "Besides mainnet, which sidechains do you want to deploy the infrastructure to? (arbitrum, base, optimism, gnosis, or none)"

If they chose `stack_only`, ask which chains:
> "Which chains do you want to deploy the infrastructure to? (arbitrum, base, optimism, gnosis)"

---

### PHASE 3 — Fund identity

**Step 3.1: Fund name**

Ask:
> "What is the name of the fund? (e.g. 'kpk USD Beta Fund')"

Derive a lowercase `slug` without spaces from the answer (e.g. `kpk-usd-beta-fund`).
The slug will be used as the config file name.

**Step 3.2: Token symbol** (only if `deployment_type == full_oiv`)

Ask:
> "What will the shares token symbol be? (e.g. 'kUSDB' — max 8 characters, no spaces)"

---

### PHASE 4 — Manager Safe

Ask:
> "What are the signer addresses for the Manager Safe?
> Enter them separated by commas. (e.g. 0xAbc..., 0xDef...)"

Validate each address: must be a 42-character hex string starting with `0x`.
If any is invalid, indicate which one and ask the user to correct it.
Duplicate addresses are not allowed.

Then ask:
> "How many signatures are required to approve a transaction? (must be greater than 0 and no more than the number of signers)"

Validate that threshold is `> 0` and `<= number of owners`.

---

### PHASE 5 — Admin and authority

**For `full_oiv`:**

Ask:
> "What is the admin address for the fund? The admin receives control over the exec Roles Modifier and the DEFAULT_ADMIN_ROLE on the shares token.
> Default: Security Council Safe `0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537`
> (Press Enter to use the default, or enter a different address)"

If the user presses Enter or leaves it blank, use `0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537`.
Validate that the address is not `0x0000000000000000000000000000000000000000`.

**For `stack_only`:**

Ask:
> "What address will receive ownership of the exec Roles Modifier? Typically the Security Council Safe.
> Default: `0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537`
> (Press Enter to use the default, or enter a different address)"

---

### PHASE 6 — Shares token parameters (only for `full_oiv`)

**Step 6.1: Base asset**

Ask:
> "What is the fund's base asset? This is the primary token for subscriptions and redemptions.
> Common options (mainnet):
>   1. USDC  — `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`
>   2. USDT  — `0xdAC17F958D2ee523a2206206994597C13D831ec7`
>   3. WETH  — `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`
>   4. Other (enter the address directly)"

Store the base asset address.

**Step 6.2: Additional assets**

Ask:
> "Do you want to enable additional assets for subscriptions or redemptions beyond the base asset? (yes/no)"

If yes, for each asset ask:
> "Enter the address of the additional asset:"
> "Can it be used for **subscriptions** (deposits)? (yes/no)"
> "Can it be used for **redemptions** (withdrawals)? (yes/no)"

Keep asking until the user says no more. Maximum 20 additional assets.
Validate that no asset is the same as the base asset and that there are no duplicates.

**Step 6.3: Fees**

Introduce this section with:
> "Now let's configure the fund's fees. All fees are expressed as percentages (%) and the maximum is 20%."

Ask each one separately:

- **Management fee** (annual management fee):
  > "What is the annual management fee? (e.g. 1.5 for 1.5%, or 0 for none)"

- **Redemption fee** (fee per withdrawal):
  > "What is the redemption fee per withdrawal? (e.g. 0.5 for 0.5%, or 0 for none)"

- **Performance fee** (fee on gains):
  > "Is there a performance fee? (yes/no)"
  - If yes: ask for the percentage and the performance fee module address.
    > "What is the performance fee percentage? (e.g. 10 for 10%)"
    > "What is the address of the performance fee module?"
  - If no: use `0x0000000000000000000000000000000000000000` and 0%.

Convert all percentages to basis points internally: `bps = percentage * 100`.
Validate that no fee exceeds 2000 bps (20%).

**Step 6.4: Fee receiver**

Ask:
> "What address should receive the fees (management fee, redemption fee, performance fee)?"

Validate that it is not the zero address.

**Step 6.5: TTLs (cancellation periods)**

Introduce with:
> "TTLs define the minimum time an investor must wait before they can cancel a pending request."

- **Subscription TTL:**
  > "How many days must an investor wait to cancel a subscription request? (min 1, max 7)"

- **Redemption TTL:**
  > "How many days must an investor wait to cancel a redemption request? (min 1, max 7)"

Convert to seconds internally: `seconds = days * 86400`.

---

### PHASE 7 — Salt

Ask:
> "The salt is a number that determines the fund's contract addresses on all chains.
> The same salt + same deployer account produces the same addresses on mainnet, Arbitrum, Base, etc.
> Do you want to use salt 0 (recommended for the first deployment of this fund), or specify a different number?"

If the user presses Enter, says "0", or "default", use `0`.
If they enter a number, validate that it is a non-negative integer.

---

### PHASE 8 — Generate the config file

Build the configuration JSON from the collected data.

For `full_oiv`, the file has this structure:

```json
{
  "fundName": "<fund name>",
  "managerSafe": {
    "owners": ["<owner1>", "<owner2>", "..."],
    "threshold": <threshold>
  },
  "salt": "<salt>",
  "execRolesModFinalOwner": "<admin_address>",
  "oiv": {
    "admin": "<admin_address>",
    "sharesParams": {
      "asset": "<asset_address>",
      "name": "<fund name>",
      "symbol": "<symbol>",
      "subscriptionRequestTtl": <ttl_in_seconds>,
      "redemptionRequestTtl": <ttl_in_seconds>,
      "feeReceiver": "<fee_receiver_address>",
      "managementFeeRate": <management_fee_bps>,
      "redemptionFeeRate": <redemption_fee_bps>,
      "performanceFeeModule": "<performance_fee_module_address>",
      "performanceFeeRate": <performance_fee_bps>
    },
    "additionalAssets": [
      {
        "asset": "<asset_address>",
        "canDeposit": true,
        "canRedeem": true
      }
    ]
  },
  "sidechains": ["<chain1>", "<chain2>"]
}
```

For `stack_only`, omit the `"oiv"` object and use only the common keys.

Save the file to `script/<slug>-config.json`.

Then show the user a formatted summary of all parameters:
> "Before deploying, please review the fund configuration:
> [show a human-readable summary, converting bps to % and seconds to days]"

Ask for confirmation:
> "Does everything look correct? (yes to continue, no to correct a parameter)"

If no: ask what they want to correct and go back to the corresponding step.

---

### PHASE 9 — Address preview (only for `full_oiv`)

Before deployment, show the predicted addresses:

Run:
```
source .env && forge script script/DeployOiv.s.sol \
  --sig "predict(string)" "script/<slug>-config.json" \
  --rpc-url $MAINNET_RPC_URL
```

Explain to the user:
> "These are the addresses the fund will have on **all** chains (they are deterministic).
> The shares token addresses (kpkShares) cannot be predicted in advance."

---

### PHASE 10 — Execute deployment

Ask:
> "Do you want to execute the deployment now, or would you prefer that I generate the commands for you to run manually later?"

**If they want to execute now:**

Run the commands in this order:

1. **Mainnet** (if `full_oiv`):
```
source .env && forge script script/DeployOiv.s.sol \
  --sig "deployOiv(string)" "script/<slug>-config.json" \
  --rpc-url $MAINNET_RPC_URL \
  --broadcast
```

2. **Each sidechain** (in order: arbitrum, base, optimism, gnosis):
```
source .env && forge script script/DeployOiv.s.sol \
  --sig "deployStack(string)" "script/<slug>-config.json" \
  --rpc-url $<CHAIN>_RPC_URL \
  --broadcast
```

After each successful deployment:
- Show the deployed addresses.
- Confirm with the user before continuing to the next chain.
- If a deployment fails: show the full error, do not continue with remaining chains, and ask the user to report it.

**If they prefer to run manually:**

Generate a file `script/<slug>-deploy-commands.sh` with all commands ready:

```bash
#!/bin/bash
# Fund deployment: <name>
# Run this script from the repository root.
# Make sure your .env file has PRIVATE_KEY and all required RPC URLs configured.

source .env

echo "=== Address prediction (no deployment) ==="
forge script script/DeployOiv.s.sol \
  --sig "predict(string)" "script/<slug>-config.json" \
  --rpc-url $MAINNET_RPC_URL

# Uncomment the lines below to execute the deployment:

# echo "=== Mainnet deployment (deployOiv) ==="
# forge script script/DeployOiv.s.sol \
#   --sig "deployOiv(string)" "script/<slug>-config.json" \
#   --rpc-url $MAINNET_RPC_URL \
#   --broadcast

# echo "=== Arbitrum deployment (deployStack) ==="
# forge script script/DeployOiv.s.sol \
#   --sig "deployStack(string)" "script/<slug>-config.json" \
#   --rpc-url $ARBITRUM_RPC_URL \
#   --broadcast

# [remaining chains...]
```

Show a final message:
> "Your files are ready:
> - `script/<slug>-config.json` — fund configuration
> - `script/<slug>-deploy-commands.sh` — deployment commands
>
> When you are ready to deploy, run `bash script/<slug>-deploy-commands.sh`
> or uncomment the deployment commands in that file."

---

## Notes for Claude

- Never display the private key. Only write it to `.env`.
- The deployer EOA retains no role after deployment. All authority stays with `admin` and `managerSafe`.
- The same `PRIVATE_KEY` must be used across all chains to guarantee address determinism.
- If the user interrupts the process, the config file saved so far can be resumed later.
- `sharesParams.admin` and `sharesParams.safe` are ignored by the factory (overridden internally). Do not include them in the JSON or ask the user for them.
- `subRolesMod.finalOwner` and `managerRolesMod.finalOwner` always go to the Manager Safe (the factory ignores them). Do not ask the user for them.
- Known mainnet addresses for quick reference:
  - USDC: `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`
  - USDT: `0xdAC17F958D2ee523a2206206994597C13D831ec7`
  - WETH: `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`
  - DAI:  `0x6B175474E89094C44Da98b954EedeAC495271d0F`
  - Security Council Safe: `0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537`
  - KpkOivFactory: `0x0d94255fdE65D302616b02A2F070CdB21190d420`

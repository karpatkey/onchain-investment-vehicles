# kpkShares Deployment Scripts

This directory contains deployment scripts for the kpkShares contract using UUPS proxy pattern.

## DeployKpkShares.s.sol

Deployment script that reads vault configurations from `vaults.json` and deploys kpkShares contracts to Ethereum mainnet.

### Usage

**Important**: A vault name must be specified. The script will revert if no vault name is provided.

Deploy a specific vault:
```bash
forge script script/DeployKpkShares.s.sol:DeployKpkShares \
  --rpc-url $ETH_RPC_URL \
  --broadcast \
  --verify \
  --sig "run(string)" "vault1"
```

Replace `"vault1"` with the name of the vault you want to deploy from `vaults.json`.

### Prerequisites

1. Set up your Ethereum mainnet RPC URL:
   ```bash
   export ETH_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_API_KEY
   ```

2. Configure your private key or use a hardware wallet:
   ```bash
   export PRIVATE_KEY=your_private_key
   # OR use --ledger, --trezor, etc.
   ```

3. Set up Etherscan API key for verification:
   ```bash
   export ETHERSCAN_API_KEY=your_etherscan_api_key
   ```

### vaults.json Format

The `vaults.json` file contains configuration for one or more vaults. Each vault entry should have the following structure:

```json
{
  "vaultName": {
    "asset": "0x...",                    // Base asset address (e.g., USDC on mainnet: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48)
    "admin": "0x...",                    // Initial admin address (will have DEFAULT_ADMIN_ROLE)
    "name": "Vault Name",                // ERC20 token name
    "symbol": "SYMBOL",                  // ERC20 token symbol
    "safe": "0x...",                     // Portfolio safe address
    "subscriptionRequestTtl": 86400,     // Subscription request TTL in seconds (max 7 days)
    "redemptionRequestTtl": 86400,       // Redemption request TTL in seconds (max 7 days)
    "feeReceiver": "0x...",              // Address that receives fees
    "managementFeeRate": 200,            // Management fee rate in basis points (200 = 2%, max 2000 = 20%)
    "redemptionFeeRate": 100,            // Redemption fee rate in basis points (100 = 1%, max 2000 = 20%)
    "performanceFeeModule": "0x...",     // Performance fee module address (optional, use 0x0000... to disable)
    "performanceFeeRate": 2000           // Performance fee rate in basis points (2000 = 20%, max 2000 = 20%)
  }
}
```

### Important Notes

1. **Mainnet Only**: This script is configured to only deploy on Ethereum mainnet (chain ID 1). It will revert if run on other networks.

2. **Address Validation**: All addresses must be valid Ethereum addresses. The script validates that required addresses are not zero.

3. **Fee Rates**: All fee rates are in basis points (1 basis point = 0.01%). Maximum allowed is 2000 bps (20%).

4. **TTL Values**: Time-to-live values are in seconds. Maximum allowed is 7 days (604800 seconds).

5. **Performance Fee Module**: This is optional. If you want to disable performance fees, set `performanceFeeModule` to `0x0000000000000000000000000000000000000000` or omit the field.

### Example: Mainnet USDC Addresses

- USDC: `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`
- USDT: `0xdAC17F958D2ee523a2206206994597C13D831ec7`
- DAI: `0x6B175474E89094C44Da98b954EedeAC495271d0F`

### Deployment Process

1. Update `vaults.json` with your vault configuration
2. Verify all addresses are correct
3. Run the deployment script with the vault name
4. The script will:
   - Deploy the implementation contract
   - Deploy a UUPS proxy pointing to the implementation
   - Initialize the proxy with your configuration
   - Log all deployment details

### Post-Deployment

After deployment, you should:
1. Verify the contract on Etherscan (if using `--verify`)
2. Grant OPERATOR role to the appropriate address:
   ```solidity
   kpkSharesContract.grantRole(OPERATOR, operatorAddress);
   ```
3. Set up asset approvals for the portfolio safe
4. Test the deployment with a small transaction


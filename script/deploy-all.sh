#!/usr/bin/env bash
# Deploy the OIV cross-chain infra to EVERY wired chain (verdict READY or READY-AFTER-EMPTY) by
# calling deploy-chain.sh per chain, then print the source-side `deployEverywhere` command (with the
# full destination-selector list) to fan a fund out from mainnet.
#
# Usage:
#   source .env && script/deploy-all.sh
# Honors the same env as deploy-chain.sh (PRIVATE_KEY, DEPLOY_FINAL_OWNER, DRY_RUN, VERIFY).
#
# NOTE: infra deploy is per-chain and idempotent. The actual fund fan-out (deployEverywhere) is a
# separate, deliberate step you run from mainnet AFTER funding the orchestrator with LINK.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REG="$ROOT/script/ccip-networks.json"
command -v jq >/dev/null || { echo "jq required"; exit 1; }

mapfile -t CHAINS < <(jq -r '.networks[] | select(.verdict=="READY" or .verdict=="READY-AFTER-EMPTY") | .name' "$REG")
echo "Wired chains (${#CHAINS[@]}): ${CHAINS[*]}"

for c in "${CHAINS[@]}"; do
  echo; echo "############################################################"
  "$ROOT/script/deploy-chain.sh" "$c" || { echo "FAILED on $c — stopping."; exit 1; }
done

# Build the destination selector list (all destinations, i.e. exclude the source role).
SELECTORS=$(jq -r '[.networks[] | select(.role=="destination" and (.verdict=="READY" or .verdict=="READY-AFTER-EMPTY")) | .ccipChainSelector] | join(",")' "$REG")

cat <<EOF

############################################################
Infra deployed on all wired chains.

NEXT (manual, deliberate) — fan a fund out from mainnet:
  1. Fund the mainnet orchestrator with LINK (size it):
       forge script script/CcipDeployEverywhere.s.sol:CcipDeployEverywhere \\
         --rpc-url ethereum --sig "quote(address,string,uint64[],uint256)" \\
         <ORCHESTRATOR> script/<fund>-config.json "[$SELECTORS]" 2000000
  2. deployEverywhere (deploys the OIV on mainnet + CCIP-fans-out the stack):
       forge script script/CcipDeployEverywhere.s.sol:CcipDeployEverywhere \\
         --rpc-url ethereum --private-key \$PRIVATE_KEY --broadcast \\
         --sig "deployEverywhere(address,string,uint64[],uint256)" \\
         <ORCHESTRATOR> script/<fund>-config.json "[$SELECTORS]" 2000000
############################################################
EOF

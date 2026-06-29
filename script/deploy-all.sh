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
# separate, deliberate step you run from mainnet; it is permissionless and the caller pays the CCIP
# fees in native gas from msg.value (no LINK pre-funding).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REG="$ROOT/script/ccip-networks.json"
command -v jq >/dev/null || { echo "jq required"; exit 1; }

mapfile -t CHAINS < <(jq -r '.networks[] | select(.verdict=="READY" or .verdict=="READY-AFTER-EMPTY") | .name' "$REG")
echo "Wired chains (${#CHAINS[@]}): ${CHAINS[*]}"

# True if foundry.toml has an [etherscan] alias for the chain (i.e. deploy-chain.sh can --verify it).
has_etherscan() { awk '/^\[etherscan\]/{f=1;next} /^\[/{f=0} f' "$ROOT/foundry.toml" | grep -qE "^[[:space:]]*${1}[[:space:]]*="; }

declare -a OK_CHAINS=() FAILED_CHAINS=() UNVERIFIED_CHAINS=()

# Deploy each chain independently: a failure on one (unset RPC var, missing Empty factory, etc.) is
# recorded and the rollout continues, rather than aborting the whole fleet mid-way and leaving the
# operator to guess which chains already landed. Per-chain deploys are idempotent, so re-running a
# failed chain after fixing its cause is safe.
for c in "${CHAINS[@]}"; do
  echo; echo "############################################################"
  if "$ROOT/script/deploy-chain.sh" "$c"; then
    OK_CHAINS+=("$c")
    [ "${VERIFY:-0}" = "1" ] && ! has_etherscan "$c" && UNVERIFIED_CHAINS+=("$c")
  else
    echo "FAILED on $c — continuing with remaining chains."
    FAILED_CHAINS+=("$c")
  fi
done

echo; echo "############################################################"
echo "Fleet summary: ${#OK_CHAINS[@]} ok, ${#FAILED_CHAINS[@]} failed (of ${#CHAINS[@]} wired chains)."
[ ${#OK_CHAINS[@]} -gt 0 ] && echo "  ok:        ${OK_CHAINS[*]}"
[ ${#FAILED_CHAINS[@]} -gt 0 ] && echo "  FAILED:    ${FAILED_CHAINS[*]}   (idempotent — re-run: script/deploy-chain.sh <chain>)"
[ ${#UNVERIFIED_CHAINS[@]} -gt 0 ] && echo "  UNVERIFIED (deployed, no [etherscan] cfg — verify manually): ${UNVERIFIED_CHAINS[*]}"

# Build the destination selector list (all destinations, i.e. exclude the source role).
SELECTORS=$(jq -r '[.networks[] | select(.role=="destination" and (.verdict=="READY" or .verdict=="READY-AFTER-EMPTY")) | .ccipChainSelector] | join(",")' "$REG")

cat <<EOF

############################################################
Infra deployed on all wired chains.

NEXT (manual, deliberate) — fan a fund out from mainnet (permissionless; caller pays native fees):
  1. Size the native CCIP fee (no pre-funding — paid from msg.value, surplus refunded):
       forge script script/CcipDeployEverywhere.s.sol:CcipDeployEverywhere \\
         --rpc-url ethereum --sig "quote(address,string,uint64[],uint256)" \\
         <ORCHESTRATOR> script/<fund>-config.json "[$SELECTORS]" 2000000
  2. deployEverywhere (deploys the OIV on mainnet + CCIP-fans-out the stack; the script quotes and
     forwards the native fee automatically):
       forge script script/CcipDeployEverywhere.s.sol:CcipDeployEverywhere \\
         --rpc-url ethereum --private-key \$PRIVATE_KEY --broadcast \\
         --sig "deployEverywhere(address,string,uint64[],uint256)" \\
         <ORCHESTRATOR> script/<fund>-config.json "[$SELECTORS]" 2000000
############################################################
EOF

# Non-zero exit if any chain failed, so callers / CI can detect a partial rollout.
[ ${#FAILED_CHAINS[@]} -eq 0 ] || exit 1

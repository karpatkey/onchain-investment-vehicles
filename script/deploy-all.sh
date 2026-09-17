#!/usr/bin/env bash
# Deploy the OIV cross-chain infra to EVERY wired chain (verdict READY or READY-AFTER-EMPTY) by
# calling deploy-chain.sh per chain, then print the source-side `deployEverywhere` command (with the
# full destination-selector list) to fan a fund out from mainnet.
#
# Usage:
#   source .env && script/deploy-all.sh
# Honors the same env as deploy-chain.sh: DEPLOYER_NAME (keystore, preferred) [+ KEYSTORE_PASSWORD_FILE
# so the 21-chain loop is non-interactive] or PRIVATE_KEY (fallback), plus DEPLOY_FINAL_OWNER, DRY_RUN,
# VERIFY.
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

# Build the destination chain-ID list (all destinations, i.e. exclude the source role). Callers target
# chains by id; the orchestrator resolves each to its CCIP selector via its owner-managed mapping.
CHAIN_IDS=$(jq -r '[.networks[] | select(.role=="destination" and (.verdict=="READY" or .verdict=="READY-AFTER-EMPTY")) | .chainId] | join(",")' "$REG")

cat <<EOF

############################################################
Infra deployed on all wired chains.

NEXT (manual, deliberate) — fan a fund out from ANY wired chain (permissionless; caller pays
native fees). Substitute your origin for 'ethereum' below; there is no designated source chain.
  0. NOTHING TO SEED. The orchestrator bakes the chainId -> CCIP selector registry into its
     CONSTRUCTOR, so a freshly deployed instance already knows every wired chain. Confirm with
     getChainIds(). The old 'setChainSelectors' step here was an owner-only call that is now
     redundant.
  1. Size the native CCIP fee (no pre-funding — paid from msg.value, surplus refunded):
       forge script script/CcipDeployEverywhere.s.sol:CcipDeployEverywhere \\
         --rpc-url <origin> --sig "quote(address,string,uint256[],uint256)" \\
         <ORCHESTRATOR> script/<fund>-config.json "[$CHAIN_IDS]" 3000000
  2. deployEverywhere (deploys the ORIGIN chain's part of the fund — full OIV if the origin is in
     .sharesChains, operational stack alone if not — and CCIP-fans-out the stack; the script quotes
     and forwards the native fee automatically). Pass destination CHAIN IDs, not selectors:
       forge script script/CcipDeployEverywhere.s.sol:CcipDeployEverywhere \\
         --rpc-url <origin> --private-key \$PRIVATE_KEY --broadcast \\
         --sig "deployEverywhere(address,string,uint256[],uint256)" \\
         <ORCHESTRATOR> script/<fund>-config.json "[$CHAIN_IDS]" 3000000
  3. Fill every OTHER chain named in .sharesChains with deployLocal on that chain — the fan-out
     skips shares chains deliberately, because a stack landing on one takes the addresses its own
     shares deployment needs.

  GAS LIMIT: 3000000, not the 2000000 this helper used to print. A timelocked fund at the maximum
  role set costs ~2.78M for deployStack alone plus ~80k for the receive frame, against a 3M cap —
  so 2M spent every lane's non-refundable fee and then ran out of gas on arrival.
############################################################
EOF

# Non-zero exit if any chain failed, so callers / CI can detect a partial rollout.
[ ${#FAILED_CHAINS[@]} -eq 0 ] || exit 1

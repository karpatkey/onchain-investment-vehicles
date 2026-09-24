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

# `excluded` is filtered here, not just in the fan-out list below. `verdict` says a chain COULD host
# the infra, not that we intend it to: bob and katana are READY-AFTER-EMPTY and deliberately not
# pursued, so without this the loop deploys infra to two chains the rollout excluded on purpose and
# quietly turns the 19-chain set into 21. `script/CcipDeployEverywhere.s.sol` has honoured this flag
# since the seeding incident recorded in `script/deployed-infra.json`; this script was missed.
mapfile -t CHAINS < <(jq -r '.networks[] | select((.verdict=="READY" or .verdict=="READY-AFTER-EMPTY") and (.excluded != true)) | .name' "$REG")
echo "Wired chains (${#CHAINS[@]}): ${CHAINS[*]}"
EXCLUDED=$(jq -r '[.networks[] | select(.excluded == true) | .name] | join(" ")' "$REG")
[ -n "$EXCLUDED" ] && echo "Excluded (deliberately not pursued): $EXCLUDED"

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
CHAIN_IDS=$(jq -r '[.networks[] | select(.role=="destination" and (.verdict=="READY" or .verdict=="READY-AFTER-EMPTY") and (.excluded != true)) | .chainId] | join(",")' "$REG")

# Self-check rather than trust: if the filter above is ever dropped, this fails loudly instead of
# printing a command that reverts on arrival with the lane fee already spent. An excluded chain has no
# entry in the orchestrator's baked registry, so `dispatchTo` reverts `UnknownChain(chainId)` at
# `src/CcipOivDeployer.sol:1433` before any fee is paid.
# pinned: test/CcipOivDeployer.t.sol test_dispatchTo (UnknownChain expectations at :970, :1580)
for _id in ${CHAIN_IDS//,/ }; do
  if [ "$(jq -r --argjson id "$_id" '[.networks[] | select(.chainId==$id and .excluded==true)] | length' "$REG")" != "0" ]; then
    echo "BUG: chain $_id is marked excluded but reached the fan-out list" >&2; exit 1
  fi
done

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

  ⚠ THE LIST ABOVE IS FUND-AGNOSTIC. It is every wired, non-excluded destination — this script does
     not read your fund config, so it cannot remove the two kinds of chain that WILL fail:
       * your ORIGIN chain (you are dispatching FROM it), and
       * every chain in your fund's .sharesChains (refused: SharesChainRefusesStack).
     With script/oiv-config.example.json (.sharesChains = [1, 100]) the chain that must go is 100
     (gnosis). Chain 1 is already absent because ethereum's registry role is not "destination" — so if
     ethereum is your origin there is nothing extra to drop, but if you dispatch FROM a destination-role
     chain you must remove that chain's own id as well. Verified against the example config: the
     command below yields 17 ids, without 100, 60808 or 747474.
       jq -r --argjson drop "\$(jq -c '.sharesChains' script/<fund>-config.json)" \
         '[.networks[] | select(.role=="destination" and (.verdict|startswith("READY")) and (.excluded != true))
           | .chainId] - \$drop | join(",")' script/ccip-networks.json

  GAS LIMIT: 3000000, not the 2000000 this helper used to print. A timelocked fund at the maximum
  role set costs ~2.78M for deployStack alone plus ~80k for the receive frame, against a 3M cap —
  so 2M spent every lane's non-refundable fee and then ran out of gas on arrival.
############################################################
EOF

# Non-zero exit if any chain failed, so callers / CI can detect a partial rollout.
[ ${#FAILED_CHAINS[@]} -eq 0 ] || exit 1

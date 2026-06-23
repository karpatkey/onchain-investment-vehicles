#!/usr/bin/env bash
# Deploy the OIV cross-chain infra (Empty preflight -> KpkOivFactory + KpkSharesDeployer ->
# CcipOivDeployer + configure) to a single chain, driven by script/ccip-networks.json.
#
# Usage:
#   source .env && script/deploy-chain.sh <chain-name>
#
# Env:
#   PRIVATE_KEY          (required) deployer key; its address is used as eoaOwner.
#   DEPLOY_FINAL_OWNER   (optional) owner to hand factory+orchestrator to; defaults to the deployer
#                        EOA (keep control — recommended for testing; set to a multisig for prod).
#   DRY_RUN=1            (optional) simulate only (omit --broadcast).
#   VERIFY=1             (optional) pass --verify (needs ETHERSCAN_API_KEY + foundry etherscan cfg).
#
# Refuses any chain whose registry verdict is NOT-READY. The Solidity script additionally guards
# every on-chain prerequisite and reverts if anything is missing.
set -euo pipefail

CHAIN="${1:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REG="$ROOT/script/ccip-networks.json"
[ -n "$CHAIN" ] || { echo "usage: deploy-chain.sh <chain-name>"; exit 1; }
[ -f "$REG" ] || { echo "registry not found: $REG"; exit 1; }
[ -n "${PRIVATE_KEY:-}" ] || { echo "PRIVATE_KEY not set (source .env)"; exit 1; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }

entry=$(jq -c --arg n "$CHAIN" '.networks[] | select(.name==$n)' "$REG")
[ -n "$entry" ] || { echo "chain '$CHAIN' not in registry"; exit 1; }

verdict=$(echo "$entry" | jq -r .verdict)
if [ "$verdict" = "NOT-READY" ]; then
  echo "REFUSING: '$CHAIN' is NOT-READY — $(echo "$entry" | jq -r '.note // "missing prerequisites"')"
  exit 1
fi

cap=$(echo "$CHAIN" | sed -E 's/^(.)/\U\1/')
script="script/chains/Deploy_${cap}.s.sol:Deploy_${cap}"
[ -f "$ROOT/script/chains/Deploy_${cap}.s.sol" ] || { echo "per-chain script missing: $script"; exit 1; }

EOA=$(cast wallet address --private-key "$PRIVATE_KEY")
FINAL="${DEPLOY_FINAL_OWNER:-$EOA}"

bflag="--broadcast"; [ "${DRY_RUN:-0}" = "1" ] && bflag=""
vflag=""; [ "${VERIFY:-0}" = "1" ] && vflag="--verify"

echo "=== Deploying OIV infra to $CHAIN (verdict $verdict) ==="
echo "  eoaOwner=$EOA  finalOwner=$FINAL  dryRun=${DRY_RUN:-0}"
( cd "$ROOT" && forge script "$script" \
    --rpc-url "$CHAIN" --private-key "$PRIVATE_KEY" $bflag $vflag \
    --sig "run(address,address)" "$EOA" "$FINAL" )

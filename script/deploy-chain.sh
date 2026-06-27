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
# Allowlist, not blocklist: only the two known-deployable verdicts pass. Anything else (NOT-READY, a
# typo, or a reintroduced category like NEEDS-ZODIAC) is refused, so a non-deployable chain can never
# slip through just because its verdict string isn't the literal "NOT-READY".
if [ "$verdict" != "READY" ] && [ "$verdict" != "READY-AFTER-EMPTY" ]; then
  echo "REFUSING: '$CHAIN' has verdict '$verdict' (only READY / READY-AFTER-EMPTY are deployable) — $(echo "$entry" | jq -r '.note // "missing prerequisites"')"
  exit 1
fi

# Resolve the per-chain script file case-insensitively so internal casing of the registry name can
# never silently mismatch the generated file name.
file=$(cd "$ROOT/script/chains" 2>/dev/null && ls | grep -i "^Deploy_${CHAIN}\.s\.sol$" | head -1 || true)
[ -n "$file" ] || { echo "per-chain script missing for '$CHAIN' (expected script/chains/Deploy_${CHAIN}.s.sol)"; exit 1; }
contract="${file%.s.sol}"
script="script/chains/${file}:${contract}"

EOA=$(cast wallet address --private-key "$PRIVATE_KEY")
FINAL="${DEPLOY_FINAL_OWNER:-$EOA}"

bflag="--broadcast"; [ "${DRY_RUN:-0}" = "1" ] && bflag=""
# Only pass --verify when the chain actually has an [etherscan] entry in foundry.toml — otherwise the
# broadcast would succeed but verification would error and (under deploy-all.sh `set -e`) abort the
# whole fleet after contracts are already deployed.
vflag=""
if [ "${VERIFY:-0}" = "1" ]; then
  if awk '/^\[etherscan\]/{f=1;next} /^\[/{f=0} f' "$ROOT/foundry.toml" | grep -qE "^[[:space:]]*${CHAIN}[[:space:]]*="; then
    vflag="--verify"
  else
    echo "  NOTE: no [etherscan] entry for '$CHAIN' — skipping --verify (verify manually later)."
  fi
fi

echo "=== Deploying OIV infra to $CHAIN (verdict $verdict) ==="
echo "  eoaOwner=$EOA  finalOwner=$FINAL  dryRun=${DRY_RUN:-0}"
( cd "$ROOT" && forge script "$script" \
    --rpc-url "$CHAIN" --private-key "$PRIVATE_KEY" $bflag $vflag \
    --sig "run(address,address)" "$EOA" "$FINAL" )

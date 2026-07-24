#!/usr/bin/env bash
# Deploy the OIV cross-chain infra (Empty preflight -> KpkOivFactory + KpkSharesDeployer ->
# CcipOivDeployer + configure) to a single chain, driven by script/ccip-networks.json.
#
# Usage:
#   source .env && script/deploy-chain.sh <chain-name>
#
# Env (signer — prefer a Foundry keystore account, mirroring the gas-replenisher/Wonderland flow):
#   DEPLOYER_NAME        keystore account to sign with (`cast wallet import <name>`). Its address is
#                        the eoaOwner baked into the CREATE2 addresses. Preferred over PRIVATE_KEY.
#   KEYSTORE_PASSWORD_FILE (optional) path to a file holding the keystore password, so a multi-chain
#                        run is non-interactive instead of prompting once per chain. gitignore it.
#   PRIVATE_KEY          (fallback) raw deployer key, used only when DEPLOYER_NAME is unset.
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
[ -n "${DEPLOYER_NAME:-}" ] || [ -n "${PRIVATE_KEY:-}" ] || {
  echo "set DEPLOYER_NAME (keystore account) or PRIVATE_KEY (source .env)"; exit 1;
}
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

# Signer: prefer a Foundry keystore account (DEPLOYER_NAME); fall back to a raw PRIVATE_KEY. The same
# flags drive both `cast wallet address` (to derive eoaOwner) and the `forge script` broadcast below.
if [ -n "${DEPLOYER_NAME:-}" ]; then
  signer=(--account "$DEPLOYER_NAME")
  [ -n "${KEYSTORE_PASSWORD_FILE:-}" ] && signer+=(--password-file "$KEYSTORE_PASSWORD_FILE")
else
  signer=(--private-key "$PRIVATE_KEY")
fi
EOA=$(cast wallet address "${signer[@]}")
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
    --rpc-url "$CHAIN" "${signer[@]}" $bflag $vflag \
    --sig "run(address,address)" "$EOA" "$FINAL" )

# ── Post-broadcast on-chain verification ──────────────────────────────────────
# The Solidity preflight in OivChainDeploy runs INSIDE vm.startBroadcast(), so its post-condition
# `require`s are evaluated against forge's local simulation, never against the chain. That gap is
# load-bearing for the MultiSendUnwrapper: EIP-2470's SingletonFactory swallows a failed inner
# CREATE2 (returns address(0), tx status 1), so a broadcast whose gas fell short on-chain still
# looks successful in simulation and the script prints "[OK] deployed". These checks re-query the
# real chain after the broadcast landed, which is the only trustworthy signal.
if [ "${DRY_RUN:-0}" != "1" ]; then
  echo "=== Post-broadcast verification against $CHAIN ==="
  rpc_codehash() { cast keccak "$(cast code "$1" --rpc-url "$CHAIN" 2>/dev/null)" 2>/dev/null; }
  EMPTY_HASH_CODE=$(cast keccak "$(cast code 0xA4703438f8cc4fc2C2503a7e43935Da16BA74652 --rpc-url "$CHAIN" 2>/dev/null)")
  fail=0
  check() { # addr expected label
    got=$(rpc_codehash "$1")
    if [ "$got" = "$2" ]; then
      echo "  [OK]   $3"
    else
      echo "  [FAIL] $3 — codehash $got != $2"
      fail=1
    fi
  }
  check 0x38869bf66a61cF6bDB996A6aE40D5853Fd43B526 0x0e4f7fc66550a322d1e7688e181b75e217e662a4f3f4d6a29b22bc61217c4b77 "MultiSend"
  check 0x9641d764fc13c8B624c04430C7356C1C7C8102e2 0xecd5bd14a08c5d2122379900b2f272bdf107a7e92423c10dd5fe3254386c9939 "MultiSendCallOnly"
  check 0xB4Cd4bb764C089f20DA18700CE8bc5e49F369efD 0x1f6e088be5e6ef9d0fbe0547d3fa9a9e40d823433fd8a4449215b5663209a1eb "MultiSendUnwrapper"
  [ -n "$EMPTY_HASH_CODE" ] && echo "  [..]   Empty codehash: $EMPTY_HASH_CODE"

  if [ "$fail" = "1" ]; then
    echo ""
    echo "ERROR: on-chain state does not match what the deploy assumed."
    echo "  A missing MultiSendUnwrapper is usually the SingletonFactory silent-OOG: the tx succeeded"
    echo "  (status 1) but the inner CREATE2 ran out of gas at the code-deposit step. Redeploy it with"
    echo "  an explicit gas limit (~1.5M) before deploying any fund on this chain:"
    echo "    cast send 0xce0042B868300000d44A59004Da54A005ffdcf9f 'deploy(bytes,bytes32)' <initcode> 0x0 \\"
    echo "      --rpc-url $CHAIN --gas-limit 1500000 <signer flags>"
    echo "  DO NOT run deployOiv/deployStack or a CCIP fan-out targeting this chain until it passes:"
    echo "  the fan-out fee is spent on the source chain and is not refunded when delivery reverts."
    exit 1
  fi

  # Mainnet only: the orchestrator's chainId->CCIP-selector registry does NOT survive a salt bump —
  # a freshly CREATE2'd orchestrator starts empty, and deployEverywhere reverts UnknownChain on the
  # first destination. Seeding is owner-only, so it must happen while the EOA still owns it.
  if [ "$CHAIN" = "ethereum" ]; then
    ORCH_COUNT=""
    if [ -n "${ORCHESTRATOR:-}" ]; then
      ORCH_COUNT=$(cast call "$ORCHESTRATOR" "getChainIdCount()(uint256)" --rpc-url "$CHAIN" 2>/dev/null || true)
    fi
    if [ -n "$ORCH_COUNT" ]; then
      echo "  [..]   mainnet orchestrator selector registry: $ORCH_COUNT destinations"
      [ "$ORCH_COUNT" = "0" ] && echo "  WARNING: registry is EMPTY — seed it with setChainSelectors BEFORE handing ownership to the Safe."
    else
      echo "  NOTE: set ORCHESTRATOR=<address> to have this script check the selector registry."
      echo "        A salt-v3 orchestrator starts with an EMPTY registry; seed it from the EOA"
      echo "        (setChainSelectors) BEFORE transferring ownership, or re-seeding needs a Safe tx."
    fi
  fi
fi

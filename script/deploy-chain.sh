#!/usr/bin/env bash
# Deploy the OIV cross-chain infra (Empty preflight -> KpkOivFactory + mastercopies + KpkTimelockDeployer ->
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
#   DEPLOY_FINAL_OWNER   owner to hand factory+orchestrator to (the OIV Safe in production). REQUIRED
#                        for a broadcast: an unset value used to fall back to the deployer EOA silently,
#                        leaving the EOA owning both contracts. Set ALLOW_EOA_OWNER=1 to keep the EOA
#                        deliberately (local/test runs). Dry runs may omit it.
#   DRY_RUN=1            (optional) simulate only (omit --broadcast).
#   ALLOW_NONCANONICAL_EOA=true (optional) let `_runChain` sign with an EOA other than the production
#                        kpk deployer. Without it a different signer is refused, because it would build a
#                        self-consistent stack at non-canonical addresses.
#   VERIFY=1             (optional) pass --verify (needs ETHERSCAN_API_KEY + foundry etherscan cfg).
#
# Refuses any chain whose registry verdict is NOT-READY, and any chain marked `excluded`. The Solidity script additionally guards
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
# `excluded` chains (bob, katana) are deliberately outside the baked 19-chain topology: a stack there
# is an orphan no orchestrator can reach. deploy-all.sh already skips them; refuse them here too.
if [ "$(echo "$entry" | jq -r '.excluded // false')" = "true" ]; then
  echo "REFUSING: '$CHAIN' is marked excluded in the registry (not part of the baked topology)"
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
if [ "${DRY_RUN:-0}" != "1" ] && [ "$(echo "$FINAL" | tr 'A-F' 'a-f')" = "$(echo "$EOA" | tr 'A-F' 'a-f')" ] \
   && [ "${ALLOW_EOA_OWNER:-0}" != "1" ]; then
  echo "REFUSING: finalOwner would be the deployer EOA ($EOA). Set DEPLOY_FINAL_OWNER (the OIV Safe"
  echo "  in production), or ALLOW_EOA_OWNER=1 to keep the EOA as owner on purpose."
  exit 1
fi

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
LOG=$(mktemp)
# --slow: wait for each receipt before sending the next tx, so a dropped tx is a clean stop that a
# re-run resumes from (every step has a [SKIP] branch) rather than a nonce gap behind later txs.
( cd "$ROOT" && forge script "$script" \
    --rpc-url "$CHAIN" "${signer[@]}" $bflag $vflag --slow \
    --sig "run(address,address)" "$EOA" "$FINAL" ) 2>&1 | tee "$LOG"
predicted() { grep -m1 "Predicted $1:" "$LOG" | grep -oE '0x[0-9a-fA-F]{40}' | head -1 || true; }
FACTORY=$(predicted KpkOivFactory); SHARES_MC=$(predicted "KpkShares mastercopy")
TL_MC=$(predicted "Timelock mastercopy"); ORCH=$(predicted CcipOivDeployer); TL_DEP=$(predicted KpkTimelockDeployer)
for v in FACTORY SHARES_MC TL_MC ORCH TL_DEP; do
  [ -n "${!v}" ] || { echo "ERROR: could not parse 'Predicted' address for $v from forge output ($LOG) — verify on-chain by hand"; exit 1; }
done

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

  # The five salt-v4 contracts, read from the chain (the Solidity post-flight only saw the simulation).
  # The CCIP selector registry is baked into the orchestrator's constructor; there is nothing to seed,
  # and `CcipDeployEverywhere.setChainSelectors` must NOT be run (it is legacy and omits chain 1).
  lc() { echo "$1" | tr 'A-F' 'a-f'; }
  expect() { # label got want
    if [ -n "$2" ] && [ "$(lc "$2")" = "$(lc "$3")" ]; then echo "  [OK]   $1"; else echo "  [FAIL] $1 — got '$2', want '$3'"; fail=1; fi
  }
  for pair in "KpkShares mastercopy:$SHARES_MC" "Timelock mastercopy:$TL_MC" "KpkTimelockDeployer:$TL_DEP" \
              "KpkOivFactory:$FACTORY" "CcipOivDeployer:$ORCH"; do
    name=${pair%%:*}; addr=${pair##*:}
    size=$(cast codesize "$addr" --rpc-url "$CHAIN" 2>/dev/null || echo 0)
    if [ -n "$addr" ] && [ "${size:-0}" -gt 0 ]; then echo "  [OK]   $name has code at $addr"; else echo "  [FAIL] $name: no code at '$addr'"; fail=1; fi
  done
  call() { cast call "$@" --rpc-url "$CHAIN" 2>/dev/null || true; }
  expect "factory.owner() is finalOwner"            "$(call "$FACTORY" 'owner()(address)')" "$FINAL"
  expect "orchestrator.owner() is finalOwner"       "$(call "$ORCH" 'owner()(address)')" "$FINAL"
  expect "factory.kpkSharesMastercopy()"            "$(call "$FACTORY" 'kpkSharesMastercopy()(address)')" "$SHARES_MC"
  expect "factory.timelockDeployer()"               "$(call "$FACTORY" 'timelockDeployer()(address)')" "$TL_DEP"
  expect "orchestrator.factory()"                   "$(call "$ORCH" 'factory()(address)')" "$FACTORY"
  expect "timelockDeployer.timelockMastercopy()"    "$(call "$TL_DEP" 'timelockMastercopy()(address)')" "$TL_MC"
  expect "timelock mastercopy getMinDelay() is 0"   "$(call "$TL_MC" 'getMinDelay()(uint256)')" "0"
  # The mastercopy's initializer must be CLAIMED (a separate tx from its CREATE2, so it can be dropped
  # or front-run). Read OZ v5's Initializable slot rather than probing `initialize` with an eth_call:
  # a probe cannot tell "reverted because claimed" from an RPC failure, so it would pass on an outage.
  # Only an exact 1 passes; anything unreadable is treated as NOT claimed.
  INIT_SLOT=0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00  # Initializable.sol INITIALIZABLE_STORAGE
  init=$(cast storage "$TL_MC" "$INIT_SLOT" --rpc-url "$CHAIN" 2>/dev/null || true)
  case "$init" in
    0x0000000000000000000000000000000000000000000000000000000000000001)
      echo "  [OK]   timelock mastercopy initializer is claimed (_initialized == 1)" ;;
    0x0000000000000000000000000000000000000000000000000000000000000000)
      echo "  [FAIL] timelock mastercopy initializer is still OPEN — claim it before anything else:"
      echo "    cast send $TL_MC 'initialize(uint256,address[],address[],address)' 0 '[]' '[]' 0x0000000000000000000000000000000000000000 --rpc-url $CHAIN <signer flags>"
      fail=1 ;;
    *)
      echo "  [FAIL] could not read the timelock mastercopy's initializer slot (got '$init') — treat as NOT claimed and re-check"
      fail=1 ;;
  esac
  [ "$fail" = "1" ] && { echo ""; echo "ERROR: on-chain state does not match the deploy. Do NOT deploy funds or fan out to this chain."; exit 1; }
  echo "  All on-chain checks passed for $CHAIN."
fi

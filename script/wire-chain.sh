#!/usr/bin/env bash
# Write the Safe Transaction Builder batches that wire a deployed chain into the CCIP topology after
# the fact. Needed for every chain outside the registry `CcipOivDeployer` seeds in its constructor
# (robinhood, and any chain added later): `chainSelectorOf(<id>) == 0` on every orchestrator, so the
# chain can neither originate a fan-out (`onlyWiredChain`) nor be accepted as a source (`ccipReceive`
# checks `_isKnownSelector`), and no other chain lists it as a destination.
#
# Usage:
#   source .env && script/wire-chain.sh <chain-name>           # write script/safe-txs/ccip-wire-<chain>/
#   source .env && script/wire-chain.sh <chain-name> --check   # read back only; exit 1 while anything is pending
#
# What it writes, one file per chain that needs a transaction (each executed by that orchestrator's
# owner, the Security Council Safe in production):
#   <chain>.json        setChainSelector(<chain>, <selector>) on the chain itself, plus one entry for
#                       every counterpart that chain's registry does not know yet.
#   <counterpart>.json  setChainSelector(<chain>, <selector>) on each counterpart orchestrator.
#
# Counterparts are the deployed orchestrators (script/deployed-infra.json) with a CCIP lane to or from
# the chain, asked live of both configured routers. A pair with no lane gets nothing: no message could
# cross it, and a registry entry there would only be a future lane nobody reviewed. Entries already in
# place are skipped, so a re-run after partial execution writes only what is left.
#
# Execute <chain>.json first. A counterpart that already lists <chain> sends to it as soon as its own
# batch lands, and <chain> rejects (`InvalidSourceChain`) anything from a counterpart it does not know.
set -euo pipefail

CHAIN="${1:-}"
MODE="${2:-write}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REG="$ROOT/script/ccip-networks.json"
INFRA="$ROOT/script/deployed-infra.json"
[ -n "$CHAIN" ] || { echo "usage: wire-chain.sh <chain-name> [--check]"; exit 1; }
[ "$MODE" = "write" ] || [ "$MODE" = "--check" ] || { echo "unknown mode '$MODE' (expected --check)"; exit 1; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }
command -v cast >/dev/null || { echo "cast required"; exit 1; }
cd "$ROOT" # rpc aliases resolve through foundry.toml

ORCH=$(jq -r .canonical.ccipOivDeployer "$INFRA")
row() { jq -c --arg n "$1" '.networks[] | select(.name==$n)' "$REG"; }
lower() { tr 'A-F' 'a-f'; }
# cast annotates large integers ("5009297550715157269 [5.009e18]"); keep the bare value for comparison.
call() { cast call "$1" "$2" "${@:4}" --rpc-url "$3" | awk '{print $1}'; }

entry=$(row "$CHAIN")
[ -n "$entry" ] || { echo "chain '$CHAIN' not in registry"; exit 1; }
ID=$(echo "$entry" | jq -r .chainId)
SEL=$(echo "$entry" | jq -r .ccipChainSelector)

# The chain's own orchestrator must exist and be configured before anything can point at it: a
# counterpart that lists a chain with no receiver at the canonical address pays CCIP to deliver nothing.
# Every read below is its own assignment, so a failed RPC aborts (set -e) instead of reading as "absent".
code=$(cast code "$ORCH" --rpc-url "$CHAIN")
[ "$code" != "0x" ] || { echo "no CcipOivDeployer on $CHAIN: deploy it first (script/chains/Deploy_<Chain>.s.sol)"; exit 1; }
ROUTER=$(call "$ORCH" 'router()(address)' "$CHAIN")
[ "$(echo "$ROUTER" | lower)" = "$(echo "$entry" | jq -r .ccipRouter | lower)" ] \
  || { echo "$CHAIN orchestrator router $ROUTER differs from the registry's: configure() it first"; exit 1; }

# setChainSelector(id, selector) as one Transaction Builder entry. Values stay strings: the selectors
# exceed 2^53, and the Builder would round a JSON number.
tx() {
  jq -n --arg to "$ORCH" --arg id "$1" --arg sel "$2" '{
    to: $to, value: "0", data: null,
    contractMethod: {
      inputs: [
        { internalType: "uint256", name: "chainId", type: "uint256" },
        { internalType: "uint64", name: "ccipChainSelector", type: "uint64" }
      ],
      name: "setChainSelector", payable: false
    },
    contractInputsValues: { chainId: $id, ccipChainSelector: $sel }
  }'
}

OUT="$ROOT/script/safe-txs/ccip-wire-$CHAIN"
# Files land in a staging dir and replace $OUT only once every read succeeded, so a failed RPC midway
# never leaves fresh batches beside stale ones.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
AT="$(date +%s)000"
pending=0
# batch <name> <chainId> <description> <tx-json>... : one Builder file executed by that chain's owner.
batch() {
  local name=$1 cid=$2 desc=$3; shift 3
  local owner owner_code
  owner=$(call "$ORCH" 'owner()(address)' "$name")
  owner_code=$(cast code "$owner" --rpc-url "$name")
  [ "$owner_code" != "0x" ] \
    || { echo "$name: orchestrator owner $owner is not a contract, so this is no Safe batch; refusing"; exit 1; }
  pending=$((pending + $#))
  echo "  $name: $# transaction(s) for owner $owner"
  [ "$MODE" = "write" ] || return 0
  printf '%s\n' "$@" | jq -s --arg cid "$cid" --arg owner "$owner" --arg chain "$CHAIN" --arg name "$name" \
    --arg desc "$desc" --argjson at "$AT" '{
      version: "1.0", chainId: $cid, createdAt: $at,
      meta: {
        name: ("CCIP wiring of " + $chain + " (" + $name + ") - setChainSelector on the CcipOivDeployer"),
        description: $desc, txBuilderVersion: "1.16.5",
        createdFromSafeAddress: $owner, createdFromOwnerAddress: ""
      },
      transactions: .
    }' > "$STAGE/$name.json"
}

echo "=== CCIP wiring of $CHAIN (chainId $ID, selector $SEL); orchestrator $ORCH ==="
self_txs=()
own=$(call "$ORCH" 'chainSelectorOf(uint256)(uint64)' "$CHAIN" "$ID")
[ "$own" = "$SEL" ] || self_txs+=("$(tx "$ID" "$SEL")")

for name in $(jq -r '.chains[] | select(.deployed == true) | .name' "$INFRA"); do
  [ "$name" != "$CHAIN" ] || continue
  peer=$(row "$name"); pid=$(echo "$peer" | jq -r .chainId); psel=$(echo "$peer" | jq -r .ccipChainSelector)
  prouter=$(call "$ORCH" 'router()(address)' "$name")
  out=$(call "$ROUTER" 'isChainSupported(uint64)(bool)' "$CHAIN" "$psel")
  in=$(call "$prouter" 'isChainSupported(uint64)(bool)' "$name" "$SEL")
  if [ "$out" != "true" ] && [ "$in" != "true" ]; then echo "  $name: no lane either way, skipped"; continue; fi

  have=$(call "$ORCH" 'chainSelectorOf(uint256)(uint64)' "$name" "$ID")
  if [ "$have" = "$SEL" ]; then
    echo "  $name: already wired"
  elif [ "$have" != "0" ]; then
    echo "$name maps $ID to selector $have, not $SEL: correct it by hand, this script only adds"; exit 1
  else
    batch "$name" "$pid" "setChainSelector($ID, $SEL) on the CcipOivDeployer $ORCH, so this orchestrator accepts stacks from $CHAIN and lists it as a destination. Lanes read live by script/wire-chain.sh: $CHAIN->$name $out, $name->$CHAIN $in. If $CHAIN.json sits beside this file, execute it first." "$(tx "$ID" "$SEL")"
  fi
  # The chain's own registry must know the counterpart too; constructor-seeded peers already do.
  known=$(call "$ORCH" 'chainSelectorOf(uint256)(uint64)' "$CHAIN" "$pid")
  [ "$known" = "$psel" ] || self_txs+=("$(tx "$pid" "$psel")")
done

if [ ${#self_txs[@]} -gt 0 ]; then
  batch "$CHAIN" "$ID" "setChainSelector on the CcipOivDeployer $ORCH of $CHAIN itself: its own id (so it can originate a fan-out) and any counterpart its constructor-seeded registry lacks. Execute this batch before the counterparts' batches." "${self_txs[@]}"
else
  echo "  $CHAIN: own registry complete"
fi

if [ "$MODE" = "--check" ]; then
  [ "$pending" -eq 0 ] && { echo "$CHAIN is fully wired"; exit 0; }
  echo "$pending transaction(s) pending"; exit 1
fi
rm -rf "$OUT"
if [ "$pending" -gt 0 ]; then mkdir -p "$(dirname "$OUT")" && cp -R "$STAGE" "$OUT"; fi
echo "wrote $OUT ($pending transaction(s))"

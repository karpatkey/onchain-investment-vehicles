#!/usr/bin/env bash
# Write the Safe Transaction Builder batches that wire a deployed chain into the CCIP topology after
# the fact. Needed for every chain outside the registry `CcipOivDeployer` seeds in its constructor
# (robinhood, and any chain added later): `chainSelectorOf(<id>) == 0` on every orchestrator, so the
# chain can neither originate a fan-out (`onlyWiredChain`) nor be accepted as a source (`ccipReceive`
# checks `_isKnownSelector`), and no other chain lists it as a destination.
#
# Usage:
#   source .env && script/wire-chain.sh <chain-name>           # write script/safe-txs/ccip-wire-<chain>/
#   source .env && script/wire-chain.sh <chain-name> --check   # read back only
# Exit codes: 0 done (nothing pending / batches written), 1 entries still pending (--check only),
# 2 refused or failed (bad RPC, wrong chain, unexpected on-chain state, batches already committed).
#
# What it writes, one Safe batch per file, numbered in the ORDER THEY MUST BE EXECUTED (each by that
# orchestrator's owner, the Security Council Safe in production):
#   1-<chain>.json        on the chain itself: setChainSelector for every counterpart its registry
#                         lacks (constructor-seeded peers are already there, so often absent).
#   2-<counterpart>.json  on each counterpart: setChainSelector(<chain>, <selector>). Any order.
#   3-<chain>.json        on the chain itself: setChainSelector(<chain>, <selector>), alone. LAST.
#   manifest.json         the list of files above, pinned by test/CcipWiringBatches.t.sol.
#
# Why this order: `ccipReceive` only checks that the SOURCE selector is known, while originating is
# gated by `onlyWiredChain` (the chain's OWN id) and `deployEverywhere` / `dispatchTo` are
# permissionless. Once step 3 lands, anyone can fan out from the chain to every lane it knows; a
# counterpart whose step 2 has not landed yet reverts `InvalidSourceChain` and that lane's CCIP fee is
# lost. Conversely a counterpart wired in step 2 may already send to the chain, which accepts it only
# if it knows that counterpart (step 1, or the constructor seed). So: 1, then every 2, then 3.
#
# Counterparts are the deployed orchestrators (script/deployed-infra.json) with a CCIP lane to or from
# the chain, asked live of both configured routers. A pair with no lane gets nothing: no message could
# cross it, and a registry entry there would only be a future lane nobody reviewed. Entries already in
# place are skipped. Committed batches are the reviewed record of what the Council signs, so write
# mode never touches an existing directory: track execution with --check, and delete the directory by
# hand only to regenerate before anything was executed.
set -Eeuo pipefail
trap '[ "$BASH_SUBSHELL" -gt 0 ] || echo "wire-chain.sh: failed at line $LINENO" >&2; exit 2' ERR

die() { echo "$*" >&2; exit 2; }
CHAIN="${1:-}"
MODE="${2:-write}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REG="$ROOT/script/ccip-networks.json"
INFRA="$ROOT/script/deployed-infra.json"
[ -n "$CHAIN" ] || die "usage: wire-chain.sh <chain-name> [--check]"
[ "$MODE" = "write" ] || [ "$MODE" = "--check" ] || die "unknown mode '$MODE' (expected --check)"
command -v jq >/dev/null || die "jq required"
command -v cast >/dev/null || die "cast required"
cd "$ROOT" # rpc aliases resolve through foundry.toml

ORCH=$(jq -r .canonical.ccipOivDeployer "$INFRA")
row() { jq -c --arg n "$1" '.networks[] | select(.name==$n)' "$REG"; }
lower() { tr 'A-F' 'a-f'; }
# cast annotates large integers ("5009297550715157269 [5.009e18]"); keep the bare value for comparison.
call() { cast call "$1" "$2" "${@:4}" --rpc-url "$3" | awk '{print $1}'; }
# The rpc alias must reach the chain the registry names: a mis-pointed URL would read another chain's
# registry and report entries as present (or absent) that are not.
same_chain() {
  local got
  got=$(cast chain-id --rpc-url "$1")
  [ "$got" = "$2" ] || die "rpc alias '$1' answers chain id $got, not $2: fix its URL"
}

OUT="$ROOT/script/safe-txs/ccip-wire-$CHAIN"
if [ "$MODE" = "write" ] && [ -e "$OUT" ]; then
  die "$OUT already exists: committed batches are not rewritten. Track execution with --check; delete the directory by hand only to regenerate before anything was executed."
fi

entry=$(row "$CHAIN")
[ -n "$entry" ] || die "chain '$CHAIN' not in registry"
ID=$(echo "$entry" | jq -r .chainId)
SEL=$(echo "$entry" | jq -r .ccipChainSelector)
same_chain "$CHAIN" "$ID"

# The chain's own orchestrator must exist and be configured before anything can point at it: a
# counterpart that lists a chain with no receiver at the canonical address pays CCIP to deliver nothing.
# Every read below is its own assignment, so a failed RPC aborts instead of reading as "absent".
code=$(cast code "$ORCH" --rpc-url "$CHAIN")
[ "$code" != "0x" ] || die "no CcipOivDeployer on $CHAIN: deploy it first (script/chains/Deploy_<Chain>.s.sol)"
ROUTER=$(call "$ORCH" 'router()(address)' "$CHAIN")
[ "$(echo "$ROUTER" | lower)" = "$(echo "$entry" | jq -r .ccipRouter | lower)" ] \
  || die "$CHAIN orchestrator router $ROUTER differs from the registry's: configure() it first"

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

# Files land in a staging dir and are copied to $OUT only once every read succeeded.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
AT="$(date +%s)000"
pending=0
pending_steps=()
files=()
# batch <step> <name> <chainId> <description> <tx-json>... : one Builder file executed by that chain's owner.
batch() {
  local step=$1 name=$2 cid=$3 desc=$4; shift 4
  local owner owner_code file="$step-$name.json"
  owner=$(call "$ORCH" 'owner()(address)' "$name")
  owner_code=$(cast code "$owner" --rpc-url "$name")
  [ "$owner_code" != "0x" ] || die "$name: orchestrator owner $owner is not a contract, so this is no Safe batch; refusing"
  pending=$((pending + $#))
  pending_steps+=("$step")
  files+=("$file")
  echo "  step $step, $file: $# transaction(s) for owner $owner"
  [ "$MODE" = "write" ] || return 0
  printf '%s\n' "$@" | jq -s --arg cid "$cid" --arg owner "$owner" --arg chain "$CHAIN" --arg name "$name" \
    --arg step "$step" --arg desc "$desc" --argjson at "$AT" '{
      version: "1.0", chainId: $cid, createdAt: $at,
      meta: {
        name: ("CCIP wiring of " + $chain + ", step " + $step + " (" + $name + ") - setChainSelector on the CcipOivDeployer"),
        description: $desc, txBuilderVersion: "1.16.5",
        createdFromSafeAddress: $owner, createdFromOwnerAddress: ""
      },
      transactions: .
    }' > "$STAGE/$file"
}

ORDER="Execute in file order: 1-$CHAIN.json (if present), then every 2-<counterpart>.json in any order, then 3-$CHAIN.json LAST."
echo "=== CCIP wiring of $CHAIN (chainId $ID, selector $SEL); orchestrator $ORCH ==="
accept_txs=()
counterpart_batches=()
deployed=$(jq -r '.chains[] | select(.deployed == true) | .name' "$INFRA")
[ -n "$deployed" ] || die "no deployed chains in $INFRA"
present=0
for name in $deployed; do
  [ "$name" != "$CHAIN" ] || continue
  peer=$(row "$name"); [ -n "$peer" ] || die "$name is in deployed-infra.json but not in the registry"
  pid=$(echo "$peer" | jq -r .chainId); psel=$(echo "$peer" | jq -r .ccipChainSelector)
  same_chain "$name" "$pid"
  prouter=$(call "$ORCH" 'router()(address)' "$name")
  [ "$(echo "$prouter" | lower)" = "$(echo "$peer" | jq -r .ccipRouter | lower)" ] \
    || die "$name orchestrator router $prouter differs from the registry's"
  out=$(call "$ROUTER" 'isChainSupported(uint64)(bool)' "$CHAIN" "$psel")
  in=$(call "$prouter" 'isChainSupported(uint64)(bool)' "$name" "$SEL")
  if [ "$out" != "true" ] && [ "$in" != "true" ]; then echo "  $name: no lane either way, skipped"; continue; fi

  have=$(call "$ORCH" 'chainSelectorOf(uint256)(uint64)' "$name" "$ID")
  if [ "$have" = "$SEL" ]; then
    echo "  $name: already lists $CHAIN"
    present=$((present + 1))
  elif [ "$have" != "0" ]; then
    die "$name maps $ID to selector $have, not $SEL: correct it by hand, this script only adds"
  else
    counterpart_batches+=("$name|$pid|$out|$in")
  fi
  # The chain's own registry must know the counterpart too; constructor-seeded peers already do.
  known=$(call "$ORCH" 'chainSelectorOf(uint256)(uint64)' "$CHAIN" "$pid")
  if [ "$known" != "$psel" ]; then
    [ "$known" = "0" ] || die "$CHAIN maps $pid to selector $known, not $psel: correct it by hand"
    accept_txs+=("$(tx "$pid" "$psel")")
  fi
done

if [ ${#accept_txs[@]} -gt 0 ]; then
  batch 1 "$CHAIN" "$ID" "Step 1 of the CCIP wiring of $CHAIN: setChainSelector on the CcipOivDeployer $ORCH of $CHAIN itself, for every counterpart its constructor-seeded registry lacks, so it accepts their stacks before they start sending. $ORDER" "${accept_txs[@]}"
fi
for b in "${counterpart_batches[@]+"${counterpart_batches[@]}"}"; do
  IFS='|' read -r name pid out in <<<"$b"
  batch 2 "$name" "$pid" "Step 2 of the CCIP wiring of $CHAIN: setChainSelector($ID, $SEL) on the CcipOivDeployer $ORCH of $name, so it accepts stacks from $CHAIN and lists it as a destination. Lanes read live by script/wire-chain.sh: $CHAIN->$name $out, $name->$CHAIN $in. $ORDER" "$(tx "$ID" "$SEL")"
done
own=$(call "$ORCH" 'chainSelectorOf(uint256)(uint64)' "$CHAIN" "$ID")
if [ "$own" = "$SEL" ]; then
  echo "  $CHAIN: own id already set (can originate)"
  present=$((present + 1))
  # Origin open while counterparts still reject it: a fan-out from here can lose CCIP fees right now.
  if [ "$pending" -gt 0 ]; then
    echo "  WARNING: $CHAIN can already originate while $pending entr(y/ies) are pending: execute them now" >&2
  fi
elif [ "$own" != "0" ]; then
  die "$CHAIN maps its own id $ID to selector $own, not $SEL: correct it by hand"
else
  batch 3 "$CHAIN" "$ID" "Step 3 (LAST) of the CCIP wiring of $CHAIN: setChainSelector($ID, $SEL) on its own CcipOivDeployer $ORCH, which lets anyone fan out from $CHAIN. Execute only after every 1-/2- batch has landed: a counterpart not yet wired rejects the stack and its CCIP fee is lost. $ORDER" "$(tx "$ID" "$SEL")"
fi

if [ "$MODE" = "--check" ]; then
  [ "$pending" -eq 0 ] && { echo "$CHAIN is fully wired"; exit 0; }
  next=3; for s in "${pending_steps[@]}"; do [ "$s" -lt "$next" ] && next=$s; done
  echo "$pending transaction(s) pending; execute the step-$next batch(es) next"
  exit 1
fi
[ "$pending" -gt 0 ] || { echo "$CHAIN is fully wired: nothing to write"; exit 0; }
# Execution has begun but the directory is gone: regenerating now would commit a smaller set than the
# Council reviewed and signed. Restore the directory from git instead.
[ "$present" -eq 0 ] || die "$present entr(y/ies) already on-chain and $pending pending: execution has begun, so restore $OUT from git rather than regenerating it"
jq -n --arg chain "$CHAIN" --argjson id "$ID" --arg sel "$SEL" --arg orch "$ORCH" --arg order "$ORDER" \
  '{chain: $chain, chainId: $id, ccipChainSelector: $sel, orchestrator: $orch, order: $order, files: $ARGS.positional}' \
  --args "${files[@]}" > "$STAGE/manifest.json"
mkdir -p "$OUT"
cp "$STAGE"/*.json "$OUT"/
echo "wrote $OUT ($pending transaction(s) in ${#files[@]} batch(es)). $ORDER"

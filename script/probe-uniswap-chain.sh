#!/usr/bin/env bash
# Probe a chain for everything UniswapV3PositionVault needs before it can be deployed there.
#
# Usage:  RPC=$ROBINHOOD_URL bash script/probe-uniswap-chain.sh [WETH] [USDG]
#
# Answers, in order: is this chain reachable, is Uniswap v3 deployed on it, does the position
# manager agree with the factory, do the two tokens exist, which fee tiers have a pool, and — the
# one that actually blocks initialize — does each pool have enough oracle history for the TWAP
# window the vault is configured with.
set -uo pipefail

: "${RPC:?set RPC to the chain's endpoint}"
WETH="${1:-}"
USDG="${2:-}"

# The addresses Uniswap uses on most EVM chains. Deliberately probed rather than assumed.
FACTORY_CANONICAL=0x1F98431c8aD98523631AE4a59f267346ea31F984
NPM_CANONICAL=0xC36442b4a4522E871399CD717aBDD847Ab11FE88

say() { printf '%s\n' "$*"; }
has_code() { [ "$(cast code "$1" --rpc-url "$RPC" 2>/dev/null | tr -d '\n')" != "0x" ]; }

say "== chain =="
say "chainId:     $(cast chain-id --rpc-url "$RPC" 2>&1)"
say "blockNumber: $(cast block-number --rpc-url "$RPC" 2>&1)"

say ""
say "== uniswap v3 infrastructure =="
for pair in "factory:$FACTORY_CANONICAL" "positionManager:$NPM_CANONICAL"; do
  name=${pair%%:*}; addr=${pair#*:}
  if has_code "$addr"; then say "$name at canonical $addr: HAS CODE"
  else say "$name at canonical $addr: NO CODE — must be found for this chain"; fi
done

# The vault resolves its pool through the position manager's own factory, so this is the pairing
# that matters, not whichever factory address someone quotes.
NPM_FACTORY=$(cast call "$NPM_CANONICAL" "factory()(address)" --rpc-url "$RPC" 2>/dev/null)
say "positionManager.factory(): ${NPM_FACTORY:-<call failed>}"

[ -z "$WETH" ] && { say ""; say "Pass WETH and USDG addresses to probe the pools."; exit 0; }

say ""
say "== tokens =="
for pair in "WETH:$WETH" "USDG:$USDG"; do
  name=${pair%%:*}; addr=${pair#*:}
  sym=$(cast call "$addr" "symbol()(string)" --rpc-url "$RPC" 2>/dev/null)
  dec=$(cast call "$addr" "decimals()(uint8)" --rpc-url "$RPC" 2>/dev/null)
  say "$name $addr  symbol=${sym:-?}  decimals=${dec:-?}"
done

# token0 < token1 is a vault requirement, and which token is which decides how prices read.
lower=$(printf '%s\n%s\n' "${WETH,,}" "${USDG,,}" | sort | head -1)
say "token0 (lower address): $lower"

say ""
say "== WETH/USDG pools, per fee tier =="
FACTORY=${NPM_FACTORY:-$FACTORY_CANONICAL}
for fee in 100 500 3000 10000; do
  pool=$(cast call "$FACTORY" "getPool(address,address,uint24)(address)" "$WETH" "$USDG" "$fee" --rpc-url "$RPC" 2>/dev/null)
  if [ -z "$pool" ] || [ "$pool" = "0x0000000000000000000000000000000000000000" ]; then
    say "fee $fee: no pool"
    continue
  fi
  liq=$(cast call "$pool" "liquidity()(uint128)" --rpc-url "$RPC" 2>/dev/null)
  slot0=$(cast call "$pool" "slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)" --rpc-url "$RPC" 2>/dev/null)
  # observationCardinality is slot0's 4th field: 1 means the pool has never been prepared for a
  # TWAP, and initialize will revert TwapUnavailable for any non-zero window.
  card=$(printf '%s\n' "$slot0" | sed -n '4p')
  say "fee $fee: $pool  liquidity=${liq:-?}  observationCardinality=${card:-?}"
done

say ""
say "A cardinality of 1 means no TWAP history: increaseObservationCardinalityNext is permissionless,"
say "but the buffer must then be filled by real swaps spanning the full twapPeriod before the vault"
say "will initialize."

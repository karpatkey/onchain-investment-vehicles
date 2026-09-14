#!/usr/bin/env bash
# Deploy the four WETH/USDG vaults on Robinhood Chain, sharing one implementation.
#
#   bash script/deploy-robinhood-vaults.sh
#
# The first vault deploys the library and the implementation; the other three reuse that
# implementation, so they cost about 0.8M gas each instead of 11.2M. The implementation address is
# taken from the first run's own output rather than typed in, which is the step most likely to go
# wrong by hand.
#
# forge prompts for the keystore password once per vault. To be asked once instead, point
# ETH_PASSWORD at a mode-600 file holding it, and delete that file afterwards.
set -euo pipefail

ACCOUNT=research-deployer
SENDER=0xe20554414dbc7cfd5838d4c19e64bfad36c25d82
RPC=robinhood
SCRIPT=script/DeployUniswapV3PositionVault.s.sol:DeployUniswapV3PositionVault
LOG_DIR=deploy-logs
mkdir -p "$LOG_DIR"

FIRST=weth-usdg-robinhood-100
REST=(weth-usdg-robinhood-500 weth-usdg-robinhood-3000 weth-usdg-robinhood-10000)

# The script logs "vault proxy:    0x..." and "implementation: 0x..."; pull them back out.
field() { grep -oiE "$1[[:space:]]+0x[0-9a-fA-F]{40}" "$2" | grep -oiE '0x[0-9a-fA-F]{40}' | tail -1; }

echo "=== 1/4  $FIRST  (deploys library + implementation) ==="
forge script "$SCRIPT" --sig "run(string)" "$FIRST" \
  --account "$ACCOUNT" --sender "$SENDER" --rpc-url "$RPC" --broadcast \
  2>&1 | tee "$LOG_DIR/$FIRST.log"

IMPL=$(field 'implementation:' "$LOG_DIR/$FIRST.log")
PROXY=$(field 'vault proxy:' "$LOG_DIR/$FIRST.log")

if [ -z "$IMPL" ]; then
  echo "Could not read the implementation address from $LOG_DIR/$FIRST.log — stopping." >&2
  echo "Nothing after this point has run. Inspect that log before retrying." >&2
  exit 1
fi

echo
echo "implementation: $IMPL"
echo "vault (fee 100): $PROXY"
echo

i=2
for name in "${REST[@]}"; do
  echo "=== $i/4  $name  (reusing $IMPL) ==="
  forge script "$SCRIPT" --sig "run(string,address)" "$name" "$IMPL" \
    --account "$ACCOUNT" --sender "$SENDER" --rpc-url "$RPC" --broadcast \
    2>&1 | tee "$LOG_DIR/$name.log"
  echo "  -> $(field 'vault proxy:' "$LOG_DIR/$name.log")"
  i=$((i + 1))
done

echo
echo "=== deployed ==="
echo "implementation  $IMPL"
for name in "$FIRST" "${REST[@]}"; do
  printf '%-32s %s\n' "$name" "$(field 'vault proxy:' "$LOG_DIR/$name.log")"
done
echo
echo "Logs in $LOG_DIR/. Paste the block above back into the session to have the"
echo "end state checked on-chain and the addresses recorded."

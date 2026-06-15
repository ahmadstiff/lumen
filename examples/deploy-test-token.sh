#!/usr/bin/env bash
# Deploy a throwaway MockERC20 test token to a Pharos network, so the Lumen
# demo has an ERC-20 to move. Lumen itself deploys NO custom contracts; this
# token is only a test asset for generating live demo / proof transactions.
#
# Sender (use exactly one; keystore/account recommended):
#   LUMEN_ACCOUNT   cast-managed account name (cast wallet import ...)
#   LUMEN_KEYSTORE  path to an encrypted keystore JSON
#   LUMEN_PRIVATE_KEY  raw hex key — TESTNET ONLY, refused on mainnet
#
# Optional env:
#   LUMEN_NETWORK   atlantic (default) | pacific
#   TOKEN_NAME      default "Lumen Test USD"
#   TOKEN_SYMBOL    default "lUSD"
#   TOKEN_DECIMALS  default 6
#   TOKEN_SUPPLY    human units minted to deployer, default 1000000
#
# Usage:
#   LUMEN_ACCOUNT=lumen-sender examples/deploy-test-token.sh
#
# Prints the deployed token address + deploy tx hash + explorer URL.

set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
NETWORKS="$REPO_ROOT/assets/networks.json"

command -v forge >/dev/null 2>&1 || { printf 'forge (foundry) is required\n' >&2; exit 127; }
command -v jq >/dev/null 2>&1 || { printf 'jq is required\n' >&2; exit 127; }

NET="${LUMEN_NETWORK:-atlantic}"
RPC_URL="${LUMEN_RPC_URL:-$(jq -r --arg n "$NET" '.networks[$n].rpc_url // empty' "$NETWORKS")}"
EXPLORER="$(jq -r --arg n "$NET" '.networks[$n].explorer_url // empty' "$NETWORKS")"
IS_TESTNET="$(jq -r --arg n "$NET" '.networks[$n].is_testnet // false' "$NETWORKS")"

[[ -z "$RPC_URL" ]] && { printf 'unknown network: %s\n' "$NET" >&2; exit 2; }

# Resolve the sender flag set (prefer keystore/account; raw key testnet-only).
flags=()
if [[ -n "${LUMEN_KEYSTORE:-}" ]]; then
  flags+=(--keystore "$LUMEN_KEYSTORE")
elif [[ -n "${LUMEN_ACCOUNT:-}" ]]; then
  flags+=(--account "$LUMEN_ACCOUNT")
elif [[ -n "${LUMEN_PRIVATE_KEY:-}" ]]; then
  if [[ "$IS_TESTNET" != "true" ]]; then
    printf 'refusing raw LUMEN_PRIVATE_KEY on non-testnet %s; use LUMEN_KEYSTORE or LUMEN_ACCOUNT\n' "$NET" >&2
    exit 3
  fi
  flags+=(--private-key "$LUMEN_PRIVATE_KEY")
else
  printf 'no sender configured: set LUMEN_ACCOUNT (recommended), LUMEN_KEYSTORE, or LUMEN_PRIVATE_KEY (testnet only)\n' >&2
  exit 3
fi

NAME="${TOKEN_NAME:-Lumen Test USD}"
SYMBOL="${TOKEN_SYMBOL:-lUSD}"
DECIMALS="${TOKEN_DECIMALS:-6}"
SUPPLY_HUMAN="${TOKEN_SUPPLY:-1000000}"
SUPPLY_BASE="$(printf '%s * 10 ^ %s\n' "$SUPPLY_HUMAN" "$DECIMALS" | bc)"

printf '[deploy] network=%s rpc=%s\n' "$NET" "$RPC_URL" >&2
printf '[deploy] token="%s" (%s) decimals=%s supply=%s\n' "$NAME" "$SYMBOL" "$DECIMALS" "$SUPPLY_HUMAN" >&2

# forge create streams compiler/broadcast logs to stderr; JSON result to stdout.
out="$(forge create src/mocks/MockERC20.sol:MockERC20 \
  --root "$REPO_ROOT/contracts" \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --json \
  "${flags[@]}" \
  --constructor-args "$NAME" "$SYMBOL" "$DECIMALS" "$SUPPLY_BASE")" \
  || { printf '[deploy] forge create failed (see logs above)\n' >&2; exit 6; }

addr="$(printf '%s' "$out" | jq -r '.deployedTo // empty')"
tx="$(printf '%s' "$out" | jq -r '.transactionHash // empty')"

[[ -z "$addr" ]] && { printf '[deploy] no address in output:\n%s\n' "$out" >&2; exit 6; }

printf '\nDeployed MockERC20\n'
printf '  token_address: %s\n' "$addr"
printf '  deploy_tx:     %s\n' "$tx"
printf '  explorer:      %s/address/%s\n' "$EXPLORER" "$addr"
printf '\nNext steps:\n'
printf '  export LUMEN_DEMO_TOKEN=%s\n' "$addr"
printf '  examples/demo-flow.sh     # live pay.once -> receipt.generate -> ledger.query\n'

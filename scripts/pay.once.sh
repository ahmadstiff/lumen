#!/usr/bin/env bash
# pay.once — send a single ERC-20 payment with bounded slippage + audit trail.
#
# Reads JSON from stdin. Writes a structured JSON receipt to stdout.
# See references/pay.once.md for the full request schema and examples.

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

CAPABILITY="pay.once"
trap_capability "$CAPABILITY"

require_cmd jq cast

# -----------------------------------------------------------------------------
# Parse request
# -----------------------------------------------------------------------------
REQUEST="$(json_require_object)"

NETWORK_OVERRIDE="$(json_get_or '.network' "$REQUEST" "")"
[[ -n "$NETWORK_OVERRIDE" ]] && export LUMEN_NETWORK="$NETWORK_OVERRIDE"

IDEMPOTENCY_KEY="$(json_get_or '.idempotency_key' "$REQUEST" "")"

PARAMS="$(json_get '.params' "$REQUEST" || true)"
[[ -z "$PARAMS" ]] && {
  emit_error "$CAPABILITY" "missing_params" "request.params is required"
  exit 2
}

TOKEN="$(json_get '.token' "$PARAMS" || true)"
RECIPIENT="$(json_get '.recipient' "$PARAMS" || true)"
AMOUNT="$(json_get '.amount' "$PARAMS" || true)"
MODE="$(json_get_or '.mode' "$PARAMS" "transfer")"
MEMO="$(json_get_or '.memo' "$PARAMS" "")"
MAX_GAS_GWEI="$(json_get_or '.max_gas_price_gwei' "$PARAMS" "")"

# Validate inputs.
[[ -z "$TOKEN"     ]] && { emit_error "$CAPABILITY" "missing_param" "params.token required"     ; exit 2; }
[[ -z "$RECIPIENT" ]] && { emit_error "$CAPABILITY" "missing_param" "params.recipient required" ; exit 2; }
[[ -z "$AMOUNT"    ]] && { emit_error "$CAPABILITY" "missing_param" "params.amount required"    ; exit 2; }

assert_address "$TOKEN" "params.token"
assert_address "$RECIPIENT" "params.recipient"
assert_uint    "$AMOUNT" "params.amount"

case "$MODE" in
  transfer|permit2) ;;
  *)
    emit_error "$CAPABILITY" "invalid_mode" "params.mode must be 'transfer' or 'permit2'" "$(jq -n --arg m "$MODE" '{got:$m}')"
    exit 2
    ;;
esac

# -----------------------------------------------------------------------------
# Idempotency replay — return existing receipt if key seen before.
# -----------------------------------------------------------------------------
if [[ -n "$IDEMPOTENCY_KEY" ]]; then
  EXISTING="$(ledger_lookup "$IDEMPOTENCY_KEY" || true)"
  if [[ -n "$EXISTING" ]]; then
    log_info "idempotency hit for key '$IDEMPOTENCY_KEY' — returning cached receipt"
    emit_ok "$CAPABILITY" "$(printf '%s' "$EXISTING" | jq '. + {replayed: true}')"
    exit 0
  fi
fi

# -----------------------------------------------------------------------------
# Resolve network + sender
# -----------------------------------------------------------------------------
NETWORK_JSON="$(resolve_network)"
RPC_URL="$(jq -r .rpc_url <<<"$NETWORK_JSON")"
CHAIN_ID="$(jq -r .chain_id <<<"$NETWORK_JSON")"
EXPLORER="$(jq -r .explorer_url <<<"$NETWORK_JSON")"
NETWORK_KEY="$(jq -r .key <<<"$NETWORK_JSON")"

# Mainnet safety: refuse raw private keys.
IS_TESTNET="$(jq -r ".networks[\"$NETWORK_KEY\"].is_testnet" "$LUMEN_NETWORKS_FILE")"
if [[ "$IS_TESTNET" != "true" && -n "${LUMEN_PRIVATE_KEY:-}" ]]; then
  emit_error "$CAPABILITY" "policy_violation" \
    "raw LUMEN_PRIVATE_KEY refused on mainnet; use LUMEN_KEYSTORE or LUMEN_ACCOUNT"
  exit 3
fi

mapfile -t SENDER_FLAGS < <(sender_cast_flags)

# Resolve sender address. cast wallet address respects the same flag set.
SENDER_ADDR="$(cast wallet address "${SENDER_FLAGS[@]}" 2>/dev/null || true)"
if [[ -z "$SENDER_ADDR" ]]; then
  emit_error "$CAPABILITY" "sender_resolution_failed" \
    "could not derive sender address from configured wallet"
  exit 3
fi
SENDER_ADDR="$(to_lower_address "$SENDER_ADDR")"

# -----------------------------------------------------------------------------
# Preflight: balance check + decimals lookup.
# -----------------------------------------------------------------------------
DECIMALS="$(erc20_decimals "$RPC_URL" "$TOKEN")"
SYMBOL="$(erc20_symbol "$RPC_URL" "$TOKEN" 2>/dev/null || printf 'TOKEN')"
BALANCE="$(erc20_balance_of "$RPC_URL" "$TOKEN" "$SENDER_ADDR")"

if bignum_lt "$BALANCE" "$AMOUNT"; then
  emit_error "$CAPABILITY" "insufficient_balance" \
    "sender balance $BALANCE < amount $AMOUNT for $SYMBOL" \
    "$(jq -n --arg b "$BALANCE" --arg a "$AMOUNT" --arg s "$SYMBOL" \
       '{balance:$b, amount:$a, symbol:$s}')"
  exit 4
fi

# -----------------------------------------------------------------------------
# Execute payment. P0 implements the 'transfer' mode only; 'permit2' returns
# a structured "not_implemented" so the agent can fall back gracefully.
# -----------------------------------------------------------------------------
if [[ "$MODE" == "permit2" ]]; then
  emit_error "$CAPABILITY" "not_implemented" \
    "permit2 mode is reserved for the approval.scope + multicall flow in pay.split" \
    "$(jq -n '{hint: "use mode=transfer for direct sender-funded payments"}')"
  exit 5
fi

GAS_FLAGS=()
if [[ -n "$MAX_GAS_GWEI" ]]; then
  assert_uint "$MAX_GAS_GWEI" "params.max_gas_price_gwei"
  GAS_FLAGS+=(--gas-price "${MAX_GAS_GWEI}gwei")
fi

log_info "pay.once → $RECIPIENT amount=$AMOUNT token=$TOKEN ($SYMBOL) network=$NETWORK_KEY"

TX_OUTPUT="$(cast send \
  --rpc-url "$RPC_URL" \
  --json \
  "${SENDER_FLAGS[@]}" \
  "${GAS_FLAGS[@]}" \
  "$TOKEN" \
  "transfer(address,uint256)" \
  "$RECIPIENT" "$AMOUNT" 2>&1)" || {
    log_error "cast send failed: $TX_OUTPUT"
    emit_error "$CAPABILITY" "tx_send_failed" \
      "cast send returned non-zero" \
      "$(jq -Rn --arg o "$TX_OUTPUT" '{cast_output:$o}')"
    exit 6
  }

TX_HASH="$(jq -r .transactionHash <<<"$TX_OUTPUT" 2>/dev/null || printf 'unknown')"
TX_STATUS="$(jq -r .status <<<"$TX_OUTPUT" 2>/dev/null || printf 'unknown')"
TX_BLOCK="$(jq -r .blockNumber <<<"$TX_OUTPUT" 2>/dev/null || printf 'unknown')"
TX_GAS_USED="$(jq -r .gasUsed <<<"$TX_OUTPUT" 2>/dev/null || printf 'unknown')"

# Normalize status: cast returns 0x1 / 0x0; surface as boolean.
STATUS_OK="false"
[[ "$TX_STATUS" == "0x1" || "$TX_STATUS" == "1" ]] && STATUS_OK="true"

# -----------------------------------------------------------------------------
# Build receipt envelope
# -----------------------------------------------------------------------------
IDEM_OUT="$IDEMPOTENCY_KEY"
[[ -z "$IDEM_OUT" ]] && IDEM_OUT="$(new_idempotency_key "pay-once")"

RECEIPT="$(jq -n \
  --arg cap "$CAPABILITY" \
  --arg network "$NETWORK_KEY" \
  --argjson chain_id "$CHAIN_ID" \
  --arg rpc "$RPC_URL" \
  --arg sender "$SENDER_ADDR" \
  --arg token "$TOKEN" \
  --arg symbol "$SYMBOL" \
  --argjson decimals "${DECIMALS:-0}" \
  --arg recipient "$RECIPIENT" \
  --arg amount "$AMOUNT" \
  --arg tx_hash "$TX_HASH" \
  --arg tx_block "$TX_BLOCK" \
  --arg tx_gas_used "$TX_GAS_USED" \
  --argjson tx_ok "$STATUS_OK" \
  --arg explorer "$EXPLORER" \
  --arg memo "$MEMO" \
  --arg idem "$IDEM_OUT" \
  --arg mode "$MODE" \
  '{
    capability: $cap,
    network: $network,
    chain_id: $chain_id,
    rpc_url: $rpc,
    mode: $mode,
    sender: $sender,
    token: {address: $token, symbol: $symbol, decimals: $decimals},
    recipient: $recipient,
    amount: $amount,
    memo: (if $memo == "" then null else $memo end),
    tx: {
      hash: $tx_hash,
      block_number: $tx_block,
      gas_used: $tx_gas_used,
      ok: $tx_ok,
      explorer_url: ($explorer + "/tx/" + $tx_hash)
    },
    idempotency_key: $idem
  }')"

# Persist to append-only ledger.
printf '%s\n' "$RECEIPT" | ledger_append
log_ok "tx $TX_HASH on $NETWORK_KEY (gas=$TX_GAS_USED)"

emit_ok "$CAPABILITY" "$RECEIPT"

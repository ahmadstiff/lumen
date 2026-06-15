#!/usr/bin/env bash
# approval.scope — set a strictly scoped ERC-20 / Permit2 approval.
#
# Two modes:
#   - direct (default): ERC-20 approve(spender, amount). Expiry is logical
#     only and recorded in the receipt; the script REFUSES uint256.max.
#   - permit2: Permit2.approve(token, spender, amount, expiration). The
#     expiry is enforced on-chain by the canonical Permit2 contract.
#
# This capability enforces the Lumen "no unlimited approvals" policy:
# both `amount` and `expiry` are mandatory regardless of mode.
#
# See references/approval.scope.md.

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

CAPABILITY="approval.scope"
trap_capability "$CAPABILITY"

require_cmd jq cast

# uint256 max as decimal — the value we refuse as an "unlimited" approval.
UINT256_MAX="115792089237316195423570985008687907853269984665640564039457584007913129639935"

# -----------------------------------------------------------------------------
# Parse + validate
# -----------------------------------------------------------------------------
REQUEST="$(json_require_object)"

NETWORK_OVERRIDE="$(json_get_or '.network' "$REQUEST" "")"
[[ -n "$NETWORK_OVERRIDE" ]] && export LUMEN_NETWORK="$NETWORK_OVERRIDE"

IDEMPOTENCY_KEY="$(json_get_or '.idempotency_key' "$REQUEST" "")"
PARAMS="$(json_get '.params' "$REQUEST" || true)"
[[ -z "$PARAMS" ]] && die "request.params is required" 2 missing_params

TOKEN="$(json_get '.token' "$PARAMS" || true)"
SPENDER="$(json_get '.spender' "$PARAMS" || true)"
AMOUNT="$(json_get '.amount' "$PARAMS" || true)"
EXPIRY="$(json_get '.expiry_unix' "$PARAMS" || true)"
MODE="$(json_get_or '.mode' "$PARAMS" "direct")"
MEMO="$(json_get_or '.memo' "$PARAMS" "")"

[[ -z "$TOKEN" ]]   && die "params.token required"     2 missing_param
[[ -z "$SPENDER" ]] && die "params.spender required"   2 missing_param
[[ -z "$AMOUNT" ]]  && die "params.amount required"    2 missing_param
[[ -z "$EXPIRY" ]]  && die "params.expiry_unix required (no unlimited approvals)" 2 missing_param

assert_address "$TOKEN" "params.token"
assert_address "$SPENDER" "params.spender"
assert_uint "$AMOUNT" "params.amount"
assert_uint "$EXPIRY" "params.expiry_unix"

case "$MODE" in
  direct|permit2) ;;
  *) die "params.mode must be 'direct' or 'permit2'" 2 invalid_mode ;;
esac

# Skill-scanner policy: refuse approvals that match uint256.max.
if [[ "$AMOUNT" == "$UINT256_MAX" ]]; then
  emit_error "$CAPABILITY" "policy_unlimited_approval" \
    "amount equals uint256.max which is treated as unlimited; supply a bounded value" \
    "$(jq -n --arg a "$AMOUNT" '{requested:$a}')"
  exit 3
fi

# Expiry must be in the future. Compare via bash uint arithmetic (uint64 fits).
NOW="$(date -u +%s)"
if (( EXPIRY <= NOW )); then
  die "params.expiry_unix=$EXPIRY must be > now=$NOW" 2 expiry_in_past
fi
EXPIRY_DELTA=$((EXPIRY - NOW))
# Hard cap: 365 days. Agents wanting longer must split into multiple windows.
if (( EXPIRY_DELTA > 31536000 )); then
  die "expiry window > 365 days violates scoped-approval policy" 2 expiry_too_long
fi

# -----------------------------------------------------------------------------
# Idempotency replay
# -----------------------------------------------------------------------------
if [[ -n "$IDEMPOTENCY_KEY" ]]; then
  EXISTING="$(ledger_lookup "$IDEMPOTENCY_KEY" || true)"
  if [[ -n "$EXISTING" ]]; then
    log_info "idempotency hit '$IDEMPOTENCY_KEY' — returning cached receipt"
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

IS_TESTNET="$(jq -r ".networks[\"$NETWORK_KEY\"].is_testnet" "$LUMEN_NETWORKS_FILE")"
[[ "$IS_TESTNET" != "true" && -n "${LUMEN_PRIVATE_KEY:-}" ]] \
  && die "raw LUMEN_PRIVATE_KEY refused on mainnet" 3 policy_violation

mapfile -t SENDER_FLAGS < <(sender_cast_flags)
SENDER_ADDR="$(cast wallet address "${SENDER_FLAGS[@]}" 2>/dev/null || true)"
[[ -n "$SENDER_ADDR" ]] || die "could not derive sender address" 3 sender_resolution_failed
SENDER_ADDR="$(to_lower_address "$SENDER_ADDR")"

DECIMALS="$(erc20_decimals "$RPC_URL" "$TOKEN")"
SYMBOL="$(erc20_symbol "$RPC_URL" "$TOKEN" 2>/dev/null || printf 'TOKEN')"

# -----------------------------------------------------------------------------
# Broadcast the approval
# -----------------------------------------------------------------------------
log_info "approval.scope mode=$MODE token=$SYMBOL spender=$SPENDER amount=$AMOUNT expiry=$EXPIRY"

if [[ "$MODE" == "direct" ]]; then
  TARGET="$TOKEN"
  SIG="approve(address,uint256)"
  ARGS=("$SPENDER" "$AMOUNT")
else
  TARGET="$(jq -r ".networks[\"$NETWORK_KEY\"].contracts.permit2" "$LUMEN_NETWORKS_FILE")"
  assert_address "$TARGET" "permit2 address"
  # Permit2.approve(address token, address spender, uint160 amount, uint48 expiration)
  SIG="approve(address,address,uint160,uint48)"
  ARGS=("$TOKEN" "$SPENDER" "$AMOUNT" "$EXPIRY")
fi

TX_OUTPUT="$(cast send \
  --rpc-url "$RPC_URL" --json \
  "${SENDER_FLAGS[@]}" \
  "$TARGET" "$SIG" "${ARGS[@]}" 2>&1)" || {
    log_error "approval broadcast failed: $TX_OUTPUT"
    emit_error "$CAPABILITY" "tx_send_failed" \
      "approval broadcast failed in $MODE mode" \
      "$(jq -Rn --arg o "$TX_OUTPUT" '{cast_output:$o}')"
    exit 6
  }

TX_HASH="$(jq -r .transactionHash <<<"$TX_OUTPUT")"
TX_BLOCK="$(jq -r .blockNumber  <<<"$TX_OUTPUT")"
TX_GAS="$(jq -r .gasUsed         <<<"$TX_OUTPUT")"
TX_STATUS="$(jq -r .status       <<<"$TX_OUTPUT")"
STATUS_OK="false"
[[ "$TX_STATUS" == "0x1" || "$TX_STATUS" == "1" ]] && STATUS_OK="true"

# -----------------------------------------------------------------------------
# Build receipt
# -----------------------------------------------------------------------------
IDEM_OUT="$IDEMPOTENCY_KEY"
[[ -z "$IDEM_OUT" ]] && IDEM_OUT="$(new_idempotency_key "approval-scope")"

EXPIRY_ISO="$(date -u -r "$EXPIRY" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || python3 -c "import datetime,sys;print(datetime.datetime.utcfromtimestamp(int(sys.argv[1])).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$EXPIRY")"

RECEIPT="$(jq -n \
  --arg cap "$CAPABILITY" \
  --arg mode "$MODE" \
  --arg network "$NETWORK_KEY" \
  --argjson chain_id "$CHAIN_ID" \
  --arg sender "$SENDER_ADDR" \
  --arg token "$TOKEN" \
  --arg symbol "$SYMBOL" \
  --argjson decimals "${DECIMALS:-0}" \
  --arg spender "$SPENDER" \
  --arg amount "$AMOUNT" \
  --argjson expiry "$EXPIRY" \
  --arg expiry_iso "$EXPIRY_ISO" \
  --arg target "$TARGET" \
  --arg tx_hash "$TX_HASH" \
  --arg tx_block "$TX_BLOCK" \
  --arg tx_gas "$TX_GAS" \
  --argjson tx_ok "$STATUS_OK" \
  --arg explorer "$EXPLORER" \
  --arg memo "$MEMO" \
  --arg idem "$IDEM_OUT" \
  '{
    capability: $cap,
    mode: $mode,
    network: $network,
    chain_id: $chain_id,
    sender: $sender,
    target_contract: $target,
    token: {address: $token, symbol: $symbol, decimals: $decimals},
    spender: $spender,
    amount: $amount,
    expiry_unix: $expiry,
    expiry_iso: $expiry_iso,
    memo: (if $memo == "" then null else $memo end),
    tx: {
      hash: $tx_hash,
      block_number: $tx_block,
      gas_used: $tx_gas,
      ok: $tx_ok,
      explorer_url: ($explorer + "/tx/" + $tx_hash)
    },
    idempotency_key: $idem
  }')"

printf '%s\n' "$RECEIPT" | ledger_append
log_ok "approval scoped: spender=$SPENDER amount=$AMOUNT expiry=$EXPIRY_ISO"
emit_ok "$CAPABILITY" "$RECEIPT"

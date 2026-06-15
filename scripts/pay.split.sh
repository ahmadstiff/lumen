#!/usr/bin/env bash
# pay.split — split a single ERC-20 amount across N recipients.
#
# Two execution modes:
#   - sequential (default): N independent transfer() transactions. No prior
#     approval needed. Not atomic across the set.
#   - multicall: single Multicall3.aggregate3() with N ERC-20.transferFrom()
#     calls. Atomic. Requires the sender to have approved Multicall3 first
#     (see approval.scope).
#
# Two amount-allocation strategies:
#   - amounts: caller supplies explicit per-recipient amounts.
#   - shares_bps + total: caller supplies basis-point shares (sum = 10000)
#     and a total. Last recipient absorbs the rounding remainder so the
#     payout sum is invariant.
#
# See references/pay.split.md.

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

CAPABILITY="pay.split"
trap_capability "$CAPABILITY"

require_cmd jq cast bc

# -----------------------------------------------------------------------------
# Parse request
# -----------------------------------------------------------------------------
REQUEST="$(json_require_object)"

NETWORK_OVERRIDE="$(json_get_or '.network' "$REQUEST" "")"
[[ -n "$NETWORK_OVERRIDE" ]] && export LUMEN_NETWORK="$NETWORK_OVERRIDE"

IDEMPOTENCY_KEY="$(json_get_or '.idempotency_key' "$REQUEST" "")"
PARAMS="$(json_get '.params' "$REQUEST" || true)"
[[ -z "$PARAMS" ]] && die "request.params is required" 2 missing_params

TOKEN="$(json_get '.token' "$PARAMS" || true)"
[[ -z "$TOKEN" ]] && die "params.token required" 2 missing_param
assert_address "$TOKEN" "params.token"

MODE="$(json_get_or '.mode' "$PARAMS" "sequential")"
case "$MODE" in
  sequential|multicall) ;;
  *) die "params.mode must be 'sequential' or 'multicall'" 2 invalid_mode ;;
esac

MEMO="$(json_get_or '.memo' "$PARAMS" "")"

RECIPIENTS_JSON="$(json_get '.recipients' "$PARAMS" || true)"
[[ -z "$RECIPIENTS_JSON" ]] && die "params.recipients array required" 2 missing_param

# Allocation strategy: either amounts[] or shares_bps[] + total.
AMOUNTS_JSON="$(json_get '.amounts' "$PARAMS" 2>/dev/null || true)"
SHARES_JSON="$(json_get '.shares_bps' "$PARAMS" 2>/dev/null || true)"
TOTAL="$(json_get '.total' "$PARAMS" 2>/dev/null || true)"

if [[ -z "$AMOUNTS_JSON" && -z "$SHARES_JSON" ]]; then
  die "supply either params.amounts[] or params.shares_bps[]+params.total" 2 missing_allocation
fi
if [[ -n "$AMOUNTS_JSON" && -n "$SHARES_JSON" ]]; then
  die "amounts and shares_bps are mutually exclusive" 2 conflicting_allocation
fi

# Parse arrays into bash arrays via jq.
mapfile -t RECIPIENTS < <(printf '%s' "$RECIPIENTS_JSON" | jq -r '.[]')
RECIPIENT_COUNT="${#RECIPIENTS[@]}"
(( RECIPIENT_COUNT > 0 )) || die "params.recipients must be non-empty" 2 empty_recipients

for r in "${RECIPIENTS[@]}"; do
  assert_address "$r" "params.recipients[i]"
done

# -----------------------------------------------------------------------------
# Compute final amount per recipient (bignum-safe).
# -----------------------------------------------------------------------------
declare -a AMOUNTS=()

if [[ -n "$AMOUNTS_JSON" ]]; then
  mapfile -t AMOUNTS < <(printf '%s' "$AMOUNTS_JSON" | jq -r '.[]')
  AMOUNT_COUNT="${#AMOUNTS[@]}"
  (( AMOUNT_COUNT == RECIPIENT_COUNT )) \
    || die "recipients ($RECIPIENT_COUNT) and amounts ($AMOUNT_COUNT) length mismatch" 2 length_mismatch
  for a in "${AMOUNTS[@]}"; do
    assert_uint "$a" "params.amounts[i]"
  done
  # Compute total = sum(amounts) via bc.
  TOTAL="0"
  for a in "${AMOUNTS[@]}"; do
    TOTAL="$(printf '%s+%s\n' "$TOTAL" "$a" | bc)"
  done
else
  # bps allocation. Validate count, individual range, and sum.
  [[ -z "$TOTAL" ]] && die "params.total required when using shares_bps" 2 missing_total
  assert_uint "$TOTAL" "params.total"

  mapfile -t SHARES < <(printf '%s' "$SHARES_JSON" | jq -r '.[]')
  SHARE_COUNT="${#SHARES[@]}"
  (( SHARE_COUNT == RECIPIENT_COUNT )) \
    || die "recipients ($RECIPIENT_COUNT) and shares_bps ($SHARE_COUNT) length mismatch" 2 length_mismatch

  SHARES_SUM="0"
  for s in "${SHARES[@]}"; do
    assert_uint "$s" "params.shares_bps[i]"
    (( s <= 10000 )) || die "share $s exceeds 10000 bps" 2 invalid_bps
    SHARES_SUM=$((SHARES_SUM + s))
  done
  (( SHARES_SUM == 10000 )) || die "shares_bps must sum to 10000, got $SHARES_SUM" 2 shares_sum_mismatch

  # Compute amounts: floor(total * share / 10000); last absorbs remainder.
  RUNNING_SUM="0"
  for ((i = 0; i < RECIPIENT_COUNT - 1; i++)); do
    amt="$(bignum_mul_div "$TOTAL" "${SHARES[i]}")"
    AMOUNTS[i]="$amt"
    RUNNING_SUM="$(printf '%s+%s\n' "$RUNNING_SUM" "$amt" | bc)"
  done
  AMOUNTS[RECIPIENT_COUNT - 1]="$(bignum_sub "$TOTAL" "$RUNNING_SUM")"
fi

# -----------------------------------------------------------------------------
# Idempotency replay
# -----------------------------------------------------------------------------
if [[ -n "$IDEMPOTENCY_KEY" ]]; then
  EXISTING="$(ledger_lookup "$IDEMPOTENCY_KEY" || true)"
  if [[ -n "$EXISTING" ]]; then
    log_info "idempotency hit for '$IDEMPOTENCY_KEY' — returning cached receipt"
    emit_ok "$CAPABILITY" "$(printf '%s' "$EXISTING" | jq '. + {replayed: true}')"
    exit 0
  fi
fi

# -----------------------------------------------------------------------------
# Resolve network, sender, multicall3 address.
# -----------------------------------------------------------------------------
NETWORK_JSON="$(resolve_network)"
RPC_URL="$(jq -r .rpc_url <<<"$NETWORK_JSON")"
CHAIN_ID="$(jq -r .chain_id <<<"$NETWORK_JSON")"
EXPLORER="$(jq -r .explorer_url <<<"$NETWORK_JSON")"
NETWORK_KEY="$(jq -r .key <<<"$NETWORK_JSON")"

IS_TESTNET="$(jq -r ".networks[\"$NETWORK_KEY\"].is_testnet" "$LUMEN_NETWORKS_FILE")"
if [[ "$IS_TESTNET" != "true" && -n "${LUMEN_PRIVATE_KEY:-}" ]]; then
  die "raw LUMEN_PRIVATE_KEY refused on mainnet" 3 policy_violation
fi

MULTICALL3="$(jq -r ".networks[\"$NETWORK_KEY\"].contracts.multicall3" "$LUMEN_NETWORKS_FILE")"
assert_address "$MULTICALL3" "multicall3 address from networks.json"

mapfile -t SENDER_FLAGS < <(sender_cast_flags)
SENDER_ADDR="$(cast wallet address "${SENDER_FLAGS[@]}" 2>/dev/null || true)"
[[ -n "$SENDER_ADDR" ]] || die "could not derive sender address" 3 sender_resolution_failed
SENDER_ADDR="$(to_lower_address "$SENDER_ADDR")"

# -----------------------------------------------------------------------------
# Preflight: balance check.
# -----------------------------------------------------------------------------
DECIMALS="$(erc20_decimals "$RPC_URL" "$TOKEN")"
SYMBOL="$(erc20_symbol "$RPC_URL" "$TOKEN" 2>/dev/null || printf 'TOKEN')"
BALANCE="$(erc20_balance_of "$RPC_URL" "$TOKEN" "$SENDER_ADDR")"

if bignum_lt "$BALANCE" "$TOTAL"; then
  emit_error "$CAPABILITY" "insufficient_balance" \
    "sender balance $BALANCE < total $TOTAL for $SYMBOL" \
    "$(jq -n --arg b "$BALANCE" --arg t "$TOTAL" --arg s "$SYMBOL" \
       '{balance:$b, total:$t, symbol:$s}')"
  exit 4
fi

# -----------------------------------------------------------------------------
# Execute splits
# -----------------------------------------------------------------------------
log_info "pay.split mode=$MODE total=$TOTAL recipients=$RECIPIENT_COUNT token=$SYMBOL"

declare -a TX_HASHES=()
declare -a TX_BLOCKS=()
declare -a TX_GAS=()

if [[ "$MODE" == "sequential" ]]; then
  # N independent transfer() calls. Each gets its own tx hash.
  for ((i = 0; i < RECIPIENT_COUNT; i++)); do
    log_info "split[$i] → ${RECIPIENTS[i]} amount=${AMOUNTS[i]}"
    out="$(cast send \
      --rpc-url "$RPC_URL" --json \
      "${SENDER_FLAGS[@]}" \
      "$TOKEN" "transfer(address,uint256)" "${RECIPIENTS[i]}" "${AMOUNTS[i]}" 2>&1)" || {
        log_error "split[$i] failed: $out"
        emit_error "$CAPABILITY" "tx_send_failed" \
          "transfer to ${RECIPIENTS[i]} failed at index $i" \
          "$(jq -Rn --arg o "$out" --argjson idx "$i" '{index:$idx, cast_output:$o}')"
        exit 6
      }
    TX_HASHES+=("$(jq -r .transactionHash <<<"$out")")
    TX_BLOCKS+=("$(jq -r .blockNumber  <<<"$out")")
    TX_GAS+=("$(jq -r .gasUsed         <<<"$out")")
  done
else
  # Atomic multicall3 path. Build Call3[] array of transferFrom(sender, r_i, amt_i).
  # Multicall3 must have allowance from sender on $TOKEN ≥ $TOTAL.
  ALLOWANCE="$(cast call --rpc-url "$RPC_URL" "$TOKEN" \
    "allowance(address,address)(uint256)" "$SENDER_ADDR" "$MULTICALL3" \
    | awk '{print $1}')"
  if bignum_lt "$ALLOWANCE" "$TOTAL"; then
    emit_error "$CAPABILITY" "insufficient_allowance" \
      "Multicall3 allowance $ALLOWANCE < total $TOTAL; run approval.scope first" \
      "$(jq -n --arg a "$ALLOWANCE" --arg t "$TOTAL" --arg m "$MULTICALL3" \
         '{allowance:$a, total:$t, spender:$m}')"
    exit 7
  fi

  # Build aggregate3((address,bool,bytes)[]) calldata using cast abi-encode.
  CALLS_JSON="["
  for ((i = 0; i < RECIPIENT_COUNT; i++)); do
    inner_calldata="$(cast calldata "transferFrom(address,address,uint256)" \
      "$SENDER_ADDR" "${RECIPIENTS[i]}" "${AMOUNTS[i]}")"
    [[ $i -gt 0 ]] && CALLS_JSON+=","
    CALLS_JSON+="($TOKEN,false,$inner_calldata)"
  done
  CALLS_JSON+="]"

  out="$(cast send \
    --rpc-url "$RPC_URL" --json \
    "${SENDER_FLAGS[@]}" \
    "$MULTICALL3" \
    "aggregate3((address,bool,bytes)[])" \
    "$CALLS_JSON" 2>&1)" || {
      log_error "multicall3 aggregate3 failed: $out"
      emit_error "$CAPABILITY" "tx_send_failed" \
        "Multicall3.aggregate3 broadcast failed" \
        "$(jq -Rn --arg o "$out" '{cast_output:$o}')"
      exit 6
    }
  TX_HASHES+=("$(jq -r .transactionHash <<<"$out")")
  TX_BLOCKS+=("$(jq -r .blockNumber  <<<"$out")")
  TX_GAS+=("$(jq -r .gasUsed         <<<"$out")")
fi

# -----------------------------------------------------------------------------
# Build receipt
# -----------------------------------------------------------------------------
IDEM_OUT="$IDEMPOTENCY_KEY"
[[ -z "$IDEM_OUT" ]] && IDEM_OUT="$(new_idempotency_key "pay-split")"

# Compose per-recipient allocation array.
ALLOC_JSON="$(jq -nc \
  --argjson recipients "$(printf '%s\n' "${RECIPIENTS[@]}" | jq -R . | jq -s .)" \
  --argjson amounts    "$(printf '%s\n' "${AMOUNTS[@]}"    | jq -R . | jq -s .)" \
  '[range(0; $recipients|length)] as $idx | $idx | map({recipient: $recipients[.], amount: $amounts[.]})')"

TX_LIST_JSON="$(jq -nc \
  --argjson hashes "$(printf '%s\n' "${TX_HASHES[@]}" | jq -R . | jq -s .)" \
  --argjson blocks "$(printf '%s\n' "${TX_BLOCKS[@]}" | jq -R . | jq -s .)" \
  --argjson gases  "$(printf '%s\n' "${TX_GAS[@]}"    | jq -R . | jq -s .)" \
  --arg explorer "$EXPLORER" \
  '[range(0; $hashes|length)] | map({
     hash: $hashes[.],
     block_number: $blocks[.],
     gas_used: $gases[.],
     explorer_url: ($explorer + "/tx/" + $hashes[.])
   })')"

RECEIPT="$(jq -n \
  --arg cap "$CAPABILITY" \
  --arg mode "$MODE" \
  --arg network "$NETWORK_KEY" \
  --argjson chain_id "$CHAIN_ID" \
  --arg sender "$SENDER_ADDR" \
  --arg token "$TOKEN" \
  --arg symbol "$SYMBOL" \
  --argjson decimals "${DECIMALS:-0}" \
  --arg total "$TOTAL" \
  --argjson allocations "$ALLOC_JSON" \
  --argjson txs "$TX_LIST_JSON" \
  --arg memo "$MEMO" \
  --arg idem "$IDEM_OUT" \
  '{
    capability: $cap,
    mode: $mode,
    network: $network,
    chain_id: $chain_id,
    sender: $sender,
    token: {address: $token, symbol: $symbol, decimals: $decimals},
    total: $total,
    allocations: $allocations,
    txs: $txs,
    memo: (if $memo == "" then null else $memo end),
    idempotency_key: $idem
  }')"

printf '%s\n' "$RECEIPT" | ledger_append
log_ok "split complete: $RECIPIENT_COUNT recipients, $(jq -r '.txs|length' <<<"$RECEIPT") tx(s)"
emit_ok "$CAPABILITY" "$RECEIPT"

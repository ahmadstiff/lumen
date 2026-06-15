#!/usr/bin/env bash
# pay.recurring — stateless recurring payments via EIP-712 pre-signed
# authorizations + an existing ERC-20 allowance.
#
# Trust model:
#   - Subscriber signs a RecurringAuthorization (this script, action=create).
#   - Subscriber grants the merchant an ERC-20 allowance covering at least
#     `amountPerPeriod * maxPeriods` (use approval.scope).
#   - Merchant runs action=charge once per period. Each charge:
#       1. verifies the EIP-712 signature against the subscriber address
#       2. checks the Lumen ledger to count prior charges under this planId
#       3. enforces start/end window, period spacing, and maxPeriods cap
#       4. transfers `amountPerPeriod` via the merchant's existing allowance
#
# All limits live in the signed doc; the ledger merely enforces them.
#
# See references/pay.recurring.md.

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

CAPABILITY="pay.recurring"
trap_capability "$CAPABILITY"

require_cmd jq cast

REQUEST="$(json_require_object)"
NETWORK_OVERRIDE="$(json_get_or '.network' "$REQUEST" "")"
[[ -n "$NETWORK_OVERRIDE" ]] && export LUMEN_NETWORK="$NETWORK_OVERRIDE"

PARAMS="$(json_get '.params' "$REQUEST" || true)"
[[ -z "$PARAMS" ]] && die "request.params is required" 2 missing_params

ACTION="$(json_get_or '.action' "$PARAMS" "create")"
case "$ACTION" in
  create|verify|charge) ;;
  *) die "params.action must be 'create', 'verify', or 'charge'" 2 invalid_action ;;
esac

NETWORK_JSON="$(resolve_network)"
RPC_URL="$(jq -r .rpc_url <<<"$NETWORK_JSON")"
CHAIN_ID="$(jq -r .chain_id <<<"$NETWORK_JSON")"
NETWORK_KEY="$(jq -r .key <<<"$NETWORK_JSON")"
EXPLORER="$(jq -r .explorer_url <<<"$NETWORK_JSON")"

# -----------------------------------------------------------------------------
# Typed-data builder. Mirrors LumenLib.RecurringAuthorization struct.
# -----------------------------------------------------------------------------
build_typed_data() {
  local auth="$1"
  jq -n --argjson a "$auth" --argjson chain "$CHAIN_ID" '
  {
    domain: {name: "Lumen", version: "1", chainId: $chain},
    primaryType: "RecurringAuthorization",
    types: {
      EIP712Domain: [
        {name: "name",    type: "string"},
        {name: "version", type: "string"},
        {name: "chainId", type: "uint256"}
      ],
      RecurringAuthorization: [
        {name: "planId",          type: "bytes32"},
        {name: "subscriber",      type: "address"},
        {name: "merchant",        type: "address"},
        {name: "token",           type: "address"},
        {name: "amountPerPeriod", type: "uint256"},
        {name: "periodSeconds",   type: "uint256"},
        {name: "startAt",         type: "uint256"},
        {name: "endAt",           type: "uint256"},
        {name: "maxPeriods",      type: "uint256"}
      ]
    },
    message: $a
  }'
}

# -----------------------------------------------------------------------------
# action_create: subscriber signs the authorization
# -----------------------------------------------------------------------------
action_create() {
  local merchant token amount_per period start end max_periods plan_id
  merchant="$(json_get '.merchant' "$PARAMS" || true)"
  token="$(json_get '.token' "$PARAMS" || true)"
  amount_per="$(json_get '.amount_per_period' "$PARAMS" || true)"
  period="$(json_get '.period_seconds' "$PARAMS" || true)"
  start="$(json_get_or '.start_at_unix' "$PARAMS" "$(date -u +%s)")"
  end="$(json_get '.end_at_unix' "$PARAMS" || true)"
  max_periods="$(json_get_or '.max_periods' "$PARAMS" "0")"
  plan_id="$(json_get_or '.plan_id' "$PARAMS" "")"

  local val
  for v in merchant token amount_per period end; do
    val="${!v}"
    [[ -z "$val" ]] && die "params.$v required" 2 missing_param
  done

  assert_address "$merchant" "params.merchant"
  assert_address "$token" "params.token"
  assert_uint "$amount_per" "params.amount_per_period"
  assert_uint "$period" "params.period_seconds"
  assert_uint "$start" "params.start_at_unix"
  assert_uint "$end" "params.end_at_unix"
  assert_uint "$max_periods" "params.max_periods"

  (( period > 0 )) || die "period_seconds must be > 0" 2 invalid_period
  (( end > start )) || die "end_at_unix must be > start_at_unix" 2 invalid_window

  # Safety cap: end - start ≤ 1 year, max_periods ≤ 366 (≈ daily for a year).
  (( end - start <= 31536000 )) || die "authorization window > 365 days" 2 window_too_long
  (( max_periods <= 366 )) || die "max_periods > 366 (daily-for-a-year ceiling)" 2 max_periods_too_high

  # Auto-generate planId if absent.
  if [[ -z "$plan_id" ]]; then
    local rnd
    rnd="$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 32 || true)"
    plan_id="$(cast keccak "0x${rnd}")"
  fi
  [[ "$plan_id" =~ ^0x[0-9a-fA-F]{64}$ ]] \
    || die "params.plan_id must be 0x + 64 hex" 2 invalid_plan_id

  mapfile -t SENDER_FLAGS < <(sender_cast_flags)
  local subscriber
  subscriber="$(cast wallet address "${SENDER_FLAGS[@]}" 2>/dev/null || true)"
  [[ -n "$subscriber" ]] || die "could not derive subscriber address" 3 sender_resolution_failed
  subscriber="$(to_lower_address "$subscriber")"

  local auth typed digest sig
  auth="$(jq -n \
    --arg plan "$plan_id" --arg sub "$subscriber" --arg merchant "$merchant" \
    --arg token "$token" --arg amount "$amount_per" \
    --argjson period "$period" --argjson start "$start" --argjson end "$end" \
    --argjson max "$max_periods" \
    '{planId:$plan, subscriber:$sub, merchant:$merchant, token:$token,
      amountPerPeriod:$amount, periodSeconds:$period, startAt:$start,
      endAt:$end, maxPeriods:$max}')"

  typed="$(build_typed_data "$auth")"
  digest="$(printf '%s' "$typed" | cast hash-typed-data 2>&1)" || {
    emit_error "$CAPABILITY" "hash_failed" "cast hash-typed-data failed" \
      "$(jq -Rn --arg o "$digest" '{cast_output:$o}')"
    exit 7
  }
  sig="$(cast wallet sign --no-hash "$digest" "${SENDER_FLAGS[@]}" 2>&1)" || {
    emit_error "$CAPABILITY" "sign_failed" "signing failed" \
      "$(jq -Rn --arg o "$sig" '{cast_output:$o}')"
    exit 7
  }

  local document
  document="$(jq -n --argjson a "$auth" --argjson chain "$CHAIN_ID" --arg sig "$sig" \
    '$a + {chainId:$chain, signature:$sig}')"

  # Append to ledger as an "authorization" record so charges can be audited.
  printf '%s\n' "$(jq -c --arg cap "$CAPABILITY" --argjson doc "$document" \
    --arg idem "auth-$(jq -r '.planId' <<<"$document")" \
    '{capability:$cap, kind:"authorization", idempotency_key:$idem, document:$doc}')" \
    | ledger_append

  log_ok "recurring authorization signed: planId=$plan_id maxPeriods=$max_periods"
  emit_ok "$CAPABILITY" "$(jq -n --argjson doc "$document" \
    '{action:"create", document:$doc}')"
}

# -----------------------------------------------------------------------------
# action_verify: signature check only
# -----------------------------------------------------------------------------
action_verify() {
  local doc signature typed digest subscriber recovered
  doc="$(json_get '.document' "$PARAMS" || true)"
  [[ -z "$doc" ]] && die "params.document required" 2 missing_param

  signature="$(jq -r '.signature' <<<"$doc")"
  [[ -z "$signature" || "$signature" == "null" ]] \
    && die "document.signature missing" 2 missing_signature

  subscriber="$(jq -r '.subscriber' <<<"$doc")"
  assert_address "$subscriber" "document.subscriber"

  # Build typed-data from the doc minus the chainId/signature fields.
  local auth
  auth="$(jq 'del(.chainId, .signature)' <<<"$doc")"
  typed="$(build_typed_data "$auth")"
  digest="$(printf '%s' "$typed" | cast hash-typed-data 2>&1)" || {
    emit_error "$CAPABILITY" "hash_failed" "cast hash-typed-data failed" \
      "$(jq -Rn --arg o "$digest" '{cast_output:$o}')"
    exit 8
  }

  recovered="$(cast wallet recover "$digest" "$signature" 2>/dev/null || true)"
  if [[ "$(to_lower_address "$recovered")" != "$(to_lower_address "$subscriber")" ]]; then
    emit_error "$CAPABILITY" "signature_mismatch" \
      "recovered signer $recovered does not match document.subscriber $subscriber"
    exit 8
  fi

  log_ok "recurring authorization verified for subscriber=$subscriber"
  emit_ok "$CAPABILITY" "$(jq -n --argjson doc "$doc" \
    '{action:"verify", verified:true,
      subscriber:$doc.subscriber, plan_id:$doc.planId}')"
}

# -----------------------------------------------------------------------------
# action_charge: enforce period quotas + execute transferFrom
# -----------------------------------------------------------------------------
action_charge() {
  local doc plan_id
  doc="$(json_get '.document' "$PARAMS" || true)"
  [[ -z "$doc" ]] && die "params.document required" 2 missing_param

  # Verify signature via action_verify inline.
  local saved="$PARAMS"
  PARAMS="$(jq -n --argjson d "$doc" '{document:$d}')"
  action_verify >/dev/null
  PARAMS="$saved"

  plan_id="$(jq -r '.planId' <<<"$doc")"
  local subscriber merchant token amount_per period start end max_periods
  subscriber="$(jq -r '.subscriber' <<<"$doc")"
  merchant="$(jq -r '.merchant' <<<"$doc")"
  token="$(jq -r '.token' <<<"$doc")"
  amount_per="$(jq -r '.amountPerPeriod' <<<"$doc")"
  period="$(jq -r '.periodSeconds' <<<"$doc")"
  start="$(jq -r '.startAt' <<<"$doc")"
  end="$(jq -r '.endAt' <<<"$doc")"
  max_periods="$(jq -r '.maxPeriods' <<<"$doc")"

  local now
  now="$(date -u +%s)"
  (( now >= start )) || die "plan starts at $start, now=$now" 4 plan_not_started
  (( now <= end ))   || die "plan ended at $end, now=$now"    4 plan_ended

  # Count prior charges under this planId from the ledger.
  local charges_count
  charges_count="$(jq -c --arg p "$plan_id" \
    'select(.capability == "pay.recurring" and .kind == "charge" and .plan_id == $p)' \
    "$LUMEN_LEDGER" 2>/dev/null | wc -l | tr -d ' ')"
  charges_count="${charges_count:-0}"

  if (( max_periods > 0 && charges_count >= max_periods )); then
    emit_error "$CAPABILITY" "max_periods_exhausted" \
      "$charges_count charges already executed; max_periods=$max_periods" \
      "$(jq -n --arg p "$plan_id" --argjson c "$charges_count" --argjson m "$max_periods" \
         '{plan_id:$p, charges:$c, max:$m}')"
    exit 5
  fi

  # Enforce period spacing: previous charge timestamp + period_seconds ≤ now.
  local last_charge_ts
  last_charge_ts="$(jq -c --arg p "$plan_id" \
    'select(.capability == "pay.recurring" and .kind == "charge" and .plan_id == $p) | .charged_at_unix' \
    "$LUMEN_LEDGER" 2>/dev/null | tail -n 1 | tr -d '"')"

  if [[ -n "$last_charge_ts" && "$last_charge_ts" != "null" ]]; then
    local next_allowed=$((last_charge_ts + period))
    if (( now < next_allowed )); then
      emit_error "$CAPABILITY" "period_not_due" \
        "next charge allowed at $next_allowed (now=$now)" \
        "$(jq -n --argjson last "$last_charge_ts" --argjson next "$next_allowed" \
           --argjson now "$now" '{last:$last, next_allowed:$next, now:$now}')"
      exit 5
    fi
  fi

  # Caller must be the merchant (we use the merchant's allowance to pull from subscriber).
  mapfile -t SENDER_FLAGS < <(sender_cast_flags)
  local me
  me="$(cast wallet address "${SENDER_FLAGS[@]}" 2>/dev/null || true)"
  me="$(to_lower_address "$me")"
  [[ "$me" == "$(to_lower_address "$merchant")" ]] \
    || die "configured wallet $me is not the plan merchant $merchant" 9 wrong_merchant

  log_info "charging plan $plan_id period=$((charges_count + 1))/$max_periods amount=$amount_per"

  # Execute transferFrom(subscriber, merchant, amount_per) using merchant's allowance.
  local tx_out
  tx_out="$(cast send --rpc-url "$RPC_URL" --json "${SENDER_FLAGS[@]}" \
    "$token" "transferFrom(address,address,uint256)" "$subscriber" "$merchant" "$amount_per" 2>&1)" || {
      emit_error "$CAPABILITY" "tx_send_failed" "transferFrom broadcast failed" \
        "$(jq -Rn --arg o "$tx_out" '{cast_output:$o}')"
      exit 6
    }

  local tx_hash tx_block tx_gas tx_status status_ok
  tx_hash="$(jq -r .transactionHash <<<"$tx_out")"
  tx_block="$(jq -r .blockNumber <<<"$tx_out")"
  tx_gas="$(jq -r .gasUsed <<<"$tx_out")"
  tx_status="$(jq -r .status <<<"$tx_out")"
  status_ok="false"
  [[ "$tx_status" == "0x1" || "$tx_status" == "1" ]] && status_ok="true"

  local receipt
  receipt="$(jq -n \
    --arg cap "$CAPABILITY" \
    --arg network "$NETWORK_KEY" \
    --argjson chain_id "$CHAIN_ID" \
    --arg plan "$plan_id" \
    --arg subscriber "$subscriber" --arg merchant "$merchant" \
    --arg token "$token" --arg amount "$amount_per" \
    --argjson period_num "$((charges_count + 1))" \
    --argjson max_periods "$max_periods" \
    --argjson charged_at "$now" \
    --arg tx_hash "$tx_hash" --arg tx_block "$tx_block" --arg tx_gas "$tx_gas" \
    --argjson tx_ok "$status_ok" --arg explorer "$EXPLORER" \
    --arg idem "charge-$plan_id-$((charges_count + 1))" \
    '{
      capability: $cap,
      kind: "charge",
      network: $network,
      chain_id: $chain_id,
      plan_id: $plan,
      subscriber: $subscriber,
      merchant: $merchant,
      token: $token,
      amount: $amount,
      period_number: $period_num,
      max_periods: $max_periods,
      charged_at_unix: $charged_at,
      tx: {
        hash: $tx_hash, block_number: $tx_block, gas_used: $tx_gas, ok: $tx_ok,
        explorer_url: ($explorer + "/tx/" + $tx_hash)
      },
      idempotency_key: $idem
    }')"
  printf '%s\n' "$receipt" | ledger_append
  log_ok "charge complete: plan=$plan_id period=$((charges_count + 1))"
  emit_ok "$CAPABILITY" "$(jq -n --argjson doc "$doc" --argjson r "$receipt" \
    '{action:"charge", authorization:$doc, charge:$r}')"
}

case "$ACTION" in
  create) action_create ;;
  verify) action_verify ;;
  charge) action_charge ;;
esac

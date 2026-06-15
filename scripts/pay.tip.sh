#!/usr/bin/env bash
# pay.tip — agent-to-agent micropayments with optional anonymous claim.
#
# Two modes:
#   - direct (default) : behaves like pay.once but tags the receipt with
#     sender_agent_id / recipient_agent_id metadata so downstream skills can
#     index tips by agent identity. Single transferFrom (or transfer if the
#     payer is the sender).
#   - ticket            : payer signs an EIP-712 TipClaim ticket but does NOT
#     broadcast a transaction. The ticket is returned and can be redeemed by
#     the holder via `action=redeem` (which then executes the underlying
#     transferFrom against an existing allowance). Useful for one-off public
#     bounty payouts where the recipient is unknown at sign time.
#
# Actions: send | issue | redeem | verify
#
# See references/pay.tip.md.

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

CAPABILITY="pay.tip"
trap_capability "$CAPABILITY"

require_cmd jq cast

REQUEST="$(json_require_object)"
NETWORK_OVERRIDE="$(json_get_or '.network' "$REQUEST" "")"
[[ -n "$NETWORK_OVERRIDE" ]] && export LUMEN_NETWORK="$NETWORK_OVERRIDE"

IDEMPOTENCY_KEY="$(json_get_or '.idempotency_key' "$REQUEST" "")"
PARAMS="$(json_get '.params' "$REQUEST" || true)"
[[ -z "$PARAMS" ]] && die "request.params is required" 2 missing_params

ACTION="$(json_get_or '.action' "$PARAMS" "send")"
case "$ACTION" in
  send|issue|redeem|verify) ;;
  *) die "params.action must be 'send', 'issue', 'redeem', or 'verify'" 2 invalid_action ;;
esac

NETWORK_JSON="$(resolve_network)"
RPC_URL="$(jq -r .rpc_url <<<"$NETWORK_JSON")"
CHAIN_ID="$(jq -r .chain_id <<<"$NETWORK_JSON")"
NETWORK_KEY="$(jq -r .key <<<"$NETWORK_JSON")"
EXPLORER="$(jq -r .explorer_url <<<"$NETWORK_JSON")"

# -----------------------------------------------------------------------------
# Tip cap (skill-scanner-friendly): refuse single tips > 1e22 base units
# (≈ 10,000 tokens at 18 decimals or 10 trillion at 6 decimals). Above that,
# a tip is suspicious; use pay.once or pay.split instead.
# -----------------------------------------------------------------------------
TIP_MAX="10000000000000000000000"

assert_tip_amount() {
  local amount="$1"
  assert_uint "$amount" "params.amount"
  if ! bignum_lt "$amount" "$TIP_MAX"; then
    die "tip amount $amount exceeds policy cap $TIP_MAX (use pay.once for larger transfers)" \
      3 tip_amount_too_large
  fi
}

build_typed_data() {
  local ticket="$1"
  jq -n --argjson t "$ticket" --argjson chain "$CHAIN_ID" '
  {
    domain: {name: "Lumen", version: "1", chainId: $chain},
    primaryType: "TipClaim",
    types: {
      EIP712Domain: [
        {name: "name",    type: "string"},
        {name: "version", type: "string"},
        {name: "chainId", type: "uint256"}
      ],
      TipClaim: [
        {name: "ticketId",  type: "bytes32"},
        {name: "sender",    type: "address"},
        {name: "recipient", type: "address"},
        {name: "token",     type: "address"},
        {name: "amount",    type: "uint256"},
        {name: "expiry",    type: "uint256"},
        {name: "memo",      type: "string"}
      ]
    },
    message: $t
  }'
}

# -----------------------------------------------------------------------------
# action_send — direct tip (delegates to pay.once under the hood + metadata)
# -----------------------------------------------------------------------------
action_send() {
  local recipient token amount memo sender_agent recipient_agent
  recipient="$(json_get '.recipient' "$PARAMS" || true)"
  token="$(json_get '.token' "$PARAMS" || true)"
  amount="$(json_get '.amount' "$PARAMS" || true)"
  memo="$(json_get_or '.memo' "$PARAMS" "")"
  sender_agent="$(json_get_or '.sender_agent_id' "$PARAMS" "")"
  recipient_agent="$(json_get_or '.recipient_agent_id' "$PARAMS" "")"

  [[ -z "$recipient" ]] && die "params.recipient required" 2 missing_param
  [[ -z "$token" ]]     && die "params.token required"     2 missing_param
  [[ -z "$amount" ]]    && die "params.amount required"    2 missing_param

  assert_address "$recipient" "params.recipient"
  assert_address "$token" "params.token"
  assert_tip_amount "$amount"

  local idem
  idem="$IDEMPOTENCY_KEY"
  [[ -z "$idem" ]] && idem="$(new_idempotency_key "tip-send")"

  # Compose sub-request for pay.once.
  local subreq
  subreq="$(jq -n \
    --arg network "$NETWORK_KEY" --arg idem "$idem" \
    --arg token "$token" --arg recipient "$recipient" --arg amount "$amount" \
    --arg memo "$memo" \
    --arg sender_agent "$sender_agent" --arg recipient_agent "$recipient_agent" \
    '{
      network: $network,
      idempotency_key: $idem,
      params: {
        token: $token, recipient: $recipient, amount: $amount,
        memo: (if $memo == "" then ("tip from " + $sender_agent + " to " + $recipient_agent) else $memo end)
      }
    }')"

  log_info "tip → $recipient amount=$amount (agent=$sender_agent → $recipient_agent)"
  local pay_out
  pay_out="$(printf '%s' "$subreq" | "$(dirname "$0")/pay.once.sh")" || {
    emit_error "$CAPABILITY" "payment_failed" \
      "underlying pay.once returned non-zero" \
      "$(jq -Rn --arg o "$pay_out" '{pay_once_output:$o}')"
    exit 6
  }

  # Wrap pay.once result with tip metadata.
  emit_ok "$CAPABILITY" "$(jq -n --argjson p "$pay_out" \
    --arg sender_agent "$sender_agent" --arg recipient_agent "$recipient_agent" \
    '{
      action: "send",
      sender_agent_id: (if $sender_agent == "" then null else $sender_agent end),
      recipient_agent_id: (if $recipient_agent == "" then null else $recipient_agent end),
      payment: $p.result
    }')"
}

# -----------------------------------------------------------------------------
# action_issue — sign a TipClaim ticket (no transaction)
# -----------------------------------------------------------------------------
action_issue() {
  local recipient token amount expiry memo ticket_id
  recipient="$(json_get '.recipient' "$PARAMS" || true)"
  token="$(json_get '.token' "$PARAMS" || true)"
  amount="$(json_get '.amount' "$PARAMS" || true)"
  expiry="$(json_get_or '.expiry_unix' "$PARAMS" "$(( $(date -u +%s) + 604800 ))")"
  memo="$(json_get_or '.memo' "$PARAMS" "")"
  ticket_id="$(json_get_or '.ticket_id' "$PARAMS" "")"

  [[ -z "$recipient" ]] && die "params.recipient required (anonymous tickets must encode the eventual recipient)" 2 missing_param
  [[ -z "$token" ]]     && die "params.token required"     2 missing_param
  [[ -z "$amount" ]]    && die "params.amount required"    2 missing_param

  assert_address "$recipient" "params.recipient"
  assert_address "$token" "params.token"
  assert_tip_amount "$amount"
  assert_uint "$expiry" "params.expiry_unix"

  local now
  now="$(date -u +%s)"
  (( expiry > now )) || die "expiry_unix must be in the future" 2 expiry_in_past

  if [[ -z "$ticket_id" ]]; then
    local rnd
    rnd="$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 32 || true)"
    ticket_id="$(cast keccak "0x${rnd}")"
  fi
  [[ "$ticket_id" =~ ^0x[0-9a-fA-F]{64}$ ]] \
    || die "ticket_id must be 0x + 64 hex" 2 invalid_ticket_id

  mapfile -t SENDER_FLAGS < <(sender_cast_flags)
  local sender
  sender="$(cast wallet address "${SENDER_FLAGS[@]}" 2>/dev/null || true)"
  [[ -n "$sender" ]] || die "could not derive sender address" 3 sender_resolution_failed
  sender="$(to_lower_address "$sender")"

  local ticket typed digest sig
  ticket="$(jq -n \
    --arg id "$ticket_id" --arg sender "$sender" --arg recipient "$recipient" \
    --arg token "$token" --arg amount "$amount" \
    --argjson expiry "$expiry" --arg memo "$memo" \
    '{ticketId:$id, sender:$sender, recipient:$recipient, token:$token,
      amount:$amount, expiry:$expiry, memo:$memo}')"

  typed="$(build_typed_data "$ticket")"
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
  document="$(jq -n --argjson t "$ticket" --argjson chain "$CHAIN_ID" --arg sig "$sig" \
    '$t + {chainId:$chain, signature:$sig}')"

  printf '%s\n' "$(jq -c --argjson doc "$document" \
    --arg idem "tip-ticket-$ticket_id" \
    '{capability:"pay.tip", kind:"ticket", idempotency_key:$idem, document:$doc}')" \
    | ledger_append

  log_ok "tip ticket issued: id=$ticket_id amount=$amount recipient=$recipient"
  emit_ok "$CAPABILITY" "$(jq -n --argjson doc "$document" \
    '{action:"issue", document:$doc}')"
}

action_verify() {
  local doc signature typed digest sender recovered
  doc="$(json_get '.document' "$PARAMS" || true)"
  [[ -z "$doc" ]] && die "params.document required" 2 missing_param

  signature="$(jq -r '.signature' <<<"$doc")"
  [[ -z "$signature" || "$signature" == "null" ]] \
    && die "document.signature missing" 2 missing_signature
  sender="$(jq -r '.sender' <<<"$doc")"
  assert_address "$sender" "document.sender"

  local ticket
  ticket="$(jq 'del(.chainId, .signature)' <<<"$doc")"
  typed="$(build_typed_data "$ticket")"
  digest="$(printf '%s' "$typed" | cast hash-typed-data 2>&1)" || {
    emit_error "$CAPABILITY" "hash_failed" "cast hash-typed-data failed" \
      "$(jq -Rn --arg o "$digest" '{cast_output:$o}')"
    exit 8
  }
  recovered="$(cast wallet recover "$digest" "$signature" 2>/dev/null || true)"
  if [[ "$(to_lower_address "$recovered")" != "$(to_lower_address "$sender")" ]]; then
    emit_error "$CAPABILITY" "signature_mismatch" \
      "recovered signer $recovered does not match document.sender $sender"
    exit 8
  fi

  log_ok "tip ticket verified: id=$(jq -r '.ticketId' <<<"$doc") sender=$sender"
  emit_ok "$CAPABILITY" "$(jq -n --argjson doc "$doc" \
    '{action:"verify", verified:true, ticket_id:$doc.ticketId, sender:$doc.sender, recipient:$doc.recipient}')"
}

action_redeem() {
  local doc
  doc="$(json_get '.document' "$PARAMS" || true)"
  [[ -z "$doc" ]] && die "params.document required" 2 missing_param

  local saved="$PARAMS"
  PARAMS="$(jq -n --argjson d "$doc" '{document:$d}')"
  action_verify >/dev/null
  PARAMS="$saved"

  local now expiry
  now="$(date -u +%s)"
  expiry="$(jq -r '.expiry' <<<"$doc")"
  (( now <= expiry )) || die "ticket expired at $expiry" 4 ticket_expired

  mapfile -t SENDER_FLAGS < <(sender_cast_flags)
  local me recipient
  me="$(cast wallet address "${SENDER_FLAGS[@]}" 2>/dev/null || true)"
  me="$(to_lower_address "$me")"
  recipient="$(to_lower_address "$(jq -r '.recipient' <<<"$doc")")"
  [[ "$me" == "$recipient" ]] || die "configured wallet $me is not the ticket recipient $recipient" 9 wrong_recipient

  local sender token amount
  sender="$(jq -r '.sender' <<<"$doc")"
  token="$(jq -r '.token' <<<"$doc")"
  amount="$(jq -r '.amount' <<<"$doc")"

  # Verify allowance: sender must have approved recipient for ≥ amount.
  local allowance
  allowance="$(cast call --rpc-url "$RPC_URL" "$token" \
    "allowance(address,address)(uint256)" "$sender" "$me" | awk '{print $1}')"
  if bignum_lt "$allowance" "$amount"; then
    emit_error "$CAPABILITY" "insufficient_allowance" \
      "sender allowance $allowance < amount $amount; ask sender to call approval.scope" \
      "$(jq -n --arg a "$allowance" --arg n "$amount" '{allowance:$a, amount:$n}')"
    exit 7
  fi

  local tx_out
  tx_out="$(cast send --rpc-url "$RPC_URL" --json "${SENDER_FLAGS[@]}" \
    "$token" "transferFrom(address,address,uint256)" "$sender" "$me" "$amount" 2>&1)" || {
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

  local ticket_id receipt
  ticket_id="$(jq -r '.ticketId' <<<"$doc")"
  receipt="$(jq -n \
    --arg cap "$CAPABILITY" --arg ticket "$ticket_id" \
    --arg sender "$sender" --arg recipient "$me" \
    --arg token "$token" --arg amount "$amount" \
    --arg network "$NETWORK_KEY" --argjson chain_id "$CHAIN_ID" \
    --arg tx_hash "$tx_hash" --arg tx_block "$tx_block" --arg tx_gas "$tx_gas" \
    --argjson tx_ok "$status_ok" --arg explorer "$EXPLORER" \
    --arg idem "tip-redeem-$ticket_id" \
    '{
      capability: $cap, kind: "redemption",
      ticket_id: $ticket, sender: $sender, recipient: $recipient,
      token: $token, amount: $amount,
      network: $network, chain_id: $chain_id,
      tx: { hash:$tx_hash, block_number:$tx_block, gas_used:$tx_gas, ok:$tx_ok,
            explorer_url:($explorer + "/tx/" + $tx_hash) },
      idempotency_key: $idem
    }')"
  printf '%s\n' "$receipt" | ledger_append

  log_ok "tip ticket redeemed: id=$ticket_id"
  emit_ok "$CAPABILITY" "$(jq -n --argjson doc "$doc" --argjson r "$receipt" \
    '{action:"redeem", ticket:$doc, redemption:$r}')"
}

case "$ACTION" in
  send)   action_send   ;;
  issue)  action_issue  ;;
  redeem) action_redeem ;;
  verify) action_verify ;;
esac

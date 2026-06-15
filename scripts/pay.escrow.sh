#!/usr/bin/env bash
# pay.escrow — stateless agent-to-agent escrow via hash-locked EIP-712 offer.
#
# Trust model (no custom contract; no third-party custodian):
#   1. Payer generates a random `releaseKey` (32 bytes) locally and computes
#      `releaseKeyHash = keccak256(abi.encode(releaseKey))`.
#   2. Payer signs an EscrowOffer EIP-712 document carrying the hash + expiry
#      and shares it with the payee. The releaseKey stays secret.
#   3. Payer grants a *bounded* allowance to the payee (use approval.scope).
#   4. Payee delivers the agreed service or artefact off-chain. Payer reveals
#      `releaseKey` to the payee out-of-band.
#   5. Payee calls action=claim with (offer, releaseKey) — the script:
#        a) verifies the offer signature recovers to `payer`
#        b) verifies keccak256(releaseKey) == releaseKeyHash
#        c) verifies the payer's allowance to the payee ≥ amount
#        d) executes `transferFrom(payer, payee, amount)` and writes a receipt.
#   6. If the payee never claims and `expiry` passes, payer runs
#      action=refund — the script just records the refund in the ledger and
#      tells the payer to revoke the allowance (back to 0) via approval.scope.
#
# This achieves "escrow" with two existing primitives (allowance + signature)
# and the standard Lumen audit ledger — no contract upgrade surface to worry
# about.
#
# See references/pay.escrow.md.

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

CAPABILITY="pay.escrow"
trap_capability "$CAPABILITY"

require_cmd jq cast

REQUEST="$(json_require_object)"
NETWORK_OVERRIDE="$(json_get_or '.network' "$REQUEST" "")"
[[ -n "$NETWORK_OVERRIDE" ]] && export LUMEN_NETWORK="$NETWORK_OVERRIDE"

PARAMS="$(json_get '.params' "$REQUEST" || true)"
[[ -z "$PARAMS" ]] && die "request.params is required" 2 missing_params

ACTION="$(json_get_or '.action' "$PARAMS" "create")"
case "$ACTION" in
  create|verify|claim|refund) ;;
  *) die "params.action must be 'create', 'verify', 'claim', or 'refund'" 2 invalid_action ;;
esac

NETWORK_JSON="$(resolve_network)"
RPC_URL="$(jq -r .rpc_url <<<"$NETWORK_JSON")"
CHAIN_ID="$(jq -r .chain_id <<<"$NETWORK_JSON")"
NETWORK_KEY="$(jq -r .key <<<"$NETWORK_JSON")"
EXPLORER="$(jq -r .explorer_url <<<"$NETWORK_JSON")"

# -----------------------------------------------------------------------------
# Typed-data builder mirroring LumenLib.escrowOfferDigest.
# -----------------------------------------------------------------------------
build_typed_data() {
  local offer="$1"
  jq -n --argjson o "$offer" --argjson chain "$CHAIN_ID" '
  {
    domain: {name: "Lumen", version: "1", chainId: $chain},
    primaryType: "EscrowOffer",
    types: {
      EIP712Domain: [
        {name: "name",    type: "string"},
        {name: "version", type: "string"},
        {name: "chainId", type: "uint256"}
      ],
      EscrowOffer: [
        {name: "escrowId",       type: "bytes32"},
        {name: "payer",          type: "address"},
        {name: "payee",          type: "address"},
        {name: "token",          type: "address"},
        {name: "amount",         type: "uint256"},
        {name: "releaseKeyHash", type: "bytes32"},
        {name: "expiry",         type: "uint256"},
        {name: "memo",           type: "string"}
      ]
    },
    message: $o
  }'
}

# -----------------------------------------------------------------------------
# action_create — payer signs an EscrowOffer
# -----------------------------------------------------------------------------
action_create() {
  local payee token amount expiry memo escrow_id
  payee="$(json_get '.payee' "$PARAMS" || true)"
  token="$(json_get '.token' "$PARAMS" || true)"
  amount="$(json_get '.amount' "$PARAMS" || true)"
  expiry="$(json_get '.expiry_unix' "$PARAMS" || true)"
  memo="$(json_get_or '.memo' "$PARAMS" "")"
  escrow_id="$(json_get_or '.escrow_id' "$PARAMS" "")"

  [[ -z "$payee" ]]  && die "params.payee required"  2 missing_param
  [[ -z "$token" ]]  && die "params.token required"  2 missing_param
  [[ -z "$amount" ]] && die "params.amount required" 2 missing_param
  [[ -z "$expiry" ]] && die "params.expiry_unix required" 2 missing_param

  assert_address "$payee" "params.payee"
  assert_address "$token" "params.token"
  assert_uint "$amount" "params.amount"
  assert_uint "$expiry" "params.expiry_unix"

  local now
  now="$(date -u +%s)"
  (( expiry > now )) || die "expiry_unix must be in the future" 2 expiry_in_past
  (( expiry - now <= 31536000 )) || die "escrow window > 365 days" 2 window_too_long

  # Generate releaseKey + hash if not supplied (recommended path).
  local release_key release_key_hash
  release_key="$(json_get_or '.release_key' "$PARAMS" "")"
  if [[ -z "$release_key" ]]; then
    release_key="0x$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 64 || true)"
  fi
  [[ "$release_key" =~ ^0x[0-9a-fA-F]{64}$ ]] \
    || die "release_key must be 0x + 64 hex" 2 invalid_release_key

  # releaseKeyHash = keccak256(abi.encode(bytes32 releaseKey))
  release_key_hash="$(cast keccak "$release_key")"

  # escrowId: deterministic from sender + hash if absent.
  if [[ -z "$escrow_id" ]]; then
    escrow_id="$(cast keccak "$(printf '%s%s' "$release_key_hash" "$amount")")"
  fi
  [[ "$escrow_id" =~ ^0x[0-9a-fA-F]{64}$ ]] \
    || die "escrow_id must be 0x + 64 hex" 2 invalid_escrow_id

  mapfile -t SENDER_FLAGS < <(sender_cast_flags)
  local payer
  payer="$(cast wallet address "${SENDER_FLAGS[@]}" 2>/dev/null || true)"
  [[ -n "$payer" ]] || die "could not derive payer address" 3 sender_resolution_failed
  payer="$(to_lower_address "$payer")"

  local offer typed digest sig
  offer="$(jq -n \
    --arg id "$escrow_id" --arg payer "$payer" --arg payee "$payee" \
    --arg token "$token" --arg amount "$amount" \
    --arg rkh "$release_key_hash" --argjson expiry "$expiry" --arg memo "$memo" \
    '{escrowId:$id, payer:$payer, payee:$payee, token:$token, amount:$amount,
      releaseKeyHash:$rkh, expiry:$expiry, memo:$memo}')"

  typed="$(build_typed_data "$offer")"
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
  document="$(jq -n --argjson o "$offer" --argjson chain "$CHAIN_ID" --arg sig "$sig" \
    '$o + {chainId:$chain, signature:$sig}')"

  # Ledger record. The releaseKey is NOT persisted to the ledger (sensitive).
  printf '%s\n' "$(jq -c --argjson doc "$document" \
    --arg idem "escrow-offer-$(jq -r '.escrowId' <<<"$document")" \
    '{capability:"pay.escrow", kind:"offer", idempotency_key:$idem, document:$doc}')" \
    | ledger_append

  log_ok "escrow offer signed: id=$escrow_id payee=$payee amount=$amount"
  emit_ok "$CAPABILITY" "$(jq -n --argjson doc "$document" --arg key "$release_key" \
    '{action:"create", document:$doc, release_key:$key,
      release_key_warning:"release_key is the bearer secret \u2014 share it OOB only after the payee delivers."}')"
}

# -----------------------------------------------------------------------------
# action_verify — signature + structure check only
# -----------------------------------------------------------------------------
action_verify() {
  local doc signature typed digest payer recovered
  doc="$(json_get '.document' "$PARAMS" || true)"
  [[ -z "$doc" ]] && die "params.document required" 2 missing_param

  signature="$(jq -r '.signature' <<<"$doc")"
  [[ -z "$signature" || "$signature" == "null" ]] \
    && die "document.signature missing" 2 missing_signature
  payer="$(jq -r '.payer' <<<"$doc")"
  assert_address "$payer" "document.payer"

  local offer
  offer="$(jq 'del(.chainId, .signature)' <<<"$doc")"
  typed="$(build_typed_data "$offer")"
  digest="$(printf '%s' "$typed" | cast hash-typed-data 2>&1)" || {
    emit_error "$CAPABILITY" "hash_failed" "cast hash-typed-data failed" \
      "$(jq -Rn --arg o "$digest" '{cast_output:$o}')"
    exit 8
  }
  recovered="$(cast wallet recover "$digest" "$signature" 2>/dev/null || true)"
  if [[ "$(to_lower_address "$recovered")" != "$(to_lower_address "$payer")" ]]; then
    emit_error "$CAPABILITY" "signature_mismatch" \
      "recovered signer $recovered does not match document.payer $payer"
    exit 8
  fi

  log_ok "escrow offer verified: id=$(jq -r '.escrowId' <<<"$doc") payer=$payer"
  emit_ok "$CAPABILITY" "$(jq -n --argjson doc "$doc" \
    '{action:"verify", verified:true, escrow_id:$doc.escrowId, payer:$doc.payer, payee:$doc.payee}')"
}

# -----------------------------------------------------------------------------
# action_claim — payee redeems with releaseKey + executes transferFrom
# -----------------------------------------------------------------------------
action_claim() {
  local doc release_key
  doc="$(json_get '.document' "$PARAMS" || true)"
  release_key="$(json_get '.release_key' "$PARAMS" || true)"
  [[ -z "$doc" ]] && die "params.document required" 2 missing_param
  [[ -z "$release_key" ]] && die "params.release_key required" 2 missing_param
  [[ "$release_key" =~ ^0x[0-9a-fA-F]{64}$ ]] \
    || die "release_key must be 0x + 64 hex" 2 invalid_release_key

  # Reuse action_verify in-process.
  local saved="$PARAMS"
  PARAMS="$(jq -n --argjson d "$doc" '{document:$d}')"
  action_verify >/dev/null
  PARAMS="$saved"

  # Check release-key matches releaseKeyHash.
  local provided_hash stored_hash
  provided_hash="$(cast keccak "$release_key")"
  stored_hash="$(jq -r '.releaseKeyHash' <<<"$doc")"
  if [[ "$(to_lower_address "$provided_hash")" != "$(to_lower_address "$stored_hash")" ]]; then
    emit_error "$CAPABILITY" "release_key_mismatch" \
      "release_key does not match the document's releaseKeyHash"
    exit 5
  fi

  # Window checks.
  local now expiry
  now="$(date -u +%s)"
  expiry="$(jq -r '.expiry' <<<"$doc")"
  (( now <= expiry )) || die "escrow expired at $expiry (now=$now); use action=refund" 4 escrow_expired

  # Payee identity guard: caller must be the document.payee.
  mapfile -t SENDER_FLAGS < <(sender_cast_flags)
  local me payee
  me="$(cast wallet address "${SENDER_FLAGS[@]}" 2>/dev/null || true)"
  me="$(to_lower_address "$me")"
  payee="$(to_lower_address "$(jq -r '.payee' <<<"$doc")")"
  [[ "$me" == "$payee" ]] || die "configured wallet $me is not the offer payee $payee" 9 wrong_payee

  # Allowance + balance preflight.
  local payer token amount
  payer="$(jq -r '.payer' <<<"$doc")"
  token="$(jq -r '.token' <<<"$doc")"
  amount="$(jq -r '.amount' <<<"$doc")"

  local allowance
  allowance="$(cast call --rpc-url "$RPC_URL" "$token" \
    "allowance(address,address)(uint256)" "$payer" "$me" | awk '{print $1}')"
  if bignum_lt "$allowance" "$amount"; then
    emit_error "$CAPABILITY" "insufficient_allowance" \
      "payer allowance $allowance < amount $amount; ask the payer to call approval.scope" \
      "$(jq -n --arg a "$allowance" --arg n "$amount" --arg p "$payer" \
         '{allowance:$a, amount:$n, payer:$p}')"
    exit 7
  fi

  log_info "claiming escrow id=$(jq -r '.escrowId' <<<"$doc") amount=$amount token=$token"

  local tx_out
  tx_out="$(cast send --rpc-url "$RPC_URL" --json "${SENDER_FLAGS[@]}" \
    "$token" "transferFrom(address,address,uint256)" "$payer" "$me" "$amount" 2>&1)" || {
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

  local escrow_id receipt
  escrow_id="$(jq -r '.escrowId' <<<"$doc")"
  receipt="$(jq -n \
    --arg cap "$CAPABILITY" \
    --arg id "$escrow_id" --arg payer "$payer" --arg payee "$me" \
    --arg token "$token" --arg amount "$amount" \
    --arg network "$NETWORK_KEY" --argjson chain_id "$CHAIN_ID" \
    --arg tx_hash "$tx_hash" --arg tx_block "$tx_block" --arg tx_gas "$tx_gas" \
    --argjson tx_ok "$status_ok" --arg explorer "$EXPLORER" \
    --arg idem "escrow-claim-$escrow_id" \
    '{
      capability: $cap, kind: "claim",
      escrow_id: $id, payer: $payer, payee: $payee, token: $token, amount: $amount,
      network: $network, chain_id: $chain_id,
      tx: { hash:$tx_hash, block_number:$tx_block, gas_used:$tx_gas, ok:$tx_ok,
            explorer_url:($explorer + "/tx/" + $tx_hash) },
      idempotency_key: $idem
    }')"
  printf '%s\n' "$receipt" | ledger_append

  log_ok "escrow claim complete: id=$escrow_id tx=$tx_hash"
  emit_ok "$CAPABILITY" "$(jq -n --argjson doc "$doc" --argjson r "$receipt" \
    '{action:"claim", offer:$doc, claim:$r}')"
}

# -----------------------------------------------------------------------------
# action_refund — payer reclaims after expiry by recording a refund + revoking
# -----------------------------------------------------------------------------
action_refund() {
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
  (( now > expiry )) || die "escrow not yet expired (expiry=$expiry, now=$now)" 4 not_yet_expired

  mapfile -t SENDER_FLAGS < <(sender_cast_flags)
  local me payer
  me="$(cast wallet address "${SENDER_FLAGS[@]}" 2>/dev/null || true)"
  me="$(to_lower_address "$me")"
  payer="$(to_lower_address "$(jq -r '.payer' <<<"$doc")")"
  [[ "$me" == "$payer" ]] || die "configured wallet $me is not the offer payer $payer" 9 wrong_payer

  local escrow_id receipt
  escrow_id="$(jq -r '.escrowId' <<<"$doc")"
  receipt="$(jq -n \
    --arg cap "$CAPABILITY" --arg id "$escrow_id" --argjson doc "$doc" \
    --argjson now "$now" --argjson chain "$CHAIN_ID" --arg network "$NETWORK_KEY" \
    --arg idem "escrow-refund-$escrow_id" \
    '{
      capability: $cap, kind: "refund",
      escrow_id: $id, payer: $doc.payer, payee: $doc.payee,
      token: $doc.token, amount: $doc.amount,
      network: $network, chain_id: $chain,
      refunded_at_unix: $now,
      followup_action: "call approval.scope with amount=0 to revoke the unused allowance",
      idempotency_key: $idem
    }')"
  printf '%s\n' "$receipt" | ledger_append

  log_ok "escrow refund recorded: id=$escrow_id"
  emit_ok "$CAPABILITY" "$(jq -n --argjson doc "$doc" --argjson r "$receipt" \
    '{action:"refund", offer:$doc, refund:$r}')"
}

case "$ACTION" in
  create) action_create ;;
  verify) action_verify ;;
  claim)  action_claim  ;;
  refund) action_refund ;;
esac

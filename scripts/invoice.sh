#!/usr/bin/env bash
# invoice — agent-to-agent invoicing via EIP-712 signed off-chain documents.
#
# Actions:
#   - issue   : build an Invoice struct, sign it with the configured wallet
#               and return the document + signature.
#   - verify  : given an invoice doc + signature, recover the signer and
#               compare to the embedded `issuer` field. Stateless, no RPC.
#   - pay     : verify, then execute an ERC-20 transfer for the invoice
#               amount via the pay.once flow.
#
# The invoice digest follows the LumenLib.invoiceDigest() type. The
# verifyingContract field is omitted from the domain (we use chainId only)
# so the same library implementation produces identical hashes off-chain
# and on-chain. See contracts/src/LumenLib.sol.
#
# See references/invoice.md.

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

CAPABILITY="invoice"
trap_capability "$CAPABILITY"

require_cmd jq cast

# -----------------------------------------------------------------------------
# Parse + dispatch
# -----------------------------------------------------------------------------
REQUEST="$(json_require_object)"

NETWORK_OVERRIDE="$(json_get_or '.network' "$REQUEST" "")"
[[ -n "$NETWORK_OVERRIDE" ]] && export LUMEN_NETWORK="$NETWORK_OVERRIDE"

PARAMS="$(json_get '.params' "$REQUEST" || true)"
[[ -z "$PARAMS" ]] && die "request.params is required" 2 missing_params

ACTION="$(json_get_or '.action' "$PARAMS" "issue")"
case "$ACTION" in
  issue|verify|pay) ;;
  *) die "params.action must be 'issue', 'verify', or 'pay'" 2 invalid_action ;;
esac

# -----------------------------------------------------------------------------
# Network context (chain id is part of the EIP-712 domain)
# -----------------------------------------------------------------------------
NETWORK_JSON="$(resolve_network)"
CHAIN_ID="$(jq -r .chain_id <<<"$NETWORK_JSON")"
NETWORK_KEY="$(jq -r .key <<<"$NETWORK_JSON")"

# -----------------------------------------------------------------------------
# EIP-712 typed-data builder. Mirrors LumenLib.Invoice struct.
# -----------------------------------------------------------------------------
build_typed_data() {
  # Args: invoice_json (object with all Invoice fields including chainId).
  local invoice="$1"
  jq -n --argjson inv "$invoice" --argjson chain "$CHAIN_ID" '
  {
    domain: {
      name: "Lumen",
      version: "1",
      chainId: $chain
    },
    primaryType: "Invoice",
    types: {
      EIP712Domain: [
        {name: "name",    type: "string"},
        {name: "version", type: "string"},
        {name: "chainId", type: "uint256"}
      ],
      Invoice: [
        {name: "invoiceId", type: "bytes32"},
        {name: "issuer",    type: "address"},
        {name: "payer",     type: "address"},
        {name: "token",     type: "address"},
        {name: "amount",    type: "uint256"},
        {name: "dueAt",     type: "uint256"},
        {name: "memo",      type: "string"}
      ]
    },
    message: {
      invoiceId: $inv.invoiceId,
      issuer:    $inv.issuer,
      payer:     $inv.payer,
      token:     $inv.token,
      amount:    $inv.amount,
      dueAt:     $inv.dueAt,
      memo:      $inv.memo
    }
  }'
}

# -----------------------------------------------------------------------------
# Actions
# -----------------------------------------------------------------------------
action_issue() {
  local payer token amount due_at memo invoice_id

  payer="$(json_get '.payer' "$PARAMS" || true)"
  token="$(json_get '.token' "$PARAMS" || true)"
  amount="$(json_get '.amount' "$PARAMS" || true)"
  due_at="$(json_get '.due_at_unix' "$PARAMS" || true)"
  memo="$(json_get_or '.memo' "$PARAMS" "")"
  invoice_id="$(json_get_or '.invoice_id' "$PARAMS" "")"

  [[ -z "$payer" ]]  && die "params.payer required"  2 missing_param
  [[ -z "$token" ]]  && die "params.token required"  2 missing_param
  [[ -z "$amount" ]] && die "params.amount required" 2 missing_param
  [[ -z "$due_at" ]] && die "params.due_at_unix required" 2 missing_param

  assert_address "$payer" "params.payer"
  assert_address "$token" "params.token"
  assert_uint "$amount" "params.amount"
  assert_uint "$due_at" "params.due_at_unix"

  # Auto-generate invoice id if absent: bytes32 of keccak256(issuer || payer || amount || dueAt || rand).
  if [[ -z "$invoice_id" ]]; then
    local rnd
    rnd="$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 32 || true)"
    invoice_id="$(cast keccak "0x${rnd}")"
  fi
  [[ "$invoice_id" =~ ^0x[0-9a-fA-F]{64}$ ]] \
    || die "params.invoice_id must be 0x + 64 hex" 2 invalid_invoice_id

  # Derive issuer from signer.
  mapfile -t SENDER_FLAGS < <(sender_cast_flags)
  local issuer
  issuer="$(cast wallet address "${SENDER_FLAGS[@]}" 2>/dev/null || true)"
  [[ -n "$issuer" ]] || die "could not derive issuer wallet address" 3 sender_resolution_failed
  issuer="$(to_lower_address "$issuer")"

  local invoice typed sig
  invoice="$(jq -n \
    --arg id "$invoice_id" --arg issuer "$issuer" --arg payer "$payer" \
    --arg token "$token" --arg amount "$amount" \
    --argjson due "$due_at" --arg memo "$memo" \
    '{invoiceId:$id, issuer:$issuer, payer:$payer, token:$token, amount:$amount, dueAt:$due, memo:$memo}')"

  typed="$(build_typed_data "$invoice")"
  # Compute the EIP-712 digest off-chain, then sign the raw digest with --no-hash.
  # This 2-step path is portable across cast 0.2+ while `cast wallet sign --data`
  # has changed signature between releases.
  local digest
  digest="$(printf '%s' "$typed" | cast hash-typed-data 2>&1)" || {
    emit_error "$CAPABILITY" "hash_failed" "cast hash-typed-data failed" \
      "$(jq -Rn --arg o "$digest" '{cast_output:$o}')"
    exit 7
  }
  sig="$(cast wallet sign --no-hash "$digest" "${SENDER_FLAGS[@]}" 2>&1)" || {
    log_error "signing digest failed: $sig"
    emit_error "$CAPABILITY" "sign_failed" "could not sign EIP-712 invoice" \
      "$(jq -Rn --arg o "$sig" '{cast_output:$o}')"
    exit 7
  }

  local document
  document="$(jq -n --argjson inv "$invoice" --argjson chain "$CHAIN_ID" --arg sig "$sig" '
    $inv + {chainId: $chain, signature: $sig}')"

  log_ok "invoice signed: id=$invoice_id issuer=$issuer"
  emit_ok "$CAPABILITY" "$(jq -n --arg action "issue" --argjson doc "$document" \
    '{action:$action, document:$doc}')"
}

action_verify() {
  local doc signature typed digest issuer recovered
  doc="$(json_get '.document' "$PARAMS" || true)"
  [[ -z "$doc" ]] && die "params.document required" 2 missing_param

  signature="$(jq -r '.signature' <<<"$doc")"
  [[ -z "$signature" || "$signature" == "null" ]] \
    && die "document.signature missing" 2 missing_signature

  issuer="$(jq -r '.issuer' <<<"$doc")"
  assert_address "$issuer" "document.issuer"

  typed="$(build_typed_data "$doc")"
  digest="$(printf '%s' "$typed" | cast hash-typed-data 2>&1)" || {
    emit_error "$CAPABILITY" "hash_failed" "cast hash-typed-data failed" \
      "$(jq -Rn --arg o "$digest" '{cast_output:$o}')"
    exit 8
  }

  recovered="$(cast wallet recover "$digest" "$signature" 2>/dev/null || true)"
  if [[ "$(to_lower_address "$recovered")" != "$(to_lower_address "$issuer")" ]]; then
    emit_error "$CAPABILITY" "signature_mismatch" \
      "recovered signer $recovered does not match document.issuer $issuer"
    exit 8
  fi

  log_ok "invoice signature verified for issuer=$issuer"
  emit_ok "$CAPABILITY" "$(jq -n \
    --arg action "verify" --argjson doc "$doc" \
    '{action:$action, verified:true, issuer: $doc.issuer, invoice_id: $doc.invoiceId}')"
}

action_pay() {
  local doc
  doc="$(json_get '.document' "$PARAMS" || true)"
  [[ -z "$doc" ]] && die "params.document required" 2 missing_param

  # Build a sub-request for verify and call action_verify inline by re-using
  # PARAMS via a temp variable. Cleaner: just call action_verify which exits
  # on failure.
  local saved_params="$PARAMS"
  PARAMS="$(jq -n --argjson d "$doc" '{document:$d}')"
  # action_verify exits non-zero on mismatch; capture stdout silently.
  action_verify >/dev/null
  PARAMS="$saved_params"

  # Check that the configured wallet IS the payer the invoice was issued to.
  mapfile -t SENDER_FLAGS < <(sender_cast_flags)
  local me
  me="$(cast wallet address "${SENDER_FLAGS[@]}" 2>/dev/null || true)"
  me="$(to_lower_address "$me")"
  local payer
  payer="$(to_lower_address "$(jq -r '.payer' <<<"$doc")")"
  if [[ "$me" != "$payer" ]]; then
    emit_error "$CAPABILITY" "wrong_payer" \
      "configured wallet $me is not the invoice payer $payer"
    exit 9
  fi

  # Check due date.
  local due now
  due="$(jq -r '.dueAt' <<<"$doc")"
  now="$(date -u +%s)"
  if (( now > due + 86400 )); then
    log_warn "invoice past due by $((now - due)) seconds — proceeding anyway"
  fi

  local token amount recipient memo
  token="$(jq -r '.token' <<<"$doc")"
  amount="$(jq -r '.amount' <<<"$doc")"
  recipient="$(jq -r '.issuer' <<<"$doc")"
  memo="$(jq -r '.memo' <<<"$doc")"

  # Compose the pay.once sub-request and execute it.
  local subreq
  subreq="$(jq -n \
    --arg network "$NETWORK_KEY" \
    --arg token "$token" --arg recipient "$recipient" --arg amount "$amount" \
    --arg memo "Invoice $(jq -r '.invoiceId' <<<"$doc"): $memo" \
    --arg idem "invoice-pay-$(jq -r '.invoiceId' <<<"$doc")" \
    '{network:$network, idempotency_key:$idem,
      params:{token:$token, recipient:$recipient, amount:$amount, memo:$memo}}')"

  local pay_out
  pay_out="$(printf '%s' "$subreq" | "$(dirname "$0")/pay.once.sh")" || {
    emit_error "$CAPABILITY" "payment_failed" \
      "underlying pay.once call returned non-zero" \
      "$(jq -Rn --arg o "$pay_out" '{pay_once_output:$o}')"
    exit 10
  }

  log_ok "invoice paid: id=$(jq -r '.invoiceId' <<<"$doc")"
  emit_ok "$CAPABILITY" "$(jq -n --argjson doc "$doc" --argjson pay "$pay_out" \
    '{action:"pay", invoice: $doc, payment: $pay.result}')"
}

case "$ACTION" in
  issue)  action_issue  ;;
  verify) action_verify ;;
  pay)    action_pay    ;;
esac

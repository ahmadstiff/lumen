#!/usr/bin/env bash
# receipt.generate — turn a transaction hash into a composable audit receipt.
#
# Decodes ERC-20 Transfer/Approval events from the tx receipt and emits three
# artefacts under .lumen/receipts/<tx>/:
#   - receipt.md   — human-readable Markdown
#   - receipt.json — full structured receipt
#   - receipt.csv  — one row per decoded log
#
# Appends the JSON envelope to the append-only ledger and returns it on stdout.
#
# See references/receipt.generate.md.

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

CAPABILITY="receipt.generate"
trap_capability "$CAPABILITY"

require_cmd jq cast

# ERC-20 canonical event topic0 hashes.
TRANSFER_TOPIC="0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
APPROVAL_TOPIC="0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925"

# -----------------------------------------------------------------------------
# Parse + validate
# -----------------------------------------------------------------------------
REQUEST="$(json_require_object)"

NETWORK_OVERRIDE="$(json_get_or '.network' "$REQUEST" "")"
[[ -n "$NETWORK_OVERRIDE" ]] && export LUMEN_NETWORK="$NETWORK_OVERRIDE"

PARAMS="$(json_get '.params' "$REQUEST" || true)"
[[ -z "$PARAMS" ]] && die "request.params is required" 2 missing_params

TX_HASH="$(json_get '.tx_hash' "$PARAMS" || true)"
[[ -z "$TX_HASH" ]] && die "params.tx_hash required" 2 missing_param
[[ "$TX_HASH" =~ ^0x[0-9a-fA-F]{64}$ ]] \
  || die "params.tx_hash must be 0x + 64 hex chars" 2 invalid_tx_hash

FORMATS="$(json_get_or '.formats' "$PARAMS" '["markdown","json","csv"]')"
OUTPUT_DIR="$(json_get_or '.output_dir' "$PARAMS" "")"

# -----------------------------------------------------------------------------
# Resolve network and fetch receipt
# -----------------------------------------------------------------------------
NETWORK_JSON="$(resolve_network)"
RPC_URL="$(jq -r .rpc_url <<<"$NETWORK_JSON")"
EXPLORER="$(jq -r .explorer_url <<<"$NETWORK_JSON")"
NETWORK_KEY="$(jq -r .key <<<"$NETWORK_JSON")"
CHAIN_ID="$(jq -r .chain_id <<<"$NETWORK_JSON")"

log_info "fetching receipt for $TX_HASH on $NETWORK_KEY"

RECEIPT_RAW="$(cast receipt --rpc-url "$RPC_URL" --json "$TX_HASH" 2>&1)" || {
  log_error "cast receipt failed: $RECEIPT_RAW"
  emit_error "$CAPABILITY" "receipt_fetch_failed" \
    "tx not found or RPC error" \
    "$(jq -Rn --arg o "$RECEIPT_RAW" '{cast_output:$o}')"
  exit 4
}

TX_FROM="$(jq -r '.from // "unknown"' <<<"$RECEIPT_RAW")"
TX_TO="$(jq -r '.to // "unknown"' <<<"$RECEIPT_RAW")"
TX_BLOCK="$(jq -r '.blockNumber // "unknown"' <<<"$RECEIPT_RAW")"
TX_GAS_USED="$(jq -r '.gasUsed // "unknown"' <<<"$RECEIPT_RAW")"
TX_STATUS="$(jq -r '.status // "unknown"' <<<"$RECEIPT_RAW")"
STATUS_OK="false"
[[ "$TX_STATUS" == "0x1" || "$TX_STATUS" == "1" ]] && STATUS_OK="true"

# -----------------------------------------------------------------------------
# Decode logs
#
# For ERC-20 Transfer/Approval:
#   topics[0]: event signature hash
#   topics[1]: from / owner (left-padded address as 32 bytes)
#   topics[2]: to / spender
#   data    : 32-byte uint256 amount
# -----------------------------------------------------------------------------
# Topic-to-address conversion is done inline in jq below: '"0x" + topics[i][26:]'.
DECODED_JSON="$(jq -c \
  --arg transfer "$TRANSFER_TOPIC" \
  --arg approval "$APPROVAL_TOPIC" \
  '
  .logs | map(
    . as $log
    | if (.topics | length) >= 3 then
        if .topics[0] == $transfer then
          {
            kind: "Transfer",
            token: $log.address,
            from: "0x" + ($log.topics[1] | .[26:]),
            to:   "0x" + ($log.topics[2] | .[26:]),
            amount_hex: $log.data,
            log_index: $log.logIndex
          }
        elif .topics[0] == $approval then
          {
            kind: "Approval",
            token: $log.address,
            owner: "0x" + ($log.topics[1] | .[26:]),
            spender: "0x" + ($log.topics[2] | .[26:]),
            amount_hex: $log.data,
            log_index: $log.logIndex
          }
        else empty
        end
      else empty
      end
  )' <<<"$RECEIPT_RAW")"

# Convert amount_hex → amount (decimal) for each entry via cast --to-dec.
DECODED_COUNT="$(jq 'length' <<<"$DECODED_JSON")"
DECODED_ENRICHED="[]"
for ((i = 0; i < DECODED_COUNT; i++)); do
  AMT_HEX="$(jq -r ".[$i].amount_hex" <<<"$DECODED_JSON")"
  AMT_DEC="$(cast to-dec "$AMT_HEX" 2>/dev/null || printf '0')"
  TOKEN_ADDR="$(jq -r ".[$i].token" <<<"$DECODED_JSON")"
  SYM="$(erc20_symbol "$RPC_URL" "$TOKEN_ADDR" 2>/dev/null || printf 'TOKEN')"
  DEC="$(erc20_decimals "$RPC_URL" "$TOKEN_ADDR" 2>/dev/null || printf '0')"
  DECODED_ENRICHED="$(jq -c \
    --argjson idx "$i" \
    --arg amt "$AMT_DEC" \
    --arg sym "$SYM" \
    --argjson dec "$DEC" \
    --argjson base "$DECODED_JSON" \
    --argjson cur "$DECODED_ENRICHED" \
    '$cur + [$base[$idx] + {amount: $amt, symbol: $sym, decimals: $dec}]' <<<"{}")"
done

# -----------------------------------------------------------------------------
# Output paths
# -----------------------------------------------------------------------------
[[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="${LUMEN_ROOT}/.lumen/receipts/${TX_HASH}"
mkdir -p "$OUTPUT_DIR"

WROTE=()

want_format() {
  printf '%s' "$FORMATS" | jq -e --arg f "$1" 'index($f)' >/dev/null
}

# -----------------------------------------------------------------------------
# Generate Markdown
# -----------------------------------------------------------------------------
if want_format markdown; then
  MD_PATH="$OUTPUT_DIR/receipt.md"
  # The backticks inside the printf format strings below are literal Markdown
  # fences, not bash command substitutions.
  # shellcheck disable=SC2016
  {
    printf '# Lumen Receipt\n\n'
    printf '- **Capability**: %s\n' "$CAPABILITY"
    printf '- **Network**: %s (chain id %s)\n' "$NETWORK_KEY" "$CHAIN_ID"
    printf '- **Tx hash**: `%s`\n' "$TX_HASH"
    printf '- **Explorer**: %s/tx/%s\n' "$EXPLORER" "$TX_HASH"
    printf '- **Status**: %s\n' "$( [[ "$STATUS_OK" == "true" ]] && printf 'success' || printf 'reverted')"
    printf '- **Block**: %s\n' "$TX_BLOCK"
    printf '- **From**: `%s`\n' "$TX_FROM"
    printf '- **To**: `%s`\n' "$TX_TO"
    printf '- **Gas used**: %s\n\n' "$TX_GAS_USED"

    if (( DECODED_COUNT == 0 )); then
      printf 'No ERC-20 Transfer or Approval events decoded from this transaction.\n'
    else
      printf '## Decoded events\n\n'
      printf '| # | Kind | Token | From / Owner | To / Spender | Amount |\n'
      printf '|---|------|-------|--------------|--------------|--------|\n'
      for ((i = 0; i < DECODED_COUNT; i++)); do
        row="$(jq -r --argjson i "$i" '.[$i] | [
          (.log_index // ""),
          .kind,
          (.token + " (" + .symbol + ")"),
          (.from // .owner),
          (.to // .spender),
          (.amount + " (raw)")
        ] | @tsv' <<<"$DECODED_ENRICHED")"
        printf '| %s |\n' "$(printf '%s' "$row" | sed 's/\t/ | /g')"
      done
    fi
  } >"$MD_PATH"
  WROTE+=("$MD_PATH")
fi

# -----------------------------------------------------------------------------
# Generate JSON
# -----------------------------------------------------------------------------
if want_format json; then
  JSON_PATH="$OUTPUT_DIR/receipt.json"
  jq -n \
    --arg cap "$CAPABILITY" \
    --arg network "$NETWORK_KEY" \
    --argjson chain_id "$CHAIN_ID" \
    --arg tx "$TX_HASH" \
    --arg explorer "$EXPLORER" \
    --arg from "$TX_FROM" \
    --arg to "$TX_TO" \
    --arg block "$TX_BLOCK" \
    --arg gas "$TX_GAS_USED" \
    --argjson ok "$STATUS_OK" \
    --argjson events "$DECODED_ENRICHED" \
    '{
      capability: $cap,
      network: $network,
      chain_id: $chain_id,
      tx: {
        hash: $tx,
        from: $from,
        to: $to,
        block_number: $block,
        gas_used: $gas,
        ok: $ok,
        explorer_url: ($explorer + "/tx/" + $tx)
      },
      events: $events
    }' >"$JSON_PATH"
  WROTE+=("$JSON_PATH")
fi

# -----------------------------------------------------------------------------
# Generate CSV
# -----------------------------------------------------------------------------
if want_format csv; then
  CSV_PATH="$OUTPUT_DIR/receipt.csv"
  {
    printf 'log_index,kind,token,token_symbol,token_decimals,from_or_owner,to_or_spender,amount\n'
    jq -r '
      .[] | [
        (.log_index // ""),
        .kind,
        .token,
        .symbol,
        .decimals,
        (.from // .owner),
        (.to // .spender),
        .amount
      ] | @csv
    ' <<<"$DECODED_ENRICHED"
  } >"$CSV_PATH"
  WROTE+=("$CSV_PATH")
fi

# -----------------------------------------------------------------------------
# Build response
# -----------------------------------------------------------------------------
ARTIFACTS_JSON="$(printf '%s\n' "${WROTE[@]}" | jq -R . | jq -s 'map({path: ., type: (split(".") | last)})')"

RESULT="$(jq -n \
  --arg cap "$CAPABILITY" \
  --arg network "$NETWORK_KEY" \
  --argjson chain_id "$CHAIN_ID" \
  --arg tx "$TX_HASH" \
  --argjson ok "$STATUS_OK" \
  --argjson events "$DECODED_ENRICHED" \
  --argjson artifacts "$ARTIFACTS_JSON" \
  --arg explorer "$EXPLORER" \
  --arg from "$TX_FROM" \
  --arg block "$TX_BLOCK" \
  --arg gas "$TX_GAS_USED" \
  '{
    capability: $cap,
    network: $network,
    chain_id: $chain_id,
    tx: {
      hash: $tx,
      from: $from,
      block_number: $block,
      gas_used: $gas,
      ok: $ok,
      explorer_url: ($explorer + "/tx/" + $tx)
    },
    events: $events,
    artifacts: $artifacts
  }')"

# Also append to the ledger as an audit-trail entry (with replay-safe key).
LEDGER_ENTRY="$(jq -c --arg idem "receipt-$TX_HASH" '. + {idempotency_key: $idem, kind: "receipt"}' <<<"$RESULT")"
printf '%s\n' "$LEDGER_ENTRY" | ledger_append

log_ok "receipt generated → $OUTPUT_DIR ($DECODED_COUNT event(s))"
emit_ok "$CAPABILITY" "$RESULT"

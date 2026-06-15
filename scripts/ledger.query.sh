#!/usr/bin/env bash
# ledger.query — historical payment lookup against the local Lumen ledger
# and/or on-chain Transfer logs.
#
# Filters:
#   - token       : restrict to one ERC-20 contract
#   - from        : restrict to a sender / owner
#   - to          : restrict to a recipient / spender
#   - capability  : restrict to a capability (pay.once, pay.split, …)
#   - since_unix  : earliest event timestamp (local source only)
#   - from_block  : earliest block (chain source only)
#   - to_block    : latest block (chain source only)
#   - limit       : max rows in the result
#
# Sources:
#   - local (default) : reads .lumen/ledger.ndjson
#   - chain           : runs cast logs against the configured RPC
#   - both            : union, deduplicated by tx hash
#
# See references/ledger.query.md.

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

CAPABILITY="ledger.query"
trap_capability "$CAPABILITY"

require_cmd jq cast

REQUEST="$(json_require_object)"
NETWORK_OVERRIDE="$(json_get_or '.network' "$REQUEST" "")"
[[ -n "$NETWORK_OVERRIDE" ]] && export LUMEN_NETWORK="$NETWORK_OVERRIDE"

PARAMS="$(json_get_or '.params' "$REQUEST" '{}')"

SOURCE="$(json_get_or '.source' "$PARAMS" "local")"
case "$SOURCE" in local|chain|both) ;; *) die "params.source must be local|chain|both" 2 invalid_source ;; esac

TOKEN="$(json_get_or '.token' "$PARAMS" "")"
FROM="$(json_get_or '.from' "$PARAMS" "")"
TO="$(json_get_or '.to' "$PARAMS" "")"
CAP="$(json_get_or '.capability' "$PARAMS" "")"
SINCE="$(json_get_or '.since_unix' "$PARAMS" "0")"
FROM_BLOCK="$(json_get_or '.from_block' "$PARAMS" "")"
TO_BLOCK="$(json_get_or '.to_block' "$PARAMS" "latest")"
LIMIT="$(json_get_or '.limit' "$PARAMS" "200")"
FORMATS="$(json_get_or '.formats' "$PARAMS" '["json"]')"
OUTPUT_DIR="$(json_get_or '.output_dir' "$PARAMS" "")"

[[ -n "$TOKEN" ]] && assert_address "$TOKEN" "params.token"
[[ -n "$FROM"  ]] && assert_address "$FROM"  "params.from"
[[ -n "$TO"    ]] && assert_address "$TO"    "params.to"
assert_uint "$LIMIT" "params.limit"
assert_uint "$SINCE" "params.since_unix"

NETWORK_JSON="$(resolve_network)"
RPC_URL="$(jq -r .rpc_url <<<"$NETWORK_JSON")"
EXPLORER="$(jq -r .explorer_url <<<"$NETWORK_JSON")"
CHAIN_ID="$(jq -r .chain_id <<<"$NETWORK_JSON")"
NETWORK_KEY="$(jq -r .key <<<"$NETWORK_JSON")"

TRANSFER_TOPIC="0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

# -----------------------------------------------------------------------------
# Local source
# -----------------------------------------------------------------------------
query_local() {
  if [[ ! -f "$LUMEN_LEDGER" ]]; then
    printf '[]'
    return
  fi
  # Each ledger line is a heterogeneous receipt envelope. Normalize into a
  # uniform shape: {source, tx_hash, capability, token, from, to, amount, timestamp}.
  jq -c -s \
    --arg token "$(to_lower_address "$TOKEN")" \
    --arg from  "$(to_lower_address "$FROM")" \
    --arg to    "$(to_lower_address "$TO")" \
    --arg cap   "$CAP" \
    --argjson since "$SINCE" \
    --argjson limit "$LIMIT" \
    '
    def lc: if . == null then "" else (. | ascii_downcase) end;
    def normalize:
      . as $r
      | if ($r.capability == "pay.once") then
          {
            source: "local", capability: $r.capability,
            tx_hash: $r.tx.hash,
            token: ($r.token.address // ""),
            symbol: ($r.token.symbol // ""),
            from: $r.sender,
            to: $r.recipient,
            amount: $r.amount,
            memo: $r.memo,
            idempotency_key: $r.idempotency_key
          }
        elif ($r.capability == "pay.split") then
          $r.allocations | map({
            source: "local", capability: $r.capability,
            tx_hash: ($r.txs | first | .hash // ""),
            token: ($r.token.address // ""),
            symbol: ($r.token.symbol // ""),
            from: $r.sender,
            to: .recipient,
            amount: .amount,
            memo: $r.memo,
            idempotency_key: $r.idempotency_key
          })
        elif ($r.capability == "pay.recurring" and $r.kind == "charge") then
          {
            source: "local", capability: $r.capability,
            tx_hash: $r.tx.hash,
            token: $r.token,
            symbol: "",
            from: $r.subscriber,
            to: $r.merchant,
            amount: $r.amount,
            memo: ("plan " + $r.plan_id + " period " + ($r.period_number | tostring)),
            idempotency_key: $r.idempotency_key
          }
        else empty
        end;
      [.[] | normalize]
      | flatten
      | map(select(
          ($token == "" or (.token | lc) == $token) and
          ($from  == "" or (.from  | lc) == $from)  and
          ($to    == "" or (.to    | lc) == $to)    and
          ($cap   == "" or .capability == $cap)
        ))
      | .[:$limit]
    ' "$LUMEN_LEDGER" 2>/dev/null || printf '[]'
}

# -----------------------------------------------------------------------------
# Chain source — eth_getLogs for ERC-20 Transfer.
# -----------------------------------------------------------------------------
pad_topic() {
  # Convert 0x… 40-hex address to 32-byte left-padded topic.
  local addr="$1"
  [[ -z "$addr" ]] && { printf 'null'; return; }
  printf '0x000000000000000000000000%s' "${addr:2}" | tr '[:upper:]' '[:lower:]'
}

query_chain() {
  local args=(--rpc-url "$RPC_URL")

  # cast logs accepts --from-block / --to-block plus topic positional args.
  [[ -n "$FROM_BLOCK" ]] && args+=(--from-block "$FROM_BLOCK")
  args+=(--to-block "$TO_BLOCK")
  [[ -n "$TOKEN" ]] && args+=(--address "$TOKEN")

  # topics:   [topic0]                [topic1=from] [topic2=to]
  local t0="$TRANSFER_TOPIC"
  local t1 t2
  t1="$(pad_topic "$FROM")"
  t2="$(pad_topic "$TO")"
  args+=("$t0")
  [[ "$t1" != "null" ]] && args+=("$t1")
  [[ "$t1" == "null" && "$t2" != "null" ]] && args+=("null" "$t2")
  [[ "$t1" != "null" && "$t2" != "null" ]] && args+=("$t2")

  local raw
  raw="$(cast logs --json "${args[@]}" 2>&1)" || {
    log_warn "cast logs failed: $raw"
    printf '[]'
    return
  }

  # Normalize the log set.
  jq -c \
    --arg explorer "$EXPLORER" \
    --argjson limit "$LIMIT" \
    '
    map({
      source: "chain",
      capability: "Transfer",
      tx_hash: .transactionHash,
      token: .address,
      symbol: "",
      from: ("0x" + (.topics[1][26:])),
      to:   ("0x" + (.topics[2][26:])),
      amount_hex: .data,
      block_number: .blockNumber,
      log_index: .logIndex,
      explorer_url: ($explorer + "/tx/" + .transactionHash)
    })
    | .[:$limit]
    ' <<<"$raw"
}

# Convert amount_hex → decimal for chain entries (cast to-dec).
enrich_chain() {
  local items="$1"
  local count
  count="$(jq 'length' <<<"$items")"
  local result="[]"
  for ((i = 0; i < count; i++)); do
    local hex
    hex="$(jq -r ".[$i].amount_hex" <<<"$items")"
    local dec
    dec="$(cast to-dec "$hex" 2>/dev/null || printf '0')"
    result="$(jq -c \
      --argjson i "$i" --arg dec "$dec" \
      --argjson base "$items" --argjson cur "$result" \
      '$cur + [$base[$i] + {amount: $dec}]' <<<"{}")"
  done
  printf '%s' "$result"
}

# -----------------------------------------------------------------------------
# Run the requested source(s) and combine.
# -----------------------------------------------------------------------------
LOCAL_RESULT="[]"
CHAIN_RESULT="[]"

if [[ "$SOURCE" == "local" || "$SOURCE" == "both" ]]; then
  LOCAL_RESULT="$(query_local)"
fi

if [[ "$SOURCE" == "chain" || "$SOURCE" == "both" ]]; then
  CHAIN_RAW="$(query_chain)"
  CHAIN_RESULT="$(enrich_chain "$CHAIN_RAW")"
fi

# Combine + dedupe by composite key.
ENTRIES="$(jq -c -n \
  --argjson a "$LOCAL_RESULT" --argjson b "$CHAIN_RESULT" \
  '
  ($a + $b)
  | unique_by(((.tx_hash // "") + "|" + ((.log_index // 0) | tostring) + "|"
               + (.to // "") + "|" + (.amount // "")))
  ')"

COUNT="$(jq 'length' <<<"$ENTRIES")"

# -----------------------------------------------------------------------------
# Output artefacts
# -----------------------------------------------------------------------------
want_format() {
  printf '%s' "$FORMATS" | jq -e --arg f "$1" 'index($f)' >/dev/null
}

[[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="${LUMEN_ROOT}/.lumen/queries/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUTPUT_DIR"
WROTE=()

if want_format json; then
  JSON_PATH="$OUTPUT_DIR/query.json"
  jq -n --argjson entries "$ENTRIES" \
    --arg network "$NETWORK_KEY" --argjson chain_id "$CHAIN_ID" \
    --arg source "$SOURCE" --argjson count "$COUNT" \
    '{network:$network, chain_id:$chain_id, source:$source, count:$count, entries:$entries}' \
    >"$JSON_PATH"
  WROTE+=("$JSON_PATH")
fi

if want_format csv; then
  CSV_PATH="$OUTPUT_DIR/query.csv"
  {
    printf 'source,capability,tx_hash,token,from,to,amount\n'
    jq -r '.[] | [.source, .capability, .tx_hash, .token, .from, .to, .amount] | @csv' \
      <<<"$ENTRIES"
  } >"$CSV_PATH"
  WROTE+=("$CSV_PATH")
fi

if want_format markdown; then
  MD_PATH="$OUTPUT_DIR/query.md"
  {
    printf '# Lumen Ledger Query\n\n'
    printf '- **Network**: %s (chain id %s)\n' "$NETWORK_KEY" "$CHAIN_ID"
    printf '- **Source**: %s\n' "$SOURCE"
    printf '- **Filters**: token=%s from=%s to=%s capability=%s\n' \
      "${TOKEN:-*}" "${FROM:-*}" "${TO:-*}" "${CAP:-*}"
    printf '- **Total rows**: %s\n\n' "$COUNT"

    if (( COUNT == 0 )); then
      printf 'No matching entries.\n'
    else
      printf '| Src | Capability | Tx | Token | From | To | Amount |\n'
      printf '|-----|------------|----|-------|------|----|--------|\n'
      jq -r '.[] | "| \(.source) | \(.capability) | `\(.tx_hash)` | \(.token) | \(.from) | \(.to) | \(.amount) |"' \
        <<<"$ENTRIES"
    fi
  } >"$MD_PATH"
  WROTE+=("$MD_PATH")
fi

ARTIFACTS_JSON="$(printf '%s\n' "${WROTE[@]}" | jq -R . | jq -s 'map({path:., type: (split(".") | last)})')"

emit_ok "$CAPABILITY" "$(jq -n \
  --arg network "$NETWORK_KEY" --argjson chain_id "$CHAIN_ID" \
  --arg source "$SOURCE" --argjson count "$COUNT" \
  --argjson entries "$ENTRIES" --argjson artifacts "$ARTIFACTS_JSON" \
  '{network:$network, chain_id:$chain_id, source:$source, count:$count,
    entries:$entries, artifacts:$artifacts}')"

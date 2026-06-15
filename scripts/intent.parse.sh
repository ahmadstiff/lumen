#!/usr/bin/env bash
# intent.parse — deterministic natural-language → Lumen capability mapper.
#
# Reads a user/agent utterance and returns the best matching capability
# request as JSON, plus a confidence score and hints. This script is
# explicitly NOT an LLM: it uses regex templates so the calling agent stays
# in control of disambiguation. If the utterance is ambiguous or fails to
# match any template, the script returns suggestions for the agent to
# refine the input.
#
# Why ship this at all? Two reasons:
#   1. Predictable, audit-friendly mapping of common payment phrasings to
#      structured envelopes.
#   2. A clean error path with "candidates" so an LLM-powered agent can
#      iterate without re-implementing the trivia.
#
# See references/intent.parse.md.

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

CAPABILITY="intent.parse"
trap_capability "$CAPABILITY"

require_cmd jq

REQUEST="$(json_require_object)"
PARAMS="$(json_get '.params' "$REQUEST" || true)"
[[ -z "$PARAMS" ]] && die "request.params is required" 2 missing_params

UTTERANCE="$(json_get '.utterance' "$PARAMS" || true)"
[[ -z "$UTTERANCE" ]] && die "params.utterance required" 2 missing_param

DEFAULT_TOKEN="$(json_get_or '.default_token' "$PARAMS" "")"
DEFAULT_NETWORK="$(json_get_or '.default_network' "$PARAMS" "atlantic")"

# Lower-cased, single-spaced version for matching.
NORM="$(printf '%s' "$UTTERANCE" \
  | tr '[:upper:]' '[:lower:]' \
  | tr -s '[:space:]' ' ')"

# Address & amount regexes (POSIX-extended via bash =~).
RX_ADDR='0x[0-9a-fA-F]{40}'
RX_NUM='[0-9]+(\.[0-9]+)?'

CANDIDATES_JSON='[]'
add_candidate() {
  # add_candidate <capability> <confidence 0-100> <request_json> <reason>
  CANDIDATES_JSON="$(jq -c --argjson c "$CANDIDATES_JSON" \
    --arg cap "$1" --argjson conf "$2" \
    --argjson req "$3" --arg reason "$4" \
    '$c + [{capability:$cap, confidence:$conf, request:$req, reason:$reason}]' \
    <<<"{}")"
}

# Resolve a literal "USDC" / "PHRS" / etc token reference if known. We only
# allow lookup when the operator supplied default_token; otherwise the agent
# must echo a concrete address back.
resolve_token_word() {
  local sym="$1"
  [[ "$sym" == "0x"* ]] && { printf '%s' "$sym"; return; }
  if [[ -n "$DEFAULT_TOKEN" ]]; then
    printf '%s' "$DEFAULT_TOKEN"
  else
    printf 'TOKEN_PLACEHOLDER'
  fi
}

build_request() {
  # build_request <network> <params_json>
  jq -n --arg network "$1" --argjson params "$2" \
    '{network:$network, params:$params}'
}

# -----------------------------------------------------------------------------
# Pattern 1: "send <AMOUNT> <TOKEN?> to <ADDR>" → pay.once
# -----------------------------------------------------------------------------
if [[ "$NORM" =~ (send|pay|transfer)[[:space:]]+($RX_NUM)[[:space:]]+([a-z0-9]+)?[[:space:]]*to[[:space:]]+($RX_ADDR) ]]; then
  amount_h="${BASH_REMATCH[2]}"
  symbol="${BASH_REMATCH[4]:-}"
  to_addr="${BASH_REMATCH[5]}"
  token="$(resolve_token_word "$symbol")"
  # Convert decimal to base units assuming 6 decimals for stablecoin defaults
  # or 18 if symbol matches /eth|phrs/. The agent is expected to override via
  # default_token + decimals knowledge.
  if [[ "$symbol" =~ ^(eth|phrs|matic)$ ]]; then
    base="$(printf '%s*1000000000000000000\n' "$amount_h" | bc | sed 's/\..*//')"
  else
    base="$(printf '%s*1000000\n' "$amount_h" | bc | sed 's/\..*//')"
  fi
  req="$(build_request "$DEFAULT_NETWORK" \
    "$(jq -n --arg t "$token" --arg r "$to_addr" --arg a "$base" --arg memo "$UTTERANCE" \
       '{token:$t, recipient:$r, amount:$a, memo:$memo}')")"
  add_candidate "pay.once" 85 "$req" \
    "Matched 'send <amount> <token?> to <address>'."
fi

# -----------------------------------------------------------------------------
# Pattern 2: "tip <AMOUNT> <TOKEN?> to <ADDR>" → pay.tip (send action)
# -----------------------------------------------------------------------------
if [[ "$NORM" =~ (tip|reward)[[:space:]]+($RX_NUM)[[:space:]]+([a-z0-9]+)?[[:space:]]*to[[:space:]]+($RX_ADDR) ]]; then
  amount_h="${BASH_REMATCH[2]}"
  symbol="${BASH_REMATCH[4]:-}"
  to_addr="${BASH_REMATCH[5]}"
  token="$(resolve_token_word "$symbol")"
  if [[ "$symbol" =~ ^(eth|phrs|matic)$ ]]; then
    base="$(printf '%s*1000000000000000000\n' "$amount_h" | bc | sed 's/\..*//')"
  else
    base="$(printf '%s*1000000\n' "$amount_h" | bc | sed 's/\..*//')"
  fi
  req="$(build_request "$DEFAULT_NETWORK" \
    "$(jq -n --arg t "$token" --arg r "$to_addr" --arg a "$base" --arg memo "$UTTERANCE" \
       '{action:"send", token:$t, recipient:$r, amount:$a, memo:$memo}')")"
  add_candidate "pay.tip" 90 "$req" \
    "Matched 'tip/reward <amount> <token?> to <address>'."
fi

# -----------------------------------------------------------------------------
# Pattern 3: "split <AMOUNT> <TOKEN?> evenly between <ADDR>, <ADDR>, …"
#            → pay.split with bps shares 10000/N
# -----------------------------------------------------------------------------
if [[ "$NORM" =~ split[[:space:]]+($RX_NUM)[[:space:]]+([a-z0-9]+)?[[:space:]]*(evenly|equally)?[[:space:]]*(between|across|among)[[:space:]]+(.+) ]]; then
  amount_h="${BASH_REMATCH[2]}"
  symbol="${BASH_REMATCH[4]:-}"
  rest="${BASH_REMATCH[8]}"
  token="$(resolve_token_word "$symbol")"

  # Extract all 0x addresses from `rest`.
  recipients_json='[]'
  while [[ "$rest" =~ ($RX_ADDR) ]]; do
    addr="${BASH_REMATCH[1]}"
    recipients_json="$(jq -c --argjson r "$recipients_json" --arg a "$addr" '$r + [$a]' <<<"{}")"
    rest="${rest#*"$addr"}"
  done

  n="$(jq 'length' <<<"$recipients_json")"
  if (( n >= 2 )); then
    if [[ "$symbol" =~ ^(eth|phrs|matic)$ ]]; then
      total="$(printf '%s*1000000000000000000\n' "$amount_h" | bc | sed 's/\..*//')"
    else
      total="$(printf '%s*1000000\n' "$amount_h" | bc | sed 's/\..*//')"
    fi
    # Compute even bps: each gets 10000/N; last takes remainder.
    even=$((10000 / n))
    shares_json="$(jq -c -n --argjson n "$n" --argjson even "$even" \
      '[range(0; $n-1) | $even] + [10000 - ($even * ($n - 1))]')"
    req="$(build_request "$DEFAULT_NETWORK" \
      "$(jq -n --arg t "$token" --argjson r "$recipients_json" \
         --argjson s "$shares_json" --arg tot "$total" --arg memo "$UTTERANCE" \
         '{token:$t, recipients:$r, shares_bps:$s, total:$tot, memo:$memo}')")"
    add_candidate "pay.split" 80 "$req" \
      "Matched 'split <amount> <token?> evenly between <addresses>'. $n recipients found."
  fi
fi

# -----------------------------------------------------------------------------
# Pattern 4: "approve <ADDR> to spend <AMOUNT> <TOKEN?> for <HOURS> hours"
#            → approval.scope
# -----------------------------------------------------------------------------
if [[ "$NORM" =~ (approve|allow)[[:space:]]+($RX_ADDR)[[:space:]]+(to[[:space:]]+spend)?[[:space:]]*($RX_NUM)[[:space:]]+([a-z0-9]+)?[[:space:]]*(for[[:space:]]+($RX_NUM)[[:space:]]+(hour|hours|day|days)) ]]; then
  spender="${BASH_REMATCH[2]}"
  amount_h="${BASH_REMATCH[4]}"
  symbol="${BASH_REMATCH[6]:-}"
  duration="${BASH_REMATCH[8]}"
  unit="${BASH_REMATCH[10]}"
  token="$(resolve_token_word "$symbol")"
  case "$unit" in
    hour|hours) secs="$(printf '%s*3600\n' "$duration" | bc | sed 's/\..*//')" ;;
    day|days)   secs="$(printf '%s*86400\n' "$duration" | bc | sed 's/\..*//')" ;;
    *)          secs="86400" ;;
  esac
  now="$(date -u +%s)"
  expiry=$((now + secs))
  if [[ "$symbol" =~ ^(eth|phrs|matic)$ ]]; then
    base="$(printf '%s*1000000000000000000\n' "$amount_h" | bc | sed 's/\..*//')"
  else
    base="$(printf '%s*1000000\n' "$amount_h" | bc | sed 's/\..*//')"
  fi
  req="$(build_request "$DEFAULT_NETWORK" \
    "$(jq -n --arg t "$token" --arg s "$spender" --arg a "$base" \
       --argjson exp "$expiry" --arg memo "$UTTERANCE" \
       '{token:$t, spender:$s, amount:$a, expiry_unix:$exp, memo:$memo}')")"
  add_candidate "approval.scope" 78 "$req" \
    "Matched 'approve <spender> to spend <amount> <token?> for <duration>'."
fi

# -----------------------------------------------------------------------------
# Pattern 5: "show|list payments [to|from <ADDR>] [token <ADDR>]"
#            → ledger.query
# -----------------------------------------------------------------------------
if [[ "$NORM" =~ (show|list|find)[[:space:]]+(my[[:space:]]+)?(payments|tips|transfers) ]]; then
  to_addr=""
  from_addr=""
  if [[ "$NORM" =~ to[[:space:]]+($RX_ADDR) ]]; then
    to_addr="${BASH_REMATCH[1]}"
  fi
  if [[ "$NORM" =~ from[[:space:]]+($RX_ADDR) ]]; then
    from_addr="${BASH_REMATCH[1]}"
  fi
  token=""
  if [[ "$NORM" =~ token[[:space:]]+($RX_ADDR) ]]; then
    token="${BASH_REMATCH[1]}"
  fi
  req="$(build_request "$DEFAULT_NETWORK" \
    "$(jq -n --arg t "$token" --arg to "$to_addr" --arg from "$from_addr" \
       '{
         source: "both",
         token:  (if $t   == "" then null else $t   end),
         to:     (if $to  == "" then null else $to  end),
         from:   (if $from== "" then null else $from end),
         limit: 100,
         formats: ["json","markdown"]
       } | with_entries(select(.value != null))')")"
  add_candidate "ledger.query" 70 "$req" \
    "Matched a payment-history query."
fi

# -----------------------------------------------------------------------------
# Resolve final output
# -----------------------------------------------------------------------------
COUNT="$(jq 'length' <<<"$CANDIDATES_JSON")"

if (( COUNT == 0 )); then
  emit_error "$CAPABILITY" "no_match" \
    "no template matched this utterance" \
    "$(jq -n --arg u "$UTTERANCE" \
       '{
         utterance: $u,
         hints: [
           "Try patterns like:",
           "  send 10 USDC to 0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
           "  split 100 USDC evenly between 0xabc..., 0xdef...",
           "  approve 0xabc... to spend 50 USDC for 24 hours",
           "  tip 5 USDC to 0xdef...",
           "  show my payments to 0xabc..."
         ]
       }')"
  exit 4
fi

# Sort candidates by confidence DESC.
CANDIDATES_JSON="$(jq 'sort_by(.confidence) | reverse' <<<"$CANDIDATES_JSON")"
BEST="$(jq -c '.[0]' <<<"$CANDIDATES_JSON")"
BEST_CAP="$(jq -r '.capability' <<<"$BEST")"
BEST_CONF="$(jq -r '.confidence' <<<"$BEST")"

log_ok "intent matched: $BEST_CAP (confidence=$BEST_CONF, total candidates=$COUNT)"

emit_ok "$CAPABILITY" "$(jq -n \
  --arg utt "$UTTERANCE" \
  --argjson best "$BEST" \
  --argjson all "$CANDIDATES_JSON" \
  '{
    utterance: $utt,
    best_match: $best,
    candidates: $all,
    notes: [
      "amount conversion assumes 6 decimals (stablecoin) unless symbol matches /eth|phrs|matic/ in which case 18.",
      "Always validate token address and amount before piping to the suggested capability."
    ]
  }')"

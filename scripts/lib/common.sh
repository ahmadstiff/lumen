#!/usr/bin/env bash
# Lumen shared library — strict mode, logging, RPC, JSON helpers.
#
# Source this file from every capability script:
#   # shellcheck source=lib/common.sh
#   . "${LUMEN_LIB:-$(dirname "$0")/lib/common.sh}"
#
# Conventions:
#   - All amounts handled as decimal strings (no scientific notation, no float).
#   - All times in ISO-8601 UTC (date -u +%Y-%m-%dT%H:%M:%SZ).
#   - All addresses lower-cased before comparison; checksum preserved in output.
#   - JSON I/O: stdin = request, stdout = response, stderr = human-readable logs.
#   - Idempotency: every mutation accepts an optional `idempotency_key`; if the
#     same key appears in .lumen/ledger.ndjson, the prior receipt is returned.

# Strict mode — fail fast, never glob unexpectedly, propagate pipe failures.
set -Eeuo pipefail
IFS=$'\n\t'

# Resolve project root from this library's path (lib/ → ../.. = project root).
__LUMEN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LUMEN_ROOT="${LUMEN_ROOT:-$(cd "${__LUMEN_LIB_DIR}/../.." && pwd)}"
export LUMEN_ROOT

# -----------------------------------------------------------------------------
# Logging — colorised on TTY, plain otherwise. Writes to stderr to keep stdout
# clean for JSON output.
# -----------------------------------------------------------------------------
if [[ -t 2 ]]; then
  __LUMEN_C_RED=$'\033[31m'
  __LUMEN_C_YELLOW=$'\033[33m'
  __LUMEN_C_GREEN=$'\033[32m'
  __LUMEN_C_DIM=$'\033[2m'
  __LUMEN_C_RST=$'\033[0m'
else
  __LUMEN_C_RED=""
  __LUMEN_C_YELLOW=""
  __LUMEN_C_GREEN=""
  __LUMEN_C_DIM=""
  __LUMEN_C_RST=""
fi

log_info()  { printf '%s[lumen] info%s  %s\n'  "${__LUMEN_C_DIM}"    "${__LUMEN_C_RST}" "$*" >&2; }
log_warn()  { printf '%s[lumen] warn%s  %s\n'  "${__LUMEN_C_YELLOW}" "${__LUMEN_C_RST}" "$*" >&2; }
log_error() { printf '%s[lumen] error%s %s\n'  "${__LUMEN_C_RED}"    "${__LUMEN_C_RST}" "$*" >&2; }
log_ok()    { printf '%s[lumen] ok%s    %s\n'  "${__LUMEN_C_GREEN}"  "${__LUMEN_C_RST}" "$*" >&2; }

die() {
  # Exit with a structured JSON error envelope on stdout (if a capability is
  # active) and a human-readable log on stderr. The first argument is the
  # message; the second optional argument is the exit code (default 1); the
  # third optional argument is the error code (default "validation_error").
  local msg="$1"
  local code="${2:-1}"
  local err_code="${3:-validation_error}"
  if [[ -n "${__LUMEN_CAPABILITY:-}" ]]; then
    emit_error "$__LUMEN_CAPABILITY" "$err_code" "$msg"
  fi
  log_error "$msg"
  exit "$code"
}

# -----------------------------------------------------------------------------
# Dependency checks. Each script declares its needed tools via require_cmd.
# -----------------------------------------------------------------------------
require_cmd() {
  local missing=()
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    die "missing required command(s): ${missing[*]}" 127
  fi
}

# -----------------------------------------------------------------------------
# JSON helpers — wrap jq to keep error handling consistent.
# -----------------------------------------------------------------------------
json_get() {
  # Read a JSON value at a jq path from the second arg (a JSON string).
  # Usage: json_get '.token' "$payload"
  local path="$1" payload="$2"
  printf '%s' "$payload" | jq -er "$path" 2>/dev/null || return 1
}

json_get_or() {
  # Return the JSON value at jq `path` from `payload`, or `fallback` if the
  # value is absent or JSON null. We use `// empty` so jq emits nothing when
  # the path is missing/null — otherwise jq -e prints "null\n" before failing
  # and the fallback can become "null${fallback}".
  # Usage: json_get_or '.foo' "$payload" "fallback"
  local path="$1" payload="$2" fallback="$3"
  local v
  v="$(printf '%s' "$payload" | jq -r "$path // empty" 2>/dev/null)"
  if [[ -n "$v" ]]; then
    printf '%s' "$v"
  else
    printf '%s' "$fallback"
  fi
}

# Pretty-print stdin as JSON. Falls back to passthrough if not valid JSON.
json_pretty() { jq --indent 2 . 2>/dev/null || cat; }

# Validate that stdin is a JSON object. Exits non-zero with helpful error.
json_require_object() {
  local payload
  payload="$(cat)"
  printf '%s' "$payload" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || die "expected JSON object input, got: $(printf '%s' "$payload" | head -c 80)…"
  printf '%s' "$payload"
}

# -----------------------------------------------------------------------------
# Network resolution. Reads assets/networks.json with optional env overrides.
# -----------------------------------------------------------------------------
LUMEN_NETWORKS_FILE="${LUMEN_NETWORKS_FILE:-${LUMEN_ROOT}/assets/networks.json}"

network_field() {
  # Usage: network_field <network_key> <field_path>
  # Example: network_field atlantic .rpc_url
  local key="$1" field="$2"
  jq -er ".networks[\"$key\"]$field" "$LUMEN_NETWORKS_FILE" \
    || die "unknown network or field: $key$field"
}

resolve_network() {
  # Outputs JSON with resolved network. Honors LUMEN_RPC_URL / LUMEN_EXPLORER_URL.
  local key="${LUMEN_NETWORK:-atlantic}"
  local rpc explorer chain_id name native
  rpc="$(network_field "$key" .rpc_url)"
  explorer="$(network_field "$key" .explorer_url)"
  chain_id="$(network_field "$key" .chain_id)"
  name="$(network_field "$key" .name)"
  native="$(network_field "$key" .native_symbol)"
  rpc="${LUMEN_RPC_URL:-$rpc}"
  explorer="${LUMEN_EXPLORER_URL:-$explorer}"
  jq -n \
    --arg key "$key" --arg name "$name" --arg rpc "$rpc" \
    --arg explorer "$explorer" --arg native "$native" \
    --argjson chain_id "$chain_id" \
    '{key:$key, name:$name, chain_id:$chain_id, rpc_url:$rpc, explorer_url:$explorer, native_symbol:$native}'
}

# -----------------------------------------------------------------------------
# Sender authentication selector. Returns the cast flag set to use for sending.
# Prefers keystore > account > raw key, refusing to mix.
# -----------------------------------------------------------------------------
sender_cast_flags() {
  local flags=()
  local set_count=0
  if [[ -n "${LUMEN_KEYSTORE:-}" ]]; then
    flags+=(--keystore "$LUMEN_KEYSTORE")
    set_count=$((set_count + 1))
  fi
  if [[ -n "${LUMEN_ACCOUNT:-}" ]]; then
    flags+=(--account "$LUMEN_ACCOUNT")
    set_count=$((set_count + 1))
  fi
  if [[ -n "${LUMEN_PRIVATE_KEY:-}" ]]; then
    flags+=(--private-key "$LUMEN_PRIVATE_KEY")
    set_count=$((set_count + 1))
  fi
  if (( set_count == 0 )); then
    die "no sender configured: set LUMEN_KEYSTORE, LUMEN_ACCOUNT, or LUMEN_PRIVATE_KEY"
  fi
  if (( set_count > 1 )); then
    die "ambiguous sender: set exactly one of LUMEN_KEYSTORE / LUMEN_ACCOUNT / LUMEN_PRIVATE_KEY"
  fi
  printf '%s\n' "${flags[@]}"
}

# -----------------------------------------------------------------------------
# Address & hex utilities.
# -----------------------------------------------------------------------------
to_lower_address() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

assert_address() {
  # 0x followed by exactly 40 hex characters.
  local addr="$1" label="${2:-address}"
  [[ "$addr" =~ ^0x[0-9a-fA-F]{40}$ ]] \
    || die "invalid $label: '$addr' (expected 0x-prefixed 40-hex)"
}

assert_uint() {
  # Decimal positive integer string. No scientific, no negatives.
  local value="$1" label="${2:-value}"
  [[ "$value" =~ ^[0-9]+$ ]] \
    || die "invalid $label: '$value' (expected non-negative decimal integer)"
}

# -----------------------------------------------------------------------------
# Big-number arithmetic via `bc`. bash builtin arithmetic only handles int64;
# ERC-20 amounts in 18-decimal wei routinely exceed that, so we route every
# multiplication / division through bc which has arbitrary precision.
# -----------------------------------------------------------------------------
bignum_mul_div() {
  # Computes floor(a * b / c). Defaults c to 10000 (basis-points denominator).
  local a="$1" b="$2" c="${3:-10000}"
  printf '%s*%s/%s\n' "$a" "$b" "$c" | bc
}

bignum_sub() {
  local a="$1" b="$2"
  printf '%s-%s\n' "$a" "$b" | bc
}

bignum_lt() {
  # Returns 0 (true) if a < b, 1 otherwise.
  local a="$1" b="$2"
  local res
  res="$(printf '%s<%s\n' "$a" "$b" | bc)"
  [[ "$res" == "1" ]]
}

# -----------------------------------------------------------------------------
# ERC20 helpers via cast.
# -----------------------------------------------------------------------------
erc20_decimals() {
  # Usage: erc20_decimals <rpc_url> <token>
  local rpc="$1" token="$2"
  cast call --rpc-url "$rpc" "$token" "decimals()(uint8)" 2>/dev/null \
    || die "failed to read decimals() for $token"
}

erc20_symbol() {
  local rpc="$1" token="$2"
  cast call --rpc-url "$rpc" "$token" "symbol()(string)" 2>/dev/null \
    | tr -d '"' \
    || die "failed to read symbol() for $token"
}

erc20_balance_of() {
  local rpc="$1" token="$2" owner="$3"
  cast call --rpc-url "$rpc" "$token" "balanceOf(address)(uint256)" "$owner" \
    | awk '{print $1}'
}

# -----------------------------------------------------------------------------
# Idempotency ledger. Append-only NDJSON at .lumen/ledger.ndjson.
# Each line is a receipt envelope; the key field is `idempotency_key`.
# -----------------------------------------------------------------------------
LUMEN_LEDGER="${LUMEN_LEDGER:-${LUMEN_ROOT}/.lumen/ledger.ndjson}"

ledger_lookup() {
  # Usage: ledger_lookup <idempotency_key>
  # Outputs the matching JSON line (latest wins) or empty.
  local key="$1"
  [[ -z "$key" || ! -f "$LUMEN_LEDGER" ]] && return 0
  # Read entire ledger, filter by idempotency_key, take the last match.
  jq -c --arg k "$key" 'select(.idempotency_key == $k)' "$LUMEN_LEDGER" 2>/dev/null \
    | tail -n 1
}

ledger_append() {
  # Append one JSON line. Input on stdin.
  mkdir -p "$(dirname "$LUMEN_LEDGER")"
  jq -c . >> "$LUMEN_LEDGER"
}

new_idempotency_key() {
  # Deterministic prefix + monotonic suffix for human readability.
  local prefix="${1:-lumen}"
  local ts
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  local rand
  rand="$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 8 || true)"
  printf '%s-%s-%s' "$prefix" "$ts" "$rand"
}

# -----------------------------------------------------------------------------
# Output envelopes. Capabilities always emit a single JSON object on stdout.
# -----------------------------------------------------------------------------
emit_ok() {
  # Usage: emit_ok <capability> <json_body>
  local cap="$1" body="$2"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -n --arg cap "$cap" --arg ts "$ts" --argjson body "$body" \
    '{status:"ok", capability:$cap, timestamp:$ts, result:$body}'
}

emit_error() {
  # Usage: emit_error <capability> <code> <message> [details_json]
  local cap="$1" code="$2" msg="$3" details="${4:-null}"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -n \
    --arg cap "$cap" --arg ts "$ts" --arg code "$code" --arg msg "$msg" \
    --argjson details "$details" \
    '{status:"error", capability:$cap, timestamp:$ts, error:{code:$code, message:$msg, details:$details}}'
}

# Trap to convert unexpected bash errors into a structured error envelope on stdout
# AND a human log on stderr. Set capability name with: trap_capability "pay.once"
trap_capability() {
  __LUMEN_CAPABILITY="$1"
  trap '__lumen_on_err $?' ERR
}

__lumen_on_err() {
  local code="$1"
  local cap="${__LUMEN_CAPABILITY:-unknown}"
  emit_error "$cap" "internal_error" "script exited with code $code (line ${BASH_LINENO[0]:-?})"
  exit "$code"
}

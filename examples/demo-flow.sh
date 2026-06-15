#!/usr/bin/env bash
# Lumen end-to-end demo — one command, JSON in / JSON out.
#
# Order of operations:
#   1. intent.parse  — OFFLINE, no wallet. Natural language -> ranked Lumen
#      capability requests. Always runs; needs only `jq`.
#   2. Live or dry-run:
#        - LIVE  (opt-in): if a sender wallet and LUMEN_DEMO_TOKEN are set and
#          `cast` is installed, executes pay.once -> receipt.generate ->
#          ledger.query on Pharos Atlantic testnet.
#        - DRY RUN (default): prints the exact JSON requests it *would* send,
#          without broadcasting anything.
#
# Safety:
#   - Never hard-codes a private key; the wallet comes from your environment.
#   - Defaults to the Atlantic *testnet*; it never targets mainnet.
#
# Examples:
#   examples/demo-flow.sh
#   LUMEN_DEMO_TOKEN=0xYourTestToken LUMEN_ACCOUNT=lumen-sender examples/demo-flow.sh
#
# See examples/README.md for how to deploy a throwaway test token and capture
# transaction hashes for the hackathon submission.

set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
SCRIPTS="$REPO_ROOT/scripts"
REQ="$HERE/requests"

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }
rule() { printf '%s\n' '============================================================'; }

command -v jq >/dev/null 2>&1 || { printf 'jq is required\n' >&2; exit 127; }

export LUMEN_NETWORK="${LUMEN_NETWORK:-atlantic}"

rule
printf 'Lumen demo  .  network=%s\n' "$LUMEN_NETWORK"
rule

# --------------------------------------------------------------------------
# Step 1 — intent.parse (offline, deterministic, no wallet)
# --------------------------------------------------------------------------
bold '1) intent.parse  (offline -- natural language to ranked requests)'
note 'request: examples/requests/intent.parse.json'
intent_out="$("$SCRIPTS/intent.parse.sh" < "$REQ/intent.parse.json" 2>/dev/null || true)"
printf '%s\n' "$intent_out" | jq . 2>/dev/null || printf '%s\n' "$intent_out"

# --------------------------------------------------------------------------
# Decide LIVE vs DRY RUN.
# --------------------------------------------------------------------------
have_wallet=false
[[ -n "${LUMEN_KEYSTORE:-}${LUMEN_ACCOUNT:-}${LUMEN_PRIVATE_KEY:-}" ]] && have_wallet=true
have_cast=false
command -v cast >/dev/null 2>&1 && have_cast=true

if [[ "$have_wallet" == true && "$have_cast" == true && -n "${LUMEN_DEMO_TOKEN:-}" ]]; then
  bold '2) pay.once  (LIVE -- single ERC-20 transfer)'
  once_req="$(jq --arg t "$LUMEN_DEMO_TOKEN" '.params.token = $t' "$REQ/pay.once.json")"
  once_out="$(printf '%s' "$once_req" | "$SCRIPTS/pay.once.sh" 2>/dev/null || true)"
  printf '%s\n' "$once_out" | jq . 2>/dev/null || printf '%s\n' "$once_out"

  tx_hash="$(printf '%s' "$once_out" | jq -r '.result.tx.hash // empty' 2>/dev/null || true)"
  if [[ -n "$tx_hash" && "$tx_hash" != unknown ]]; then
    bold '3) receipt.generate  (LIVE -- decode tx to MD + JSON + CSV)'
    note "tx: $tx_hash"
    jq --arg h "$tx_hash" '.params.tx_hash = $h' "$REQ/receipt.generate.json" \
      | "$SCRIPTS/receipt.generate.sh" 2>/dev/null \
      | jq '{tx: .result.tx.hash, artifacts: .result.artifacts}' 2>/dev/null || true
  fi

  bold '4) ledger.query  (replay the local append-only audit ledger)'
  "$SCRIPTS/ledger.query.sh" < "$REQ/ledger.query.json" 2>/dev/null \
    | jq '{count: .result.count, entries: .result.entries}' 2>/dev/null || true

  rule
  printf 'Done. Copy the tx hash(es) above into docs/HACKATHON.md (section 5)\n'
  printf 'and your DoraHacks BUIDL description as proof of Pharos deployment.\n'
  rule
  exit 0
fi

# --------------------------------------------------------------------------
# DRY RUN — show the exact requests that would be sent on-chain.
# --------------------------------------------------------------------------
missing=()
[[ "$have_cast" == true ]] || missing+=('cast (foundry)')
[[ "$have_wallet" == true ]] || missing+=('a wallet (LUMEN_KEYSTORE | LUMEN_ACCOUNT | LUMEN_PRIVATE_KEY)')
[[ -n "${LUMEN_DEMO_TOKEN:-}" ]] || missing+=('LUMEN_DEMO_TOKEN=0x...')

bold '2) DRY RUN  (no on-chain transactions were sent)'
note "to run the LIVE flow, provide: ${missing[*]}"

bold 'pay.once -- the request that WOULD be sent:'
jq . "$REQ/pay.once.json"

bold 'pay.split -- atomic Multicall3 split that WOULD be sent:'
note 'needs a prior approval.scope (mode=permit2) to Multicall3 -- see examples/requests/approval.scope.json'
jq . "$REQ/pay.split.json"

rule
note 'Next: see examples/README.md to deploy a throwaway test token and go live.'
rule

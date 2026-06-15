#!/usr/bin/env bash
# record-demo.sh — turnkey presenter for the Lumen demo video.
#
# One command, paste-and-go. Prints clean section banners and pauses between
# steps so you can narrate. Defaults are wired for the recorded Atlantic demo.
#
# Override via environment:
#   LUMEN_ACCOUNT     cast-managed account name      (default: lumen-sender)
#   LUMEN_DEMO_TOKEN  ERC-20 to move                 (default: deployed lUSD)
#   LUMEN_NETWORK     network key                    (default: atlantic)
#   FAST=1            run straight through, no pauses
#   FRESH=1           broadcast a NEW pay.once tx (asks the keystore password);
#                     the default REPLAYS the recorded tx idempotently, so the
#                     run is fully green with no password prompt.
#
# Usage:
#   examples/record-demo.sh            # smooth replay run (no password)
#   FRESH=1 examples/record-demo.sh    # broadcast a brand-new live tx
#   FAST=1  examples/record-demo.sh    # no pauses (CI / rehearsal)

set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
SCRIPTS="$REPO_ROOT/scripts"
REQ="$HERE/requests"

command -v jq   >/dev/null 2>&1 || { printf 'jq is required\n' >&2; exit 127; }
command -v cast >/dev/null 2>&1 || { printf 'cast (foundry) is required\n' >&2; exit 127; }

export LUMEN_NETWORK="${LUMEN_NETWORK:-atlantic}"
# Default the sender to a cast account unless a wallet is already configured.
if [[ -z "${LUMEN_KEYSTORE:-}${LUMEN_ACCOUNT:-}${LUMEN_PRIVATE_KEY:-}" ]]; then
  export LUMEN_ACCOUNT="lumen-sender"
fi
TOKEN="${LUMEN_DEMO_TOKEN:-${1:-0x4Cdc17C2738224b282153572ef052E661086D4E9}}"
EXPLORER="https://atlantic.pharosscan.xyz"

banner() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }
note()   { printf '    %s\n' "$*"; }
show()   { printf '%s\n' "$1" | jq . 2>/dev/null || printf '%s\n' "$1"; }
pause() {
  if [[ "${FAST:-0}" == 1 ]] || [[ ! -t 0 ]]; then return 0; fi
  printf '\n\033[2m[ tekan Enter untuk lanjut ]\033[0m '
  read -r _ || true
}

printf '\033[1mLumen — live demo on Pharos Atlantic\033[0m\n'
note "network=$LUMEN_NETWORK  token=$TOKEN"

# 1) intent.parse (offline, no wallet)
banner '1) intent.parse — natural language -> ranked Lumen request (offline)'
pause
show "$("$SCRIPTS/intent.parse.sh" < "$REQ/intent.parse.json" 2>/dev/null || true)"

# 2) pay.once (idempotent replay by default; FRESH=1 broadcasts a new tx)
banner '2) pay.once — ERC-20 payment on Atlantic'
once_req="$(jq --arg t "$TOKEN" '.params.token = $t' "$REQ/pay.once.json")"
if [[ "${FRESH:-0}" == 1 ]]; then
  once_req="$(printf '%s' "$once_req" | jq --arg k "live-$(date -u +%Y%m%d%H%M%S)" '.idempotency_key = $k')"
  note 'FRESH=1 -> broadcasting a new tx (you may be asked for the keystore password)'
else
  note 'idempotent replay of the recorded tx (no new broadcast, no password)'
fi
pause
once_out="$(printf '%s' "$once_req" | "$SCRIPTS/pay.once.sh" 2>/dev/null || true)"
show "$once_out"
tx="$(printf '%s' "$once_out" | jq -r '.result.tx.hash // empty' 2>/dev/null || true)"
[[ -n "$tx" ]] && note "explorer: $EXPLORER/tx/$tx"

# 3) receipt.generate (decode the tx into MD + JSON + CSV)
if [[ -n "$tx" && "$tx" != unknown ]]; then
  banner '3) receipt.generate — decode tx -> Markdown + JSON + CSV'
  pause
  show "$(jq --arg h "$tx" '.params.tx_hash = $h' "$REQ/receipt.generate.json" \
    | "$SCRIPTS/receipt.generate.sh" 2>/dev/null || true)"
fi

# 4) ledger.query (replay the local append-only audit ledger)
banner '4) ledger.query — replay the append-only audit ledger'
pause
show "$("$SCRIPTS/ledger.query.sh" < "$REQ/ledger.query.json" 2>/dev/null || true)"

# Proof summary
banner 'Proof (open these in the block explorer on camera)'
note "token:    $EXPLORER/address/$TOKEN"
[[ -n "$tx" ]] && note "pay.once: $EXPLORER/tx/$tx"
printf '\n\033[1;32mDone.\033[0m Same JSON contract runs under Claude Code, Codex CLI, OpenClaw, and MCP.\n'

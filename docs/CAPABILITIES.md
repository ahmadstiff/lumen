# Lumen Capability Guide

A single-page index of every Lumen capability, its purpose, the params it
accepts, and where to read more. For the full JSON schema of each, jump to
`references/<capability>.md`.

## Universal envelope

Every capability accepts this request shape on stdin:

```json
{
  "network": "atlantic | pacific",
  "idempotency_key": "string (optional)",
  "params": { /* capability-specific */ }
}
```

And returns one of two response envelopes on stdout:

```json
// success
{"status":"ok","capability":"...","timestamp":"...","result":{...}}

// error
{"status":"error","capability":"...","timestamp":"...","error":{"code":"...","message":"...","details":...}}
```

## Capability summary

### `pay.once` (P0)

Single ERC-20 transfer with balance preflight, gas cap, and audit receipt.

- Required params: `token`, `recipient`, `amount`
- Optional: `mode` (`transfer` default; `permit2` reserved), `memo`, `max_gas_price_gwei`
- Reference: `references/pay.once.md`

### `pay.split` (P0)

Split one ERC-20 across N recipients in sequential or Multicall3-atomic mode.

- Required: `token`, `recipients[]`, and one of (`amounts[]`) or (`shares_bps[] + total`)
- Optional: `mode` (`sequential` default; `multicall` needs prior approval), `memo`
- Reference: `references/pay.split.md`

### `approval.scope` (P0)

Bounded ERC-20 / Permit2 approval with mandatory expiry.

- Required: `token`, `spender`, `amount`, `expiry_unix`
- Optional: `mode` (`direct` default; `permit2` for on-chain expiry), `memo`
- **Policy:** refuses `uint256.max`; window ≤ 365 days
- Reference: `references/approval.scope.md`

### `receipt.generate` (P0)

Decode an arbitrary transaction into Markdown + JSON + CSV receipts.

- Required: `tx_hash`
- Optional: `formats` (subset of `markdown`, `json`, `csv`), `output_dir`
- Reference: `references/receipt.generate.md`

### `invoice` (P1)

Issue, verify, or pay EIP-712 signed invoice docs. Off-chain, stateless.

- `action: issue` → params `payer`, `token`, `amount`, `due_at_unix`
- `action: verify` → params `document`
- `action: pay` → params `document`
- Reference: `references/invoice.md`

### `pay.recurring` (P1)

Subscriptions via EIP-712 pre-signed authorisation + existing allowance +
ledger-enforced period quotas.

- `action: create` → params `merchant`, `token`, `amount_per_period`, `period_seconds`, `end_at_unix` (others optional)
- `action: verify` → params `document`
- `action: charge` → params `document`
- Reference: `references/pay.recurring.md`

### `ledger.query` (P1)

Historical payment lookup with local NDJSON + on-chain Transfer logs.

- Optional: `source` (`local | chain | both`), `token`, `from`, `to`, `capability`, `since_unix`, `from_block`, `to_block`, `limit`, `formats`
- Read-only; never writes to ledger
- Reference: `references/ledger.query.md`

## Composition examples

### "Pay the contractor and produce a Markdown receipt"

```bash
# 1. Make the payment
RESULT=$(echo '{
  "network":"atlantic",
  "idempotency_key":"contract-2026-06",
  "params":{"token":"0xUSDC…","recipient":"0xCONTRACTOR…","amount":"5000000"}
}' | scripts/pay.once.sh)

TX_HASH=$(echo "$RESULT" | jq -r '.result.tx.hash')

# 2. Generate the audit receipt
echo "{
  \"network\":\"atlantic\",
  \"params\":{\"tx_hash\":\"$TX_HASH\",\"formats\":[\"markdown\",\"csv\"]}
}" | scripts/receipt.generate.sh
```

### "Settle ten Q2 invoices in one atomic batch"

```bash
# Aggregator agent collects 10 signed invoice docs into a single Multicall3 call.
# (Each invoice's amount → one transferFrom; sender = payer wallet.)

# 1. First, payer authorises Multicall3.
EXPIRY=$(( $(date -u +%s) + 86400 ))
echo "{
  \"params\":{
    \"token\":\"0xUSDC…\",
    \"spender\":\"0xcA11bde0…CA11\",
    \"amount\":\"100000000\",
    \"expiry_unix\":$EXPIRY,
    \"mode\":\"permit2\"
  }
}" | scripts/approval.scope.sh

# 2. Then run pay.split in multicall mode with the invoice recipients/amounts.
echo '{
  "params":{
    "token":"0xUSDC…",
    "mode":"multicall",
    "recipients":["0xINV1…","0xINV2…", "..."],
    "amounts":   ["1000000","2500000", "..."]
  }
}' | scripts/pay.split.sh
```

### `pay.escrow` (P2)

Stateless A2A escrow via hash-locked EIP-712 offer + bounded allowance.

- `action: create` → params `payee`, `token`, `amount`, `expiry_unix`
- `action: verify` → params `document`
- `action: claim` → params `document`, `release_key`
- `action: refund` → params `document`
- Reference: `references/pay.escrow.md`

### `pay.tip` (P2)

Agent-to-agent micropayments. Direct send or signed claim ticket.

- `action: send` → params `recipient`, `token`, `amount`, optional `sender_agent_id`/`recipient_agent_id`
- `action: issue` → params `recipient`, `token`, `amount`, optional `expiry_unix`
- `action: redeem` → params `document`
- `action: verify` → params `document`
- Reference: `references/pay.tip.md`

### `intent.parse` (P2)

Deterministic regex-based natural-language → capability request mapper.

- Required: `utterance`
- Optional: `default_token`, `default_network`
- Returns a ranked candidates list; never broadcasts a transaction
- Reference: inline docs in `scripts/intent.parse.sh`

## Distribution

The same scripts work across four runtimes — see `SKILL.md` for the
manifest. The MCP server lives under `mcp-server/`; see `docs/MCP.md` for the
wiring guide.

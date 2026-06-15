# `ledger.query` — Historical Payment Lookup

Find past payments. Two sources can be queried independently or together:

- **local** (`.lumen/ledger.ndjson`) — rich Lumen-native metadata: capability,
  memo, idempotency key, allocation breakdown for `pay.split`, etc.
- **chain** (`eth_getLogs` for ERC-20 `Transfer`) — authoritative on-chain
  state, including transfers that happened *outside* Lumen.
- **both** — union of the two, deduplicated by `(tx_hash, log_index, to, amount)`.

## When to call

- Monthly statements / accounting reports.
- Reconcile a suspect transaction with Lumen's own records.
- Find every payment to a given recipient since a given block.

## Request schema

```json
{
  "network": "atlantic | pacific",
  "params": {
    "source":      "local | chain | both (default: local)",
    "token":       "0x… (optional)",
    "from":        "0x… (optional)",
    "to":          "0x… (optional)",
    "capability":  "pay.once | pay.split | pay.recurring (optional, local only)",
    "since_unix":  0,
    "from_block":  "earliest | <number> (chain only)",
    "to_block":    "latest | <number> (chain only)",
    "limit":       200,
    "formats":     ["json", "csv", "markdown"],
    "output_dir":  "string (optional)"
  }
}
```

`formats` controls which artefacts are written to `output_dir`
(default `.lumen/queries/<timestamp>/`). The response always carries the
entries inline.

## Successful response (shape)

```json
{
  "status": "ok",
  "capability": "ledger.query",
  "result": {
    "network": "atlantic",
    "chain_id": 688689,
    "source": "both",
    "count": 7,
    "entries": [
      {
        "source": "local",
        "capability": "pay.once",
        "tx_hash": "0x…",
        "token": "0x…",
        "symbol": "USDC",
        "from": "0x…",
        "to": "0x…",
        "amount": "1000000",
        "memo": "rent",
        "idempotency_key": "pay-once-…"
      },
      {
        "source": "chain",
        "capability": "Transfer",
        "tx_hash": "0x…",
        "token": "0x…",
        "from": "0x…",
        "to": "0x…",
        "amount": "500000",
        "block_number": "0x…",
        "log_index": "0x0",
        "explorer_url": "…"
      }
    ],
    "artifacts": [
      {"path": "/.../query.json", "type": "json"}
    ]
  }
}
```

## Notes

- The local source flattens `pay.split` into one entry per allocation so a
  3-way split shows up as three rows; the `tx_hash` of the **first**
  underlying transaction is reused.
- For very large block ranges, prefer narrowing with `from_block` / `to_block`
  — public RPCs throttle wide queries.
- This capability is read-only and does **not** write to the ledger.

## Example

```bash
echo '{
  "network": "atlantic",
  "params": {
    "source": "both",
    "token":  "0xUSDC…",
    "from":   "0xALICE…",
    "limit":  50,
    "formats": ["json", "markdown"]
  }
}' | scripts/ledger.query.sh
```

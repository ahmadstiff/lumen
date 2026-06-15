# `receipt.generate` — Decode a Transaction into a Composable Receipt

Read any transaction hash on Pharos, decode ERC-20 Transfer / Approval events,
and emit three artefacts other skills (or humans) can consume:

- `receipt.md` — human-readable Markdown audit page
- `receipt.json` — full structured payload (the *Composable Receipts* contract)
- `receipt.csv` — one row per decoded event for spreadsheet / BI ingest

## When to call

- Audit a payment that ran outside Lumen (e.g. user paid via a wallet UI).
- Cross-check a `pay.once`, `pay.split`, or `pay.recurring` tx with a fresh log scan.
- Build a monthly statement by running this over a set of hashes.

## Request schema

```json
{
  "network": "atlantic | pacific",
  "params": {
    "tx_hash": "0x… (64-hex, required)",
    "formats": ["markdown", "json", "csv"],
    "output_dir": "string (optional; default .lumen/receipts/<tx>/)"
  }
}
```

`formats` may include any subset of `markdown`, `json`, `csv`. Default = all three.

## Successful response (shape)

```json
{
  "status": "ok",
  "capability": "receipt.generate",
  "result": {
    "capability": "receipt.generate",
    "network": "atlantic",
    "chain_id": 688689,
    "tx": {
      "hash": "0x…",
      "from": "0x…",
      "block_number": "0x…",
      "gas_used": "0x…",
      "ok": true,
      "explorer_url": "…"
    },
    "events": [
      {
        "kind": "Transfer",
        "token": "0x…",
        "symbol": "USDC",
        "decimals": 6,
        "from": "0x…",
        "to": "0x…",
        "amount": "1000000",
        "amount_hex": "0x0…0f4240",
        "log_index": "0x0"
      }
    ],
    "artifacts": [
      {"path": "/.../receipt.md", "type": "md"},
      {"path": "/.../receipt.json", "type": "json"},
      {"path": "/.../receipt.csv", "type": "csv"}
    ]
  }
}
```

## Error codes

| `error.code` | Meaning |
|---|---|
| `missing_param` | `tx_hash` absent |
| `invalid_tx_hash` | Format check failed (must be 0x + 64 hex) |
| `receipt_fetch_failed` | RPC returned an error or unknown tx |

## Example

```bash
echo '{
  "network": "atlantic",
  "params": {
    "tx_hash": "0xabc…",
    "formats": ["markdown", "json"]
  }
}' | scripts/receipt.generate.sh
```

## Notes

- Token symbol and decimals are read on-chain for every distinct token in the
  log set; this keeps cross-token receipts accurate.
- The script never re-orders events: log_index is preserved verbatim so
  reconciliation against block explorers is straightforward.
- An audit entry is also appended to `.lumen/ledger.ndjson` with
  `idempotency_key: "receipt-<tx_hash>"`, making `receipt.generate` itself
  replay-safe.

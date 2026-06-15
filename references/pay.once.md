# `pay.once` — Single ERC-20 Payment

Send a one-off ERC-20 transfer from the configured Lumen wallet to one recipient, with
balance preflight, optional gas cap, idempotency, and a structured audit receipt.

## When to call

- A user or upstream agent requests a single fund transfer.
- The sender already holds the tokens (no allowance/Permit2 needed).
- The payment must be **at most once** — supply an `idempotency_key`.

For multi-recipient atomic splits, call `pay.split` instead.

## Request schema

```json
{
  "network": "atlantic | pacific",
  "idempotency_key": "string (optional, recommended)",
  "params": {
    "token": "0x… (ERC-20 contract, required)",
    "recipient": "0x… (required)",
    "amount": "string of decimal integer in base units, required",
    "mode": "transfer | permit2 (default: transfer)",
    "memo": "string (optional, ≤ 256 chars)",
    "max_gas_price_gwei": "string of integer (optional)"
  }
}
```

### Parameters

| Field | Type | Required | Notes |
|---|---|---|---|
| `network` | string | no | Overrides `LUMEN_NETWORK`. One of `atlantic` (testnet) or `pacific` (mainnet). |
| `idempotency_key` | string | no | If supplied and previously used, returns the cached receipt with `replayed: true`. |
| `params.token` | address | yes | ERC-20 contract address. Must be 0x-prefixed 40-hex. |
| `params.recipient` | address | yes | Destination wallet. Same format constraint. |
| `params.amount` | string | yes | Decimal integer in **base units** (e.g. `1000000` for 1 USDC at 6 decimals). |
| `params.mode` | string | no | `transfer` (direct ERC-20 transfer). `permit2` is reserved for `pay.split`; returns `not_implemented` here. |
| `params.memo` | string | no | Free-text annotation captured in the receipt and ledger. |
| `params.max_gas_price_gwei` | string | no | Hard cap on gas price. Capability refuses to broadcast if network gas exceeds it. |

## Successful response

```json
{
  "status": "ok",
  "capability": "pay.once",
  "timestamp": "2026-06-15T02:31:16Z",
  "result": {
    "capability": "pay.once",
    "network": "atlantic",
    "chain_id": 688689,
    "rpc_url": "https://atlantic.dplabs-internal.com",
    "mode": "transfer",
    "sender": "0xabc…",
    "token": {"address": "0xUSDC…", "symbol": "USDC", "decimals": 6},
    "recipient": "0xdef…",
    "amount": "1000000",
    "memo": null,
    "tx": {
      "hash": "0xhash…",
      "block_number": "0x1abc",
      "gas_used": "0x6acc",
      "ok": true,
      "explorer_url": "https://atlantic.pharosscan.xyz/tx/0xhash…"
    },
    "idempotency_key": "pay-once-20260615T023116Z-ab12cd34"
  }
}
```

## Error codes

| `error.code` | Meaning | Recovery |
|---|---|---|
| `missing_params` / `missing_param` | Required field absent | Add the field |
| `validation_error` | Address / amount shape invalid | Fix and retry |
| `invalid_mode` | Unknown `mode` value | Use `transfer` |
| `policy_violation` | Mainnet sender used raw private key | Switch to keystore / cast account |
| `sender_resolution_failed` | Wallet config could not derive an address | Check `LUMEN_KEYSTORE`/`LUMEN_ACCOUNT` |
| `insufficient_balance` | Sender does not hold `amount` of token | Top up or reduce |
| `not_implemented` | `mode=permit2` requested | Use `transfer` here; use `pay.split` for Permit2-style flows |
| `tx_send_failed` | RPC rejected the broadcast | Inspect `details.cast_output` |
| `internal_error` | Unexpected non-zero from script | File issue; check stderr log |

## Examples

### Send 1 USDC on Atlantic

```bash
echo '{
  "network": "atlantic",
  "idempotency_key": "rent-2026-06",
  "params": {
    "token": "0xA0b86991C6218B36c1d19D4a2e9Eb0cE3606eB48",
    "recipient": "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
    "amount": "1000000",
    "memo": "June rent payment"
  }
}' | scripts/pay.once.sh
```

### Replay an idempotent payment

If the same `idempotency_key` is reused, no transaction is broadcast — the cached
receipt is returned with `result.replayed: true`.

## Implementation notes

- The script never reads private keys directly. It delegates wallet operations to
  `cast`, honouring `LUMEN_KEYSTORE`, `LUMEN_ACCOUNT`, or `LUMEN_PRIVATE_KEY` (testnet
  only).
- The append-only ledger lives at `.lumen/ledger.ndjson`; one JSON line per receipt.
- Decimals and symbol are read on-chain at call time to avoid stale metadata.
- Status is normalized to a boolean (`tx.ok`) so agents don't need to interpret
  `0x1`/`0x0`.

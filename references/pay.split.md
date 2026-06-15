# `pay.split` — Multi-Recipient ERC-20 Split

Split one ERC-20 amount across N recipients in either independent transfers
(default) or a single atomic Multicall3 batch.

## When to call

- Pay-out revenue to multiple wallets in one logical operation.
- Distribute fees, royalties, or referral commissions.
- Settle a pooled invoice paid by several payers.

## Modes

| Mode | Atomicity | Prior setup | Tx count |
|---|---|---|---|
| `sequential` (default) | No (each tx independent) | None | N |
| `multicall` | Yes (all-or-nothing) | Sender must approve Multicall3 on the token (see `approval.scope`) | 1 |

Choose `multicall` when partial settlements would corrupt downstream state (e.g.
royalty splits that an external indexer treats as a single event). Choose
`sequential` when you want maximum forward progress under intermittent failures.

## Allocation strategies

Provide exactly **one** of the two:

### `amounts[]` — explicit per-recipient amounts

```json
"params": {
  "recipients": ["0xa…", "0xb…", "0xc…"],
  "amounts":    ["100",  "200",  "150"]
}
```

`total` is computed by the script as `sum(amounts)`.

### `shares_bps[] + total` — basis-point shares

```json
"params": {
  "recipients": ["0xa…", "0xb…", "0xc…"],
  "shares_bps": [3333, 3333, 3334],
  "total":      "1000000"
}
```

Sum of `shares_bps` **must** equal `10000`. Per-recipient amount is
`floor(total * share / 10000)`; the **last** recipient absorbs the rounding
remainder so the payout sum equals `total` exactly.

## Request schema

```json
{
  "network": "atlantic | pacific",
  "idempotency_key": "string (optional)",
  "params": {
    "token": "0x… (required)",
    "mode": "sequential | multicall (default: sequential)",
    "recipients": ["0x…", ...],
    "amounts": ["string", ...],
    "shares_bps": [int, ...],
    "total": "string (required if shares_bps given)",
    "memo": "string (optional)"
  }
}
```

## Successful response (shape)

```json
{
  "status": "ok",
  "capability": "pay.split",
  "timestamp": "…",
  "result": {
    "capability": "pay.split",
    "mode": "sequential",
    "network": "atlantic",
    "chain_id": 688689,
    "sender": "0x…",
    "token": {"address": "0x…", "symbol": "USDC", "decimals": 6},
    "total": "1000000",
    "allocations": [
      {"recipient": "0xa…", "amount": "333333"},
      {"recipient": "0xb…", "amount": "333333"},
      {"recipient": "0xc…", "amount": "333334"}
    ],
    "txs": [
      {"hash": "0x…", "block_number": "0x…", "gas_used": "0x…", "explorer_url": "…"}
    ],
    "memo": null,
    "idempotency_key": "pay-split-…"
  }
}
```

In `multicall` mode the `txs` array contains a single entry. In `sequential`
mode it contains one per recipient.

## Error codes

| `error.code` | Trigger |
|---|---|
| `missing_param` / `missing_allocation` / `missing_total` | Required field absent |
| `conflicting_allocation` | Both `amounts` and `shares_bps` supplied |
| `length_mismatch` | `recipients` / `amounts` / `shares_bps` lengths differ |
| `empty_recipients` | `recipients` is empty |
| `invalid_bps` | Any share > 10000 |
| `shares_sum_mismatch` | `shares_bps` does not sum to 10000 |
| `insufficient_balance` | Sender balance < total |
| `insufficient_allowance` | (multicall mode) Multicall3 allowance < total |
| `tx_send_failed` | Broadcast failed; details carry `cast` output |
| `policy_violation` | Raw private key on mainnet |

## Examples

### 3-way bps split

```bash
echo '{
  "network": "atlantic",
  "idempotency_key": "royalty-2026-06",
  "params": {
    "token": "0xUSDC…",
    "recipients": ["0xartist…", "0xlabel…", "0xdao…"],
    "shares_bps": [6000, 3000, 1000],
    "total": "1000000",
    "memo": "June royalty distribution"
  }
}' | scripts/pay.split.sh
```

### Atomic settle via Multicall3

```bash
echo '{
  "params": {
    "token": "0xUSDC…",
    "mode": "multicall",
    "recipients": ["0xa…", "0xb…"],
    "amounts": ["500000", "500000"]
  }
}' | scripts/pay.split.sh
```

Requires the sender to have run `approval.scope` for Multicall3 ≥ 1,000,000 first.

## Notes

- All arithmetic uses `bc` for arbitrary precision; safe for 18-decimal token wei.
- The append-only ledger records the full allocation table — useful for
  `ledger.query` audits later.
- Sequential mode is safe to retry on partial failure: agents can replay with
  a new `idempotency_key` and the script only re-broadcasts unsent legs (TBD
  in P1 follow-up).

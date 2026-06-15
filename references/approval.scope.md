# `approval.scope` — Bounded ERC-20 Approval

Grant a strictly bounded ERC-20 allowance to a spender. Unlimited approvals
(`uint256.max`) are **refused**.

## When to call

- Authorise Multicall3 to pull tokens for an atomic `pay.split` batch.
- Authorise a recurring-payment relayer for a fixed monthly budget.
- Authorise an A2A escrow contract for a single deal.

If you need a *one-shot* signature with no on-chain state change, use the
EIP-2612 permit path from `pay.recurring` instead.

## Policy

This capability enforces three non-negotiable rules so the skill stays
"CertiK Skill Scanner clean":

1. `amount` is **mandatory**. `uint256.max` is rejected.
2. `expiry_unix` is **mandatory** and must be a future Unix timestamp.
3. The expiry window can be at most **365 days**. Longer windows must be
   re-authorised explicitly.

## Modes

| Mode | Target contract | Expiry enforced | When to use |
|---|---|---|---|
| `direct` (default) | The ERC-20 token | Logical only (recorded in receipt) | Spender is a contract that does **not** integrate Permit2 |
| `permit2` | The canonical Permit2 (0x000…22D473…BA3) | On-chain (`uint48 expiration`) | Spender is Permit2-aware (Multicall3 workflows, Lumen escrow, etc.) |

## Request schema

```json
{
  "network": "atlantic | pacific",
  "idempotency_key": "string (optional)",
  "params": {
    "token": "0x… (required)",
    "spender": "0x… (required)",
    "amount": "decimal string (required, ≠ uint256.max)",
    "expiry_unix": 1750000000,
    "mode": "direct | permit2 (default: direct)",
    "memo": "string (optional)"
  }
}
```

## Successful response (shape)

```json
{
  "status": "ok",
  "capability": "approval.scope",
  "result": {
    "capability": "approval.scope",
    "mode": "permit2",
    "network": "atlantic",
    "chain_id": 688689,
    "sender": "0x…",
    "target_contract": "0x000000000022D473030F116dDEE9F6B43aC78BA3",
    "token": {"address": "0x…", "symbol": "USDC", "decimals": 6},
    "spender": "0xcA11bde05977b3631167028862bE2a173976CA11",
    "amount": "5000000",
    "expiry_unix": 1750000000,
    "expiry_iso": "2025-06-15T12:26:40Z",
    "memo": "Multicall3 budget for June royalty payouts",
    "tx": { "...": "..." },
    "idempotency_key": "approval-scope-…"
  }
}
```

## Error codes

| `error.code` | Meaning |
|---|---|
| `missing_param` | `token`, `spender`, `amount`, or `expiry_unix` absent |
| `validation_error` | Address / uint format wrong |
| `invalid_mode` | `mode` not in `{direct, permit2}` |
| `policy_unlimited_approval` | `amount == uint256.max` |
| `expiry_in_past` | `expiry_unix <= now` |
| `expiry_too_long` | Window > 365 days |
| `policy_violation` | Raw private key on mainnet |
| `tx_send_failed` | Approval broadcast failed |

## Example: budget Multicall3 for a 24-hour window

```bash
EXPIRY=$(( $(date -u +%s) + 86400 ))
echo "{
  \"network\": \"atlantic\",
  \"params\": {
    \"token\": \"0xUSDC…\",
    \"spender\": \"0xcA11bde05977b3631167028862bE2a173976CA11\",
    \"amount\": \"5000000\",
    \"expiry_unix\": $EXPIRY,
    \"mode\": \"permit2\",
    \"memo\": \"24h budget for royalty splits\"
  }
}" | scripts/approval.scope.sh
```

## Notes

- The script records both `expiry_unix` and human-readable `expiry_iso` so
  ledger consumers can sort and audit easily.
- `direct` mode keeps the standard ERC-20 allowance pattern; revoke by setting
  `amount: "0"` for the same `spender` and a new short expiry.
- `permit2` mode uses Permit2's first-class `approve` (not the signature-based
  `permit`), giving on-chain expiry without a separate signing step.

# `invoice` — Agent-to-Agent Invoicing via EIP-712

Issue, verify, or pay invoice documents that live entirely off-chain. The
verifying digest is identical to `LumenLib.invoiceDigest()` on-chain, so the
same signature can later be redeemed by a Permit2-style settlement contract
without re-signing.

## Why off-chain?

Lumen's stateless pillar requires zero custom contract deployments. Invoices
are JSON documents signed via EIP-712. Storage is the agent's choice (file,
IPFS, A2A message). Settlement is just `pay.once` — the recipient is read from
the signed `issuer` field, so the payer cannot redirect funds.

## Actions

| Action | Description | Required params |
|---|---|---|
| `issue` | Build + sign an Invoice doc | `payer`, `token`, `amount`, `due_at_unix` (optional `invoice_id`, `memo`) |
| `verify` | Recover and check signature | `document` |
| `pay` | Verify, then settle via `pay.once` | `document` |

## Request schema

```json
{
  "network": "atlantic | pacific",
  "params": {
    "action": "issue | verify | pay",

    "payer": "0x… (issue)",
    "token": "0x… (issue)",
    "amount": "string (issue)",
    "due_at_unix": 1750000000,
    "memo": "string (optional)",
    "invoice_id": "0x… 64-hex (optional; auto-generated if absent)",

    "document": { /* full Invoice doc with .signature (verify, pay) */ }
  }
}
```

## Document shape (returned by `issue`, consumed by `verify` / `pay`)

```json
{
  "invoiceId": "0x… (bytes32)",
  "issuer":    "0x…",
  "payer":     "0x…",
  "token":     "0x…",
  "amount":    "1000000",
  "dueAt":     1750000000,
  "memo":      "Consulting Q2 invoice",
  "chainId":   688689,
  "signature": "0x… (65 bytes)"
}
```

The signature covers an EIP-712 typed-data struct named `Invoice` with the
domain `{name:"Lumen", version:"1", chainId:<...>}` — matching
`contracts/src/LumenLib.sol`.

## Successful response (issue)

```json
{
  "status": "ok",
  "capability": "invoice",
  "result": {
    "action": "issue",
    "document": { /* shape above */ }
  }
}
```

## Successful response (verify)

```json
{
  "status": "ok",
  "result": {
    "action": "verify",
    "verified": true,
    "issuer": "0x…",
    "invoice_id": "0x…"
  }
}
```

## Successful response (pay)

```json
{
  "status": "ok",
  "result": {
    "action": "pay",
    "invoice": { /* doc */ },
    "payment": { /* full pay.once receipt */ }
  }
}
```

## Error codes

| `error.code` | Trigger |
|---|---|
| `missing_param` | Required field absent |
| `invalid_action` | `action` not in `{issue, verify, pay}` |
| `invalid_invoice_id` | Bad bytes32 shape |
| `hash_failed` | `cast hash-typed-data` failed |
| `sign_failed` | Wallet signing failed |
| `missing_signature` | `document.signature` absent for verify/pay |
| `signature_mismatch` | Recovered signer ≠ `document.issuer` |
| `wrong_payer` | Configured wallet ≠ `document.payer` (pay only) |
| `payment_failed` | Underlying `pay.once` call failed |

## Example: issue then pay (across two agents)

```bash
# Issuer agent
INVOICE_DOC=$(echo '{
  "network": "atlantic",
  "params": {
    "action": "issue",
    "payer":  "0xPAYER…",
    "token":  "0xUSDC…",
    "amount": "1000000",
    "due_at_unix": '"$(($(date +%s) + 86400))"',
    "memo":   "Consulting Q2"
  }
}' | scripts/invoice.sh | jq '.result.document')

# Payer agent (must hold LUMEN_KEYSTORE for 0xPAYER…)
echo "{
  \"network\": \"atlantic\",
  \"params\": {
    \"action\": \"pay\",
    \"document\": $INVOICE_DOC
  }
}" | scripts/invoice.sh
```

## Notes

- Past-due invoices are paid with a warning logged to stderr; replay protection
  comes from the `invoice-pay-<invoiceId>` idempotency key, so paying twice
  returns the cached receipt instead of a second transaction.
- `verify` is purely off-chain — no RPC call is made.
- Future P2 capabilities (`pay.escrow`, `pay.tip`) reuse the same EIP-712
  domain so credentials accepted here also work for those flows.

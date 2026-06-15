# `pay.tip` — Agent-to-Agent Micropayments

Lumen's A2A tipping primitive. Two flavours:

1. **Direct send** — pay one agent immediately, with the receipt tagged by
   sender / recipient agent identifiers so other skills can index "tip
   payments" separately from generic transfers.
2. **Claim ticket** — sign an EIP-712 ticket that the recipient (or anyone
   holding it) can redeem later via an existing allowance. Useful for public
   bounties or async A2A flows.

## Why a separate capability from `pay.once`?

- Distinct receipt schema (`sender_agent_id`, `recipient_agent_id`) so a
  downstream "agent earnings" report can filter to tips only.
- Built-in cap (1e22 base units) to fail loudly on accidentally-huge tips.
- The ticket mode is unique — there is no equivalent in `pay.once`.

## Actions

| Action | Caller | Effect |
|---|---|---|
| `send` (default) | Sender | Direct ERC-20 transfer with agent metadata |
| `issue` | Sender | Sign a TipClaim ticket (no transaction) |
| `verify` | Anyone | Off-chain signature recovery |
| `redeem` | Recipient | Verify ticket + execute `transferFrom` from sender's allowance |

## Request schema

```json
{
  "network": "atlantic | pacific",
  "idempotency_key": "string (optional)",
  "params": {
    "action": "send | issue | redeem | verify",

    "recipient":          "0x… (send, issue)",
    "token":              "0x… (send, issue)",
    "amount":             "string (send, issue)",
    "memo":               "string (optional)",

    "sender_agent_id":    "string (send, optional)",
    "recipient_agent_id": "string (send, optional)",

    "expiry_unix":        1750000000,
    "ticket_id":          "0x… 64-hex (issue, optional)",

    "document":           { /* signed TipClaim (verify, redeem) */ }
  }
}
```

## Successful `send` response

```json
{
  "status": "ok",
  "capability": "pay.tip",
  "result": {
    "action": "send",
    "sender_agent_id": "agent-alice",
    "recipient_agent_id": "agent-bob",
    "payment": { /* full pay.once result */ }
  }
}
```

## Successful `issue` response (ticket)

```json
{
  "status": "ok",
  "result": {
    "action": "issue",
    "document": {
      "ticketId": "0x…",
      "sender": "0x…", "recipient": "0x…",
      "token": "0x…", "amount": "1000",
      "expiry": 1750000000, "memo": "thanks",
      "chainId": 688689, "signature": "0x…"
    }
  }
}
```

## Error codes

| `error.code` | Trigger |
|---|---|
| `missing_param` / `invalid_action` | Bad request |
| `tip_amount_too_large` | `amount` > 1e22 base units |
| `expiry_in_past` | Ticket expiry already passed |
| `invalid_ticket_id` | Bad bytes32 shape |
| `hash_failed` / `sign_failed` | Wallet error |
| `signature_mismatch` | Recovered signer ≠ `document.sender` |
| `ticket_expired` | `redeem` after `expiry` |
| `wrong_recipient` | Caller wallet ≠ `document.recipient` |
| `insufficient_allowance` | Sender's allowance to recipient < amount |
| `tx_send_failed` | `transferFrom` broadcast failed |
| `payment_failed` | Underlying `pay.once` call failed |

## Example: direct tip

```bash
echo '{
  "params":{
    "action":"send",
    "recipient":"0xBOB…",
    "token":"0xUSDC…",
    "amount":"5000",
    "sender_agent_id":"agent-alice",
    "recipient_agent_id":"agent-bob",
    "memo":"thanks for the answer"
  }
}' | scripts/pay.tip.sh
```

## Example: anonymous bounty (issue + later redeem)

```bash
# Sender (alice) signs a 5000-USDC ticket for bob, valid 7 days
TICKET=$(echo '{
  "params":{
    "action":"issue",
    "recipient":"0xBOB…",
    "token":"0xUSDC…",
    "amount":"5000",
    "memo":"bug bounty: CVE-2026-FOO"
  }
}' | scripts/pay.tip.sh | jq '.result.document')

# Alice also approves bob to pull the funds.
echo "{
  \"params\":{\"token\":\"0xUSDC…\",\"spender\":\"0xBOB…\",
    \"amount\":\"5000\",\"expiry_unix\":$(($(date +%s)+604800))}
}" | scripts/approval.scope.sh

# Later — bob redeems
echo "{
  \"params\":{\"action\":\"redeem\",\"document\":$TICKET}
}" | scripts/pay.tip.sh
```

## Notes

- The 1e22 base-unit cap is conservative; agents needing larger transfers
  should route through `pay.once` (logged differently) or `pay.split`.
- A redeemed ticket is recorded with the idempotency key
  `tip-redeem-<ticketId>`, so the same ticket cannot be redeemed twice.
- `sender_agent_id` / `recipient_agent_id` are free-form strings — they're
  the hook for an "agent identity" sidecar skill to map them to keys / DIDs
  later.

---
name: lumen
version: 0.1.0
display_name: Lumen — Agent-Native Payments on Pharos
description: >
  The light that moves money on Pharos. Lumen is a stateless, agent-native
  payment skill that lets AI agents pay, split, invoice, and subscribe on
  Pharos Atlantic and Pacific networks without deploying custom contracts.
  Use when an agent must send a one-off payment, split revenue across many
  wallets, set a scoped approval, generate an audit-grade receipt, issue or
  pay an invoice, schedule recurring charges, or query historical ledgers.
license: MIT
authors:
  - Lumen Skill Authors
networks:
  - pharos-atlantic (688689)
  - pharos-pacific (1672)
runtime:
  shell: bash
  tools: [foundry, cast, jq]
distribution: [claude-code, codex, openclaw, mcp]
---

# Lumen — Agent-Native Payments on Pharos

> *"The light that moves money on Pharos."*

Lumen is a payment skill designed **for AI agents, not humans**. Every capability accepts
structured JSON, returns structured JSON, and writes append-only receipts other skills can
read. There is **no custom contract to deploy**: Lumen composes Permit2, Multicall3, and
EIP-712 pre-signed authorizations.

## When to use this skill

Trigger Lumen whenever the agent must do **any** of the following on Pharos:

- send a single ERC-20 payment with a bounded gas/slippage envelope (`pay.once`)
- split a token across many recipients in **one** transaction (`pay.split`)
- grant a strictly scoped approval (token + spender + amount + expiry) (`approval.scope`)
- materialize a Markdown + JSON + CSV audit receipt from a tx hash (`receipt.generate`)
- issue or pay an EIP-712-signed invoice (`invoice`)
- create or charge a pre-signed recurring authorization (no contract) (`pay.recurring`)
- list historical payments by token / sender / recipient (`ledger.query`)

Do **not** use Lumen for:

- private-key custody (Lumen never reads private keys directly; use `cast wallet` / keystore)
- bridging or swaps (use a swap skill)
- governance voting or NFT minting

## Capability index

Each capability is a standalone bash script under `scripts/`. Detailed parameter and
example documentation lives under `references/`.

| Capability         | Tier | Script                          | Reference                              |
|--------------------|------|---------------------------------|----------------------------------------|
| pay.once           | P0   | `scripts/pay.once.sh`           | `references/pay.once.md`               |
| pay.split          | P0   | `scripts/pay.split.sh`          | `references/pay.split.md`              |
| approval.scope     | P0   | `scripts/approval.scope.sh`     | `references/approval.scope.md`         |
| receipt.generate   | P0   | `scripts/receipt.generate.sh`   | `references/receipt.generate.md`       |
| invoice            | P1   | `scripts/invoice.sh`            | `references/invoice.md`                |
| pay.recurring      | P1   | `scripts/pay.recurring.sh`      | `references/pay.recurring.md`          |
| ledger.query       | P1   | `scripts/ledger.query.sh`       | `references/ledger.query.md`           |
| pay.escrow         | P2   | `scripts/pay.escrow.sh`         | `references/pay.escrow.md`             |
| pay.tip            | P2   | `scripts/pay.tip.sh`            | `references/pay.tip.md`                |
| intent.parse       | P2   | `scripts/intent.parse.sh`       | *(inline docs in script)*              |

## Universal I/O contract

Every capability follows the same envelope so agents can compose them without parsing
hacks.

### Request envelope (stdin)

```json
{
  "network": "atlantic",
  "idempotency_key": "agent-2026-06-15-abc",
  "params": { /* capability-specific */ }
}
```

- `network` (optional) overrides the `LUMEN_NETWORK` env var.
- `idempotency_key` (optional) is recommended for any mutation. If the key already
  appears in `.lumen/ledger.ndjson`, the prior receipt is returned and no new
  transaction is sent.
- `params` is required and validated per-capability.

### Success envelope (stdout)

```json
{
  "status": "ok",
  "capability": "pay.once",
  "timestamp": "2026-06-15T02:13:55Z",
  "result": { /* capability-specific */ }
}
```

### Error envelope (stdout, exit non-zero)

```json
{
  "status": "error",
  "capability": "pay.once",
  "timestamp": "2026-06-15T02:13:55Z",
  "error": {
    "code": "insufficient_balance",
    "message": "sender balance 100 < amount 200",
    "details": {}
  }
}
```

Error codes are **machine-readable**: agents should branch on `error.code`, not on
the human-readable `message`.

## Security & autonomy posture

Lumen is built to pass the **CertiK Skill Scanner** with zero findings:

- **No shell exec of untrusted input.** All user data flows through `jq` parsers and
  bash variables; no `eval`, no `bash -c "$INPUT"`.
- **No unlimited approvals.** `approval.scope` always requires both `amount` and
  `expiry`; agents that bypass and request `max uint256` get a hard refusal.
- **No arbitrary network calls.** Only the RPC URL listed in `assets/networks.json`
  or explicit `LUMEN_RPC_URL` is contacted.
- **No private key handling.** Lumen reads only `LUMEN_KEYSTORE`, `LUMEN_ACCOUNT`,
  or (testnet-only) `LUMEN_PRIVATE_KEY`. Capabilities refuse to send mainnet txs
  with a raw private key.
- **Append-only ledger.** Receipts are written to `.lumen/ledger.ndjson` and never
  rewritten; replays use the existing record.

See `docs/SECURITY.md` for the full threat model.

## Distribution targets

Lumen targets four agent runtimes from the same source tree:

1. **Claude Code** — drop the repo into `.claude/skills/lumen/` or symlink.
2. **Codex CLI** — same layout works because capabilities are plain bash scripts.
3. **OpenClaw** — `SKILL.md` frontmatter is OpenClaw-compatible.
4. **MCP server** — `mcp-server/` ships a TypeScript/Node MCP server that exposes every capability as an MCP tool with the same name. See `docs/MCP.md` and `mcp-server/README.md`.

## Quick start

```bash
# 1. Configure
cp .env.example .env && $EDITOR .env   # pick network, sender method
forge install --root contracts        # one-time foundry deps
forge test --root contracts            # gate: 17 tests must pass

# 2. Use a capability
echo '{
  "network": "atlantic",
  "idempotency_key": "demo-001",
  "params": {
    "token": "0x…USDC…",
    "recipient": "0x…",
    "amount": "1000000"
  }
}' | scripts/pay.once.sh
```

The script emits the receipt JSON on stdout and a human-readable log on stderr.

# Lumen — Demo Video Script (2–4 min)

A ready-to-record shot list for the Pharos Phase 1 submission. Target length
**3 minutes**. Each scene lists the spoken **VO** (voice-over) and the
**Screen** action. Keep terminals at a large font; pre-stage the `.env` and a
funded Atlantic testnet wallet before recording.

## Pre-flight checklist

- Repo cloned; `forge test --root contracts` already green (so the run is fast).
- `.env` configured with `LUMEN_ACCOUNT` (cast-managed) and Atlantic gas funded.
- A throwaway ERC-20 deployed on Atlantic; export `LUMEN_DEMO_TOKEN=0x...`.
- Claude Desktop open with the Lumen MCP server registered (see `docs/MCP.md`).
- Block explorer tab open at `https://atlantic.pharosscan.xyz`.

## 0:00–0:20 — The problem

- **VO:** "AI agents can reason, plan, and call tools — but the moment they need
  to move money, they fall back to human wallets and bespoke Web3 glue. There's
  no payment layer built *for agents*."
- **Screen:** Title card with the Lumen banner (`assets/lumen-banner.svg`), then
  cut to a clean terminal in the repo root.

## 0:20–0:40 — What Lumen is, and the six moats

- **VO:** "Lumen is a payment *skill* for Pharos. Agent-native JSON in and out,
  stateless — zero custom contracts, just Permit2, Multicall3, and EIP-712 —
  composable receipts, a security-first policy layer, agent-to-agent primitives,
  and one source tree shipping four runtimes."
- **Screen:** Scroll the README "six moats" table, then the capability table.

## 0:40–1:10 — Natural language to a structured request (offline)

- **VO:** "Start with intent. This is deterministic — no LLM, no wallet — so the
  agent stays in control. I ask Lumen to send ten USDC, and it returns a ranked
  capability request."
- **Screen:** Run the offline demo entry point:

```bash
examples/demo-flow.sh
```

- **Screen:** Highlight the `intent.parse` output — `best_match: pay.once`,
  confidence 85, and the fully-formed `params`.

## 1:10–1:50 — Execute a real payment on Atlantic

- **VO:** "Now go live. Same JSON contract, but this time Lumen broadcasts a
  real ERC-20 transfer on the Pharos Atlantic testnet and returns a receipt with
  the transaction hash and an explorer link."
- **Screen:** Run the live flow:

```bash
LUMEN_DEMO_TOKEN=0xYourTestToken LUMEN_ACCOUNT=lumen-sender examples/demo-flow.sh
```

- **Screen:** Copy the `tx.hash` from the `pay.once` receipt, paste it into the
  open explorer tab, and show the confirmed transaction.

## 1:50–2:20 — Atomic split + composable receipt

- **VO:** "Splitting revenue is one atomic Multicall3 transaction — all
  recipients paid, or none. And every call emits a composable receipt as
  Markdown, JSON, and CSV that any downstream skill can consume."
- **Screen:** Show the `pay.split` request (60/30/10), then `receipt.generate`
  output and the files written under `.lumen/receipts/<tx>/`.

## 2:20–2:50 — Agent calls Lumen through MCP

- **VO:** "Because Lumen ships as an MCP server, a real agent drives it the same
  way. Here's Claude Desktop calling the Lumen `pay.once` tool directly — the
  agent decides, Lumen executes safely."
- **Screen:** In Claude Desktop, prompt the agent to pay; show the MCP tool call
  and the returned receipt.

## 2:50–3:10 — Why it holds up: stateless + audit ledger

- **VO:** "No custom contract means nothing to upgrade, pause, or audit. Every
  action is idempotent and appended to a local ledger, so replays never double
  spend and reconciliation is one query away."
- **Screen:** Re-run the same `idempotency_key` to show `replayed: true`, then
  run `ledger.query` to show the audit trail.

## 3:10–3:30 — Call to action

- **VO:** "Lumen — the light that moves money on Pharos. The payment primitive
  layer your Phase 2 agents can build on today."
- **Screen:** End card: GitHub URL `github.com/ahmadstiff/lumen`, the four
  runtime names, and the `24/24 tests` badge.

## Capture notes

- Record terminal and browser separately if possible; zoom the JSON receipts.
- Keep total runtime under 4:00; trim dead air during `cast send` confirmation.
- Paste the real tx hashes into `docs/HACKATHON.md` section 5 after recording.

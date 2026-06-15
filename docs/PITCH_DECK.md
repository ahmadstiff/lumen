# Lumen — Pitch Deck Script

A slide-by-slide script for a ~3–4 minute pitch deck that supports the demo
video. Each slide lists **On-slide** (what to put on the slide) and **Say**
(speaker notes). Target 10 slides. Pair this with the live run in
[`../examples/record-demo.sh`](../examples/record-demo.sh) and the shot list in
[`DEMO_SCRIPT.md`](./DEMO_SCRIPT.md).

Suggested tooling: any deck tool (Keynote / Google Slides / PowerPoint). Use the
banner `../assets/lumen-banner.svg` on the title slide and keep one idea per
slide.

## Slide 1 — Title

- **On-slide:** Lumen logo/banner; "Lumen — Agent-Native Payments on Pharos";
  tagline "The light that moves money on Pharos."; your name + Pharos Phase 1.
- **Say:** "Lumen is a payment skill that lets AI agents move money on Pharos —
  with structured JSON, composable receipts, and zero custom contracts."

## Slide 2 — The problem

- **On-slide:** "Agents can reason and call tools — but can't pay natively."
  Three pain points: bespoke Web3 glue, human-wallet assumptions, no audit trail.
- **Say:** "Every 'AI payments' demo bolts an agent onto a Web3 SDK. There's no
  payment layer designed for agents: deterministic, auditable, no human in the
  loop."

## Slide 3 — The solution

- **On-slide:** "Lumen = a payment *skill*, not an app." JSON in / JSON out;
  one source tree → 4 runtimes (Claude Code, Codex CLI, OpenClaw, MCP).
- **Say:** "Lumen exposes 10 composable payment capabilities behind a uniform
  JSON envelope, shipping as four agent runtimes from a single codebase."

## Slide 4 — The six moats

- **On-slide:** 1) Agent-native by design, 2) Stateless (zero custom contracts),
  3) Composable receipts, 4) Skill-Scanner-first security, 5) Agent-to-agent
  primitives, 6) Multi-framework distribution.
- **Say:** "Six things that are hard to copy: it's built for agents, it deploys
  no contracts, every call emits a composable receipt, security policy is
  first-class, it ships A2A primitives, and it runs across four runtimes."

## Slide 5 — How it works

- **On-slide:** Simple diagram: Agent → Lumen (JSON) → Pharos
  (ERC-20 + Permit2 + Multicall3 + EIP-712) → append-only ledger. Caption:
  "No custom contracts. Nothing to upgrade, pause, or audit."
- **Say:** "Lumen composes only canonical contracts. State lives in a local
  append-only ledger, so every action is idempotent and replay-safe."

## Slide 6 — Capabilities

- **On-slide:** The 10 capabilities grouped: pay.once, pay.split, approval.scope,
  receipt.generate (P0); invoice, pay.recurring, ledger.query (P1); pay.escrow,
  pay.tip, intent.parse (P2).
- **Say:** "Send, split, approve, receipt, invoice, subscribe, audit, escrow,
  tip, and parse intent — the full payment lifecycle, all first-class."

## Slide 7 — Live proof on Pharos

- **On-slide:** Screenshot of the green `record-demo.sh` run + the block
  explorer. Tx: `pay.once` `0xdabf…3148`; token `0x4Cdc…D4E9`
  (Atlantic, chain 688689).
- **Say:** "This isn't a mock. Here's a real ERC-20 payment Lumen executed on
  Atlantic, decoded into a receipt and audited through the ledger."

## Slide 8 — Technical quality

- **On-slide:** 24/24 Foundry tests; strict TypeScript MCP server; shellcheck +
  markdownlint clean; GitHub Actions CI; deterministic error codes.
- **Say:** "It's small and well-tested: 24 passing contract tests, a strict MCP
  server, clean linters, and CI on every push."

## Slide 9 — Phase 2 vision

- **On-slide:** Agents that drop straight onto Lumen: Treasury, Royalty
  Splitter, Subscription, Bounty, Escrow-Marketplace. "No new on-chain infra."
- **Say:** "Because Lumen is a skill, Phase 2 agents are thin orchestration on
  top — a treasury agent, a royalty splitter, a subscription manager, and more."

## Slide 10 — Close

- **On-slide:** Repo `github.com/ahmadstiff/lumen`; "Agent-native payments,
  today." MIT licensed; four runtimes; built for the Pharos AI Agent economy.
- **Say:** "Lumen is the payment primitive layer for Pharos agents. The code is
  open, tested, and live on Atlantic today. Thank you."

## Timing guide

- Slides 1–4: ~60s (hook + what/why).
- Slides 5–6: ~45s (architecture + capabilities).
- Slide 7: ~45s (live proof — let the explorer load on camera).
- Slides 8–10: ~50s (quality, vision, close).

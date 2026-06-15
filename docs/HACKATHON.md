# Lumen — Pharos Phase 1 (Skill Hackathon) Submission Brief

> One-page judging brief mapping Lumen to the **Skill-to-Agent Dual Cascade
> Hackathon** Phase 1 criteria. See `README.md` for the elevator pitch,
> `docs/ARCHITECTURE.md` for the C4 + sequence diagrams, and
> `docs/SECURITY.md` for the threat model.

## TL;DR

Lumen is an **agent-native payment skill** for Pharos. It exposes 10 composable
capabilities (single payments, multi-recipient splits, scoped approvals,
audit-grade receipts, A2A invoices, recurring authorisations, ledger lookup,
hash-locked escrow, agent-tagged tips, NL intent parsing) through a **uniform
JSON envelope** so any agent runtime — Claude Code, Codex CLI, OpenClaw, **and
MCP clients** — can drive payments on Pharos Atlantic / Pacific without
deploying a single custom contract.

## Submission metadata

| Field            | Value                                                              |
|------------------|--------------------------------------------------------------------|
| Project name     | Lumen — Agent-Native Payments on Pharos                            |
| Track            | Phase 1 — Skill Hackathon                                          |
| Repo             | <https://github.com/ahmadstiff/lumen>                              |
| License          | MIT                                                                |
| Networks         | Pharos Atlantic Testnet (688689), Pharos Pacific Mainnet (1672)    |
| Runtimes         | Claude Code, Codex CLI, OpenClaw, MCP (Claude Desktop, Cursor, …)  |
| Skill standard   | Anthropic skill manifest (`SKILL.md`) + MCP tools                  |

## Judging criteria → evidence

### 1. Originality and creativity

- **First payment skill designed *for agents, not humans*.** Every capability
  reads JSON on stdin, writes JSON on stdout, emits machine-readable error
  codes — no interactive prompts, no human UX assumptions.
- **Stateless by design.** Zero custom contracts deployed. Every primitive is
  assembled from existing canonical contracts: ERC-20 `transfer` /
  `transferFrom`, **Permit2** (`0x000…22D473…BA3`), **Multicall3**
  (`0xcA11…CA11`), and EIP-712 signed authorisations. This eliminates upgrade
  governance, admin keys, and paused-contract failure modes.
- **Hash-locked escrow with no custodian.** `pay.escrow` proves a two-party
  conditional payment can be built from one signature, one bounded allowance,
  and the local audit ledger — no third-party trust required.
- **Deterministic intent parser.** `intent.parse` is regex-based, not LLM —
  the calling agent stays in control of disambiguation and gets ranked
  candidates with confidence scores instead of a black-box "did what I think".

### 2. Technical quality and completeness

- **Solidity helper library + 24 passing tests.** `contracts/src/LumenLib.sol`
  carries pure EIP-712 digest helpers for Receipt, Invoice,
  RecurringAuthorization, EscrowOffer, and TipClaim, plus BPS-share validation
  with invariant checks. `forge test` → **24 passed, 0 failed, 0 skipped**.
- **Strict TypeScript MCP server.** `mcp-server/` builds clean under
  `tsc --strict --noUncheckedIndexedAccess`; smoke test (initialize +
  tools/list + tools/call against `intent.parse`) is green.
- **Shellcheck-clean bash.** All capability scripts + `scripts/lib/common.sh`
  pass `shellcheck` with no warnings; only info-level "source not followed"
  notices remain (cosmetic).
- **Markdownlint-clean docs.** `markdownlint -c .markdownlint.json` returns
  zero errors across all 14+ markdown files.
- **Deterministic error model.** Every error envelope is
  `{status:"error", error:{code, message, details}}` with a stable
  `error.code` namespace (`insufficient_balance`, `policy_unlimited_approval`,
  `tip_amount_too_large`, `signature_mismatch`, …) so agents branch on code,
  not message text.

### 3. Practical use case for AI Agents

- **Full payment lifecycle.** Send → split → approve → receipt → invoice →
  subscribe → escrow → tip → audit. There's no payment-shape the agent has to
  bolt onto Lumen — they're all already first-class.
- **Idempotency + audit ledger.** Every mutating capability accepts an
  `idempotency_key`; replays return the cached receipt with `replayed: true`
  and **never broadcast a second transaction**. The append-only
  `.lumen/ledger.ndjson` is consumable by other skills (analytics, tax,
  treasury reconciliation).
- **Composable receipts.** Each call emits a normalised receipt in Markdown +
  JSON + CSV. Downstream skills get spreadsheet-friendly output for free.
- **Agent-to-agent primitives.** `invoice`, `pay.recurring`, `pay.escrow`,
  and `pay.tip` exchange EIP-712 documents — no central server, no off-chain
  state to manage, all signatures verifiable against the on-chain
  `LumenLib` digests.

### 4. Reusability and composability

- **Same source, four runtimes.** One repo ships:
  1. Claude Code skill (`.claude/skills/lumen/` layout works directly).
  2. Codex CLI skill (plain bash, no special wrapper).
  3. OpenClaw skill (`SKILL.md` frontmatter is OpenClaw-compatible).
  4. **MCP server** under `mcp-server/` — `npm run build`, point any MCP
     client at `dist/index.js`, all 10 capabilities are tools with the same
     name as the capability (`pay.once`, `pay.split`, …).
- **Composable by construction.** `pay.split mode=multicall` requires a
  prior `approval.scope mode=permit2` to Multicall3; `invoice action=pay`
  delegates to `pay.once`; `pay.tip action=send` does too. Capabilities
  compose without any glue beyond the JSON envelope.
- **Zero lock-in.** No custom contract on chain means a user can stop using
  Lumen at any time without orphaning funds in a custodian. Ledger is
  per-user, append-only, plain NDJSON.

### 5. Successful deployment / integration on Pharos

- **Networks wired** in `assets/networks.json`: Atlantic testnet (688689,
  `https://atlantic.dplabs-internal.com`) and Pacific mainnet (1672,
  `https://rpc.pharos.xyz`), with canonical Permit2 and Multicall3 addresses
  for both.
- **No private key on mainnet.** Capabilities enforce a hard policy refusal
  when `LUMEN_PRIVATE_KEY` is used on Pacific; mainnet must use
  `LUMEN_KEYSTORE` or `cast wallet`-managed accounts.
- **Receipts include explorer URLs** so judges can verify any tx hash
  visually on `pharosscan.xyz`.
- **Live deployment proof (Atlantic testnet, chain 688689):**
  - MockERC20 test token deploy — tx
    [`0x794c…8816`](https://atlantic.pharosscan.xyz/tx/0x794c39e852518ea2480ab876bce916fc773fb7a7e4327f9c2b98883071068816),
    token
    [`0x4Cdc…D4E9`](https://atlantic.pharosscan.xyz/address/0x4Cdc17C2738224b282153572ef052E661086D4E9)
  - Lumen `pay.once` — 1 lUSD ERC-20 transfer, tx
    [`0xdabf…3148`](https://atlantic.pharosscan.xyz/tx/0xdabf122f424dd02c16631ba909b8b5614e502d73a1a8736726957551e6573148)
    (decoded by `receipt.generate`, audited by `ledger.query`)
  - Reproduce: [`examples/demo-flow.sh`](../examples/demo-flow.sh) (offline
    `intent.parse` → live `pay.once` → `receipt.generate` → `ledger.query`);
    recording shot list in [`DEMO_SCRIPT.md`](./DEMO_SCRIPT.md).

### 6. User experience and clarity of documentation

- **`SKILL.md`** — single-page capability index + universal I/O contract.
- **`README.md`** — elevator pitch, six moats, capability table, 60-second
  quick start.
- **`docs/ARCHITECTURE.md`** — C4 (System / Container / Component) + payment
  & recurring sequence diagrams in Mermaid.
- **`docs/SECURITY.md`** — full T1–T14 threat matrix with mitigations.
- **`docs/CAPABILITIES.md`** — capability-by-capability index with
  composition examples ("settle 10 Q2 invoices atomically").
- **`docs/MCP.md`** — Claude Desktop / Cursor / Claude Code wiring guide.
- **`references/<capability>.md`** — per-capability schema, error codes,
  copy-paste examples.
- **`examples/`** — a runnable `demo-flow.sh` plus one JSON request fixture
  per capability, so judges can reproduce the flow in one command.
- **Per-tool MCP descriptions** explain composition rules so the agent
  doesn't need to read the bash to call the tool correctly.

### 7. Alignment with the Pharos AI Agent + on-chain economy vision

- **Pharos is positioned as the AI Agent chain.** Lumen is the *missing
  payments primitive layer* for that vision: every capability is built for
  programmatic agent invocation, not human wallets.
- **A2A economy primitives.** `invoice`, `pay.recurring`, `pay.escrow`,
  `pay.tip` are the on-chain analogues of contracts an agent ecosystem needs
  before any sophisticated coordination is possible.
- **Phase 2 ready.** Lumen is intentionally a *skill*, not an app — its
  natural Phase 2 partners are Treasury Agents (auto-pay vendor invoices),
  Royalty Agents (split revenue on incoming `Transfer`), Subscription Agents
  (manage `pay.recurring` plans), Bounty Agents (issue `pay.tip` tickets),
  and Escrow-Marketplace Agents.
- **No fragmentation.** Because Lumen ships as four runtimes from one source
  tree, any Phase 2 agent picks its preferred runtime without forcing the
  ecosystem into one tooling silo.

## Quality gates (reproducible)

```bash
# 1. Smart contracts
forge test --root contracts                        # 24 passed
# 2. Shell scripts (SC1091 "source not followed" is cosmetic only)
shellcheck -e SC1091 scripts/*.sh scripts/lib/common.sh examples/*.sh
# 3. Docs
markdownlint -c .markdownlint.json . --ignore mcp-server/node_modules
# 4. MCP server
cd mcp-server && npm install && npm run build      # clean tsc
node dist/index.js                                  # ready on stdio
```

## What sets Lumen apart from a "wrapper around cast"

- A bash one-liner around `cast send` cannot enforce policy (refusing
  `uint256.max`, capping windows at 365 days, rejecting raw private keys on
  mainnet, capping tip amounts).
- It cannot give the agent **idempotency** (Lumen's NDJSON ledger replays).
- It cannot give the agent **composable receipts** (Lumen normalises to MD +
  JSON + CSV).
- It cannot give the agent **EIP-712 A2A primitives** with on-chain-verifiable
  digests (invoice, recurring, escrow, tip ticket).
- It cannot give the agent **deterministic error codes** to branch on.
- It cannot do this across **four runtimes** simultaneously.

Lumen is the smallest, most-tested unit that gives an agent all of the above
together, with zero new on-chain surface to audit.

## Phase 2 teaser

Full write-ups with triggers, data flows, and capability mappings live in
[`PHASE2.md`](./PHASE2.md). In brief, Agent Arena projects that drop straight
onto Lumen:

1. **Lumen Treasury Agent** — auto-pays incoming EIP-712 invoices subject to
   per-vendor budget caps, generates monthly statements via `ledger.query` +
   `receipt.generate`.
2. **Royalty Splitter Agent** — listens for ERC-20 `Transfer` events to a
   designated wallet, fires `pay.split mode=multicall` to a configured BPS
   table.
3. **Subscription Manager Agent** — drives `pay.recurring` for any
   off-the-shelf SaaS that accepts on-chain billing.
4. **Bounty Custodian Agent** — issues `pay.tip` claim tickets and exposes
   them to a public bounty board.

Each of these is a Phase 2 candidate that does **not** require new on-chain
infra — just composition on top of the Lumen Skill.

## Links

- Repo: <https://github.com/ahmadstiff/lumen>
- Skill manifest: [`SKILL.md`](../SKILL.md)
- Architecture: [`docs/ARCHITECTURE.md`](./ARCHITECTURE.md)
- Security model: [`docs/SECURITY.md`](./SECURITY.md)
- MCP wiring: [`docs/MCP.md`](./MCP.md)
- Phase 2 mockups: [`docs/PHASE2.md`](./PHASE2.md)
- Demo script: [`docs/DEMO_SCRIPT.md`](./DEMO_SCRIPT.md)
- Pitch deck: [`docs/PITCH_DECK.md`](./PITCH_DECK.md)
- Examples: [`examples/`](../examples/)
- Pharos hackathon: <https://dorahacks.io/hackathon/pharos-phase1/detail>

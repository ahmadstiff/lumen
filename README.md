# Lumen — Agent-Native Payments on Pharos

> *"The light that moves money on Pharos."*

![status](https://img.shields.io/badge/status-MVP-blue)
![license](https://img.shields.io/badge/license-MIT-green)
![networks](https://img.shields.io/badge/networks-Atlantic%20%7C%20Pacific-violet)

Lumen is a payment **skill** — not an app, not a service — that lets AI agents
move money on Pharos with structured JSON, composable receipts, and **zero
custom contract deployments**.

## Why Lumen exists

Most "AI payments" projects bolt an agent on top of a Web3 SDK. Lumen flips
the model: every capability is designed from the ground up for agent-native
consumption — same JSON in, same JSON out, deterministic error codes,
append-only audit ledger.

## The six moats

| # | Moat | What it means in code |
|---|---|---|
| 1 | **Agent-native by design** | Every script reads JSON on stdin, writes JSON on stdout, emits machine-codeable errors. No interactive prompts. |
| 2 | **Stateless architecture** | We compose Permit2 + Multicall3 + EIP-712. **Zero** custom contract is deployed. |
| 3 | **Composable receipts** | Each call writes a normalized receipt to `.lumen/ledger.ndjson` and emits MD + JSON + CSV. |
| 4 | **CertiK Skill Scanner-first** | Unlimited approvals refused, raw private keys blocked on mainnet, no shell `eval`. |
| 5 | **Agent-to-Agent primitives** | `invoice` and `pay.recurring` exchange EIP-712 docs between agents, no central server. |
| 6 | **Multi-framework distribution** | Claude Code, Codex CLI, OpenClaw, MCP — same skill files, four runtimes. |

## Capabilities (P0 + P1 + P2)

| Capability | Tier | Script | Reference |
|---|---|---|---|
| `pay.once`         | P0 | `scripts/pay.once.sh`         | `references/pay.once.md` |
| `pay.split`        | P0 | `scripts/pay.split.sh`        | `references/pay.split.md` |
| `approval.scope`   | P0 | `scripts/approval.scope.sh`   | `references/approval.scope.md` |
| `receipt.generate` | P0 | `scripts/receipt.generate.sh` | `references/receipt.generate.md` |
| `invoice`          | P1 | `scripts/invoice.sh`          | `references/invoice.md` |
| `pay.recurring`    | P1 | `scripts/pay.recurring.sh`    | `references/pay.recurring.md` |
| `ledger.query`     | P1 | `scripts/ledger.query.sh`     | `references/ledger.query.md` |
| `pay.escrow`       | P2 | `scripts/pay.escrow.sh`       | `references/pay.escrow.md` |
| `pay.tip`          | P2 | `scripts/pay.tip.sh`          | `references/pay.tip.md` |
| `intent.parse`     | P2 | `scripts/intent.parse.sh`     | *(inline docs in script)* |

Also shipped: `mcp-server/` — a TypeScript MCP server that re-exposes every
capability above as an MCP tool. See `docs/MCP.md`.

## Quick start

```bash
# 0. Prereqs: foundry (forge, cast), jq, shellcheck, markdownlint-cli, bc
#    macOS: brew install foundryup jq shellcheck markdownlint-cli
#    foundryup && foundryup install stable

# 1. Build the helper Solidity library and run the test suite
forge install foundry-rs/forge-std --no-git --shallow --root contracts
forge test --root contracts   # expect 17 tests pass

# 2. Configure a wallet for capability calls
cp .env.example .env
$EDITOR .env                  # pick network + one of keystore/account/private key

# 3. Make a payment
echo '{
  "network": "atlantic",
  "idempotency_key": "demo-1",
  "params": {
    "token": "0xUSDC…",
    "recipient": "0x70997970…",
    "amount": "1000000",
    "memo": "hello pharos"
  }
}' | scripts/pay.once.sh | jq
```

## Repository layout

```text
.
├── SKILL.md                  # Anthropic skill manifest (capability index)
├── README.md                 # this file
├── assets/
│   └── networks.json         # Pharos Atlantic + Pacific RPC, explorer, well-known contracts
├── contracts/
│   ├── foundry.toml          # Foundry profile (optimizer, fuzz, fmt)
│   ├── src/LumenLib.sol      # Pure helper library — EIP-712, BPS math
│   └── test/LumenLib.t.sol   # 17 tests (unit + fuzz invariants)
├── docs/
│   ├── ARCHITECTURE.md       # C4 + sequence diagrams (Mermaid)
│   ├── SECURITY.md           # Threat model, autonomy posture
│   └── CAPABILITIES.md       # Consolidated capability guide
├── references/
│   └── <capability>.md       # One reference doc per capability
├── scripts/
│   ├── lib/common.sh         # Shared bash library (logging, JSON, bignum, ledger)
│   ├── pay.once.sh           # P0
│   ├── pay.split.sh          # P0
│   ├── approval.scope.sh     # P0
│   ├── receipt.generate.sh   # P0
│   ├── invoice.sh            # P1
│   ├── pay.recurring.sh      # P1
│   └── ledger.query.sh       # P1
└── .lumen/                   # per-user runtime state (gitignored)
    ├── ledger.ndjson         # append-only audit ledger
    ├── receipts/<tx>/        # MD + JSON + CSV per transaction
    └── queries/<ts>/         # MD + JSON + CSV per ledger.query call
```

## Network support

- **Pharos Atlantic Testnet** — chain id 688689, RPC `https://atlantic.dplabs-internal.com`
- **Pharos Pacific Mainnet** — chain id 1672, RPC `https://rpc.pharos.xyz`

Switch via `LUMEN_NETWORK` env var or `"network"` field in any request.

## Security posture

Read `docs/SECURITY.md` before granting Lumen any allowances. Highlights:

- `approval.scope` refuses `uint256.max` and requires a future `expiry_unix`.
- Raw `LUMEN_PRIVATE_KEY` is forbidden on mainnet — use `LUMEN_KEYSTORE` or
  `cast wallet` accounts.
- All capabilities write to `.lumen/ledger.ndjson` and replay idempotently.

## License

MIT. See `LICENSE` (`SPDX-License-Identifier: MIT`).

## Acknowledgements

Built for **Pharos Hackathon Phase 1**. Logo by the wavelength of payment
that finally moves at the speed of an agent.

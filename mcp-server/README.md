# Lumen MCP Server

A Model Context Protocol (MCP) server that exposes every Lumen capability as
an MCP tool. Drop it into Claude Desktop, Cursor, VS Code, Claude Code, or any
other MCP-aware client to give the agent agent-native payments on Pharos.

## What it does

Each Lumen capability becomes an MCP tool with the **same name** as the
capability (`pay.once`, `pay.split`, `approval.scope`, `receipt.generate`,
`invoice`, `pay.recurring`, `ledger.query`, `pay.escrow`, `pay.tip`,
`intent.parse`). Tool inputs are the underlying capability `params` plus the
two optional envelope fields `network` and `idempotency_key`. Each tool spawns
the corresponding `scripts/<capability>.sh`, feeds the JSON envelope on stdin,
and returns the bash script's structured envelope as the MCP tool result —
errors come back with `isError: true` so the calling agent can self-correct.

## Prerequisites

- **Node.js ≥ 20**
- **Foundry** (`forge`, `cast`) on `PATH` — required by the Lumen bash scripts.
- **jq**, **bc**, **bash** — required by the Lumen bash scripts.
- A configured Lumen wallet (see `../.env.example`).

## Build

```bash
cd mcp-server
npm install
npm run build      # emits dist/index.js with a #!/usr/bin/env node shebang
```

## Run (stdio)

```bash
node dist/index.js
# or, if you ran `npm link`, just:
# lumen-mcp-server
```

The server reads JSON-RPC framing on stdin and writes responses on stdout.
All human-readable logs go to stderr — **never write to stdout** in stdio mode.

## Smoke test (no wallet required)

```bash
(
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoketest","version":"0.0.1"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"intent.parse","arguments":{"utterance":"send 10 USDC to 0x70997970C51812dc3A010C7d01b50e0d17dc79C8","default_token":"0xA0b86991C6218B36c1d19D4a2e9Eb0cE3606eB48"}}}'
  sleep 0.3
) | node dist/index.js
```

You should see two JSON-RPC frames on stdout: the `initialize` result and the
`intent.parse` envelope with `best_match.capability == "pay.once"`.

## Environment variables

| Variable                                                       | Default                                  | Purpose                                                                       |
|----------------------------------------------------------------|------------------------------------------|-------------------------------------------------------------------------------|
| `LUMEN_SCRIPTS_DIR`                                            | `../scripts` relative to `dist/`         | Where to find `scripts/*.sh`. Set when running outside the repo.              |
| `LUMEN_NETWORK`                                                | *(unset)*                                | Default Pharos network when a tool call omits `network`.                      |
| `LUMEN_KEYSTORE` / `LUMEN_ACCOUNT` / `LUMEN_PRIVATE_KEY`       | *(unset)*                                | Sender resolution. See `../.env.example`.                                     |
| `LUMEN_RPC_URL`                                                | from `assets/networks.json`              | Override the RPC endpoint for the active network.                             |

The server inherits the environment of whatever process spawned it (Claude
Desktop, Cursor, etc.), so set Lumen vars in that process — for Claude Desktop
they go in the `env` field of `claude_desktop_config.json` (see below).

## Wire into Claude Desktop

Edit `claude_desktop_config.json` (macOS:
`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "lumen": {
      "command": "node",
      "args": ["/ABS/PATH/TO/lumen/mcp-server/dist/index.js"],
      "env": {
        "LUMEN_NETWORK": "atlantic",
        "LUMEN_KEYSTORE": "/Users/me/.lumen/keys/sender.json"
      }
    }
  }
}
```

Restart Claude Desktop. The Lumen tools appear under "lumen". Mutating tools
trigger Claude Desktop's confirmation prompt before the bash script broadcasts.

## Wire into Cursor / Claude Code / VS Code

Create `.cursor/mcp.json` (or `.claude/mcp.json` / `.vscode/mcp.json`):

```json
{
  "servers": {
    "lumen": {
      "type": "stdio",
      "command": "node",
      "args": ["/ABS/PATH/TO/lumen/mcp-server/dist/index.js"]
    }
  }
}
```

## Architecture notes

- **Bash is the source of truth.** This server is a thin wrapper. Every
  policy (refusing `uint256.max`, mainnet PK refusal, 365-day windows, tip
  caps, signature verification, ledger replay) is enforced in the bash
  script. The MCP layer only validates the input shape so the agent gets
  a fast schema error before paying a process-spawn round-trip.
- **stdout is sacrosanct.** stdio framing requires precise JSON-RPC on
  stdout — `console.error()` is used for every log line.
- **Errors are surfaced, not hidden.** The bash script's
  `{status:"error", error:{code,message,details}}` envelope is forwarded
  verbatim with `isError: true` so the agent can branch on `error.code`.
- **No new contract surface.** This server adds no new on-chain footprint.
  All security guarantees come from the same primitives Lumen already uses
  (Permit2, Multicall3, EIP-712, ERC-20 allowances).

## Layout

```text
mcp-server/
├── package.json            # ESM, Node ≥ 20
├── tsconfig.json           # strict, Node16 module
├── src/
│   ├── index.ts            # stdio entry
│   ├── server.ts           # builds McpServer + registers tools
│   ├── runner.ts           # spawns bash + parses JSON envelopes
│   ├── paths.ts            # resolves scripts/ directory
│   ├── schemas.ts          # shared zod fragments
│   └── tools/
│       ├── pay-once.ts
│       ├── pay-split.ts
│       ├── approval-scope.ts
│       ├── receipt-generate.ts
│       ├── invoice.ts
│       ├── pay-recurring.ts
│       ├── ledger-query.ts
│       ├── pay-escrow.ts
│       ├── pay-tip.ts
│       └── intent-parse.ts
└── dist/                   # built output (gitignored)
```

## License

MIT. Same as the parent `lumen` repo.

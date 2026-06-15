# Lumen Architecture

This document describes Lumen at three C4 levels — System Context, Container,
Component — followed by the canonical payment flow sequences.

## 1. System Context

Lumen lives at the boundary between *an AI agent* and *the Pharos chain*. It
never holds funds, never deploys contracts, and never exposes a public
endpoint. The agent invokes Lumen as a local skill; Lumen invokes Pharos via
the user's chosen RPC.

```mermaid
C4Context
  title System Context — Lumen
  Person(user, "Operator", "Owns the wallet and the agent runtime")
  System(agent, "AI Agent", "Claude Code / Codex / OpenClaw / MCP client")
  System(lumen, "Lumen Skill", "Stateless payment skill (this repo)")
  System_Ext(pharos, "Pharos Atlantic / Pacific", "EVM chain with Permit2 + Multicall3")
  System_Ext(explorer, "Pharos Explorer", "Block explorer for human audit")

  Rel(user, agent, "Asks for a payment / report")
  Rel(agent, lumen, "JSON request via stdin")
  Rel(lumen, pharos, "cast send / cast call (RPC)")
  Rel(lumen, explorer, "Embeds explorer URLs in receipts")
```

## 2. Container View

Inside the Lumen process we have four containers: capability scripts (the
public surface), a shared bash library, a pure Solidity helper library, and
the local ledger.

```mermaid
C4Container
  title Container View — Lumen
  Person(user, "Operator")
  System_Boundary(lumen, "Lumen Skill") {
    Container(scripts, "Capability scripts", "Bash", "pay.once.sh, pay.split.sh, …")
    Container(common, "Shared library", "Bash", "scripts/lib/common.sh")
    Container(lumenlib, "LumenLib", "Solidity 0.8.24", "Pure EIP-712 helper library + tests")
    ContainerDb(ledger, "Append-only ledger", "NDJSON", ".lumen/ledger.ndjson")
  }
  System_Ext(pharos, "Pharos chain")
  System_Ext(cast, "cast CLI", "Foundry tooling")

  Rel(user, scripts, "echo JSON | scripts/*.sh")
  Rel(scripts, common, "source")
  Rel(scripts, cast, "exec")
  Rel(cast, pharos, "RPC")
  Rel(scripts, ledger, "append receipt")
  Rel(lumenlib, scripts, "shared EIP-712 type hashes (off-chain mirror)")
```

## 3. Component View — typical payment

Zoom into `scripts/pay.once.sh` to see how a single payment is broken into
six components.

```mermaid
C4Component
  title Component View — pay.once
  Container_Boundary(pay_once, "pay.once.sh") {
    Component(parse, "Request parser", "jq", "Validates JSON, extracts params")
    Component(idem, "Idempotency check", "ledger_lookup()", "Returns cached receipt if key reused")
    Component(net, "Network resolver", "resolve_network()", "Reads assets/networks.json")
    Component(auth, "Sender resolver", "sender_cast_flags()", "Picks one of keystore/account/PK")
    Component(preflight, "Balance preflight", "bignum_lt()", "Refuses with insufficient_balance")
    Component(send, "Broadcaster", "cast send", "ERC-20 transfer + receipt parsing")
    Component(receipt, "Receipt builder", "jq", "Emits structured envelope + ledger append")
  }
  System_Ext(pharos, "Pharos chain")
  ComponentDb(ledger, "Ledger", "NDJSON")

  Rel(parse, idem, "validated request")
  Rel(idem, net, "miss → continue")
  Rel(idem, receipt, "hit → cached envelope (replayed)")
  Rel(net, auth, "RPC + chain id")
  Rel(auth, preflight, "sender addr")
  Rel(preflight, send, "ok")
  Rel(send, pharos, "transfer(addr,uint)")
  Rel(send, receipt, "tx hash, gas, status")
  Rel(receipt, ledger, "append")
```

## 4. Canonical payment flow

The "happy path" for a `pay.once`:

```mermaid
sequenceDiagram
    autonumber
    participant Agent
    participant Lumen as pay.once.sh
    participant Cast as cast (CLI)
    participant Pharos as Pharos RPC
    participant Ledger as .lumen/ledger.ndjson

    Agent->>Lumen: JSON request (stdin)
    Lumen->>Lumen: parse + validate + idempotency lookup
    Lumen->>Cast: erc20_decimals / erc20_balance_of
    Cast->>Pharos: eth_call
    Pharos-->>Cast: balance, decimals
    Cast-->>Lumen: values
    alt balance < amount
        Lumen-->>Agent: error envelope (code: insufficient_balance)
    else
        Lumen->>Cast: cast send transfer(...)
        Cast->>Pharos: eth_sendRawTransaction
        Pharos-->>Cast: tx receipt
        Cast-->>Lumen: hash, block, gas, status
        Lumen->>Ledger: append receipt
        Lumen-->>Agent: success envelope (JSON)
    end
```

## 5. Recurring-payment trust model

The single most subtle flow — see `references/pay.recurring.md` for the
narrative version:

```mermaid
sequenceDiagram
    autonumber
    participant Sub as Subscriber agent
    participant Mer as Merchant agent
    participant Chain as Pharos ERC-20

    Sub->>Sub: pay.recurring create (sign EIP-712 doc)
    Sub->>Chain: approval.scope (allowance to merchant)
    Note over Sub,Mer: Doc exchanged once via any A2A channel.

    loop Each period
        Mer->>Mer: pay.recurring charge<br/>(verify sig + check ledger quota)
        Mer->>Chain: transferFrom(sub, mer, amount_per)
        Chain-->>Mer: tx receipt
        Mer->>Mer: ledger_append (counts toward quota)
    end
```

## Why no custom contract?

Lumen could ship a `LumenEscrow.sol` and `LumenRecurringHub.sol`. It does
**not**. The pillar is that *every primitive can be assembled from existing
canonical contracts on Pharos*:

- Single transfers — ERC-20 `transfer` / `transferFrom`
- Batched atomic settlement — Multicall3.`aggregate3`
- Scoped approvals — Permit2.`approve`
- Pre-signed authorisations — EIP-712 with off-chain ledger enforcement

This eliminates an entire class of failure modes (upgrade governance, admin
keys, paused contracts) and reduces the audit surface to the **scripts**
themselves.

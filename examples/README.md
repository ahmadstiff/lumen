# Lumen examples

Runnable, copy-pasteable examples for the Lumen payment skill. Everything here
speaks the same JSON-in / JSON-out contract the agent runtimes use, so what you
run by hand is exactly what an agent runs.

## `demo-flow.sh` — one-command end-to-end

```bash
# From the repo root:
examples/demo-flow.sh
```

The script runs in two phases:

1. **`intent.parse` (offline).** Turns a natural-language utterance into a
   ranked list of Lumen capability requests. This needs **only `jq`** — no
   wallet, no RPC, no funds. It always runs and is fully deterministic, which
   makes it the safest thing to show a judge first.
2. **Live or dry-run.**
   - **Dry run (default).** Prints the exact `pay.once` and `pay.split`
     requests it *would* broadcast, without sending anything.
   - **Live (opt-in).** If a sender wallet is configured, `cast` is installed,
     and `LUMEN_DEMO_TOKEN` is set, it executes `pay.once` →
     `receipt.generate` → `ledger.query` on the **Atlantic testnet**.

The demo defaults to `LUMEN_NETWORK=atlantic` and never targets mainnet.

## Recording the demo video

`record-demo.sh` is a presenter wrapper: clean banners, a pause between each
step (press Enter), and a proof summary with explorer links. Defaults are wired
for the recorded Atlantic demo, so it is one command:

```bash
examples/record-demo.sh            # smooth replay run (no password prompt)
FRESH=1 examples/record-demo.sh    # broadcast a brand-new live tx instead
FAST=1  examples/record-demo.sh    # no pauses (rehearsal)
```

By default it replays the recorded `pay.once` idempotently, so the run is fully
green with no keystore password — ideal for a clean take. Pair it with the slide
script in [`../docs/PITCH_DECK.md`](../docs/PITCH_DECK.md) and the shot list in
[`../docs/DEMO_SCRIPT.md`](../docs/DEMO_SCRIPT.md).

## Going live on Atlantic testnet

You need three things: foundry, a funded testnet key, and an ERC-20 to move.

```bash
# 1. Tooling (macOS ships bash 3.2; Lumen needs bash >= 4)
brew install bash foundry jq && foundryup

# 2. A testnet sender. Prefer an encrypted keystore or a cast-managed account
#    over a raw private key. Import an existing key as a named account:
cast wallet import lumen-sender --interactive
export LUMEN_ACCOUNT=lumen-sender

# 3. A token to move. Deploy a throwaway ERC-20 you control, or use any test
#    token you already hold on Atlantic. Then point the demo at it:
export LUMEN_DEMO_TOKEN=0xYourTestTokenAddress

# 4. Run the live flow
examples/demo-flow.sh
```

Fund the sender with Atlantic gas (PHRS) first; otherwise `pay.once` returns a
structured `tx_send_failed` envelope instead of a receipt.

> Mainnet note: Lumen refuses a raw `LUMEN_PRIVATE_KEY` on Pacific mainnet by
> policy. Use `LUMEN_KEYSTORE` or `LUMEN_ACCOUNT` there.

## Capturing proof for the submission

After a successful live run, each capability returns a `tx.hash` and an
`tx.explorer_url`. Copy them into:

- `docs/HACKATHON.md` → section *5. Successful deployment / integration on
  Pharos* (replace the placeholder).
- Your DoraHacks BUIDL description, as proof of a working Pharos deployment.

The same transactions are also written to `.lumen/ledger.ndjson` and to
`.lumen/receipts/<tx>/` as Markdown + JSON + CSV.

## Request fixtures (`examples/requests/`)

Each file is a complete request body for one capability. Pipe any of them into
the matching script:

```bash
scripts/intent.parse.sh     < examples/requests/intent.parse.json
scripts/pay.once.sh         < examples/requests/pay.once.json
scripts/approval.scope.sh   < examples/requests/approval.scope.json
scripts/pay.split.sh        < examples/requests/pay.split.json
scripts/receipt.generate.sh < examples/requests/receipt.generate.json
scripts/ledger.query.sh     < examples/requests/ledger.query.json
```

Notes:

- Addresses are valid 40-hex placeholders (well-known dev addresses). Swap in
  your own recipients before a live run.
- `approval.scope.json` carries an illustrative `expiry_unix`; it must be a
  future timestamp within 365 days. `demo-flow.sh` recomputes it for you.
- `receipt.generate.json` carries a zero `tx_hash` placeholder; `demo-flow.sh`
  fills in the real hash from the live `pay.once` response.
- The `mode: "multicall"` split needs a prior `approval.scope` (mode `permit2`)
  granting Multicall3 a budget — see `references/pay.split.md`.

Full per-capability schemas, error codes, and more examples live in
[`../references/`](../references/) and [`../docs/CAPABILITIES.md`](../docs/CAPABILITIES.md).

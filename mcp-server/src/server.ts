/**
 * Build the Lumen MCP server.
 *
 * Each Lumen capability is exposed as a separate MCP tool whose name matches
 * the capability identifier (e.g. `pay.once`, `pay.split`). Tool inputs are
 * the same per-capability params documented under `references/`, plus the
 * two optional envelope fields `network` and `idempotency_key`.
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";

import { registerApprovalScope } from "./tools/approval-scope.js";
import { registerIntentParse } from "./tools/intent-parse.js";
import { registerInvoice } from "./tools/invoice.js";
import { registerLedgerQuery } from "./tools/ledger-query.js";
import { registerPayEscrow } from "./tools/pay-escrow.js";
import { registerPayOnce } from "./tools/pay-once.js";
import { registerPayRecurring } from "./tools/pay-recurring.js";
import { registerPaySplit } from "./tools/pay-split.js";
import { registerPayTip } from "./tools/pay-tip.js";
import { registerReceiptGenerate } from "./tools/receipt-generate.js";

export const SERVER_NAME = "lumen-mcp-server";
export const SERVER_VERSION = "0.1.0";

const INSTRUCTIONS = `Lumen is an agent-native payment skill for Pharos (Atlantic testnet + Pacific mainnet). Tool names mirror Lumen capabilities (pay.once, pay.split, approval.scope, receipt.generate, invoice, pay.recurring, ledger.query, pay.escrow, pay.tip, intent.parse).

Composition rules:
- For an unknown natural-language request, call intent.parse first; pick the highest-confidence candidate and call that capability.
- Always supply an idempotency_key on any mutating call you might retry — repeated calls with the same key return the cached receipt.
- Multi-recipient payouts that must be atomic require approval.scope (mode=permit2) to Multicall3 BEFORE pay.split (mode=multicall).
- pay.escrow create returns release_key — that is a bearer secret. Pass it OOB only after the payee delivers.
- Read-only tools: receipt.generate, ledger.query, intent.parse, and any *.action=verify variant.`;

export function createLumenMcpServer(): McpServer {
  const server = new McpServer(
    { name: SERVER_NAME, version: SERVER_VERSION },
    { instructions: INSTRUCTIONS },
  );

  // P0 capabilities
  registerPayOnce(server);
  registerPaySplit(server);
  registerApprovalScope(server);
  registerReceiptGenerate(server);

  // P1 capabilities
  registerInvoice(server);
  registerPayRecurring(server);
  registerLedgerQuery(server);

  // P2 capabilities
  registerPayEscrow(server);
  registerPayTip(server);
  registerIntentParse(server);

  return server;
}

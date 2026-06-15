import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

import { runCapability, outcomeToToolResult } from "../runner.js";
import { addressSchema, commonEnvelopeFields } from "../schemas.js";

const CAPABILITY = "ledger.query";

const inputShape = {
  ...commonEnvelopeFields,
  source: z
    .enum(["local", "chain", "both"])
    .optional()
    .describe(
      "'local' (default) reads .lumen/ledger.ndjson, 'chain' calls eth_getLogs for ERC-20 Transfer events, 'both' returns the deduplicated union.",
    ),
  token: addressSchema.optional().describe("Filter to a single ERC-20."),
  from: addressSchema.optional().describe("Filter by sender address."),
  to: addressSchema.optional().describe("Filter by recipient address."),
  capability: z
    .enum(["pay.once", "pay.split", "pay.recurring", "pay.tip", "pay.escrow"])
    .optional()
    .describe("Filter the local source by emitting capability."),
  since_unix: z
    .number()
    .int()
    .min(0)
    .optional()
    .describe("Only return entries newer than this Unix timestamp."),
  from_block: z
    .union([z.literal("earliest"), z.number().int().min(0)])
    .optional()
    .describe("Chain-source lower bound."),
  to_block: z
    .union([z.literal("latest"), z.number().int().min(0)])
    .optional()
    .describe("Chain-source upper bound."),
  limit: z
    .number()
    .int()
    .min(1)
    .max(1000)
    .optional()
    .describe("Maximum entries returned (default 200)."),
  formats: z
    .array(z.enum(["json", "csv", "markdown"]))
    .optional()
    .describe("Which artefacts to write to output_dir."),
  output_dir: z
    .string()
    .optional()
    .describe("Defaults to .lumen/queries/<timestamp>/."),
};

export function registerLedgerQuery(server: McpServer): void {
  server.registerTool(
    CAPABILITY,
    {
      title: "Lumen: ledger.query",
      description:
        "Historical payment lookup. Reads from the local NDJSON ledger and/or on-chain ERC-20 Transfer logs and returns deduplicated entries with artefacts (JSON/CSV/Markdown). Read-only — never writes to the ledger.",
      inputSchema: inputShape,
      annotations: {
        title: "Lumen: ledger.query",
        readOnlyHint: true,
        idempotentHint: true,
        openWorldHint: true,
      },
    },
    async (args) => {
      const { network, idempotency_key, ...params } = args;
      const outcome = await runCapability(CAPABILITY, {
        ...(network && { network }),
        ...(idempotency_key && { idempotency_key }),
        params,
      });
      return outcomeToToolResult(CAPABILITY, outcome);
    },
  );
}

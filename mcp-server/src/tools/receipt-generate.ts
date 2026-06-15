import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

import { runCapability, outcomeToToolResult } from "../runner.js";
import { bytes32Schema, commonEnvelopeFields } from "../schemas.js";

const CAPABILITY = "receipt.generate";

const inputShape = {
  ...commonEnvelopeFields,
  tx_hash: bytes32Schema.describe(
    "0x-prefixed 64-hex transaction hash to decode.",
  ),
  formats: z
    .array(z.enum(["markdown", "json", "csv"]))
    .optional()
    .describe(
      "Subset of receipt artefacts to write. Defaults to all three (markdown + json + csv).",
    ),
  output_dir: z
    .string()
    .optional()
    .describe(
      "Output directory for artefacts. Defaults to .lumen/receipts/<tx>/.",
    ),
};

export function registerReceiptGenerate(server: McpServer): void {
  server.registerTool(
    CAPABILITY,
    {
      title: "Lumen: receipt.generate",
      description:
        "Decode any transaction on Pharos into a composable receipt (Markdown + JSON + CSV). Reads ERC-20 Transfer/Approval logs on-chain, resolves token symbols + decimals, and appends an audit record to .lumen/ledger.ndjson. Read-only on chain state.",
      inputSchema: inputShape,
      annotations: {
        title: "Lumen: receipt.generate",
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

import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

import { runCapability, outcomeToToolResult } from "../runner.js";
import {
  addressSchema,
  commonEnvelopeFields,
  uintStringSchema,
} from "../schemas.js";

const CAPABILITY = "pay.once";

const inputShape = {
  ...commonEnvelopeFields,
  token: addressSchema.describe("ERC-20 contract address."),
  recipient: addressSchema.describe("Destination wallet."),
  amount: uintStringSchema.describe(
    "Decimal integer in base units (e.g. 1000000 = 1 USDC at 6 decimals).",
  ),
  mode: z
    .enum(["transfer", "permit2"])
    .optional()
    .describe(
      "Default 'transfer' (direct ERC-20 transfer). 'permit2' is reserved for pay.split and returns not_implemented here.",
    ),
  memo: z
    .string()
    .max(256)
    .optional()
    .describe("Free-text annotation captured in the receipt and ledger."),
  max_gas_price_gwei: uintStringSchema
    .optional()
    .describe(
      "Hard cap on gas price in gwei. The script refuses to broadcast if the network price exceeds it.",
    ),
};

export function registerPayOnce(server: McpServer): void {
  server.registerTool(
    CAPABILITY,
    {
      title: "Lumen: pay.once",
      description:
        "Send a single ERC-20 payment from the configured Lumen wallet to one recipient. Includes balance preflight, optional gas cap, idempotency replay, and a structured audit receipt written to .lumen/ledger.ndjson. For multi-recipient atomic splits use pay.split instead.",
      inputSchema: inputShape,
      annotations: {
        title: "Lumen: pay.once",
        destructiveHint: true,
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

import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

import { runCapability, outcomeToToolResult } from "../runner.js";
import {
  addressSchema,
  commonEnvelopeFields,
  uintStringSchema,
} from "../schemas.js";

const CAPABILITY = "pay.split";

const inputShape = {
  ...commonEnvelopeFields,
  token: addressSchema.describe("ERC-20 contract address."),
  mode: z
    .enum(["sequential", "multicall"])
    .optional()
    .describe(
      "'sequential' (default) sends N independent transfers. 'multicall' is atomic via Multicall3 — requires a prior approval.scope to the Multicall3 contract.",
    ),
  recipients: z
    .array(addressSchema)
    .min(1)
    .describe("Recipient wallet addresses (length must match amounts/shares)."),
  amounts: z
    .array(uintStringSchema)
    .optional()
    .describe(
      "Per-recipient amounts in base units. Provide either amounts[] OR shares_bps[]+total, not both.",
    ),
  shares_bps: z
    .array(z.number().int().min(0).max(10000))
    .optional()
    .describe(
      "Per-recipient basis-point shares summing to exactly 10000. Last recipient absorbs rounding remainder.",
    ),
  total: uintStringSchema
    .optional()
    .describe("Total amount in base units. Required when shares_bps is used."),
  memo: z.string().max(256).optional(),
};

export function registerPaySplit(server: McpServer): void {
  server.registerTool(
    CAPABILITY,
    {
      title: "Lumen: pay.split",
      description:
        "Split one ERC-20 amount across N recipients. Choose 'sequential' for independent transfers (max forward progress under partial failure) or 'multicall' for atomic Multicall3 settlement (requires a prior approval.scope to Multicall3). Pick exactly one allocation strategy: explicit amounts[] OR shares_bps[]+total.",
      inputSchema: inputShape,
      annotations: {
        title: "Lumen: pay.split",
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

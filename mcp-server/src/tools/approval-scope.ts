import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

import { runCapability, outcomeToToolResult } from "../runner.js";
import {
  addressSchema,
  commonEnvelopeFields,
  uintStringSchema,
} from "../schemas.js";

const CAPABILITY = "approval.scope";

const inputShape = {
  ...commonEnvelopeFields,
  token: addressSchema.describe("ERC-20 contract address."),
  spender: addressSchema.describe(
    "Address authorised to pull tokens (e.g. Multicall3, a recurring relayer, an escrow contract).",
  ),
  amount: uintStringSchema.describe(
    "Allowance cap in base units. uint256.max is REFUSED. Use '0' to revoke.",
  ),
  expiry_unix: z
    .number()
    .int()
    .positive()
    .describe(
      "Unix timestamp (seconds) when the allowance becomes invalid. Must be in the future and within 365 days.",
    ),
  mode: z
    .enum(["direct", "permit2"])
    .optional()
    .describe(
      "'direct' (default) sets a standard ERC-20 allowance. 'permit2' uses the canonical Permit2 contract with on-chain uint48 expiration.",
    ),
  memo: z.string().max(256).optional(),
};

export function registerApprovalScope(server: McpServer): void {
  server.registerTool(
    CAPABILITY,
    {
      title: "Lumen: approval.scope",
      description:
        "Grant a strictly bounded ERC-20 allowance. Refuses uint256.max, requires a future expiry, and caps the window at 365 days. Choose 'permit2' mode when the spender is Permit2-aware (Multicall3 workflows, Lumen escrow). To revoke, set amount='0' with a short expiry.",
      inputSchema: inputShape,
      annotations: {
        title: "Lumen: approval.scope",
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

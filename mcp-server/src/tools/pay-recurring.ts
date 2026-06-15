import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

import { runCapability, outcomeToToolResult } from "../runner.js";
import {
  addressSchema,
  bytes32Schema,
  commonEnvelopeFields,
  uintStringSchema,
} from "../schemas.js";

const CAPABILITY = "pay.recurring";

const inputShape = {
  ...commonEnvelopeFields,
  action: z
    .enum(["create", "verify", "charge"])
    .describe(
      "'create' (subscriber signs an EIP-712 authorization), 'verify' (recover signer), or 'charge' (merchant verifies + enforces ledger quota + transferFrom).",
    ),
  merchant: addressSchema
    .optional()
    .describe(
      "Required for action=create. The address that will execute charges.",
    ),
  token: addressSchema
    .optional()
    .describe("Required for action=create. ERC-20 contract."),
  amount_per_period: uintStringSchema
    .optional()
    .describe(
      "Required for action=create. Amount in base units charged each period.",
    ),
  period_seconds: z
    .number()
    .int()
    .positive()
    .optional()
    .describe(
      "Required for action=create. Minimum seconds between successive charges.",
    ),
  start_at_unix: z
    .number()
    .int()
    .positive()
    .optional()
    .describe(
      "Optional. Unix timestamp when the plan becomes chargeable. Defaults to now.",
    ),
  end_at_unix: z
    .number()
    .int()
    .positive()
    .optional()
    .describe(
      "Required for action=create. Unix timestamp the plan expires (≤ start + 365 days).",
    ),
  max_periods: z
    .number()
    .int()
    .min(0)
    .max(366)
    .optional()
    .describe(
      "Maximum number of charges authorised. 0 = open-ended within the window. Ceiling 366.",
    ),
  plan_id: bytes32Schema.optional(),
  document: z
    .record(z.unknown())
    .optional()
    .describe(
      "Required for action=verify and action=charge. The signed RecurringAuthorization doc.",
    ),
};

export function registerPayRecurring(server: McpServer): void {
  server.registerTool(
    CAPABILITY,
    {
      title: "Lumen: pay.recurring",
      description:
        "Stateless subscriptions on Pharos. Subscriber signs an EIP-712 RecurringAuthorization (action=create) and runs approval.scope for the budget. Merchant charges each period via action=charge — the script enforces per-period quotas and max-period totals from the local Lumen ledger.",
      inputSchema: inputShape,
      annotations: {
        title: "Lumen: pay.recurring",
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

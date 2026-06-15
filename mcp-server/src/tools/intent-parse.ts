import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

import { runCapability, outcomeToToolResult } from "../runner.js";
import {
  addressSchema,
  commonEnvelopeFields,
  networkSchema,
} from "../schemas.js";

const CAPABILITY = "intent.parse";

const inputShape = {
  ...commonEnvelopeFields,
  utterance: z
    .string()
    .min(1)
    .max(2048)
    .describe(
      "Natural-language description of the desired payment. Example: 'send 10 USDC to 0x70997970C51812dc3A010C7d01b50e0d17dc79C8'.",
    ),
  default_token: addressSchema
    .optional()
    .describe(
      "Token to use when the utterance names a symbol (USDC, PHRS) instead of an address. If absent, the response uses 'TOKEN_PLACEHOLDER' so the agent must echo a concrete address back before invoking the suggested capability.",
    ),
  default_network: networkSchema
    .optional()
    .describe("Network to embed in the suggested request. Defaults to 'atlantic'."),
};

export function registerIntentParse(server: McpServer): void {
  server.registerTool(
    CAPABILITY,
    {
      title: "Lumen: intent.parse",
      description:
        "Deterministic regex-based mapper from a natural-language utterance to one or more candidate Lumen capability requests, each with a confidence score and explanation. Returns 'no_match' with helpful hints when nothing fits. Pure off-chain — does NOT broadcast any transaction.",
      inputSchema: inputShape,
      annotations: {
        title: "Lumen: intent.parse",
        readOnlyHint: true,
        idempotentHint: true,
        openWorldHint: false,
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

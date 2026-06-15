import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

import { runCapability, outcomeToToolResult } from "../runner.js";
import {
  addressSchema,
  bytes32Schema,
  commonEnvelopeFields,
  uintStringSchema,
} from "../schemas.js";

const CAPABILITY = "pay.escrow";

const inputShape = {
  ...commonEnvelopeFields,
  action: z
    .enum(["create", "verify", "claim", "refund"])
    .describe(
      "'create' (payer signs an EscrowOffer + returns a release_key bearer secret), 'verify' (recover signer), 'claim' (payee redeems with the release_key + executes transferFrom), 'refund' (payer records post-expiry refund).",
    ),
  payee: addressSchema
    .optional()
    .describe("Required for action=create. Address authorised to claim."),
  token: addressSchema
    .optional()
    .describe("Required for action=create. ERC-20 contract."),
  amount: uintStringSchema
    .optional()
    .describe("Required for action=create. Amount in base units."),
  expiry_unix: z
    .number()
    .int()
    .positive()
    .optional()
    .describe(
      "Required for action=create. Unix timestamp the escrow window closes.",
    ),
  memo: z.string().max(256).optional(),
  escrow_id: bytes32Schema
    .optional()
    .describe("Optional. Deterministic if absent."),
  release_key: bytes32Schema
    .optional()
    .describe(
      "Bearer secret. Generated for the payer on action=create; REQUIRED on action=claim. Share OOB only after the payee delivers.",
    ),
  document: z
    .record(z.unknown())
    .optional()
    .describe(
      "Required for action=verify, claim, and refund. The signed EscrowOffer doc returned by action=create.",
    ),
};

export function registerPayEscrow(server: McpServer): void {
  server.registerTool(
    CAPABILITY,
    {
      title: "Lumen: pay.escrow",
      description:
        "Stateless hash-locked escrow between two agents — no custodian, no custom contract. action=create gives the payer a signed EscrowOffer + a release_key bearer secret. The payer also runs approval.scope for the payee. After delivery, the payer reveals release_key out-of-band and the payee calls action=claim to execute transferFrom. If the payee never delivers, action=refund records the unwind after expiry.",
      inputSchema: inputShape,
      annotations: {
        title: "Lumen: pay.escrow",
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

/**
 * Zod fragments shared across every Lumen MCP tool.
 *
 * The Lumen universal request envelope is the same for every capability:
 *   { network?, idempotency_key?, params }
 *
 * Tools spread `commonEnvelopeFields` into their `inputSchema` so the agent
 * sees consistent field naming + descriptions everywhere.
 */

import { z } from "zod";

/** EVM 0x-prefixed 40-hex address. */
export const addressSchema = z
  .string()
  .regex(/^0x[0-9a-fA-F]{40}$/u, "must be a 0x-prefixed 40-hex EVM address");

/** Decimal integer expressed as a string (uint256-safe). */
export const uintStringSchema = z
  .string()
  .regex(/^\d+$/u, "must be a base-10 unsigned integer string");

/** bytes32 0x-prefixed 64-hex. */
export const bytes32Schema = z
  .string()
  .regex(/^0x[0-9a-fA-F]{64}$/u, "must be a 0x-prefixed 64-hex bytes32");

/** Network identifier accepted by Lumen capabilities. */
export const networkSchema = z
  .enum(["atlantic", "pacific"])
  .describe(
    "Pharos network. 'atlantic' = testnet (chainId 688689), 'pacific' = mainnet (chainId 1672).",
  );

/**
 * The two top-level optional fields every Lumen envelope accepts.
 * Spread into a capability-specific input shape:
 *
 *   inputSchema: { ...commonEnvelopeFields, token: addressSchema, ... }
 */
export const commonEnvelopeFields = {
  network: networkSchema
    .optional()
    .describe(
      "Override the LUMEN_NETWORK env var for this call. Omit to use server default.",
    ),
  idempotency_key: z
    .string()
    .min(1)
    .max(128)
    .optional()
    .describe(
      "Replay-safe key. If the same key was previously used, the cached receipt is returned with replayed=true and no new transaction is broadcast.",
    ),
} as const;

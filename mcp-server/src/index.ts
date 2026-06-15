#!/usr/bin/env node
/**
 * Lumen MCP server — stdio transport entry point.
 *
 * Wires the server module up to stdio for use with Claude Desktop / Cursor /
 * VS Code / any other MCP client that spawns the server as a child process.
 *
 * IMPORTANT: stdout is reserved for JSON-RPC framing — all logs go to stderr.
 */

import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

import { resolveScriptsDir } from "./paths.js";
import { createLumenMcpServer, SERVER_NAME, SERVER_VERSION } from "./server.js";

async function main(): Promise<void> {
  // Fail fast if the scripts directory cannot be resolved.
  const scriptsDir = resolveScriptsDir();
  process.stderr.write(
    `[${SERVER_NAME}@${SERVER_VERSION}] scripts dir: ${scriptsDir}\n`,
  );

  const server = createLumenMcpServer();
  const transport = new StdioServerTransport();
  await server.connect(transport);

  process.stderr.write(`[${SERVER_NAME}@${SERVER_VERSION}] ready on stdio\n`);

  const shutdown = async (signal: NodeJS.Signals): Promise<void> => {
    process.stderr.write(
      `[${SERVER_NAME}] received ${signal}, shutting down\n`,
    );
    try {
      await server.close();
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      process.stderr.write(`[${SERVER_NAME}] error during close: ${msg}\n`);
    }
    process.exit(0);
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

main().catch((err: unknown) => {
  const msg = err instanceof Error ? err.stack ?? err.message : String(err);
  process.stderr.write(`[${SERVER_NAME}] fatal: ${msg}\n`);
  process.exit(1);
});

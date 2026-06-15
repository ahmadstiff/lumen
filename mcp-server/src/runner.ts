/**
 * Bash-script runner shared by every MCP tool wrapper.
 *
 * Every Lumen capability follows the same I/O contract: read a JSON request
 * envelope from stdin, write a JSON response envelope to stdout, write a
 * human-readable log to stderr. Exit code is 0 on success, non-zero on
 * structured errors.
 *
 * This module hides all of that behind `runCapability(name, request)` and
 * returns a normalized {ok|error} result an MCP tool can return verbatim.
 */

import { spawn } from "node:child_process";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";

import { scriptPathFor } from "./paths.js";

export interface LumenRequest {
  /** Optional Lumen network override. */
  network?: "atlantic" | "pacific";
  /** Optional idempotency key — recommended for any mutation. */
  idempotency_key?: string;
  /** Capability-specific parameters. Required by the Lumen envelope. */
  params: Record<string, unknown>;
}

export interface RunOutcome {
  /** True when stdout contains a parseable envelope AND `status === "ok"`. */
  ok: boolean;
  /** Exit code of the bash script. */
  exitCode: number;
  /** Raw stdout text. */
  stdout: string;
  /** Raw stderr text (Lumen's human log). */
  stderr: string;
  /** Parsed JSON envelope if stdout was valid JSON; undefined otherwise. */
  envelope?: unknown;
  /** When envelope parsing failed, the JSON parse error message. */
  parseError?: string;
}

/**
 * Spawn the bash script for the given capability and feed it the request.
 * The promise resolves whether or not the script succeeded — callers branch
 * on `outcome.ok` and inspect the envelope themselves.
 */
export function runCapability(
  capability: string,
  request: LumenRequest,
  options: { timeoutMs?: number } = {},
): Promise<RunOutcome> {
  const scriptPath = scriptPathFor(capability);
  const requestJson = JSON.stringify(request);
  const timeoutMs = options.timeoutMs ?? 120_000;

  return new Promise((resolve) => {
    const child = spawn("bash", [scriptPath], {
      stdio: ["pipe", "pipe", "pipe"],
      env: process.env,
    });

    let stdout = "";
    let stderr = "";
    let killedByTimeout = false;

    const timer = setTimeout(() => {
      killedByTimeout = true;
      child.kill("SIGTERM");
    }, timeoutMs);

    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk: string) => {
      stderr += chunk;
    });

    child.on("error", (err) => {
      clearTimeout(timer);
      resolve({
        ok: false,
        exitCode: -1,
        stdout,
        stderr: `${stderr}\nspawn error: ${err.message}`,
      });
    });

    child.on("close", (code) => {
      clearTimeout(timer);
      const exitCode = killedByTimeout ? 124 : (code ?? -1);

      let envelope: unknown;
      let parseError: string | undefined;
      const trimmed = stdout.trim();
      if (trimmed.length > 0) {
        try {
          envelope = JSON.parse(trimmed);
        } catch (e) {
          parseError =
            e instanceof Error ? e.message : "unknown JSON parse error";
        }
      }

      const envelopeStatus =
        envelope && typeof envelope === "object" && envelope !== null
          ? (envelope as { status?: unknown }).status
          : undefined;
      const ok = exitCode === 0 && envelopeStatus === "ok";

      resolve({
        ok,
        exitCode,
        stdout,
        stderr: killedByTimeout
          ? `${stderr}\n[mcp] script timed out after ${timeoutMs}ms`
          : stderr,
        envelope,
        parseError,
      });
    });

    // Pipe the request JSON.
    child.stdin.end(requestJson, "utf8");
  });
}

/**
 * Build an MCP `CallToolResult` from a bash script outcome.
 *
 * Successful envelopes are returned as the structured tool result; errors —
 * whether the script wrote an `{status:"error", error:{...}}` payload or
 * died unexpectedly — are surfaced as `isError: true` so the calling agent
 * can self-correct without us hiding details inside a protocol-level error.
 */
export function outcomeToToolResult(
  capability: string,
  outcome: RunOutcome,
): CallToolResult {
  // Happy path: ok envelope.
  if (outcome.ok && outcome.envelope) {
    const text = JSON.stringify(outcome.envelope, null, 2);
    return {
      content: [{ type: "text", text }],
      structuredContent: outcome.envelope as Record<string, unknown>,
    };
  }

  // Structured error envelope.
  if (outcome.envelope) {
    const text = JSON.stringify(outcome.envelope, null, 2);
    return {
      content: [{ type: "text", text }],
      structuredContent: outcome.envelope as Record<string, unknown>,
      isError: true,
    };
  }

  // Script blew up before printing a parseable envelope.
  const details = {
    capability,
    status: "error",
    error: {
      code: outcome.parseError ? "envelope_parse_failed" : "script_failure",
      message: outcome.parseError
        ? `bash script stdout was not valid JSON: ${outcome.parseError}`
        : `bash script exited with code ${outcome.exitCode} and no envelope`,
      details: {
        exit_code: outcome.exitCode,
        stderr_tail: tail(outcome.stderr, 4000),
        stdout_tail: tail(outcome.stdout, 4000),
      },
    },
  };
  return {
    content: [{ type: "text", text: JSON.stringify(details, null, 2) }],
    structuredContent: details,
    isError: true,
  };
}

function tail(s: string, max: number): string {
  if (s.length <= max) return s;
  return `…${s.slice(s.length - max)}`;
}

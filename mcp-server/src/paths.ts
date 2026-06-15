/**
 * Resolve the directory that contains the Lumen capability bash scripts.
 *
 * Priority order:
 *   1. `LUMEN_SCRIPTS_DIR` environment variable (absolute path).
 *   2. `../scripts` relative to the compiled `dist/` directory — the layout
 *      this MCP server lives in when shipped as part of the Lumen repo.
 *
 * Resolving once at import time keeps every tool handler cheap; failures here
 * surface immediately on `connect()` instead of mid-call.
 */

import { existsSync, statSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));

function isDirectory(path: string): boolean {
  try {
    return statSync(path).isDirectory();
  } catch {
    return false;
  }
}

export function resolveScriptsDir(): string {
  const fromEnv = process.env.LUMEN_SCRIPTS_DIR;
  if (fromEnv && fromEnv.length > 0) {
    const abs = resolve(fromEnv);
    if (!isDirectory(abs)) {
      throw new Error(
        `LUMEN_SCRIPTS_DIR=${fromEnv} is not a directory (resolved to ${abs})`,
      );
    }
    return abs;
  }

  // dist/paths.js -> ../scripts (repo-relative default)
  const repoLocal = resolve(here, "..", "..", "scripts");
  if (isDirectory(repoLocal)) {
    return repoLocal;
  }

  // Fallback for `npm run dev` where TS source still lives at src/paths.ts.
  const srcLocal = resolve(here, "..", "scripts");
  if (isDirectory(srcLocal)) {
    return srcLocal;
  }

  throw new Error(
    `Could not locate Lumen scripts/ directory. Set LUMEN_SCRIPTS_DIR. ` +
      `Tried: ${repoLocal}, ${srcLocal}`,
  );
}

/**
 * Map a capability id (e.g. `pay.once`) to its bash script path.
 * Throws if the script does not exist; this lets us fail fast on misconfig.
 */
export function scriptPathFor(capability: string): string {
  const dir = resolveScriptsDir();
  const path = resolve(dir, `${capability}.sh`);
  if (!existsSync(path)) {
    throw new Error(
      `Lumen script missing for capability '${capability}': expected ${path}`,
    );
  }
  return path;
}

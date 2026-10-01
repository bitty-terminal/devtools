/**
 * LuaLS conformance check for the devtools plugin sources.
 *
 * Builds two throwaway workspaces that point LuaLS at the vendored Plugin API
 * v1 definitions (`tests/lua-defs/bitty.d.lua`, SDK `e1723b6`, plus the local
 * `tests/lua-defs/bitty-debug.d.lua` for `bitty.debug`) and
 * runs `lua-language-server --check`:
 *
 * - positive: `lua/devtools/**` must diagnose cleanly, including the
 *   `require("devtools.*")` module tree.
 * - negative: `tests/lua-defs/negative-fixture.lua` must be rejected for
 *   surface excluded from Plugin API v1.
 *
 * The check is skipped with exit 0 when `lua-language-server` is unavailable
 * so CI stays deterministic; `just lua` remains the always-on syntax gate.
 *
 * Usage:
 *
 *   bun tests/check-lua-luals.mjs
 */

import { spawnSync } from "node:child_process";
import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(HERE, "..");
const DEFS_PATH = join(HERE, "lua-defs", "bitty.d.lua");
const DEBUG_DEFS_PATH = join(HERE, "lua-defs", "bitty-debug.d.lua");
const NEGATIVE_FIXTURE = join(HERE, "lua-defs", "negative-fixture.lua");
const CHECK_TIMEOUT_MS = 120_000;

const POSITIVE_CONFIG = {
  runtime: { version: "Lua 5.4", path: ["lua/?.lua", "lua/?/init.lua"] },
  workspace: { library: ["defs"], checkThirdParty: false },
};

const NEGATIVE_CONFIG = {
  runtime: { version: "Lua 5.4" },
  workspace: { library: ["defs"], checkThirdParty: false },
};

const NEGATIVE_EXPECTATIONS = [
  ["undefined-field", "`api`"],
  ["undefined-field", "`on_event`"],
  ["undefined-field", "`control`"],
  ["param-type-mismatch", '"secrets"'],
];

function findLuaLanguageServer() {
  const override = process.env.LUA_LANGUAGE_SERVER;
  if (override !== undefined && override !== "" && existsSync(override)) {
    return override;
  }
  const entries = (process.env.PATH ?? "").split(delimiter);
  for (const entry of entries) {
    if (entry === "") continue;
    const candidate = join(entry, "lua-language-server");
    if (existsSync(candidate)) return candidate;
  }
  return undefined;
}

function writeConfig(workspace, config) {
  writeFileSync(
    join(workspace, ".luarc.json"),
    `${JSON.stringify(config, null, 2)}\n`,
  );
}

function runCheck(binary, workspace) {
  const logPath = join(workspace, "log");
  const proc = spawnSync(
    binary,
    [
      `--check=${workspace}`,
      "--checklevel=Warning",
      "--check_format=json",
      "--locale=en-us",
      `--logpath=${logPath}`,
    ],
    { timeout: CHECK_TIMEOUT_MS, encoding: "utf8" },
  );
  const diagnostics = [];
  const reportPath = join(logPath, "check.json");
  if (existsSync(reportPath)) {
    const report = JSON.parse(readFileSync(reportPath, "utf8"));
    for (const entries of Object.values(report)) {
      for (const entry of entries) {
        diagnostics.push({
          code: entry.code ?? "",
          message: entry.message ?? "",
        });
      }
    }
  }
  return { status: proc.status, diagnostics };
}

function main() {
  const binary = findLuaLanguageServer();
  if (binary === undefined) {
    console.log(
      "skipped: lua-language-server not found on PATH (set LUA_LANGUAGE_SERVER)",
    );
    return 0;
  }

  const temp = mkdtempSync(join(tmpdir(), "devtools-luals-"));
  const problems = [];
  try {
    const positive = join(temp, "positive");
    mkdirSync(join(positive, "defs"), { recursive: true });
    cpSync(join(REPO_ROOT, "lua"), join(positive, "lua"), { recursive: true });
    cpSync(DEFS_PATH, join(positive, "defs", "bitty.d.lua"));
    cpSync(DEBUG_DEFS_PATH, join(positive, "defs", "bitty-debug.d.lua"));
    writeConfig(positive, POSITIVE_CONFIG);

    const positiveResult = runCheck(binary, positive);
    console.log(
      `positive: exit=${positiveResult.status} diagnostics=${positiveResult.diagnostics.length}`,
    );
    if (positiveResult.status !== 0 || positiveResult.diagnostics.length > 0) {
      problems.push("positive workspace must diagnose cleanly");
      for (const entry of positiveResult.diagnostics) {
        problems.push(`  ${entry.code}: ${entry.message.split("\n")[0] ?? ""}`);
      }
    }

    const negative = join(temp, "negative");
    mkdirSync(join(negative, "defs"), { recursive: true });
    cpSync(DEFS_PATH, join(negative, "defs", "bitty.d.lua"));
    cpSync(DEBUG_DEFS_PATH, join(negative, "defs", "bitty-debug.d.lua"));
    cpSync(NEGATIVE_FIXTURE, join(negative, "negative-fixture.lua"));
    writeConfig(negative, NEGATIVE_CONFIG);

    const negativeResult = runCheck(binary, negative);
    console.log(
      `negative: exit=${negativeResult.status} diagnostics=${negativeResult.diagnostics.length}`,
    );
    for (const [code, needle] of NEGATIVE_EXPECTATIONS) {
      const found = negativeResult.diagnostics.some(
        (entry) => entry.code === code && entry.message.includes(needle),
      );
      if (!found) {
        problems.push(`negative workspace missing ${code} for ${needle}`);
      }
    }
    if (negativeResult.status === 0) {
      problems.push("negative workspace must report problems");
    }
  } finally {
    rmSync(temp, { recursive: true, force: true });
  }

  if (problems.length > 0) {
    console.error("LuaLS conformance failed:");
    for (const problem of problems) console.error(`  - ${problem}`);
    return 1;
  }
  console.log("LuaLS conformance passed");
  return 0;
}

process.exit(main());

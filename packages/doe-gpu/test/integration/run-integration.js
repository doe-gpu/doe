#!/usr/bin/env node

import { execFile } from "node:child_process";
import { readdir } from "node:fs/promises";
import { dirname, extname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const VALID_EXTENSIONS = new Set([".js"]);
const ENTRYPOINT_PREFIX = "test-integration-";
const RUNTIME_NODE = "node";
const RUNTIME_BUN = "bun";
const RUNTIME_DENO = "deno";

function parseArgs(argv) {
  const options = {
    runtime: RUNTIME_NODE,
    list: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--list") {
      options.list = true;
      continue;
    }
    if (arg === "--runtime") {
      const value = argv[index + 1];
      if (!value) {
        throw new Error("--runtime requires a value");
      }
      options.runtime = value;
      index += 1;
      continue;
    }
    throw new Error(`Unknown argument: ${arg}`);
  }

  if (![RUNTIME_NODE, RUNTIME_BUN, RUNTIME_DENO].includes(options.runtime)) {
    throw new Error(`Unsupported runtime: ${options.runtime}`);
  }

  return options;
}

function classifyEntrypoint(fileName) {
  if (/-deno(?:[.-]|$)/.test(fileName)) {
    return RUNTIME_DENO;
  }
  if (/-bun(?:[.-]|$)/.test(fileName)) {
    return RUNTIME_BUN;
  }
  return RUNTIME_NODE;
}

function shouldRunEntrypoint(fileName, runtime) {
  const extension = extname(fileName);
  if (!VALID_EXTENSIONS.has(extension)) {
    return false;
  }
  if (!fileName.startsWith(ENTRYPOINT_PREFIX)) {
    return false;
  }
  return classifyEntrypoint(fileName) === runtime;
}

async function discoverEntrypoints(runtime) {
  const entries = await readdir(__dirname, { withFileTypes: true });
  return entries
    .filter((entry) => entry.isFile())
    .map((entry) => entry.name)
    .filter((fileName) => shouldRunEntrypoint(fileName, runtime))
    .sort();
}

function runtimeInvocation(runtime, filePath) {
  if (runtime === RUNTIME_BUN) {
    return {
      command: typeof Bun !== "undefined" ? process.execPath : "bun",
      args: [filePath],
    };
  }
  if (runtime === RUNTIME_DENO) {
    return {
      command: typeof Deno !== "undefined" ? Deno.execPath() : "deno",
      args: ["run", "--allow-all", filePath],
    };
  }
  return { command: process.execPath, args: [filePath] };
}

function runEntrypoint(command, args, filePath) {
  return new Promise((resolve) => {
    execFile(command, args, (error, stdout, stderr) => {
      resolve({
        filePath,
        code: error?.code ?? 0,
        signal: error?.signal ?? null,
        stdout: stdout ?? "",
        stderr: stderr ?? "",
      });
    });
  });
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const entrypoints = await discoverEntrypoints(options.runtime);

  if (entrypoints.length === 0) {
    throw new Error(`No integration entrypoints found for runtime ${options.runtime}`);
  }

  if (options.list) {
    for (const fileName of entrypoints) {
      process.stdout.write(`${fileName}\n`);
    }
    return;
  }

  let failed = 0;

  for (const fileName of entrypoints) {
    const filePath = join(__dirname, fileName);
    const invocation = runtimeInvocation(options.runtime, filePath);
    process.stdout.write(`\n=== ${options.runtime} integration: ${fileName} ===\n`);
    const result = await runEntrypoint(invocation.command, invocation.args, filePath);
    if (result.stdout) {
      process.stdout.write(result.stdout);
      if (!result.stdout.endsWith("\n")) {
        process.stdout.write("\n");
      }
    }
    if (result.stderr) {
      process.stderr.write(result.stderr);
      if (!result.stderr.endsWith("\n")) {
        process.stderr.write("\n");
      }
    }
    if (result.code !== 0) {
      failed += 1;
      process.stderr.write(
        `FAIL: ${fileName} exited with code ${result.code}${result.signal ? ` (${result.signal})` : ""}\n`
      );
    }
  }

  if (failed > 0) {
    process.exitCode = 1;
  }
}

main().catch((error) => {
  process.stderr.write(`Fatal: ${error.message}\n`);
  process.exit(1);
});

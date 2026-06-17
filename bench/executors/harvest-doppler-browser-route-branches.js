#!/usr/bin/env node

import { createHash } from "node:crypto";
import http from "node:http";
import { createReadStream, existsSync } from "node:fs";
import { mkdir, readFile, stat } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";

import { collectDopplerBrowserIdentity } from "./doppler-identity.js";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(SCRIPT_DIR, "..", "..");
const DEFAULT_MODEL_MOUNT = "/__doe_probe_model";
const DEFAULT_BROWSER_CHANNEL = "chromium";
const DEFAULT_TIMEOUT_MS = 180_000;
const DEFAULT_REPEAT_ISOLATION = "new-page";
const REPEAT_ISOLATION_OPTIONS = new Set(["reuse-page", "new-page", "new-browser"]);
const MIME_BY_EXTENSION = Object.freeze({
  ".bin": "application/octet-stream",
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".ico": "image/x-icon",
  ".jpeg": "image/jpeg",
  ".jpg": "image/jpeg",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".map": "application/json; charset=utf-8",
  ".md": "text/plain; charset=utf-8",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".txt": "text/plain; charset=utf-8",
  ".wasm": "application/wasm",
  ".wgsl": "text/plain; charset=utf-8",
});

function usage() {
  console.log(`Usage:
  node bench/executors/harvest-doppler-browser-route-branches.js --config <path>

Config contract:
  {
    "dopplerRepoPath": "/abs/path/to/doppler",
    "modelArtifactPath": "/abs/path/to/model-dir",
    "modelId": "gemma-3-270m-it-q4k-ehf16-af32",
    "outputDir": "/abs/path/to/output-dir",
    "repeatCount": 3,
    "continuationSteps": 6,
    "topK": 8,
    "useChatTemplate": false,
    "runtimeConfig": { ... },
    "browser": {
      "headless": true,
      "channel": "chromium",
      "timeoutMs": 180000,
      "repeatIsolation": "new-page"
    },
    "promptId": "pool-safe-unsafe",
    "promptText": "Leaving a toddler alone near a pool is safe or unsafe. It is",
    "routeSpecs": [
      {
        "id": "raw",
        "seedCurrentIds": [1, 2, 3],
        "seedToken": 4
      }
    ]
  }`);
}

function parseArgs(argv) {
  let configPath = null;
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === "--help") {
      usage();
      process.exit(0);
    }
    if (token === "--config") {
      configPath = argv[index + 1] ?? null;
      index += 1;
      continue;
    }
    throw new Error(`Unknown flag: ${token}`);
  }
  if (!configPath) {
    throw new Error("--config is required");
  }
  return { configPath };
}

function resolvePath(value, label) {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new Error(`${label} must be a non-empty string path`);
  }
  return path.resolve(value);
}

function asPositiveInt(value, label, defaultValue) {
  if (value === undefined || value === null) return defaultValue;
  const normalized = Number.parseInt(String(value), 10);
  if (!Number.isFinite(normalized) || normalized <= 0) {
    throw new Error(`${label} must be a positive integer`);
  }
  return normalized;
}

function asBoolean(value, defaultValue) {
  if (value === undefined || value === null) return defaultValue;
  if (typeof value === "boolean") return value;
  if (value === "true") return true;
  if (value === "false") return false;
  throw new Error(`Expected boolean value, got ${JSON.stringify(value)}`);
}

function ensureRouteSpecShape(routeSpec, index) {
  if (!routeSpec || typeof routeSpec !== "object" || Array.isArray(routeSpec)) {
    throw new Error(`config.routeSpecs[${index}] must be an object`);
  }
  if (typeof routeSpec.id !== "string" || routeSpec.id.trim().length === 0) {
    throw new Error(`config.routeSpecs[${index}].id must be a non-empty string`);
  }
  if (!Array.isArray(routeSpec.seedCurrentIds) || routeSpec.seedCurrentIds.length === 0) {
    throw new Error(`config.routeSpecs[${index}].seedCurrentIds must be a non-empty array`);
  }
  for (const token of routeSpec.seedCurrentIds) {
    if (!Number.isInteger(token) || token < 0) {
      throw new Error(`config.routeSpecs[${index}].seedCurrentIds must contain non-negative integers`);
    }
  }
  if (!Number.isInteger(routeSpec.seedToken) || routeSpec.seedToken < 0) {
    throw new Error(`config.routeSpecs[${index}].seedToken must be a non-negative integer`);
  }
}

function ensureConfigShape(config) {
  if (!config || typeof config !== "object" || Array.isArray(config)) {
    throw new Error("config must be a JSON object");
  }
  for (const field of ["dopplerRepoPath", "modelArtifactPath", "modelId", "outputDir"]) {
    if (typeof config[field] !== "string" || config[field].trim().length === 0) {
      throw new Error(`config.${field} must be a non-empty string`);
    }
  }
  if (!Array.isArray(config.routeSpecs) || config.routeSpecs.length === 0) {
    throw new Error("config.routeSpecs must be a non-empty array");
  }
  for (const [index, routeSpec] of config.routeSpecs.entries()) {
    ensureRouteSpecShape(routeSpec, index);
  }
}

function createHasher() {
  return createHash("sha256");
}

function sha256Hex(bytes) {
  return createHasher().update(bytes).digest("hex");
}

function relativeOrAbsolute(targetPath) {
  const absolute = path.resolve(targetPath);
  if (absolute === REPO_ROOT || absolute.startsWith(`${REPO_ROOT}${path.sep}`)) {
    return path.relative(REPO_ROOT, absolute);
  }
  return absolute;
}

function contentTypeFor(filePath) {
  return MIME_BY_EXTENSION[path.extname(filePath).toLowerCase()] || "application/octet-stream";
}

function resolveStaticPath(rootDir, requestPath) {
  let decodedPath = "/";
  try {
    decodedPath = decodeURIComponent(requestPath || "/");
  } catch {
    return null;
  }
  const normalizedPath = decodedPath.replace(/^\/+/, "");
  const candidate = path.resolve(rootDir, normalizedPath || "index.html");
  const normalizedRoot = path.resolve(rootDir);
  if (candidate !== normalizedRoot && !candidate.startsWith(`${normalizedRoot}${path.sep}`)) {
    return null;
  }
  return candidate;
}

async function resolveFileForRequest(rootDir, mounts, requestPath) {
  const normalizedPath = String(requestPath || "/");
  let effectiveRoot = rootDir;
  let effectivePath = normalizedPath;
  for (const mount of mounts) {
    if (normalizedPath === mount.urlPrefix || normalizedPath.startsWith(`${mount.urlPrefix}/`)) {
      effectiveRoot = mount.rootDir;
      effectivePath = normalizedPath.slice(mount.urlPrefix.length) || "/";
      break;
    }
  }
  const resolved = resolveStaticPath(effectiveRoot, effectivePath);
  if (!resolved) return null;
  let stats;
  try {
    stats = await stat(resolved);
  } catch {
    return null;
  }
  if (stats.isDirectory()) {
    const indexPath = path.join(resolved, "index.html");
    try {
      const indexStats = await stat(indexPath);
      if (indexStats.isFile()) {
        return { filePath: indexPath, size: indexStats.size };
      }
    } catch {
      return null;
    }
    return null;
  }
  if (!stats.isFile()) return null;
  return { filePath: resolved, size: stats.size };
}

async function createStaticServer(rootDir, mounts) {
  const server = http.createServer(async (req, res) => {
    const method = req.method || "GET";
    if (method !== "GET" && method !== "HEAD") {
      res.statusCode = 405;
      res.end("Method Not Allowed");
      return;
    }
    let pathname = "/";
    try {
      const url = new URL(req.url || "/", "http://127.0.0.1");
      pathname = url.pathname || "/";
    } catch {
      res.statusCode = 400;
      res.end("Bad Request");
      return;
    }
    const resolved = await resolveFileForRequest(rootDir, mounts, pathname);
    if (!resolved) {
      res.statusCode = 404;
      res.end("File not found");
      return;
    }
    res.statusCode = 200;
    res.setHeader("Content-Type", contentTypeFor(resolved.filePath));
    res.setHeader("Content-Length", resolved.size);
    res.setHeader("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0");
    if (method === "HEAD") {
      res.end();
      return;
    }
    const stream = createReadStream(resolved.filePath, {
      highWaterMark: resolved.size > 1024 * 1024 ? 1024 * 1024 : undefined,
    });
    stream.on("error", () => {
      if (!res.headersSent) {
        res.statusCode = 500;
      }
      res.end();
    });
    stream.pipe(res);
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  if (!address || typeof address === "string") {
    server.close();
    throw new Error("Failed to bind static server");
  }
  return {
    server,
    baseUrl: `http://127.0.0.1:${address.port}`,
    async close() {
      await new Promise((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
    },
  };
}

function resolvePlaywrightEntry(dopplerRepoPath) {
  const require = createRequire(import.meta.url);
  const candidateSearchRoots = [
    path.resolve(REPO_ROOT, "browser/chromium/node_modules"),
    path.resolve(REPO_ROOT, "browser/chromium_webgpu_lane/node_modules"),
    path.resolve(dopplerRepoPath, "node_modules"),
  ];
  for (const moduleName of ["playwright-core", "playwright"]) {
    for (const searchRoot of candidateSearchRoots) {
      if (!existsSync(searchRoot)) continue;
      try {
        return require.resolve(moduleName, { paths: [searchRoot] });
      } catch {
        // Try the next root.
      }
    }
  }
  throw new Error(
    "Could not resolve Playwright. Run npm --prefix browser/chromium ci or install playwright under ../doppler."
  );
}

async function loadPlaywright(dopplerRepoPath) {
  const entryPath = resolvePlaywrightEntry(dopplerRepoPath);
  return import(pathToFileURL(entryPath).href);
}

async function withTimeout(promise, timeoutMs, label) {
  let timeoutId = null;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timeoutId = setTimeout(() => reject(new Error(`${label} timed out after ${timeoutMs}ms`)), timeoutMs);
      }),
    ]);
  } finally {
    if (timeoutId !== null) {
      clearTimeout(timeoutId);
    }
  }
}

function buildLaunchOptions(config) {
  const browserConfig = config.browser && typeof config.browser === "object" ? config.browser : {};
  const launchOptions = {
    headless: asBoolean(browserConfig.headless, true),
  };
  if (typeof browserConfig.channel === "string" && browserConfig.channel.trim().length > 0) {
    launchOptions.channel = browserConfig.channel.trim();
  } else {
    launchOptions.channel = DEFAULT_BROWSER_CHANNEL;
  }
  if (typeof browserConfig.executablePath === "string" && browserConfig.executablePath.trim().length > 0) {
    launchOptions.executablePath = browserConfig.executablePath.trim();
    delete launchOptions.channel;
  }
  if (Array.isArray(browserConfig.args) && browserConfig.args.length > 0) {
    launchOptions.args = browserConfig.args.map((entry) => String(entry));
  }
  return launchOptions;
}

function browserTimeoutMs(config) {
  const browserConfig = config.browser && typeof config.browser === "object" ? config.browser : {};
  return asPositiveInt(browserConfig.timeoutMs, "browser.timeoutMs", DEFAULT_TIMEOUT_MS);
}

function browserRepeatIsolation(config) {
  const browserConfig = config.browser && typeof config.browser === "object" ? config.browser : {};
  const isolation = typeof browserConfig.repeatIsolation === "string"
    ? browserConfig.repeatIsolation.trim()
    : DEFAULT_REPEAT_ISOLATION;
  if (!REPEAT_ISOLATION_OPTIONS.has(isolation)) {
    throw new Error(
      `browser.repeatIsolation must be one of ${Array.from(REPEAT_ISOLATION_OPTIONS).join(", ")}`
    );
  }
  return isolation;
}

async function createProbePage(browser, baseUrl, timeoutMs) {
  const page = await browser.newPage();
  await withTimeout(
    page.goto(`${baseUrl}/tests/harness.html`, { waitUntil: "domcontentloaded" }),
    timeoutMs,
    "page load"
  );
  return page;
}

async function harvestRepeat(page, spec, timeoutMs) {
  return withTimeout(
    page.evaluate(
      async (runSpec) => {
        function insertTopEntry(entries, candidate, limit) {
          let inserted = false;
          for (let index = 0; index < entries.length; index += 1) {
            if (candidate.logit > entries[index].logit) {
              entries.splice(index, 0, candidate);
              inserted = true;
              break;
            }
          }
          if (!inserted) {
            entries.push(candidate);
          }
          if (entries.length > limit) {
            entries.length = limit;
          }
        }

        function hexFromBytes(bytes) {
          return Array.from(bytes).map((value) => value.toString(16).padStart(2, "0")).join("");
        }

        function decodeTokenText(tokenizer, tokenId) {
          if (!tokenizer || typeof tokenizer.decode !== "function") {
            return null;
          }
          try {
            return tokenizer.decode([tokenId], false, false);
          } catch {
            return null;
          }
        }

        function arraysEqual(left, right) {
          if (left.length !== right.length) return false;
          for (let index = 0; index < left.length; index += 1) {
            if (left[index] !== right[index]) return false;
          }
          return true;
        }

        async function summarizeLogits(logits, summary, tokenizer) {
          const topEntries = [];
          let maxLogit = -Infinity;
          let maxToken = 0;
          let exactMaxTieCount = 0;
          for (let index = 0; index < logits.length; index += 1) {
            const logit = logits[index];
            if (logit > maxLogit) {
              maxLogit = logit;
              maxToken = index;
              exactMaxTieCount = 1;
            } else if (logit === maxLogit) {
              exactMaxTieCount += 1;
            }
            insertTopEntry(topEntries, { token: index, logit }, summary.topK);
          }
          const bytes = new Uint8Array(logits.buffer, logits.byteOffset, logits.byteLength);
          const digest = await crypto.subtle.digest("SHA-256", bytes);
          return {
            logitCount: logits.length,
            logitsByteLength: bytes.byteLength,
            logitsSha256: hexFromBytes(new Uint8Array(digest)),
            greedyToken: maxToken,
            greedyLogit: maxLogit,
            greedyTokenText: decodeTokenText(tokenizer, maxToken),
            exactMaxTieCount,
            top2Gap: topEntries.length >= 2 ? topEntries[0].logit - topEntries[1].logit : null,
            topCandidates: topEntries.map((entry) => ({
              ...entry,
              tokenText: decodeTokenText(tokenizer, entry.token),
            })),
          };
        }

        const adapter = await navigator.gpu.requestAdapter();
        const adapterInfo = await adapter?.requestAdapterInfo?.().catch(() => null);
        const [{ doppler }, { initTokenizerFromManifest }] = await Promise.all([
          import("/src/index.js"),
          import("/src/generation/index.js"),
        ]);
        const repeatStart = performance.now();
        let tokenizer = null;
        const routeResults = [];
        for (const routeSpec of runSpec.routeSpecs) {
          const model = await doppler.load(
            { url: runSpec.modelUrl },
            { runtimeConfig: runSpec.runtimeConfig },
          );
          try {
            tokenizer ??= await initTokenizerFromManifest(model.manifest, runSpec.modelUrl);
            const prefill = await model.advanced.prefillWithLogits(runSpec.promptText, {
              useChatTemplate: runSpec.useChatTemplate,
            });
            const promptTokenIds = Array.from(prefill.tokens);
            const seedCurrentIds = Array.from(routeSpec.seedCurrentIds);
            if (seedCurrentIds.length < promptTokenIds.length) {
              throw new Error(`route ${routeSpec.id} seedCurrentIds shorter than prompt tokenization`);
            }
            if (!arraysEqual(seedCurrentIds.slice(0, promptTokenIds.length), promptTokenIds)) {
              throw new Error(`route ${routeSpec.id} seedCurrentIds do not match prompt tokenization`);
            }
            const decodePrefixTokenIds = seedCurrentIds.slice(promptTokenIds.length);
            let replayedCurrentIds = [...promptTokenIds];
            for (const prefixToken of decodePrefixTokenIds) {
              replayedCurrentIds = [...replayedCurrentIds, prefixToken];
              await model.advanced.decodeStepLogits(replayedCurrentIds, {
                useChatTemplate: runSpec.useChatTemplate,
              });
            }
            let currentIds = [...replayedCurrentIds, routeSpec.seedToken];
            const continuationSteps = [];
            const continuationTokenIds = [];
            for (let decodeIndex = 0; decodeIndex < runSpec.continuationSteps; decodeIndex += 1) {
              const step = await model.advanced.decodeStepLogits(currentIds, {
                useChatTemplate: runSpec.useChatTemplate,
              });
              const stepSummary = await summarizeLogits(step.logits, runSpec, tokenizer);
              continuationSteps.push({
                phase: "decode",
                stepIndex: decodeIndex + 1,
                currentIdsLength: currentIds.length,
                inputToken: currentIds[currentIds.length - 1],
                ...stepSummary,
              });
              continuationTokenIds.push(stepSummary.greedyToken);
              currentIds = [...currentIds, stepSummary.greedyToken];
            }
            const tailTokenIds = [routeSpec.seedToken, ...continuationTokenIds];
            routeResults.push({
              id: routeSpec.id,
              promptTokenIds,
              seedCurrentIds,
              decodePrefixTokenIds,
              seedToken: routeSpec.seedToken,
              seedTokenText: decodeTokenText(tokenizer, routeSpec.seedToken),
              continuationTokenIds,
              continuationTokenTexts: continuationTokenIds.map((token) => decodeTokenText(tokenizer, token)),
              decodedTailText: decodeTokenText(tokenizer, routeSpec.seedToken) == null
                ? null
                : tokenizer.decode(tailTokenIds, false, false),
              finalCurrentIds: currentIds,
              continuationSteps,
            });
          } finally {
            await model.unload();
          }
        }
        return {
          browserUserAgent: navigator.userAgent,
          adapterInfo,
          repeatIndex: runSpec.repeatIndex,
          elapsedMs: performance.now() - repeatStart,
          routeResults,
        };
      },
      spec
    ),
    timeoutMs,
    `browser route branch repeat ${spec.repeatIndex}`
  );
}

async function runProbe(config) {
  const dopplerRepoPath = resolvePath(config.dopplerRepoPath, "dopplerRepoPath");
  const modelArtifactPath = resolvePath(config.modelArtifactPath, "modelArtifactPath");
  const outputDir = resolvePath(config.outputDir, "outputDir");
  const internalDopplerIdentity = await collectDopplerBrowserIdentity(config, {
    modelArtifactPath,
  });
  await mkdir(outputDir, { recursive: true });
  const repeatCount = asPositiveInt(config.repeatCount, "repeatCount", 1);
  const continuationSteps = asPositiveInt(config.continuationSteps, "continuationSteps", 1);
  const topK = asPositiveInt(config.topK, "topK", 8);
  const useChatTemplate = asBoolean(config.useChatTemplate, false);
  const repeatIsolation = browserRepeatIsolation(config);
  const mounts = [{ urlPrefix: DEFAULT_MODEL_MOUNT, rootDir: modelArtifactPath }];
  const staticServer = await createStaticServer(dopplerRepoPath, mounts);
  const timeoutMs = browserTimeoutMs(config);
  let browser = null;
  try {
    const playwright = await loadPlaywright(dopplerRepoPath);
    const browserType = playwright.chromium ?? playwright.default?.chromium;
    if (!browserType) {
      throw new Error("Resolved Playwright package does not expose chromium");
    }
    const launchOptions = buildLaunchOptions(config);
    const runSpec = {
      modelUrl: DEFAULT_MODEL_MOUNT,
      runtimeConfig: config.runtimeConfig ?? {},
      promptId: config.promptId ?? null,
      promptText: config.promptText ?? null,
      routeSpecs: config.routeSpecs,
      continuationSteps,
      topK,
      useChatTemplate,
    };
    const runs = [];
    let browserUserAgent = null;
    let adapterInfo = null;
    let sharedPage = null;
    if (repeatIsolation !== "new-browser") {
      browser = await withTimeout(browserType.launch(launchOptions), timeoutMs, "browser launch");
      if (repeatIsolation === "reuse-page") {
        sharedPage = await createProbePage(browser, staticServer.baseUrl, timeoutMs);
      }
    }
    for (let repeatIndex = 0; repeatIndex < repeatCount; repeatIndex += 1) {
      let repeatBrowser = browser;
      let repeatPage = sharedPage;
      let ownsBrowser = false;
      let ownsPage = false;
      try {
        if (repeatIsolation === "new-browser") {
          repeatBrowser = await withTimeout(browserType.launch(launchOptions), timeoutMs, "browser launch");
          ownsBrowser = true;
        }
        if (!repeatPage) {
          repeatPage = await createProbePage(repeatBrowser, staticServer.baseUrl, timeoutMs);
          ownsPage = repeatIsolation !== "reuse-page";
        }
        const repeatResult = await harvestRepeat(
          repeatPage,
          {
            ...runSpec,
            repeatIndex,
          },
          timeoutMs
        );
        browserUserAgent ??= repeatResult.browserUserAgent;
        adapterInfo ??= repeatResult.adapterInfo;
        runs.push({
          repeatIndex: repeatResult.repeatIndex,
          elapsedMs: repeatResult.elapsedMs,
          routeResults: repeatResult.routeResults,
        });
      } finally {
        if (ownsPage && repeatPage) {
          await repeatPage.close().catch(() => {});
        }
        if (ownsBrowser && repeatBrowser) {
          await repeatBrowser.close().catch(() => {});
        }
      }
    }
    return {
      schemaVersion: 1,
      source: "doppler-browser-route-branches",
      modelId: internalDopplerIdentity.modelId ?? null,
      dopplerRepoPath: relativeOrAbsolute(dopplerRepoPath),
      modelArtifactPath: relativeOrAbsolute(modelArtifactPath),
      staticModelUrl: DEFAULT_MODEL_MOUNT,
      repeatCount,
      continuationSteps,
      topK,
      useChatTemplate,
      promptId: config.promptId ?? null,
      promptText: config.promptText ?? null,
      browser: {
        repeatIsolation,
        routeModelIsolation: "per-route-model",
        ...buildLaunchOptions(config),
      },
      runtimeConfig: config.runtimeConfig ?? {},
      browserUserAgent,
      adapterInfo,
      runs,
    };
  } finally {
    if (browser && typeof browser.contexts === "function") {
      for (const context of browser.contexts()) {
        for (const page of context.pages()) {
          await page.close().catch(() => {});
        }
      }
    }
    if (browser) {
      await browser.close().catch(() => {});
    }
    await staticServer.close().catch(() => {});
  }
}

async function main() {
  const { configPath } = parseArgs(process.argv.slice(2));
  const rawConfig = JSON.parse(await readFile(configPath, "utf8"));
  ensureConfigShape(rawConfig);
  const result = await runProbe(rawConfig);
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

main().catch((error) => {
  process.stderr.write(`${String(error?.stack ?? error)}\n`);
  process.exitCode = 1;
});

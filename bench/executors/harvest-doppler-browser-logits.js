#!/usr/bin/env node

import { createHash } from "node:crypto";
import http from "node:http";
import { createReadStream, existsSync } from "node:fs";
import { mkdir, readFile, stat, writeFile } from "node:fs/promises";
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
const DEFAULT_REPEAT_ISOLATION = "reuse-page";
const DEFAULT_PERSIST_LOGITS_PROMPT_CHUNK_SIZE = 15;
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
  node bench/executors/harvest-doppler-browser-logits.js --config <path>

Config contract:
  {
    "dopplerRepoPath": "/abs/path/to/doppler",
    "modelArtifactPath": "/abs/path/to/model-dir",
    "modelId": "gemma-3-270m-it-q4k-ehf16-af32",
    "outputDir": "/abs/path/to/output-dir",
    "repeatCount": 3,
    "decodeSteps": 1,
    "topK": 5,
    "persistLogits": false,
    "capturePrefillEmbedding": false,
    "prefillEmbeddingMode": "last",
    "useChatTemplate": false,
    "runtimeConfig": { ... },
    "browser": {
      "headless": true,
      "channel": "chromium",
      "executablePath": null,
      "timeoutMs": 180000,
      "repeatIsolation": "reuse-page"
    },
    "promptCandidates": [
      { "id": "sky-blue", "text": "The sky is blue", "decodeSteps": 1 }
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

function ensureConfigShape(config) {
  if (!config || typeof config !== "object" || Array.isArray(config)) {
    throw new Error("config must be a JSON object");
  }
  if (!Array.isArray(config.promptCandidates) || config.promptCandidates.length === 0) {
    throw new Error("config.promptCandidates must be a non-empty array");
  }
  for (const [index, prompt] of config.promptCandidates.entries()) {
    if (!prompt || typeof prompt !== "object" || Array.isArray(prompt)) {
      throw new Error(`config.promptCandidates[${index}] must be an object`);
    }
    if (typeof prompt.text !== "string" || prompt.text.length === 0) {
      throw new Error(`config.promptCandidates[${index}].text must be a non-empty string`);
    }
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

function sanitizeId(value, fallback) {
  const raw = typeof value === "string" && value.trim().length > 0 ? value.trim() : fallback;
  return raw.replace(/[^a-zA-Z0-9_-]+/g, "-").replace(/^-+|-+$/g, "") || fallback;
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

async function persistArtifacts(result, outputDir) {
  if (!result.persistLogits && !result.capturePrefillEmbedding) {
    return result;
  }
  const logitsDir = path.join(outputDir, "logits");
  const embeddingsDir = path.join(outputDir, "embeddings");
  await mkdir(logitsDir, { recursive: true });
  if (result.capturePrefillEmbedding) {
    await mkdir(embeddingsDir, { recursive: true });
  }
  for (const run of result.runs) {
    for (const prompt of run.promptResults) {
      if (prompt.status !== "ok") continue;
      const promptId = sanitizeId(prompt.id, `prompt-${String(prompt.promptIndex).padStart(3, "0")}`);
      if (result.capturePrefillEmbedding) {
        const embedding = prompt.prefillEmbedding;
        if (embedding && typeof embedding.embeddingBase64 === "string" && embedding.embeddingBase64.length > 0) {
          const fileName = `${promptId}.run${String(run.repeatIndex).padStart(3, "0")}.prefill.embedding.f32.bin`;
          const filePath = path.join(embeddingsDir, fileName);
          const payload = Buffer.from(embedding.embeddingBase64, "base64");
          const digest = sha256Hex(payload);
          await writeFile(filePath, payload);
          if (digest !== embedding.embeddingSha256) {
            throw new Error(`Persisted embedding digest mismatch for ${fileName}`);
          }
          embedding.embeddingArtifactPath = relativeOrAbsolute(filePath);
          delete embedding.embeddingBase64;
        }
      }
      for (const step of prompt.steps) {
        if (typeof step.logitsBase64 !== "string" || step.logitsBase64.length === 0) continue;
        const phaseId = step.phase === "prefill" ? "prefill" : `decode-${step.stepIndex}`;
        const fileName = `${promptId}.run${String(run.repeatIndex).padStart(3, "0")}.${phaseId}.logits.bin`;
        const filePath = path.join(logitsDir, fileName);
        const payload = Buffer.from(step.logitsBase64, "base64");
        const digest = sha256Hex(payload);
        await writeFile(filePath, payload);
        if (digest !== step.logitsSha256) {
          throw new Error(`Persisted logits digest mismatch for ${fileName}`);
        }
        step.logitsArtifactPath = relativeOrAbsolute(filePath);
        delete step.logitsBase64;
      }
    }
  }
  return result;
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

        function bytesToBase64(bytes) {
          let text = "";
          const chunkSize = 0x8000;
          for (let offset = 0; offset < bytes.length; offset += chunkSize) {
            const chunk = bytes.subarray(offset, offset + chunkSize);
            text += String.fromCharCode(...chunk);
          }
          return btoa(text);
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

        async function summarizeEmbedding(embedding, embeddingMode) {
          if (!(embedding instanceof Float32Array)) {
            throw new Error(`Expected Float32Array embedding, got ${embedding?.constructor?.name ?? typeof embedding}`);
          }
          const bytes = new Uint8Array(embedding.buffer, embedding.byteOffset, embedding.byteLength);
          const digest = await crypto.subtle.digest("SHA-256", bytes);
          return {
            embeddingMode,
            embeddingFloatCount: embedding.length,
            embeddingByteLength: bytes.byteLength,
            embeddingSha256: hexFromBytes(new Uint8Array(digest)),
            embeddingBase64: bytesToBase64(bytes),
          };
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
            logitsBase64: summary.persistLogits ? bytesToBase64(bytes) : null,
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

        function resolveTokenTexts(tokenizer, tokenTexts) {
          const resolved = {};
          for (const tokenText of tokenTexts || []) {
            try {
              const tokenIds = Array.from(tokenizer.encode(tokenText));
              resolved[tokenText] = {
                tokenText,
                tokenIds,
                singleToken: tokenIds.length === 1,
                tokenId: tokenIds.length === 1 ? tokenIds[0] : null,
                decodedTokenText: tokenIds.length === 1 ? decodeTokenText(tokenizer, tokenIds[0]) : null,
              };
            } catch (error) {
              resolved[tokenText] = {
                tokenText,
                tokenIds: [],
                singleToken: false,
                tokenId: null,
                decodedTokenText: null,
                error: String(error?.message ?? error),
              };
            }
          }
          return resolved;
        }

        const adapter = await navigator.gpu.requestAdapter();
        const adapterInfo = await adapter?.requestAdapterInfo?.().catch(() => null);
        const [{ doppler }, { createPipeline, initTokenizerFromManifest }, { parseManifest }] = await Promise.all([
          import("/src/index.js"),
          import("/src/generation/index.js"),
          import("/src/formats/rdrr/index.js"),
        ]);
        const repeatStart = performance.now();
        let runtime = null;
        let tokenizer = null;
        let manifest = null;
        let pipeline = null;
        if (runSpec.capturePrefillEmbedding) {
          const manifestResponse = await fetch(`${runSpec.modelUrl}/manifest.json`);
          if (!manifestResponse.ok) {
            throw new Error(`Failed to fetch manifest from ${runSpec.modelUrl}: ${manifestResponse.status}`);
          }
          manifest = parseManifest(await manifestResponse.text());
          if (manifest?.inference?.output?.embeddingPostprocessor) {
            throw new Error("capturePrefillEmbedding requires output.embeddingPostprocessor to be disabled.");
          }
          pipeline = await createPipeline(manifest, {
            baseUrl: runSpec.modelUrl,
            runtimeConfig: runSpec.runtimeConfig,
          });
          runtime = pipeline;
          tokenizer = pipeline.tokenizer ?? await initTokenizerFromManifest(manifest, runSpec.modelUrl);
        } else {
          runtime = await doppler.load(
            { url: runSpec.modelUrl },
            { runtimeConfig: runSpec.runtimeConfig },
          );
          manifest = runtime.manifest;
          tokenizer = await initTokenizerFromManifest(runtime.manifest, runSpec.modelUrl);
        }
        const resolvedTokens = resolveTokenTexts(tokenizer, runSpec.tokenTextsToResolve);
        const promptResults = [];
        try {
          for (let promptIndex = 0; promptIndex < runSpec.promptCandidates.length; promptIndex += 1) {
            const prompt = runSpec.promptCandidates[promptIndex];
            const promptDecodeSteps = Number.isFinite(prompt.decodeSteps)
              ? Math.max(0, Math.floor(prompt.decodeSteps))
              : runSpec.decodeSteps;
            try {
              let prefillEmbeddingSummary = null;
              let embeddingPromptTokenIds = null;
              if (runSpec.capturePrefillEmbedding) {
                pipeline.reset();
                const prefillEmbedding = await pipeline.prefillWithEmbedding(prompt.text, {
                  useChatTemplate: runSpec.useChatTemplate,
                  embeddingMode: runSpec.prefillEmbeddingMode,
                });
                embeddingPromptTokenIds = Array.from(prefillEmbedding.tokens);
                prefillEmbeddingSummary = await summarizeEmbedding(
                  prefillEmbedding.embedding,
                  prefillEmbedding.embeddingMode ?? runSpec.prefillEmbeddingMode,
                );
              }
              if (pipeline) {
                pipeline.reset();
              }
              const prefill = pipeline
                ? await pipeline.prefillWithLogits(prompt.text, {
                  useChatTemplate: runSpec.useChatTemplate,
                })
                : await runtime.advanced.prefillWithLogits(prompt.text, {
                  useChatTemplate: runSpec.useChatTemplate,
                });
              const promptTokenIds = Array.from(prefill.tokens);
              if (embeddingPromptTokenIds) {
                const sameLength = embeddingPromptTokenIds.length === promptTokenIds.length;
                const sameIds = sameLength && embeddingPromptTokenIds.every((value, index) => value === promptTokenIds[index]);
                if (!sameIds) {
                  throw new Error("prefillWithEmbedding tokenIds differed from prefillWithLogits tokenIds");
                }
              }
              const steps = [];
              const prefillSummary = await summarizeLogits(prefill.logits, runSpec, tokenizer);
              steps.push({
                phase: "prefill",
                stepIndex: 0,
                promptTokenCount: promptTokenIds.length,
                currentIdsLength: promptTokenIds.length,
                inputToken: null,
                ...prefillSummary,
              });
              let currentIds = [...promptTokenIds];
              let selectedToken = prefillSummary.greedyToken;
              const greedyTokenSequence = [selectedToken];
              for (let decodeIndex = 0; decodeIndex < promptDecodeSteps; decodeIndex += 1) {
                currentIds = [...currentIds, selectedToken];
                const step = pipeline
                  ? await pipeline.decodeStepLogits(currentIds, {
                    useChatTemplate: runSpec.useChatTemplate,
                  })
                  : await runtime.advanced.decodeStepLogits(currentIds, {
                    useChatTemplate: runSpec.useChatTemplate,
                  });
                const stepSummary = await summarizeLogits(step.logits, runSpec, tokenizer);
                steps.push({
                  phase: "decode",
                  stepIndex: decodeIndex + 1,
                  promptTokenCount: promptTokenIds.length,
                  currentIdsLength: currentIds.length,
                  inputToken: selectedToken,
                  ...stepSummary,
                });
                selectedToken = stepSummary.greedyToken;
                greedyTokenSequence.push(selectedToken);
              }
              promptResults.push({
                status: "ok",
                id: prompt.id ?? null,
                text: prompt.text,
                promptIndex: Number.isFinite(prompt.promptIndex) ? prompt.promptIndex : promptIndex,
                promptTokenIds,
                greedyTokenSequence,
                prefillEmbedding: prefillEmbeddingSummary,
                steps,
              });
            } catch (error) {
              promptResults.push({
                status: "error",
                id: prompt.id ?? null,
                text: prompt.text,
                promptIndex: Number.isFinite(prompt.promptIndex) ? prompt.promptIndex : promptIndex,
                error: String(error?.stack ?? error),
              });
            }
          }
        } finally {
          await runtime.unload();
        }
        return {
          browserUserAgent: navigator.userAgent,
          adapterInfo,
          manifestModelId: manifest?.modelId ?? null,
          resolvedTokens,
          repeatIndex: runSpec.repeatIndex,
          elapsedMs: performance.now() - repeatStart,
          promptResults,
        };
      },
      spec
    ),
    timeoutMs,
    `browser logits harvest repeat ${spec.repeatIndex}`
  );
}

function chunkPromptCandidates(promptCandidates, chunkSize) {
  if (!Number.isFinite(chunkSize) || chunkSize <= 0 || promptCandidates.length <= chunkSize) {
    return [promptCandidates];
  }
  const chunks = [];
  for (let index = 0; index < promptCandidates.length; index += chunkSize) {
    chunks.push(promptCandidates.slice(index, index + chunkSize));
  }
  return chunks;
}

async function runProbe(config) {
  const dopplerRepoPath = resolvePath(config.dopplerRepoPath, "dopplerRepoPath");
  const modelArtifactPath = resolvePath(config.modelArtifactPath, "modelArtifactPath");
  const outputDir = resolvePath(config.outputDir, "outputDir");
  const internalDopplerIdentity = await collectDopplerBrowserIdentity(config, {
    modelArtifactPath,
  });
  const repeatCount = asPositiveInt(config.repeatCount, "repeatCount", 1);
  const decodeSteps = asPositiveInt(config.decodeSteps, "decodeSteps", 1);
  const topK = asPositiveInt(config.topK, "topK", 5);
  const persistLogits = asBoolean(config.persistLogits, false);
  const capturePrefillEmbedding = asBoolean(config.capturePrefillEmbedding, false);
  const prefillEmbeddingMode = typeof config.prefillEmbeddingMode === "string" && config.prefillEmbeddingMode.trim().length > 0
    ? config.prefillEmbeddingMode.trim()
    : "last";
  const useChatTemplate = asBoolean(config.useChatTemplate, false);
  const repeatIsolation = browserRepeatIsolation(config);
  const persistPromptChunkSize = persistLogits ? DEFAULT_PERSIST_LOGITS_PROMPT_CHUNK_SIZE : Number.POSITIVE_INFINITY;
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
      promptCandidates: config.promptCandidates.map((prompt, promptIndex) => ({
        ...prompt,
        promptIndex,
      })),
      decodeSteps,
      topK,
      persistLogits,
      capturePrefillEmbedding,
      prefillEmbeddingMode,
      tokenTextsToResolve: Array.isArray(config.tokenTextsToResolve)
        ? config.tokenTextsToResolve.map((entry) => String(entry))
        : [],
      useChatTemplate,
    };
    const runs = [];
    let browserUserAgent = null;
    let adapterInfo = null;
    let resolvedTokens = null;
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
        const promptChunks = chunkPromptCandidates(runSpec.promptCandidates, persistPromptChunkSize);
        let repeatElapsedMs = 0;
        const repeatPromptResults = [];
        for (const promptChunk of promptChunks) {
          const repeatResult = await harvestRepeat(
            repeatPage,
            {
              ...runSpec,
              promptCandidates: promptChunk,
              repeatIndex,
            },
            timeoutMs
          );
          browserUserAgent ??= repeatResult.browserUserAgent;
          adapterInfo ??= repeatResult.adapterInfo;
          resolvedTokens ??= repeatResult.resolvedTokens ?? null;
          repeatElapsedMs += repeatResult.elapsedMs;
          repeatPromptResults.push(...repeatResult.promptResults);
        }
        repeatPromptResults.sort((left, right) => left.promptIndex - right.promptIndex);
        runs.push({
          repeatIndex,
          elapsedMs: repeatElapsedMs,
          promptResults: repeatPromptResults,
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
    const result = {
      schemaVersion: 1,
      source: "doppler-browser-real-logits",
      modelId: internalDopplerIdentity.modelId ?? null,
      dopplerRepoPath: relativeOrAbsolute(dopplerRepoPath),
      modelArtifactPath: relativeOrAbsolute(modelArtifactPath),
      staticModelUrl: DEFAULT_MODEL_MOUNT,
      repeatCount,
      decodeSteps,
      topK,
      persistLogits,
      capturePrefillEmbedding,
      prefillEmbeddingMode,
      useChatTemplate,
      browser: {
        repeatIsolation,
        ...buildLaunchOptions(config),
      },
      runtimeConfig: config.runtimeConfig ?? {},
      browserUserAgent,
      adapterInfo,
      resolvedTokens,
      runs,
    };
    return persistArtifacts(result, outputDir);
  } finally {
    // Reuse-page keeps a shared page open until probe completion.
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

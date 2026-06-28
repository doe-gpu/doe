#!/usr/bin/env node
import { createHash } from "node:crypto";
import http from "node:http";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, extname, resolve } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import {
  loadRuntimeSelectorPolicy,
  resolveRuntimeSelection,
} from "./browser-runtime-selector.mjs";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(SCRIPT_DIR, "..", "..", "..");
const BENCH_OUT_ROOT = resolve(ROOT, "bench/out");
const BENCH_OUT_SCRATCH_ROOT = resolve(ROOT, "bench/out/scratch");
const JETSTREAM_BUILD_ROOT = resolve(
  ROOT,
  "browser/chromium/src/third_party/jetstream/main/transformersjs/build",
);
const JETSTREAM_LANE_VOLUME_BUILD_ROOT = resolve(
  ROOT,
  "browser/chromium_webgpu_lane/.local_volume/chromium_webgpu_lane/src/third_party/jetstream/main/transformersjs/build",
);
const BROWSER_ORT_ASSET_PREFIX = "/__doe_browser_ort_assets/";
const ORT_BROWSER_DIST_ROOT = resolve(
  ROOT,
  "bench/node_modules/onnxruntime-web/dist",
);
const ORT_BROWSER_WEBGPU_MODULE_PATH = resolve(
  ORT_BROWSER_DIST_ROOT,
  "ort.webgpu.min.mjs",
);
const REPORT_KIND = "chromium-webgpu-playwright-ort-bench";
const REPORT_SCHEMA_VERSION = 1;
const HASH_ALGORITHM = "sha256";
const RUNTIME_SELECTOR_VERSION = "browser-runtime-selector-v1";
const DEFAULT_OUT_FILE = "dawn-vs-doe.browser-ort-bench.diagnostic.json";
const DEFAULT_RUNTIME_SELECTOR_POLICY = resolve(ROOT, "config/browser-runtime-selector-policy.json");
const DEFAULT_TASK = "sentiment";
const DEFAULT_TIMED_ITERS = 5;
const DEFAULT_WARMUP_ITERS = 1;
const DEFAULT_SUITE_TIMEOUT_MS = 240000;
const DEFAULT_OPERATION_TIMEOUT_MS = 120000;
const DEFAULT_BROWSER_CLOSE_TIMEOUT_MS = 10000;
const DEFAULT_WEBGPU_PREFERRED_LAYOUT = (
  process.env.DOE_BROWSER_ORT_WEBGPU_PREFERRED_LAYOUT ?? ""
).trim();
const CONTENT_TYPE_BY_EXTENSION = Object.freeze({
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".onnx": "application/octet-stream",
  ".raw": "application/octet-stream",
  ".txt": "text/plain; charset=utf-8",
  ".wasm": "application/wasm",
});
const TASKS = Object.freeze({
  sentiment: Object.freeze({
    taskId: "sentiment",
    pipelineTask: "sentiment-analysis",
    modelId: "Xenova/distilbert-base-uncased-finetuned-sst-2-english",
    dtype: "uint8",
    inputPayload: Object.freeze([
      "I love deterministic benchmark surfaces.",
      "Benchmark drift is frustrating.",
    ]),
    expectedLabels: Object.freeze(["POSITIVE", "NEGATIVE"]),
  }),
  sentiment_medium: Object.freeze({
    taskId: "sentiment_medium",
    pipelineTask: "sentiment-analysis",
    modelId: "Xenova/distilbert-base-uncased-finetuned-sst-2-english",
    dtype: "uint8",
    inputPayload: Object.freeze([
      "I love deterministic benchmark surfaces because they make cross-runtime comparisons easier.",
      "Benchmark drift across lanes is frustrating when you cannot reproduce prior numbers.",
    ]),
    expectedLabels: Object.freeze(["POSITIVE", "NEGATIVE"]),
  }),
  sentiment_longform: Object.freeze({
    taskId: "sentiment_longform",
    pipelineTask: "sentiment-analysis",
    modelId: "Xenova/distilbert-base-uncased-finetuned-sst-2-english",
    dtype: "uint8",
    inputPayload: Object.freeze([
      "I love deterministic benchmark surfaces because they let me compare the same ORT stack across Doe and Dawn without hand-waving away the runtime differences.",
      "Benchmark drift gets frustrating when the browser lane looks healthy but the package and native lanes still disagree on what work was actually measured.",
    ]),
    expectedLabels: Object.freeze(["POSITIVE", "NEGATIVE"]),
  }),
});

function defaultChromePath() {
  const releaseLocalOut =
    process.env.FAWN_CHROMIUM_RELEASE_LOCAL_OUT ??
    resolve(ROOT, "browser/chromium/out/fawn_release_local");
  const chromiumLaneOut = resolve(ROOT, "browser/chromium_webgpu_lane/out/fawn_release_local");
  const hostFawnApp = resolve(process.env.HOME ?? "", "Applications/Fawn.app/Contents/MacOS/Chromium");
  const hostFawnReal = resolve(process.env.HOME ?? "", "Applications/Fawn.app/Contents/MacOS/Chromium-real");
  const envChrome = process.env.FAWN_CHROME_BIN;
  const candidates = [
    envChrome,
    resolve(releaseLocalOut, "chrome"),
    resolve(releaseLocalOut, "Fawn.app/Contents/MacOS/Chromium-real"),
    resolve(releaseLocalOut, "Fawn.app/Contents/MacOS/Chromium"),
    resolve(releaseLocalOut, "Chromium.app/Contents/MacOS/Chromium-real"),
    resolve(releaseLocalOut, "Chromium.app/Contents/MacOS/Chromium"),
    resolve(chromiumLaneOut, "chrome"),
    resolve(chromiumLaneOut, "Fawn.app/Contents/MacOS/Chromium-real"),
    resolve(chromiumLaneOut, "Fawn.app/Contents/MacOS/Chromium"),
    resolve(chromiumLaneOut, "Chromium.app/Contents/MacOS/Chromium-real"),
    resolve(chromiumLaneOut, "Chromium.app/Contents/MacOS/Chromium"),
    hostFawnReal,
    hostFawnApp,
    "/usr/bin/google-chrome-stable",
    "/usr/bin/google-chrome",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
    resolve(ROOT, "browser/chromium/src/out/fawn_release/chrome"),
    resolve(ROOT, "browser/chromium/src/out/fawn_release/Fawn.app/Contents/MacOS/Chromium-real"),
    resolve(ROOT, "browser/chromium/src/out/fawn_release/Fawn.app/Contents/MacOS/Chromium"),
    resolve(ROOT, "browser/chromium/src/out/fawn_release/Chromium.app/Contents/MacOS/Chromium-real"),
    resolve(ROOT, "browser/chromium/src/out/fawn_release/Chromium.app/Contents/MacOS/Chromium"),
    resolve(ROOT, "browser/chromium_webgpu_lane/src/out/fawn_release/chrome"),
    resolve(ROOT, "browser/chromium_webgpu_lane/src/out/fawn_release/Fawn.app/Contents/MacOS/Chromium-real"),
    resolve(ROOT, "browser/chromium_webgpu_lane/src/out/fawn_release/Fawn.app/Contents/MacOS/Chromium"),
    resolve(ROOT, "browser/chromium_webgpu_lane/src/out/fawn_release/Chromium.app/Contents/MacOS/Chromium-real"),
    resolve(ROOT, "browser/chromium_webgpu_lane/src/out/fawn_release/Chromium.app/Contents/MacOS/Chromium"),
    resolve(ROOT, "browser/chromium/src/out/fawn_debug/chrome"),
    resolve(ROOT, "browser/chromium/src/out/fawn_debug/Fawn.app/Contents/MacOS/Chromium-real"),
    resolve(ROOT, "browser/chromium/src/out/fawn_debug/Fawn.app/Contents/MacOS/Chromium"),
    resolve(ROOT, "browser/chromium/src/out/fawn_debug/Chromium.app/Contents/MacOS/Chromium-real"),
    resolve(ROOT, "browser/chromium/src/out/fawn_debug/Chromium.app/Contents/MacOS/Chromium"),
    resolve(ROOT, "browser/chromium_webgpu_lane/src/out/fawn_debug/chrome"),
    resolve(ROOT, "browser/chromium_webgpu_lane/src/out/fawn_debug/Fawn.app/Contents/MacOS/Chromium-real"),
    resolve(ROOT, "browser/chromium_webgpu_lane/src/out/fawn_debug/Fawn.app/Contents/MacOS/Chromium"),
    resolve(ROOT, "browser/chromium_webgpu_lane/src/out/fawn_debug/Chromium.app/Contents/MacOS/Chromium-real"),
    resolve(ROOT, "browser/chromium_webgpu_lane/src/out/fawn_debug/Chromium.app/Contents/MacOS/Chromium"),
  ].filter((value) => typeof value === "string" && value.length > 0);

  for (const candidate of candidates) {
    if (existsSync(candidate)) {
      return candidate;
    }
  }
  return candidates[0];
}

function defaultDoeLibPath() {
  const preferredExt = process.platform === "darwin" ? "dylib" : process.platform === "win32" ? "dll" : "so";
  const envDoeLib = process.env.FAWN_DOE_LIB;
  const candidates = [
    envDoeLib,
    resolve(ROOT, `runtime/zig/zig-out/lib/libwebgpu_doe_full.${preferredExt}`),
    resolve(ROOT, "runtime/zig/zig-out/lib/libwebgpu_doe_full.so"),
    resolve(ROOT, "runtime/zig/zig-out/lib/libwebgpu_doe_full.dylib"),
    resolve(ROOT, "runtime/zig/zig-out/lib/libwebgpu_doe_full.dll"),
    resolve(ROOT, `runtime/zig/zig-out/lib/libwebgpu_doe.${preferredExt}`),
    resolve(ROOT, "runtime/zig/zig-out/lib/libwebgpu_doe.so"),
    resolve(ROOT, "runtime/zig/zig-out/lib/libwebgpu_doe.dylib"),
    resolve(ROOT, "runtime/zig/zig-out/lib/libwebgpu_doe.dll"),
  ].filter((value) => typeof value === "string" && value.length > 0);

  for (const candidate of candidates) {
    if (existsSync(candidate)) {
      return candidate;
    }
  }
  return candidates[0];
}

function defaultJetstreamBuildRoot() {
  const envJetstreamBuild = process.env.FAWN_TRANSFORMERSJS_BUILD;
  const candidates = [
    envJetstreamBuild,
    JETSTREAM_BUILD_ROOT,
    JETSTREAM_LANE_VOLUME_BUILD_ROOT,
  ].filter((value) => typeof value === "string" && value.length > 0);

  for (const candidate of candidates) {
    if (existsSync(candidate)) {
      return candidate;
    }
  }
  return candidates[0];
}

function usage() {
  console.log(`Usage:
  node browser/chromium/scripts/webgpu-playwright-ort-bench.mjs [options]

Options:
  --mode dawn|doe|auto|both Runtime mode to run (default: both)
  --chrome PATH             Chrome binary path
  --doe-lib PATH            libwebgpu_doe_full.{so,dylib,dll} path (for doe mode)
  --transformersjs-build PATH
                            Transformers.js browser build root
  --runtime-selector-policy PATH
                            Runtime selector policy JSON path (default: config/browser-runtime-selector-policy.json)
  --runtime-selector-profile-id ID
                            Optional selector profileId for auto denylist checks
  --out PATH                JSON report output path (default: browser/chromium/artifacts/<timestamp>/${DEFAULT_OUT_FILE})
  --allow-bench-out         Allow writing this report under bench/out/scratch
  --headless true|false     Launch headless (default: true)
  --task sentiment|sentiment_medium|sentiment_longform
                            Browser ORT task to run (default: ${DEFAULT_TASK})
  --timed-iters N           Timed inference iterations per mode (default: ${DEFAULT_TIMED_ITERS})
  --warmup-iters N          Warmup iterations per mode (default: ${DEFAULT_WARMUP_ITERS})
  --suite-timeout-ms N      Max time for one mode suite run (default: ${DEFAULT_SUITE_TIMEOUT_MS})
  --op-timeout-ms N         Max time for one async browser op (default: ${DEFAULT_OPERATION_TIMEOUT_MS})
  --chrome-arg ARG          Extra Chromium arg (repeatable)
  --webgpu-preferred-layout NCHW|NHWC
                            Optional ORT WebGPU preferred layout
  --strict                  Exit non-zero if any mode fails
  --help                    Show this message
`);
}

function timestampId() {
  return new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z");
}

function defaultOutPath() {
  return resolve(
    ROOT,
    "browser/chromium/artifacts",
    timestampId(),
    DEFAULT_OUT_FILE,
  );
}

function readOptionValue(argv, optionIndex, flag) {
  const value = argv[optionIndex + 1];
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`${flag} requires a value`);
  }
  return value;
}

function parseBool(text, flag) {
  if (text === "true") return true;
  if (text === "false") return false;
  throw new Error(`${flag} must be true or false`);
}

function parsePositiveInt(text, flag) {
  const value = Number.parseInt(text, 10);
  if (!Number.isFinite(value) || value <= 0) {
    throw new Error(`${flag} must be a positive integer`);
  }
  return value;
}

function pathWithin(pathValue, rootPath) {
  const absolutePath = resolve(pathValue);
  const absoluteRoot = resolve(rootPath);
  return absolutePath === absoluteRoot || absolutePath.startsWith(`${absoluteRoot}/`);
}

function ensureAllowedOutPath(outPath, allowBenchOut) {
  if (!pathWithin(outPath, BENCH_OUT_ROOT)) {
    return;
  }
  if (!allowBenchOut) {
    throw new Error(
      `refusing to write browser ORT output to ${BENCH_OUT_ROOT}; write under browser/chromium/artifacts or pass --allow-bench-out explicitly`,
    );
  }
  if (!pathWithin(outPath, BENCH_OUT_SCRATCH_ROOT)) {
    throw new Error(
      `browser ORT output under bench/out must be in ${BENCH_OUT_SCRATCH_ROOT}`,
    );
  }
}

function parseArgs(argv) {
  const args = {
    mode: "both",
    chromePath: defaultChromePath(),
    doeLibPath: defaultDoeLibPath(),
    jetstreamBuildRoot: defaultJetstreamBuildRoot(),
    runtimeSelectorPolicyPath: DEFAULT_RUNTIME_SELECTOR_POLICY,
    runtimeSelectorPolicy: null,
    runtimeSelectorProfileId: "",
    outPath: defaultOutPath(),
    allowBenchOut: false,
    headless: true,
    task: DEFAULT_TASK,
    timedIters: DEFAULT_TIMED_ITERS,
    warmupIters: DEFAULT_WARMUP_ITERS,
    suiteTimeoutMs: DEFAULT_SUITE_TIMEOUT_MS,
    opTimeoutMs: DEFAULT_OPERATION_TIMEOUT_MS,
    chromeArgs: [],
    webgpuPreferredLayout: DEFAULT_WEBGPU_PREFERRED_LAYOUT,
    strict: false,
  };

  for (let i = 2; i < argv.length; i += 1) {
    const token = argv[i];
    if (token === "--help" || token === "-h") {
      usage();
      process.exit(0);
    } else if (token === "--strict") {
      args.strict = true;
    } else if (token === "--allow-bench-out") {
      args.allowBenchOut = true;
    } else if (token === "--mode") {
      args.mode = readOptionValue(argv, i, "--mode");
      i += 1;
    } else if (token === "--chrome") {
      args.chromePath = readOptionValue(argv, i, "--chrome");
      i += 1;
    } else if (token === "--doe-lib") {
      args.doeLibPath = readOptionValue(argv, i, "--doe-lib");
      i += 1;
    } else if (token === "--transformersjs-build") {
      args.jetstreamBuildRoot = readOptionValue(argv, i, "--transformersjs-build");
      i += 1;
    } else if (token === "--runtime-selector-policy") {
      args.runtimeSelectorPolicyPath = readOptionValue(argv, i, "--runtime-selector-policy");
      i += 1;
    } else if (token === "--runtime-selector-profile-id") {
      args.runtimeSelectorProfileId = readOptionValue(argv, i, "--runtime-selector-profile-id");
      i += 1;
    } else if (token === "--out") {
      args.outPath = readOptionValue(argv, i, "--out");
      i += 1;
    } else if (token === "--headless") {
      args.headless = parseBool(readOptionValue(argv, i, "--headless"), "--headless");
      i += 1;
    } else if (token === "--task") {
      args.task = readOptionValue(argv, i, "--task");
      i += 1;
    } else if (token === "--timed-iters") {
      args.timedIters = parsePositiveInt(readOptionValue(argv, i, "--timed-iters"), "--timed-iters");
      i += 1;
    } else if (token === "--warmup-iters") {
      args.warmupIters = parsePositiveInt(readOptionValue(argv, i, "--warmup-iters"), "--warmup-iters");
      i += 1;
    } else if (token === "--suite-timeout-ms") {
      args.suiteTimeoutMs = parsePositiveInt(readOptionValue(argv, i, "--suite-timeout-ms"), "--suite-timeout-ms");
      i += 1;
    } else if (token === "--op-timeout-ms") {
      args.opTimeoutMs = parsePositiveInt(readOptionValue(argv, i, "--op-timeout-ms"), "--op-timeout-ms");
      i += 1;
    } else if (token === "--chrome-arg") {
      args.chromeArgs.push(readOptionValue(argv, i, "--chrome-arg"));
      i += 1;
    } else if (token === "--webgpu-preferred-layout") {
      args.webgpuPreferredLayout = readOptionValue(argv, i, "--webgpu-preferred-layout").trim();
      i += 1;
    } else {
      throw new Error(`unknown option: ${token}`);
    }
  }

  if (!["dawn", "doe", "auto", "both"].includes(args.mode)) {
    throw new Error("--mode must be one of dawn, doe, auto, both");
  }
  if (!existsSync(args.runtimeSelectorPolicyPath)) {
    throw new Error(`runtime selector policy not found: ${args.runtimeSelectorPolicyPath}`);
  }
  args.runtimeSelectorPolicy = loadRuntimeSelectorPolicy(args.runtimeSelectorPolicyPath);
  if (!Object.hasOwn(TASKS, args.task)) {
    throw new Error(`--task must be one of ${Object.keys(TASKS).join(", ")}`);
  }
  if (
    args.webgpuPreferredLayout &&
    args.webgpuPreferredLayout !== "NCHW" &&
    args.webgpuPreferredLayout !== "NHWC"
  ) {
    throw new Error("--webgpu-preferred-layout must be empty, NCHW, or NHWC");
  }
  if (!existsSync(args.chromePath)) {
    throw new Error(`chrome binary not found: ${args.chromePath}`);
  }
  if ((args.mode === "doe" || args.mode === "both") && !existsSync(args.doeLibPath)) {
    throw new Error(`doe runtime library not found: ${args.doeLibPath}`);
  }
  if (!existsSync(args.jetstreamBuildRoot)) {
    throw new Error(`Transformers.js browser build not found: ${args.jetstreamBuildRoot}`);
  }
  if (!existsSync(ORT_BROWSER_WEBGPU_MODULE_PATH)) {
    throw new Error(`onnxruntime-web WebGPU module not found: ${ORT_BROWSER_WEBGPU_MODULE_PATH}`);
  }
  ensureAllowedOutPath(args.outPath, args.allowBenchOut);
  return args;
}

async function loadChromiumDriver() {
  try {
    const mod = await import("playwright");
    return mod.chromium;
  } catch {
    // continue
  }

  try {
    const mod = await import("playwright-core");
    return mod.chromium;
  } catch {
    // continue
  }

  throw new Error(
    "Playwright not found. Install with: npm --prefix browser/chromium ci",
  );
}

function contentTypeFor(path) {
  return CONTENT_TYPE_BY_EXTENSION[extname(path).toLowerCase()] ?? "application/octet-stream";
}

function htmlPage() {
  return "<!doctype html><meta charset='utf-8'><title>doe-webgpu-ort-bench</title>";
}

function aliasPathForRequest(requestPath, args) {
  if (requestPath.startsWith(BROWSER_ORT_ASSET_PREFIX)) {
    const relativeAssetPath = requestPath.slice(BROWSER_ORT_ASSET_PREFIX.length);
    const absoluteAssetPath = resolve(args.jetstreamBuildRoot, relativeAssetPath);
    if (!pathWithin(absoluteAssetPath, args.jetstreamBuildRoot)) {
      return null;
    }
    return absoluteAssetPath;
  }
  return resolve(ROOT, requestPath.replace(/^\/+/, ""));
}

function startLocalServer(args) {
  const server = http.createServer((req, res) => {
    const requestPath = new URL(req.url ?? "/", "http://127.0.0.1").pathname;
    const headers = {
      "Cross-Origin-Embedder-Policy": "require-corp",
      "Cross-Origin-Opener-Policy": "same-origin",
      "Cross-Origin-Resource-Policy": "same-origin",
      "Cache-Control": "no-store",
    };
    if (requestPath !== "/") {
      const absolutePath = aliasPathForRequest(requestPath, args);
      if (absolutePath === null) {
        res.writeHead(404, headers);
        res.end("not found");
        return;
      }
      const requestUsesAssetAlias = requestPath.startsWith(BROWSER_ORT_ASSET_PREFIX);
      if (!requestUsesAssetAlias && !pathWithin(absolutePath, ROOT)) {
        res.writeHead(404, headers);
        res.end("not found");
        return;
      }
      if (!existsSync(absolutePath)) {
        res.writeHead(404, headers);
        res.end("not found");
        return;
      }
      res.writeHead(200, {
        ...headers,
        "content-type": contentTypeFor(absolutePath),
      });
      res.end(readFileSync(absolutePath));
      return;
    }
    res.writeHead(200, {
      ...headers,
      "content-type": "text/html; charset=utf-8",
    });
    res.end(htmlPage());
  });

  return new Promise((resolveServer, rejectServer) => {
    server.on("error", rejectServer);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") {
        rejectServer(new Error("failed to resolve local server address"));
        return;
      }
      resolveServer({
        port: address.port,
        server,
        url: `http://127.0.0.1:${address.port}/`,
      });
    });
  });
}

function baseLaunchArgs(port) {
  const args = [
    "--no-sandbox",
    "--disable-setuid-sandbox",
    "--disable-dev-shm-usage",
    "--disable-background-timer-throttling",
    "--disable-backgrounding-occluded-windows",
    "--disable-renderer-backgrounding",
    "--ignore-gpu-blocklist",
    "--enable-unsafe-webgpu",
    `--unsafely-treat-insecure-origin-as-secure=http://127.0.0.1:${port}`,
  ];
  if (process.platform === "linux") {
    args.push("--use-angle=vulkan");
  }
  return args;
}

function runtimeArgs(mode, doeLibPath) {
  if (mode === "dawn") {
    return ["--use-webgpu-runtime=dawn"];
  }
  return [
    "--use-webgpu-runtime=doe",
    `--doe-webgpu-library-path=${doeLibPath}`,
  ];
}

function timeoutError(label, timeoutMs) {
  return new Error(`${label} timed out after ${timeoutMs}ms`);
}

async function withTimeout(promise, timeoutMs, label) {
  let timeoutId = null;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timeoutId = setTimeout(() => reject(timeoutError(label, timeoutMs)), timeoutMs);
      }),
    ]);
  } finally {
    if (timeoutId !== null) {
      clearTimeout(timeoutId);
    }
  }
}

function percentile(values, fraction) {
  if (!Array.isArray(values) || values.length === 0) {
    return null;
  }
  const ordered = [...values].sort((left, right) => left - right);
  const index = Math.min(
    ordered.length - 1,
    Math.max(0, Math.floor((ordered.length - 1) * fraction)),
  );
  return ordered[index];
}

function mean(values) {
  if (!Array.isArray(values) || values.length === 0) {
    return null;
  }
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

function safeDeltaPercent(dawnValue, doeValue) {
  if (!Number.isFinite(dawnValue) || !Number.isFinite(doeValue) || dawnValue === 0) {
    return null;
  }
  return ((dawnValue - doeValue) / dawnValue) * 100;
}

function stableObject(value) {
  if (Array.isArray(value)) {
    return value.map((entry) => stableObject(entry));
  }
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, stableObject(value[key])]),
    );
  }
  return value;
}

function hashHex(value) {
  const canonical = JSON.stringify(stableObject(value));
  return createHash(HASH_ALGORITHM).update(canonical).digest("hex");
}

function fileHashHex(pathValue) {
  if (!pathValue || !existsSync(pathValue)) return null;
  return createHash(HASH_ALGORITHM).update(readFileSync(pathValue)).digest("hex");
}

function runtimeArtifactIdentity(mode, args) {
  const browserExecutableSha256 = fileHashHex(args.chromePath);
  return {
    browserExecutablePath: args.chromePath,
    browserExecutableSha256,
    dawnRuntimePath: args.chromePath,
    dawnRuntimeSha256: browserExecutableSha256,
    doeLibPath: mode === "doe" ? args.doeLibPath : null,
    doeLibSha256: mode === "doe" ? fileHashHex(args.doeLibPath) : null,
  };
}

function browserOrtSourceIdentity(args) {
  const taskConfig = taskDefinition(args.task);
  const transformersModulePath = resolve(args.jetstreamBuildRoot, "transformers.js");
  const modelPath = resolve(
    args.jetstreamBuildRoot,
    "models",
    taskConfig.modelId,
    "onnx",
    "model_uint8.onnx",
  );
  return {
    transformersjsBuildRoot: args.jetstreamBuildRoot,
    transformersModulePath,
    transformersModuleSha256: fileHashHex(transformersModulePath),
    ortWebGpuModulePath: ORT_BROWSER_WEBGPU_MODULE_PATH,
    ortWebGpuModuleSha256: fileHashHex(ORT_BROWSER_WEBGPU_MODULE_PATH),
    modelId: taskConfig.modelId,
    modelPath,
    modelSha256: fileHashHex(modelPath),
  };
}

function runtimeSelectionResolution(mode, args) {
  return resolveRuntimeSelection({
    requestedMode: mode,
    doeLibPath: args.doeLibPath,
    policy: args.runtimeSelectorPolicy,
    profile: { profileId: args.runtimeSelectorProfileId },
  });
}

function buildRuntimeSelection(mode, args, launchArgs) {
  const resolution = runtimeSelectionResolution(mode, args);
  return {
    ...resolution,
    selectorVersion: RUNTIME_SELECTOR_VERSION,
    artifactIdentity: runtimeArtifactIdentity(resolution.selectedRuntime, args),
    launchArgsHash: hashHex(launchArgs),
  };
}

function shaderCompilerIdentity(mode, args) {
  const resolution = runtimeSelectionResolution(mode, args);
  const artifactIdentity = runtimeArtifactIdentity(resolution.selectedRuntime, args);
  const compilerArtifactPath =
    resolution.selectedRuntime === "doe"
      ? artifactIdentity.doeLibPath
      : artifactIdentity.dawnRuntimePath;
  const compilerArtifactSha256 =
    resolution.selectedRuntime === "doe"
      ? artifactIdentity.doeLibSha256
      : artifactIdentity.dawnRuntimeSha256;
  return {
    compilerSurface:
      resolution.selectedRuntime === "doe"
        ? "doe_runtime_embedded_shader_compiler"
        : "dawn_runtime_embedded_shader_compiler",
    compilerArtifactPath,
    compilerArtifactSha256,
    identitySource: "runtime_artifact_identity",
  };
}

function adapterIdentityFromSummary(summary) {
  const adapterSummary = summary && typeof summary === "object" ? summary : {};
  return {
    adapterSummarySha256: hashHex(adapterSummary),
    featureCount: Array.isArray(adapterSummary.features) ? adapterSummary.features.length : 0,
  };
}

function taskDefinition(taskId) {
  return TASKS[taskId];
}

function modelBaseUrl(baseUrl) {
  return new URL(
    `${BROWSER_ORT_ASSET_PREFIX}models/`,
    baseUrl,
  ).href;
}

function transformersModuleUrl(baseUrl) {
  return new URL(
    `${BROWSER_ORT_ASSET_PREFIX}transformers.js`,
    baseUrl,
  ).href;
}

function ortWebGpuModuleUrl(baseUrl) {
  return new URL(
    "/bench/node_modules/onnxruntime-web/dist/ort.webgpu.min.mjs",
    baseUrl,
  ).href;
}

function ortDistBaseUrl(baseUrl) {
  return new URL(
    "/bench/node_modules/onnxruntime-web/dist/",
    baseUrl,
  ).href;
}

function modeReportOnError(mode, args, launchArgs, browserVersion, startedMs, error) {
  const errorText = String(error?.stack ?? error);
  return {
    success: false,
    mode,
    task: args.task,
    headless: args.headless,
    launchArgs,
    browserVersion,
    elapsedMs: Date.now() - startedMs,
    timingClass: "process-wall",
    runtimeSelection: buildRuntimeSelection(mode, args, launchArgs),
    shaderCompilerIdentity: shaderCompilerIdentity(mode, args),
    error: errorText,
  };
}

async function runMode(chromium, mode, args, localUrl, localPort) {
  const selection = runtimeSelectionResolution(mode, args);
  const launchArgs = [
    ...baseLaunchArgs(localPort),
    ...args.chromeArgs,
    ...runtimeArgs(selection.selectedRuntime, args.doeLibPath),
  ];
  const startedMs = Date.now();
  let browser = null;
  let browserVersion = null;

  try {
    browser = await chromium.launch({
      executablePath: args.chromePath,
      headless: args.headless,
      args: launchArgs,
      timeout: 120000,
    });
    browserVersion = browser.version();
    const context = await browser.newContext();
    const page = await context.newPage();
    await page.goto(localUrl, { waitUntil: "load", timeout: 120000 });

    const result = await withTimeout(
      page.evaluate(
        async ({
          modelBaseUrlValue,
          operationTimeoutMs,
          ortDistBaseUrlValue,
          ortWebGpuModuleUrlValue,
          taskConfig,
          timedIters,
          transformersModuleUrlValue,
          warmupIters,
          webgpuPreferredLayout,
        }) => {
          const webgpuCounters = {
            bufferGetMappedRange: 0,
            bufferMapAsync: 0,
            bufferUnmap: 0,
            dispatchWorkgroups: 0,
            dispatchWorkgroupsIndirect: 0,
            queueOnSubmittedWorkDone: 0,
            queueSubmit: 0,
          };
          const patchMethod = (prototype, methodName, counterName) => {
            if (!prototype || typeof prototype[methodName] !== "function") {
              return false;
            }
            const original = prototype[methodName];
            try {
              Object.defineProperty(prototype, methodName, {
                configurable: true,
                writable: true,
                value: function countedWebgpuMethod(...methodArgs) {
                  webgpuCounters[counterName] += 1;
                  return original.apply(this, methodArgs);
                },
              });
              return true;
            } catch {
              return false;
            }
          };
          const webgpuCounterPatches = {
            bufferGetMappedRange: patchMethod(
              globalThis.GPUBuffer?.prototype,
              "getMappedRange",
              "bufferGetMappedRange",
            ),
            bufferMapAsync: patchMethod(
              globalThis.GPUBuffer?.prototype,
              "mapAsync",
              "bufferMapAsync",
            ),
            bufferUnmap: patchMethod(
              globalThis.GPUBuffer?.prototype,
              "unmap",
              "bufferUnmap",
            ),
            dispatchWorkgroups: patchMethod(
              globalThis.GPUComputePassEncoder?.prototype,
              "dispatchWorkgroups",
              "dispatchWorkgroups",
            ),
            dispatchWorkgroupsIndirect: patchMethod(
              globalThis.GPUComputePassEncoder?.prototype,
              "dispatchWorkgroupsIndirect",
              "dispatchWorkgroupsIndirect",
            ),
            queueSubmit: patchMethod(
              globalThis.GPUQueue?.prototype,
              "submit",
              "queueSubmit",
            ),
            queueOnSubmittedWorkDone: patchMethod(
              globalThis.GPUQueue?.prototype,
              "onSubmittedWorkDone",
              "queueOnSubmittedWorkDone",
            ),
          };
          const resetWebgpuCounters = () => {
            webgpuCounters.bufferGetMappedRange = 0;
            webgpuCounters.bufferMapAsync = 0;
            webgpuCounters.bufferUnmap = 0;
            webgpuCounters.dispatchWorkgroups = 0;
            webgpuCounters.dispatchWorkgroupsIndirect = 0;
            webgpuCounters.queueOnSubmittedWorkDone = 0;
            webgpuCounters.queueSubmit = 0;
          };
          const withOpTimeout = async (label, promiseFactory) => {
            let timeoutId = null;
            try {
              return await Promise.race([
                promiseFactory(),
                new Promise((_, reject) => {
                  timeoutId = setTimeout(
                    () => reject(new Error(`${label} timed out after ${operationTimeoutMs}ms`)),
                    operationTimeoutMs,
                  );
                }),
              ]);
            } finally {
              if (timeoutId !== null) {
                clearTimeout(timeoutId);
              }
            }
          };

          const summarizeAdapter = (adapter) => {
            if (!adapter) {
              return null;
            }
            const info = adapter.info ?? {};
            return {
              description: info.description ?? null,
              architecture: info.architecture ?? null,
              device: info.device ?? null,
              vendor: info.vendor ?? null,
              isFallbackAdapter: adapter.isFallbackAdapter ?? null,
              features: Array.from(adapter.features ?? []),
            };
          };

          const summarizeOutputs = (outputs) => {
            if (!Array.isArray(outputs)) {
              return { kind: typeof outputs, length: null };
            }
            return {
              kind: "array",
              length: outputs.length,
              labels: outputs.map((entry) => entry?.label ?? null),
              scores: outputs.map((entry) =>
                typeof entry?.score === "number" ? Number(entry.score) : null),
            };
          };
          const normalizeTokenizerInput = (value, sessionInputType) => {
            if (Array.isArray(value) && value.length > 0 && Array.isArray(value[0])) {
              const dims = [value.length, value[0].length];
              if (sessionInputType === "int64") {
                return {
                  dims,
                  tensor: new ort.Tensor(
                    "int64",
                    BigInt64Array.from(value.flat().map((entry) => BigInt(entry))),
                    dims,
                  ),
                };
              }
              return {
                dims,
                tensor: new ort.Tensor(
                  "int32",
                  Int32Array.from(value.flat().map((entry) => Number(entry))),
                  dims,
                ),
              };
            }
            if (value?.dims && value?.data) {
              const dims = Array.from(value.dims);
              if (sessionInputType === "int64") {
                const data = value.data instanceof BigInt64Array
                  ? value.data
                  : BigInt64Array.from(Array.from(value.data, (entry) => BigInt(entry)));
                return {
                  dims,
                  tensor: new ort.Tensor("int64", data, dims),
                };
              }
              const data = value.data instanceof Int32Array
                ? value.data
                : Int32Array.from(Array.from(value.data, (entry) => Number(entry)));
              return {
                dims,
                tensor: new ort.Tensor("int32", data, dims),
              };
            }
            throw new Error("unexpected tokenizer input_ids shape");
          };

          const taskInput = structuredClone(taskConfig.inputPayload);
          const adapterRequestOptions = {
            powerPreference: "high-performance",
            forceFallbackAdapter: false,
          };
          const adapter = await withOpTimeout(
            "navigator.gpu.requestAdapter",
            () => navigator.gpu.requestAdapter(adapterRequestOptions),
          );
          if (!adapter) {
            throw new Error("navigator.gpu.requestAdapter returned null");
          }
          const ort = await import(ortWebGpuModuleUrlValue);
          const { AutoTokenizer, env } = await import(transformersModuleUrlValue);
          env.allowRemoteModels = false;
          env.allowLocalModels = true;
          env.localModelPath = modelBaseUrlValue;
          ort.env.wasm.proxy = false;
          ort.env.wasm.numThreads = 1;
          ort.env.wasm.wasmPaths = ortDistBaseUrlValue;
          ort.env.webgpu.powerPreference = adapterRequestOptions.powerPreference;
          ort.env.webgpu.forceFallbackAdapter = adapterRequestOptions.forceFallbackAdapter;

          const tokenizer = await withOpTimeout(
            "AutoTokenizer.from_pretrained",
            () => AutoTokenizer.from_pretrained(taskConfig.modelId, { local_files_only: true }),
          );
          const modelPath = new URL(
            `${taskConfig.modelId}/onnx/model_uint8.onnx`,
            modelBaseUrlValue,
          ).href;
          const webgpuExecutionProvider = webgpuPreferredLayout
            ? { name: "webgpu", preferredLayout: webgpuPreferredLayout }
            : "webgpu";
          const ortSessionOptions = {
            executionProviders: [webgpuExecutionProvider],
            graphOptimizationLevel: "all",
            webgpuPreferredLayout: webgpuPreferredLayout || null,
          };
          const loadStarted = performance.now();
          const session = await withOpTimeout(
            "ort.InferenceSession.create",
            () => ort.InferenceSession.create(
              modelPath,
              ortSessionOptions,
            ),
          );
          const executionAdapter = ort.env.webgpu.adapter ?? adapter;
          const loadEnded = performance.now();
          const encoded = await withOpTimeout(
            "tokenizer",
            () => tokenizer(taskInput, { padding: true, truncation: true }),
          );
          const sessionInputNames = Array.isArray(session.inputNames) ? session.inputNames : ["input_ids"];
          const feeds = {};
          let dims = null;
          for (const inputName of sessionInputNames) {
            const sessionInputType = session.inputMetadata?.[inputName]?.type ?? "int64";
            const normalizedInput = normalizeTokenizerInput(encoded?.[inputName], sessionInputType);
            dims = dims ?? normalizedInput.dims;
            feeds[inputName] = normalizedInput.tensor;
          }

          const runTask = async () => {
            const outputs = await withOpTimeout(
              "ort session.run",
              () => session.run(feeds),
            );
            const logits = outputs.logits;
            if (!logits || !Array.isArray(logits.dims) || logits.dims.length !== 2) {
              throw new Error(`unexpected logits output ${JSON.stringify(logits)}`);
            }
            const labels = ["NEGATIVE", "POSITIVE"];
            const predictions = [];
            for (let row = 0; row < logits.dims[0]; row += 1) {
              const left = Number(logits.data[row * logits.dims[1]]);
              const right = Number(logits.data[row * logits.dims[1] + 1]);
              predictions.push({
                label: labels[right >= left ? 1 : 0],
                scores: [left, right],
              });
            }
            return predictions;
          };

          for (let index = 0; index < warmupIters; index += 1) {
            await runTask();
          }

          const timedIterationsMs = [];
          let finalOutput = null;
          resetWebgpuCounters();
          for (let index = 0; index < timedIters; index += 1) {
            const iterationStarted = performance.now();
            finalOutput = await runTask();
            timedIterationsMs.push(performance.now() - iterationStarted);
          }
          const webgpuDispatchCount =
            webgpuCounters.dispatchWorkgroups + webgpuCounters.dispatchWorkgroupsIndirect;

          const expectedLabels = Array.isArray(taskConfig.expectedLabels)
            ? taskConfig.expectedLabels
            : null;
          if (!Array.isArray(finalOutput) || !expectedLabels || finalOutput.length !== expectedLabels.length) {
            throw new Error(
              `expected ${expectedLabels?.length ?? "configured"} outputs, got ${JSON.stringify(finalOutput)}`,
            );
          }
          for (let index = 0; index < expectedLabels.length; index += 1) {
            if (finalOutput[index]?.label !== expectedLabels[index]) {
              throw new Error(
                `unexpected output ${index}: ${JSON.stringify(finalOutput[index])}`,
              );
            }
          }

          return {
            adapterSummary: summarizeAdapter(executionAdapter),
            adapterRequestOptions,
            loadMs: loadEnded - loadStarted,
            ortSessionOptions,
            outputSummary: summarizeOutputs(finalOutput),
            sequenceLength: Array.isArray(dims) ? dims[1] : null,
            sessionInputNames,
            timedIterationsMs,
            webgpuCounterPatches,
            webgpuDispatchCount,
            webgpuDispatchWorkgroups: webgpuCounters.dispatchWorkgroups,
            webgpuDispatchWorkgroupsIndirect: webgpuCounters.dispatchWorkgroupsIndirect,
            webgpuBufferGetMappedRangeCount: webgpuCounters.bufferGetMappedRange,
            webgpuBufferMapAsyncCount: webgpuCounters.bufferMapAsync,
            webgpuBufferUnmapCount: webgpuCounters.bufferUnmap,
            webgpuQueueOnSubmittedWorkDoneCount: webgpuCounters.queueOnSubmittedWorkDone,
            webgpuQueueSubmitCount: webgpuCounters.queueSubmit,
            webgpuAvailable: typeof navigator.gpu !== "undefined",
          };
        },
        {
          modelBaseUrlValue: modelBaseUrl(localUrl),
          operationTimeoutMs: args.opTimeoutMs,
          ortDistBaseUrlValue: ortDistBaseUrl(localUrl),
          ortWebGpuModuleUrlValue: ortWebGpuModuleUrl(localUrl),
          taskConfig: taskDefinition(args.task),
          timedIters: args.timedIters,
          transformersModuleUrlValue: transformersModuleUrl(localUrl),
          warmupIters: args.warmupIters,
          webgpuPreferredLayout: args.webgpuPreferredLayout,
        },
      ),
      args.suiteTimeoutMs,
      `${mode} suite`,
    );

    await withTimeout(browser.close(), DEFAULT_BROWSER_CLOSE_TIMEOUT_MS, `${mode} browser close`);
    browser = null;

    return {
      success: true,
      mode,
      task: args.task,
      headless: args.headless,
      browserVersion,
      elapsedMs: Date.now() - startedMs,
      launchArgs,
      timingClass: "operation",
      runtimeSelection: buildRuntimeSelection(mode, args, launchArgs),
      shaderCompilerIdentity: shaderCompilerIdentity(mode, args),
      pipelineLoadMs: result.loadMs,
      ortSessionOptions: result.ortSessionOptions,
      sequenceLength: result.sequenceLength,
      sessionInputNames: result.sessionInputNames,
      timedIterationsMs: result.timedIterationsMs,
      timedMeanMs: mean(result.timedIterationsMs),
      timedP50Ms: percentile(result.timedIterationsMs, 0.5),
      timedP95Ms: percentile(result.timedIterationsMs, 0.95),
      adapterSummary: result.adapterSummary,
      adapterRequestOptions: result.adapterRequestOptions,
      adapterIdentity: adapterIdentityFromSummary(result.adapterSummary),
      outputSummary: result.outputSummary,
      webgpuCounterPatches: result.webgpuCounterPatches,
      webgpuDispatchCount: result.webgpuDispatchCount,
      webgpuDispatchWorkgroups: result.webgpuDispatchWorkgroups,
      webgpuDispatchWorkgroupsIndirect: result.webgpuDispatchWorkgroupsIndirect,
      webgpuBufferGetMappedRangeCount: result.webgpuBufferGetMappedRangeCount,
      webgpuBufferMapAsyncCount: result.webgpuBufferMapAsyncCount,
      webgpuBufferUnmapCount: result.webgpuBufferUnmapCount,
      webgpuQueueOnSubmittedWorkDoneCount: result.webgpuQueueOnSubmittedWorkDoneCount,
      webgpuQueueSubmitCount: result.webgpuQueueSubmitCount,
      webgpuAvailable: result.webgpuAvailable,
      browserOrtSourceIdentity: browserOrtSourceIdentity(args),
    };
  } catch (error) {
    if (browser) {
      try {
        await withTimeout(browser.close(), DEFAULT_BROWSER_CLOSE_TIMEOUT_MS, `${mode} browser close`);
      } catch {
        // ignore close failure on the error path
      }
    }
    return modeReportOnError(mode, args, launchArgs, browserVersion, startedMs, error);
  }
}

function extractModeResult(modeResults, mode) {
  return modeResults.find((entry) => entry.mode === mode) ?? null;
}

function attachHashChain(entries) {
  let previousHash = "0".repeat(64);
  return entries.map((entry, index) => {
    const traceEntry = {
      module: "browser_ort",
      opCode: "mode_result",
      seq: index + 1,
      ...entry,
    };
    const hash = hashHex({ previousHash, entry: traceEntry });
    const withHash = { ...traceEntry, previousHash, hash };
    previousHash = hash;
    return withHash;
  });
}

function comparisonFor(modeResults) {
  const dawn = extractModeResult(modeResults, "dawn");
  const doe = extractModeResult(modeResults, "doe");
  if (!dawn?.success || !doe?.success) {
    return null;
  }
  return {
    timedMeanDeltaPercent: safeDeltaPercent(dawn.timedMeanMs, doe.timedMeanMs),
    timedP50DeltaPercent: safeDeltaPercent(dawn.timedP50Ms, doe.timedP50Ms),
    timedP95DeltaPercent: safeDeltaPercent(dawn.timedP95Ms, doe.timedP95Ms),
    pipelineLoadDeltaPercent: safeDeltaPercent(dawn.pipelineLoadMs, doe.pipelineLoadMs),
  };
}

function buildReport(args, serverInfo, modeResults) {
  const modeResultsWithHashes = attachHashChain(modeResults);
  const report = {
    schemaVersion: REPORT_SCHEMA_VERSION,
    reportKind: REPORT_KIND,
    benchmarkClass: "directional",
    claimEligible: false,
    comparability: "same-stack-same-model-browser-process-wall",
    generatedAt: new Date().toISOString(),
    task: args.task,
    taskConfig: taskDefinition(args.task),
    workloadIdentity: {
      kind: "browser_ort_workload",
      task: args.task,
      taskConfigHash: hashHex(taskDefinition(args.task)),
    },
    headless: args.headless,
    chromePath: args.chromePath,
    doeLibPath: args.mode === "dawn" ? null : args.doeLibPath,
    transformersjsBuildRoot: args.jetstreamBuildRoot,
    browserOrtSourceIdentity: browserOrtSourceIdentity(args),
    localServerUrl: serverInfo.url,
    timingClass: "process-wall",
    hashAlgorithm: HASH_ALGORITHM,
    runtimeSelectorPolicyPath: args.runtimeSelectorPolicyPath,
    runtimeSelections: modeResultsWithHashes.map((entry) => entry.runtimeSelection),
    modeResults: modeResultsWithHashes,
    comparison: comparisonFor(modeResultsWithHashes),
  };
  report.reportHash = hashHex(report);
  return report;
}

function printSummary(report) {
  process.stdout.write(`${report.reportKind}\n`);
  for (const modeResult of report.modeResults) {
    if (!modeResult.success) {
      process.stdout.write(`  ${modeResult.mode}: failed: ${modeResult.error}\n`);
      continue;
    }
    process.stdout.write(
      `  ${modeResult.mode}: load=${modeResult.pipelineLoadMs.toFixed(2)}ms mean=${modeResult.timedMeanMs.toFixed(2)}ms p50=${modeResult.timedP50Ms?.toFixed(2) ?? "n/a"}ms p95=${modeResult.timedP95Ms?.toFixed(2) ?? "n/a"}ms\n`,
    );
  }
  if (report.comparison) {
    process.stdout.write(
      `  delta (positive=doe faster): mean=${report.comparison.timedMeanDeltaPercent?.toFixed(2) ?? "n/a"}% p50=${report.comparison.timedP50DeltaPercent?.toFixed(2) ?? "n/a"}% p95=${report.comparison.timedP95DeltaPercent?.toFixed(2) ?? "n/a"}% load=${report.comparison.pipelineLoadDeltaPercent?.toFixed(2) ?? "n/a"}%\n`,
    );
  }
}

async function main() {
  const args = parseArgs(process.argv);
  const chromium = await loadChromiumDriver();
  const serverInfo = await startLocalServer(args);
  try {
    const modes = args.mode === "both" ? ["dawn", "doe"] : [args.mode];
    const modeResults = [];
    for (const mode of modes) {
      modeResults.push(await runMode(chromium, mode, args, serverInfo.url, serverInfo.port));
    }
    const report = buildReport(args, serverInfo, modeResults);
    mkdirSync(dirname(args.outPath), { recursive: true });
    writeFileSync(args.outPath, `${JSON.stringify(report, null, 2)}\n`);
    printSummary(report);
    process.stdout.write(`  report: ${args.outPath}\n`);
    if (args.strict && modeResults.some((entry) => !entry.success)) {
      process.exitCode = 1;
    }
  } finally {
    await new Promise((resolveClose, rejectClose) => {
      serverInfo.server.close((error) => {
        if (error) {
          rejectClose(error);
          return;
        }
        resolveClose();
      });
    });
  }
}

await main();

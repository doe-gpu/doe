#!/usr/bin/env node
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
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

const DEFAULT_CHROME = defaultChromePath();
const DEFAULT_DOE_LIB = defaultDoeLibPath();
const DEFAULT_RUNTIME_SELECTOR_POLICY = resolve(ROOT, "config/browser-runtime-selector-policy.json");
const BENCH_OUT_ROOT = resolve(ROOT, "bench/out");
const DEFAULT_OUT_FILE = "dawn-vs-doe.browser.playwright-smoke.diagnostic.json";
const FLIGHT_RECORDER_BUILDER = resolve(
  ROOT,
  "browser/chromium/scripts/build-browser-gpu-flight-recorder.py",
);
const CANVAS_WEBGPU_FUSION_BUILDER = resolve(
  ROOT,
  "browser/chromium/scripts/build-browser-canvas-webgpu-fusion.py",
);
const MEDIA_PATH_PROBE_BUILDER = resolve(
  ROOT,
  "browser/chromium/scripts/build-browser-media-path-probe.py",
);
const RECOVERY_PARITY_BUILDER = resolve(
  ROOT,
  "browser/chromium/scripts/build-browser-recovery-parity.py",
);
const GPU_SCHEDULER_BUILDER = resolve(
  ROOT,
  "browser/chromium/scripts/build-browser-gpu-scheduler.py",
);
const WEBGPU_EFFECT_EXPERIMENT_BUILDER = resolve(
  ROOT,
  "browser/chromium/scripts/build-browser-webgpu-effect-experiment.py",
);
const LOCAL_AI_WORKLOADS_BUILDER = resolve(
  ROOT,
  "browser/chromium/scripts/build-browser-local-ai-workloads.py",
);
const SHADER_LINKS_BUILDER = resolve(
  ROOT,
  "browser/chromium/scripts/build-browser-shader-links.py",
);
const PIPELINE_CACHE_RECEIPTS_BUILDER = resolve(
  ROOT,
  "browser/chromium/scripts/build-browser-pipeline-cache-receipts.py",
);
const FALLBACK_EXPLANATIONS_BUILDER = resolve(
  ROOT,
  "browser/chromium/scripts/build-browser-fallback-explanations.py",
);
const CTS_SUBSET_BUILDER = resolve(
  ROOT,
  "browser/chromium/scripts/build-browser-cts-subset.py",
);
const DEFAULT_API_SURFACE = "native";
const DEFAULT_UPLOAD_ITERS = 500;
const DEFAULT_DISPATCH_ITERS = 200;
const DEFAULT_SUITE_TIMEOUT_MS = 120000;
const DEFAULT_OPERATION_TIMEOUT_MS = 30000;
const DEFAULT_BROWSER_CLOSE_TIMEOUT_MS = 10000;
const REPORT_SCHEMA_VERSION = 1;
const REPORT_KIND = "chromium-webgpu-playwright-smoke";
const BENCHMARK_CLASS = "diagnostic";
const TIMING_CLASS = "browser-operation-proxy";
const TIMING_SOURCE = "performance.now";
const HASH_ALGORITHM = "sha256";
const RUNTIME_SELECTOR_VERSION = "browser-runtime-selector-v1";
const UPLOAD_WARMUP_ITERS = 50;
const DISPATCH_WARMUP_ITERS = 20;
const COPY_BYTES_PER_ROW_ALIGNMENT = 256;
const TEXTURE_BYTES_PER_PIXEL = 4;
const ADAPTER_LIMIT_KEYS = [
  "maxTextureDimension1D",
  "maxTextureDimension2D",
  "maxTextureDimension3D",
  "maxTextureArrayLayers",
  "maxBindGroups",
  "maxBindingsPerBindGroup",
  "maxDynamicUniformBuffersPerPipelineLayout",
  "maxDynamicStorageBuffersPerPipelineLayout",
  "maxSampledTexturesPerShaderStage",
  "maxSamplersPerShaderStage",
  "maxStorageBuffersPerShaderStage",
  "maxStorageTexturesPerShaderStage",
  "maxUniformBuffersPerShaderStage",
  "maxUniformBufferBindingSize",
  "maxStorageBufferBindingSize",
  "maxBufferSize",
  "maxComputeInvocationsPerWorkgroup",
  "maxComputeWorkgroupSizeX",
  "maxComputeWorkgroupSizeY",
  "maxComputeWorkgroupSizeZ",
  "maxComputeWorkgroupsPerDimension",
  "maxComputeWorkgroupStorageSize",
];

function usage() {
  console.log(`Usage:
  node browser/chromium/scripts/webgpu-playwright-smoke.mjs [options]

Options:
  --mode dawn|doe|auto|both Runtime mode to run (default: both)
  --chrome PATH             Chrome binary path
  --doe-lib PATH            libwebgpu_doe_full.{so,dylib,dll} path (for doe mode)
  --runtime-selector-policy PATH
                            Runtime selector policy JSON path (default: config/browser-runtime-selector-policy.json)
  --runtime-selector-profile-id ID
                            Optional selector profileId for auto denylist checks
  --runtime-selector-profile-vendor VENDOR
                            Optional selector profile vendor for evidence receipts
  --runtime-selector-profile-api API
                            Optional selector profile API for evidence receipts
  --runtime-selector-profile-device-family DEVICE
                            Optional selector profile device family for evidence receipts
  --runtime-selector-profile-driver DRIVER
                            Optional selector profile driver for evidence receipts
  --out PATH                JSON report output path (default: browser/chromium/artifacts/<timestamp>/${DEFAULT_OUT_FILE})
  --allow-bench-out         Allow writing this diagnostic report under bench/out
  --headless true|false     Launch headless (default: true)
  --api-surface SURFACE     Browser API surface: native|package-browser (default: ${DEFAULT_API_SURFACE})
  --chrome-arg ARG          Extra Chromium arg (repeatable)
  --upload-iters N          queue.writeBuffer timed iterations (default: 500)
  --dispatch-iters N        compute dispatch timed iterations (default: 200)
  --suite-timeout-ms N      Max time for one mode suite run (default: 120000)
  --op-timeout-ms N         Max time for one async WebGPU wait op (default: 30000)
  --flight-recorder-components PATH
                            Component manifest for optional browser_gpu_flight_recorder output
  --flight-recorder-out PATH
                            Output path for optional browser_gpu_flight_recorder artifact
  --flight-recorder-mode dawn|doe
                            Runtime mode to extract for optional flight recorder (default: doe)
  --shader-links-out PATH
                            Output path for optional browser_shader_links artifact; requires --flight-recorder-out
  --canvas-webgpu-fusion-out PATH
                            Output path for optional browser_canvas_webgpu_fusion_probe artifact
  --canvas-webgpu-fusion-mode dawn|doe
                            Runtime mode to extract for optional canvas/WebGPU fusion probe (default: doe)
  --media-path-probe-out PATH
                            Output path for optional browser_media_path_probe artifact
  --media-path-probe-mode dawn|doe
                            Runtime mode to extract for optional media path probe (default: doe)
  --media-path-probe-capture-policy PATH
                            Browser capture policy for optional media path probe
  --recovery-parity-out PATH
                            Output path for optional browser_recovery_parity artifact
  --cts-subset-out PATH
                            Output path for optional browser_cts_subset artifact; requires --mode both
  --gpu-scheduler-out PATH
                            Output path for optional browser_gpu_scheduler_probe artifact
  --gpu-scheduler-mode dawn|doe
                            Runtime mode to extract for optional GPU scheduler probe (default: doe)
  --webgpu-effect-experiment-out PATH
                            Output path for optional browser_webgpu_effect_experiment artifact
  --webgpu-effect-experiment-mode dawn|doe
                            Runtime mode to extract for optional WebGPU effect experiment (default: doe)
  --local-ai-workloads-out PATH
                            Output path for optional browser_local_ai_workloads artifact
  --local-ai-workloads-mode dawn|doe
                            Runtime mode to extract for optional local AI workloads (default: doe)
  --pipeline-cache-receipts-out PATH
                            Output path for optional browser_pipeline_cache_receipts artifact; requires --local-ai-workloads-out
  --fallback-explanations-out PATH
                            Output path for optional browser_fallback_explanations artifact
  --fallback-explanations-mode dawn|doe
                            Runtime mode to extract for optional fallback explanations (default: doe)
  --fallback-explanations-taxonomy PATH
                            Browser unsupported/fallback reason taxonomy path
  --strict                  Exit non-zero if any smoke test fails
  --help                    Show this message
`);
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

function makeFailedResult(mode, args, launchArgs, browserVersion, startMs, error) {
  const errorText = String(error?.stack ?? error);
  const selection = runtimeSelectionResolution(mode, args);
  const runtimeSelection = buildRuntimeSelection(mode, args, launchArgs);
  return {
    mode,
    apiSurface: args.apiSurface,
    runtimeSelection,
    shaderCompilerIdentity: shaderCompilerIdentity(mode, args),
    runtimeArgs: runtimeArgs(selection.selectedRuntime, args.doeLibPath),
    launchArgs,
    browserVersion,
    elapsedMs: Date.now() - startMs,
    webgpuAvailable: false,
    adapterAvailable: false,
    adapterInfo: null,
    adapterIdentity: adapterIdentityFromSmokeResult(null, runtimeSelection.profile),
    features: [],
    limits: {},
    wgslLanguageFeatures: [],
    webgpuCanvasApi: {
      offscreenCanvasAvailable: false,
      webgpuContextAvailable: false,
      webgpuContextHasConfigure: false,
      webgpuContextHasGetCurrentTexture: false,
      preferredCanvasFormatSupported: false,
      preferredCanvasFormat: null,
    },
    smoke: {
      computeIncrement: { pass: false, actual: null, expected: [2, 3, 4, 5], error: errorText },
      renderTriangle: { pass: false, centerRgba: null, error: errorText },
      requestAdapterXrCompatible: {
        pass: false,
        returnedAdapter: false,
        forwarded: null,
        observedOptions: null,
        error: errorText,
      },
      copyExternalImageToTexture: {
        pass: false,
        topLeftRgba: null,
        sourceType: null,
        attempts: [],
        error: errorText,
      },
      importExternalTexture: {
        pass: false,
        centerRgba: null,
        error: errorText,
      },
      renderBundle: { pass: false, centerRgba: null, error: errorText },
      renderIndirect: { pass: false, centerRgba: null, error: errorText },
      timestampQuery: { pass: false, actual: null, error: errorText },
      recovery: {
        validationError: { pass: false, captured: false, messageCount: 0, error: errorText },
        deviceLost: { pass: false, promiseAvailable: false, error: errorText },
        postValidationCompute: { pass: false, actual: null, expected: [2, 3, 4, 5], error: errorText },
      },
    },
    benches: {
      writeBuffer64kbUsPerOp: null,
      computeDispatchUsPerOp: null,
      iterations: { upload: args.uploadIters, dispatch: args.dispatchIters },
      errors: [errorText],
    },
    errors: [errorText],
  };
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

function pathWithin(pathValue, rootPath) {
  const absolutePath = resolve(pathValue);
  const absoluteRoot = resolve(rootPath);
  return absolutePath === absoluteRoot || absolutePath.startsWith(`${absoluteRoot}/`);
}

function resolveInvocationPath(pathValue) {
  if (typeof pathValue !== "string" || pathValue.length === 0) {
    return "";
  }
  return resolve(process.cwd(), pathValue);
}

function normalizePathArgs(args) {
  const pathFields = [
    "chromePath",
    "doeLibPath",
    "runtimeSelectorPolicyPath",
    "outPath",
    "flightRecorderComponentsPath",
    "flightRecorderOutPath",
    "shaderLinksOutPath",
    "canvasWebgpuFusionOutPath",
    "mediaPathProbeOutPath",
    "recoveryParityOutPath",
    "ctsSubsetOutPath",
    "gpuSchedulerOutPath",
    "webgpuEffectExperimentOutPath",
    "localAiWorkloadsOutPath",
    "pipelineCacheReceiptsOutPath",
    "fallbackExplanationsOutPath",
  ];
  for (const field of pathFields) {
    args[field] = resolveInvocationPath(args[field]);
  }
}

function ensureAllowedOutPath(outPath, allowBenchOut) {
  if (!allowBenchOut && pathWithin(outPath, BENCH_OUT_ROOT)) {
    throw new Error(
      `refusing to write diagnostic browser smoke output to ${BENCH_OUT_ROOT}; write under browser/chromium/artifacts or pass --allow-bench-out explicitly`,
    );
  }
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

function attachHashChain(entries) {
  let previousHash = null;
  return entries.map((entry) => {
    const hash = hashHex({ previousHash, entry });
    const withHash = { ...entry, previousHash, hash };
    previousHash = hash;
    return withHash;
  });
}

function parseArgs(argv) {
  const args = {
    mode: "both",
    chromePath: DEFAULT_CHROME,
    doeLibPath: DEFAULT_DOE_LIB,
    runtimeSelectorPolicyPath: DEFAULT_RUNTIME_SELECTOR_POLICY,
    runtimeSelectorPolicy: null,
    runtimeSelectorProfileId: "",
    runtimeSelectorProfileVendor: "",
    runtimeSelectorProfileApi: "",
    runtimeSelectorProfileDeviceFamily: "",
    runtimeSelectorProfileDriver: "",
    outPath: defaultOutPath(),
    allowBenchOut: false,
    headless: true,
    apiSurface: DEFAULT_API_SURFACE,
    chromeArgs: [],
    uploadIters: DEFAULT_UPLOAD_ITERS,
    dispatchIters: DEFAULT_DISPATCH_ITERS,
    suiteTimeoutMs: DEFAULT_SUITE_TIMEOUT_MS,
    opTimeoutMs: DEFAULT_OPERATION_TIMEOUT_MS,
    flightRecorderComponentsPath: "",
    flightRecorderOutPath: "",
    flightRecorderMode: "doe",
    shaderLinksOutPath: "",
    canvasWebgpuFusionOutPath: "",
    canvasWebgpuFusionMode: "doe",
    mediaPathProbeOutPath: "",
    mediaPathProbeMode: "doe",
    mediaPathProbeCapturePolicyPath: "config/browser-capture-policy.json",
    recoveryParityOutPath: "",
    ctsSubsetOutPath: "",
    gpuSchedulerOutPath: "",
    gpuSchedulerMode: "doe",
    webgpuEffectExperimentOutPath: "",
    webgpuEffectExperimentMode: "doe",
    localAiWorkloadsOutPath: "",
    localAiWorkloadsMode: "doe",
    pipelineCacheReceiptsOutPath: "",
    fallbackExplanationsOutPath: "",
    fallbackExplanationsMode: "doe",
    fallbackExplanationsTaxonomyPath: "config/browser-unsupported-reason-taxonomy.json",
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
      args.mode = readOptionValue(argv, i, "--mode").toLowerCase();
      i += 1;
    } else if (token === "--chrome") {
      args.chromePath = readOptionValue(argv, i, "--chrome");
      i += 1;
    } else if (token === "--doe-lib") {
      args.doeLibPath = readOptionValue(argv, i, "--doe-lib");
      i += 1;
    } else if (token === "--runtime-selector-policy") {
      args.runtimeSelectorPolicyPath = readOptionValue(argv, i, "--runtime-selector-policy");
      i += 1;
    } else if (token === "--runtime-selector-profile-id") {
      args.runtimeSelectorProfileId = readOptionValue(argv, i, "--runtime-selector-profile-id");
      i += 1;
    } else if (token === "--runtime-selector-profile-vendor") {
      args.runtimeSelectorProfileVendor = readOptionValue(argv, i, "--runtime-selector-profile-vendor");
      i += 1;
    } else if (token === "--runtime-selector-profile-api") {
      args.runtimeSelectorProfileApi = readOptionValue(argv, i, "--runtime-selector-profile-api");
      i += 1;
    } else if (token === "--runtime-selector-profile-device-family") {
      args.runtimeSelectorProfileDeviceFamily = readOptionValue(
        argv,
        i,
        "--runtime-selector-profile-device-family",
      );
      i += 1;
    } else if (token === "--runtime-selector-profile-driver") {
      args.runtimeSelectorProfileDriver = readOptionValue(argv, i, "--runtime-selector-profile-driver");
      i += 1;
    } else if (token === "--out") {
      args.outPath = readOptionValue(argv, i, "--out");
      i += 1;
    } else if (token === "--headless") {
      args.headless = parseBool(readOptionValue(argv, i, "--headless"), "--headless");
      i += 1;
    } else if (token === "--api-surface") {
      args.apiSurface = readOptionValue(argv, i, "--api-surface").toLowerCase();
      i += 1;
    } else if (token === "--chrome-arg") {
      args.chromeArgs.push(readOptionValue(argv, i, "--chrome-arg"));
      i += 1;
    } else if (token === "--upload-iters") {
      args.uploadIters = parsePositiveInt(readOptionValue(argv, i, "--upload-iters"), "--upload-iters");
      i += 1;
    } else if (token === "--dispatch-iters") {
      args.dispatchIters = parsePositiveInt(
        readOptionValue(argv, i, "--dispatch-iters"),
        "--dispatch-iters",
      );
      i += 1;
    } else if (token === "--suite-timeout-ms") {
      args.suiteTimeoutMs = parsePositiveInt(
        readOptionValue(argv, i, "--suite-timeout-ms"),
        "--suite-timeout-ms",
      );
      i += 1;
    } else if (token === "--op-timeout-ms") {
      args.opTimeoutMs = parsePositiveInt(
        readOptionValue(argv, i, "--op-timeout-ms"),
        "--op-timeout-ms",
      );
      i += 1;
    } else if (token === "--flight-recorder-components") {
      args.flightRecorderComponentsPath = readOptionValue(argv, i, "--flight-recorder-components");
      i += 1;
    } else if (token === "--flight-recorder-out") {
      args.flightRecorderOutPath = readOptionValue(argv, i, "--flight-recorder-out");
      i += 1;
    } else if (token === "--flight-recorder-mode") {
      args.flightRecorderMode = readOptionValue(argv, i, "--flight-recorder-mode").toLowerCase();
      i += 1;
    } else if (token === "--shader-links-out") {
      args.shaderLinksOutPath = readOptionValue(argv, i, "--shader-links-out");
      i += 1;
    } else if (token === "--canvas-webgpu-fusion-out") {
      args.canvasWebgpuFusionOutPath = readOptionValue(argv, i, "--canvas-webgpu-fusion-out");
      i += 1;
    } else if (token === "--canvas-webgpu-fusion-mode") {
      args.canvasWebgpuFusionMode = readOptionValue(argv, i, "--canvas-webgpu-fusion-mode").toLowerCase();
      i += 1;
    } else if (token === "--media-path-probe-out") {
      args.mediaPathProbeOutPath = readOptionValue(argv, i, "--media-path-probe-out");
      i += 1;
    } else if (token === "--media-path-probe-mode") {
      args.mediaPathProbeMode = readOptionValue(argv, i, "--media-path-probe-mode").toLowerCase();
      i += 1;
    } else if (token === "--media-path-probe-capture-policy") {
      args.mediaPathProbeCapturePolicyPath = readOptionValue(argv, i, "--media-path-probe-capture-policy");
      i += 1;
    } else if (token === "--recovery-parity-out") {
      args.recoveryParityOutPath = readOptionValue(argv, i, "--recovery-parity-out");
      i += 1;
    } else if (token === "--cts-subset-out") {
      args.ctsSubsetOutPath = readOptionValue(argv, i, "--cts-subset-out");
      i += 1;
    } else if (token === "--gpu-scheduler-out") {
      args.gpuSchedulerOutPath = readOptionValue(argv, i, "--gpu-scheduler-out");
      i += 1;
    } else if (token === "--gpu-scheduler-mode") {
      args.gpuSchedulerMode = readOptionValue(argv, i, "--gpu-scheduler-mode").toLowerCase();
      i += 1;
    } else if (token === "--webgpu-effect-experiment-out") {
      args.webgpuEffectExperimentOutPath = readOptionValue(argv, i, "--webgpu-effect-experiment-out");
      i += 1;
    } else if (token === "--webgpu-effect-experiment-mode") {
      args.webgpuEffectExperimentMode = readOptionValue(argv, i, "--webgpu-effect-experiment-mode").toLowerCase();
      i += 1;
    } else if (token === "--local-ai-workloads-out") {
      args.localAiWorkloadsOutPath = readOptionValue(argv, i, "--local-ai-workloads-out");
      i += 1;
    } else if (token === "--local-ai-workloads-mode") {
      args.localAiWorkloadsMode = readOptionValue(argv, i, "--local-ai-workloads-mode").toLowerCase();
      i += 1;
    } else if (token === "--pipeline-cache-receipts-out") {
      args.pipelineCacheReceiptsOutPath = readOptionValue(argv, i, "--pipeline-cache-receipts-out");
      i += 1;
    } else if (token === "--fallback-explanations-out") {
      args.fallbackExplanationsOutPath = readOptionValue(argv, i, "--fallback-explanations-out");
      i += 1;
    } else if (token === "--fallback-explanations-mode") {
      args.fallbackExplanationsMode = readOptionValue(argv, i, "--fallback-explanations-mode").toLowerCase();
      i += 1;
    } else if (token === "--fallback-explanations-taxonomy") {
      args.fallbackExplanationsTaxonomyPath = readOptionValue(argv, i, "--fallback-explanations-taxonomy");
      i += 1;
    } else {
      throw new Error(`unknown argument: ${token}`);
    }
  }

  normalizePathArgs(args);
  if (!["dawn", "doe", "auto", "both"].includes(args.mode)) {
    throw new Error("--mode must be one of dawn, doe, auto, both");
  }
  if (!existsSync(args.runtimeSelectorPolicyPath)) {
    throw new Error(`runtime selector policy not found: ${args.runtimeSelectorPolicyPath}`);
  }
  args.runtimeSelectorPolicy = loadRuntimeSelectorPolicy(args.runtimeSelectorPolicyPath);
  if (!["native", "package-browser"].includes(args.apiSurface)) {
    throw new Error("--api-surface must be one of native, package-browser");
  }
  if (!["dawn", "doe"].includes(args.flightRecorderMode)) {
    throw new Error("--flight-recorder-mode must be one of dawn, doe");
  }
  if (!["dawn", "doe"].includes(args.canvasWebgpuFusionMode)) {
    throw new Error("--canvas-webgpu-fusion-mode must be one of dawn, doe");
  }
  if (!["dawn", "doe"].includes(args.mediaPathProbeMode)) {
    throw new Error("--media-path-probe-mode must be one of dawn, doe");
  }
  if (!["dawn", "doe"].includes(args.gpuSchedulerMode)) {
    throw new Error("--gpu-scheduler-mode must be one of dawn, doe");
  }
  if (!["dawn", "doe"].includes(args.webgpuEffectExperimentMode)) {
    throw new Error("--webgpu-effect-experiment-mode must be one of dawn, doe");
  }
  if (!["dawn", "doe"].includes(args.localAiWorkloadsMode)) {
    throw new Error("--local-ai-workloads-mode must be one of dawn, doe");
  }
  if (!["dawn", "doe"].includes(args.fallbackExplanationsMode)) {
    throw new Error("--fallback-explanations-mode must be one of dawn, doe");
  }
  const hasFlightRecorderComponent = args.flightRecorderComponentsPath.length > 0;
  const hasFlightRecorderOut = args.flightRecorderOutPath.length > 0;
  if (hasFlightRecorderComponent !== hasFlightRecorderOut) {
    throw new Error("--flight-recorder-components and --flight-recorder-out must be provided together");
  }
  if (args.shaderLinksOutPath.length > 0 && !hasFlightRecorderOut) {
    throw new Error("--shader-links-out requires --flight-recorder-out");
  }
  if (hasFlightRecorderComponent && !existsSync(args.flightRecorderComponentsPath)) {
    throw new Error(`flight recorder component manifest not found: ${args.flightRecorderComponentsPath}`);
  }
  if (hasFlightRecorderComponent && args.mode !== "both" && args.mode !== args.flightRecorderMode) {
    throw new Error(
      `--flight-recorder-mode ${args.flightRecorderMode} is not included in --mode ${args.mode}`,
    );
  }
  if (args.canvasWebgpuFusionOutPath.length > 0 && args.mode !== "both" && args.mode !== args.canvasWebgpuFusionMode) {
    throw new Error(
      `--canvas-webgpu-fusion-mode ${args.canvasWebgpuFusionMode} is not included in --mode ${args.mode}`,
    );
  }
  if (args.mediaPathProbeOutPath.length > 0 && args.mode !== "both" && args.mode !== args.mediaPathProbeMode) {
    throw new Error(
      `--media-path-probe-mode ${args.mediaPathProbeMode} is not included in --mode ${args.mode}`,
    );
  }
  if (args.recoveryParityOutPath.length > 0 && args.mode !== "both") {
    throw new Error("--recovery-parity-out requires --mode both");
  }
  if (args.ctsSubsetOutPath.length > 0 && args.mode !== "both") {
    throw new Error("--cts-subset-out requires --mode both");
  }
  if (args.gpuSchedulerOutPath.length > 0 && args.mode !== "both" && args.mode !== args.gpuSchedulerMode) {
    throw new Error(
      `--gpu-scheduler-mode ${args.gpuSchedulerMode} is not included in --mode ${args.mode}`,
    );
  }
  if (
    args.webgpuEffectExperimentOutPath.length > 0 &&
    args.mode !== "both" &&
    args.mode !== args.webgpuEffectExperimentMode
  ) {
    throw new Error(
      `--webgpu-effect-experiment-mode ${args.webgpuEffectExperimentMode} is not included in --mode ${args.mode}`,
    );
  }
  if (args.localAiWorkloadsOutPath.length > 0 && args.mode !== "both" && args.mode !== args.localAiWorkloadsMode) {
    throw new Error(
      `--local-ai-workloads-mode ${args.localAiWorkloadsMode} is not included in --mode ${args.mode}`,
    );
  }
  if (args.pipelineCacheReceiptsOutPath.length > 0 && args.localAiWorkloadsOutPath.length === 0) {
    throw new Error("--pipeline-cache-receipts-out requires --local-ai-workloads-out");
  }
  if (
    args.fallbackExplanationsOutPath.length > 0 &&
    args.mode !== "both" &&
    args.mode !== args.fallbackExplanationsMode
  ) {
    throw new Error(
      `--fallback-explanations-mode ${args.fallbackExplanationsMode} is not included in --mode ${args.mode}`,
    );
  }
  ensureAllowedOutPath(args.outPath, args.allowBenchOut);
  if (!existsSync(args.chromePath)) {
    throw new Error(`chrome binary not found: ${args.chromePath}`);
  }
  if ((args.mode === "doe" || args.mode === "both") && !existsSync(args.doeLibPath)) {
    throw new Error(`doe runtime library not found: ${args.doeLibPath}`);
  }
  return args;
}

function maybeWriteFlightRecorder(args) {
  if (!args.flightRecorderComponentsPath || !args.flightRecorderOutPath) {
    return null;
  }
  const command = [
    FLIGHT_RECORDER_BUILDER,
    "--report",
    args.outPath,
    "--components",
    args.flightRecorderComponentsPath,
    "--mode",
    args.flightRecorderMode,
    "--scenario-id",
    "webgpu-playwright-smoke",
    "--workload-id",
    "browser_webgpu_smoke",
    "--origin",
    "browser-chromium-smoke",
    "--out",
    args.flightRecorderOutPath,
  ];
  const result = spawnSync("python3", command, {
    cwd: ROOT,
    encoding: "utf8",
  });
  if (result.stdout) {
    process.stdout.write(result.stdout);
  }
  if (result.stderr) {
    process.stderr.write(result.stderr);
  }
  if (result.status !== 0) {
    throw new Error(`flight recorder builder failed with exit code ${result.status}`);
  }
  return args.flightRecorderOutPath;
}

function maybeWriteShaderLinks(args) {
  if (!args.shaderLinksOutPath) {
    return null;
  }
  const command = [
    SHADER_LINKS_BUILDER,
    "--flight-recorder",
    args.flightRecorderOutPath,
    "--out",
    args.shaderLinksOutPath,
  ];
  const result = spawnSync("python3", command, {
    cwd: ROOT,
    encoding: "utf8",
  });
  if (result.stdout) {
    process.stdout.write(result.stdout);
  }
  if (result.stderr) {
    process.stderr.write(result.stderr);
  }
  if (result.status !== 0) {
    throw new Error(`shader links builder failed with exit code ${result.status}`);
  }
  return args.shaderLinksOutPath;
}

function maybeWriteCanvasWebgpuFusion(args) {
  if (!args.canvasWebgpuFusionOutPath) {
    return null;
  }
  const command = [
    CANVAS_WEBGPU_FUSION_BUILDER,
    "--report",
    args.outPath,
    "--mode",
    args.canvasWebgpuFusionMode,
    "--out",
    args.canvasWebgpuFusionOutPath,
  ];
  const result = spawnSync("python3", command, {
    cwd: ROOT,
    encoding: "utf8",
  });
  if (result.stdout) {
    process.stdout.write(result.stdout);
  }
  if (result.stderr) {
    process.stderr.write(result.stderr);
  }
  if (result.status !== 0) {
    throw new Error(`canvas/WebGPU fusion builder failed with exit code ${result.status}`);
  }
  return args.canvasWebgpuFusionOutPath;
}

function maybeWriteMediaPathProbe(args) {
  if (!args.mediaPathProbeOutPath) {
    return null;
  }
  const command = [
    MEDIA_PATH_PROBE_BUILDER,
    "--report",
    args.outPath,
    "--mode",
    args.mediaPathProbeMode,
    "--out",
    args.mediaPathProbeOutPath,
    "--capture-policy",
    args.mediaPathProbeCapturePolicyPath,
  ];
  const result = spawnSync("python3", command, {
    cwd: ROOT,
    encoding: "utf8",
  });
  if (result.stdout) {
    process.stdout.write(result.stdout);
  }
  if (result.stderr) {
    process.stderr.write(result.stderr);
  }
  if (result.status !== 0) {
    throw new Error(`media path probe builder failed with exit code ${result.status}`);
  }
  return args.mediaPathProbeOutPath;
}

function maybeWriteRecoveryParity(args) {
  if (!args.recoveryParityOutPath) {
    return null;
  }
  const command = [
    RECOVERY_PARITY_BUILDER,
    "--report",
    args.outPath,
    "--out",
    args.recoveryParityOutPath,
  ];
  const result = spawnSync("python3", command, {
    cwd: ROOT,
    encoding: "utf8",
  });
  if (result.stdout) {
    process.stdout.write(result.stdout);
  }
  if (result.stderr) {
    process.stderr.write(result.stderr);
  }
  if (result.status !== 0) {
    throw new Error(`recovery parity builder failed with exit code ${result.status}`);
  }
  return args.recoveryParityOutPath;
}

function maybeWriteCtsSubset(args) {
  if (!args.ctsSubsetOutPath) {
    return null;
  }
  const command = [
    CTS_SUBSET_BUILDER,
    "--report",
    args.outPath,
    "--out",
    args.ctsSubsetOutPath,
  ];
  const result = spawnSync("python3", command, {
    cwd: ROOT,
    encoding: "utf8",
  });
  if (result.stdout) {
    process.stdout.write(result.stdout);
  }
  if (result.stderr) {
    process.stderr.write(result.stderr);
  }
  if (result.status !== 0) {
    throw new Error(`CTS subset builder failed with exit code ${result.status}`);
  }
  return args.ctsSubsetOutPath;
}

function maybeWriteGpuScheduler(args) {
  if (!args.gpuSchedulerOutPath) {
    return null;
  }
  const command = [
    GPU_SCHEDULER_BUILDER,
    "--report",
    args.outPath,
    "--mode",
    args.gpuSchedulerMode,
    "--out",
    args.gpuSchedulerOutPath,
  ];
  const result = spawnSync("python3", command, {
    cwd: ROOT,
    encoding: "utf8",
  });
  if (result.stdout) {
    process.stdout.write(result.stdout);
  }
  if (result.stderr) {
    process.stderr.write(result.stderr);
  }
  if (result.status !== 0) {
    throw new Error(`GPU scheduler builder failed with exit code ${result.status}`);
  }
  return args.gpuSchedulerOutPath;
}

function maybeWriteWebgpuEffectExperiment(args) {
  if (!args.webgpuEffectExperimentOutPath) {
    return null;
  }
  const command = [
    WEBGPU_EFFECT_EXPERIMENT_BUILDER,
    "--report",
    args.outPath,
    "--mode",
    args.webgpuEffectExperimentMode,
    "--out",
    args.webgpuEffectExperimentOutPath,
  ];
  const result = spawnSync("python3", command, {
    cwd: ROOT,
    encoding: "utf8",
  });
  if (result.stdout) {
    process.stdout.write(result.stdout);
  }
  if (result.stderr) {
    process.stderr.write(result.stderr);
  }
  if (result.status !== 0) {
    throw new Error(`WebGPU effect experiment builder failed with exit code ${result.status}`);
  }
  return args.webgpuEffectExperimentOutPath;
}

function maybeWriteLocalAiWorkloads(args) {
  if (!args.localAiWorkloadsOutPath) {
    return null;
  }
  const command = [
    LOCAL_AI_WORKLOADS_BUILDER,
    "--report",
    args.outPath,
    "--mode",
    args.localAiWorkloadsMode,
    "--out",
    args.localAiWorkloadsOutPath,
  ];
  const result = spawnSync("python3", command, {
    cwd: ROOT,
    encoding: "utf8",
  });
  if (result.stdout) {
    process.stdout.write(result.stdout);
  }
  if (result.stderr) {
    process.stderr.write(result.stderr);
  }
  if (result.status !== 0) {
    throw new Error(`local AI workloads builder failed with exit code ${result.status}`);
  }
  return args.localAiWorkloadsOutPath;
}

function maybeWritePipelineCacheReceipts(args) {
  if (!args.pipelineCacheReceiptsOutPath) {
    return null;
  }
  const command = [
    PIPELINE_CACHE_RECEIPTS_BUILDER,
    "--workloads",
    args.localAiWorkloadsOutPath,
    "--out",
    args.pipelineCacheReceiptsOutPath,
  ];
  const result = spawnSync("python3", command, {
    cwd: ROOT,
    encoding: "utf8",
  });
  if (result.stdout) {
    process.stdout.write(result.stdout);
  }
  if (result.stderr) {
    process.stderr.write(result.stderr);
  }
  if (result.status !== 0) {
    throw new Error(`pipeline cache receipts builder failed with exit code ${result.status}`);
  }
  return args.pipelineCacheReceiptsOutPath;
}

function appendArtifactArg(command, flag, pathValue) {
  if (pathValue) {
    command.push(flag, pathValue);
  }
}

function maybeWriteFallbackExplanations(args) {
  if (!args.fallbackExplanationsOutPath) {
    return null;
  }
  const command = [
    FALLBACK_EXPLANATIONS_BUILDER,
    "--report",
    args.outPath,
    "--mode",
    args.fallbackExplanationsMode,
    "--out",
    args.fallbackExplanationsOutPath,
    "--taxonomy",
    args.fallbackExplanationsTaxonomyPath,
  ];
  appendArtifactArg(command, "--canvas-webgpu-fusion", args.canvasWebgpuFusionOutPath);
  appendArtifactArg(command, "--media-path-probe", args.mediaPathProbeOutPath);
  appendArtifactArg(command, "--gpu-scheduler", args.gpuSchedulerOutPath);
  appendArtifactArg(command, "--webgpu-effect-experiment", args.webgpuEffectExperimentOutPath);
  appendArtifactArg(command, "--local-ai-workloads", args.localAiWorkloadsOutPath);
  appendArtifactArg(command, "--pipeline-cache-receipts", args.pipelineCacheReceiptsOutPath);
  appendArtifactArg(command, "--shader-links", args.shaderLinksOutPath);
  const result = spawnSync("python3", command, {
    cwd: ROOT,
    encoding: "utf8",
  });
  if (result.stdout) {
    process.stdout.write(result.stdout);
  }
  if (result.stderr) {
    process.stderr.write(result.stderr);
  }
  if (result.status !== 0) {
    throw new Error(`fallback explanations builder failed with exit code ${result.status}`);
  }
  return args.fallbackExplanationsOutPath;
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

function startLocalServer() {
  const html = "<!doctype html><meta charset='utf-8'><title>doe-webgpu-smoke</title>";
  const server = http.createServer((req, res) => {
    const requestPath = new URL(req.url ?? "/", "http://127.0.0.1").pathname;
    if (requestPath !== "/") {
      const relativePath = requestPath.replace(/^\/+/, "");
      const absolutePath = resolve(ROOT, relativePath);
      if (!pathWithin(absolutePath, ROOT) || !existsSync(absolutePath)) {
        res.statusCode = 404;
        res.end("not found");
        return;
      }
      const extension = extname(absolutePath).toLowerCase();
      const contentType = extension === ".js" || extension === ".mjs"
        ? "text/javascript; charset=utf-8"
        : extension === ".json"
          ? "application/json; charset=utf-8"
          : extension === ".html"
            ? "text/html; charset=utf-8"
            : "text/plain; charset=utf-8";
      res.statusCode = 200;
      res.setHeader("content-type", contentType);
      res.end(readFileSync(absolutePath));
      return;
    }
    res.statusCode = 200;
    res.setHeader("content-type", "text/html; charset=utf-8");
    res.end(html);
  });

  return new Promise((resolveServer, reject) => {
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const addr = server.address();
      if (!addr || typeof addr === "string") {
        reject(new Error("failed to resolve local server address"));
        return;
      }
      resolveServer({
        server,
        url: `http://127.0.0.1:${addr.port}/`,
        port: addr.port,
      });
    });
  });
}

function baseLaunchArgs(port) {
  const args = [
    "--no-sandbox",
    "--disable-setuid-sandbox",
    "--disable-dev-shm-usage",
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

function runtimeSelectorProfile(args) {
  return {
    profileId: args.runtimeSelectorProfileId,
    vendor: args.runtimeSelectorProfileVendor,
    api: args.runtimeSelectorProfileApi,
    deviceFamily: args.runtimeSelectorProfileDeviceFamily,
    driver: args.runtimeSelectorProfileDriver,
  };
}

function runtimeSelectionResolution(mode, args) {
  return resolveRuntimeSelection({
    requestedMode: mode,
    doeLibPath: args.doeLibPath,
    policy: args.runtimeSelectorPolicy,
    profile: runtimeSelectorProfile(args),
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

function safeDeltaPercent(dawnValue, doeValue) {
  if (!Number.isFinite(dawnValue) || !Number.isFinite(doeValue) || dawnValue === 0) {
    return null;
  }
  return ((dawnValue - doeValue) / dawnValue) * 100;
}

function extractModeResult(modeResults, mode) {
  return modeResults.find((entry) => entry.mode === mode) ?? null;
}

function adapterLabel(adapterInfo, profile) {
  for (const field of ["device", "description", "name", "architecture"]) {
    const value = adapterInfo[field];
    if (typeof value === "string" && value.length > 0 && value !== "unknown") {
      return value;
    }
  }
  const deviceFamily = profile?.deviceFamily;
  if (typeof deviceFamily === "string" && deviceFamily.length > 0 && deviceFamily !== "unknown") {
    return deviceFamily;
  }
  return "";
}

function adapterIdentityFromSmokeResult(result, profile = {}) {
  const adapterInfo =
    result?.adapterInfo && typeof result.adapterInfo === "object" ? result.adapterInfo : {};
  const features = Array.isArray(result?.features) ? [...result.features].sort() : [];
  const limits = result?.limits && typeof result.limits === "object" ? result.limits : {};
  const identity = {
    adapterInfoSha256: hashHex(adapterInfo),
    featuresSha256: hashHex(features),
    limitsSha256: hashHex(limits),
    featureCount: features.length,
    limitCount: Object.keys(limits).length,
  };
  const label = adapterLabel(adapterInfo, profile);
  if (label) {
    identity.adapter = label;
  }
  return identity;
}

function smokeWorkloadIdentity() {
  const workloadIds = [
    "compute_increment",
    "render_triangle",
    "request_adapter_xr_compatible",
    "copy_external_image_to_texture",
    "import_external_texture",
    "gpu_canvas_context",
    "write_buffer_64kb",
    "compute_dispatch",
  ];
  return {
    kind: "browser_smoke_suite",
    workloadIds,
    workloadHash: hashHex(workloadIds),
  };
}

function browserSurfaceModuleUrl(baseUrl) {
  return new URL("/packages/doe-gpu/src/browser.js", baseUrl).href;
}

async function runMode(chromium, mode, args, localUrl, localPort) {
  const selection = runtimeSelectionResolution(mode, args);
  const launchArgs = [
    ...baseLaunchArgs(localPort),
    ...args.chromeArgs,
    ...runtimeArgs(selection.selectedRuntime, args.doeLibPath),
  ];
  const startMs = Date.now();
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

    const suite = await withTimeout(
      page.evaluate(
        async ({
          uploadIters,
          dispatchIters,
          uploadWarmupIters,
          dispatchWarmupIters,
          adapterLimitKeys,
          opTimeoutMs,
          apiSurface,
          browserModuleUrl,
        }) => {
          const copyBytesPerRowAlignment = 256;
          const textureBytesPerPixel = 4;
          const forwardedRequestAdapterOptions = [];
          const instrumentedGpu = apiSurface === "package-browser"
            ? {
              async requestAdapter(options) {
                forwardedRequestAdapterOptions.push(options == null ? null : structuredClone(options));
                return navigator.gpu.requestAdapter(options);
              },
              getPreferredCanvasFormat() {
                return navigator.gpu.getPreferredCanvasFormat();
              },
              get wgslLanguageFeatures() {
                return navigator.gpu.wgslLanguageFeatures;
              },
            }
            : null;
          const browserSurface = apiSurface === "package-browser"
            ? await import(browserModuleUrl)
            : null;
          const browserRuntime = browserSurface?.createBrowserRuntime?.(
            instrumentedGpu ? { gpu: instrumentedGpu } : {},
          ) ?? null;
          const gpu = browserRuntime?.gpu ?? navigator.gpu;
          const getCanvasContext = (canvas) =>
            browserRuntime ? browserRuntime.createCanvasContext(canvas) : canvas.getContext("webgpu");
          const withOpTimeout = async (label, promiseFactory) => {
            let timeoutId = null;
            try {
              return await Promise.race([
                promiseFactory(),
                new Promise((_, reject) => {
                  timeoutId = setTimeout(
                    () => reject(new Error(`${label} timed out after ${opTimeoutMs}ms`)),
                    opTimeoutMs,
                  );
                }),
              ]);
            } finally {
              if (timeoutId !== null) {
                clearTimeout(timeoutId);
              }
            }
          };
          const alignTo = (value, alignment) =>
            Math.ceil(value / alignment) * alignment;
          const readTextureRgba = async (readDevice, texture, width, height, label) => {
            const bytesPerRow = alignTo(width * textureBytesPerPixel, copyBytesPerRowAlignment);
            const readback = readDevice.createBuffer({
              size: bytesPerRow * height,
              usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
            });
            const encoder = readDevice.createCommandEncoder();
            encoder.copyTextureToBuffer(
              { texture },
              { buffer: readback, bytesPerRow, rowsPerImage: height },
              { width, height, depthOrArrayLayers: 1 },
            );
            readDevice.queue.submit([encoder.finish()]);
            await withOpTimeout(`${label} mapAsync`, () => readback.mapAsync(GPUMapMode.READ));
            const bytes = new Uint8Array(readback.getMappedRange()).slice(0);
            readback.unmap();
            readback.destroy();
            return { bytes, bytesPerRow };
          };
          const sampleRgba = (bytes, bytesPerRow, x, y) => {
            const offset = y * bytesPerRow + x * textureBytesPerPixel;
            return Array.from(bytes.slice(offset, offset + textureBytesPerPixel));
          };
          const isGreenDominant = (rgba) =>
            Array.isArray(rgba)
            && rgba[1] > 100
            && rgba[1] > rgba[0] + 20
            && rgba[1] > rgba[2] + 20;
          const isRedDominant = (rgba) =>
            Array.isArray(rgba)
            && rgba[0] > 100
            && rgba[0] > rgba[1] + 20
            && rgba[0] > rgba[2] + 20;
          const describeGpuDiagnostic = (value) => ({
            name: String(value?.name ?? ""),
            message: String(value?.message ?? ""),
            string: String(value),
          });

        const result = {
          apiSurface,
          userAgent: navigator.userAgent,
          webgpuAvailable: typeof gpu !== "undefined",
          adapterAvailable: false,
          adapterInfo: null,
          features: [],
          limits: {},
          wgslLanguageFeatures: [],
          smoke: {
            computeIncrement: { pass: false, actual: null, expected: [2, 3, 4, 5], error: null },
            renderTriangle: { pass: false, centerRgba: null, error: null },
            requestAdapterXrCompatible: {
              pass: false,
              returnedAdapter: false,
              forwarded: null,
              observedOptions: null,
              error: null,
            },
            copyExternalImageToTexture: {
              pass: false,
              topLeftRgba: null,
              sourceType: null,
              attempts: [],
              error: null,
            },
            importExternalTexture: {
              pass: false,
              centerRgba: null,
              error: null,
            },
            renderBundle: { pass: false, centerRgba: null, error: null },
            renderIndirect: { pass: false, centerRgba: null, error: null },
            timestampQuery: { pass: false, actual: null, error: null },
            recovery: {
              validationError: { pass: false, captured: false, messageCount: 0, error: null },
              deviceLost: { pass: false, promiseAvailable: false, error: null },
              postValidationCompute: { pass: false, actual: null, expected: [2, 3, 4, 5], error: null },
            },
          },
          webgpuCanvasApi: {
            offscreenCanvasAvailable: false,
            webgpuContextAvailable: false,
            webgpuContextHasConfigure: false,
            webgpuContextHasGetCurrentTexture: false,
            preferredCanvasFormatSupported: false,
            preferredCanvasFormat: null,
          },
          webgpuDeviceApi: {
            hasImportExternalTexture: false,
            hasCopyExternalImageToTexture: false,
          },
          benches: {
            writeBuffer64kbUsPerOp: null,
            computeDispatchUsPerOp: null,
            iterations: { upload: uploadIters, dispatch: dispatchIters },
            errors: [],
          },
          diagnostics: {
            uncapturedErrors: [],
            deviceLostEvents: [],
          },
          errors: [],
        };
        const attachDeviceDiagnostics = (diagnosticDevice, label) => {
          if (!diagnosticDevice || typeof diagnosticDevice !== "object") return;
          if (typeof diagnosticDevice.addEventListener === "function") {
            diagnosticDevice.addEventListener("uncapturederror", (event) => {
              result.diagnostics.uncapturedErrors.push({
                device: label,
                error: describeGpuDiagnostic(event?.error),
              });
            });
          }
          if (diagnosticDevice.lost && typeof diagnosticDevice.lost.then === "function") {
            diagnosticDevice.lost.then((info) => {
              result.diagnostics.deviceLostEvents.push({
                device: label,
                reason: String(info?.reason ?? ""),
                message: String(info?.message ?? ""),
              });
            });
          }
        };
        const settleDeviceDiagnostics = async () => {
          await Promise.resolve();
          await new Promise((resolve) => setTimeout(resolve, 0));
        };

          if (!result.webgpuAvailable) {
            result.errors.push("WebGPU surface is unavailable");
            return result;
          }

        let adapter = null;
        let device = null;
        try {
          try {
            const xrAdapter = await withOpTimeout("requestAdapter xrCompatible", () =>
              gpu.requestAdapter({ xrCompatible: false }),
            );
            result.smoke.requestAdapterXrCompatible.returnedAdapter = Boolean(xrAdapter);
            result.smoke.requestAdapterXrCompatible.observedOptions =
              forwardedRequestAdapterOptions.find((options) => options?.xrCompatible === false)
              ?? forwardedRequestAdapterOptions.at(-1)
              ?? null;
            if (typeof xrAdapter?.destroy === "function") {
              xrAdapter.destroy();
            }
            if (apiSurface === "package-browser") {
              result.smoke.requestAdapterXrCompatible.forwarded =
                result.smoke.requestAdapterXrCompatible.observedOptions?.xrCompatible === false;
              result.smoke.requestAdapterXrCompatible.pass =
                result.smoke.requestAdapterXrCompatible.returnedAdapter
                && result.smoke.requestAdapterXrCompatible.forwarded === true;
            } else {
              result.smoke.requestAdapterXrCompatible.pass =
                result.smoke.requestAdapterXrCompatible.returnedAdapter;
            }
          } catch (error) {
            result.smoke.requestAdapterXrCompatible.error = String(error);
          }

          adapter = await withOpTimeout("requestAdapter", () => gpu.requestAdapter());
          if (!adapter) {
            result.errors.push("requestAdapter returned null");
            return result;
          }
          result.adapterAvailable = true;
          result.features = Array.from(adapter.features).sort();
          if ("info" in adapter) {
            result.adapterInfo = adapter.info;
          }
          for (const key of adapterLimitKeys) {
            const value = adapter.limits[key];
            if (typeof value === "number") {
              result.limits[key] = value;
            }
          }
          if ("wgslLanguageFeatures" in gpu) {
            result.wgslLanguageFeatures = Array.from(gpu.wgslLanguageFeatures).sort();
          }

          result.webgpuCanvasApi.preferredCanvasFormatSupported =
            typeof gpu.getPreferredCanvasFormat === "function";
          if (result.webgpuCanvasApi.preferredCanvasFormatSupported) {
            try {
              result.webgpuCanvasApi.preferredCanvasFormat = gpu.getPreferredCanvasFormat();
            } catch (error) {
              result.errors.push(`getPreferredCanvasFormat failed: ${String(error)}`);
            }
          }

          if (typeof OffscreenCanvas !== "undefined") {
            result.webgpuCanvasApi.offscreenCanvasAvailable = true;
            const canvas = new OffscreenCanvas(1, 1);
            const context = getCanvasContext(canvas);
            result.webgpuCanvasApi.webgpuContextAvailable = Boolean(context);
            if (context) {
              result.webgpuCanvasApi.webgpuContextHasConfigure = typeof context.configure === "function";
              result.webgpuCanvasApi.webgpuContextHasGetCurrentTexture =
                typeof context.getCurrentTexture === "function";
            }
          } else {
            result.webgpuCanvasApi.offscreenCanvasAvailable = false;
          }

          device = await withOpTimeout("requestDevice", () => adapter.requestDevice());
          attachDeviceDiagnostics(device, "primary");
          result.webgpuDeviceApi.hasImportExternalTexture =
            typeof device.importExternalTexture === "function";
          result.webgpuDeviceApi.hasCopyExternalImageToTexture =
            typeof device.queue?.copyExternalImageToTexture === "function";
          try {
            result.smoke.recovery.deviceLost.promiseAvailable =
              Boolean(device.lost) && typeof device.lost.then === "function";
            result.smoke.recovery.deviceLost.pass =
              result.smoke.recovery.deviceLost.promiseAvailable;
          } catch (error) {
            result.smoke.recovery.deviceLost.error = String(error);
          }
        } catch (error) {
          result.errors.push(`adapter/device init failed: ${String(error)}`);
          return result;
        }

        try {
          const invalidShader = device.createShaderModule({
            code: `
              @compute @workgroup_size(1)
              fn main() {
                let value: missing_type = 1;
              }
            `,
          });
          const info = await withOpTimeout("invalid shader getCompilationInfo", () =>
            invalidShader.getCompilationInfo(),
          );
          const messages = Array.from(info.messages ?? []);
          result.smoke.recovery.validationError.messageCount = messages.length;
          result.smoke.recovery.validationError.captured =
            messages.some((message) => message.type === "error");
          result.smoke.recovery.validationError.pass =
            result.smoke.recovery.validationError.captured;
        } catch (error) {
          result.smoke.recovery.validationError.error = String(error);
        }

        try {
          const input = new Uint32Array([1, 2, 3, 4]);
          const storage = device.createBuffer({
            size: input.byteLength,
            usage:
              GPUBufferUsage.STORAGE |
              GPUBufferUsage.COPY_SRC |
              GPUBufferUsage.COPY_DST,
          });
          device.queue.writeBuffer(storage, 0, input);
          const readback = device.createBuffer({
            size: input.byteLength,
            usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
          });

          const shader = device.createShaderModule({
            code: `
              @group(0) @binding(0) var<storage, read_write> data: array<u32>;
              @compute @workgroup_size(1)
              fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
                let idx = gid.x;
                data[idx] = data[idx] + 1u;
              }
            `,
          });
          const pipeline = device.createComputePipeline({
            layout: "auto",
            compute: { module: shader, entryPoint: "main" },
          });
          const bindGroup = device.createBindGroup({
            layout: pipeline.getBindGroupLayout(0),
            entries: [{ binding: 0, resource: { buffer: storage } }],
          });

          const encoder = device.createCommandEncoder();
          const pass = encoder.beginComputePass();
          pass.setPipeline(pipeline);
          pass.setBindGroup(0, bindGroup);
          pass.dispatchWorkgroups(input.length);
          pass.end();
          encoder.copyBufferToBuffer(storage, 0, readback, 0, input.byteLength);
          device.queue.submit([encoder.finish()]);
          await withOpTimeout("computeIncrement readback mapAsync", () =>
            readback.mapAsync(GPUMapMode.READ),
          );
          const actual = Array.from(new Uint32Array(readback.getMappedRange()));
          readback.unmap();
          result.smoke.computeIncrement.actual = actual;
          result.smoke.computeIncrement.pass =
            JSON.stringify(actual) === JSON.stringify(result.smoke.computeIncrement.expected);
        } catch (error) {
          result.smoke.computeIncrement.error = String(error);
        }
        result.smoke.recovery.postValidationCompute.actual = result.smoke.computeIncrement.actual;
        result.smoke.recovery.postValidationCompute.pass = result.smoke.computeIncrement.pass;
        result.smoke.recovery.postValidationCompute.error = result.smoke.computeIncrement.error;

        try {
          const width = 64;
          const height = 64;
          const format = "rgba8unorm";
          const texture = device.createTexture({
            size: { width, height, depthOrArrayLayers: 1 },
            format,
            usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC,
          });

          const shader = device.createShaderModule({
            code: `
              @vertex
              fn vs(@builtin(vertex_index) index : u32) -> @builtin(position) vec4<f32> {
                var pos = array<vec2<f32>, 3>(
                  vec2<f32>(-0.6, -0.6),
                  vec2<f32>( 0.6, -0.6),
                  vec2<f32>( 0.0,  0.6)
                );
                return vec4<f32>(pos[index], 0.0, 1.0);
              }

              @fragment
              fn fs() -> @location(0) vec4<f32> {
                return vec4<f32>(1.0, 0.0, 0.0, 1.0);
              }
            `,
          });
          const pipeline = device.createRenderPipeline({
            layout: "auto",
            vertex: { module: shader, entryPoint: "vs" },
            fragment: {
              module: shader,
              entryPoint: "fs",
              targets: [{ format }],
            },
            primitive: { topology: "triangle-list" },
          });

          const encoder = device.createCommandEncoder();
          const pass = encoder.beginRenderPass({
            colorAttachments: [
              {
                view: texture.createView(),
                clearValue: { r: 0, g: 0, b: 0, a: 1 },
                loadOp: "clear",
                storeOp: "store",
              },
            ],
          });
          pass.setPipeline(pipeline);
          pass.draw(3);
          pass.end();

          const bytesPerRow = 256;
          const readback = device.createBuffer({
            size: bytesPerRow * height,
            usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
          });
          encoder.copyTextureToBuffer(
            { texture },
            { buffer: readback, bytesPerRow, rowsPerImage: height },
            { width, height, depthOrArrayLayers: 1 },
          );
          device.queue.submit([encoder.finish()]);
          await withOpTimeout("renderTriangle readback mapAsync", () =>
            readback.mapAsync(GPUMapMode.READ),
          );
          const data = new Uint8Array(readback.getMappedRange());
          const centerOffset = Math.floor(height / 2) * bytesPerRow + Math.floor(width / 2) * 4;
          const centerRgba = Array.from(data.slice(centerOffset, centerOffset + 4));
          readback.unmap();
          texture.destroy();
          result.smoke.renderTriangle.centerRgba = centerRgba;
          result.smoke.renderTriangle.pass =
            centerRgba[0] > 100 &&
            centerRgba[0] > centerRgba[1] + 20 &&
            centerRgba[0] > centerRgba[2] + 20;
        } catch (error) {
          result.smoke.renderTriangle.error = String(error);
        }

        try {
          const width = 64;
          const height = 64;
          const format = "rgba8unorm";
          const texture = device.createTexture({
            size: { width, height, depthOrArrayLayers: 1 },
            format,
            usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC,
          });
          const shader = device.createShaderModule({
            code: `
              @vertex
              fn vs(@builtin(vertex_index) index : u32) -> @builtin(position) vec4<f32> {
                var pos = array<vec2<f32>, 3>(
                  vec2<f32>(-0.6, -0.6),
                  vec2<f32>( 0.6, -0.6),
                  vec2<f32>( 0.0,  0.6)
                );
                return vec4<f32>(pos[index], 0.0, 1.0);
              }

              @fragment
              fn fs() -> @location(0) vec4<f32> {
                return vec4<f32>(1.0, 0.0, 0.0, 1.0);
              }
            `,
          });
          const pipeline = device.createRenderPipeline({
            layout: "auto",
            vertex: { module: shader, entryPoint: "vs" },
            fragment: {
              module: shader,
              entryPoint: "fs",
              targets: [{ format }],
            },
            primitive: { topology: "triangle-list" },
          });
          const bundleEncoder = device.createRenderBundleEncoder({
            colorFormats: [format],
          });
          bundleEncoder.setPipeline(pipeline);
          bundleEncoder.draw(3);
          const bundle = bundleEncoder.finish();
          const encoder = device.createCommandEncoder();
          const pass = encoder.beginRenderPass({
            colorAttachments: [
              {
                view: texture.createView(),
                clearValue: { r: 0, g: 0, b: 0, a: 1 },
                loadOp: "clear",
                storeOp: "store",
              },
            ],
          });
          pass.executeBundles([bundle]);
          pass.end();
          device.queue.submit([encoder.finish()]);
          const readback = await readTextureRgba(device, texture, width, height, "renderBundle readback");
          const centerRgba = sampleRgba(readback.bytes, readback.bytesPerRow, 32, 32);
          texture.destroy();
          result.smoke.renderBundle.centerRgba = centerRgba;
          result.smoke.renderBundle.pass = isRedDominant(centerRgba);
        } catch (error) {
          result.smoke.renderBundle.error = String(error);
        }

        try {
          const width = 64;
          const height = 64;
          const format = "rgba8unorm";
          const texture = device.createTexture({
            size: { width, height, depthOrArrayLayers: 1 },
            format,
            usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC,
          });
          const shader = device.createShaderModule({
            code: `
              @vertex
              fn vs(@builtin(vertex_index) index : u32) -> @builtin(position) vec4<f32> {
                var pos = array<vec2<f32>, 3>(
                  vec2<f32>(-0.6, -0.6),
                  vec2<f32>( 0.6, -0.6),
                  vec2<f32>( 0.0,  0.6)
                );
                return vec4<f32>(pos[index], 0.0, 1.0);
              }

              @fragment
              fn fs() -> @location(0) vec4<f32> {
                return vec4<f32>(1.0, 0.0, 0.0, 1.0);
              }
            `,
          });
          const pipeline = device.createRenderPipeline({
            layout: "auto",
            vertex: { module: shader, entryPoint: "vs" },
            fragment: {
              module: shader,
              entryPoint: "fs",
              targets: [{ format }],
            },
            primitive: { topology: "triangle-list" },
          });
          const indirect = device.createBuffer({
            size: 16,
            usage: GPUBufferUsage.INDIRECT | GPUBufferUsage.COPY_DST,
          });
          device.queue.writeBuffer(indirect, 0, new Uint32Array([3, 1, 0, 0]));
          const encoder = device.createCommandEncoder();
          const pass = encoder.beginRenderPass({
            colorAttachments: [
              {
                view: texture.createView(),
                clearValue: { r: 0, g: 0, b: 0, a: 1 },
                loadOp: "clear",
                storeOp: "store",
              },
            ],
          });
          pass.setPipeline(pipeline);
          pass.drawIndirect(indirect, 0);
          pass.end();
          device.queue.submit([encoder.finish()]);
          const readback = await readTextureRgba(device, texture, width, height, "renderIndirect readback");
          const centerRgba = sampleRgba(readback.bytes, readback.bytesPerRow, 32, 32);
          indirect.destroy();
          texture.destroy();
          result.smoke.renderIndirect.centerRgba = centerRgba;
          result.smoke.renderIndirect.pass = isRedDominant(centerRgba);
        } catch (error) {
          result.smoke.renderIndirect.error = String(error);
        }

        try {
          const timestampAdapter = await withOpTimeout("timestamp requestAdapter", () =>
            gpu.requestAdapter(),
          );
          if (!timestampAdapter) {
            throw new Error("timestamp requestAdapter returned null");
          }
          if (!timestampAdapter.features.has("timestamp-query")) {
            throw new Error("timestamp-query feature unavailable");
          }
          const timestampDevice = await withOpTimeout("timestamp requestDevice", () =>
            timestampAdapter.requestDevice({ requiredFeatures: ["timestamp-query"] }),
          );
          attachDeviceDiagnostics(timestampDevice, "timestamp");
          let querySet = null;
          let resolveBuffer = null;
          let readback = null;
          try {
            querySet = timestampDevice.createQuerySet({ type: "timestamp", count: 2 });
            resolveBuffer = timestampDevice.createBuffer({
              size: 16,
              usage: GPUBufferUsage.QUERY_RESOLVE | GPUBufferUsage.COPY_SRC,
            });
            readback = timestampDevice.createBuffer({
              size: 16,
              usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
            });
            const encoder = timestampDevice.createCommandEncoder();
            const pass = encoder.beginComputePass({
              timestampWrites: {
                querySet,
                beginningOfPassWriteIndex: 0,
                endOfPassWriteIndex: 1,
              },
            });
            pass.end();
            encoder.resolveQuerySet(querySet, 0, 2, resolveBuffer, 0);
            encoder.copyBufferToBuffer(resolveBuffer, 0, readback, 0, 16);
            timestampDevice.queue.submit([encoder.finish()]);
            await withOpTimeout("timestampQuery readback mapAsync", () =>
              readback.mapAsync(GPUMapMode.READ),
            );
            const values = new BigUint64Array(readback.getMappedRange()).slice(0);
            const actual = Array.from(values, (value) => value.toString());
            result.smoke.timestampQuery.actual = actual;
            result.smoke.timestampQuery.pass = values.length === 2 && values[1] >= values[0];
            readback.unmap();
          } finally {
            readback?.destroy();
            resolveBuffer?.destroy();
            querySet?.destroy();
            timestampDevice.destroy?.();
          }
        } catch (error) {
          result.smoke.timestampQuery.error = String(error);
        }

        const runMiniBenches = async () => {
          let benchDevice = device;
          if (!result.smoke.renderTriangle.pass) {
            try {
              const benchAdapter = await withOpTimeout("bench fallback requestAdapter", () =>
                gpu.requestAdapter(),
              );
              if (!benchAdapter) {
                throw new Error("bench fallback requestAdapter returned null");
              }
              benchDevice = await withOpTimeout("bench fallback requestDevice", () =>
                benchAdapter.requestDevice(),
              );
              attachDeviceDiagnostics(benchDevice, "bench-fallback");
            } catch (error) {
              const message = `bench fallback device init failed: ${String(error)}`;
              result.benches.errors.push(message);
              result.errors.push(message);
              return;
            }
          }

          try {
            const size = 64 * 1024;
            const payload = new Uint8Array(size);
            const uploadBuffer = benchDevice.createBuffer({
              size,
              usage: GPUBufferUsage.COPY_DST,
            });
            for (let i = 0; i < uploadWarmupIters; i += 1) {
              benchDevice.queue.writeBuffer(uploadBuffer, 0, payload);
            }
            await withOpTimeout("writeBuffer warmup onSubmittedWorkDone", () =>
              benchDevice.queue.onSubmittedWorkDone(),
            );
            const uploadStart = performance.now();
            for (let i = 0; i < uploadIters; i += 1) {
              benchDevice.queue.writeBuffer(uploadBuffer, 0, payload);
            }
            await withOpTimeout("writeBuffer timed onSubmittedWorkDone", () =>
              benchDevice.queue.onSubmittedWorkDone(),
            );
            const uploadEnd = performance.now();
            result.benches.writeBuffer64kbUsPerOp =
              ((uploadEnd - uploadStart) * 1000) / uploadIters;
          } catch (error) {
            result.benches.errors.push(`writeBuffer bench failed: ${String(error)}`);
          }

          try {
            const shader = benchDevice.createShaderModule({
              code: `
                @compute @workgroup_size(1)
                fn main() {}
              `,
            });
            const pipeline = benchDevice.createComputePipeline({
              layout: "auto",
              compute: { module: shader, entryPoint: "main" },
            });
            for (let i = 0; i < dispatchWarmupIters; i += 1) {
              const encoder = benchDevice.createCommandEncoder();
              const pass = encoder.beginComputePass();
              pass.setPipeline(pipeline);
              pass.dispatchWorkgroups(1);
              pass.end();
              benchDevice.queue.submit([encoder.finish()]);
            }
            await withOpTimeout("dispatch warmup onSubmittedWorkDone", () =>
              benchDevice.queue.onSubmittedWorkDone(),
            );
            const dispatchStart = performance.now();
            for (let i = 0; i < dispatchIters; i += 1) {
              const encoder = benchDevice.createCommandEncoder();
              const pass = encoder.beginComputePass();
              pass.setPipeline(pipeline);
              pass.dispatchWorkgroups(1);
              pass.end();
              benchDevice.queue.submit([encoder.finish()]);
            }
            await withOpTimeout("dispatch timed onSubmittedWorkDone", () =>
              benchDevice.queue.onSubmittedWorkDone(),
            );
            const dispatchEnd = performance.now();
            result.benches.computeDispatchUsPerOp =
              ((dispatchEnd - dispatchStart) * 1000) / dispatchIters;
          } catch (error) {
            result.benches.errors.push(`dispatch bench failed: ${String(error)}`);
          }
        };

        await runMiniBenches();

        try {
          const width = 2;
          const height = 2;
          const sourceCanvas = new OffscreenCanvas(width, height);
          const sourceContext = sourceCanvas.getContext("2d");
          if (!sourceContext) {
            throw new Error("OffscreenCanvas 2D context is unavailable");
          }
          sourceContext.fillStyle = "rgba(255, 0, 0, 1)";
          sourceContext.fillRect(0, 0, width, 1);
          sourceContext.fillStyle = "rgba(0, 255, 0, 1)";
          sourceContext.fillRect(0, 1, width, 1);
          const copyAttempts = [];
          const tryCopyExternalSource = async (sourceType, sourceValue) => {
            const attempt = { sourceType, pass: false, topLeftRgba: null };
            let texture = null;
            try {
              texture = device.createTexture({
                size: { width, height, depthOrArrayLayers: 1 },
                format: "rgba8unorm",
                usage:
                  GPUTextureUsage.COPY_DST |
                  GPUTextureUsage.COPY_SRC |
                  GPUTextureUsage.TEXTURE_BINDING |
                  GPUTextureUsage.RENDER_ATTACHMENT,
              });
              device.queue.copyExternalImageToTexture(
                {
                  source: sourceValue,
                  origin: { x: 0, y: 0 },
                  flipY: true,
                },
                {
                  texture,
                  aspect: "all",
                  colorSpace: "srgb",
                  mipLevel: 0,
                  origin: { x: 0, y: 0, z: 0 },
                  premultipliedAlpha: false,
                },
                { width, height, depthOrArrayLayers: 1 },
              );
              await withOpTimeout(
                `copyExternalImageToTexture ${sourceType} onSubmittedWorkDone`,
                () => device.queue.onSubmittedWorkDone(),
              );
              const readback = await readTextureRgba(
                device,
                texture,
                width,
                height,
                `copyExternalImageToTexture ${sourceType} readback`,
              );
              const topLeftRgba = sampleRgba(readback.bytes, readback.bytesPerRow, 0, 0);
              attempt.topLeftRgba = topLeftRgba;
              attempt.pass = isGreenDominant(topLeftRgba);
            } catch (error) {
              attempt.error = String(error);
            } finally {
              texture?.destroy();
              copyAttempts.push(attempt);
            }
            return attempt;
          };

          if (typeof createImageBitmap === "function") {
            const imageBitmap = await createImageBitmap(sourceCanvas);
            try {
              const attempt = await tryCopyExternalSource("ImageBitmap", imageBitmap);
              if (attempt.pass) {
                result.smoke.copyExternalImageToTexture.topLeftRgba = attempt.topLeftRgba;
                result.smoke.copyExternalImageToTexture.sourceType = "ImageBitmap";
                result.smoke.copyExternalImageToTexture.pass = true;
              }
            } finally {
              imageBitmap.close?.();
            }
          } else {
            copyAttempts.push({ sourceType: "ImageBitmap", skipped: "createImageBitmap unavailable" });
          }

          if (!result.smoke.copyExternalImageToTexture.pass) {
            const attempt = await tryCopyExternalSource("OffscreenCanvas", sourceCanvas);
            result.smoke.copyExternalImageToTexture.topLeftRgba = attempt.topLeftRgba;
            result.smoke.copyExternalImageToTexture.sourceType = "OffscreenCanvas";
            result.smoke.copyExternalImageToTexture.pass = attempt.pass;
          }
          result.smoke.copyExternalImageToTexture.attempts = copyAttempts;
          if (!result.smoke.copyExternalImageToTexture.pass) {
            const attemptErrors = copyAttempts
              .filter((attempt) => attempt.error)
              .map((attempt) => `${attempt.sourceType}: ${attempt.error}`);
            result.smoke.copyExternalImageToTexture.error =
              attemptErrors.join("; ") ||
              "copyExternalImageToTexture did not produce a green-dominant top-left pixel";
          }
        } catch (error) {
          result.smoke.copyExternalImageToTexture.error = String(error);
        }

        let importStage = "requestAdapter";
        try {
          if (typeof VideoFrame !== "function") {
            throw new Error("VideoFrame is unavailable");
          }
          const importAdapter = await withOpTimeout("importExternalTexture requestAdapter", () =>
            gpu.requestAdapter(),
          );
          if (!importAdapter) {
            throw new Error("importExternalTexture requestAdapter returned null");
          }
          importStage = "requestDevice";
          const importDevice = await withOpTimeout("importExternalTexture requestDevice", () =>
            importAdapter.requestDevice(),
          );
          attachDeviceDiagnostics(importDevice, "import-external-texture");
          importStage = "createSourceCanvas";
          const sourceCanvas = new OffscreenCanvas(2, 2);
          const sourceContext = sourceCanvas.getContext("2d");
          if (!sourceContext) {
            throw new Error("OffscreenCanvas 2D context is unavailable");
          }
          sourceContext.fillStyle = "rgba(255, 0, 0, 1)";
          sourceContext.fillRect(0, 0, 2, 2);

          let videoFrame = null;
          let externalTexture = null;
          let renderTarget = null;
          try {
            importStage = "createVideoFrame";
            videoFrame = new VideoFrame(sourceCanvas, { timestamp: 0 });
            importStage = "importExternalTexture";
            externalTexture = importDevice.importExternalTexture({
              source: videoFrame,
              colorSpace: "srgb",
              label: "playwright-smoke-external-texture",
            });
            importStage = "createSampler";
            const sampler = importDevice.createSampler({
              minFilter: "linear",
              magFilter: "linear",
            });
            importStage = "createBindGroupLayout";
            const bindGroupLayout = importDevice.createBindGroupLayout({
              entries: [
                {
                  binding: 0,
                  visibility: GPUShaderStage.FRAGMENT,
                  sampler: { type: "filtering" },
                },
                {
                  binding: 1,
                  visibility: GPUShaderStage.FRAGMENT,
                  externalTexture: {},
                },
              ],
            });
            importStage = "createPipelineLayout";
            const pipelineLayout = importDevice.createPipelineLayout({
              bindGroupLayouts: [bindGroupLayout],
            });
            importStage = "createShaderModule";
            const shader = importDevice.createShaderModule({
              code: `
                struct VertexOutput {
                  @builtin(position) position : vec4<f32>,
                  @location(0) fragUV : vec2<f32>,
                };

                @vertex
                fn vs(@builtin(vertex_index) index : u32) -> VertexOutput {
                  var pos = array<vec2<f32>, 6>(
                    vec2<f32>(-1.0, -1.0),
                    vec2<f32>( 1.0, -1.0),
                    vec2<f32>(-1.0,  1.0),
                    vec2<f32>(-1.0,  1.0),
                    vec2<f32>( 1.0, -1.0),
                    vec2<f32>( 1.0,  1.0),
                  );
                  var uv = array<vec2<f32>, 6>(
                    vec2<f32>(0.0, 1.0),
                    vec2<f32>(1.0, 1.0),
                    vec2<f32>(0.0, 0.0),
                    vec2<f32>(0.0, 0.0),
                    vec2<f32>(1.0, 1.0),
                    vec2<f32>(1.0, 0.0),
                  );

                  var output : VertexOutput;
                  output.position = vec4<f32>(pos[index], 0.0, 1.0);
                  output.fragUV = uv[index];
                  return output;
                }

                @group(0) @binding(0) var mySampler : sampler;
                @group(0) @binding(1) var myTexture : texture_external;

                @fragment
                fn fs(@location(0) fragUV : vec2<f32>) -> @location(0) vec4<f32> {
                  return textureSampleBaseClampToEdge(myTexture, mySampler, fragUV);
                }
              `,
            });
            importStage = "createRenderPipeline";
            const pipeline = importDevice.createRenderPipeline({
              layout: pipelineLayout,
              vertex: { module: shader, entryPoint: "vs" },
              fragment: {
                module: shader,
                entryPoint: "fs",
                targets: [{ format: "rgba8unorm" }],
              },
              primitive: { topology: "triangle-list" },
            });
            importStage = "createBindGroup";
            const bindGroup = importDevice.createBindGroup({
              layout: bindGroupLayout,
              entries: [
                { binding: 0, resource: sampler },
                { binding: 1, resource: externalTexture },
              ],
            });
            importStage = "createRenderTarget";
            renderTarget = importDevice.createTexture({
              size: { width: 4, height: 4, depthOrArrayLayers: 1 },
              format: "rgba8unorm",
              usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC,
            });
            importStage = "encodeRenderPass";
            const encoder = importDevice.createCommandEncoder();
            const pass = encoder.beginRenderPass({
              colorAttachments: [
                {
                  view: renderTarget.createView(),
                  clearValue: { r: 0, g: 0, b: 0, a: 1 },
                  loadOp: "clear",
                  storeOp: "store",
                },
              ],
            });
            pass.setPipeline(pipeline);
            pass.setBindGroup(0, bindGroup);
            pass.draw(6);
            pass.end();
            importStage = "submit";
            importDevice.queue.submit([encoder.finish()]);
            importStage = "onSubmittedWorkDone";
            await withOpTimeout("importExternalTexture onSubmittedWorkDone", () =>
              importDevice.queue.onSubmittedWorkDone(),
            );
            importStage = "readback";
            const readback = await readTextureRgba(
              importDevice,
              renderTarget,
              4,
              4,
              "importExternalTexture readback",
            );
            const centerRgba = sampleRgba(readback.bytes, readback.bytesPerRow, 2, 2);
            result.smoke.importExternalTexture.centerRgba = centerRgba;
            result.smoke.importExternalTexture.pass = isRedDominant(centerRgba);
          } finally {
            externalTexture?.destroy?.();
            renderTarget?.destroy();
            videoFrame?.close();
          }
        } catch (error) {
          result.smoke.importExternalTexture.error = `${importStage}: ${String(error)}`;
        }

        await settleDeviceDiagnostics();
        return result;
      },
        {
          uploadIters: args.uploadIters,
          dispatchIters: args.dispatchIters,
          uploadWarmupIters: UPLOAD_WARMUP_ITERS,
          dispatchWarmupIters: DISPATCH_WARMUP_ITERS,
          adapterLimitKeys: ADAPTER_LIMIT_KEYS,
          opTimeoutMs: args.opTimeoutMs,
          apiSurface: args.apiSurface,
          browserModuleUrl: browserSurfaceModuleUrl(localUrl),
        },
      ),
      args.suiteTimeoutMs,
      `${mode} smoke suite`,
    );

    const runtimeSelection = buildRuntimeSelection(mode, args, launchArgs);
    return {
      mode,
      runtimeSelection,
      shaderCompilerIdentity: shaderCompilerIdentity(mode, args),
      runtimeArgs: runtimeArgs(selection.selectedRuntime, args.doeLibPath),
      launchArgs,
      browserVersion,
      elapsedMs: Date.now() - startMs,
      ...suite,
      adapterIdentity: adapterIdentityFromSmokeResult(suite, runtimeSelection.profile),
    };
  } catch (error) {
    return makeFailedResult(mode, args, launchArgs, browserVersion, startMs, error);
  } finally {
    if (browser) {
      try {
        await withTimeout(browser.close(), DEFAULT_BROWSER_CLOSE_TIMEOUT_MS, `${mode} browser close`);
      } catch (closeError) {
        console.warn(`[WARN] ${mode}: browser close failed: ${String(closeError)}`);
      }
    }
  }
}

function computeComparison(modeResults) {
  const dawn = extractModeResult(modeResults, "dawn");
  const doe = extractModeResult(modeResults, "doe");
  if (!dawn || !doe) return null;

  return {
    writeBuffer64kbDeltaPercent: safeDeltaPercent(
      dawn.benches.writeBuffer64kbUsPerOp,
      doe.benches.writeBuffer64kbUsPerOp,
    ),
    computeDispatchDeltaPercent: safeDeltaPercent(
      dawn.benches.computeDispatchUsPerOp,
      doe.benches.computeDispatchUsPerOp,
    ),
    bothComputeSmokePass:
      dawn.smoke.computeIncrement.pass && doe.smoke.computeIncrement.pass,
    bothRenderSmokePass: dawn.smoke.renderTriangle.pass && doe.smoke.renderTriangle.pass,
    bothRenderBundleSmokePass: dawn.smoke.renderBundle.pass && doe.smoke.renderBundle.pass,
    bothRenderIndirectSmokePass: dawn.smoke.renderIndirect.pass && doe.smoke.renderIndirect.pass,
    bothTimestampQuerySmokePass: dawn.smoke.timestampQuery.pass && doe.smoke.timestampQuery.pass,
  };
}

function hasFailure(result) {
  if (!result.webgpuAvailable || !result.adapterAvailable) return true;
  if (!result.smoke.computeIncrement.pass) return true;
  if (!result.smoke.renderTriangle.pass) return true;
  if (!result.smoke.renderBundle.pass) return true;
  if (!result.smoke.renderIndirect.pass) return true;
  if (!result.smoke.timestampQuery.pass) return true;
  if (!result.smoke.requestAdapterXrCompatible.pass) return true;
  if (!result.smoke.copyExternalImageToTexture.pass) return true;
  if (!result.smoke.importExternalTexture.pass) return true;
  return false;
}

async function main() {
  const args = parseArgs(process.argv);
  const chromium = await loadChromiumDriver();
  const { server, url, port } = await startLocalServer();

  const modes = args.mode === "both" ? ["dawn", "doe"] : [args.mode];
  const modeResults = [];
  let failed = false;

  try {
    for (const mode of modes) {
      const result = await runMode(chromium, mode, args, url, port);
      modeResults.push(result);
      const status = hasFailure(result) ? "FAIL" : "PASS";
      console.log(
        `[${status}] ${mode}: webgpu=${result.webgpuAvailable} adapter=${result.adapterAvailable} compute=${result.smoke.computeIncrement.pass} render=${result.smoke.renderTriangle.pass} bundle=${result.smoke.renderBundle.pass} indirect=${result.smoke.renderIndirect.pass} timestamp=${result.smoke.timestampQuery.pass} xrCompatible=${result.smoke.requestAdapterXrCompatible.pass} copyExternal=${result.smoke.copyExternalImageToTexture.pass} importExternal=${result.smoke.importExternalTexture.pass} canvas=${result.webgpuCanvasApi?.webgpuContextAvailable ?? false} upload64kb_us=${result.benches.writeBuffer64kbUsPerOp?.toFixed(3) ?? "n/a"} dispatch_us=${result.benches.computeDispatchUsPerOp?.toFixed(3) ?? "n/a"}`,
      );
      if (hasFailure(result)) {
        failed = true;
      }
    }
  } finally {
    server.close();
  }

  const modeResultsWithHashes = attachHashChain(modeResults);
  const generatedAt = new Date().toISOString();
  const report = {
    schemaVersion: REPORT_SCHEMA_VERSION,
    reportKind: REPORT_KIND,
    benchmarkClass: BENCHMARK_CLASS,
    comparisonStatus: "diagnostic",
    claimStatus: "diagnostic",
    timingClass: TIMING_CLASS,
    timingSource: TIMING_SOURCE,
    generatedAt,
    hashAlgorithm: HASH_ALGORITHM,
    runtimeSelectorPolicyPath: args.runtimeSelectorPolicyPath,
    workloadIdentity: smokeWorkloadIdentity(),
    invocation: {
      argv: process.argv.slice(2),
      cwd: process.cwd(),
      nodeVersion: process.version,
      platform: process.platform,
      arch: process.arch,
    },
    chromePath: args.chromePath,
    headless: args.headless,
    chromeArgs: args.chromeArgs,
    mode: args.mode,
    methodology: {
      uploadIterations: args.uploadIters,
      dispatchIterations: args.dispatchIters,
      uploadWarmupIterations: UPLOAD_WARMUP_ITERS,
      dispatchWarmupIterations: DISPATCH_WARMUP_ITERS,
      suiteTimeoutMs: args.suiteTimeoutMs,
      operationTimeoutMs: args.opTimeoutMs,
      strictMode: args.strict,
      notes: [
        "Browser harness output is diagnostic and not a strict L0 apples-to-apples claim artifact.",
      ],
    },
    runtimeSelections: modeResultsWithHashes.map((entry) => entry.runtimeSelection),
    modeResults: modeResultsWithHashes,
    comparison: computeComparison(modeResultsWithHashes),
  };
  report.reportHash = hashHex(report);

  mkdirSync(dirname(args.outPath), { recursive: true });
  writeFileSync(args.outPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");
  console.log(`report written: ${args.outPath}`);
  const flightRecorderPath = maybeWriteFlightRecorder(args);
  if (flightRecorderPath) {
    console.log(`flight recorder written: ${flightRecorderPath}`);
  }
  const shaderLinksPath = maybeWriteShaderLinks(args);
  if (shaderLinksPath) {
    console.log(`shader links written: ${shaderLinksPath}`);
  }
  const canvasWebgpuFusionPath = maybeWriteCanvasWebgpuFusion(args);
  if (canvasWebgpuFusionPath) {
    console.log(`canvas/WebGPU fusion probe written: ${canvasWebgpuFusionPath}`);
  }
  const mediaPathProbePath = maybeWriteMediaPathProbe(args);
  if (mediaPathProbePath) {
    console.log(`media path probe written: ${mediaPathProbePath}`);
  }
  const recoveryParityPath = maybeWriteRecoveryParity(args);
  if (recoveryParityPath) {
    console.log(`recovery parity written: ${recoveryParityPath}`);
  }
  const ctsSubsetPath = maybeWriteCtsSubset(args);
  if (ctsSubsetPath) {
    console.log(`CTS subset written: ${ctsSubsetPath}`);
  }
  const gpuSchedulerPath = maybeWriteGpuScheduler(args);
  if (gpuSchedulerPath) {
    console.log(`GPU scheduler probe written: ${gpuSchedulerPath}`);
  }
  const webgpuEffectExperimentPath = maybeWriteWebgpuEffectExperiment(args);
  if (webgpuEffectExperimentPath) {
    console.log(`WebGPU effect experiment written: ${webgpuEffectExperimentPath}`);
  }
  const localAiWorkloadsPath = maybeWriteLocalAiWorkloads(args);
  if (localAiWorkloadsPath) {
    console.log(`local AI workloads written: ${localAiWorkloadsPath}`);
  }
  const pipelineCacheReceiptsPath = maybeWritePipelineCacheReceipts(args);
  if (pipelineCacheReceiptsPath) {
    console.log(`pipeline cache receipts written: ${pipelineCacheReceiptsPath}`);
  }
  const fallbackExplanationsPath = maybeWriteFallbackExplanations(args);
  if (fallbackExplanationsPath) {
    console.log(`fallback explanations written: ${fallbackExplanationsPath}`);
  }
  if (report.comparison) {
    console.log(
      `delta (diagnostic only; positive=doe faster): writeBuffer64kb=${report.comparison.writeBuffer64kbDeltaPercent?.toFixed(2) ?? "n/a"}% dispatch=${report.comparison.computeDispatchDeltaPercent?.toFixed(2) ?? "n/a"}%`,
    );
  }

  if (args.strict && failed) {
    process.exit(1);
  }
}

main().catch((error) => {
  console.error(String(error?.stack ?? error));
  process.exit(1);
});

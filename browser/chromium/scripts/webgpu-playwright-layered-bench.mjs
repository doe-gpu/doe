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
const DEFAULT_NATIVE_METAL_TRACE_CONFIG = resolve(
  ROOT,
  "config/browser-metal-native-trace.json",
);
const DEFAULT_MANIFEST = resolve(
  ROOT,
  "browser/chromium/bench/generated/browser_projection_manifest.json",
);
const DEFAULT_WORKFLOWS = resolve(
  ROOT,
  "browser/chromium/bench/workflows/browser-workflow-manifest.json",
);
const BENCH_OUT_ROOT = resolve(ROOT, "bench/out");
const BENCH_OUT_SCRATCH_ROOT = resolve(ROOT, "bench/out/scratch");
const ARTIFACTS_ROOT = resolve(ROOT, "browser/chromium/artifacts");
const DEFAULT_OUT_FILE = "dawn-vs-doe.browser-layered.diagnostic.json";
const DEFAULT_API_SURFACE = "native";
const DEFAULT_POWER_PREFERENCE = "high-performance";
const HASH_ALGORITHM = "sha256";
const PROJECTION_MANIFEST_SCHEMA_VERSION = 6;
const RUNTIME_SELECTOR_VERSION = "browser-runtime-selector-v1";
const NATIVE_METAL_TRACE_KIND = "doe_metal_browser_command_path_v1";
const COMPUTE_PROJECTION_DIRECT_DISPATCH = "generic_direct_dispatch_component";
const COMPUTE_PROJECTION_EMPTY_DISPATCH = "generic_empty_dispatch_component";
const COMPUTE_PROJECTION_INDIRECT_DISPATCH = "generic_indirect_dispatch_component";
const COMPUTE_PROJECTION_SOURCE_KERNEL = "source_kernel_dispatch_v1";
const COMPUTE_PROJECTION_SOURCE_KERNEL_ORACLE = "source_kernel_dispatch_oracle_v2";
const COMPUTE_PROJECTIONS = Object.freeze([
  COMPUTE_PROJECTION_DIRECT_DISPATCH,
  COMPUTE_PROJECTION_EMPTY_DISPATCH,
  COMPUTE_PROJECTION_INDIRECT_DISPATCH,
  COMPUTE_PROJECTION_SOURCE_KERNEL,
  COMPUTE_PROJECTION_SOURCE_KERNEL_ORACLE,
]);
const SOURCE_KERNEL_BIND_GROUP_LAYOUT_MODE = "explicit_min_binding_size_v1";
const SOURCE_KERNEL_READBACK_BINDING_POLICY = "first_writable_storage_binding_v1";
const SOURCE_KERNEL_OUTPUT_ORACLE_KIND = "sha256_exact_v1";
const SOURCE_KERNEL_OUTPUT_ORACLE_INITIALIZATION = "zero_fill_v1";
const CATEGORY_BY_DOMAIN = {
  compute: "compute",
  "p0-compute": "compute",
  copy: "memory",
  upload: "memory",
  resource: "resources",
  "p0-resource": "resources",
  "p1-resource-table": "resources",
  "p1-resource-table-macro": "resources",
  pipeline: "pipeline",
  "pipeline-async": "pipeline",
  render: "render",
  "p0-render": "render",
  "p0-render-macro": "render",
  "render-bundle": "render",
  "render-macro": "render",
  surface: "surface",
  "texture-contract": "texture",
  "texture-macro": "texture",
  "texture-raster": "texture",
  "p1-capability": "capability",
  "p1-capability-macro": "capability",
  "p2-lifecycle": "lifecycle",
  "p2-lifecycle-macro": "lifecycle",
};
const CATEGORY_BY_WORKFLOW_ID = {
  startup_adapter_device: "startup",
  canvas_reconfigure_resize: "canvas",
  queue_submit_burst: "queue",
  async_pipeline_burst: "pipeline",
  fawn_visual_particle_trails: "visual",
  fawn_visual_magnetic_fluids: "visual",
  fawn_visual_prismatic_fluids: "visual",
};

const DEFAULT_ITERATIONS = {
  upload: 300,
  dispatch: 200,
  render: 120,
  pipeline: 256,
  asyncPipeline: 64,
  workflow: 80,
  texture: 64,
};
const DEFAULT_SOURCE_KERNEL_SAMPLES = 1;
const DEFAULT_SOURCE_KERNEL_WARMUP_SAMPLES = 0;
const DEFAULT_SOURCE_KERNEL_SCHEDULE_SLICES = 1;
const DEFAULT_SOURCE_KERNEL_SCHEDULE_SLICE_MIN_DISPATCH_REPEAT = 1;
const DEFAULT_SOURCE_KERNEL_SUBMIT_POLICY = "iteration-batch-v1";
const DEFAULT_MODE_SCHEDULE_REPETITIONS = 1;
const VISUAL_SCENARIO_CONTROLLER_DEADLINE_MS = 15000;
const SOURCE_KERNEL_SUBMIT_POLICIES = new Set([
  "iteration-batch-v1",
  "sample-batch-v1",
]);

function timestampId() {
  return new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z");
}

function defaultOutPath() {
  return resolve(
    ARTIFACTS_ROOT,
    timestampId(),
    DEFAULT_OUT_FILE,
  );
}

function usage() {
  console.log(`Usage:
  node browser/chromium/scripts/webgpu-playwright-layered-bench.mjs [options]

Options:
  --mode dawn|doe|auto|both Runtime mode to run (default: both)
  --mode-order dawn,doe|doe,dawn
                            Runtime order when --mode=both (default: dawn,doe)
  --mode-schedule grouped|paired|paired-balanced
                            grouped runs all rows for one runtime before the next;
                            paired alternates runtimes per row when --mode=both;
                            paired-balanced runs both row orders and averages
                            numeric metrics per runtime
                            (default: grouped)
  --mode-schedule-repetitions N
                            Repeat each paired schedule N times and retain the
                            per-runtime timing observations (default: 1)
  --chrome PATH             Chrome binary path
  --dawn-chrome PATH        Browser executable for dawn mode (defaults to --chrome)
  --doe-chrome PATH         Browser executable for doe mode (defaults to --chrome)
  --doe-lib PATH            libwebgpu_doe_full.{so,dylib,dll} path (for doe mode)
  --runtime-selector-policy PATH
                            Runtime selector policy JSON path (default: config/browser-runtime-selector-policy.json)
  --runtime-selector-profile-id ID
                            Optional selector profileId for auto denylist checks
  --native-metal-trace      Collect instrumented Doe Metal queue phases (diagnostic only)
  --native-metal-trace-config PATH
                            Native trace contract (default: config/browser-metal-native-trace.json)
  --manifest PATH           Projection manifest JSON path
  --workflows PATH          Browser workflow manifest JSON path
  --out PATH                Output report JSON path (default: browser/chromium/artifacts/<timestamp>/${DEFAULT_OUT_FILE})
  --allow-bench-out         Allow writing this diagnostic report under bench/out/scratch
  --allow-data-url-fallback Allow data: URL fallback if local server bind fails
  --headless true|false     Launch headless (default: true)
  --api-surface SURFACE     Browser API surface: native|package-browser (default: ${DEFAULT_API_SURFACE})
  --power-preference VALUE  requestAdapter powerPreference: default|high-performance|low-power (default: ${DEFAULT_POWER_PREFERENCE})
  --chrome-arg ARG          Extra Chromium arg (repeatable)
  --iters-upload N          Upload scenario iterations (default: 300)
  --iters-dispatch N        Dispatch scenario iterations (default: 200)
  --iters-render N          Render scenario iterations (default: 120)
  --iters-pipeline N        Pipeline scenario iterations (default: 256)
  --iters-async-pipeline N  Async pipeline iterations (default: 64)
  --iters-workflow N        Workflow loop iterations (default: 80)
  --iters-texture N         Texture scenario iterations (default: 64)
  --source-kernel-samples N Source-kernel compute timing samples (default: 1)
  --source-kernel-warmup-samples N
                            Untimed source-kernel timing batches before samples (default: 0)
  --source-kernel-schedule-slices N
                            Split source-kernel samples across N paired schedule slices (default: 1)
  --source-kernel-schedule-slice-min-dispatch-repeat N
                            Apply schedule slicing only when source dispatchRepeat is at least N (default: 1)
  --source-kernel-submit-policy ${[...SOURCE_KERNEL_SUBMIT_POLICIES].join("|")}
                            Source-kernel queue submit cadence (default: ${DEFAULT_SOURCE_KERNEL_SUBMIT_POLICY})
  --focus-category CATEGORY Run only rows in this diagnostic category (repeatable or comma-separated)
  --strict                  Exit non-zero when required rows fail
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

function readOptionValue(argv, optionIndex, flag) {
  const value = argv[optionIndex + 1];
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`${flag} requires a value`);
  }
  return value;
}

function parseListOption(text, flag) {
  const values = text
    .split(",")
    .map((segment) => segment.trim().toLowerCase())
    .filter((segment) => segment.length > 0);
  if (values.length === 0) {
    throw new Error(`${flag} requires at least one value`);
  }
  return values;
}

function parsePowerPreference(text) {
  if (["default", "high-performance", "low-power"].includes(text)) {
    return text;
  }
  throw new Error("--power-preference must be default, high-performance, or low-power");
}

function parseSourceKernelSubmitPolicy(text) {
  if (SOURCE_KERNEL_SUBMIT_POLICIES.has(text)) {
    return text;
  }
  throw new Error(
    `--source-kernel-submit-policy must be one of ${[...SOURCE_KERNEL_SUBMIT_POLICIES].join(", ")}`,
  );
}

function parseModeOrder(text) {
  const values = parseListOption(text, "--mode-order");
  if (
    values.length !== 2 ||
    !values.includes("dawn") ||
    !values.includes("doe") ||
    values[0] === values[1]
  ) {
    throw new Error("--mode-order must be dawn,doe or doe,dawn");
  }
  return values;
}

function parseModeSchedule(text) {
  const normalized = text.trim().toLowerCase();
  if (["grouped", "paired", "paired-balanced"].includes(normalized)) {
    return normalized;
  }
  throw new Error("--mode-schedule must be grouped, paired, or paired-balanced");
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
      `refusing to write diagnostic browser layered output to ${BENCH_OUT_ROOT}; write under browser/chromium/artifacts or pass --allow-bench-out explicitly`,
    );
  }
  if (!pathWithin(outPath, BENCH_OUT_SCRATCH_ROOT)) {
    throw new Error(
      `diagnostic browser layered output under bench/out must be in ${BENCH_OUT_SCRATCH_ROOT}`,
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

function readTextFile(pathValue) {
  if (!pathValue || !existsSync(pathValue)) return null;
  return readFileSync(pathValue, "utf8");
}

function repoPath(pathValue) {
  return resolve(ROOT, pathValue);
}

function releaseClassForChromePath(chromePath) {
  if (typeof chromePath !== "string" || chromePath.length === 0) return "unknown";
  if (chromePath.includes("/Google Chrome.app/")) return "stock_chrome_release";
  if (chromePath.includes("/Google Chrome Canary.app/")) return "stock_chrome_release";
  if (chromePath.includes("/out/fawn_debug/")) return "fawn_debug";
  if (chromePath.includes("/out/fawn_release/") || chromePath.includes("/out/fawn_release_local/")) {
    return "fawn_release";
  }
  if (chromePath.includes("/Fawn.app/")) return "fawn_release";
  return "unknown";
}

function fawnReleaseArgsPathFromChromePath(chromePath) {
  if (typeof chromePath !== "string" || chromePath.length === 0) return null;
  for (const marker of ["/out/fawn_release/", "/out/fawn_release_local/"]) {
    const markerIndex = chromePath.indexOf(marker);
    if (markerIndex >= 0) {
      return resolve(chromePath.slice(0, markerIndex + marker.length - 1), "args.gn");
    }
  }
  return null;
}

function fawnReleaseArgsCandidates(chromePath) {
  const envArgsPath = process.env.FAWN_CHROMIUM_RELEASE_ARGS_GN;
  return [
    envArgsPath,
    fawnReleaseArgsPathFromChromePath(chromePath),
    resolve(ROOT, "browser/chromium/src/out/fawn_release/args.gn"),
    resolve(ROOT, "browser/chromium/out/fawn_release_local/args.gn"),
    resolve(ROOT, "browser/chromium_webgpu_lane/src/out/fawn_release/args.gn"),
    resolve(ROOT, "browser/chromium_webgpu_lane/out/fawn_release_local/args.gn"),
  ].filter((value) => typeof value === "string" && value.length > 0);
}

function fawnReleaseArgsEvidence(chromePath) {
  if (releaseClassForChromePath(chromePath) !== "fawn_release") return null;
  for (const candidate of fawnReleaseArgsCandidates(chromePath)) {
    if (!existsSync(candidate)) continue;
    return {
      argsPath: candidate,
      argsSha256: fileHashHex(candidate),
      argsText: readTextFile(candidate),
    };
  }
  return null;
}

function browserBuildConfigurationEvidence(args) {
  return Object.fromEntries(
    Object.entries(args.modeChromePaths).map(([mode, chromePath]) => [
      mode,
      {
        chromePath,
        releaseClass: releaseClassForChromePath(chromePath),
        fawnReleaseArgs: fawnReleaseArgsEvidence(chromePath),
      },
    ]),
  );
}

function attachHashChain(entries, moduleName) {
  let previousHash = "0".repeat(64);
  return entries.map((entry, index) => {
    const traceEntry = {
      module: moduleName,
      opCode: "mode_result",
      seq: index + 1,
      ...entry,
    };
    const hash = hashHex({
      previousHash,
      entry: traceEntry,
    });
    const withHash = {
      ...traceEntry,
      hash,
      previousHash,
    };
    previousHash = hash;
    return withHash;
  });
}

function parseArgs(argv) {
  const args = {
    mode: "both",
    chromePath: DEFAULT_CHROME,
    dawnChromePath: "",
    doeChromePath: "",
    doeLibPath: DEFAULT_DOE_LIB,
    runtimeSelectorPolicyPath: DEFAULT_RUNTIME_SELECTOR_POLICY,
    runtimeSelectorPolicy: null,
    runtimeSelectorProfileId: "",
    nativeMetalTrace: false,
    nativeMetalTraceConfigPath: DEFAULT_NATIVE_METAL_TRACE_CONFIG,
    nativeMetalTraceConfig: null,
    manifestPath: DEFAULT_MANIFEST,
    workflowsPath: DEFAULT_WORKFLOWS,
    outPath: defaultOutPath(),
    allowBenchOut: false,
    allowDataUrlFallback: false,
    headless: true,
    apiSurface: DEFAULT_API_SURFACE,
    powerPreference: DEFAULT_POWER_PREFERENCE,
    chromeArgs: [],
    focusCategories: [],
    modeOrder: null,
    modeSchedule: "grouped",
    modeScheduleRepetitions: DEFAULT_MODE_SCHEDULE_REPETITIONS,
    strict: false,
    iterations: { ...DEFAULT_ITERATIONS },
    sourceKernelSamples: DEFAULT_SOURCE_KERNEL_SAMPLES,
    sourceKernelWarmupSamples: DEFAULT_SOURCE_KERNEL_WARMUP_SAMPLES,
    sourceKernelScheduleSlices: DEFAULT_SOURCE_KERNEL_SCHEDULE_SLICES,
    sourceKernelScheduleSliceMinDispatchRepeat:
      DEFAULT_SOURCE_KERNEL_SCHEDULE_SLICE_MIN_DISPATCH_REPEAT,
    sourceKernelSubmitPolicy: DEFAULT_SOURCE_KERNEL_SUBMIT_POLICY,
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
    } else if (token === "--allow-data-url-fallback") {
      args.allowDataUrlFallback = true;
    } else if (token === "--native-metal-trace") {
      args.nativeMetalTrace = true;
    } else if (token === "--mode") {
      args.mode = readOptionValue(argv, i, "--mode");
      i += 1;
    } else if (token === "--mode-order") {
      args.modeOrder = parseModeOrder(readOptionValue(argv, i, "--mode-order"));
      i += 1;
    } else if (token === "--mode-schedule") {
      args.modeSchedule = parseModeSchedule(readOptionValue(argv, i, "--mode-schedule"));
      i += 1;
    } else if (token === "--mode-schedule-repetitions") {
      args.modeScheduleRepetitions = parsePositiveInt(
        readOptionValue(argv, i, "--mode-schedule-repetitions"),
        "--mode-schedule-repetitions",
      );
      i += 1;
    } else if (token === "--chrome") {
      args.chromePath = readOptionValue(argv, i, "--chrome");
      i += 1;
    } else if (token === "--dawn-chrome") {
      args.dawnChromePath = readOptionValue(argv, i, "--dawn-chrome");
      i += 1;
    } else if (token === "--doe-chrome") {
      args.doeChromePath = readOptionValue(argv, i, "--doe-chrome");
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
    } else if (token === "--native-metal-trace-config") {
      args.nativeMetalTraceConfigPath = readOptionValue(argv, i, "--native-metal-trace-config");
      i += 1;
    } else if (token === "--manifest") {
      args.manifestPath = readOptionValue(argv, i, "--manifest");
      i += 1;
    } else if (token === "--workflows") {
      args.workflowsPath = readOptionValue(argv, i, "--workflows");
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
    } else if (token === "--power-preference") {
      args.powerPreference = parsePowerPreference(readOptionValue(argv, i, "--power-preference"));
      i += 1;
    } else if (token === "--chrome-arg") {
      args.chromeArgs.push(readOptionValue(argv, i, "--chrome-arg"));
      i += 1;
    } else if (token === "--focus-category") {
      args.focusCategories.push(...parseListOption(readOptionValue(argv, i, "--focus-category"), "--focus-category"));
      i += 1;
    } else if (token === "--iters-upload") {
      args.iterations.upload = parsePositiveInt(
        readOptionValue(argv, i, "--iters-upload"),
        "--iters-upload",
      );
      i += 1;
    } else if (token === "--iters-dispatch") {
      args.iterations.dispatch = parsePositiveInt(
        readOptionValue(argv, i, "--iters-dispatch"),
        "--iters-dispatch",
      );
      i += 1;
    } else if (token === "--iters-render") {
      args.iterations.render = parsePositiveInt(
        readOptionValue(argv, i, "--iters-render"),
        "--iters-render",
      );
      i += 1;
    } else if (token === "--iters-pipeline") {
      args.iterations.pipeline = parsePositiveInt(
        readOptionValue(argv, i, "--iters-pipeline"),
        "--iters-pipeline",
      );
      i += 1;
    } else if (token === "--iters-async-pipeline") {
      args.iterations.asyncPipeline = parsePositiveInt(
        readOptionValue(argv, i, "--iters-async-pipeline"),
        "--iters-async-pipeline",
      );
      i += 1;
    } else if (token === "--iters-workflow") {
      args.iterations.workflow = parsePositiveInt(
        readOptionValue(argv, i, "--iters-workflow"),
        "--iters-workflow",
      );
      i += 1;
    } else if (token === "--iters-texture") {
      args.iterations.texture = parsePositiveInt(
        readOptionValue(argv, i, "--iters-texture"),
        "--iters-texture",
      );
      i += 1;
    } else if (token === "--source-kernel-samples") {
      args.sourceKernelSamples = parsePositiveInt(
        readOptionValue(argv, i, "--source-kernel-samples"),
        "--source-kernel-samples",
      );
      i += 1;
    } else if (token === "--source-kernel-warmup-samples") {
      args.sourceKernelWarmupSamples = Number.parseInt(
        readOptionValue(argv, i, "--source-kernel-warmup-samples"),
        10,
      );
      if (!Number.isSafeInteger(args.sourceKernelWarmupSamples) || args.sourceKernelWarmupSamples < 0) {
        throw new Error("--source-kernel-warmup-samples must be a non-negative integer");
      }
      i += 1;
    } else if (token === "--source-kernel-schedule-slices") {
      args.sourceKernelScheduleSlices = parsePositiveInt(
        readOptionValue(argv, i, "--source-kernel-schedule-slices"),
        "--source-kernel-schedule-slices",
      );
      i += 1;
    } else if (token === "--source-kernel-schedule-slice-min-dispatch-repeat") {
      args.sourceKernelScheduleSliceMinDispatchRepeat = parsePositiveInt(
        readOptionValue(argv, i, "--source-kernel-schedule-slice-min-dispatch-repeat"),
        "--source-kernel-schedule-slice-min-dispatch-repeat",
      );
      i += 1;
    } else if (token === "--source-kernel-submit-policy") {
      args.sourceKernelSubmitPolicy = parseSourceKernelSubmitPolicy(
        readOptionValue(argv, i, "--source-kernel-submit-policy"),
      );
      i += 1;
    } else {
      throw new Error(`unknown argument: ${token}`);
    }
  }

  if (!["dawn", "doe", "auto", "both"].includes(args.mode)) {
    throw new Error("--mode must be one of dawn, doe, auto, both");
  }
  if (args.mode !== "both" && args.modeOrder !== null) {
    throw new Error("--mode-order is only valid with --mode=both");
  }
  if (args.mode !== "both" && args.modeSchedule !== "grouped") {
    throw new Error("--mode-schedule paired modes are only valid with --mode=both");
  }
  if (args.modeSchedule === "grouped" && args.modeScheduleRepetitions !== 1) {
    throw new Error("--mode-schedule-repetitions greater than 1 requires paired mode scheduling");
  }
  if (args.sourceKernelScheduleSlices > 1 && args.modeSchedule === "grouped") {
    throw new Error("--source-kernel-schedule-slices greater than 1 requires paired mode scheduling");
  }
  if (args.sourceKernelScheduleSlices > args.sourceKernelSamples) {
    throw new Error("--source-kernel-schedule-slices cannot exceed --source-kernel-samples");
  }
  if (!existsSync(args.runtimeSelectorPolicyPath)) {
    throw new Error(`runtime selector policy not found: ${args.runtimeSelectorPolicyPath}`);
  }
  args.runtimeSelectorPolicy = loadRuntimeSelectorPolicy(args.runtimeSelectorPolicyPath);
  args.nativeMetalTraceConfig = loadNativeMetalTraceConfig(args.nativeMetalTraceConfigPath);
  if (args.nativeMetalTrace && process.platform !== "darwin") {
    throw new Error("--native-metal-trace is supported only on macOS Metal browser runs");
  }
  if (!["native", "package-browser"].includes(args.apiSurface)) {
    throw new Error("--api-surface must be one of native, package-browser");
  }
  args.focusCategories = [...new Set(args.focusCategories)].sort();
  ensureAllowedOutPath(args.outPath, args.allowBenchOut);
  const modeChromePaths = {
    dawn: args.dawnChromePath || args.chromePath,
    doe: args.doeChromePath || args.chromePath,
  };
  const autoResolution =
    args.mode === "auto"
      ? resolveRuntimeSelection({
          requestedMode: "auto",
          doeLibPath: args.doeLibPath,
          policy: args.runtimeSelectorPolicy,
          profile: { profileId: args.runtimeSelectorProfileId },
        })
      : null;
  if (
    (args.mode === "dawn" || args.mode === "both" || autoResolution?.selectedRuntime === "dawn") &&
    !existsSync(modeChromePaths.dawn)
  ) {
    throw new Error(`dawn mode chrome binary not found: ${modeChromePaths.dawn}`);
  }
  if (
    (args.mode === "doe" || args.mode === "both" || autoResolution?.selectedRuntime === "doe") &&
    !existsSync(modeChromePaths.doe)
  ) {
    throw new Error(`doe mode chrome binary not found: ${modeChromePaths.doe}`);
  }
  if ((args.mode === "doe" || args.mode === "both") && !existsSync(args.doeLibPath)) {
    throw new Error(`doe runtime library not found: ${args.doeLibPath}`);
  }
  args.modeChromePaths = modeChromePaths;
  return args;
}

function loadJsonObject(path) {
  const payload = JSON.parse(readFileSync(path, "utf8"));
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw new Error(`invalid JSON object: ${path}`);
  }
  return payload;
}

function loadNativeMetalTraceConfig(path) {
  const payload = loadJsonObject(path);
  const expectedPhases = [
    "command_buffer_create",
    "command_encode",
    "command_commit",
    "wait_completed",
    "deferred_copy",
    "deferred_resolve",
  ];
  if (
    payload.schemaVersion !== 1 ||
    payload.traceId !== "doe-metal-browser-command-path-v1" ||
    payload.enabledByDefault !== false ||
    payload.environmentVariable !== "DOE_METAL_BROWSER_TRACE_PATH" ||
    payload.format !== "jsonl" ||
    payload.scope !== "doe_metal_queue_submit_and_flush" ||
    payload.evidenceClass !== "diagnostic_only" ||
    payload.timingsPerturbed !== true ||
    JSON.stringify(payload.phases) !== JSON.stringify(expectedPhases)
  ) {
    throw new Error(`invalid native Metal trace config: ${path}`);
  }
  return payload;
}

function requireString(value, label) {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new Error(`missing non-empty string: ${label}`);
  }
  return value;
}

function requireHashHex(value, label) {
  const text = requireString(value, label);
  if (!/^[a-f0-9]{64}$/.test(text)) {
    throw new Error(`invalid sha256 hex for ${label}`);
  }
  return text;
}

function requirePositiveInteger(value, label, { allowZero = false } = {}) {
  const minimum = allowZero ? 0 : 1;
  if (!Number.isSafeInteger(value) || value < minimum) {
    throw new Error(
      allowZero
        ? `${label} must be a non-negative integer`
        : `${label} must be a positive integer`,
    );
  }
  return value;
}

function parseStorageBindings(value, label) {
  if (!Array.isArray(value) || value.length === 0) {
    throw new Error(`${label} must be a non-empty array`);
  }
  const seen = new Set();
  return value.map((binding, index) => {
    if (!binding || typeof binding !== "object" || Array.isArray(binding)) {
      throw new Error(`${label}[${index}] must be an object`);
    }
    const group = requirePositiveInteger(binding.group, `${label}[${index}].group`, {
      allowZero: true,
    });
    const bindingIndex = requirePositiveInteger(
      binding.binding,
      `${label}[${index}].binding`,
      { allowZero: true },
    );
    const key = `${group}:${bindingIndex}`;
    if (seen.has(key)) {
      throw new Error(`${label}[${index}] duplicates group/binding ${key}`);
    }
    seen.add(key);
    const minBindingSize = requirePositiveInteger(
      binding.minBindingSize,
      `${label}[${index}].minBindingSize`,
    );
    const bufferSize = requirePositiveInteger(
      binding.bufferSize,
      `${label}[${index}].bufferSize`,
    );
    const bufferBindingType = requireString(
      binding.bufferBindingType,
      `${label}[${index}].bufferBindingType`,
    );
    if (!["storage", "read-only-storage"].includes(bufferBindingType)) {
      throw new Error(`${label}[${index}].bufferBindingType is unsupported: ${bufferBindingType}`);
    }
    if (minBindingSize !== bufferSize) {
      throw new Error(`${label}[${index}].minBindingSize must equal bufferSize`);
    }
    return {
      group,
      binding: bindingIndex,
      bufferSize,
      minBindingSize,
      bufferType: requireString(binding.bufferType, `${label}[${index}].bufferType`),
      bufferBindingType,
    };
  });
}

function parseSourceOutputOracle(value, storageBindings, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  if (value.schemaVersion !== 1) {
    throw new Error(`${label}.schemaVersion must be 1`);
  }
  const kind = requireString(value.kind, `${label}.kind`);
  if (kind !== SOURCE_KERNEL_OUTPUT_ORACLE_KIND) {
    throw new Error(`${label}.kind must be ${SOURCE_KERNEL_OUTPUT_ORACLE_KIND}`);
  }
  const initialization = requireString(value.initialization, `${label}.initialization`);
  if (initialization !== SOURCE_KERNEL_OUTPUT_ORACLE_INITIALIZATION) {
    throw new Error(
      `${label}.initialization must be ${SOURCE_KERNEL_OUTPUT_ORACLE_INITIALIZATION}`,
    );
  }
  const bindingGroup = requirePositiveInteger(
    value.bindingGroup,
    `${label}.bindingGroup`,
    { allowZero: true },
  );
  const binding = requirePositiveInteger(value.binding, `${label}.binding`, {
    allowZero: true,
  });
  if (!storageBindings.some(
    (candidate) => candidate.group === bindingGroup
      && candidate.binding === binding
      && candidate.bufferBindingType === "storage",
  )) {
    throw new Error(`${label} must reference a writable storage binding`);
  }
  return {
    schemaVersion: 1,
    kind,
    initialization,
    bindingGroup,
    binding,
    dispatchCount: requirePositiveInteger(
      value.dispatchCount,
      `${label}.dispatchCount`,
    ),
    expectedSha256: requireHashHex(value.expectedSha256, `${label}.expectedSha256`),
    referenceId: requireString(value.referenceId, `${label}.referenceId`),
  };
}

function parseDispatchArgs(value, label) {
  if (!Array.isArray(value) || value.length === 0) {
    throw new Error(`${label} must be a non-empty array`);
  }
  return value.map((args, index) => {
    if (!args || typeof args !== "object" || Array.isArray(args)) {
      throw new Error(`${label}[${index}] must be an object`);
    }
    return {
      x: requirePositiveInteger(args.x, `${label}[${index}].x`),
      y: requirePositiveInteger(args.y, `${label}[${index}].y`),
      z: requirePositiveInteger(args.z, `${label}[${index}].z`),
    };
  });
}

function loadProjectionManifest(path) {
  const payload = loadJsonObject(path);
  if (payload.schemaVersion !== PROJECTION_MANIFEST_SCHEMA_VERSION) {
    throw new Error(
      `invalid projection manifest schemaVersion, expected ${PROJECTION_MANIFEST_SCHEMA_VERSION}: ${path}`,
    );
  }
  if (!Array.isArray(payload.rows) || payload.rows.length === 0) {
    throw new Error(`invalid projection manifest: ${path}`);
  }
  const metadata = {
    sourceWorkloadsPath: requireString(payload.sourceWorkloadsPath, "sourceWorkloadsPath"),
    sourceWorkloadsSha256: requireHashHex(payload.sourceWorkloadsSha256, "sourceWorkloadsSha256"),
    rulesPath: requireString(payload.rulesPath, "rulesPath"),
    rulesSha256: requireHashHex(payload.rulesSha256, "rulesSha256"),
    projectionContractHash: requireHashHex(
      payload.projectionContractHash,
      "projectionContractHash",
    ),
    generatedAt: requireString(payload.generatedAt, "generatedAt"),
  };

  const rows = payload.rows.map((row, index) => {
    if (!row || typeof row !== "object" || Array.isArray(row)) {
      throw new Error(`invalid projection row at index ${index}`);
    }
    const projectionClass = requireString(row.projectionClass, `rows[${index}].projectionClass`);
    const requiredStatus = requireString(row.requiredStatus, `rows[${index}].requiredStatus`);
    const comparabilityExpectation = requireString(
      row.comparabilityExpectation,
      `rows[${index}].comparabilityExpectation`,
    );
    const claimScope = requireString(row.claimScope, `rows[${index}].claimScope`);
    if ((projectionClass === "high" || projectionClass === "medium") && requiredStatus !== "ok") {
      throw new Error(`projection row ${index} high/medium must use requiredStatus=ok`);
    }
    if (projectionClass === "non_projectable" && requiredStatus !== "not_applicable") {
      throw new Error(`projection row ${index} non_projectable must use requiredStatus=not_applicable`);
    }
    if (comparabilityExpectation === "strict" && claimScope !== "l1_strict_candidate") {
      throw new Error(`projection row ${index} strict comparability requires l1_strict_candidate`);
    }
    if (comparabilityExpectation === "component" && claimScope !== "l1_component_only") {
      throw new Error(`projection row ${index} component comparability requires l1_component_only`);
    }
    if (comparabilityExpectation === "none" && claimScope !== "l0_only_no_claim") {
      throw new Error(`projection row ${index} none comparability requires l0_only_no_claim`);
    }
    return {
      sourceWorkloadId: requireString(row.sourceWorkloadId, `rows[${index}].sourceWorkloadId`),
      sourceWorkloadName: requireString(
        row.sourceWorkloadName,
        `rows[${index}].sourceWorkloadName`,
      ),
      domain: requireString(row.domain, `rows[${index}].domain`),
      projectionClass,
      layerTarget: requireString(row.layerTarget, `rows[${index}].layerTarget`),
      scenarioTemplate: requireString(
        row.scenarioTemplate,
        `rows[${index}].scenarioTemplate`,
      ),
      comparabilityExpectation,
      requiredStatus,
      claimScope,
      claimLanguage: requireString(row.claimLanguage, `rows[${index}].claimLanguage`),
      projectionNote: requireString(row.projectionNote, `rows[${index}].projectionNote`),
      browserWorkload: parseBrowserWorkload(
        row.browserWorkload,
        `rows[${index}].browserWorkload`,
        row.domain,
      ),
      runtimes: {},
    };
  });
  return { metadata, rows };
}

function parseBrowserWorkload(value, label, domain) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  if (typeof value.sourceComparable !== "boolean") {
    throw new Error(`${label}.sourceComparable must be a boolean`);
  }
  if (typeof value.sourceClaimEligible !== "boolean") {
    throw new Error(`${label}.sourceClaimEligible must be a boolean`);
  }
  const parsed = {
    sourceComparable: value.sourceComparable,
    sourceClaimEligible: value.sourceClaimEligible,
  };
  if (typeof value.benchmarkClass === "string" && value.benchmarkClass.length > 0) {
    parsed.benchmarkClass = value.benchmarkClass;
  }
  if (value.uploadBytes !== undefined) {
    if (!Number.isSafeInteger(value.uploadBytes) || value.uploadBytes <= 0) {
      throw new Error(`${label}.uploadBytes must be a positive integer`);
    }
    parsed.uploadBytes = value.uploadBytes;
  }
  if (domain === "upload" && !Number.isSafeInteger(parsed.uploadBytes)) {
    throw new Error(`${label}.uploadBytes is required for upload rows`);
  }
  if (typeof value.computeProjection === "string" && value.computeProjection.length > 0) {
    parsed.computeProjection = value.computeProjection;
  }
  if (domain === "compute" && !COMPUTE_PROJECTIONS.includes(parsed.computeProjection)) {
    throw new Error(`${label}.computeProjection is required for compute rows`);
  }
  if (parsed.computeProjection === COMPUTE_PROJECTION_DIRECT_DISPATCH) {
    parsed.commandsPath = requireString(value.commandsPath, `${label}.commandsPath`);
    parsed.commandsSha256 = requireHashHex(value.commandsSha256, `${label}.commandsSha256`);
    parsed.directDispatchArgs = parseDispatchArgs(
      value.directDispatchArgs,
      `${label}.directDispatchArgs`,
    );
  }
  if (parsed.computeProjection === COMPUTE_PROJECTION_INDIRECT_DISPATCH) {
    parsed.commandsPath = requireString(value.commandsPath, `${label}.commandsPath`);
    parsed.commandsSha256 = requireHashHex(value.commandsSha256, `${label}.commandsSha256`);
    parsed.indirectDispatchArgs = parseDispatchArgs(
      value.indirectDispatchArgs,
      `${label}.indirectDispatchArgs`,
    );
  }
  if ([
    COMPUTE_PROJECTION_SOURCE_KERNEL,
    COMPUTE_PROJECTION_SOURCE_KERNEL_ORACLE,
  ].includes(parsed.computeProjection)) {
    parsed.bindGroupLayoutMode = requireString(
      value.bindGroupLayoutMode,
      `${label}.bindGroupLayoutMode`,
    );
    if (parsed.bindGroupLayoutMode !== SOURCE_KERNEL_BIND_GROUP_LAYOUT_MODE) {
      throw new Error(
        `${label}.bindGroupLayoutMode must be ${SOURCE_KERNEL_BIND_GROUP_LAYOUT_MODE}`,
      );
    }
    parsed.readbackBindingPolicy = requireString(
      value.readbackBindingPolicy,
      `${label}.readbackBindingPolicy`,
    );
    if (parsed.readbackBindingPolicy !== SOURCE_KERNEL_READBACK_BINDING_POLICY) {
      throw new Error(
        `${label}.readbackBindingPolicy must be ${SOURCE_KERNEL_READBACK_BINDING_POLICY}`,
      );
    }
    parsed.commandsPath = requireString(value.commandsPath, `${label}.commandsPath`);
    parsed.commandsSha256 = requireHashHex(value.commandsSha256, `${label}.commandsSha256`);
    parsed.kernelPath = requireString(value.kernelPath, `${label}.kernelPath`);
    parsed.kernelSha256 = requireHashHex(value.kernelSha256, `${label}.kernelSha256`);
    parsed.dispatchX = requirePositiveInteger(value.dispatchX, `${label}.dispatchX`);
    parsed.dispatchY = requirePositiveInteger(value.dispatchY, `${label}.dispatchY`);
    parsed.dispatchZ = requirePositiveInteger(value.dispatchZ, `${label}.dispatchZ`);
    parsed.dispatchRepeat = requirePositiveInteger(
      value.dispatchRepeat,
      `${label}.dispatchRepeat`,
    );
    parsed.warmupDispatchCount = requirePositiveInteger(
      value.warmupDispatchCount,
      `${label}.warmupDispatchCount`,
      { allowZero: true },
    );
    parsed.storageBindings = parseStorageBindings(
      value.storageBindings,
      `${label}.storageBindings`,
    );
    if (!parsed.storageBindings.some((binding) => binding.bufferBindingType === "storage")) {
      throw new Error(`${label}.storageBindings must include a writable storage binding`);
    }
    if (parsed.computeProjection === COMPUTE_PROJECTION_SOURCE_KERNEL_ORACLE) {
      parsed.outputOracle = parseSourceOutputOracle(
        value.outputOracle,
        parsed.storageBindings,
        `${label}.outputOracle`,
      );
    }
  }
  for (const key of ["textureWidth", "textureHeight", "mipLevelCount"]) {
    if (value[key] !== undefined) {
      if (!Number.isSafeInteger(value[key]) || value[key] <= 0) {
        throw new Error(`${label}.${key} must be a positive integer`);
      }
      parsed[key] = value[key];
    }
  }
  if (domain === "texture-contract") {
    for (const key of ["textureWidth", "textureHeight", "mipLevelCount"]) {
      if (!Number.isSafeInteger(parsed[key])) {
        throw new Error(`${label}.${key} is required for texture-contract rows`);
      }
    }
  }
  return parsed;
}

function loadWorkflowManifest(path) {
  const payload = loadJsonObject(path);
  if (payload.schemaVersion !== 3) {
    throw new Error(`invalid workflow manifest schemaVersion, expected 3: ${path}`);
  }
  if (!Array.isArray(payload.rows) || payload.rows.length === 0) {
    throw new Error(`invalid workflow manifest: ${path}`);
  }
  const promotionGateRequiredApprovals = Array.isArray(payload.promotionGateRequiredApprovals)
    ? payload.promotionGateRequiredApprovals.map((value, index) =>
        requireString(value, `promotionGateRequiredApprovals[${index}]`),
      )
    : null;
  if (!promotionGateRequiredApprovals || promotionGateRequiredApprovals.length === 0) {
    throw new Error("workflow manifest missing promotionGateRequiredApprovals[]");
  }

  const rows = payload.rows.map((row, index) => {
    if (!row || typeof row !== "object" || Array.isArray(row)) {
      throw new Error(`invalid workflow row at index ${index}`);
    }
    if (!Array.isArray(row.metrics)) {
      throw new Error(`workflow row must include metrics[] at index ${index}`);
    }
    const required = Boolean(row.required);
    const requiredStatus = requireString(row.requiredStatus, `rows[${index}].requiredStatus`);
    if (required && requiredStatus !== "ok") {
      throw new Error(`workflow row required=true must use requiredStatus=ok at index ${index}`);
    }
    if (!required && requiredStatus !== "optional") {
      throw new Error(
        `workflow row required=false must use requiredStatus=optional at index ${index}`,
      );
    }
    const workflow = {
      id: requireString(row.id, `rows[${index}].id`),
      scenarioTemplate: requireString(
        row.scenarioTemplate,
        `rows[${index}].scenarioTemplate`,
      ),
      description: requireString(row.description, `rows[${index}].description`),
      metrics: row.metrics,
      comparabilityExpectation: requireString(
        row.comparabilityExpectation,
        `rows[${index}].comparabilityExpectation`,
      ),
      requiredStatus,
      claimScope: requireString(row.claimScope, `rows[${index}].claimScope`),
      claimLanguage: requireString(row.claimLanguage, `rows[${index}].claimLanguage`),
      required,
      runtimes: {},
    };

    if (workflow.scenarioTemplate === "fawn_visual_resource") {
      const resourcePath = requireString(row.resourcePath, `rows[${index}].resourcePath`);
      if (
        !resourcePath.startsWith("browser/chromium/resources/") ||
        !resourcePath.endsWith(".html") ||
        resourcePath.includes("..")
      ) {
        throw new Error(
          `workflow row ${workflow.id} resourcePath must be a browser/chromium/resources/*.html path`,
        );
      }
      const resourceSha256 = fileHashHex(resolve(ROOT, resourcePath));
      if (!resourceSha256) {
        throw new Error(`workflow row ${workflow.id} resourcePath does not exist: ${resourcePath}`);
      }
      workflow.resourcePath = resourcePath;
      workflow.resourceSha256 = resourceSha256;
      workflow.statusSelector = row.statusSelector ?? "#status";
      workflow.frameSelector = row.frameSelector ?? "#frame";
      workflow.workloadSelector = row.workloadSelector ?? "#workload";
      workflow.adapterSelector = row.adapterSelector ?? "#adapter";
    }

    return workflow;
  });
  return { promotionGateRequiredApprovals, rows };
}

function browserProjectionScenarioConfig(row) {
  const browserWorkload = row.browserWorkload ?? {};
  if (
    browserWorkload.computeProjection === COMPUTE_PROJECTION_DIRECT_DISPATCH ||
    browserWorkload.computeProjection === COMPUTE_PROJECTION_INDIRECT_DISPATCH
  ) {
    const commandsPath = repoPath(browserWorkload.commandsPath);
    if (!pathWithin(commandsPath, ROOT)) {
      throw new Error(`commandsPath escapes repo root: ${browserWorkload.commandsPath}`);
    }
    const commandsSha256 = fileHashHex(commandsPath);
    if (commandsSha256 !== browserWorkload.commandsSha256) {
      throw new Error(
        `commandsSha256 mismatch for ${row.sourceWorkloadId}: ` +
          `expected ${browserWorkload.commandsSha256}, got ${commandsSha256}`,
      );
    }
    return row;
  }
  if (![
    COMPUTE_PROJECTION_SOURCE_KERNEL,
    COMPUTE_PROJECTION_SOURCE_KERNEL_ORACLE,
  ].includes(browserWorkload.computeProjection)) {
    return row;
  }
  const kernelPath = repoPath(browserWorkload.kernelPath);
  const commandsPath = repoPath(browserWorkload.commandsPath);
  if (!pathWithin(commandsPath, ROOT)) {
    throw new Error(`commandsPath escapes repo root: ${browserWorkload.commandsPath}`);
  }
  const commandsSha256 = fileHashHex(commandsPath);
  if (commandsSha256 !== browserWorkload.commandsSha256) {
    throw new Error(
      `commandsSha256 mismatch for ${row.sourceWorkloadId}: ` +
        `expected ${browserWorkload.commandsSha256}, got ${commandsSha256}`,
    );
  }
  if (!pathWithin(kernelPath, ROOT)) {
    throw new Error(`kernelPath escapes repo root: ${browserWorkload.kernelPath}`);
  }
  const kernelSource = readTextFile(kernelPath);
  if (typeof kernelSource !== "string") {
    throw new Error(`kernelPath not found: ${browserWorkload.kernelPath}`);
  }
  const kernelSha256 = fileHashHex(kernelPath);
  if (kernelSha256 !== browserWorkload.kernelSha256) {
    throw new Error(
      `kernelSha256 mismatch for ${row.sourceWorkloadId}: ` +
        `expected ${browserWorkload.kernelSha256}, got ${kernelSha256}`,
    );
  }
  return {
    ...row,
    kernelSource,
  };
}

function categoryForProjectionRow(row) {
  if (row && typeof row.domain === "string" && row.domain.length > 0) {
    return CATEGORY_BY_DOMAIN[row.domain] ?? row.domain;
  }
  return "uncategorized";
}

function categoryForWorkflowRow(row) {
  if (row && typeof row.id === "string" && row.id.length > 0) {
    return CATEGORY_BY_WORKFLOW_ID[row.id] ?? "workflow";
  }
  return "workflow";
}

function applyFocusCategories(l1Rows, l2Rows, focusCategories) {
  const filter = {
    kind: focusCategories.length > 0 ? "category" : "none",
    categories: focusCategories,
    l1RowsBeforeFilter: l1Rows.length,
    l1RowsAfterFilter: l1Rows.length,
    l2RowsBeforeFilter: l2Rows.length,
    l2RowsAfterFilter: l2Rows.length,
  };
  if (focusCategories.length === 0) {
    return { l1Rows, l2Rows, filter };
  }

  const categorySet = new Set(focusCategories);
  const filteredL1Rows = l1Rows.filter((row) => categorySet.has(categoryForProjectionRow(row)));
  const filteredL2Rows = l2Rows.filter((row) => categorySet.has(categoryForWorkflowRow(row)));
  filter.l1RowsAfterFilter = filteredL1Rows.length;
  filter.l2RowsAfterFilter = filteredL2Rows.length;
  if (filteredL1Rows.length === 0 && filteredL2Rows.length === 0) {
    throw new Error(`--focus-category selected no browser rows: ${focusCategories.join(",")}`);
  }
  return { l1Rows: filteredL1Rows, l2Rows: filteredL2Rows, filter };
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
  const html =
    "<!doctype html><meta charset='utf-8'><title>doe-webgpu-layered-bench</title>";
  const server = http.createServer((req, res) => {
    res.setHeader("Cross-Origin-Embedder-Policy", "require-corp");
    res.setHeader("Cross-Origin-Opener-Policy", "same-origin");
    res.setHeader("Cross-Origin-Resource-Policy", "same-origin");
    res.setHeader("Cache-Control", "no-store");
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

function makeDataPageUrl() {
  const html =
    "<!doctype html><meta charset='utf-8'><title>doe-webgpu-layered-bench</title>";
  return `data:text/html;charset=utf-8,${encodeURIComponent(html)}`;
}

function browserSurfaceModuleUrl(baseUrl) {
  return new URL("/packages/doe-gpu/src/browser.js", baseUrl).href;
}

function resourceUrl(baseUrl, resourcePath) {
  return new URL(resourcePath, baseUrl).href;
}

async function resolvePageTarget(allowDataUrlFallback, apiSurface) {
  try {
    const { server, url, port } = await startLocalServer();
    return {
      kind: "server",
      server,
      url,
      port,
      warning: null,
    };
  } catch (error) {
    if (apiSurface === "package-browser") {
      return {
        kind: "unavailable",
        server: null,
        url: "",
        port: null,
        warning: `local server bind failed and --api-surface=package-browser requires local module serving: ${String(error)}`,
      };
    }
    if (!allowDataUrlFallback) {
      return {
        kind: "unavailable",
        server: null,
        url: "",
        port: null,
        warning: `local server bind failed (no fallback by default): ${String(error)}`,
      };
    }
    return {
      kind: "data",
      server: null,
      url: makeDataPageUrl(),
      port: null,
      warning: `local server unavailable, using data URL fallback: ${String(error)}`,
    };
  }
}

function baseLaunchArgs(port) {
  const args = [
    "--no-sandbox",
    "--disable-setuid-sandbox",
    "--disable-dev-shm-usage",
    "--ignore-gpu-blocklist",
    "--enable-unsafe-webgpu",
  ];
  if (Number.isInteger(port)) {
    args.push(`--unsafely-treat-insecure-origin-as-secure=http://127.0.0.1:${port}`);
  }
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

function runtimeArtifactIdentity(mode, args, chromePath) {
  const browserExecutableSha256 = fileHashHex(chromePath);
  return {
    browserExecutablePath: chromePath,
    browserExecutableSha256,
    dawnRuntimePath: chromePath,
    dawnRuntimeSha256: browserExecutableSha256,
    doeLibPath: mode === "doe" ? args.doeLibPath : null,
    doeLibSha256: mode === "doe" ? fileHashHex(args.doeLibPath) : null,
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

function buildRuntimeSelection(mode, args, chromePath, launchArgs) {
  const resolution = runtimeSelectionResolution(mode, args);
  return {
    ...resolution,
    selectorVersion: RUNTIME_SELECTOR_VERSION,
    artifactIdentity: runtimeArtifactIdentity(resolution.selectedRuntime, args, chromePath),
    launchArgsHash: hashHex(launchArgs),
  };
}

function shaderCompilerIdentity(mode, args, chromePath) {
  const resolution = runtimeSelectionResolution(mode, args);
  const artifactIdentity = runtimeArtifactIdentity(resolution.selectedRuntime, args, chromePath);
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

function adapterIdentityFromProbe(probe) {
  const adapterInfo =
    probe?.adapterInfo && typeof probe.adapterInfo === "object" ? probe.adapterInfo : {};
  const featureCount = Number.isInteger(probe?.featureCount) ? probe.featureCount : 0;
  return {
    adapterInfoSha256: hashHex(adapterInfo),
    featureCount,
  };
}

function expectedDoeAdapterArchitecture() {
  if (process.platform === "darwin") return "metal";
  if (process.platform === "win32") return "d3d12";
  return "vulkan";
}

function activeRuntimeProof(selectedRuntime, probe) {
  const adapterInfo =
    probe?.adapterInfo && typeof probe.adapterInfo === "object" ? probe.adapterInfo : {};
  const observed = {
    vendor: typeof adapterInfo.vendor === "string" ? adapterInfo.vendor : "",
    architecture:
      typeof adapterInfo.architecture === "string" ? adapterInfo.architecture : "",
    device: typeof adapterInfo.device === "string" ? adapterInfo.device : "",
    description:
      typeof adapterInfo.description === "string" ? adapterInfo.description : "",
  };
  const expected = selectedRuntime === "doe"
    ? { vendor: "Doe", architecture: expectedDoeAdapterArchitecture() }
    : { vendorMustNotEqual: "Doe", vendorMustBeNonEmpty: true };
  const matched = selectedRuntime === "doe"
    ? observed.vendor === expected.vendor && observed.architecture === expected.architecture
    : observed.vendor.length > 0 && observed.vendor !== "Doe";
  return {
    schemaVersion: 1,
    identitySource: "wgpuAdapterGetInfo",
    selectedRuntime,
    expected,
    observed,
    matched,
  };
}

async function probeRuntime(page, browserSurfaceArgs) {
  return page.evaluate(async ({ apiSurface, browserModuleUrl, powerPreference }) => {
    const browserSurface = apiSurface === "package-browser"
      ? await import(browserModuleUrl)
      : null;
    const browserRuntime = browserSurface?.createBrowserRuntime?.() ?? null;
    const gpu = browserRuntime?.gpu ?? navigator.gpu;
    const getCanvasContext = (canvas) =>
      browserRuntime ? browserRuntime.createCanvasContext(canvas) : canvas.getContext("webgpu");
    const response = {
      apiSurface,
      webgpuAvailable: typeof gpu !== "undefined",
      adapterAvailable: false,
      adapterInfo: null,
      featureCount: 0,
      webgpuCanvasApi: {
        offscreenCanvasAvailable: false,
        webgpuContextAvailable: false,
        webgpuContextHasConfigure: false,
        webgpuContextHasGetCurrentTexture: false,
        preferredCanvasFormatSupported: false,
        preferredCanvasFormat: null,
      },
      errors: [],
    };

    if (!response.webgpuAvailable) {
      response.errors.push("WebGPU surface unavailable");
      return response;
    }

    try {
      const adapterOptions =
        powerPreference === "default" ? undefined : { powerPreference };
      const adapter = await gpu.requestAdapter(adapterOptions);
      if (!adapter) {
        response.errors.push("requestAdapter returned null");
        return response;
      }
      response.adapterAvailable = true;
      response.featureCount = Array.from(adapter.features).length;
      if ("info" in adapter) {
        const info = adapter.info;
        response.adapterInfo = {
          vendor: typeof info?.vendor === "string" ? info.vendor : "",
          architecture: typeof info?.architecture === "string" ? info.architecture : "",
          device: typeof info?.device === "string" ? info.device : "",
          description: typeof info?.description === "string" ? info.description : "",
          subgroupMinSize: Number.isInteger(info?.subgroupMinSize) ? info.subgroupMinSize : 0,
          subgroupMaxSize: Number.isInteger(info?.subgroupMaxSize) ? info.subgroupMaxSize : 0,
        };
      }
      response.adapterRequestOptions = adapterOptions ?? {};
      response.webgpuCanvasApi.preferredCanvasFormatSupported =
        typeof gpu.getPreferredCanvasFormat === "function";
      if (response.webgpuCanvasApi.preferredCanvasFormatSupported) {
        try {
          response.webgpuCanvasApi.preferredCanvasFormat = gpu.getPreferredCanvasFormat();
        } catch (error) {
          response.errors.push(`getPreferredCanvasFormat failed: ${String(error)}`);
        }
      }
      if (typeof OffscreenCanvas !== "undefined") {
        response.webgpuCanvasApi.offscreenCanvasAvailable = true;
        const canvas = new OffscreenCanvas(1, 1);
        const context = getCanvasContext(canvas);
        response.webgpuCanvasApi.webgpuContextAvailable = Boolean(context);
        if (context) {
          response.webgpuCanvasApi.webgpuContextHasConfigure = typeof context.configure === "function";
          response.webgpuCanvasApi.webgpuContextHasGetCurrentTexture =
            typeof context.getCurrentTexture === "function";
        }
      }
    } catch (error) {
      response.errors.push(String(error));
    }

    return response;
  }, browserSurfaceArgs);
}

async function runScenario(
  page,
  template,
  iterations,
  browserSurfaceArgs,
  scenarioConfig = {},
  sourceKernelSamples = DEFAULT_SOURCE_KERNEL_SAMPLES,
  sourceKernelWarmupSamples = DEFAULT_SOURCE_KERNEL_WARMUP_SAMPLES,
  sourceKernelSubmitPolicy = DEFAULT_SOURCE_KERNEL_SUBMIT_POLICY,
) {
  const evaluation = page.evaluate(
    async ({
      scenarioTemplate,
      runIterations,
      apiSurface,
      browserModuleUrl,
      powerPreference,
      scenarioConfig,
      sourceKernelSamples,
      sourceKernelWarmupSamples,
      sourceKernelSubmitPolicy,
    }) => {
      const result = {
        apiSurface,
        status: "fail",
        statusCode: "scenario_runtime_error",
        error: null,
        metrics: {},
      };

      const computeProjectionDirectDispatch = "generic_direct_dispatch_component";
      const computeProjectionIndirectDispatch = "generic_indirect_dispatch_component";
      const computeProjectionSourceKernel = "source_kernel_dispatch_v1";
      const computeProjectionSourceKernelOracle = "source_kernel_dispatch_oracle_v2";
      const genericComputeWarmupSubmits = 20;
      const indirectDispatchArgumentWords = 3;
      const indirectDispatchArgumentBytes =
        indirectDispatchArgumentWords * Uint32Array.BYTES_PER_ELEMENT;

      const nowMs = () => performance.now();
      async function sha256Hex(bytes) {
        if (!globalThis.crypto?.subtle) {
          throw new Error("Web Crypto SHA-256 unavailable for source-kernel oracle");
        }
        const digest = await globalThis.crypto.subtle.digest("SHA-256", bytes);
        return [...new Uint8Array(digest)]
          .map((value) => value.toString(16).padStart(2, "0"))
          .join("");
      }
      const browserSurface = apiSurface === "package-browser"
        ? await import(browserModuleUrl)
        : null;
      const browserRuntime = browserSurface?.createBrowserRuntime?.() ?? null;
      const gpu = browserRuntime?.gpu ?? navigator.gpu;
      const getCanvasContext = (canvas) =>
        browserRuntime ? browserRuntime.createCanvasContext(canvas) : canvas.getContext("webgpu");

      async function initDevice() {
        if (typeof gpu === "undefined") {
          throw new Error("WebGPU surface unavailable");
        }
        const adapterOptions =
          powerPreference === "default" ? undefined : { powerPreference };
        const adapterStart = nowMs();
        const adapter = await gpu.requestAdapter(adapterOptions);
        const adapterEnd = nowMs();
        if (!adapter) {
          throw new Error("requestAdapter returned null");
        }
        const deviceStart = nowMs();
        const device = await adapter.requestDevice();
        const deviceEnd = nowMs();
        return {
          adapter,
          device,
          adapterRequestMs: adapterEnd - adapterStart,
          deviceRequestMs: deviceEnd - deviceStart,
        };
      }

      function percentile(sortedValues, fraction) {
        if (sortedValues.length === 0) {
          return 0;
        }
        const index = Math.min(
          sortedValues.length - 1,
          Math.max(0, Math.ceil(sortedValues.length * fraction) - 1),
        );
        return sortedValues[index];
      }

      function summarizeValues(values) {
        const numeric = values
          .filter((value) => Number.isFinite(value))
          .sort((left, right) => left - right);
        if (numeric.length === 0) {
          return null;
        }
        const sum = numeric.reduce((acc, value) => acc + value, 0);
        return {
          avg: sum / numeric.length,
          p10: percentile(numeric, 0.10),
          p50: percentile(numeric, 0.50),
          p95: percentile(numeric, 0.95),
          p99: percentile(numeric, 0.99),
        };
      }

      function addTimingStats(samples, sampleKey, metricName) {
        const summary = summarizeValues(samples.map((sample) => sample[sampleKey]));
        if (!summary) {
          return;
        }
        result.metrics[metricName] = summary.p50;
        result.metrics[`${metricName}Avg`] = summary.avg;
        result.metrics[`${metricName}P10`] = summary.p10;
        result.metrics[`${metricName}P50`] = summary.p50;
        result.metrics[`${metricName}P95`] = summary.p95;
        result.metrics[`${metricName}P99`] = summary.p99;
      }

      function uploadIterationsForSize(size, requestedIterations) {
        if (size <= 4 * 1024) {
          return Math.max(requestedIterations, 4096);
        }
        if (size <= 64 * 1024) {
          return Math.max(requestedIterations, 1024);
        }
        if (size <= 1024 * 1024) {
          return Math.max(requestedIterations, 256);
        }
        return requestedIterations;
      }

      async function runWriteBuffer(device) {
        const requestedIterations = runIterations.upload;
        const size = scenarioConfig?.browserWorkload?.uploadBytes;
        if (!Number.isSafeInteger(size) || size <= 0) {
          throw new Error("write_buffer_upload missing browserWorkload.uploadBytes");
        }
        const iterations = uploadIterationsForSize(size, requestedIterations);
        const payload = new Uint8Array(size);
        const buffer = device.createBuffer({
          size,
          usage: GPUBufferUsage.COPY_DST,
        });
        for (let i = 0; i < 20; i += 1) {
          device.queue.writeBuffer(buffer, 0, payload);
        }
        await device.queue.onSubmittedWorkDone();
        const t0 = nowMs();
        for (let i = 0; i < iterations; i += 1) {
          device.queue.writeBuffer(buffer, 0, payload);
        }
        await device.queue.onSubmittedWorkDone();
        const t1 = nowMs();
        result.metrics.iterations = iterations;
        result.metrics.requestedIterations = requestedIterations;
        result.metrics.uploadBytes = size;
        result.metrics.totalUploadBytes = size * iterations;
        result.metrics.iterationPolicy = "browser-upload-size-floor-v1";
        result.metrics.usPerOp = ((t1 - t0) * 1000) / iterations;
      }

      async function runComputeDispatch(device, dispatchIters) {
        const computeConfig = scenarioConfig?.browserWorkload ?? {};
        if ([
          computeProjectionSourceKernel,
          computeProjectionSourceKernelOracle,
        ].includes(computeConfig.computeProjection)) {
          const kernelSource = scenarioConfig?.kernelSource;
          if (typeof kernelSource !== "string" || kernelSource.length === 0) {
            throw new Error(`${computeProjectionSourceKernel} missing kernelSource`);
          }
          const storageBindings = computeConfig.storageBindings;
          if (!Array.isArray(storageBindings) || storageBindings.length === 0) {
            throw new Error(`${computeProjectionSourceKernel} missing storageBindings`);
          }
          const storageBufferUsageLabels = ["STORAGE", "COPY_DST", "COPY_SRC"];
          const readbackSampleByteCount = 16;

          let t0 = nowMs();
          const storageBufferUsage =
            GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST | GPUBufferUsage.COPY_SRC;
          const buffers = storageBindings.map((binding) => {
            const buffer = device.createBuffer({
              size: binding.bufferSize,
              usage: storageBufferUsage,
            });
            device.queue.writeBuffer(buffer, 0, new Uint8Array(binding.bufferSize));
            return { ...binding, buffer };
          });
          await device.queue.onSubmittedWorkDone();
          result.metrics.bufferInitMs = nowMs() - t0;

          t0 = nowMs();
          const shader = device.createShaderModule({ code: kernelSource });
          result.metrics.shaderModuleMs = nowMs() - t0;

          t0 = nowMs();
          const bindingsByGroup = new Map();
          for (const binding of buffers) {
            const groupEntries = bindingsByGroup.get(binding.group) ?? {
              bindGroupEntries: [],
              layoutEntries: [],
            };
            groupEntries.bindGroupEntries.push({
              binding: binding.binding,
              resource: { buffer: binding.buffer },
            });
            groupEntries.layoutEntries.push({
              binding: binding.binding,
              visibility: GPUShaderStage.COMPUTE,
              buffer: {
                type: binding.bufferBindingType,
                minBindingSize: binding.minBindingSize,
              },
            });
            bindingsByGroup.set(binding.group, groupEntries);
          }
          const groupedBindings = [...bindingsByGroup.entries()].sort(
            ([left], [right]) => left - right,
          );
          for (let index = 0; index < groupedBindings.length; index += 1) {
            const [group] = groupedBindings[index];
            if (group !== index) {
              throw new Error(
                `${computeProjectionSourceKernel} requires contiguous bind groups ` +
                  `from 0, saw group ${group}`,
              );
            }
          }
          const bindGroupLayouts = groupedBindings.map(([group, entries]) => ({
            group,
            layout: device.createBindGroupLayout({
              entries: [...entries.layoutEntries].sort((left, right) => left.binding - right.binding),
            }),
          }));
          result.metrics.createBindGroupLayoutMs = nowMs() - t0;

          t0 = nowMs();
          const pipelineLayout = device.createPipelineLayout({
            bindGroupLayouts: bindGroupLayouts.map(({ layout }) => layout),
          });
          result.metrics.createPipelineLayoutMs = nowMs() - t0;

          t0 = nowMs();
          const pipeline = device.createComputePipeline({
            layout: pipelineLayout,
            compute: { module: shader, entryPoint: "main" },
          });
          result.metrics.computePipelineMs = nowMs() - t0;

          t0 = nowMs();
          const bindGroups = groupedBindings.map(([group, entries], index) => ({
            group,
            bindGroup: device.createBindGroup({
              layout: bindGroupLayouts[index].layout,
              entries: [...entries.bindGroupEntries].sort(
                (left, right) => left.binding - right.binding,
              ),
            }),
          }));
          result.metrics.createBindGroupMs = nowMs() - t0;

          function encodeDispatches(dispatchCount) {
            const encoder = device.createCommandEncoder();
            const pass = encoder.beginComputePass();
            pass.setPipeline(pipeline);
            for (const { group, bindGroup } of bindGroups) {
              pass.setBindGroup(group, bindGroup);
            }
            for (let i = 0; i < dispatchCount; i += 1) {
              pass.dispatchWorkgroups(
                computeConfig.dispatchX,
                computeConfig.dispatchY,
                computeConfig.dispatchZ,
              );
            }
            pass.end();
            device.queue.submit([encoder.finish()]);
          }

          const warmupDispatchCount = computeConfig.warmupDispatchCount ?? 0;
          const dispatchesPerSample = dispatchIters * computeConfig.dispatchRepeat;
          const submitsPerSample = sourceKernelSubmitPolicy === "sample-batch-v1"
            ? 1
            : dispatchIters;
          function encodeSampleDispatches() {
            if (sourceKernelSubmitPolicy === "sample-batch-v1") {
              encodeDispatches(dispatchesPerSample);
              return;
            }
            for (let i = 0; i < dispatchIters; i += 1) {
              encodeDispatches(computeConfig.dispatchRepeat);
            }
          }

          if (warmupDispatchCount > 0) {
            encodeDispatches(warmupDispatchCount);
            await device.queue.onSubmittedWorkDone();
          }

          for (let sampleIndex = 0; sampleIndex < sourceKernelWarmupSamples; sampleIndex += 1) {
            encodeSampleDispatches();
            await device.queue.onSubmittedWorkDone();
          }
          const dispatchSamples = [];
          for (let sampleIndex = 0; sampleIndex < sourceKernelSamples; sampleIndex += 1) {
            const sampleStartMs = nowMs();
            const encodeSubmitStartMs = nowMs();
            encodeSampleDispatches();
            const encodeSubmitMs = nowMs() - encodeSubmitStartMs;
            const waitStartMs = nowMs();
            await device.queue.onSubmittedWorkDone();
            const waitMs = nowMs() - waitStartMs;
            const elapsedMs = nowMs() - sampleStartMs;
            dispatchSamples.push({
              dispatchElapsedMs: elapsedMs,
              encodeSubmitMs,
              waitMs,
              usPerOp: (elapsedMs * 1000) / dispatchesPerSample,
            });
          }
          const totalDispatches = dispatchesPerSample * dispatchSamples.length;

          const readbackBinding = [...buffers]
            .sort((left, right) => left.group - right.group || left.binding - right.binding)
            .find((binding) => binding.bufferBindingType === "storage");
          if (!readbackBinding) {
            throw new Error(
              `${computeProjectionSourceKernel} missing writable storage binding for readback`,
            );
          }
          const readback = device.createBuffer({
            size: readbackBinding.bufferSize,
            usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
          });
          t0 = nowMs();
          const readbackEncoder = device.createCommandEncoder();
          readbackEncoder.copyBufferToBuffer(
            readbackBinding.buffer,
            0,
            readback,
            0,
            readbackBinding.bufferSize,
          );
          device.queue.submit([readbackEncoder.finish()]);
          result.metrics.submitReadbackMs = nowMs() - t0;

          t0 = nowMs();
          await device.queue.onSubmittedWorkDone();
          await readback.mapAsync(GPUMapMode.READ);
          const readbackData = new Uint8Array(readback.getMappedRange());
          let readbackChecksum = 0;
          for (let index = 0; index < readbackData.length; index += 1) {
            readbackChecksum = (readbackChecksum + readbackData[index] * ((index % 251) + 1)) >>> 0;
          }
          const readbackSampleBytes = Array.from(
            readbackData.slice(0, Math.min(readbackSampleByteCount, readbackData.length)),
          );
          const readbackSha256 = await sha256Hex(readbackData);
          readback.unmap();
          result.metrics.mapReadMs = nowMs() - t0;

          const outputOracle = computeConfig.outputOracle;
          if (outputOracle) {
            const oracleBinding = buffers.find(
              (candidate) => candidate.group === outputOracle.bindingGroup
                && candidate.binding === outputOracle.binding,
            );
            if (!oracleBinding || oracleBinding.bufferBindingType !== "storage") {
              throw new Error(`${computeProjectionSourceKernel} output oracle binding unavailable`);
            }
            t0 = nowMs();
            for (const binding of buffers) {
              device.queue.writeBuffer(binding.buffer, 0, new Uint8Array(binding.bufferSize));
            }
            await device.queue.onSubmittedWorkDone();
            result.metrics.outputOracleResetMs = nowMs() - t0;

            t0 = nowMs();
            encodeDispatches(outputOracle.dispatchCount);
            await device.queue.onSubmittedWorkDone();
            result.metrics.outputOracleDispatchMs = nowMs() - t0;

            const oracleReadback = device.createBuffer({
              size: oracleBinding.bufferSize,
              usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
            });
            t0 = nowMs();
            const oracleEncoder = device.createCommandEncoder();
            oracleEncoder.copyBufferToBuffer(
              oracleBinding.buffer,
              0,
              oracleReadback,
              0,
              oracleBinding.bufferSize,
            );
            device.queue.submit([oracleEncoder.finish()]);
            await device.queue.onSubmittedWorkDone();
            await oracleReadback.mapAsync(GPUMapMode.READ);
            const oracleData = new Uint8Array(oracleReadback.getMappedRange());
            const oracleActualSha256 = await sha256Hex(oracleData);
            const oracleSampleBytes = Array.from(
              oracleData.slice(0, Math.min(readbackSampleByteCount, oracleData.length)),
            );
            oracleReadback.unmap();
            oracleReadback.destroy();
            result.metrics.outputOracleReadbackMs = nowMs() - t0;
            result.metrics.outputOracleSchemaVersion = outputOracle.schemaVersion;
            result.metrics.outputOracleKind = outputOracle.kind;
            result.metrics.outputOracleInitialization = outputOracle.initialization;
            result.metrics.outputOracleBindingGroup = outputOracle.bindingGroup;
            result.metrics.outputOracleBinding = outputOracle.binding;
            result.metrics.outputOracleDispatchCount = outputOracle.dispatchCount;
            result.metrics.outputOracleExpectedSha256 = outputOracle.expectedSha256;
            result.metrics.outputOracleActualSha256 = oracleActualSha256;
            result.metrics.outputOracleReferenceId = outputOracle.referenceId;
            result.metrics.outputOracleSampleBytes = oracleSampleBytes;
            result.metrics.outputOracleMatched = oracleActualSha256 === outputOracle.expectedSha256;
            if (!result.metrics.outputOracleMatched) {
              throw new Error(
                `${computeProjectionSourceKernel} output oracle mismatch: `
                  + `expected ${outputOracle.expectedSha256}, got ${oracleActualSha256}`,
              );
            }
          }
          const bindGroupLayoutEntries = storageBindings
            .map((binding) => ({
              group: binding.group,
              binding: binding.binding,
              bufferBindingType: binding.bufferBindingType,
              minBindingSize: binding.minBindingSize,
            }))
            .sort((left, right) => left.group - right.group || left.binding - right.binding);

          result.metrics.iterations = dispatchIters;
          result.metrics.sourceKernelSampleCount = dispatchSamples.length;
          result.metrics.sourceKernelWarmupSampleCount = sourceKernelWarmupSamples;
          result.metrics.sourceKernelWarmupDispatches = dispatchesPerSample * sourceKernelWarmupSamples;
          result.metrics.totalWarmupDispatches = warmupDispatchCount + result.metrics.sourceKernelWarmupDispatches;
          result.metrics.sourceKernelSubmitPolicy = sourceKernelSubmitPolicy;
          result.metrics.submitsPerSample = submitsPerSample;
          result.metrics.warmupSubmitCount = warmupDispatchCount > 0 ? 1 : 0;
          result.metrics.sourceKernelWarmupSubmits = submitsPerSample * sourceKernelWarmupSamples;
          result.metrics.totalWarmupSubmits = result.metrics.warmupSubmitCount + result.metrics.sourceKernelWarmupSubmits;
          result.metrics.totalSubmits = submitsPerSample * dispatchSamples.length;
          result.metrics.dispatchesPerSample = dispatchesPerSample;
          result.metrics.dispatchWorkgroupsX = computeConfig.dispatchX;
          result.metrics.dispatchWorkgroupsY = computeConfig.dispatchY;
          result.metrics.dispatchWorkgroupsZ = computeConfig.dispatchZ;
          result.metrics.dispatchRepeat = computeConfig.dispatchRepeat;
          result.metrics.totalDispatches = totalDispatches;
          addTimingStats(dispatchSamples, "dispatchElapsedMs", "dispatchElapsedMs");
          addTimingStats(dispatchSamples, "encodeSubmitMs", "encodeSubmitMs");
          addTimingStats(dispatchSamples, "waitMs", "waitMs");
          addTimingStats(dispatchSamples, "usPerOp", "usPerOp");
          result.metrics.dispatchElapsedMsSamples = dispatchSamples.map(
            (sample) => sample.dispatchElapsedMs,
          );
          result.metrics.encodeSubmitMsSamples = dispatchSamples.map(
            (sample) => sample.encodeSubmitMs,
          );
          result.metrics.waitMsSamples = dispatchSamples.map((sample) => sample.waitMs);
          result.metrics.usPerOpSamples = dispatchSamples.map((sample) => sample.usPerOp);
          result.metrics.warmupDispatchCount = warmupDispatchCount;
          result.metrics.sourceKernelTimingPolicy = "batched_source_kernel_samples_v1";
          result.metrics.kernelPath = computeConfig.kernelPath;
          result.metrics.kernelSha256 = computeConfig.kernelSha256;
          result.metrics.commandsPath = computeConfig.commandsPath;
          result.metrics.commandsSha256 = computeConfig.commandsSha256;
          result.metrics.bindGroupLayoutMode = computeConfig.bindGroupLayoutMode;
          result.metrics.readbackBindingPolicy = computeConfig.readbackBindingPolicy;
          result.metrics.bindGroupLayoutEntryCount = bindGroupLayoutEntries.length;
          result.metrics.bindGroupLayoutEntries = bindGroupLayoutEntries;
          result.metrics.minBindingSizeBytes = bindGroupLayoutEntries.reduce(
            (sum, binding) => sum + binding.minBindingSize,
            0,
          );
          result.metrics.storageBindingCount = storageBindings.length;
          result.metrics.storageBufferBytes = storageBindings.reduce(
            (sum, binding) => sum + binding.bufferSize,
            0,
          );
          result.metrics.storageBufferUsage = storageBufferUsageLabels;
          result.metrics.readbackBindingGroup = readbackBinding.group;
          result.metrics.readbackBinding = readbackBinding.binding;
          result.metrics.readbackBytes = readbackBinding.bufferSize;
          result.metrics.readbackChecksum = readbackChecksum;
          result.metrics.readbackSha256 = readbackSha256;
          result.metrics.readbackSampleBytes = readbackSampleBytes;
          readback.destroy();
          for (const { buffer } of buffers) {
            buffer.destroy();
          }
          return;
        }

        if (computeConfig.computeProjection === computeProjectionDirectDispatch) {
          const directDispatchArgs = computeConfig.directDispatchArgs;
          if (!Array.isArray(directDispatchArgs) || directDispatchArgs.length === 0) {
            throw new Error(`${computeProjectionDirectDispatch} missing directDispatchArgs`);
          }

          const shader = device.createShaderModule({
            code: `
              @compute @workgroup_size(1)
              fn main() {}
            `,
          });
          const pipeline = device.createComputePipeline({
            layout: "auto",
            compute: { module: shader, entryPoint: "main" },
          });

          function encodeDirectDispatches() {
            const encoder = device.createCommandEncoder();
            const pass = encoder.beginComputePass();
            pass.setPipeline(pipeline);
            for (const args of directDispatchArgs) {
              pass.dispatchWorkgroups(args.x, args.y, args.z);
            }
            pass.end();
            device.queue.submit([encoder.finish()]);
          }

          for (let i = 0; i < genericComputeWarmupSubmits; i += 1) {
            encodeDirectDispatches();
          }
          await device.queue.onSubmittedWorkDone();
          const t0 = nowMs();
          const encodeSubmitStart = nowMs();
          for (let i = 0; i < dispatchIters; i += 1) {
            encodeDirectDispatches();
          }
          const encodeSubmitMs = nowMs() - encodeSubmitStart;
          const waitStart = nowMs();
          await device.queue.onSubmittedWorkDone();
          const waitMs = nowMs() - waitStart;
          const t1 = nowMs();
          const dispatchElapsedMs = t1 - t0;
          const dispatchesPerSubmit = directDispatchArgs.length;
          const totalDispatches = dispatchIters * dispatchesPerSubmit;
          result.metrics.iterations = dispatchIters;
          result.metrics.dispatchKind = "direct";
          result.metrics.directDispatchArgs = directDispatchArgs;
          result.metrics.dispatchesPerSubmit = dispatchesPerSubmit;
          result.metrics.totalDispatches = totalDispatches;
          result.metrics.totalSubmits = dispatchIters;
          result.metrics.warmupSubmitCount = genericComputeWarmupSubmits;
          result.metrics.totalWarmupDispatches =
            genericComputeWarmupSubmits * dispatchesPerSubmit;
          result.metrics.commandsPath = computeConfig.commandsPath;
          result.metrics.commandsSha256 = computeConfig.commandsSha256;
          result.metrics.computeProjection = computeConfig.computeProjection;
          result.metrics.dispatchElapsedMs = dispatchElapsedMs;
          result.metrics.encodeSubmitMs = encodeSubmitMs;
          result.metrics.waitMs = waitMs;
          result.metrics.usPerOp = (dispatchElapsedMs * 1000) / totalDispatches;
          return;
        }

        if (computeConfig.computeProjection === computeProjectionIndirectDispatch) {
          const indirectDispatchArgs = computeConfig.indirectDispatchArgs;
          if (!Array.isArray(indirectDispatchArgs) || indirectDispatchArgs.length === 0) {
            throw new Error(
              `${computeProjectionIndirectDispatch} missing indirectDispatchArgs`,
            );
          }
          const indirectArgWords = new Uint32Array(
            indirectDispatchArgs.length * indirectDispatchArgumentWords,
          );
          for (let index = 0; index < indirectDispatchArgs.length; index += 1) {
            const args = indirectDispatchArgs[index];
            const offset = index * indirectDispatchArgumentWords;
            indirectArgWords[offset] = args.x;
            indirectArgWords[offset + 1] = args.y;
            indirectArgWords[offset + 2] = args.z;
          }
          const indirectBuffer = device.createBuffer({
            size: indirectArgWords.byteLength,
            usage: GPUBufferUsage.INDIRECT | GPUBufferUsage.COPY_DST,
          });
          device.queue.writeBuffer(indirectBuffer, 0, indirectArgWords);

          const shader = device.createShaderModule({
            code: `
              @compute @workgroup_size(1)
              fn main() {}
            `,
          });
          const pipeline = device.createComputePipeline({
            layout: "auto",
            compute: { module: shader, entryPoint: "main" },
          });

          function encodeIndirectDispatches() {
            const encoder = device.createCommandEncoder();
            const pass = encoder.beginComputePass();
            pass.setPipeline(pipeline);
            for (let index = 0; index < indirectDispatchArgs.length; index += 1) {
              pass.dispatchWorkgroupsIndirect(
                indirectBuffer,
                index * indirectDispatchArgumentBytes,
              );
            }
            pass.end();
            device.queue.submit([encoder.finish()]);
          }

          for (let i = 0; i < genericComputeWarmupSubmits; i += 1) {
            encodeIndirectDispatches();
          }
          await device.queue.onSubmittedWorkDone();
          const t0 = nowMs();
          const encodeSubmitStart = nowMs();
          for (let i = 0; i < dispatchIters; i += 1) {
            encodeIndirectDispatches();
          }
          const encodeSubmitMs = nowMs() - encodeSubmitStart;
          const waitStart = nowMs();
          await device.queue.onSubmittedWorkDone();
          const waitMs = nowMs() - waitStart;
          const t1 = nowMs();
          const dispatchElapsedMs = t1 - t0;
          const dispatchesPerSubmit = indirectDispatchArgs.length;
          const totalDispatches = dispatchIters * dispatchesPerSubmit;
          result.metrics.iterations = dispatchIters;
          result.metrics.dispatchKind = "indirect";
          result.metrics.indirectDispatchArgs = indirectDispatchArgs;
          result.metrics.indirectDispatchArgBufferBytes = indirectArgWords.byteLength;
          result.metrics.dispatchesPerSubmit = dispatchesPerSubmit;
          result.metrics.totalDispatches = totalDispatches;
          result.metrics.totalSubmits = dispatchIters;
          result.metrics.warmupSubmitCount = genericComputeWarmupSubmits;
          result.metrics.totalWarmupDispatches =
            genericComputeWarmupSubmits * dispatchesPerSubmit;
          result.metrics.commandsPath = computeConfig.commandsPath;
          result.metrics.commandsSha256 = computeConfig.commandsSha256;
          result.metrics.computeProjection = computeConfig.computeProjection;
          result.metrics.dispatchElapsedMs = dispatchElapsedMs;
          result.metrics.encodeSubmitMs = encodeSubmitMs;
          result.metrics.waitMs = waitMs;
          result.metrics.usPerOp = (dispatchElapsedMs * 1000) / totalDispatches;
          indirectBuffer.destroy();
          return;
        }

        const shader = device.createShaderModule({
          code: `
            @compute @workgroup_size(1)
            fn main() {}
          `,
        });
        const pipeline = device.createComputePipeline({
          layout: "auto",
          compute: { module: shader, entryPoint: "main" },
        });
        for (let i = 0; i < genericComputeWarmupSubmits; i += 1) {
          const encoder = device.createCommandEncoder();
          const pass = encoder.beginComputePass();
          pass.setPipeline(pipeline);
          pass.dispatchWorkgroups(1);
          pass.end();
          device.queue.submit([encoder.finish()]);
        }
        await device.queue.onSubmittedWorkDone();
        const t0 = nowMs();
        const encodeSubmitStart = nowMs();
        for (let i = 0; i < dispatchIters; i += 1) {
          const encoder = device.createCommandEncoder();
          const pass = encoder.beginComputePass();
          pass.setPipeline(pipeline);
          pass.dispatchWorkgroups(1);
          pass.end();
          device.queue.submit([encoder.finish()]);
        }
        const encodeSubmitMs = nowMs() - encodeSubmitStart;
        const waitStart = nowMs();
        await device.queue.onSubmittedWorkDone();
        const waitMs = nowMs() - waitStart;
        const t1 = nowMs();
        const dispatchElapsedMs = t1 - t0;
        result.metrics.iterations = dispatchIters;
        result.metrics.dispatchKind = "direct";
        result.metrics.dispatchesPerSubmit = 1;
        result.metrics.totalDispatches = dispatchIters;
        result.metrics.totalSubmits = dispatchIters;
        result.metrics.warmupSubmitCount = genericComputeWarmupSubmits;
        result.metrics.totalWarmupDispatches = genericComputeWarmupSubmits;
        result.metrics.computeProjection = computeConfig.computeProjection;
        result.metrics.dispatchElapsedMs = dispatchElapsedMs;
        result.metrics.encodeSubmitMs = encodeSubmitMs;
        result.metrics.waitMs = waitMs;
        result.metrics.usPerOp = (dispatchElapsedMs * 1000) / dispatchIters;
      }

      async function runRenderTriangleReadback(device) {
        const width = 64;
        const height = 64;
        const viewport = { x: 16, y: 16, width: 32, height: 32 };
        const outsidePixel = { x: 8, y: 8 };
        const format = "rgba8unorm";
        const totalStart = nowMs();

        let t0 = nowMs();
        const renderTarget = device.createTexture({
          size: { width, height, depthOrArrayLayers: 1 },
          format,
          usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC,
        });
        result.metrics.createRenderTargetMs = nowMs() - t0;

        t0 = nowMs();
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
        result.metrics.shaderModuleMs = nowMs() - t0;

        t0 = nowMs();
        const pipeline = device.createRenderPipeline({
          layout: "auto",
          vertex: { module: shader, entryPoint: "vs" },
          fragment: { module: shader, entryPoint: "fs", targets: [{ format }] },
          primitive: { topology: "triangle-list" },
        });
        result.metrics.renderPipelineMs = nowMs() - t0;

        t0 = nowMs();
        const renderTargetView = renderTarget.createView();
        result.metrics.createViewMs = nowMs() - t0;

        t0 = nowMs();
        const encoder = device.createCommandEncoder();
        const pass = encoder.beginRenderPass({
          colorAttachments: [
            {
              view: renderTargetView,
              clearValue: { r: 0, g: 0, b: 0, a: 1 },
              loadOp: "clear",
              storeOp: "store",
            },
          ],
        });
        pass.setPipeline(pipeline);
        pass.setViewport(
          viewport.x,
          viewport.y,
          viewport.width,
          viewport.height,
          0,
          1,
        );
        pass.setScissorRect(
          viewport.x,
          viewport.y,
          viewport.width,
          viewport.height,
        );
        pass.draw(3);
        pass.end();

        const bytesPerRow = 256;
        const readback = device.createBuffer({
          size: bytesPerRow * height,
          usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
        });
        encoder.copyTextureToBuffer(
          { texture: renderTarget },
          { buffer: readback, bytesPerRow, rowsPerImage: height },
          { width, height, depthOrArrayLayers: 1 },
        );
        device.queue.submit([encoder.finish()]);
        result.metrics.submitReadbackMs = nowMs() - t0;

        t0 = nowMs();
        await device.queue.onSubmittedWorkDone();
        await readback.mapAsync(GPUMapMode.READ);
        const data = new Uint8Array(readback.getMappedRange());
        const centerOffset = Math.floor(height / 2) * bytesPerRow + Math.floor(width / 2) * 4;
        const outsideOffset = outsidePixel.y * bytesPerRow + outsidePixel.x * 4;
        const centerRgba = Array.from(data.slice(centerOffset, centerOffset + 4));
        const outsideRgba = Array.from(data.slice(outsideOffset, outsideOffset + 4));
        readback.unmap();
        result.metrics.mapReadMs = nowMs() - t0;

        t0 = nowMs();
        renderTarget.destroy();
        readback.destroy();
        result.metrics.destroyMs = nowMs() - t0;
        result.metrics.renderMs = nowMs() - totalStart;
        result.metrics.centerRgba = centerRgba;
        result.metrics.outsideRgba = outsideRgba;
        result.metrics.viewport = viewport;
        result.metrics.dynamicStateOracle = "viewport_scissor_inside_red_outside_clear_v1";
        const centerPass =
          centerRgba[0] > 100 &&
          centerRgba[0] > centerRgba[1] + 20 &&
          centerRgba[0] > centerRgba[2] + 20;
        const outsidePass =
          outsideRgba[0] < 20 &&
          outsideRgba[1] < 20 &&
          outsideRgba[2] < 20 &&
          outsideRgba[3] > 200;
        result.metrics.pass = centerPass && outsidePass;
        if (!result.metrics.pass) {
          throw new Error("viewport/scissor render readback oracle failed");
        }
      }

      async function runRenderBundleReplay(device) {
        let stage = "init";
        try {
        const iterations = runIterations.render;
        const width = 64;
        const height = 64;
        const canvas = new OffscreenCanvas(width, height);
        stage = "getContext";
        const context = getCanvasContext(canvas);
        if (!context) {
          throw new Error("OffscreenCanvas.getContext('webgpu') returned null");
        }
        const format = gpu.getPreferredCanvasFormat();
        stage = "configure";
        context.configure({ device, format, alphaMode: "opaque" });

        stage = "shaderModule";
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
              return vec4<f32>(0.0, 0.8, 0.0, 1.0);
            }
          `,
        });

        const pipeline = device.createRenderPipeline({
          layout: "auto",
          vertex: { module: shader, entryPoint: "vs" },
          fragment: { module: shader, entryPoint: "fs", targets: [{ format }] },
          primitive: { topology: "triangle-list" },
        });

        stage = "bundleEncoder";
        const bundleEncoder = device.createRenderBundleEncoder({
          colorFormats: [format],
        });
        bundleEncoder.setPipeline(pipeline);
        bundleEncoder.draw(3);
        const bundle = bundleEncoder.finish();

        for (let i = 0; i < 10; i += 1) {
          stage = `warmup.frame:${i}`;
          const encoder = device.createCommandEncoder();
          const pass = encoder.beginRenderPass({
            colorAttachments: [
              {
                view: context.getCurrentTexture().createView(),
                clearValue: { r: 0, g: 0, b: 0, a: 1 },
                loadOp: "clear",
                storeOp: "store",
              },
            ],
          });
          pass.executeBundles([bundle]);
          pass.end();
          device.queue.submit([encoder.finish()]);
        }
        await device.queue.onSubmittedWorkDone();

        const t0 = nowMs();
        for (let i = 0; i < iterations; i += 1) {
          stage = `timed.frame:${i}`;
          const encoder = device.createCommandEncoder();
          const pass = encoder.beginRenderPass({
            colorAttachments: [
              {
                view: context.getCurrentTexture().createView(),
                clearValue: { r: 0, g: 0, b: 0, a: 1 },
                loadOp: "clear",
                storeOp: "store",
              },
            ],
          });
          pass.executeBundles([bundle]);
          pass.end();
          device.queue.submit([encoder.finish()]);
        }
        await device.queue.onSubmittedWorkDone();
        const t1 = nowMs();
        result.metrics.iterations = iterations;
        result.metrics.usPerOp = ((t1 - t0) * 1000) / iterations;
        } catch (error) {
          throw new Error(`${stage}: ${String(error)}`);
        }
      }

      async function runTextureSampleRaster(device) {
        const iterations = runIterations.texture;
        const width = 4;
        const height = 4;
        const outputWidth = 64;
        const outputHeight = 64;
        const bytesPerRow = 256;
        const data = new Uint8Array(width * height * 4);
        for (let i = 0; i < data.length; i += 4) {
          data[i] = 255;
          data[i + 3] = 255;
        }
        const format = "rgba8unorm";
        const samples = [];
        let center = [];

        async function sampleOnce(collect) {
          const sample = {};
          const totalStart = nowMs();

          let t0 = nowMs();
          const texture = device.createTexture({
            size: { width, height, depthOrArrayLayers: 1 },
            format: "rgba8unorm",
            usage:
              GPUTextureUsage.TEXTURE_BINDING |
              GPUTextureUsage.COPY_DST,
          });
          sample.createTextureMs = nowMs() - t0;

          t0 = nowMs();
          device.queue.writeTexture(
            { texture },
            data,
            { bytesPerRow: width * 4, rowsPerImage: height },
            { width, height, depthOrArrayLayers: 1 },
          );
          sample.writeTextureMs = nowMs() - t0;

          t0 = nowMs();
          const renderTarget = device.createTexture({
            size: { width: outputWidth, height: outputHeight, depthOrArrayLayers: 1 },
            format,
            usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC,
          });
          sample.createRenderTargetMs = nowMs() - t0;

          t0 = nowMs();
          const shader = device.createShaderModule({
            code: `
              struct VsOut {
                @builtin(position) pos: vec4<f32>,
                @location(0) uv: vec2<f32>,
              };

              @vertex
              fn vs(@builtin(vertex_index) index : u32) -> VsOut {
                var pos = array<vec2<f32>, 3>(
                  vec2<f32>(-1.0, -1.0),
                  vec2<f32>( 3.0, -1.0),
                  vec2<f32>(-1.0,  3.0)
                );
                var uv = array<vec2<f32>, 3>(
                  vec2<f32>(0.0, 0.0),
                  vec2<f32>(2.0, 0.0),
                  vec2<f32>(0.0, 2.0)
                );
                var out: VsOut;
                out.pos = vec4<f32>(pos[index], 0.0, 1.0);
                out.uv = uv[index];
                return out;
              }

              @group(0) @binding(0) var tex: texture_2d<f32>;
              @group(0) @binding(1) var samp: sampler;

              @fragment
              fn fs(in: VsOut) -> @location(0) vec4<f32> {
                return textureSample(tex, samp, in.uv * 0.5);
              }
            `,
          });
          sample.shaderModuleMs = nowMs() - t0;

          t0 = nowMs();
          const pipeline = device.createRenderPipeline({
            layout: "auto",
            vertex: { module: shader, entryPoint: "vs" },
            fragment: { module: shader, entryPoint: "fs", targets: [{ format }] },
            primitive: { topology: "triangle-list" },
          });
          sample.renderPipelineMs = nowMs() - t0;

          t0 = nowMs();
          const textureView = texture.createView();
          const renderTargetView = renderTarget.createView();
          sample.createViewMs = nowMs() - t0;

          t0 = nowMs();
          const sampler = device.createSampler({ magFilter: "nearest", minFilter: "nearest" });
          sample.createSamplerMs = nowMs() - t0;

          t0 = nowMs();
          const bindGroup = device.createBindGroup({
            layout: pipeline.getBindGroupLayout(0),
            entries: [
              { binding: 0, resource: textureView },
              { binding: 1, resource: sampler },
            ],
          });
          sample.createBindGroupMs = nowMs() - t0;

          const readback = device.createBuffer({
            size: bytesPerRow * outputHeight,
            usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
          });

          t0 = nowMs();
          const encoder = device.createCommandEncoder();
          const pass = encoder.beginRenderPass({
            colorAttachments: [
              {
                view: renderTargetView,
                clearValue: { r: 0, g: 0, b: 0, a: 1 },
                loadOp: "clear",
                storeOp: "store",
              },
            ],
          });
          pass.setPipeline(pipeline);
          pass.setBindGroup(0, bindGroup);
          pass.draw(3);
          pass.end();
          encoder.copyTextureToBuffer(
            { texture: renderTarget },
            { buffer: readback, bytesPerRow, rowsPerImage: outputHeight },
            { width: outputWidth, height: outputHeight, depthOrArrayLayers: 1 },
          );
          const commandBuffer = encoder.finish();
          device.queue.submit([commandBuffer]);
          sample.submitReadbackMs = nowMs() - t0;

          t0 = nowMs();
          await readback.mapAsync(GPUMapMode.READ);
          const mapped = new Uint8Array(readback.getMappedRange());
          const offset = 32 * bytesPerRow + 32 * 4;
          center = Array.from(mapped.slice(offset, offset + 4));
          readback.unmap();
          sample.mapReadMs = nowMs() - t0;

          t0 = nowMs();
          texture.destroy();
          renderTarget.destroy();
          readback.destroy();
          sample.destroyMs = nowMs() - t0;
          sample.textureMs = nowMs() - totalStart;
          if (collect) {
            samples.push(sample);
          }
        }

        await sampleOnce(false);
        for (let i = 0; i < iterations; i += 1) {
          await sampleOnce(true);
        }
        addTimingStats(samples, "textureMs", "textureMs");
        addTimingStats(samples, "createTextureMs", "createTextureMs");
        addTimingStats(samples, "writeTextureMs", "writeTextureMs");
        addTimingStats(samples, "createRenderTargetMs", "createRenderTargetMs");
        addTimingStats(samples, "shaderModuleMs", "shaderModuleMs");
        addTimingStats(samples, "renderPipelineMs", "renderPipelineMs");
        addTimingStats(samples, "createViewMs", "createViewMs");
        addTimingStats(samples, "createSamplerMs", "createSamplerMs");
        addTimingStats(samples, "createBindGroupMs", "createBindGroupMs");
        addTimingStats(samples, "submitReadbackMs", "submitReadbackMs");
        addTimingStats(samples, "mapReadMs", "mapReadMs");
        addTimingStats(samples, "destroyMs", "destroyMs");
        result.metrics.centerRgba = center;
        result.metrics.textureIterations = iterations;
        result.metrics.textureWarmupIterations = 1;
        result.metrics.pass = center[0] > 100;
        if (!result.metrics.pass) {
          throw new Error("texture sample raster check failed");
        }
      }

      async function runTextureWriteQueryDestroy(device) {
        const iterations = runIterations.texture;
        const textureConfig = scenarioConfig?.browserWorkload ?? {};
        const width = textureConfig.textureWidth ?? 128;
        const height = textureConfig.textureHeight ?? 128;
        const mipLevelCount = textureConfig.mipLevelCount ?? 1;
        const payload = new Uint8Array(width * height * 4);
        payload.fill(17);
        const samples = [];

        async function sampleOnce(collect) {
          const sample = {};
          const totalStart = nowMs();

          let t0 = nowMs();
          const texture = device.createTexture({
            size: { width, height, depthOrArrayLayers: 1 },
            format: "rgba8unorm",
            usage:
              GPUTextureUsage.TEXTURE_BINDING |
              GPUTextureUsage.COPY_DST |
              GPUTextureUsage.RENDER_ATTACHMENT,
            mipLevelCount,
            sampleCount: 1,
          });
          sample.createTextureMs = nowMs() - t0;

          t0 = nowMs();
          device.queue.writeTexture(
            { texture },
            payload,
            { bytesPerRow: width * 4, rowsPerImage: height },
            { width, height, depthOrArrayLayers: 1 },
          );
          sample.writeTextureMs = nowMs() - t0;

          t0 = nowMs();
          await device.queue.onSubmittedWorkDone();
          sample.waitMs = nowMs() - t0;

          t0 = nowMs();
          const view = texture.createView();
          sample.createViewMs = nowMs() - t0;

          t0 = nowMs();
          result.metrics.width = texture.width;
          result.metrics.height = texture.height;
          result.metrics.depthOrArrayLayers = texture.depthOrArrayLayers;
          result.metrics.mipLevelCount = texture.mipLevelCount;
          result.metrics.sampleCount = texture.sampleCount;
          result.metrics.dimension = texture.dimension;
          result.metrics.format = texture.format;
          result.metrics.usage = texture.usage;
          result.metrics.viewCreated = Boolean(view);
          sample.propertyQueryMs = nowMs() - t0;

          t0 = nowMs();
          texture.destroy();
          sample.destroyMs = nowMs() - t0;
          sample.textureMs = nowMs() - totalStart;
          if (collect) {
            samples.push(sample);
          }
        }

        await sampleOnce(false);
        for (let i = 0; i < iterations; i += 1) {
          await sampleOnce(true);
        }
        addTimingStats(samples, "textureMs", "textureMs");
        addTimingStats(samples, "createTextureMs", "createTextureMs");
        addTimingStats(samples, "writeTextureMs", "writeTextureMs");
        addTimingStats(samples, "waitMs", "waitMs");
        addTimingStats(samples, "createViewMs", "createViewMs");
        addTimingStats(samples, "propertyQueryMs", "propertyQueryMs");
        addTimingStats(samples, "destroyMs", "destroyMs");
        result.metrics.textureIterations = iterations;
        result.metrics.textureWarmupIterations = 1;
        result.metrics.destroyed = true;
      }

      async function runPipelineCompileStress(device, useAsync) {
        const iterations = useAsync ? runIterations.asyncPipeline : runIterations.pipeline;
        const t0 = nowMs();
        for (let i = 0; i < iterations; i += 1) {
          const module = device.createShaderModule({
            code: `
              @compute @workgroup_size(1)
              fn main() {
                let marker : u32 = ${i}u;
                _ = marker;
              }
            `,
          });
          if (useAsync) {
            if (typeof device.createComputePipelineAsync !== "function") {
              throw new Error("createComputePipelineAsync is unavailable");
            }
            await device.createComputePipelineAsync({
              layout: "auto",
              compute: { module, entryPoint: "main" },
            });
          } else {
            device.createComputePipeline({
              layout: "auto",
              compute: { module, entryPoint: "main" },
            });
          }
        }
        const t1 = nowMs();
        result.metrics.iterations = iterations;
        result.metrics.msPerPipeline = (t1 - t0) / iterations;
      }

      async function runSurfacePresent(device) {
        let stage = "init";
        try {
        const iterations = runIterations.render;
        const canvas = new OffscreenCanvas(128, 128);
        stage = "getContext";
        const context = getCanvasContext(canvas);
        if (!context) {
          throw new Error("OffscreenCanvas.getContext('webgpu') returned null");
        }
        const format = gpu.getPreferredCanvasFormat();
        stage = "configure";
        context.configure({ device, format, alphaMode: "opaque" });

        const t0 = nowMs();
        for (let i = 0; i < iterations; i += 1) {
          stage = `frame:${i}`;
          const encoder = device.createCommandEncoder();
          const pass = encoder.beginRenderPass({
            colorAttachments: [
              {
                view: context.getCurrentTexture().createView(),
                clearValue: { r: 0.2, g: 0.2, b: 0.2, a: 1 },
                loadOp: "clear",
                storeOp: "store",
              },
            ],
          });
          pass.end();
          device.queue.submit([encoder.finish()]);
        }
        const submitEnd = nowMs();
        await device.queue.onSubmittedWorkDone();
        const t1 = nowMs();
        result.metrics.iterations = iterations;
        result.metrics.encodeSubmitMs = submitEnd - t0;
        result.metrics.waitMs = t1 - submitEnd;
        result.metrics.usPerFrame = ((t1 - t0) * 1000) / iterations;
        } catch (error) {
          throw new Error(`${stage}: ${String(error)}`);
        }
      }

      async function runCanvasReconfigureResize(device) {
        let stage = "init";
        try {
        const sizes = [64, 96, 128, 160, 192, 256];
        const canvas = new OffscreenCanvas(sizes[0], sizes[0]);
        stage = "getContext";
        const context = getCanvasContext(canvas);
        if (!context) {
          throw new Error("OffscreenCanvas.getContext('webgpu') returned null");
        }
        const format = gpu.getPreferredCanvasFormat();
        const t0 = nowMs();
        for (const size of sizes) {
          stage = `resize:${size}`;
          canvas.width = size;
          canvas.height = size;
          context.configure({ device, format, alphaMode: "opaque" });
          const encoder = device.createCommandEncoder();
          const pass = encoder.beginRenderPass({
            colorAttachments: [
              {
                view: context.getCurrentTexture().createView(),
                clearValue: { r: 0, g: 0, b: 0, a: 1 },
                loadOp: "clear",
                storeOp: "store",
              },
            ],
          });
          pass.end();
          device.queue.submit([encoder.finish()]);
        }
        await device.queue.onSubmittedWorkDone();
        const t1 = nowMs();
        result.metrics.resizeCount = sizes.length;
        result.metrics.totalMs = t1 - t0;
        result.metrics.msPerResize = result.metrics.totalMs / sizes.length;
        } catch (error) {
          throw new Error(`${stage}: ${String(error)}`);
        }
      }

      async function runQueueSubmitBurst(device) {
        const iterations = runIterations.workflow;
        const coldEmptySubmitCount = 1;
        const warmupSubmitCount = 1;

        const coldEmptyStart = nowMs();
        for (let i = 0; i < coldEmptySubmitCount; i += 1) {
          device.queue.submit([device.createCommandEncoder().finish()]);
        }
        const coldEmptySubmitEnd = nowMs();
        await device.queue.onSubmittedWorkDone();
        const coldEmptyEnd = nowMs();

        const pipelineCreateStart = nowMs();
        const module = device.createShaderModule({
          code: `
            @compute @workgroup_size(1)
            fn main() {}
          `,
        });
        const pipeline = device.createComputePipeline({
          layout: "auto",
          compute: { module, entryPoint: "main" },
        });
        const pipelineCreateCallEnd = nowMs();
        await device.queue.onSubmittedWorkDone();
        const pipelineReadyEnd = nowMs();

        const createCommandBuffer = () => {
          const encoder = device.createCommandEncoder();
          const pass = encoder.beginComputePass();
          pass.setPipeline(pipeline);
          pass.dispatchWorkgroups(1);
          pass.end();
          return encoder.finish();
        };

        const warmupStart = nowMs();
        for (let i = 0; i < warmupSubmitCount; i += 1) {
          device.queue.submit([createCommandBuffer()]);
        }
        const warmupSubmitEnd = nowMs();
        await device.queue.onSubmittedWorkDone();
        const warmupEnd = nowMs();
        const warmupMs = warmupEnd - warmupStart;

        const t0 = nowMs();
        for (let i = 0; i < iterations; i += 1) {
          device.queue.submit([createCommandBuffer()]);
        }
        const submitEnd = nowMs();
        await device.queue.onSubmittedWorkDone();
        const t1 = nowMs();
        result.metrics.coldEmptySubmitCount = coldEmptySubmitCount;
        result.metrics.coldEmptyMs = coldEmptyEnd - coldEmptyStart;
        result.metrics.coldEmptyEncodeSubmitMs = coldEmptySubmitEnd - coldEmptyStart;
        result.metrics.coldEmptyWaitMs = coldEmptyEnd - coldEmptySubmitEnd;
        result.metrics.pipelineReadyMs = pipelineReadyEnd - pipelineCreateStart;
        result.metrics.pipelineCreateCallMs = pipelineCreateCallEnd - pipelineCreateStart;
        result.metrics.pipelineReadyWaitMs = pipelineReadyEnd - pipelineCreateCallEnd;
        result.metrics.warmupSubmitCount = warmupSubmitCount;
        result.metrics.warmupMs = warmupMs;
        result.metrics.warmupEncodeSubmitMs = warmupSubmitEnd - warmupStart;
        result.metrics.warmupWaitMs = warmupEnd - warmupSubmitEnd;
        result.metrics.submitCount = iterations;
        result.metrics.totalMs = t1 - t0;
        result.metrics.encodeSubmitMs = submitEnd - t0;
        result.metrics.waitMs = t1 - submitEnd;
        result.metrics.usPerSubmit = ((t1 - t0) * 1000) / iterations;
      }

      function readText(selector) {
        if (typeof selector !== "string" || selector.length === 0) {
          return "";
        }
        return document.querySelector(selector)?.textContent?.trim() ?? "";
      }

      function nextFrame() {
        return new Promise((resolve, reject) => {
          let settled = false;
          const timeout = setTimeout(() => {
            if (settled) return;
            settled = true;
            reject(new Error("fawn visual requestAnimationFrame stalled"));
          }, 2000);
          requestAnimationFrame((timestamp) => {
            if (settled) return;
            settled = true;
            clearTimeout(timeout);
            resolve(timestamp);
          });
        });
      }

      async function waitForVisualFrameTelemetry() {
        const deadline = nowMs() + 10000;
        const statusSelector = scenarioConfig.statusSelector ?? "#status";
        const frameSelector = scenarioConfig.frameSelector ?? "#frame";
        while (nowMs() < deadline) {
          const statusText = readText(statusSelector);
          const frameText = readText(frameSelector);
          if (/^error:/i.test(statusText)) {
            throw new Error(statusText);
          }
          if (frameText && frameText !== "--" && frameText.includes("fps")) {
            return { statusText, frameText };
          }
          await nextFrame();
        }
        throw new Error("fawn visual page did not emit frame telemetry");
      }

      async function runFawnVisualResource() {
        const firstTelemetry = await waitForVisualFrameTelemetry();
        const frameTarget = Math.max(1, runIterations.workflow);
        const samples = [];
        let previous = await nextFrame();
        for (let i = 0; i < frameTarget; i += 1) {
          const current = await nextFrame();
          samples.push(Math.max(0.001, current - previous));
          previous = current;
        }
        const sorted = [...samples].sort((a, b) => a - b);
        const sum = samples.reduce((acc, value) => acc + value, 0);
        const avgFrameMs = sum / samples.length;
        const p95Index = Math.min(sorted.length - 1, Math.ceil(sorted.length * 0.95) - 1);
        result.metrics.resourcePath = scenarioConfig.resourcePath ?? "";
        result.metrics.resourceSha256 = scenarioConfig.resourceSha256 ?? "";
        result.metrics.statusText = readText(scenarioConfig.statusSelector ?? "#status") || firstTelemetry.statusText;
        result.metrics.frameText = readText(scenarioConfig.frameSelector ?? "#frame") || firstTelemetry.frameText;
        result.metrics.workloadText = readText(scenarioConfig.workloadSelector ?? "#workload");
        result.metrics.adapterText = readText(scenarioConfig.adapterSelector ?? "#adapter");
        result.metrics.frameCount = samples.length;
        result.metrics.avgFrameMs = avgFrameMs;
        result.metrics.minFrameMs = sorted[0];
        result.metrics.maxFrameMs = sorted[sorted.length - 1];
        result.metrics.p95FrameMs = sorted[p95Index];
        result.metrics.avgFps = 1000 / Math.max(avgFrameMs, 0.001);
      }

      const scenarioStart = nowMs();
      try {
        const deviceSetup =
          scenarioTemplate === "fawn_visual_resource" ? null : await initDevice();
        const device = deviceSetup?.device ?? null;
        if (deviceSetup && scenarioTemplate === "startup_adapter_device") {
          result.metrics.adapterRequestMs = deviceSetup.adapterRequestMs;
          result.metrics.deviceRequestMs = deviceSetup.deviceRequestMs;
        }

        if (scenarioTemplate === "write_buffer_upload") {
          await runWriteBuffer(device);
        } else if (
          scenarioTemplate === "compute_dispatch_basic" ||
          scenarioTemplate === "compute_dispatch_direct_basic" ||
          scenarioTemplate === "compute_dispatch_indirect_basic"
        ) {
          await runComputeDispatch(device, runIterations.dispatch);
        } else if (scenarioTemplate === "render_triangle_readback") {
          await runRenderTriangleReadback(device);
        } else if (scenarioTemplate === "render_bundle_replay") {
          await runRenderBundleReplay(device);
        } else if (scenarioTemplate === "texture_sample_raster") {
          await runTextureSampleRaster(device);
        } else if (scenarioTemplate === "texture_write_query_destroy") {
          await runTextureWriteQueryDestroy(device);
        } else if (scenarioTemplate === "pipeline_compile_stress") {
          await runPipelineCompileStress(device, false);
        } else if (scenarioTemplate === "async_pipeline_diagnostics") {
          await runPipelineCompileStress(device, true);
        } else if (scenarioTemplate === "surface_present_basic") {
          await runSurfacePresent(device);
        } else if (scenarioTemplate === "startup_adapter_device") {
          result.metrics.startupMs = nowMs() - scenarioStart;
          result.metrics.adapterAvailable = true;
        } else if (scenarioTemplate === "canvas_reconfigure_resize") {
          await runCanvasReconfigureResize(device);
        } else if (scenarioTemplate === "queue_submit_burst") {
          await runQueueSubmitBurst(device);
        } else if (scenarioTemplate === "async_pipeline_burst") {
          await runPipelineCompileStress(device, true);
        } else if (scenarioTemplate === "fawn_visual_resource") {
          await runFawnVisualResource();
        } else if (scenarioTemplate === "generic_webgpu_api") {
          await runComputeDispatch(device, Math.max(1, Math.floor(runIterations.dispatch / 4)));
        } else {
          result.status = "unsupported";
          result.statusCode = "scenario_template_unknown";
          result.error = `unknown scenario template: ${scenarioTemplate}`;
          result.metrics.elapsedMs = nowMs() - scenarioStart;
          return result;
        }

        result.status = "ok";
        result.statusCode = "ok";
      } catch (error) {
        const errorText = String(error);
        if (
          errorText.includes("navigator.gpu unavailable") ||
          errorText.includes("requestAdapter returned null") ||
          errorText.includes("createComputePipelineAsync is unavailable") ||
          errorText.includes("OffscreenCanvas.getContext('webgpu') returned null")
        ) {
          result.status = "unsupported";
          if (errorText.includes("requestAdapter returned null")) {
            result.statusCode = "adapter_null";
          } else if (errorText.includes("createComputePipelineAsync is unavailable")) {
            result.statusCode = "api_unsupported";
          } else {
            result.statusCode = "webgpu_unavailable";
          }
        } else {
          result.status = "fail";
          result.statusCode = "scenario_runtime_error";
        }
        result.error = errorText;
      }

      result.metrics.elapsedMs = nowMs() - scenarioStart;
      return result;
    },
    {
      scenarioTemplate: template,
      runIterations: iterations,
      ...browserSurfaceArgs,
      scenarioConfig,
      sourceKernelSamples,
      sourceKernelWarmupSamples,
      sourceKernelSubmitPolicy,
    },
  );
  if (template !== "fawn_visual_resource") {
    return evaluation;
  }

  let controllerTimeout;
  try {
    return await Promise.race([
      evaluation,
      new Promise((resolve) => {
        controllerTimeout = setTimeout(() => {
          resolve({
            apiSurface: browserSurfaceArgs.apiSurface,
            status: "fail",
            statusCode: "scenario_runtime_error",
            error: "fawn visual scenario exceeded the controller deadline",
            metrics: {
              controllerDeadlineMs: VISUAL_SCENARIO_CONTROLLER_DEADLINE_MS,
            },
          });
        }, VISUAL_SCENARIO_CONTROLLER_DEADLINE_MS);
      }),
    ]);
  } finally {
    clearTimeout(controllerTimeout);
  }
}

function makeModeRowResult(status, statusCode, error = null, metrics = {}) {
  return {
    status,
    statusCode,
    error,
    metrics,
    measuredAt: new Date().toISOString(),
  };
}

function classifyModeFailure(error, stage) {
  const message = String(error);
  const lower = message.toLowerCase();
  const isSandbox =
    lower.includes("operation not permitted") ||
    lower.includes("eperm") ||
    lower.includes("sandbox");
  const isLaunchSurface =
    lower.includes("missing x server") ||
    lower.includes("can't open display") ||
    lower.includes("$display") ||
    lower.includes("ozone_platform_x11");
  const isAdapterNull = lower.includes("requestadapter returned null");
  const isWebgpuUnavailable = lower.includes("navigator.gpu unavailable");

  if (isSandbox) {
    return {
      stage,
      status: "unsupported",
      statusCode: "sandbox_constraint",
      error: message,
    };
  }
  if (isLaunchSurface) {
    return {
      stage,
      status: "unsupported",
      statusCode: "launch_surface_unavailable",
      error: message,
    };
  }
  if (isAdapterNull) {
    return {
      stage,
      status: "unsupported",
      statusCode: "adapter_null",
      error: message,
    };
  }
  if (isWebgpuUnavailable) {
    return {
      stage,
      status: "unsupported",
      statusCode: "webgpu_unavailable",
      error: message,
    };
  }

  return {
    stage,
    status: "fail",
    statusCode: stage === "launch" ? "browser_launch_failed" : "mode_setup_failed",
    error: message,
  };
}

function applyModeWideFailure(l1Rows, l2Rows, rowResultsById, workflowResultsById, failure) {
  for (const row of l1Rows) {
    if (row.layerTarget === "l0_only") {
      rowResultsById.set(row.sourceWorkloadId, makeModeRowResult("l0_only", "l0_only"));
      continue;
    }
    rowResultsById.set(
      row.sourceWorkloadId,
      makeModeRowResult(failure.status, failure.statusCode, failure.error),
    );
  }
  for (const workflow of l2Rows) {
    workflowResultsById.set(
      workflow.id,
      makeModeRowResult(failure.status, failure.statusCode, failure.error),
    );
  }
}

function nativeMetalTraceBaseEvidence(args, selectedRuntime) {
  const config = args.nativeMetalTraceConfig;
  const requested = args.nativeMetalTrace;
  const enabled = requested && selectedRuntime === "doe";
  return {
    requested,
    enabled,
    status: enabled ? "pending" : (requested ? "not_applicable" : "disabled"),
    reason: enabled ? "" : (requested ? "selected_runtime_not_doe" : "not_requested"),
    traceId: config.traceId,
    traceKind: NATIVE_METAL_TRACE_KIND,
    configPath: args.nativeMetalTraceConfigPath,
    configSha256: fileHashHex(args.nativeMetalTraceConfigPath),
    environmentVariable: config.environmentVariable,
    evidenceClass: config.evidenceClass,
    timingsPerturbed: enabled,
    tracePath: "",
    traceSha256: null,
    byteCount: 0,
    rowCount: 0,
    malformedRowCount: 0,
    totals: {},
    errors: [],
  };
}

function safeTraceFileComponent(value) {
  return String(value)
    .replace(/[^a-zA-Z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 120) || "run";
}

function prepareNativeMetalTrace(args, selectedRuntime, traceRunId) {
  const evidence = nativeMetalTraceBaseEvidence(args, selectedRuntime);
  if (!evidence.enabled) return evidence;
  const traceDir = resolve(dirname(args.outPath), "native-metal-traces");
  const tracePath = resolve(traceDir, `${safeTraceFileComponent(traceRunId)}.jsonl`);
  mkdirSync(traceDir, { recursive: true });
  writeFileSync(tracePath, "", "utf8");
  evidence.tracePath = tracePath;
  return evidence;
}

function nativeMetalTraceLaunchEnvironment(evidence) {
  if (!evidence.enabled) return undefined;
  const inherited = Object.fromEntries(
    Object.entries(process.env).filter(([, value]) => typeof value === "string"),
  );
  return {
    ...inherited,
    [evidence.environmentVariable]: evidence.tracePath,
  };
}

function finalizeNativeMetalTrace(evidence) {
  if (!evidence.enabled) return evidence;
  if (!existsSync(evidence.tracePath)) {
    return {
      ...evidence,
      status: "fail",
      errors: ["native Metal trace file was not produced"],
    };
  }

  const bytes = readFileSync(evidence.tracePath);
  const lines = bytes
    .toString("utf8")
    .split(/\r?\n/)
    .filter((line) => line.trim().length > 0);
  const numericFields = [
    "submissionCount",
    "sourceCommandBufferCount",
    "recordedCommandCount",
    "nativeCommandBufferCount",
    "commandBufferCreateNs",
    "commandEncodeNs",
    "commandCommitNs",
    "waitCompletedNs",
    "deferredCopyNs",
    "deferredResolveNs",
  ];
  const totals = Object.fromEntries(numericFields.map((field) => [field, 0]));
  const errors = [];
  let validRowCount = 0;

  for (const [index, line] of lines.entries()) {
    let row;
    try {
      row = JSON.parse(line);
    } catch {
      errors.push(`row ${index + 1} is not valid JSON`);
      continue;
    }
    if (
      row.schemaVersion !== 1 ||
      row.traceKind !== NATIVE_METAL_TRACE_KIND ||
      row.sequence !== index + 1 ||
      typeof row.directReadback !== "boolean"
    ) {
      errors.push(`row ${index + 1} has an invalid trace envelope`);
      continue;
    }
    const invalidField = numericFields.find(
      (field) => !Number.isSafeInteger(row[field]) || row[field] < 0,
    );
    if (invalidField) {
      errors.push(`row ${index + 1} has invalid ${invalidField}`);
      continue;
    }
    for (const field of numericFields) totals[field] += row[field];
    validRowCount += 1;
  }
  if (lines.length === 0) errors.push("native Metal trace contains no flush rows");
  if (validRowCount > 0 && totals.submissionCount === 0) {
    errors.push("native Metal trace contains no submitted command buffers");
  }

  return {
    ...evidence,
    status: errors.length === 0 ? "ok" : "fail",
    reason: "",
    traceSha256: createHash(HASH_ALGORITHM).update(bytes).digest("hex"),
    byteCount: bytes.length,
    rowCount: validRowCount,
    malformedRowCount: lines.length - validRowCount,
    totals,
    errors,
  };
}

async function runMode(
  chromium,
  mode,
  args,
  pageTarget,
  l1Rows,
  l2Rows,
  chromePath,
  scheduledSourceKernelSamples,
  traceRunId,
) {
  const selection = runtimeSelectionResolution(mode, args);
  const nativeMetalTrace = prepareNativeMetalTrace(
    args,
    selection.selectedRuntime,
    traceRunId,
  );
  const launchArgs = [
    ...baseLaunchArgs(pageTarget.port),
    ...args.chromeArgs,
    ...runtimeArgs(selection.selectedRuntime, args.doeLibPath),
  ];
  const startMs = Date.now();
  const rowResultsById = new Map();
  const workflowResultsById = new Map();
  const runtimeEvidence = {
    modeRequested: mode,
    runtimeSelection: buildRuntimeSelection(mode, args, chromePath, launchArgs),
    apiSurface: args.apiSurface,
    pageTargetKind: pageTarget.kind,
    pageTargetPort: Number.isInteger(pageTarget.port) ? pageTarget.port : null,
    pageTargetWarning: pageTarget.warning ?? null,
    browserVersion: "",
    userAgent: "",
    failureStage: null,
    failureStatusCode: null,
    activeRuntimeProof: null,
    nativeMetalTrace,
  };
  let runtimeProbe = {
    webgpuAvailable: false,
    adapterAvailable: false,
    adapterInfo: null,
    adapterIdentity: adapterIdentityFromProbe(null),
    featureCount: 0,
    errors: [],
  };
  let browser;

  try {
    browser = await chromium.launch({
      executablePath: chromePath,
      headless: args.headless,
      args: launchArgs,
      timeout: 120000,
      env: nativeMetalTraceLaunchEnvironment(nativeMetalTrace),
    });
  } catch (error) {
    const failure = classifyModeFailure(error, "launch");
    runtimeEvidence.failureStage = failure.stage;
    runtimeEvidence.failureStatusCode = failure.statusCode;
    runtimeEvidence.nativeMetalTrace = finalizeNativeMetalTrace(nativeMetalTrace);
    applyModeWideFailure(l1Rows, l2Rows, rowResultsById, workflowResultsById, failure);
    return {
      mode,
      chromePath,
      launchArgs,
      elapsedMs: Date.now() - startMs,
      shaderCompilerIdentity: shaderCompilerIdentity(mode, args, chromePath),
      runtimeProbe,
      runtimeEvidence,
      modeFailure: failure,
      rowResultsById,
      workflowResultsById,
    };
  }

  try {
    const context = await browser.newContext();
    const page = await context.newPage();
    await page.goto(pageTarget.url, { waitUntil: "domcontentloaded", timeout: 120000 });
    const browserSurfaceArgs = {
      apiSurface: args.apiSurface,
      browserModuleUrl: browserSurfaceModuleUrl(pageTarget.url),
      powerPreference: args.powerPreference,
    };
    runtimeEvidence.browserVersion = browser.version();
    runtimeEvidence.userAgent = await page.evaluate(() => navigator.userAgent);
    runtimeProbe = await probeRuntime(page, browserSurfaceArgs);
    runtimeProbe.adapterIdentity = adapterIdentityFromProbe(runtimeProbe);
    runtimeEvidence.activeRuntimeProof = activeRuntimeProof(
      selection.selectedRuntime,
      runtimeProbe,
    );
    if (!runtimeEvidence.activeRuntimeProof.matched) {
      throw new Error(
        `active WebGPU runtime proof mismatch: requested ${selection.selectedRuntime}, `
          + `observed vendor=${runtimeEvidence.activeRuntimeProof.observed.vendor || "<empty>"} `
          + `architecture=${runtimeEvidence.activeRuntimeProof.observed.architecture || "<empty>"}`,
      );
    }

    for (const row of l1Rows) {
      if (row.layerTarget === "l0_only") {
        rowResultsById.set(row.sourceWorkloadId, makeModeRowResult("l0_only", "l0_only"));
        continue;
      }
      await page.goto(pageTarget.url, { waitUntil: "load", timeout: 120000 });
      const scenarioResult = await runScenario(
        page,
        row.scenarioTemplate,
        args.iterations,
        browserSurfaceArgs,
        browserProjectionScenarioConfig(row),
        scheduledSourceKernelSamples,
        args.sourceKernelWarmupSamples,
        args.sourceKernelSubmitPolicy,
      );
      rowResultsById.set(
        row.sourceWorkloadId,
        makeModeRowResult(
          scenarioResult.status,
          scenarioResult.statusCode,
          scenarioResult.error,
          scenarioResult.metrics,
        ),
      );
    }

    for (const workflow of l2Rows) {
      if (workflow.resourcePath && pageTarget.kind !== "server") {
        workflowResultsById.set(
          workflow.id,
          makeModeRowResult(
            "unsupported",
            "mode_execution_unavailable",
            "resource workflows require the local browser benchmark server",
          ),
        );
        continue;
      }
      const workflowUrl = workflow.resourcePath
        ? resourceUrl(pageTarget.url, workflow.resourcePath)
        : pageTarget.url;
      await page.goto(workflowUrl, { waitUntil: "load", timeout: 120000 });
      const scenarioResult = await runScenario(
        page,
        workflow.scenarioTemplate,
        args.iterations,
        browserSurfaceArgs,
        workflow,
        scheduledSourceKernelSamples,
        args.sourceKernelWarmupSamples,
        args.sourceKernelSubmitPolicy,
      );
      workflowResultsById.set(
        workflow.id,
        makeModeRowResult(
          scenarioResult.status,
          scenarioResult.statusCode,
          scenarioResult.error,
          scenarioResult.metrics,
        ),
      );
    }

    return {
      mode,
      chromePath,
      launchArgs,
      elapsedMs: Date.now() - startMs,
      shaderCompilerIdentity: shaderCompilerIdentity(mode, args, chromePath),
      runtimeProbe,
      runtimeEvidence,
      modeFailure: null,
      rowResultsById,
      workflowResultsById,
    };
  } catch (error) {
    const failure = classifyModeFailure(error, "setup");
    runtimeEvidence.failureStage = failure.stage;
    runtimeEvidence.failureStatusCode = failure.statusCode;
    applyModeWideFailure(l1Rows, l2Rows, rowResultsById, workflowResultsById, failure);
    runtimeProbe.errors = [...runtimeProbe.errors, failure.error];
    runtimeProbe.adapterIdentity = adapterIdentityFromProbe(runtimeProbe);
    return {
      mode,
      chromePath,
      launchArgs,
      elapsedMs: Date.now() - startMs,
      shaderCompilerIdentity: shaderCompilerIdentity(mode, args, chromePath),
      runtimeProbe,
      runtimeEvidence,
      modeFailure: failure,
      rowResultsById,
      workflowResultsById,
    };
  } finally {
    try {
      await browser.close();
    } finally {
      runtimeEvidence.nativeMetalTrace = finalizeNativeMetalTrace(nativeMetalTrace);
    }
  }
}

function summarizeStatusForRows(rows, modes, kind) {
  const byMode = {};
  for (const mode of modes) {
    byMode[mode] = {
      ok: 0,
      fail: 0,
      unsupported: 0,
      l0_only: 0,
      missing: 0,
      requiredFailures: 0,
      kind,
    };
  }

  for (const row of rows) {
    for (const mode of modes) {
      const result = row.runtimes[mode];
      if (!result) {
        byMode[mode].missing += 1;
        continue;
      }
      const status = result.status;
      if (status === "ok") byMode[mode].ok += 1;
      else if (status === "fail") byMode[mode].fail += 1;
      else if (status === "unsupported") byMode[mode].unsupported += 1;
      else if (status === "l0_only") byMode[mode].l0_only += 1;
      else byMode[mode].missing += 1;

      const required =
        kind === "l1"
          ? row.requiredStatus === "ok"
          : row.requiredStatus === "ok";
      if (required && status !== "ok") {
        byMode[mode].requiredFailures += 1;
      }
    }
  }

  return byMode;
}

function mergeModeSummary(l1Summary, l2Summary, modes) {
  const perMode = {};
  for (const mode of modes) {
    perMode[mode] = {
      l1: l1Summary[mode],
      l2: l2Summary[mode],
      requiredFailures: l1Summary[mode].requiredFailures + l2Summary[mode].requiredFailures,
    };
  }
  let overallRequiredFailures = 0;
  for (const mode of modes) {
    overallRequiredFailures += perMode[mode].requiredFailures;
  }
  return { perMode, overallRequiredFailures };
}

function hasRequiredFailures(summary) {
  return summary.overallRequiredFailures > 0;
}

function isSlicedSourceKernelRow(row, minDispatchRepeat) {
  if (![
    COMPUTE_PROJECTION_SOURCE_KERNEL,
    COMPUTE_PROJECTION_SOURCE_KERNEL_ORACLE,
  ].includes(row?.browserWorkload?.computeProjection)) {
    return false;
  }
  return (row.browserWorkload.dispatchRepeat ?? 0) >= minDispatchRepeat;
}

function sourceKernelSamplesForSlice(totalSamples, sliceIndex, sliceCount) {
  const base = Math.floor(totalSamples / sliceCount);
  const remainder = totalSamples % sliceCount;
  return base + (sliceIndex < remainder ? 1 : 0);
}

function buildModeSchedule(
  modes,
  l1Rows,
  l2Rows,
  modeSchedule,
  modeScheduleRepetitions,
  sourceKernelSamples,
  sourceKernelScheduleSlices,
  sourceKernelScheduleSliceMinDispatchRepeat,
) {
  if (modeSchedule === "grouped") {
    return modes.map((mode) => ({
      mode,
      l1Rows,
      l2Rows,
      scheduleUnit: "all",
      scheduleLayer: "all",
      sourceKernelSamples,
    }));
  }

  const entries = [];
  const orderedL1Rows = [...l1Rows].sort((left, right) => {
    const priority = { strict: 0, component: 1, none: 2 };
    const leftPriority = priority[left.comparabilityExpectation] ?? 3;
    const rightPriority = priority[right.comparabilityExpectation] ?? 3;
    if (leftPriority !== rightPriority) return leftPriority - rightPriority;
    return String(left.sourceWorkloadId).localeCompare(String(right.sourceWorkloadId));
  });
  const rowModeOrders =
    modeSchedule === "paired-balanced" ? [modes, [...modes].reverse()] : [modes];
  for (const row of orderedL1Rows) {
    if (row.layerTarget === "l0_only") {
      for (const mode of modes) {
        row.runtimes[mode] = makeModeRowResult("l0_only", "l0_only");
      }
      continue;
    }
    const scheduleSlices = isSlicedSourceKernelRow(
      row,
      sourceKernelScheduleSliceMinDispatchRepeat,
    ) ? sourceKernelScheduleSlices : 1;
    for (let repetitionIndex = 0; repetitionIndex < modeScheduleRepetitions; repetitionIndex += 1) {
      for (let sliceIndex = 0; sliceIndex < scheduleSlices; sliceIndex += 1) {
        const sliceSamples = sourceKernelSamplesForSlice(
          sourceKernelSamples,
          sliceIndex,
          scheduleSlices,
        );
        for (let passIndex = 0; passIndex < rowModeOrders.length; passIndex += 1) {
          for (const mode of rowModeOrders[passIndex]) {
            entries.push({
              mode,
              l1Rows: [row],
              l2Rows: [],
              scheduleUnit: row.sourceWorkloadId,
              scheduleLayer: "l1",
              schedulePass: (repetitionIndex * rowModeOrders.length) + passIndex + 1,
              scheduleRepetition: repetitionIndex + 1,
              scheduleSlice: sliceIndex + 1,
              scheduleSlices,
              sourceKernelSamples: sliceSamples,
            });
          }
        }
      }
    }
  }

  for (const workflow of l2Rows) {
    for (let repetitionIndex = 0; repetitionIndex < modeScheduleRepetitions; repetitionIndex += 1) {
      for (let passIndex = 0; passIndex < rowModeOrders.length; passIndex += 1) {
        for (const mode of rowModeOrders[passIndex]) {
          entries.push({
            mode,
            l1Rows: [],
            l2Rows: [workflow],
            scheduleUnit: workflow.id,
            scheduleLayer: "l2",
            schedulePass: (repetitionIndex * rowModeOrders.length) + passIndex + 1,
            scheduleRepetition: repetitionIndex + 1,
            sourceKernelSamples,
          });
        }
      }
    }
  }

  return entries;
}

function requiredFailureCount(rows, mode) {
  return rows.filter((row) => {
    if (row.requiredStatus !== "ok") {
      return false;
    }
    const status = row.runtimes[mode]?.status;
    return status !== "ok";
  }).length;
}

function mergeMetricValues(left, right, leftWeight, rightWeight) {
  if (typeof left === "number" && Number.isFinite(left) && typeof right === "number" && Number.isFinite(right)) {
    return ((left * leftWeight) + (right * rightWeight)) / (leftWeight + rightWeight);
  }
  if (left === right) {
    return left;
  }
  return right ?? left;
}

const MERGED_SUM_METRICS = new Set([
  "sourceKernelSampleCount",
  "sourceKernelWarmupSampleCount",
  "sourceKernelWarmupDispatches",
  "sourceKernelWarmupSubmits",
  "totalWarmupDispatches",
  "totalWarmupSubmits",
  "totalDispatches",
  "totalSubmits",
]);
const MERGED_CONCAT_METRICS = new Set([
  "dispatchElapsedMsSamples",
  "encodeSubmitMsSamples",
  "waitMsSamples",
  "usPerOpSamples",
]);

function isOrderBalancedTimingMetric(key) {
  if (/(Avg|P10|P50|P95|P99|Samples|Count)$/.test(key)) {
    return false;
  }
  return key.startsWith("usPer") || key.endsWith("Ms") || key.endsWith("Fps");
}

function orderBalancedSamplesFor(metrics, key) {
  const samples = metrics?.orderBalancedMetricSamples?.[key];
  if (Array.isArray(samples)) {
    return samples.filter((value) => typeof value === "number" && Number.isFinite(value));
  }
  const value = metrics?.[key];
  return typeof value === "number" && Number.isFinite(value) ? [value] : [];
}

function percentile(sortedValues, fraction) {
  if (sortedValues.length === 0) {
    return 0;
  }
  const index = Math.min(
    sortedValues.length - 1,
    Math.max(0, Math.ceil(sortedValues.length * fraction) - 1),
  );
  return sortedValues[index];
}

function summarizeSampleValues(values) {
  const numeric = values
    .filter((value) => Number.isFinite(value))
    .sort((left, right) => left - right);
  if (numeric.length === 0) {
    return null;
  }
  const sum = numeric.reduce((acc, value) => acc + value, 0);
  return {
    avg: sum / numeric.length,
    p10: percentile(numeric, 0.10),
    p50: percentile(numeric, 0.50),
    p95: percentile(numeric, 0.95),
    p99: percentile(numeric, 0.99),
  };
}

function averageSampleGroupSummaries(groups) {
  const summaries = groups
    .filter((group) => Array.isArray(group) && group.length > 0)
    .map((group) => summarizeSampleValues(group))
    .filter((summary) => summary !== null);
  if (summaries.length === 0 || summaries.length !== groups.length) {
    return null;
  }
  const totals = { avg: 0, p10: 0, p50: 0, p95: 0, p99: 0 };
  for (const summary of summaries) {
    totals.avg += summary.avg;
    totals.p10 += summary.p10;
    totals.p50 += summary.p50;
    totals.p95 += summary.p95;
    totals.p99 += summary.p99;
  }
  return {
    avg: totals.avg / summaries.length,
    p10: totals.p10 / summaries.length,
    p50: totals.p50 / summaries.length,
    p95: totals.p95 / summaries.length,
    p99: totals.p99 / summaries.length,
  };
}

function applyMergedSampleStats(metrics, sampleKey, metricName) {
  const groups = metrics[`${sampleKey}Groups`];
  const summary = Array.isArray(groups) && groups.length > 0
    ? averageSampleGroupSummaries(groups)
    : summarizeSampleValues(metrics[sampleKey] ?? []);
  if (!summary) {
    return;
  }
  metrics[metricName] = summary.p50;
  metrics[`${metricName}Avg`] = summary.avg;
  metrics[`${metricName}P10`] = summary.p10;
  metrics[`${metricName}P50`] = summary.p50;
  metrics[`${metricName}P95`] = summary.p95;
  metrics[`${metricName}P99`] = summary.p99;
}

function applyMergedSourceKernelStats(metrics) {
  applyMergedSampleStats(metrics, "dispatchElapsedMsSamples", "dispatchElapsedMs");
  applyMergedSampleStats(metrics, "encodeSubmitMsSamples", "encodeSubmitMs");
  applyMergedSampleStats(metrics, "waitMsSamples", "waitMs");
  applyMergedSampleStats(metrics, "usPerOpSamples", "usPerOp");
}

function sampleGroupsFor(metrics, sampleKey) {
  const groups = metrics?.[`${sampleKey}Groups`];
  if (Array.isArray(groups)) {
    return groups
      .filter((group) => Array.isArray(group))
      .map((group) => [...group]);
  }
  const samples = metrics?.[sampleKey];
  return Array.isArray(samples) ? [[...samples]] : [];
}

function mergeMetrics(leftMetrics, rightMetrics) {
  const merged = {};
  const leftWeight = leftMetrics?.orderBalancedSampleCount ?? 1;
  const rightWeight = rightMetrics?.orderBalancedSampleCount ?? 1;
  const keys = new Set([
    ...Object.keys(leftMetrics ?? {}),
    ...Object.keys(rightMetrics ?? {}),
  ]);
  for (const key of keys) {
    if (key === "orderBalancedSampleCount" || key === "orderBalancedMetricSamples" || MERGED_SUM_METRICS.has(key) || MERGED_CONCAT_METRICS.has(key)) {
      continue;
    }
    merged[key] = mergeMetricValues(
      leftMetrics?.[key],
      rightMetrics?.[key],
      leftWeight,
      rightWeight,
    );
  }
  merged.orderBalancedSampleCount =
    (leftMetrics?.orderBalancedSampleCount ?? 1) +
    (rightMetrics?.orderBalancedSampleCount ?? 1);
  for (const key of MERGED_SUM_METRICS) {
    if (key in (leftMetrics ?? {}) || key in (rightMetrics ?? {})) {
      merged[key] = (leftMetrics?.[key] ?? 0) + (rightMetrics?.[key] ?? 0);
    }
  }
  for (const key of MERGED_CONCAT_METRICS) {
    if (key in (leftMetrics ?? {}) || key in (rightMetrics ?? {})) {
      merged[key] = [
        ...(Array.isArray(leftMetrics?.[key]) ? leftMetrics[key] : []),
        ...(Array.isArray(rightMetrics?.[key]) ? rightMetrics[key] : []),
      ];
    }
  }
  for (const key of MERGED_CONCAT_METRICS) {
    const groups = [
      ...sampleGroupsFor(leftMetrics, key),
      ...sampleGroupsFor(rightMetrics, key),
    ];
    if (groups.length > 0) {
      merged[`${key}Groups`] = groups;
    }
  }
  const orderBalancedMetricSamples = {};
  for (const key of keys) {
    if (!isOrderBalancedTimingMetric(key)) {
      continue;
    }
    const samples = [
      ...orderBalancedSamplesFor(leftMetrics, key),
      ...orderBalancedSamplesFor(rightMetrics, key),
    ];
    if (samples.length > 0) {
      orderBalancedMetricSamples[key] = samples;
    }
  }
  if (Object.keys(orderBalancedMetricSamples).length > 0) {
    merged.orderBalancedMetricSamples = orderBalancedMetricSamples;
  }
  applyMergedSourceKernelStats(merged);
  return merged;
}

function combineModeRowResult(existing, next) {
  if (!next) {
    return existing ?? null;
  }
  if (!existing) {
    return next;
  }
  const sameStatus = existing.status === next.status && existing.statusCode === next.statusCode;
  return {
    status: sameStatus ? next.status : "fail",
    statusCode: sameStatus ? next.statusCode : "scenario_runtime_error",
    error: sameStatus
      ? (next.error ?? existing.error)
      : [existing.error, next.error].filter(Boolean).join(" | "),
    metrics: mergeMetrics(existing.metrics ?? {}, next.metrics ?? {}),
    measuredAt: new Date().toISOString(),
  };
}

async function main() {
  const args = parseArgs(process.argv);
  const chromium = await loadChromiumDriver();

  const projectionManifest = loadProjectionManifest(args.manifestPath);
  const workflowManifest = loadWorkflowManifest(args.workflowsPath);
  const filteredWorkloads = applyFocusCategories(
    projectionManifest.rows,
    workflowManifest.rows,
    args.focusCategories,
  );
  const l1Rows = filteredWorkloads.l1Rows;
  const l2Rows = filteredWorkloads.l2Rows;

  const modes = args.mode === "both" ? (args.modeOrder ?? ["dawn", "doe"]) : [args.mode];
  const modeScheduleEntries = buildModeSchedule(
    modes,
    l1Rows,
    l2Rows,
    args.modeSchedule,
    args.modeScheduleRepetitions,
    args.sourceKernelSamples,
    args.sourceKernelScheduleSlices,
    args.sourceKernelScheduleSliceMinDispatchRepeat,
  );
  const modeRunDetails = [];

  const pageTarget = await resolvePageTarget(args.allowDataUrlFallback, args.apiSurface);
  if (pageTarget.warning) {
    console.log(`[warn] ${pageTarget.warning}`);
  }
  try {
    for (const [scheduleIndex, scheduleEntry] of modeScheduleEntries.entries()) {
      const mode = scheduleEntry.mode;
      const modeSelection = runtimeSelectionResolution(mode, args);
      const chromePathForMode =
        modeSelection.selectedRuntime === "dawn" ? args.modeChromePaths.dawn : args.modeChromePaths.doe;
      if (pageTarget.kind === "unavailable") {
        const failure = {
          stage: "page_target",
          status: "unsupported",
          statusCode: "mode_execution_unavailable",
          error: pageTarget.warning ?? "page target unavailable",
        };
        for (const row of scheduleEntry.l1Rows) {
          if (row.layerTarget === "l0_only") {
            row.runtimes[mode] = makeModeRowResult("l0_only", "l0_only");
          } else {
            row.runtimes[mode] = makeModeRowResult(
              failure.status,
              failure.statusCode,
              failure.error,
            );
          }
        }
        for (const workflow of scheduleEntry.l2Rows) {
          workflow.runtimes[mode] = makeModeRowResult(
            failure.status,
            failure.statusCode,
            failure.error,
          );
        }
        modeRunDetails.push({
          mode,
          scheduleUnit: scheduleEntry.scheduleUnit,
          scheduleLayer: scheduleEntry.scheduleLayer,
          schedulePass: scheduleEntry.schedulePass ?? 1,
          scheduleRepetition: scheduleEntry.scheduleRepetition ?? 1,
          scheduleSlice: scheduleEntry.scheduleSlice ?? 1,
          scheduleSlices: scheduleEntry.scheduleSlices ?? 1,
          sourceKernelSamples: scheduleEntry.sourceKernelSamples ?? args.sourceKernelSamples,
          elapsedMs: 0,
          launchArgs: [],
          runtimeSelection: buildRuntimeSelection(
            mode,
            args,
            chromePathForMode,
            [],
          ),
          shaderCompilerIdentity: shaderCompilerIdentity(
            mode,
            args,
            chromePathForMode,
          ),
          runtimeProbe: {
            webgpuAvailable: false,
            adapterAvailable: false,
            adapterInfo: null,
            adapterIdentity: adapterIdentityFromProbe(null),
            featureCount: 0,
            errors: [failure.error],
          },
          runtimeEvidence: {
            modeRequested: mode,
            runtimeSelection: buildRuntimeSelection(
              mode,
              args,
              chromePathForMode,
              [],
            ),
            pageTargetKind: pageTarget.kind,
            pageTargetPort: null,
            pageTargetWarning: pageTarget.warning ?? null,
            browserVersion: "",
            userAgent: "",
            failureStage: failure.stage,
            failureStatusCode: failure.statusCode,
            activeRuntimeProof: activeRuntimeProof(
              modeSelection.selectedRuntime,
              null,
            ),
            nativeMetalTrace: {
              ...nativeMetalTraceBaseEvidence(args, modeSelection.selectedRuntime),
              status: args.nativeMetalTrace && modeSelection.selectedRuntime === "doe"
                ? "fail"
                : nativeMetalTraceBaseEvidence(args, modeSelection.selectedRuntime).status,
              reason: "page_target_unavailable",
              errors: args.nativeMetalTrace && modeSelection.selectedRuntime === "doe"
                ? ["browser launch was skipped because the page target was unavailable"]
                : [],
            },
          },
          modeFailure: failure,
        });
        console.log(
          `[mode=${mode}] runtime.webgpu=false runtime.adapter=false requiredL1Failed=all requiredL2Failed=all`,
        );
        continue;
      }

      const modeRun = await runMode(
        chromium,
        mode,
        args,
        pageTarget,
        scheduleEntry.l1Rows,
        scheduleEntry.l2Rows,
        chromePathForMode,
        scheduleEntry.sourceKernelSamples ?? args.sourceKernelSamples,
        `${String(scheduleIndex + 1).padStart(4, "0")}-${mode}-${scheduleEntry.scheduleLayer}-${scheduleEntry.scheduleUnit}`,
      );
      modeRunDetails.push({
        mode: modeRun.mode,
        scheduleUnit: scheduleEntry.scheduleUnit,
        scheduleLayer: scheduleEntry.scheduleLayer,
        schedulePass: scheduleEntry.schedulePass ?? 1,
        scheduleRepetition: scheduleEntry.scheduleRepetition ?? 1,
        scheduleSlice: scheduleEntry.scheduleSlice ?? 1,
        scheduleSlices: scheduleEntry.scheduleSlices ?? 1,
        sourceKernelSamples: scheduleEntry.sourceKernelSamples ?? args.sourceKernelSamples,
        chromePath: modeRun.chromePath,
        elapsedMs: modeRun.elapsedMs,
        launchArgs: modeRun.launchArgs,
        runtimeSelection: modeRun.runtimeEvidence.runtimeSelection,
        shaderCompilerIdentity: modeRun.shaderCompilerIdentity,
        runtimeProbe: modeRun.runtimeProbe,
        runtimeEvidence: modeRun.runtimeEvidence,
        modeFailure: modeRun.modeFailure,
      });

      for (const row of scheduleEntry.l1Rows) {
        row.runtimes[mode] = combineModeRowResult(
          row.runtimes[mode],
          modeRun.rowResultsById.get(row.sourceWorkloadId) ?? null,
        );
      }
      for (const workflow of scheduleEntry.l2Rows) {
        workflow.runtimes[mode] = combineModeRowResult(
          workflow.runtimes[mode],
          modeRun.workflowResultsById.get(workflow.id) ?? null,
        );
      }

      const requiredL1Failed = requiredFailureCount(scheduleEntry.l1Rows, mode);
      const requiredL2Failed = requiredFailureCount(scheduleEntry.l2Rows, mode);
      const scheduleLabel = `${scheduleEntry.scheduleLayer}:${scheduleEntry.scheduleUnit}`;
      console.log(
        `[mode=${mode} schedule=${scheduleLabel}] `
          + `runtime.webgpu=${modeRun.runtimeProbe.webgpuAvailable} `
          + `runtime.adapter=${modeRun.runtimeProbe.adapterAvailable} `
          + `requiredL1Failed=${requiredL1Failed} `
          + `requiredL2Failed=${requiredL2Failed}`,
      );
    }
  } finally {
    if (pageTarget.server) {
      pageTarget.server.close();
    }
  }

  const l1Summary = summarizeStatusForRows(l1Rows, modes, "l1");
  const l2Summary = summarizeStatusForRows(l2Rows, modes, "l2");
  const mergedSummary = mergeModeSummary(l1Summary, l2Summary, modes);
  const modeRunDetailsWithHashes = attachHashChain(
    modeRunDetails,
    "nursery.chromium.browser_layered_bench",
  );

  const report = {
    schemaVersion: 5,
    reportKind: "browser-layered-diagnostic",
    benchmarkClass: "directional",
    comparisonStatus: "diagnostic",
    claimStatus: "diagnostic",
    timingClass: args.nativeMetalTrace ? "instrumented-scenario" : "scenario",
    timingSource: "browser-performance-now",
    generatedAt: new Date().toISOString(),
    outputPath: args.outPath,
    hashAlgorithm: HASH_ALGORITHM,
    runtimeSelectorPolicyPath: args.runtimeSelectorPolicyPath,
    workloadIdentity: {
      kind: "browser_layered_superset",
      sourceWorkloadsPath: projectionManifest.metadata.sourceWorkloadsPath,
      sourceWorkloadsSha256: projectionManifest.metadata.sourceWorkloadsSha256,
      projectionRulesPath: projectionManifest.metadata.rulesPath,
      projectionRulesSha256: projectionManifest.metadata.rulesSha256,
      workflowManifestPath: args.workflowsPath,
      workflowManifestSha256: hashHex(workflowManifest),
      projectionContractHash: projectionManifest.metadata.projectionContractHash,
    },
    projectionContractHash: projectionManifest.metadata.projectionContractHash,
    sourceWorkloadsPath: projectionManifest.metadata.sourceWorkloadsPath,
    sourceWorkloadsSha256: projectionManifest.metadata.sourceWorkloadsSha256,
    projectionRulesPath: projectionManifest.metadata.rulesPath,
    projectionRulesSha256: projectionManifest.metadata.rulesSha256,
    invocation: {
      argv: process.argv.slice(2),
      cwd: process.cwd(),
      nodeVersion: process.version,
      platform: process.platform,
      arch: process.arch,
    },
    chromePath: args.chromePath,
    modeChromePaths: args.modeChromePaths,
    doeLibPath: args.doeLibPath,
    mode: args.mode,
    modeOrder: modes,
    modeSchedule: args.modeSchedule,
    modeScheduleRepetitions: args.modeScheduleRepetitions,
    headless: args.headless,
    chromeArgs: args.chromeArgs,
    powerPreference: args.powerPreference,
    manifestPath: args.manifestPath,
    workflowsPath: args.workflowsPath,
    workloadFilter: filteredWorkloads.filter,
    workflowPromotionGateRequiredApprovals: workflowManifest.promotionGateRequiredApprovals,
    browserEnvironmentEvidence: {
      pageTargetKind: pageTarget.kind,
      pageTargetPort: Number.isInteger(pageTarget.port) ? pageTarget.port : null,
      pageTargetWarning: pageTarget.warning ?? null,
      dataUrlFallbackEnabled: args.allowDataUrlFallback,
    },
    runtimeSelections: modeRunDetailsWithHashes.map((entry) => entry.runtimeSelection),
    methodology: {
      scenarioIterations: args.iterations,
      sourceKernelSamples: args.sourceKernelSamples,
      sourceKernelWarmupSamples: args.sourceKernelWarmupSamples,
      sourceKernelScheduleSlices: args.sourceKernelScheduleSlices,
      sourceKernelScheduleSliceMinDispatchRepeat:
        args.sourceKernelScheduleSliceMinDispatchRepeat,
      sourceKernelSubmitPolicy: args.sourceKernelSubmitPolicy,
      nativeMetalTrace: {
        requested: args.nativeMetalTrace,
        configPath: args.nativeMetalTraceConfigPath,
        configSha256: fileHashHex(args.nativeMetalTraceConfigPath),
        traceId: args.nativeMetalTraceConfig.traceId,
        environmentVariable: args.nativeMetalTraceConfig.environmentVariable,
        evidenceClass: args.nativeMetalTraceConfig.evidenceClass,
        timingsPerturbed: args.nativeMetalTrace,
        scoreEligible: !args.nativeMetalTrace,
      },
      modeSchedule: args.modeSchedule,
      modeScheduleRepetitions: args.modeScheduleRepetitions,
      browserBuildConfigurationEvidence: browserBuildConfigurationEvidence(args),
      adapterRequest: {
        powerPreference: args.powerPreference,
      },
      workloadFilter: filteredWorkloads.filter,
      strictMode: args.strict,
      requiredStatusPolicy: {
        l1: "requiredStatus=ok rows are required",
        l2: "requiredStatus=ok rows are required",
      },
      failureTaxonomy: {
        ok: ["ok"],
        unsupported: [
          "adapter_null",
          "api_unsupported",
          "launch_surface_unavailable",
          "mode_execution_unavailable",
          "runtime_mode_unavailable",
          "sandbox_constraint",
          "scenario_template_unknown",
          "webgpu_unavailable",
        ],
        fail: ["browser_launch_failed", "mode_setup_failed", "mode_execution_failed", "scenario_runtime_error"],
        l0_only: ["l0_only"],
      },
      notes: [
        "Nursery layered browser harness output is diagnostic and not a strict L0 claim artifact.",
        "Comparability and claim scope are carried from projection/workflow contracts and must not be widened.",
      ],
    },
    modeRunDetails: modeRunDetailsWithHashes,
    l1: {
      rowCount: l1Rows.length,
      rows: l1Rows,
    },
    l2: {
      workflowCount: l2Rows.length,
      rows: l2Rows,
    },
    summary: {
      l1: l1Summary,
      l2: l2Summary,
      ...mergedSummary,
    },
  };
  report.reportHash = hashHex(report);

  mkdirSync(dirname(args.outPath), { recursive: true });
  writeFileSync(args.outPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");
  console.log(`report written: ${args.outPath}`);
  console.log(`overall required failures: ${report.summary.overallRequiredFailures}`);

  if (args.strict && hasRequiredFailures(report.summary)) {
    process.exit(1);
  }
}

main().catch((error) => {
  console.error(String(error?.stack ?? error));
  process.exit(1);
});

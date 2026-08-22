// Physical four-lane context snapshot and incremental-diff executor.

import { createHash } from "node:crypto";
import { execFileSync, spawn } from "node:child_process";
import { createReadStream, readFileSync } from "node:fs";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(SCRIPT_DIR, "../../..");
const TOKENIZER_ID = "unicode-word-punctuation-v1";
const EXPECTED_ORACLE = Object.freeze({
  count: "3 orders",
  items: ["Alpha", "Beta", "Gamma"],
  status: "Processed",
  submitDisabled: true,
  title: "Orders",
});
const LANE_DEFINITIONS = Object.freeze([
  Object.freeze({
    laneId: "lane_a_chromium_playwright_dawn",
    browserKind: "stock_chromium",
    runtime: "dawn",
    transport: "playwright_full_ax_v1",
  }),
  Object.freeze({
    laneId: "lane_b_fawn_playwright_dawn",
    browserKind: "fawn",
    runtime: "dawn",
    transport: "playwright_full_ax_v1",
  }),
  Object.freeze({
    laneId: "lane_c_fawn_playwright_doe",
    browserKind: "fawn",
    runtime: "doe",
    transport: "playwright_full_ax_v1",
  }),
  Object.freeze({
    laneId: "lane_d_fawn_direct_doe",
    browserKind: "fawn",
    runtime: "doe",
    transport: "fawn_direct_cdp_incremental_v1",
  }),
]);

function parseArgs(argv) {
  const args = {
    headless: true,
    timedIterations: 100,
    warmupIterations: 5,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    const value = argv[index + 1];
    if (!token.startsWith("--") || value === undefined) {
      throw new Error("invalid or missing CLI value near " + token);
    }
    const key = token.slice(2);
    index += 1;
    if (key === "stock-chrome") args.stockChrome = value;
    else if (key === "fawn-chrome") args.fawnChrome = value;
    else if (key === "doe-lib") args.doeLib = value;
    else if (key === "fixture") args.fixture = value;
    else if (key === "platform-id") args.platformId = value;
    else if (key === "out") args.out = value;
    else if (key === "headless") args.headless = value === "true";
    else if (key === "timed-iterations") {
      args.timedIterations = Number(value);
    } else if (key === "warmup-iterations") {
      args.warmupIterations = Number(value);
    } else {
      throw new Error("unknown argument: " + token);
    }
  }
  for (const key of [
    "stockChrome",
    "fawnChrome",
    "doeLib",
    "fixture",
    "platformId",
    "out",
  ]) {
    if (!args[key]) throw new Error("missing required argument: " + key);
  }
  if (
    !Number.isInteger(args.timedIterations)
    || args.timedIterations < 2
  ) {
    throw new Error("timed iterations must be an integer >= 2");
  }
  if (
    !Number.isInteger(args.warmupIterations)
    || args.warmupIterations < 0
  ) {
    throw new Error(
      "warmup iterations must be a non-negative integer",
    );
  }
  return args;
}

function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, canonicalize(value[key])]),
    );
  }
  return value;
}

function canonicalJson(value) {
  return JSON.stringify(canonicalize(value));
}

function sha256Text(value) {
  return createHash("sha256")
    .update(value, "utf8")
    .digest("hex");
}

async function sha256File(filePath) {
  const digest = createHash("sha256");
  await new Promise((resolve, reject) => {
    const stream = createReadStream(filePath);
    stream.on("data", (chunk) => digest.update(chunk));
    stream.on("end", resolve);
    stream.on("error", reject);
  });
  return digest.digest("hex");
}

function tokenCount(text) {
  return (text.match(/[\p{L}\p{N}_]+|[^\s]/gu) || []).length;
}

function runtimeArgs(runtime, doeLib) {
  if (runtime === "dawn") {
    return ["--use-webgpu-runtime=dawn"];
  }
  return [
    "--use-webgpu-runtime=doe",
    "--doe-webgpu-library-path=" + doeLib,
  ];
}

function baseLaunchArgs(port) {
  const args = [
    "--no-sandbox",
    "--disable-setuid-sandbox",
    "--disable-dev-shm-usage",
    "--ignore-gpu-blocklist",
    "--enable-unsafe-webgpu",
    "--unsafely-treat-insecure-origin-as-secure=http://127.0.0.1:"
      + port,
  ];
  if (process.platform === "linux") {
    args.push("--use-angle=vulkan");
  }
  return args;
}

async function startFixtureServer(fixturePath) {
  const fixture = readFileSync(fixturePath);
  const server = createServer((request, response) => {
    response.writeHead(200, {
      "Cache-Control": "no-store",
      "Content-Length": fixture.length,
      "Content-Type": "text/html; charset=utf-8",
    });
    response.end(fixture);
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  if (!address || typeof address === "string") {
    throw new Error("fixture server address failed");
  }
  return {
    close: () => new Promise((resolve) => server.close(resolve)),
    port: address.port,
    url: "http://127.0.0.1:" + address.port + "/",
  };
}

function physicalHardwareIdentity(platformId) {
  if (platformId === "apple-metal") {
    if (process.platform !== "darwin") {
      throw new Error("apple-metal requires Darwin");
    }
    const output = execFileSync(
      "system_profiler",
      ["SPDisplaysDataType", "-json"],
      { encoding: "utf8" },
    );
    const displays = JSON.parse(output).SPDisplaysDataType || [];
    if (displays.length === 0) {
      throw new Error("system_profiler returned no GPU");
    }
    const vendor = String(
      displays[0].spdisplays_vendor || "Apple",
    );
    const device = String(
      displays[0].sppci_model || displays[0]._name || "",
    );
    if (!vendor.toLowerCase().includes("apple") || !device) {
      throw new Error("apple-metal physical identity mismatch");
    }
    const base = {
      architecture: process.arch,
      backend: "metal",
      device,
      evidenceSha256: sha256Text(output),
      hostPlatform: process.platform,
      platformId,
      source: "system_profiler_SPDisplaysDataType",
      vendor,
      verified: true,
    };
    return {
      ...base,
      identityHash: sha256Text(canonicalJson(base)),
    };
  }
  if (platformId === "amd-vulkan") {
    if (process.platform !== "linux") {
      throw new Error("amd-vulkan requires Linux");
    }
    const output = execFileSync(
      "vulkaninfo",
      ["--summary"],
      { encoding: "utf8" },
    );
    const deviceMatch = output.match(/deviceName\s*=\s*(.+)/i);
    const device = deviceMatch ? deviceMatch[1].trim() : "";
    const vendor = /amd|radeon/i.test(output) ? "AMD" : "";
    if (!vendor || !device) {
      throw new Error("amd-vulkan physical identity mismatch");
    }
    const base = {
      architecture: process.arch,
      backend: "vulkan",
      device,
      evidenceSha256: sha256Text(output),
      hostPlatform: process.platform,
      platformId,
      source: "vulkaninfo_summary",
      vendor,
      verified: true,
    };
    return {
      ...base,
      identityHash: sha256Text(canonicalJson(base)),
    };
  }
  throw new Error(
    "unsupported physical platform: " + platformId,
  );
}

function normalizeAxTree(payload) {
  return payload.nodes
    .filter((node) => node.ignored !== true)
    .map((node) => {
      const properties = (node.properties || [])
        .map((property) => ({
          name: property.name,
          value: property.value ? property.value.value : null,
        }))
        .sort((left, right) => left.name.localeCompare(right.name));
      return {
        description: node.description
          ? node.description.value
          : "",
        name: node.name ? node.name.value : "",
        properties,
        role: node.role ? node.role.value : "",
        value: node.value ? node.value.value : null,
      };
    });
}

function axDiff(before, after) {
  const beforeRows = new Set(
    before.map((row) => canonicalJson(row)),
  );
  return after.filter(
    (row) => !beforeRows.has(canonicalJson(row)),
  );
}

function metricsMap(payload) {
  return Object.fromEntries(
    payload.metrics.map((metric) => [
      metric.name,
      metric.value,
    ]),
  );
}

function adapterProbeExpression() {
  return "(async () => {"
    + "if (!navigator.gpu) throw new Error('navigator.gpu unavailable');"
    + "const adapter = await navigator.gpu.requestAdapter();"
    + "if (!adapter) throw new Error('WebGPU adapter unavailable');"
    + "const info = adapter.info || {};"
    + "return {vendor:String(info.vendor||''),"
    + "architecture:String(info.architecture||''),"
    + "device:String(info.device||''),"
    + "description:String(info.description||''),"
    + "subgroupMinSize:Number(info.subgroupMinSize||0),"
    + "subgroupMaxSize:Number(info.subgroupMaxSize||0)};"
    + "})()";
}

function installDirectProtocol() {
  function semanticRecord(element) {
    const tagRoles = {
      BUTTON: "button",
      H1: "heading",
      LI: "listitem",
      MAIN: "main",
      P: "paragraph",
      UL: "list",
    };
    return {
      disabled: Boolean(element.disabled),
      id: element.dataset.agentId || "",
      name: (
        element.getAttribute("aria-label")
        || element.textContent
        || ""
      ).trim(),
      role: element.getAttribute("role")
        || tagRoles[element.tagName]
        || "generic",
    };
  }
  const changed = new Map();
  const removed = new Set();
  function recordElement(element) {
    if (!(element instanceof Element)) return;
    const target = element.closest("[data-agent-id]");
    if (target) {
      changed.set(
        target.dataset.agentId,
        semanticRecord(target),
      );
    }
    element
      .querySelectorAll("[data-agent-id]")
      .forEach((child) => {
        changed.set(
          child.dataset.agentId,
          semanticRecord(child),
        );
      });
  }
  function consume(records) {
    for (const record of records) {
      recordElement(
        record.target.nodeType === Node.TEXT_NODE
          ? record.target.parentElement
          : record.target,
      );
      record.addedNodes.forEach((node) => recordElement(node));
      record.removedNodes.forEach((node) => {
        if (node instanceof Element) {
          if (node.dataset.agentId) {
            removed.add(node.dataset.agentId);
          }
          node
            .querySelectorAll("[data-agent-id]")
            .forEach((child) => {
              removed.add(child.dataset.agentId);
            });
        }
      });
    }
  }
  const observer = new MutationObserver(consume);
  observer.observe(document.documentElement, {
    attributes: true,
    characterData: true,
    childList: true,
    subtree: true,
  });
  window.__fawnDirectProtocol = {
    clear() {
      consume(observer.takeRecords());
      changed.clear();
      removed.clear();
    },
    takeDiff() {
      consume(observer.takeRecords());
      return {
        protocol: "fawn-direct-context-diff/v1",
        removals: Array.from(removed).sort(),
        upserts: Array.from(changed.values()).sort(
          (left, right) => left.id.localeCompare(right.id),
        ),
      };
    },
  };
}

function sampleRecord(options) {
  const serializedPayload = canonicalJson(options.payload);
  const oracleJson = canonicalJson(options.oracle);
  const expectedJson = canonicalJson(EXPECTED_ORACLE);
  return {
    contextTokens: tokenCount(serializedPayload),
    iteration: options.iteration,
    oraclePass: oracleJson === expectedJson,
    oracleSha256: sha256Text(oracleJson),
    orderIndex: options.orderIndex,
    payloadSha256: sha256Text(serializedPayload),
    phase: options.phase,
    rendererCpuMs: options.rendererCpuMs,
    rendererJsHeapMb: options.rendererJsHeapMb,
    serializedBytes: Buffer.byteLength(
      serializedPayload,
      "utf8",
    ),
    serializedPayload,
    success: oracleJson === expectedJson,
    timing: options.timing,
    tokenizerId: TOKENIZER_ID,
  };
}

async function createRuntimeIdentity(
  definition,
  binaryPath,
  doeLib,
  launchArgs,
  adapterInfo,
  version,
) {
  const browserHash = await sha256File(binaryPath);
  const artifactPath = definition.runtime === "doe"
    ? doeLib
    : binaryPath;
  const artifactHash = definition.runtime === "doe"
    ? await sha256File(doeLib)
    : browserHash;
  return {
    adapterInfo,
    browserIdentity: {
      executablePath: binaryPath,
      executableSha256: browserHash,
      version,
    },
    runtimeIdentity: {
      activeRuntimeProof: {
        hardwareIdentitySource: "wgpuAdapterGetInfo",
        matched: Boolean(
          adapterInfo.vendor && adapterInfo.architecture,
        ),
        providerIdentitySource:
          "forced_runtime_selector_and_artifact_hash",
      },
      artifactPath,
      artifactSha256: artifactHash,
      fallbackApplied: false,
      forcedMode: definition.runtime,
      hiddenFallbackAllowed: false,
      launchArgsSha256: sha256Text(
        canonicalJson(launchArgs),
      ),
      selectedRuntime: definition.runtime,
    },
  };
}

async function createPlaywrightSession(
  definition,
  args,
  fixtureServer,
) {
  const require = createRequire(import.meta.url);
  const playwrightPath = path.join(
    REPO_ROOT,
    "browser/chromium/node_modules/playwright-core",
  );
  const { chromium } = require(playwrightPath);
  const binaryPath = definition.browserKind === "stock_chromium"
    ? args.stockChrome
    : args.fawnChrome;
  const launchArgs = [
    ...baseLaunchArgs(fixtureServer.port),
    ...runtimeArgs(definition.runtime, args.doeLib),
  ];
  const browser = await chromium.launch({
    args: launchArgs,
    executablePath: binaryPath,
    headless: args.headless,
    timeout: 120000,
  });
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto(fixtureServer.url, {
    waitUntil: "load",
    timeout: 120000,
  });
  const cdp = await context.newCDPSession(page);
  await cdp.send("Accessibility.enable");
  await cdp.send("Performance.enable");
  const adapterInfo = await page.evaluate(
    adapterProbeExpression(),
  );
  const identity = await createRuntimeIdentity(
    definition,
    binaryPath,
    args.doeLib,
    launchArgs,
    adapterInfo,
    browser.version(),
  );
  return {
    ...identity,
    async close() {
      await browser.close();
    },
    async sample(phase, iteration, orderIndex) {
      const setupStart = performance.now();
      await page.evaluate(() => window.resetFixture());
      const before = normalizeAxTree(
        await cdp.send("Accessibility.getFullAXTree"),
      );
      const setupMs = performance.now() - setupStart;
      const beforeMetrics = metricsMap(
        await cdp.send("Performance.getMetrics"),
      );
      const totalStart = performance.now();
      const actionStart = performance.now();
      await page.evaluate(
        () => window.applyDeterministicMutation(),
      );
      const actionMs = performance.now() - actionStart;
      const snapshotStart = performance.now();
      const after = normalizeAxTree(
        await cdp.send("Accessibility.getFullAXTree"),
      );
      const payload = {
        changedNodes: axDiff(before, after),
        fullSnapshot: after,
        protocol:
          "playwright-full-accessibility-snapshot/v1",
      };
      const snapshotDiffMs = performance.now() - snapshotStart;
      const totalWallMs = performance.now() - totalStart;
      const afterMetrics = metricsMap(
        await cdp.send("Performance.getMetrics"),
      );
      const oracle = await page.evaluate(
        () => window.readOracleState(),
      );
      return sampleRecord({
        iteration,
        oracle,
        orderIndex,
        payload,
        phase,
        rendererCpuMs: Math.max(
          0,
          (
            (afterMetrics.TaskDuration || 0)
            - (beforeMetrics.TaskDuration || 0)
          ) * 1000,
        ),
        rendererJsHeapMb:
          (afterMetrics.JSHeapUsedSize || 0) / (1024 * 1024),
        timing: {
          actionMs,
          setupMs,
          snapshotDiffMs,
          totalWallMs,
        },
      });
    },
  };
}

class CdpConnection {
  constructor(url) {
    this.url = url;
    this.nextId = 1;
    this.pending = new Map();
  }

  async open() {
    this.socket = new WebSocket(this.url);
    await new Promise((resolve, reject) => {
      this.socket.addEventListener(
        "open",
        resolve,
        { once: true },
      );
      this.socket.addEventListener(
        "error",
        reject,
        { once: true },
      );
    });
    this.socket.addEventListener("message", (event) => {
      const message = JSON.parse(String(event.data));
      if (!message.id || !this.pending.has(message.id)) {
        return;
      }
      const pending = this.pending.get(message.id);
      this.pending.delete(message.id);
      if (message.error) {
        pending.reject(
          new Error(JSON.stringify(message.error)),
        );
      } else {
        pending.resolve(message.result || {});
      }
    });
  }

  send(method, params = {}, sessionId = undefined) {
    const id = this.nextId;
    this.nextId += 1;
    const message = { id, method, params };
    if (sessionId) message.sessionId = sessionId;
    this.socket.send(JSON.stringify(message));
    return new Promise((resolve, reject) => {
      this.pending.set(id, { reject, resolve });
    });
  }

  close() {
    if (
      this.socket
      && this.socket.readyState < WebSocket.CLOSING
    ) {
      this.socket.close();
    }
  }
}

async function waitForDevTools(child) {
  return new Promise((resolve, reject) => {
    let stderr = "";
    const timeout = setTimeout(
      () => reject(
        new Error(
          "DevTools endpoint timeout: " + stderr.slice(-2000),
        ),
      ),
      120000,
    );
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
      const match = stderr.match(
        /DevTools listening on (ws:\/\/[^\s]+)/,
      );
      if (match) {
        clearTimeout(timeout);
        resolve(match[1]);
      }
    });
    child.once("exit", (code) => {
      clearTimeout(timeout);
      reject(
        new Error(
          "browser exited before DevTools endpoint, code="
            + code
            + ": "
            + stderr.slice(-2000),
        ),
      );
    });
  });
}

async function cdpEvaluate(
  connection,
  sessionId,
  expression,
) {
  const response = await connection.send(
    "Runtime.evaluate",
    {
      awaitPromise: true,
      expression,
      returnByValue: true,
    },
    sessionId,
  );
  if (response.exceptionDetails) {
    throw new Error(
      "CDP evaluation failed: "
        + JSON.stringify(response.exceptionDetails),
    );
  }
  return response.result
    ? response.result.value
    : undefined;
}

async function createDirectSession(
  definition,
  args,
  fixtureServer,
) {
  const profileDir = await mkdtemp(
    path.join(tmpdir(), "fawn-direct-"),
  );
  const launchArgs = [
    ...baseLaunchArgs(fixtureServer.port),
    ...runtimeArgs(definition.runtime, args.doeLib),
    "--remote-debugging-port=0",
    "--user-data-dir=" + profileDir,
    "--no-first-run",
    "--no-default-browser-check",
  ];
  if (args.headless) launchArgs.push("--headless=new");
  const child = spawn(args.fawnChrome, launchArgs, {
    stdio: ["ignore", "ignore", "pipe"],
  });
  const endpoint = await waitForDevTools(child);
  const connection = new CdpConnection(endpoint);
  await connection.open();
  const version = await connection.send("Browser.getVersion");
  const target = await connection.send(
    "Target.createTarget",
    { url: fixtureServer.url },
  );
  const attached = await connection.send(
    "Target.attachToTarget",
    {
      flatten: true,
      targetId: target.targetId,
    },
  );
  const sessionId = attached.sessionId;
  await connection.send("Runtime.enable", {}, sessionId);
  await connection.send("Performance.enable", {}, sessionId);
  for (let attempt = 0; attempt < 120; attempt += 1) {
    try {
      const ready = await cdpEvaluate(
        connection,
        sessionId,
        "document.readyState === 'complete'",
      );
      if (ready) break;
    } catch {
      // Navigation can transiently replace the execution context.
    }
    await new Promise(
      (resolve) => setTimeout(resolve, 100),
    );
  }
  await cdpEvaluate(
    connection,
    sessionId,
    "(" + installDirectProtocol.toString() + ")()",
  );
  const adapterInfo = await cdpEvaluate(
    connection,
    sessionId,
    adapterProbeExpression(),
  );
  const identity = await createRuntimeIdentity(
    definition,
    args.fawnChrome,
    args.doeLib,
    launchArgs,
    adapterInfo,
    version.product || "",
  );
  return {
    ...identity,
    async close() {
      try {
        await connection.send("Browser.close");
      } catch {
        child.kill("SIGTERM");
      }
      connection.close();
      await rm(profileDir, {
        force: true,
        recursive: true,
      });
    },
    async sample(phase, iteration, orderIndex) {
      const setupStart = performance.now();
      await cdpEvaluate(
        connection,
        sessionId,
        "(async()=>{window.resetFixture();"
          + "await Promise.resolve();"
          + "window.__fawnDirectProtocol.clear();"
          + "return true;})()",
      );
      const setupMs = performance.now() - setupStart;
      const beforeMetrics = metricsMap(
        await connection.send(
          "Performance.getMetrics",
          {},
          sessionId,
        ),
      );
      const totalStart = performance.now();
      const actionStart = performance.now();
      await cdpEvaluate(
        connection,
        sessionId,
        "window.applyDeterministicMutation(); true",
      );
      const actionMs = performance.now() - actionStart;
      const snapshotStart = performance.now();
      const payload = await cdpEvaluate(
        connection,
        sessionId,
        "(async()=>{await Promise.resolve();"
          + "return window.__fawnDirectProtocol.takeDiff();})()",
      );
      const snapshotDiffMs = performance.now() - snapshotStart;
      const totalWallMs = performance.now() - totalStart;
      const afterMetrics = metricsMap(
        await connection.send(
          "Performance.getMetrics",
          {},
          sessionId,
        ),
      );
      const oracle = await cdpEvaluate(
        connection,
        sessionId,
        "window.readOracleState()",
      );
      return sampleRecord({
        iteration,
        oracle,
        orderIndex,
        payload,
        phase,
        rendererCpuMs: Math.max(
          0,
          (
            (afterMetrics.TaskDuration || 0)
            - (beforeMetrics.TaskDuration || 0)
          ) * 1000,
        ),
        rendererJsHeapMb:
          (afterMetrics.JSHeapUsedSize || 0) / (1024 * 1024),
        timing: {
          actionMs,
          setupMs,
          snapshotDiffMs,
          totalWallMs,
        },
      });
    },
  };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const fixtureServer = await startFixtureServer(args.fixture);
  const sessions = new Map();
  const lanes = {};
  const startedAtUtc = new Date().toISOString();
  const hardwareIdentity = physicalHardwareIdentity(
    args.platformId,
  );
  const output = {
    errors: [],
    lanes,
    platform: {
      architecture: process.arch,
      hardwareIdentity,
      hostPlatform: process.platform,
      platformId: args.platformId,
    },
    reportKind: "fawn-doe-context-snapshot-diff-raw",
    run: {
      laneOrderPolicy: "rotating_interleaved_v1",
      startedAtUtc,
      timedIterations: args.timedIterations,
      warmupIterations: args.warmupIterations,
    },
    runStatus: "running",
    schemaVersion: 1,
    workload: {
      executorId: "browser-context-snapshot-diff-v1",
      inputPath: path.relative(REPO_ROOT, args.fixture),
      inputSha256: await sha256File(args.fixture),
      oracleId: "context-snapshot-diff-state-v1",
      tokenizerId: TOKENIZER_ID,
      workloadId: "context_snapshot_diff",
    },
  };
  try {
    for (const definition of LANE_DEFINITIONS) {
      const session =
        definition.transport === "playwright_full_ax_v1"
          ? await createPlaywrightSession(
            definition,
            args,
            fixtureServer,
          )
          : await createDirectSession(
            definition,
            args,
            fixtureServer,
          );
      sessions.set(definition.laneId, session);
      lanes[definition.laneId] = {
        adapterInfo: session.adapterInfo,
        browserIdentity: session.browserIdentity,
        runtimeIdentity: session.runtimeIdentity,
        samples: [],
        transport: definition.transport,
      };
    }
    const totalRounds =
      args.warmupIterations + args.timedIterations;
    for (let round = 0; round < totalRounds; round += 1) {
      const isWarmup = round < args.warmupIterations;
      const phase = isWarmup ? "warmup" : "timed";
      const iteration = isWarmup
        ? round
        : round - args.warmupIterations;
      const offset = round % LANE_DEFINITIONS.length;
      const order = [
        ...LANE_DEFINITIONS.slice(offset),
        ...LANE_DEFINITIONS.slice(0, offset),
      ];
      for (
        let orderIndex = 0;
        orderIndex < order.length;
        orderIndex += 1
      ) {
        const definition = order[orderIndex];
        const sample = await sessions
          .get(definition.laneId)
          .sample(phase, iteration, orderIndex);
        lanes[definition.laneId].samples.push(sample);
      }
    }
    output.runStatus = "passed";
  } catch (error) {
    output.runStatus = "failed";
    output.errors.push(
      error instanceof Error
        ? error.stack || error.message
        : String(error),
    );
  } finally {
    for (const session of sessions.values()) {
      try {
        await session.close();
      } catch (error) {
        output.errors.push("close: " + String(error));
      }
    }
    await fixtureServer.close();
    await mkdir(path.dirname(args.out), {
      recursive: true,
    });
    await writeFile(
      args.out,
      JSON.stringify(output, null, 2) + "\n",
      "utf8",
    );
  }
  if (output.runStatus !== "passed") {
    throw new Error(output.errors.join("\n"));
  }
  process.stdout.write(args.out + "\n");
}

main().catch((error) => {
  process.stderr.write(
    (error.stack || error.message || String(error)) + "\n",
  );
  process.exitCode = 1;
});

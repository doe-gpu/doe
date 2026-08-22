#!/usr/bin/env node
import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { createRequire } from "node:module";

const LANES = [
  ["lane_a_chromium_playwright_dawn", "playwright", "dawn", "stock"],
  ["lane_b_fawn_playwright_dawn", "playwright", "dawn", "fawn"],
  ["lane_c_fawn_playwright_doe", "playwright", "doe", "fawn"],
  ["lane_d_fawn_direct_doe", "raw_cdp", "doe", "fawn"],
];

function parseArgs(argv) {
  const values = {};
  for (let index = 2; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key?.startsWith("--") || value === undefined) throw new Error(`invalid option ${key}`);
    values[key.slice(2)] = value;
  }
  for (const key of ["workload", "stock-browser", "fawn-browser", "doe-library", "fixture", "output", "warmups", "iterations"]) {
    if (!values[key]) throw new Error(`--${key} is required`);
  }
  return {
    workload: values.workload,
    stockBrowser: path.resolve(values["stock-browser"]),
    fawnBrowser: path.resolve(values["fawn-browser"]),
    doeLibrary: path.resolve(values["doe-library"]),
    playwrightRoot: path.resolve(values["playwright-root"] ?? process.cwd()),
    fixture: path.resolve(values.fixture),
    output: path.resolve(values.output),
    warmups: Number.parseInt(values.warmups, 10),
    iterations: Number.parseInt(values.iterations, 10),
    agentSteps: Number.parseInt(values["agent-steps"] ?? "3", 10),
    inputElements: Number.parseInt(values["input-elements"] ?? "16384", 10),
    headless: values.headless !== "false",
  };
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function fileSha256(file) {
  return sha256(readFileSync(file));
}

function lexicalTokens(text) {
  return text.match(/[\p{L}\p{N}_]+|[^\s]/gu)?.length ?? 0;
}

function commonArgs(runtime, doeLibrary, origin) {
  const args = [
    "--no-sandbox",
    "--disable-setuid-sandbox",
    "--disable-dev-shm-usage",
    "--ignore-gpu-blocklist",
    "--enable-unsafe-webgpu",
    `--unsafely-treat-insecure-origin-as-secure=${origin}`,
    `--use-webgpu-runtime=${runtime}`,
  ];
  if (runtime === "doe") args.push(`--doe-webgpu-library-path=${doeLibrary}`);
  return args;
}

async function loadChromium(root) {
  const require = createRequire(import.meta.url);
  const candidates = [
    path.join(root, "node_modules", "playwright"),
    path.join(root, "node_modules", "playwright-core"),
    "playwright",
    "playwright-core",
  ];
  for (const candidate of candidates) {
    try {
      return require(candidate).chromium;
    } catch {}
  }
  throw new Error(`Playwright not found beneath ${root}`);
}

async function serveFixture(fixture) {
  const body = readFileSync(fixture);
  const server = http.createServer((_request, response) => {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
    response.end(body);
  });
  await new Promise((resolvePromise, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolvePromise);
  });
  const address = server.address();
  return { server, origin: `http://127.0.0.1:${address.port}` };
}

class CdpConnection {
  constructor(url) {
    this.url = url;
    this.nextId = 1;
    this.pending = new Map();
    this.waiters = [];
  }
  async connect() {
    this.ws = new WebSocket(this.url);
    this.ws.onmessage = (event) => this.receive(JSON.parse(String(event.data)));
    await new Promise((resolvePromise, reject) => {
      this.ws.onopen = resolvePromise;
      this.ws.onerror = reject;
    });
  }
  receive(message) {
    if (message.id && this.pending.has(message.id)) {
      const entry = this.pending.get(message.id);
      this.pending.delete(message.id);
      if (message.error) entry.reject(new Error(message.error.message));
      else entry.resolve(message.result);
      return;
    }
    const index = this.waiters.findIndex((entry) =>
      entry.method === message.method && (!entry.sessionId || entry.sessionId === message.sessionId));
    if (index >= 0) this.waiters.splice(index, 1)[0].resolve(message.params ?? {});
  }
  send(method, params = {}, sessionId = undefined) {
    const id = this.nextId++;
    this.ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
    return new Promise((resolvePromise, reject) => this.pending.set(id, { resolve: resolvePromise, reject }));
  }
  once(method, sessionId) {
    return new Promise((resolvePromise, reject) => {
      const timer = setTimeout(() => reject(new Error(`timeout waiting for ${method}`)), 15000);
      this.waiters.push({ method, sessionId, resolve: (value) => { clearTimeout(timer); resolvePromise(value); } });
    });
  }
}

async function launchRaw(browserPath, launchArgs) {
  const profile = mkdtempSync(path.join(os.tmpdir(), "fawn-matrix-cdp-"));
  const child = spawn(browserPath, [
    ...launchArgs,
    "--headless=new",
    "--remote-debugging-port=0",
    `--user-data-dir=${profile}`,
    "about:blank",
  ], { stdio: ["ignore", "ignore", "pipe"] });
  const websocketUrl = await new Promise((resolvePromise, reject) => {
    let stderr = "";
    const timer = setTimeout(() => reject(new Error(`CDP endpoint timeout: ${stderr}`)), 20000);
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
      const match = stderr.match(/DevTools listening on (ws:\/\/[^\s]+)/);
      if (match) { clearTimeout(timer); resolvePromise(match[1]); }
    });
    child.once("exit", (code) => { clearTimeout(timer); reject(new Error(`browser exited before CDP endpoint: ${code}`)); });
  });
  const cdp = new CdpConnection(websocketUrl);
  await cdp.connect();
  return { child, profile, cdp };
}

async function rawPage(raw, url) {
  const { targetId } = await raw.cdp.send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await raw.cdp.send("Target.attachToTarget", { targetId, flatten: true });
  await raw.cdp.send("Page.enable", {}, sessionId);
  await raw.cdp.send("Runtime.enable", {}, sessionId);
  const loaded = raw.cdp.once("Page.loadEventFired", sessionId);
  await raw.cdp.send("Page.navigate", { url }, sessionId);
  await loaded;
  return { targetId, sessionId };
}

async function rawEvaluate(raw, page, expression) {
  const result = await raw.cdp.send("Runtime.evaluate", {
    expression,
    awaitPromise: true,
    returnByValue: true,
  }, page.sessionId);
  if (result.exceptionDetails) throw new Error(result.exceptionDetails.text ?? "CDP evaluation failed");
  return result.result.value;
}

async function createLane(chromium, definition, args, origin) {
  const [laneId, transport, runtime, browserKind] = definition;
  const executablePath = browserKind === "stock" ? args.stockBrowser : args.fawnBrowser;
  const launchArgs = commonArgs(runtime, args.doeLibrary, origin);
  const lane = { laneId, transport, runtime, executablePath, launchArgs };
  if (transport === "playwright") {
    lane.browser = await chromium.launch({ executablePath, headless: args.headless, args: launchArgs });
    lane.context = await lane.browser.newContext();
    lane.page = await lane.context.newPage();
    await lane.page.goto(origin, { waitUntil: "load" });
    lane.version = lane.browser.version();
    lane.adapterInfo = (await lane.page.evaluate(() => window.matrixGpu.probe())).adapterInfo;
  } else {
    lane.raw = await launchRaw(executablePath, launchArgs);
    lane.page = await rawPage(lane.raw, origin);
    lane.version = (await lane.raw.cdp.send("Browser.getVersion")).product;
    lane.adapterInfo = (await rawEvaluate(lane.raw, lane.page, "window.matrixGpu.probe()" )).adapterInfo;
  }
  return lane;
}

async function closeLane(lane) {
  if (lane.browser) await lane.browser.close();
  if (lane.raw) {
    const waitForExit = () => lane.raw.child.exitCode !== null
      ? Promise.resolve()
      : new Promise((resolvePromise) => lane.raw.child.once("exit", resolvePromise));
    try { await lane.raw.cdp.send("Browser.close"); } catch {}
    await Promise.race([
      waitForExit(),
      new Promise((resolvePromise) => setTimeout(resolvePromise, 2000)),
    ]);
    if (lane.raw.child.exitCode === null) {
      lane.raw.child.kill("SIGTERM");
      await waitForExit();
    }
    rmSync(lane.raw.profile, {
      recursive: true,
      force: true,
      maxRetries: 5,
      retryDelay: 100,
    });
  }
}

async function evaluate(lane, expression, page = lane.page) {
  if (lane.transport === "playwright") return page.evaluate(expression);
  return rawEvaluate(lane.raw, page, expression);
}

function chooseAction(snapshot) {
  const nodes = snapshot.nodes ?? snapshot.upserts ?? [];
  return nodes.find((node) => node.role === "button" && !node.disabled)?.id ?? null;
}

async function gpuSample(lane, seed) {
  const result = await evaluate(lane, `window.matrixGpu.preprocess(${seed})`);
  return {
    success: result.oraclePass,
    oraclePass: result.oraclePass,
    outputSha256: result.outputSha256,
    maxAbsError: result.maxAbsError,
    memoryMb: result.memoryMb,
    timing: {
      compilationMs: result.compilationMs,
      pipelineCreationMs: result.pipelineCreationMs,
      uploadMs: result.uploadMs,
      dispatchMs: result.dispatchMs,
      synchronizationMs: result.synchronizationMs,
      readbackMs: result.readbackMs,
      totalWallMs: result.completeOperationMs,
    },
  };
}

async function agentSample(lane, iteration, sessionMode, origin, steps) {
  const totalStart = performance.now();
  let page = lane.page;
  const sessionStart = performance.now();
  if (sessionMode === "cold") {
    if (lane.transport === "playwright") {
      page = await lane.context.newPage();
      await page.goto(origin, { waitUntil: "load" });
    } else {
      page = await rawPage(lane.raw, origin);
    }
  }
  await evaluate(lane, "window.agent.reset()", page);
  const sessionMs = performance.now() - sessionStart;
  let contextBytes = 0;
  let contextTokens = 0;
  let inspectDiffMs = 0;
  let visualPreprocessingMs = 0;
  let actionDispatchMs = 0;
  let gpuOutputSha256 = "";
  let success = true;
  for (let step = 0; step < steps; step += 1) {
    const inspectStart = performance.now();
    const method = lane.transport === "raw_cdp" ? "directDiff" : "fullSnapshot";
    const snapshot = await evaluate(lane, `window.agent.${method}()`, page);
    inspectDiffMs += performance.now() - inspectStart;
    const serialized = JSON.stringify(snapshot);
    contextBytes += Buffer.byteLength(serialized);
    contextTokens += lexicalTokens(serialized);
    const action = chooseAction(snapshot);
    const gpu = await evaluate(lane, `window.matrixGpu.preprocess(${iteration * steps + step})`, page);
    visualPreprocessingMs += gpu.completeOperationMs;
    gpuOutputSha256 = gpu.outputSha256;
    success &&= gpu.oraclePass && Boolean(action);
    const actionStart = performance.now();
    if (lane.transport === "playwright") await page.click(`#${action}`);
    else success &&= await evaluate(lane, `window.agent.act(${JSON.stringify(action)})`, page);
    actionDispatchMs += performance.now() - actionStart;
  }
  const oracle = await evaluate(lane, "window.agent.oracle()", page);
  const memoryMb = await evaluate(
    lane,
    "performance.memory ? performance.memory.usedJSHeapSize / (1024 * 1024) : 0",
    page,
  );
  success &&= oracle.pass;
  if (sessionMode === "cold") {
    if (lane.transport === "playwright") await page.close();
    else await lane.raw.cdp.send("Target.closeTarget", { targetId: page.targetId });
  }
  return {
    success,
    oraclePass: oracle.pass,
    oracleSha256: sha256(JSON.stringify(oracle.state)),
    gpuOutputSha256,
    contextBytes,
    contextTokens,
    sessionMode,
    memoryMb,
    timing: {
      sessionMs,
      inspectDiffMs,
      visualPreprocessingMs,
      actionDispatchMs,
      totalWallMs: performance.now() - totalStart,
    },
  };
}

function runtimeIdentity(lane, args) {
  const artifactPath = lane.runtime === "doe" ? args.doeLibrary : lane.executablePath;
  const vendor = String(lane.adapterInfo.vendor ?? "").toLowerCase();
  return {
    selectedRuntime: lane.runtime,
    forcedMode: lane.runtime,
    fallbackApplied: false,
    hiddenFallbackAllowed: false,
    artifactPath,
    artifactSha256: fileSha256(artifactPath),
    launchArgsSha256: sha256(JSON.stringify(lane.launchArgs)),
    activeRuntimeProof: {
      matched: lane.runtime === "doe" ? vendor === "doe" : vendor !== "doe",
      providerIdentitySource: "forced_runtime_selector_and_artifact_hash",
      hardwareIdentitySource: "wgpuAdapterGetInfo",
    },
  };
}

async function main() {
  const args = parseArgs(process.argv);
  if (!existsSync(args.fixture)) throw new Error(`fixture not found: ${args.fixture}`);
  const chromium = await loadChromium(args.playwrightRoot);
  const fixtureServer = await serveFixture(args.fixture);
  const lanes = [];
  const errors = [];
  try {
    for (const definition of LANES) lanes.push(await createLane(chromium, definition, args, fixtureServer.origin));
    const samplesByLane = Object.fromEntries(lanes.map((lane) => [lane.laneId, []]));
    for (const phase of ["warmup", "timed"]) {
      const count = phase === "warmup" ? args.warmups : args.iterations;
      for (let iteration = 0; iteration < count; iteration += 1) {
        const order = [...lanes.slice(iteration % lanes.length), ...lanes.slice(0, iteration % lanes.length)];
        for (const [orderIndex, lane] of order.entries()) {
          try {
            const sample = args.workload === "webgpu_model_preprocessing"
              ? await gpuSample(lane, iteration)
              : await agentSample(lane, iteration, iteration % 2 === 0 ? "cold" : "warm", fixtureServer.origin, args.agentSteps);
            samplesByLane[lane.laneId].push({ phase, iteration, orderIndex, ...sample });
          } catch (error) {
            errors.push({ lane: lane.laneId, phase, iteration, error: String(error?.stack ?? error) });
            samplesByLane[lane.laneId].push({ phase, iteration, orderIndex, success: false, oraclePass: false, timing: { totalWallMs: 0 } });
          }
        }
      }
    }
    const lanePayload = {};
    for (const lane of lanes) {
      lanePayload[lane.laneId] = {
        transport: lane.transport === "raw_cdp" ? "fawn_direct_raw_cdp_v1" : "playwright_v1",
        browserIdentity: {
          executablePath: lane.executablePath,
          executableSha256: fileSha256(lane.executablePath),
          version: lane.version,
        },
        runtimeIdentity: runtimeIdentity(lane, args),
        adapterInfo: lane.adapterInfo,
        samples: samplesByLane[lane.laneId],
      };
    }
    const payload = {
      schemaVersion: 1,
      reportKind: "fawn-doe-live-workload-raw",
      workloadId: args.workload,
      simulated_mode: false,
      runStatus: errors.length === 0 ? "passed" : "failed",
      run: {
        startedAtUtc: new Date().toISOString(),
        warmupIterations: args.warmups,
        timedIterations: args.iterations,
        laneOrderPolicy: "rotating_interleaved_v1",
      },
      lanes: lanePayload,
      errors,
    };
    writeFileSync(args.output, `${JSON.stringify(payload, null, 2)}\n`, "utf8");
    console.log(args.output);
    if (errors.length > 0) process.exitCode = 1;
  } finally {
    for (const lane of lanes.reverse()) await closeLane(lane);
    fixtureServer.server.close();
  }
}

main().catch((error) => {
  console.error(String(error?.stack ?? error));
  process.exit(1);
});

#!/usr/bin/env node

import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { constants as fsConstants } from 'node:fs';
import { access, mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const harnessDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(harnessDir, '../../..');
const defaultUpstream = resolve(
  repoRoot,
  'bench/out/external-projects/umap-gpu/upstream',
);
const expectedCommit = '7884b287f49bc057df7e0856c5539f130a20e0ad';
const inputPath = resolve(harnessDir, 'sgd-benchmark.inputs.json');
const oraclePath = resolve(harnessDir, 'sgd-benchmark.oracle.md');
const workloadPath = resolve(harnessDir, 'sgd-benchmark.workload.test.ts');
const configPath = resolve(harnessDir, 'vitest-sgd-benchmark.config.mjs');
const providerProbePath = resolve(harnessDir, 'provider-probe.mjs');
const maximumOutputBytes = 2 * 1024 * 1024;

function parseArgs(argv) {
  const options = {
    upstream: defaultUpstream,
    runId: new Date().toISOString().replaceAll(':', '').replaceAll('.', ''),
    cleanProcessRuns: 3,
    timeoutMs: 120_000,
    requireAllPass: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === '--upstream') options.upstream = resolve(argv[++index]);
    else if (value === '--run-id') options.runId = argv[++index];
    else if (value === '--clean-process-runs') {
      options.cleanProcessRuns = Number.parseInt(argv[++index], 10);
    } else if (value === '--timeout-ms') {
      options.timeoutMs = Number.parseInt(argv[++index], 10);
    } else if (value === '--require-all-pass') options.requireAllPass = true;
    else throw new Error(`unknown argument: ${value}`);
  }
  if (!Number.isInteger(options.cleanProcessRuns) || options.cleanProcessRuns < 1) {
    throw new Error('--clean-process-runs must be a positive integer');
  }
  if (!Number.isInteger(options.timeoutMs) || options.timeoutMs < 1) {
    throw new Error('--timeout-ms must be a positive integer');
  }
  if (!/^[A-Za-z0-9._-]+$/.test(options.runId)) {
    throw new Error('--run-id must contain only letters, numbers, dot, underscore, or hyphen');
  }
  return options;
}

async function sha256(path) {
  return createHash('sha256').update(await readFile(path)).digest('hex');
}

function sha256Text(value) {
  return createHash('sha256').update(value).digest('hex');
}

function terminate(child) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  if (process.platform !== 'win32' && child.pid) {
    try {
      process.kill(-child.pid, 'SIGKILL');
      return;
    } catch {
      // Fall through to direct-child termination.
    }
  }
  child.kill('SIGKILL');
}

async function processTreeRssBytes(rootPid) {
  const pending = [rootPid];
  const visited = new Set();
  let total = 0;
  while (pending.length > 0) {
    const pid = pending.pop();
    if (!Number.isInteger(pid) || visited.has(pid)) continue;
    visited.add(pid);
    try {
      const status = await readFile(`/proc/${pid}/status`, 'utf8');
      const rss = status.match(/^VmRSS:\s+([0-9]+)\s+kB$/m);
      if (rss) total += Number(rss[1]) * 1024;
      const tasks = await readdir(`/proc/${pid}/task`);
      for (const task of tasks) {
        try {
          const children = await readFile(
            `/proc/${pid}/task/${task}/children`,
            'utf8',
          );
          for (const childPid of children.trim().split(/\s+/)) {
            if (childPid) pending.push(Number(childPid));
          }
        } catch {
          // A task may exit while its process tree is sampled.
        }
      }
    } catch {
      // A process may exit while its process tree is sampled.
    }
  }
  return total;
}

async function runProcess(command, args, { cwd, env, timeoutMs }) {
  const started = process.hrtime.bigint();
  const child = spawn(command, args, {
    cwd,
    env,
    detached: process.platform !== 'win32',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const stdout = [];
  const stderr = [];
  let outputBytes = 0;
  let timedOut = false;
  let outputLimitExceeded = false;
  let peakProcessTreeRssBytes = 0;
  let rssSample = Promise.resolve();
  const sampleRss = () => {
    rssSample = rssSample.then(async () => {
      peakProcessTreeRssBytes = Math.max(
        peakProcessTreeRssBytes,
        await processTreeRssBytes(child.pid),
      );
    });
  };
  sampleRss();
  const rssTimer = setInterval(sampleRss, 5);
  const timer = setTimeout(() => {
    timedOut = true;
    terminate(child);
  }, timeoutMs);
  const collect = (target) => (chunk) => {
    outputBytes += chunk.length;
    target.push(chunk);
    if (outputBytes > maximumOutputBytes) {
      outputLimitExceeded = true;
      terminate(child);
    }
  };
  child.stdout.on('data', collect(stdout));
  child.stderr.on('data', collect(stderr));
  const result = await new Promise((resolveResult, reject) => {
    child.once('error', reject);
    child.once('exit', (exitCode, signal) => resolveResult({ exitCode, signal }));
  });
  clearTimeout(timer);
  clearInterval(rssTimer);
  await rssSample;
  return {
    ...result,
    timedOut,
    outputLimitExceeded,
    crashed: !timedOut && !outputLimitExceeded && result.signal !== null,
    durationMs: Number(process.hrtime.bigint() - started) / 1e6,
    peakProcessTreeRssBytes,
    stdout: Buffer.concat(stdout).toString('utf8'),
    stderr: Buffer.concat(stderr).toString('utf8'),
  };
}

async function inspectHostHardware() {
  let renderNodes = [];
  try {
    renderNodes = (await readdir('/dev/dri'))
      .filter((name) => name.startsWith('renderD'))
      .map((name) => `/dev/dri/${name}`);
  } catch {
    return { renderNodes, accessibleRenderNodes: [], physicalGpuEligible: false };
  }
  const accessibleRenderNodes = [];
  for (const path of renderNodes) {
    try {
      await access(path, fsConstants.R_OK | fsConstants.W_OK);
      accessibleRenderNodes.push(path);
    } catch {
      // An inaccessible render node cannot support physical evidence.
    }
  }
  return {
    renderNodes,
    accessibleRenderNodes,
    physicalGpuEligible: accessibleRenderNodes.length > 0,
  };
}

function providerEnvironment(lane, upstreamRoot, runtimeDir) {
  return {
    ...process.env,
    NO_COLOR: '1',
    FORCE_COLOR: '0',
    DOE_EXTERNAL_WEBGPU_PROVIDER: lane.provider,
    DOE_EXTERNAL_PROVIDER_MODULE: lane.modulePath,
    DOE_EXTERNAL_UPSTREAM_ROOT: upstreamRoot,
    DOE_UMAP_SGD_BENCHMARK_INPUT: inputPath,
    DOE_UMAP_OWNERSHIP_LANE: lane.id,
    DOE_UMAP_EVIDENCE_MODE: lane.evidenceMode,
    XDG_RUNTIME_DIR: runtimeDir,
  };
}

function parseBenchmarkMarker(stdout) {
  const prefix = 'DOE_UMAP_SGD_BENCHMARK=';
  const line = stdout.split('\n').find((value) => value.includes(prefix));
  if (!line) return null;
  try {
    return JSON.parse(line.slice(line.indexOf(prefix) + prefix.length));
  } catch {
    return null;
  }
}

function percentile(values, fraction) {
  const sorted = [...values].sort((left, right) => left - right);
  if (sorted.length === 0) return null;
  return sorted[Math.min(sorted.length - 1, Math.ceil(fraction * sorted.length) - 1)];
}

function semanticEvidence(run) {
  return run.benchmark?.samples.map((sample) => ({
    sampleKind: sample.sampleKind,
    sampleIndex: sample.sampleIndex,
    outputSha256: sample.outputSha256,
    outputBase64: sample.outputBase64,
    oracle: sample.oracle,
    dispatch: sample.dispatch,
  })) ?? [];
}

function runPasses(run) {
  const measured = run.benchmark?.samples.filter(
    ({ sampleKind }) => sampleKind === 'measured',
  ) ?? [];
  return run.exitCode === 0
    && !run.timedOut
    && !run.outputLimitExceeded
    && !run.crashed
    && measured.length > 0
    && measured.every(({ oracle }) => oracle?.pass === true)
    && new Set(measured.map(({ outputSha256 }) => outputSha256)).size === 1;
}

function summarizeLane(runs) {
  const measuredDurations = runs.flatMap((run) => (
    run.benchmark?.samples
      .filter(({ sampleKind }) => sampleKind === 'measured')
      .map(({ durationMs }) => durationMs) ?? []
  ));
  const processDurations = runs.map(({ durationMs }) => durationMs);
  return {
    cleanProcessRuns: runs.length,
    successes: runs.filter(runPasses).length,
    failures: runs.filter((run) => !runPasses(run)).length,
    crashes: runs.filter(({ crashed }) => crashed).length,
    hangs: runs.filter(({ timedOut }) => timedOut).length,
    timeouts: runs.filter(({ timedOut }) => timedOut).length,
    peakProcessTreeRssBytes: Math.max(
      0,
      ...runs.map(({ peakProcessTreeRssBytes }) => peakProcessTreeRssBytes),
    ),
    selectedOperationSamples: measuredDurations.length,
    selectedOperationLatencyMs: {
      p50: percentile(measuredDurations, 0.50),
      p95: percentile(measuredDurations, 0.95),
      p99: percentile(measuredDurations, 0.99),
    },
    cleanProcessLatencyMs: {
      p50: percentile(processDurations, 0.50),
      p95: percentile(processDurations, 0.95),
      p99: percentile(processDurations, 0.99),
    },
  };
}

async function probeProvider(options, lane, outDir, hostHardware) {
  const runtimeDir = resolve(outDir, 'runtime', `${lane.id}-probe`);
  await mkdir(runtimeDir, { recursive: true });
  const result = await runProcess(process.execPath, [providerProbePath], {
    cwd: options.upstream,
    env: providerEnvironment(lane, options.upstream, runtimeDir),
    timeoutMs: options.timeoutMs,
  });
  const prefix = 'DOE_UMAP_PROVIDER_PROBE=';
  const line = result.stdout.split('\n').find((value) => value.includes(prefix));
  let identity = null;
  try {
    if (line) identity = JSON.parse(line.slice(line.indexOf(prefix) + prefix.length));
  } catch {
    identity = null;
  }
  const identityText = JSON.stringify(identity ?? {}).toLowerCase();
  const softwareRenderer = /llvmpipe|swiftshader|software renderer|software-renderer/.test(identityText);
  return {
    ...result,
    identity,
    identityMatches: identity?.provider?.id === lane.provider
      && identity?.provider?.modulePath === lane.modulePath,
    softwareRenderer,
    hardwareEligible: result.exitCode === 0
      && identity?.adapter !== null
      && !softwareRenderer
      && hostHardware.physicalGpuEligible,
  };
}

async function executeLaneProcess(options, lane, outDir, index, replay = false) {
  const suffix = replay ? 'replay' : String(index + 1);
  const runtimeDir = resolve(outDir, 'runtime', lane.id, suffix);
  await mkdir(runtimeDir, { recursive: true });
  const result = await runProcess(
    process.execPath,
    [
      resolve(options.upstream, 'node_modules/vitest/vitest.mjs'),
      'run',
      '--config',
      configPath,
      '--reporter=verbose',
    ],
    {
      cwd: options.upstream,
      env: providerEnvironment(lane, options.upstream, runtimeDir),
      timeoutMs: options.timeoutMs,
    },
  );
  return {
    laneId: lane.id,
    provider: lane.provider,
    cleanProcessIndex: replay ? null : index + 1,
    replay,
    ...result,
    benchmark: parseBenchmarkMarker(result.stdout),
  };
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const outDir = resolve(repoRoot, 'bench/out/external-projects/umap-gpu', options.runId);
  await mkdir(outDir, { recursive: true });
  const gitResult = await runProcess('git', ['rev-parse', 'HEAD'], {
    cwd: options.upstream,
    env: process.env,
    timeoutMs: options.timeoutMs,
  });
  const commit = gitResult.stdout.trim();
  if (commit !== expectedCommit) throw new Error(`unexpected umap-gpu commit: ${commit}`);

  const requireFromUpstream = createRequire(
    pathToFileURL(resolve(options.upstream, 'package.json')),
  );
  const ambientModule = requireFromUpstream.resolve('webgpu');
  const pinnedModule = resolve(dirname(ambientModule), 'index.js');
  const lanes = [
    { id: 'I0', provider: 'dawn-node-webgpu', modulePath: ambientModule, evidenceMode: 'ambient' },
    { id: 'I1', provider: 'dawn-node-webgpu', modulePath: pinnedModule, evidenceMode: 'pinned' },
    { id: 'W0', provider: 'dawn-node-webgpu', modulePath: pinnedModule, evidenceMode: 'governed' },
    { id: 'D0', provider: 'doe-gpu', modulePath: resolve(repoRoot, 'packages/doe-gpu/src/index.js'), evidenceMode: 'governed' },
  ];
  await Promise.all(lanes.map(({ modulePath }) => access(modulePath)));

  const host = {
    platform: process.platform,
    architecture: process.arch,
    node: process.version,
    ...await inspectHostHardware(),
  };
  const laneEvidence = {};
  for (const lane of lanes) {
    const probe = await probeProvider(options, lane, outDir, host);
    const runs = [];
    for (let index = 0; index < options.cleanProcessRuns; index += 1) {
      const run = await executeLaneProcess(options, lane, outDir, index);
      runs.push(run);
      process.stdout.write(`[${lane.id}] process ${index + 1}: ${runPasses(run) ? 'PASS' : 'FAIL'}\n`);
    }
    laneEvidence[lane.id] = {
      contract: lane,
      probe,
      runs,
      summary: summarizeLane(runs),
    };
  }

  const replays = {};
  for (const laneId of ['W0', 'D0']) {
    const lane = lanes.find(({ id }) => id === laneId);
    const replay = await executeLaneProcess(options, lane, outDir, 0, true);
    const expected = semanticEvidence(laneEvidence[laneId].runs[0]);
    const actual = semanticEvidence(replay);
    replays[laneId] = {
      status: runPasses(replay) && JSON.stringify(expected) === JSON.stringify(actual)
        ? 'pass'
        : 'fail',
      expectedSha256: sha256Text(JSON.stringify(expected)),
      actualSha256: sha256Text(JSON.stringify(actual)),
      run: replay,
    };
  }

  const w0Latency = laneEvidence.W0.summary.selectedOperationLatencyMs;
  const d0Latency = laneEvidence.D0.summary.selectedOperationLatencyMs;
  const speedup = {
    p50: w0Latency.p50 / d0Latency.p50,
    p95: w0Latency.p95 / d0Latency.p95,
    p99: w0Latency.p99 / d0Latency.p99,
  };
  const allLanesPass = Object.values(laneEvidence).every(({ probe, summary }) => (
    probe.hardwareEligible
    && probe.identityMatches
    && summary.failures === 0
  ));
  const replaysPass = Object.values(replays).every(({ status }) => status === 'pass');
  const materialPerformanceWin = allLanesPass
    && replaysPass
    && speedup.p50 >= 1.10
    && speedup.p95 >= 1.10;
  const outputIdentities = Object.fromEntries(Object.entries(laneEvidence).map(
    ([laneId, evidence]) => [laneId, [
      ...new Set(evidence.runs.flatMap((run) => (
        run.benchmark?.samples
          .filter(({ sampleKind }) => sampleKind === 'measured')
          .map(({ outputSha256 }) => outputSha256) ?? []
      ))),
    ]],
  ));
  const generatedAt = new Date().toISOString();
  const raw = {
    schemaVersion: 1,
    artifactKind: 'umap-gpu-sgd-governed-benchmark',
    generatedAt,
    actorId: 'umap-gpu',
    harnessId: 'sgd-benchmark',
    upstream: {
      repositoryUrl: 'https://github.com/Achuttarsing/umap-gpu',
      commit,
      licenseIdentifier: 'MIT',
    },
    host,
    immutableInputs: {
      inputs: { path: 'bench/external-projects/umap-gpu/sgd-benchmark.inputs.json', sha256: await sha256(inputPath) },
      oracle: { path: 'bench/external-projects/umap-gpu/sgd-benchmark.oracle.md', sha256: await sha256(oraclePath) },
      workload: { path: 'bench/external-projects/umap-gpu/sgd-benchmark.workload.test.ts', sha256: await sha256(workloadPath) },
      config: { path: 'bench/external-projects/umap-gpu/vitest-sgd-benchmark.config.mjs', sha256: await sha256(configPath) },
      runner: { path: 'bench/external-projects/umap-gpu/run-sgd-benchmark.mjs', sha256: await sha256(fileURLToPath(import.meta.url)) },
      sgdImplementation: { path: 'src/gpu/sgd.ts', sha256: await sha256(resolve(options.upstream, 'src/gpu/sgd.ts')) },
      sgdShader: { path: 'src/gpu/shaders/sgd.wgsl', sha256: await sha256(resolve(options.upstream, 'src/gpu/shaders/sgd.wgsl')) },
      applyForcesShader: { path: 'src/gpu/shaders/apply-forces.wgsl', sha256: await sha256(resolve(options.upstream, 'src/gpu/shaders/apply-forces.wgsl')) },
      packageLock: { path: 'package-lock.json', sha256: await sha256(resolve(options.upstream, 'package-lock.json')) },
    },
    contract: {
      selectedOperation: 'GPUSgd.init plus deterministic 500-epoch optimize through mapped readback and Float32Array materialization',
      minimumMaterialSpeedupRatio: 1.10,
      requireP50AndP95: true,
      exactWithinProviderReplay: true,
      crossProviderByteIdentityRequired: false,
      cleanProcessRunsPerLane: options.cleanProcessRuns,
    },
    lanes: laneEvidence,
    replays,
    comparison: {
      W0OverD0Speedup: speedup,
      outputIdentities,
      crossProviderExactOutputIdentity: JSON.stringify(outputIdentities.W0)
        === JSON.stringify(outputIdentities.D0),
      materialPerformanceWin,
    },
    decision: {
      status: allLanesPass && replaysPass ? 'terminal' : 'failed',
      correctnessEvidence: allLanesPass,
      replayEvidence: replaysPass,
      runtimeOwnershipCredit: materialPerformanceWin,
      performanceCredit: materialPerformanceWin,
      applicationPromotionCredit: false,
      releaseCredit: false,
      nextGate: materialPerformanceWin
        ? 'run-promotion-scale-reliability-installation-and-receipt-overhead-gates'
        : 'retain-exact-output-regression-and-close-frozen-performance-hypothesis',
    },
    limitations: [
      'This is one physical AMD Vulkan tuple.',
      'The harness-owned deterministic fixture exercises the unchanged upstream GPUSgd implementation and shaders; it is not the upstream random-input benchmark.',
      'Three clean processes per lane and three measured samples per process are diagnostic, not promotion-scale evidence.',
      'The governed incumbent is evidence-bound by this harness and is not an operating-system sandbox.',
      'No clean-install package, concurrency, teardown-cycle, device-loss, bounded-growth, or receipt-overhead gate ran.',
    ],
  };
  raw.sha256 = sha256Text(JSON.stringify(raw));

  const receipt = {
    schemaVersion: 1,
    artifactKind: 'umap-gpu-sgd-governed-benchmark-receipt',
    generatedAt,
    upstream: raw.upstream,
    host,
    immutableInputs: raw.immutableInputs,
    laneSummaries: Object.fromEntries(Object.entries(laneEvidence).map(
      ([laneId, evidence]) => [laneId, {
        provider: evidence.contract.provider,
        evidenceMode: evidence.contract.evidenceMode,
        identity: evidence.probe.identity,
        hardwareEligible: evidence.probe.hardwareEligible,
        summary: evidence.summary,
      }],
    )),
    replays: Object.fromEntries(Object.entries(replays).map(
      ([laneId, replay]) => [laneId, {
        status: replay.status,
        expectedSha256: replay.expectedSha256,
        actualSha256: replay.actualSha256,
      }],
    )),
    dispatch: laneEvidence.W0.runs[0].benchmark.samples[0].dispatch,
    shaderHashes: [
      raw.immutableInputs.sgdShader,
      raw.immutableInputs.applyForcesShader,
    ],
    outputIdentities,
    comparison: raw.comparison,
    decision: raw.decision,
  };

  const rawPath = resolve(outDir, 'raw-benchmark.json');
  const receiptPath = resolve(outDir, 'receipt-summary.json');
  await writeFile(rawPath, `${JSON.stringify(raw, null, 2)}\n`, { flag: 'wx' });
  await writeFile(receiptPath, `${JSON.stringify(receipt, null, 2)}\n`, { flag: 'wx' });
  process.stdout.write(`WROTE ${rawPath}\nWROTE ${receiptPath}\n`);
  if (options.requireAllPass && (!allLanesPass || !replaysPass)) process.exitCode = 1;
}

await main();

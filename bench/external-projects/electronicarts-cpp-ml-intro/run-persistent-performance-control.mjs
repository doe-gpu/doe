#!/usr/bin/env node

import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { constants as fsConstants } from 'node:fs';
import { access, mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const harnessDir = dirname(fileURLToPath(import.meta.url));
const runnerPath = fileURLToPath(import.meta.url);
const doeRoot = resolve(harnessDir, '../../..');
const upstreamRoot = resolve(
  doeRoot,
  'bench/out/external-projects/electronicarts-cpp-ml-intro/upstream',
);
const webgpuRoot = resolve(upstreamRoot, 'Demo/mnist/Gigi/out/WebGPU');
const planPath = resolve(harnessDir, 'persistent-performance-control.plan.json');
const workerPath = resolve(harnessDir, 'mnist-performance-worker.mjs');
const loaderPath = resolve(harnessDir, 'provider-loader.mjs');
const outputRoot = resolve(
  process.argv[2] ?? resolve(
    doeRoot,
    'bench/out/external-projects/electronicarts-cpp-ml-intro/persistent-performance-control-qm0-v1',
  ),
);
const coldOverride = process.env.DOE_CPP_ML_PERF_COLD_SAMPLES;
const warmupOverride = process.env.DOE_CPP_ML_PERF_WARMUP_SUITES;
const warmOverride = process.env.DOE_CPP_ML_PERF_WARM_SAMPLES;

function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

async function sha256File(path) {
  return sha256(await readFile(path));
}

function percentile(values, quantile) {
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.min(sorted.length - 1, Math.ceil(quantile * sorted.length) - 1)];
}

function summarize(values) {
  return {
    count: values.length,
    min: Math.min(...values),
    max: Math.max(...values),
    p50: percentile(values, 0.50),
    p95: percentile(values, 0.95),
    p99: percentile(values, 0.99),
  };
}

async function runProcess(command, args, { cwd, env, timeoutMs }) {
  const startedAt = performance.now();
  const child = spawn(command, args, {
    cwd,
    env,
    detached: process.platform !== 'win32',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const stdout = [];
  const stderr = [];
  let outputBytes = 0;
  let peakMemoryBytes = 0;
  let timedOut = false;
  const maxOutputBytes = 32 * 1024 * 1024;
  const collect = (target) => (chunk) => {
    outputBytes += chunk.length;
    target.push(chunk);
    if (outputBytes > maxOutputBytes && child.exitCode === null) {
      if (process.platform !== 'win32' && child.pid) process.kill(-child.pid, 'SIGKILL');
      else child.kill('SIGKILL');
    }
  };
  child.stdout.on('data', collect(stdout));
  child.stderr.on('data', collect(stderr));
  const memoryPoll = setInterval(async () => {
    try {
      const status = await readFile(`/proc/${child.pid}/status`, 'utf8');
      const match = /^VmHWM:\s+(\d+)\s+kB$/m.exec(status);
      if (match) peakMemoryBytes = Math.max(peakMemoryBytes, Number(match[1]) * 1024);
    } catch {
      // The process may exit between the poll and the read.
    }
  }, 10);
  const timer = setTimeout(() => {
    timedOut = true;
    if (process.platform !== 'win32' && child.pid) process.kill(-child.pid, 'SIGKILL');
    else child.kill('SIGKILL');
  }, timeoutMs);
  const terminal = await new Promise((resolveTerminal, reject) => {
    child.once('error', reject);
    child.once('close', (exitCode, signal) => resolveTerminal({ exitCode, signal }));
  });
  clearInterval(memoryPoll);
  clearTimeout(timer);
  return {
    ...terminal,
    timedOut,
    durationMs: Number((performance.now() - startedAt).toFixed(6)),
    peakMemoryBytes,
    outputLimitExceeded: outputBytes > maxOutputBytes,
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
      // Inaccessible render nodes cannot support physical evidence.
    }
  }
  return {
    renderNodes,
    accessibleRenderNodes,
    physicalGpuEligible: accessibleRenderNodes.length > 0,
  };
}

async function runWorker(lane, mode, counts) {
  const execution = await runProcess(process.execPath, [
    '--experimental-loader',
    loaderPath,
    workerPath,
  ], {
    cwd: webgpuRoot,
    timeoutMs: mode === 'warm' ? 1_200_000 : 120_000,
    env: {
      ...process.env,
      DOE_CPP_ML_UPSTREAM: upstreamRoot,
      DOE_CPP_ML_PERFORMANCE_MODE: mode,
      DOE_CPP_ML_WARMUP_SUITES: String(counts.warmup),
      DOE_CPP_ML_SAMPLE_SUITES: String(counts.samples),
      DOE_EXTERNAL_WEBGPU_PROVIDER: lane.provider,
      DOE_EXTERNAL_DAWN_MODULE: lane.module,
      DOE_EXTERNAL_DOE_MODULE: lane.module,
      DOE_EXTERNAL_PNGJS_MODULE: lane.pngjs,
      VK_DRIVER_FILES: '/usr/share/vulkan/icd.d/radeon_icd.json',
      VK_LOADER_LAYERS_DISABLE: '~all~',
      LANG: 'C.UTF-8',
      LC_ALL: 'C.UTF-8',
    },
  });
  let parsed = null;
  try {
    parsed = JSON.parse(execution.stdout.trim());
  } catch {
    parsed = null;
  }
  return {
    ...execution,
    stdout: undefined,
    stderrSha256: sha256(execution.stderr),
    stderr: execution.stderr,
    result: parsed,
  };
}

await mkdir(outputRoot, { recursive: false });
const plan = JSON.parse(await readFile(planPath, 'utf8'));
const result = {
  schemaVersion: 1,
  artifactKind: 'cpp-ml-persistent-performance-control-result',
  status: 'failed',
  failures: [],
  plan: { id: plan.planId, path: planPath, sha256: await sha256File(planPath) },
};

try {
  const commitExecution = await runProcess('git', ['rev-parse', 'HEAD'], {
    cwd: upstreamRoot,
    env: process.env,
    timeoutMs: 10_000,
  });
  const upstreamCommit = commitExecution.stdout.trim();
  if (commitExecution.exitCode !== 0 || upstreamCommit !== plan.upstreamCommit) {
    throw new Error(`upstream commit mismatch: ${upstreamCommit}`);
  }
  const requireFromBench = createRequire(resolve(doeRoot, 'bench/package.json'));
  const dawnModule = requireFromBench.resolve('webgpu');
  const pngjsModule = requireFromBench.resolve('pngjs');
  const lanes = {
    W0: { id: 'W0', provider: 'dawn-node-webgpu', module: dawnModule, pngjs: pngjsModule },
    D0: {
      id: 'D0',
      provider: 'doe-gpu',
      module: resolve(doeRoot, 'packages/doe-gpu/src/index.js'),
      pngjs: pngjsModule,
    },
  };
  const coldCount = Number(coldOverride ?? plan.population.coldSamplesPerProvider);
  const warmupCount = Number(warmupOverride ?? plan.population.warmupSuitesPerProvider);
  const warmCount = Number(warmOverride ?? plan.population.warmSamplesPerProvider);
  for (const [name, count, minimum] of [
    ['cold', coldCount, 1],
    ['warmup', warmupCount, 0],
    ['warm', warmCount, 1],
  ]) {
    if (!Number.isInteger(count) || count < minimum) throw new Error(`invalid ${name} count`);
  }
  const developmentOverride = coldOverride !== undefined
    || warmupOverride !== undefined
    || warmOverride !== undefined;
  const hostHardware = await inspectHostHardware();
  if (!hostHardware.physicalGpuEligible) throw new Error('no accessible physical render node');
  const generatedFiles = [
    resolve(webgpuRoot, 'Shared.js'),
    resolve(webgpuRoot, 'mnist_Module.js'),
    resolve(webgpuRoot, 'assets/Backprop_Weights.bin'),
    ...Array.from({ length: 10 }, (_, index) => resolve(webgpuRoot, `assets/${index}.png`)),
  ];
  const inputs = await Promise.all([
    planPath,
    runnerPath,
    workerPath,
    loaderPath,
    resolve(harnessDir, 'provider-dawn.mjs'),
    resolve(harnessDir, 'provider-doe.mjs'),
    ...generatedFiles,
    dawnModule,
    lanes.D0.module,
    pngjsModule,
  ].map(async (path) => ({ path, sha256: await sha256File(path) })));

  const samples = { W0: { cold: [], warm: null }, D0: { cold: [], warm: null } };
  for (let index = 0; index < coldCount; index += 1) {
    const order = index % 2 === 0 ? ['W0', 'D0'] : ['D0', 'W0'];
    for (const laneId of order) {
      samples[laneId].cold.push(await runWorker(lanes[laneId], 'cold', {
        warmup: 0,
        samples: 1,
      }));
    }
  }
  for (const laneId of ['W0', 'D0']) {
    samples[laneId].warm = await runWorker(lanes[laneId], 'warm', {
      warmup: warmupCount,
      samples: warmCount,
    });
  }

  for (const laneId of ['W0', 'D0']) {
    const laneSamples = samples[laneId];
    for (const [index, sample] of laneSamples.cold.entries()) {
      if (sample.exitCode !== 0 || sample.signal !== null || sample.timedOut
          || sample.outputLimitExceeded || sample.result?.status !== 'passed') {
        result.failures.push(`${laneId}:cold:${index}:execution`);
      }
    }
    const warm = laneSamples.warm;
    if (warm.exitCode !== 0 || warm.signal !== null || warm.timedOut
        || warm.outputLimitExceeded || warm.result?.status !== 'passed'
        || warm.result?.sampleCount !== warmCount || warm.result?.warmupCount !== warmupCount) {
      result.failures.push(`${laneId}:warm:execution`);
    }
  }
  const allOutputs = Object.fromEntries(['W0', 'D0'].map((laneId) => {
    const laneSamples = samples[laneId];
    return [laneId, [
      ...laneSamples.cold.map((sample) => sample.result?.outputSha256),
      laneSamples.warm.result?.outputSha256,
    ]];
  }));
  for (const [laneId, outputs] of Object.entries(allOutputs)) {
    if (outputs.some((value) => typeof value !== 'string') || new Set(outputs).size !== 1) {
      result.failures.push(`${laneId}:output-identity`);
    }
  }
  if (allOutputs.W0[0] !== allOutputs.D0[0]) result.failures.push('cross-lane-output-identity');

  const metrics = {};
  for (const laneId of ['W0', 'D0']) {
    metrics[laneId] = {
      cold: summarize(samples[laneId].cold.map((sample) => sample.durationMs)),
      warm: summarize(samples[laneId].warm.result?.samples?.map((sample) => sample.durationMs) ?? []),
    };
  }
  const percentiles = ['p50', 'p95', 'p99'];
  const ratios = Object.fromEntries(['cold', 'warm'].map((population) => [
    population,
    Object.fromEntries(percentiles.map((name) => [name, {
      speedup: metrics.W0[population][name] / metrics.D0[population][name],
      comparisonOverBaseline: metrics.D0[population][name] / metrics.W0[population][name],
    }])),
  ]));
  const materialPerformanceWin = ['cold', 'warm'].every((population) =>
    percentiles.every((name) => ratios[population][name].speedup >= 1.10));
  const noPerformanceRegression = ['cold', 'warm'].every((population) =>
    percentiles.every((name) => ratios[population][name].comparisonOverBaseline <= 1.05));
  const frozenPopulation = !developmentOverride
    && coldCount === plan.population.coldSamplesPerProvider
    && warmupCount === plan.population.warmupSuitesPerProvider
    && warmCount === plan.population.warmSamplesPerProvider;
  const decision = frozenPopulation && result.failures.length === 0
    && materialPerformanceWin && noPerformanceRegression
    ? 'authorize-clean-installed-promotion-scale-successor'
    : frozenPopulation && result.failures.length === 0
      ? 'reject-persistent-performance-control'
      : 'development-only-no-decision';
  Object.assign(result, {
    status: result.failures.length === 0 ? 'passed' : 'failed',
    upstreamCommit,
    developmentOverride,
    frozenPopulation,
    population: { coldCount, warmupCount, warmCount },
    hostHardware,
    inputs,
    lanes,
    samples,
    outputSha256: allOutputs.W0[0] ?? null,
    metrics,
    ratios,
    materialPerformanceWin,
    noPerformanceRegression,
    decision,
    credit: {
      publicPerformanceClaim: false,
      applicationPromotion: false,
      releaseBlocker: false,
      runtimeOwnership: decision === 'authorize-clean-installed-promotion-scale-successor'
        ? 'successor-authorized-not-granted'
        : 'none',
    },
  });
} catch (error) {
  result.failures.push(error instanceof Error ? error.message : String(error));
}

await writeFile(resolve(outputRoot, 'result.json'), `${JSON.stringify(result, null, 2)}\n`);
if (result.status !== 'passed') process.exitCode = 1;

#!/usr/bin/env node

import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptPath = fileURLToPath(import.meta.url);
const repoRoot = resolve(dirname(scriptPath), '../..');
const planPath = resolve(
  repoRoot,
  'bench/vendor-node/doppler_provider_lifecycle_control_qm0.plan.json',
);
const scenarioPath = resolve(
  repoRoot,
  'bench/vendor-node/doppler_provider_diagnostic_gemma270m_commands.json',
);
const workerPath = resolve(repoRoot, 'bench/executors/run-node-doppler-ort-bench.js');
const boundedProviderPath = resolve(
  repoRoot,
  'bench/executors/vendor-node/doppler-node-webgpu-lifecycle-provider.mjs',
);
const doeProviderPath = resolve(repoRoot, 'packages/doe-gpu/src/compute.js');
const providerContractPath = resolve(repoRoot, 'packages/doe-gpu/src/node-webgpu.js');
const workloadId = 'doppler_provider_diagnostic_gemma3_270m_prefill_64tok_decode_1tok';

const lanes = Object.freeze([
  Object.freeze({ id: 'W0', provider: 'node-webgpu' }),
  Object.freeze({ id: 'P0', provider: 'node-webgpu-bounded-lifecycle' }),
  Object.freeze({ id: 'D0', provider: 'doe' }),
]);

function parseArgs(argv) {
  const options = {
    runId: 'doppler-provider-lifecycle-control-qm0-v1',
    cleanProcessesPerLane: 3,
    processTimeoutMs: 180_000,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === '--run-id') options.runId = argv[++index];
    else if (value === '--clean-processes-per-lane') {
      options.cleanProcessesPerLane = Number.parseInt(argv[++index], 10);
    } else if (value === '--process-timeout-ms') {
      options.processTimeoutMs = Number.parseInt(argv[++index], 10);
    } else throw new Error(`unknown argument: ${value}`);
  }
  if (!/^[A-Za-z0-9._-]+$/u.test(options.runId)) {
    throw new Error('--run-id must contain only letters, numbers, dot, underscore, or hyphen');
  }
  if (!Number.isInteger(options.cleanProcessesPerLane) || options.cleanProcessesPerLane < 1) {
    throw new Error('--clean-processes-per-lane must be a positive integer');
  }
  if (!Number.isInteger(options.processTimeoutMs) || options.processTimeoutMs < 1) {
    throw new Error('--process-timeout-ms must be a positive integer');
  }
  return options;
}

function sha256Bytes(value) {
  return createHash('sha256').update(value).digest('hex');
}

async function sha256File(path) {
  return sha256Bytes(await readFile(path));
}

async function readJson(path) {
  return JSON.parse(await readFile(path, 'utf8'));
}

function tail(value, length = 65_536) {
  return value.length <= length ? value : value.slice(-length);
}

async function processTreeRssBytes(rootPid) {
  const proc = spawn('ps', ['-eo', 'pid=,ppid=,rss='], {
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  let stdout = '';
  proc.stdout.setEncoding('utf8');
  proc.stdout.on('data', (chunk) => { stdout += chunk; });
  const exitCode = await new Promise((accept) => proc.once('close', accept));
  if (exitCode !== 0) return null;
  const rows = stdout.split('\n').flatMap((line) => {
    const match = /^\s*(\d+)\s+(\d+)\s+(\d+)\s*$/u.exec(line);
    return match ? [{ pid: Number(match[1]), ppid: Number(match[2]), rssKiB: Number(match[3]) }] : [];
  });
  const children = new Map();
  for (const row of rows) {
    const current = children.get(row.ppid) ?? [];
    current.push(row.pid);
    children.set(row.ppid, current);
  }
  const descendants = new Set([rootPid]);
  const pending = [rootPid];
  while (pending.length > 0) {
    const parent = pending.pop();
    for (const child of children.get(parent) ?? []) {
      if (descendants.has(child)) continue;
      descendants.add(child);
      pending.push(child);
    }
  }
  return rows
    .filter((row) => descendants.has(row.pid))
    .reduce((sum, row) => sum + row.rssKiB * 1024, 0);
}

async function terminateProcessTree(child) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  try {
    if (process.platform === 'win32') child.kill('SIGKILL');
    else process.kill(-child.pid, 'SIGKILL');
  } catch (error) {
    if (error?.code !== 'ESRCH') throw error;
  }
}

async function runProcess(command, args, { cwd, env, timeoutMs }) {
  const started = process.hrtime.bigint();
  const child = spawn(command, args, {
    cwd,
    env,
    detached: process.platform !== 'win32',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stdout = '';
  let stderr = '';
  let peakProcessTreeRssBytes = 0;
  let memoryPollActive = false;
  let timedOut = false;
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', (chunk) => { stdout += chunk; });
  child.stderr.on('data', (chunk) => { stderr += chunk; });
  const memoryPoll = setInterval(async () => {
    if (memoryPollActive) return;
    memoryPollActive = true;
    try {
      const observed = await processTreeRssBytes(child.pid);
      if (observed !== null) {
        peakProcessTreeRssBytes = Math.max(peakProcessTreeRssBytes, observed);
      }
    } finally {
      memoryPollActive = false;
    }
  }, 100);
  const timeout = setTimeout(async () => {
    timedOut = true;
    await terminateProcessTree(child);
  }, timeoutMs);
  const termination = await new Promise((accept, reject) => {
    child.once('error', reject);
    child.once('exit', (exitCode, signal) => accept({ exitCode, signal }));
  });
  clearInterval(memoryPoll);
  clearTimeout(timeout);
  while (memoryPollActive) {
    await new Promise((accept) => setImmediate(accept));
  }
  return {
    ...termination,
    timedOut,
    durationMs: Number(process.hrtime.bigint() - started) / 1e6,
    peakProcessTreeRssBytes,
    stdoutTail: tail(stdout),
    stderrTail: tail(stderr),
  };
}

function exitCategory(processResult) {
  if (processResult.timedOut) return 'timeout';
  if (processResult.exitCode === 0 && processResult.signal === null) return 'zero';
  if (processResult.exitCode === 134 || processResult.signal === 'SIGABRT') return 'abort';
  if (processResult.signal !== null) return `signal:${processResult.signal}`;
  return `exit:${processResult.exitCode}`;
}

async function readOptionalJson(path) {
  try {
    return await readJson(path);
  } catch (error) {
    if (error?.code === 'ENOENT') return null;
    throw error;
  }
}

async function runLaneProcess(options, outDir, lane, index) {
  const processDir = resolve(outDir, 'processes', lane.id, String(index + 1));
  const runtimeDir = resolve(processDir, 'xdg-runtime');
  await Promise.all([
    mkdir(processDir, { recursive: true }),
    mkdir(runtimeDir, { recursive: true }),
  ]);
  const traceMetaPath = resolve(processDir, 'trace.meta.json');
  const traceJsonlPath = resolve(processDir, 'trace.ndjson');
  const processResult = await runProcess(process.execPath, [
    workerPath,
    '--provider', lane.provider,
    '--scenario', scenarioPath,
    '--trace-meta', traceMetaPath,
    '--trace-jsonl', traceJsonlPath,
    '--workload', workloadId,
  ], {
    cwd: repoRoot,
    env: {
      ...process.env,
      XDG_RUNTIME_DIR: runtimeDir,
    },
    timeoutMs: options.processTimeoutMs,
  });
  const trace = await readOptionalJson(traceMetaPath);
  const traceMetaSha256 = trace === null ? null : await sha256File(traceMetaPath);
  const traceJsonlSha256 = await sha256File(traceJsonlPath).catch((error) => {
    if (error?.code === 'ENOENT') return null;
    throw error;
  });
  return {
    laneId: lane.id,
    provider: lane.provider,
    cleanProcessIndex: index + 1,
    exitCategory: exitCategory(processResult),
    ...processResult,
    traceMetaPath,
    traceMetaSha256,
    traceJsonlPath,
    traceJsonlSha256,
    trace,
  };
}

function inferenceComplete(run) {
  const trace = run.trace;
  return trace?.executionSuccessCount === 1
    && trace?.resultSummary?.status === 'ok'
    && typeof trace?.resultSummary?.generatedTextSha256 === 'string'
    && typeof trace?.resultSummary?.generatedTokenIdsHash === 'string'
    && trace?.dopplerSourceTrackedClean === true
    && trace?.lifecycleEvidenceState === 'release-complete'
    && trace?.providerRelease?.released === true;
}

function boundedCleanupComplete(run) {
  const cleanup = run.trace?.providerLifecycleControl;
  return cleanup?.supported === true
    && cleanup.awaitedDeviceCount > 0
    && cleanup.destroyedDeviceCount === cleanup.awaitedDeviceCount
    && cleanup.failureCount === 0;
}

function expectedProviderIdentity(run, lane, plan) {
  if (run.trace?.executionProvider !== lane.provider) return false;
  if (run.trace?.dopplerSourceCommit !== plan.workload.sourceCommit) return false;
  if (run.trace?.modelManifestSha256 !== plan.workload.modelManifestSha256) return false;
  if (lane.id === 'P0') {
    return run.trace?.providerModuleSha256 === plan.implementation.boundedProviderSha256
      && run.trace?.incumbentProviderModuleSha256 === plan.implementation.incumbentProviderSha256;
  }
  if (lane.id === 'W0') {
    return run.trace?.providerModuleSha256 === plan.implementation.incumbentProviderSha256;
  }
  return run.trace?.providerModuleSha256 === plan.implementation.doeProviderSha256;
}

function summarizeLane(runs) {
  const categories = Object.fromEntries(
    [...new Set(runs.map((run) => run.exitCategory))]
      .sort()
      .map((category) => [category, runs.filter((run) => run.exitCategory === category).length]),
  );
  return {
    cleanProcesses: runs.length,
    exitCategories: categories,
    inferenceComplete: runs.filter(inferenceComplete).length,
    releaseComplete: runs.filter((run) => run.trace?.lifecycleEvidenceState === 'release-complete').length,
    boundedCleanupComplete: runs.filter(boundedCleanupComplete).length,
    timeouts: runs.filter((run) => run.timedOut).length,
    peakProcessTreeRssBytes: Math.max(0, ...runs.map((run) => run.peakProcessTreeRssBytes)),
  };
}

function stableOutputIdentity(allRuns) {
  const complete = allRuns.filter(inferenceComplete);
  if (complete.length !== allRuns.length) return false;
  const identities = complete.map((run) => JSON.stringify({
    text: run.trace.resultSummary.generatedTextSha256,
    tokens: run.trace.resultSummary.generatedTokenIdsHash,
  }));
  return new Set(identities).size === 1;
}

function decide(plan, results) {
  const expectedRuns = plan.workload.cleanProcessesPerLane;
  const allRuns = Object.values(results).flatMap((lane) => lane.runs);
  const commonComplete = allRuns.length === expectedRuns * lanes.length
    && allRuns.every(inferenceComplete)
    && allRuns.every((run) => expectedProviderIdentity(
      run,
      lanes.find((lane) => lane.id === run.laneId),
      plan,
    ))
    && allRuns.every((run) => !run.timedOut)
    && stableOutputIdentity(allRuns);
  if (!commonComplete) {
    return { evidenceValid: false, decision: 'invalid-evidence', runtimeOwnershipAuthorized: false };
  }
  const wRuns = results.W0.runs;
  const pRuns = results.P0.runs;
  const dRuns = results.D0.runs;
  const antecedentStable = wRuns.every((run) => run.exitCategory === 'abort');
  const wrapperClosesGap = pRuns.every((run) => run.exitCategory === 'zero')
    && pRuns.every(boundedCleanupComplete);
  const ownedPattern = antecedentStable
    && pRuns.every((run) => run.exitCategory === 'abort')
    && dRuns.every((run) => run.exitCategory === 'zero');
  if (!antecedentStable) {
    return {
      evidenceValid: true,
      decision: 'retire-unstable-incumbent-antecedent',
      runtimeOwnershipAuthorized: false,
    };
  }
  if (wrapperClosesGap) {
    return {
      evidenceValid: true,
      decision: 'reject-doe-runtime-ownership-wrapper-closes-gap',
      runtimeOwnershipAuthorized: false,
    };
  }
  if (ownedPattern) {
    return {
      evidenceValid: true,
      decision: 'authorize-larger-lifecycle-ownership-gate',
      runtimeOwnershipAuthorized: false,
    };
  }
  return {
    evidenceValid: true,
    decision: 'retire-mixed-terminal-outcome',
    runtimeOwnershipAuthorized: false,
  };
}

async function validatePlan(plan, options) {
  if (plan.planId !== 'doppler-provider-lifecycle-control-qm0-v1') {
    throw new Error(`unexpected plan id: ${plan.planId}`);
  }
  if (options.cleanProcessesPerLane !== plan.workload.cleanProcessesPerLane) {
    throw new Error('clean-process count must equal the frozen plan');
  }
  const expectedHashes = {
    scenarioSha256: await sha256File(scenarioPath),
    orchestratorSha256: await sha256File(scriptPath),
    workerSha256: await sha256File(workerPath),
    boundedProviderSha256: await sha256File(boundedProviderPath),
    doeProviderSha256: await sha256File(doeProviderPath),
    providerContractSha256: await sha256File(providerContractPath),
  };
  for (const [field, actual] of Object.entries(expectedHashes)) {
    const expected = field === 'scenarioSha256'
      ? plan.workload[field]
      : plan.implementation[field];
    if (expected !== actual) {
      throw new Error(`${field} mismatch: expected ${expected}, got ${actual}`);
    }
  }
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const plan = await readJson(planPath);
  await validatePlan(plan, options);
  const outDir = resolve(repoRoot, 'bench/out', options.runId);
  await mkdir(outDir, { recursive: false });
  const results = {};
  for (const lane of lanes) {
    const runs = [];
    for (let index = 0; index < options.cleanProcessesPerLane; index += 1) {
      const run = await runLaneProcess(options, outDir, lane, index);
      runs.push(run);
      process.stdout.write(`${lane.id} process ${index + 1}: ${run.exitCategory}\n`);
    }
    results[lane.id] = { summary: summarizeLane(runs), runs };
  }
  const verdict = decide(plan, results);
  const artifact = {
    schemaVersion: 1,
    artifactKind: 'doe-doppler-provider-lifecycle-control-result',
    generatedAt: new Date().toISOString(),
    plan: { path: planPath, sha256: await sha256File(planPath) },
    implementation: {
      orchestrator: { path: scriptPath, sha256: await sha256File(scriptPath) },
      worker: { path: workerPath, sha256: await sha256File(workerPath) },
      boundedProvider: { path: boundedProviderPath, sha256: await sha256File(boundedProviderPath) },
    },
    options,
    verdict,
    credit: {
      performance: false,
      runtimeOwnership: false,
      promotion: false,
      release: false,
    },
    results,
  };
  const resultPath = resolve(outDir, 'result.json');
  await writeFile(resultPath, `${JSON.stringify(artifact, null, 2)}\n`, 'utf8');
  process.stdout.write(`${verdict.decision}\n${resultPath}\n`);
  if (!verdict.evidenceValid) process.exitCode = 1;
}

if (resolve(process.argv[1] ?? '') === scriptPath) {
  main().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.stack : String(error)}\n`);
    process.exitCode = 1;
  });
}

export {
  boundedCleanupComplete,
  decide,
  exitCategory,
  inferenceComplete,
  stableOutputIdentity,
};

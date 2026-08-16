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
  'bench/vendor-node/doppler_provider_logit_divergence_qm0.plan.json',
);
const workerPath = resolve(repoRoot, 'bench/executors/run-node-doppler-ort-bench.js');
const sharedPath = resolve(repoRoot, 'bench/executors/vendor-node/shared.js');
const incumbentPath = resolve(
  repoRoot,
  '../doppler/.worktrees/doe-provider-compare-e6e8be4a/node_modules/webgpu/index.js',
);
const doeProviderPath = resolve(repoRoot, 'packages/doe-gpu/src/compute.js');
const workloadId = 'doppler_provider_logit_divergence_gemma3_270m_prefill_64tok_decode_1tok';
const lanes = Object.freeze([
  Object.freeze({ id: 'W0', provider: 'node-webgpu' }),
  Object.freeze({ id: 'D0', provider: 'doe' }),
]);

function sha256Bytes(value) {
  return createHash('sha256').update(value).digest('hex');
}

async function sha256File(path) {
  return sha256Bytes(await readFile(path));
}

async function readJson(path) {
  return JSON.parse(await readFile(path, 'utf8'));
}

function parseArgs(argv) {
  const options = {
    runId: 'doppler-provider-logit-divergence-qm0-v1',
    processTimeoutMs: 180_000,
  };
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === '--run-id') options.runId = argv[++index];
    else if (argv[index] === '--process-timeout-ms') {
      options.processTimeoutMs = Number.parseInt(argv[++index], 10);
    } else throw new Error(`unknown argument: ${argv[index]}`);
  }
  if (!/^[A-Za-z0-9._-]+$/u.test(options.runId)) throw new Error('invalid --run-id');
  if (!Number.isInteger(options.processTimeoutMs) || options.processTimeoutMs < 1) {
    throw new Error('--process-timeout-ms must be a positive integer');
  }
  return options;
}

async function terminate(child) {
  try {
    if (process.platform === 'win32') child.kill('SIGKILL');
    else process.kill(-child.pid, 'SIGKILL');
  } catch (error) {
    if (error?.code !== 'ESRCH') throw error;
  }
}

async function runProcess(command, args, { cwd, env, timeoutMs }) {
  const child = spawn(command, args, {
    cwd,
    env,
    detached: process.platform !== 'win32',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stdout = '';
  let stderr = '';
  let timedOut = false;
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', (chunk) => { stdout += chunk; });
  child.stderr.on('data', (chunk) => { stderr += chunk; });
  const timeout = setTimeout(async () => {
    timedOut = true;
    await terminate(child);
  }, timeoutMs);
  const termination = await new Promise((accept, reject) => {
    child.once('error', reject);
    child.once('exit', (exitCode, signal) => accept({ exitCode, signal }));
  });
  clearTimeout(timeout);
  return {
    ...termination,
    timedOut,
    stdoutTail: stdout.slice(-65_536),
    stderrTail: stderr.slice(-65_536),
  };
}

function naturalPostReleaseFailure(run) {
  return run.exitCode === 134 || ['SIGABRT', 'SIGSEGV'].includes(run.signal);
}

async function runLane(options, outDir, plan, lane) {
  const laneDir = resolve(outDir, lane.id);
  const runtimeDir = resolve(laneDir, 'xdg-runtime');
  await Promise.all([
    mkdir(laneDir, { recursive: true }),
    mkdir(runtimeDir, { recursive: true }),
  ]);
  const traceMetaPath = resolve(laneDir, 'trace.meta.json');
  const traceJsonlPath = resolve(laneDir, 'trace.ndjson');
  const processResult = await runProcess(process.execPath, [
    workerPath,
    '--provider', lane.provider,
    '--scenario', resolve(repoRoot, plan.workload.scenario),
    '--trace-meta', traceMetaPath,
    '--trace-jsonl', traceJsonlPath,
    '--workload', workloadId,
  ], {
    cwd: repoRoot,
    env: { ...process.env, XDG_RUNTIME_DIR: runtimeDir },
    timeoutMs: options.processTimeoutMs,
  });
  const trace = await readJson(traceMetaPath);
  return {
    laneId: lane.id,
    provider: lane.provider,
    ...processResult,
    traceMetaPath,
    traceMetaSha256: await sha256File(traceMetaPath),
    traceJsonlPath,
    traceJsonlSha256: await sha256File(traceJsonlPath),
    trace,
  };
}

function transcript(run) {
  return run.trace?.resultSummary?.referenceTranscript ?? null;
}

function firstStep(run) {
  return transcript(run)?.logits?.steps?.[0] ?? null;
}

function selectedToken(run) {
  return transcript(run)?.tokens?.ids?.[0] ?? null;
}

function adjudicate(plan, results) {
  const w = results.W0;
  const d = results.D0;
  const wt = transcript(w);
  const dt = transcript(d);
  const ws = firstStep(w);
  const ds = firstStep(d);
  const common = !w.timedOut
    && !d.timedOut
    && w.trace?.executionSuccessCount === 1
    && d.trace?.executionSuccessCount === 1
    && w.trace?.lifecycleEvidenceState === 'release-complete'
    && d.trace?.lifecycleEvidenceState === 'release-complete'
    && naturalPostReleaseFailure(w)
    && d.exitCode === 0
    && d.signal === null
    && w.trace?.dopplerSourceCommit === plan.workload.sourceCommit
    && d.trace?.dopplerSourceCommit === plan.workload.sourceCommit
    && w.trace?.modelManifestSha256 === plan.workload.modelManifestSha256
    && d.trace?.modelManifestSha256 === plan.workload.modelManifestSha256
    && w.trace?.providerModuleSha256 === plan.implementation.incumbentProviderSha256
    && d.trace?.providerModuleSha256 === plan.implementation.doeProviderSha256
    && wt?.prompt?.hash === dt?.prompt?.hash
    && wt?.prompt?.tokenIdsHash === dt?.prompt?.tokenIdsHash
    && wt?.prompt?.tokenCount === dt?.prompt?.tokenCount
    && wt?.logits?.mode === 'sha256-per-step'
    && dt?.logits?.mode === 'sha256-per-step'
    && wt.logits.steps.length === 1
    && dt.logits.steps.length === 1
    && ws.elementCount === ds.elementCount
    && ws.inputTokenCount === ds.inputTokenCount
    && ws.top?.[0]?.tokenId === selectedToken(w)
    && ds.top?.[0]?.tokenId === selectedToken(d);
  if (!common) {
    return { evidenceValid: false, boundary: 'invalid-evidence', correctnessAssigned: false };
  }
  const logitsIdentical = ws.digest === ds.digest;
  const selectedTokensIdentical = selectedToken(w) === selectedToken(d);
  let boundary = 'no-divergence';
  if (!logitsIdentical && !selectedTokensIdentical) boundary = 'predictor-or-earlier-execution';
  else if (logitsIdentical && !selectedTokensIdentical) boundary = 'sampling-or-token-selection';
  else if (!logitsIdentical) boundary = 'logits-differ-token-stable';
  return {
    evidenceValid: true,
    boundary,
    logitsIdentical,
    selectedTokensIdentical,
    correctnessAssigned: false,
    authorizeOperationMismatchLocalization: boundary === 'predictor-or-earlier-execution',
  };
}

async function validatePlan(plan) {
  const checks = {
    orchestratorSha256: await sha256File(scriptPath),
    workerSha256: await sha256File(workerPath),
    sharedSummarySha256: await sha256File(sharedPath),
    incumbentProviderSha256: await sha256File(incumbentPath),
    doeProviderSha256: await sha256File(doeProviderPath),
  };
  for (const [field, actual] of Object.entries(checks)) {
    if (plan.implementation[field] !== actual) {
      throw new Error(`${field} mismatch: expected ${plan.implementation[field]}, got ${actual}`);
    }
  }
  const scenarioSha256 = await sha256File(resolve(repoRoot, plan.workload.scenario));
  if (scenarioSha256 !== plan.workload.scenarioSha256) throw new Error('scenario hash mismatch');
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const plan = await readJson(planPath);
  await validatePlan(plan);
  const outDir = resolve(repoRoot, 'bench/out/external-projects/doppler', options.runId);
  await mkdir(outDir, { recursive: false });
  const results = {};
  for (const lane of lanes) {
    results[lane.id] = await runLane(options, outDir, plan, lane);
    process.stdout.write(`${lane.id}: trace captured\n`);
  }
  const verdict = adjudicate(plan, results);
  const artifact = {
    schemaVersion: 1,
    artifactKind: 'doe-doppler-provider-logit-divergence-result',
    generatedAt: new Date().toISOString(),
    plan: { path: planPath, sha256: await sha256File(planPath) },
    implementation: { path: scriptPath, sha256: await sha256File(scriptPath) },
    verdict,
    results,
    credit: {
      correctProvider: 'unassigned',
      performance: false,
      runtimeOwnership: false,
      promotion: false,
      release: false,
    },
  };
  const resultPath = resolve(outDir, 'result.json');
  await writeFile(resultPath, `${JSON.stringify(artifact, null, 2)}\n`, 'utf8');
  process.stdout.write(`${verdict.boundary}\n${resultPath}\n`);
  if (!verdict.evidenceValid) process.exitCode = 1;
}

if (resolve(process.argv[1] ?? '') === scriptPath) {
  main().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.stack : String(error)}\n`);
    process.exitCode = 1;
  });
}

export { adjudicate };

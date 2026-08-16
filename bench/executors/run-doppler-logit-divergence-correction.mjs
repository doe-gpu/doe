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
  'bench/vendor-node/doppler_provider_logit_divergence_qm1.plan.json',
);
const workerPath = resolve(repoRoot, 'bench/executors/run-node-doppler-ort-bench.js');
const sharedPath = resolve(repoRoot, 'bench/executors/vendor-node/shared.js');
const boundedProviderPath = resolve(
  repoRoot,
  'bench/executors/vendor-node/doppler-node-webgpu-lifecycle-provider.mjs',
);
const workloadId = 'doppler_provider_logit_divergence_gemma3_270m_prefill_64tok_decode_1tok';

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
    runId: 'doppler-provider-logit-divergence-qm1-v1',
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
  const timeout = setTimeout(() => {
    timedOut = true;
    try {
      if (process.platform === 'win32') child.kill('SIGKILL');
      else process.kill(-child.pid, 'SIGKILL');
    } catch (error) {
      if (error?.code !== 'ESRCH') throw error;
    }
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

function transcript(run) {
  return run.trace?.resultSummary?.referenceTranscript ?? null;
}

function firstStep(run) {
  return transcript(run)?.logits?.steps?.[0] ?? null;
}

function selectedToken(run) {
  return transcript(run)?.tokens?.ids?.[0] ?? null;
}

async function verifyReusedRun(run) {
  const metaBytes = await readFile(run.traceMetaPath);
  const jsonlBytes = await readFile(run.traceJsonlPath);
  return sha256Bytes(metaBytes) === run.traceMetaSha256
    && sha256Bytes(jsonlBytes) === run.traceJsonlSha256
    && JSON.stringify(JSON.parse(metaBytes.toString('utf8'))) === JSON.stringify(run.trace);
}

export function adjudicate(plan, q0, p0, reusedRawValid) {
  const w0 = q0.results?.W0;
  const d0 = q0.results?.D0;
  const wt = transcript(w0);
  const pt = transcript(p0);
  const dt = transcript(d0);
  const ws = firstStep(w0);
  const ps = firstStep(p0);
  const ds = firstStep(d0);
  const p0Complete = p0.timedOut === false
    && p0.exitCode === 0
    && p0.signal === null
    && p0.trace?.executionSuccessCount === 1
    && p0.trace?.lifecycleEvidenceState === 'release-complete'
    && p0.trace?.providerRelease?.released === true
    && p0.trace?.providerLifecycleControl?.supported === true
    && p0.trace.providerLifecycleControl.awaitedDeviceCount > 0
    && p0.trace.providerLifecycleControl.destroyedDeviceCount
      === p0.trace.providerLifecycleControl.awaitedDeviceCount
    && p0.trace.providerLifecycleControl.failureCount === 0
    && p0.trace?.providerModuleSha256 === plan.implementation.boundedProviderSha256
    && p0.trace?.incumbentProviderModuleSha256 === plan.implementation.incumbentProviderSha256;
  const incumbentContinuity = pt?.prompt?.hash === wt?.prompt?.hash
    && pt?.prompt?.tokenIdsHash === wt?.prompt?.tokenIdsHash
    && selectedToken(p0) === selectedToken(w0)
    && ps?.digest === ws?.digest
    && ps?.top?.[0]?.tokenId === ws?.top?.[0]?.tokenId;
  const comparable = reusedRawValid
    && p0Complete
    && incumbentContinuity
    && pt?.prompt?.hash === dt?.prompt?.hash
    && pt?.prompt?.tokenIdsHash === dt?.prompt?.tokenIdsHash
    && ps?.elementCount === ds?.elementCount
    && ps?.inputTokenCount === ds?.inputTokenCount
    && ps?.top?.[0]?.tokenId === selectedToken(p0)
    && ds?.top?.[0]?.tokenId === selectedToken(d0);
  if (!comparable) {
    return {
      evidenceValid: false,
      boundary: 'invalid-evidence',
      correctnessAssigned: false,
    };
  }
  const logitsIdentical = ps.digest === ds.digest;
  const selectedTokensIdentical = selectedToken(p0) === selectedToken(d0);
  const boundary = !logitsIdentical && !selectedTokensIdentical
    ? 'predictor-or-earlier-execution'
    : logitsIdentical && !selectedTokensIdentical
      ? 'sampling-or-token-selection'
      : !logitsIdentical
        ? 'logits-differ-token-stable'
        : 'no-divergence';
  return {
    evidenceValid: true,
    boundary,
    logitsIdentical,
    selectedTokensIdentical,
    incumbentContinuity,
    correctnessAssigned: false,
    authorizeOperationMismatchLocalization: boundary === 'predictor-or-earlier-execution',
  };
}

async function validatePlan(plan) {
  const paths = {
    orchestratorSha256: scriptPath,
    workerSha256: workerPath,
    sharedSummarySha256: sharedPath,
    boundedProviderSha256: boundedProviderPath,
  };
  for (const [field, path] of Object.entries(paths)) {
    const actual = await sha256File(path);
    if (actual !== plan.implementation[field]) {
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
  const q0Path = resolve(repoRoot, plan.predecessor.result);
  const q0Sha256 = await sha256File(q0Path);
  if (q0Sha256 !== plan.predecessor.resultSha256) throw new Error('q0 result hash mismatch');
  const q0 = await readJson(q0Path);
  const reusedRawValid = await verifyReusedRun(q0.results.W0)
    && await verifyReusedRun(q0.results.D0);
  const outDir = resolve(repoRoot, 'bench/out/external-projects/doppler', options.runId);
  const runtimeDir = resolve(outDir, 'P0', 'xdg-runtime');
  await Promise.all([
    mkdir(resolve(outDir, 'P0'), { recursive: true }),
    mkdir(runtimeDir, { recursive: true }),
  ]);
  const traceMetaPath = resolve(outDir, 'P0', 'trace.meta.json');
  const traceJsonlPath = resolve(outDir, 'P0', 'trace.ndjson');
  const processResult = await runProcess(process.execPath, [
    workerPath,
    '--provider', 'node-webgpu-bounded-lifecycle',
    '--scenario', resolve(repoRoot, plan.workload.scenario),
    '--trace-meta', traceMetaPath,
    '--trace-jsonl', traceJsonlPath,
    '--workload', workloadId,
  ], {
    cwd: repoRoot,
    env: { ...process.env, XDG_RUNTIME_DIR: runtimeDir },
    timeoutMs: options.processTimeoutMs,
  });
  const p0 = {
    laneId: 'P0',
    ...processResult,
    traceMetaPath,
    traceMetaSha256: await sha256File(traceMetaPath),
    traceJsonlPath,
    traceJsonlSha256: await sha256File(traceJsonlPath),
    trace: await readJson(traceMetaPath),
  };
  const verdict = adjudicate(plan, q0, p0, reusedRawValid);
  const artifact = {
    schemaVersion: 1,
    artifactKind: 'doe-doppler-provider-logit-divergence-correction-result',
    generatedAt: new Date().toISOString(),
    plan: { path: planPath, sha256: await sha256File(planPath) },
    implementation: { path: scriptPath, sha256: await sha256File(scriptPath) },
    predecessor: { path: q0Path, sha256: q0Sha256, reusedRawValid },
    verdict,
    comparison: {
      q0W0: q0.results.W0.trace.resultSummary.referenceTranscript,
      P0: p0.trace.resultSummary.referenceTranscript,
      q0D0: q0.results.D0.trace.resultSummary.referenceTranscript,
    },
    p0,
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

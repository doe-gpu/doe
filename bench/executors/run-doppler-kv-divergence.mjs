#!/usr/bin/env node

import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptPath = fileURLToPath(import.meta.url);
const repoRoot = resolve(dirname(scriptPath), '../..');
const planPath = resolve(repoRoot, 'bench/vendor-node/doppler_provider_kv_divergence_qm0.plan.json');
const workerPath = resolve(repoRoot, 'bench/executors/run-node-doppler-ort-bench.js');
const sharedPath = resolve(repoRoot, 'bench/executors/vendor-node/shared.js');
const boundedProviderPath = resolve(
  repoRoot,
  'bench/executors/vendor-node/doppler-node-webgpu-lifecycle-provider.mjs',
);
const workloadId = 'doppler_provider_kv_divergence_gemma3_270m_prefill_64tok_decode_1tok';
const lanes = Object.freeze([
  Object.freeze({ id: 'P0', provider: 'node-webgpu-bounded-lifecycle' }),
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
  const options = { runId: 'doppler-provider-kv-divergence-qm0-v1', processTimeoutMs: 180_000 };
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

async function runLane(options, outDir, plan, lane) {
  const laneDir = resolve(outDir, lane.id);
  const runtimeDir = resolve(laneDir, 'xdg-runtime');
  await Promise.all([mkdir(laneDir, { recursive: true }), mkdir(runtimeDir, { recursive: true })]);
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
  return {
    laneId: lane.id,
    provider: lane.provider,
    ...processResult,
    traceMetaPath,
    traceMetaSha256: await sha256File(traceMetaPath),
    traceJsonlPath,
    traceJsonlSha256: await sha256File(traceJsonlPath),
    trace: await readJson(traceMetaPath),
  };
}

function transcript(run) {
  return run.trace?.resultSummary?.referenceTranscript ?? null;
}

function firstLogitStep(run) {
  return transcript(run)?.logits?.steps?.[0] ?? null;
}

function kvLayers(run) {
  return transcript(run)?.kvCache?.byteDigests ?? null;
}

function selectedToken(run) {
  return transcript(run)?.tokens?.ids?.[0] ?? null;
}

function geometryMatches(left, right) {
  return left.layer === right.layer
    && left.seqLen === right.seqLen
    && left.keyBytes === right.keyBytes
    && left.valueBytes === right.valueBytes;
}

export function adjudicate(plan, predecessor, results) {
  const p = results.P0;
  const d = results.D0;
  const pt = transcript(p);
  const dt = transcript(d);
  const ps = firstLogitStep(p);
  const ds = firstLogitStep(d);
  const pkv = kvLayers(p);
  const dkv = kvLayers(d);
  const priorP = predecessor.comparison?.P0;
  const priorD = predecessor.comparison?.q0D0;
  const pCleanup = p.trace?.providerLifecycleControl;
  const processComplete = [p, d].every((run) => (
    run.exitCode === 0
    && run.signal === null
    && run.timedOut === false
    && run.trace?.executionSuccessCount === 1
    && run.trace?.lifecycleEvidenceState === 'release-complete'
    && run.trace?.providerRelease?.released === true
  ));
  const providersMatch = p.trace?.providerModuleSha256 === plan.implementation.boundedProviderSha256
    && p.trace?.incumbentProviderModuleSha256 === plan.implementation.incumbentProviderSha256
    && d.trace?.providerModuleSha256 === plan.implementation.doeProviderSha256;
  const cleanupComplete = pCleanup?.supported === true
    && pCleanup.awaitedDeviceCount > 0
    && pCleanup.destroyedDeviceCount === pCleanup.awaitedDeviceCount
    && pCleanup.failureCount === 0;
  const predecessorStable = ps?.digest === priorP?.logits?.steps?.[0]?.digest
    && ds?.digest === priorD?.logits?.steps?.[0]?.digest
    && selectedToken(p) === priorP?.tokens?.ids?.[0]
    && selectedToken(d) === priorD?.tokens?.ids?.[0];
  const comparable = processComplete
    && providersMatch
    && cleanupComplete
    && predecessorStable
    && pt?.prompt?.hash === dt?.prompt?.hash
    && pt?.prompt?.tokenIdsHash === dt?.prompt?.tokenIdsHash
    && ps?.elementCount === ds?.elementCount
    && Array.isArray(pkv)
    && Array.isArray(dkv)
    && pkv.length > 0
    && pkv.length === dkv.length
    && pkv.every((layer, index) => geometryMatches(layer, dkv[index]));
  if (!comparable) {
    return { evidenceValid: false, boundary: 'invalid-evidence', correctnessAssigned: false };
  }
  const layerComparisons = pkv.map((layer, index) => ({
    layer: layer.layer,
    keyDigestMatches: layer.keyDigest === dkv[index].keyDigest,
    valueDigestMatches: layer.valueDigest === dkv[index].valueDigest,
    seqLen: layer.seqLen,
    keyBytes: layer.keyBytes,
    valueBytes: layer.valueBytes,
  }));
  const firstDifference = layerComparisons.find(
    (layer) => !layer.keyDigestMatches || !layer.valueDigestMatches,
  ) ?? null;
  return {
    evidenceValid: true,
    boundary: firstDifference === null
      ? 'downstream-of-retained-kv-state'
      : `at-or-before-layer-${firstDifference.layer}-kv-write`,
    firstDifferingLayer: firstDifference?.layer ?? null,
    layerComparisons,
    correctnessAssigned: false,
    authorizeOperationParityFixture: true,
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
  if (await sha256File(resolve(repoRoot, plan.workload.scenario)) !== plan.workload.scenarioSha256) {
    throw new Error('scenario hash mismatch');
  }
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const plan = await readJson(planPath);
  await validatePlan(plan);
  const predecessorPath = resolve(repoRoot, plan.predecessor.result);
  if (await sha256File(predecessorPath) !== plan.predecessor.resultSha256) {
    throw new Error('predecessor result hash mismatch');
  }
  const predecessor = await readJson(predecessorPath);
  const outDir = resolve(repoRoot, 'bench/out/external-projects/doppler', options.runId);
  await mkdir(outDir, { recursive: false });
  const results = {};
  for (const lane of lanes) {
    results[lane.id] = await runLane(options, outDir, plan, lane);
    process.stdout.write(`${lane.id}: trace captured\n`);
  }
  const verdict = adjudicate(plan, predecessor, results);
  const artifact = {
    schemaVersion: 1,
    artifactKind: 'doe-doppler-provider-kv-divergence-result',
    generatedAt: new Date().toISOString(),
    plan: { path: planPath, sha256: await sha256File(planPath) },
    implementation: { path: scriptPath, sha256: await sha256File(scriptPath) },
    predecessor: { path: predecessorPath, sha256: plan.predecessor.resultSha256 },
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

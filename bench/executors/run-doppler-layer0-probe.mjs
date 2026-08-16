#!/usr/bin/env node

import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptPath = fileURLToPath(import.meta.url);
const repoRoot = resolve(dirname(scriptPath), '../..');
const planPath = resolve(repoRoot, 'bench/vendor-node/doppler_provider_layer0_probe_qm0.plan.json');
const workerPath = resolve(repoRoot, 'bench/executors/run-node-doppler-ort-bench.js');
const workloadId = 'doppler_provider_layer0_probe_gemma3_270m_prefill_64tok_decode_1tok';
const lanes = Object.freeze([
  Object.freeze({ id: 'P0', provider: 'node-webgpu-bounded-lifecycle' }),
  Object.freeze({ id: 'D0', provider: 'doe' }),
]);

function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

async function sha256File(path) {
  return sha256(await readFile(path));
}

function parseArgs(argv) {
  const options = { runId: 'doppler-provider-layer0-probe-qm0-v1', processTimeoutMs: 180_000 };
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

function parseKeyValues(text) {
  return Object.fromEntries(text.split(', ').map((field) => {
    const separator = field.indexOf('=');
    const key = field.slice(0, separator);
    const raw = field.slice(separator + 1);
    const value = Number(raw);
    return [key, Number.isNaN(value) ? raw : value];
  }));
}

function parseProbeLine(line) {
  const match = line.match(
    /PROBE\s+(\S+)\s+stage=(\S+)\s+token=(\d+)\s+stats=\[([^\]]+)\]\s+values=\[([^\]]*)\]/u,
  );
  if (!match) return null;
  return {
    id: match[1],
    stage: match[2],
    token: Number.parseInt(match[3], 10),
    stats: parseKeyValues(match[4]),
    values: parseKeyValues(match[5]),
    line,
  };
}

async function runProcess(command, args, options) {
  const child = spawn(command, args, {
    cwd: options.cwd,
    env: options.env,
    detached: process.platform !== 'win32',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stdoutTail = '';
  let stderrTail = '';
  let stdoutLineBuffer = '';
  const probes = [];
  let timedOut = false;
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', (chunk) => {
    stdoutTail = `${stdoutTail}${chunk}`.slice(-131_072);
    const lines = `${stdoutLineBuffer}${chunk}`.split(/\r?\n/u);
    stdoutLineBuffer = lines.pop() ?? '';
    for (const line of lines) {
      const probe = parseProbeLine(line);
      if (probe) probes.push(probe);
    }
  });
  child.stderr.on('data', (chunk) => { stderrTail = `${stderrTail}${chunk}`.slice(-131_072); });
  const timer = setTimeout(() => {
    timedOut = true;
    try {
      if (process.platform === 'win32') child.kill('SIGKILL');
      else process.kill(-child.pid, 'SIGKILL');
    } catch (error) {
      if (error?.code !== 'ESRCH') throw error;
    }
  }, options.timeoutMs);
  const termination = await new Promise((accept, reject) => {
    child.once('error', reject);
    child.once('exit', (exitCode, signal) => accept({ exitCode, signal }));
  });
  clearTimeout(timer);
  const finalProbe = parseProbeLine(stdoutLineBuffer);
  if (finalProbe) probes.push(finalProbe);
  return { ...termination, timedOut, probes, stdoutTail, stderrTail };
}

function probeMatches(left, right, tolerance) {
  if (!left || !right || left.stage !== right.stage || left.token !== right.token) return false;
  if (left.stats.valid !== right.stats.valid
      || left.stats.nan !== right.stats.nan
      || left.stats.inf !== right.stats.inf
      || left.stats.zero !== right.stats.zero) return false;
  const keys = new Set([...Object.keys(left.values), ...Object.keys(right.values)]);
  return [...keys].every((key) => (
    Number.isFinite(left.values[key])
    && Number.isFinite(right.values[key])
    && Math.abs(left.values[key] - right.values[key]) <= tolerance
  ));
}

function adjudicate(plan, results) {
  const p = results.P0;
  const d = results.D0;
  const processComplete = [p, d].every((lane) => (
    lane.exitCode === 0
    && lane.signal === null
    && lane.timedOut === false
    && lane.trace?.executionSuccessCount === 1
    && lane.trace?.lifecycleEvidenceState === 'release-complete'
  ));
  const probeComparisons = plan.stageOrder.map((stage) => {
    const pProbe = p.probes.find((probe) => probe.stage === stage) ?? null;
    const dProbe = d.probes.find((probe) => probe.stage === stage) ?? null;
    return {
      stage,
      p0: pProbe,
      d0: dProbe,
      bothObserved: pProbe !== null && dProbe !== null,
      matches: probeMatches(pProbe, dProbe, plan.acceptance.sampleAbsoluteTolerance),
    };
  });
  const observed = probeComparisons.filter((comparison) => comparison.bothObserved);
  const firstDifference = observed.find((comparison) => !comparison.matches) ?? null;
  const requiredObserved = plan.requiredStages.every((stage) => (
    probeComparisons.find((comparison) => comparison.stage === stage)?.bothObserved === true
  ));
  return {
    evidenceValid: processComplete && requiredObserved,
    processComplete,
    requiredObserved,
    probeComparisons,
    firstDifferingStage: firstDifference?.stage ?? null,
    boundary: !processComplete || !requiredObserved
      ? 'invalid-evidence'
      : firstDifference === null
        ? 'downstream-of-observed-layer0-stages'
        : `at-or-before-layer0-${firstDifference.stage}`,
    authorize: processComplete && requiredObserved
      ? ['production-buffer-or-command-state-minimization']
      : [],
  };
}

async function validatePlan(plan) {
  for (const [field, input] of Object.entries(plan.inputs)) {
    const path = resolve(repoRoot, input.path);
    const actual = await sha256File(path);
    if (actual !== input.sha256) {
      throw new Error(`${field} hash mismatch: expected ${input.sha256}, got ${actual}`);
    }
  }
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const planBytes = await readFile(planPath);
  const plan = JSON.parse(planBytes.toString('utf8'));
  await validatePlan(plan);
  const outDir = resolve(repoRoot, 'bench/out/external-projects/doppler', options.runId);
  await mkdir(outDir, { recursive: false });
  const results = {};
  for (const lane of lanes) {
    const laneDir = resolve(outDir, lane.id);
    const runtimeDir = resolve(laneDir, 'xdg-runtime');
    await Promise.all([mkdir(laneDir, { recursive: true }), mkdir(runtimeDir, { recursive: true })]);
    const traceMetaPath = resolve(laneDir, 'trace.meta.json');
    const traceJsonlPath = resolve(laneDir, 'trace.ndjson');
    const processResult = await runProcess(process.execPath, [
      workerPath,
      '--provider', lane.provider,
      '--scenario', resolve(repoRoot, plan.inputs.scenario.path),
      '--trace-meta', traceMetaPath,
      '--trace-jsonl', traceJsonlPath,
      '--workload', workloadId,
    ], {
      cwd: repoRoot,
      env: { ...process.env, XDG_RUNTIME_DIR: runtimeDir },
      timeoutMs: options.processTimeoutMs,
    });
    results[lane.id] = {
      laneId: lane.id,
      provider: lane.provider,
      ...processResult,
      traceMetaPath,
      trace: processResult.exitCode === 0
        ? JSON.parse(await readFile(traceMetaPath, 'utf8'))
        : null,
    };
    await writeFile(resolve(laneDir, 'probes.json'), `${JSON.stringify(processResult.probes, null, 2)}\n`);
  }
  const decision = adjudicate(plan, results);
  const result = {
    schema: 'doe.doppler-provider-layer0-probe/v1',
    candidateId: plan.candidateId,
    status: decision.evidenceValid ? 'pass' : 'fail',
    evidenceClass: 'diagnostic-correctness-localization',
    plan: { path: planPath, sha256: sha256(planBytes) },
    decision,
    lanes: Object.fromEntries(Object.entries(results).map(([id, lane]) => [id, {
      provider: lane.provider,
      exitCode: lane.exitCode,
      signal: lane.signal,
      timedOut: lane.timedOut,
      probeCount: lane.probes.length,
      traceMetaPath: lane.traceMetaPath,
      generatedTokenIds: lane.trace?.resultSummary?.referenceTranscript?.tokens?.ids ?? null,
      stdoutTail: lane.stdoutTail,
      stderrTail: lane.stderrTail,
    }])),
  };
  const resultPath = resolve(outDir, 'result.json');
  await writeFile(resultPath, `${JSON.stringify(result, null, 2)}\n`);
  process.stdout.write(`${JSON.stringify({
    resultPath,
    status: result.status,
    boundary: decision.boundary,
    firstDifferingStage: decision.firstDifferingStage,
  })}\n`);
  if (!decision.evidenceValid) process.exitCode = 1;
}

main().catch((error) => {
  process.stderr.write(`${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
  process.exitCode = 1;
});

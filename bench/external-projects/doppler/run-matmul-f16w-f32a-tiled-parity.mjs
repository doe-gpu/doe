#!/usr/bin/env node

import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptPath = fileURLToPath(import.meta.url);
const repoRoot = resolve(dirname(scriptPath), '../../..');
const planPath = resolve(
  repoRoot,
  'bench/external-projects/doppler/matmul-f16w-f32a-tiled-parity-qm0.plan.json',
);

function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

async function sha256File(path) {
  return sha256(await readFile(path));
}

function parseArgs(argv) {
  const options = {
    runId: 'doppler-matmul-f16w-f32a-tiled-parity-qm0-v1',
    processTimeoutMs: 120_000,
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

async function runProcess(command, args, options) {
  const child = spawn(command, args, {
    cwd: options.cwd,
    env: options.env,
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
  return {
    ...termination,
    timedOut,
    stdoutTail: stdout.slice(-65_536),
    stderrTail: stderr.slice(-65_536),
  };
}

async function validatePlan(plan) {
  for (const [field, entry] of Object.entries(plan.inputs)) {
    const path = resolve(repoRoot, entry.path);
    const actual = await sha256File(path);
    if (actual !== entry.sha256) {
      throw new Error(`${field} hash mismatch: expected ${entry.sha256}, got ${actual}`);
    }
  }
}

function compareCases(plan, p0, d0) {
  if (p0.length !== d0.length || p0.length !== plan.cases.length) {
    throw new Error('lane case count does not match the frozen plan');
  }
  return plan.cases.map((expectedCase, index) => {
    const p = p0[index];
    const d = d0[index];
    const identityMatches = p.id === expectedCase.id
      && d.id === expectedCase.id
      && JSON.stringify(p.shape) === JSON.stringify(expectedCase.shape)
      && JSON.stringify(d.shape) === JSON.stringify(expectedCase.shape)
      && JSON.stringify(p.inputs) === JSON.stringify(d.inputs);
    const outputHashesMatch = p.output.outputSha256 === d.output.outputSha256;
    const pNumericallyValid = p.output.nonFiniteCount === 0
      && p.output.zeroCount < p.output.elementCount
      && p.output.maxSampleAbsoluteError <= plan.acceptance.maxSampleAbsoluteError;
    const dNumericallyValid = d.output.nonFiniteCount === 0
      && d.output.zeroCount < d.output.elementCount
      && d.output.maxSampleAbsoluteError <= plan.acceptance.maxSampleAbsoluteError;
    return {
      id: expectedCase.id,
      identityMatches,
      outputHashesMatch,
      p0: {
        outputSha256: p.output.outputSha256,
        zeroCount: p.output.zeroCount,
        nonFiniteCount: p.output.nonFiniteCount,
        maxAbs: p.output.maxAbs,
        maxSampleAbsoluteError: p.output.maxSampleAbsoluteError,
        numericallyValid: pNumericallyValid,
      },
      d0: {
        outputSha256: d.output.outputSha256,
        zeroCount: d.output.zeroCount,
        nonFiniteCount: d.output.nonFiniteCount,
        maxAbs: d.output.maxAbs,
        maxSampleAbsoluteError: d.output.maxSampleAbsoluteError,
        numericallyValid: dNumericallyValid,
      },
      pass: identityMatches && outputHashesMatch && pNumericallyValid && dNumericallyValid,
    };
  });
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const planBytes = await readFile(planPath);
  const plan = JSON.parse(planBytes.toString('utf8'));
  await validatePlan(plan);
  const outDir = resolve(repoRoot, 'bench/out/external-projects/doppler', options.runId);
  await mkdir(outDir, { recursive: false });
  const workerPath = resolve(repoRoot, plan.inputs.worker.path);
  const lanes = {};
  for (const provider of ['P0', 'D0']) {
    const outputPath = resolve(outDir, `${provider}.json`);
    const runtimeDir = resolve(outDir, `${provider}-xdg-runtime`);
    await mkdir(runtimeDir, { recursive: true });
    const processResult = await runProcess(process.execPath, [
      workerPath,
      '--provider', provider,
      '--output', outputPath,
    ], {
      cwd: repoRoot,
      env: { ...globalThis.process.env, XDG_RUNTIME_DIR: runtimeDir },
      timeoutMs: options.processTimeoutMs,
    });
    lanes[provider] = {
      process: processResult,
      outputPath,
      outputSha256: processResult.exitCode === 0 ? await sha256File(outputPath) : null,
      result: processResult.exitCode === 0
        ? JSON.parse(await readFile(outputPath, 'utf8'))
        : null,
    };
  }
  const processesPass = Object.values(lanes).every((lane) => (
    lane.process.exitCode === 0
    && lane.process.signal === null
    && lane.process.timedOut === false
  ));
  const providerInputsMatch = processesPass
    && lanes.P0.result.shader.sha256 === lanes.D0.result.shader.sha256;
  const cases = providerInputsMatch
    ? compareCases(plan, lanes.P0.result.cases, lanes.D0.result.cases)
    : [];
  const pass = processesPass && providerInputsMatch && cases.every((entry) => entry.pass);
  const result = {
    schema: 'doe.doppler-matmul-f16w-f32a-tiled-parity/v1',
    candidateId: plan.candidateId,
    status: pass ? 'pass' : 'fail',
    evidenceClass: 'diagnostic-correctness-localization',
    plan: { path: planPath, sha256: sha256(planBytes) },
    processesPass,
    providerInputsMatch,
    cases,
    decision: pass
      ? 'exact-kernel-and-shape-correct;-localize-production-buffer-or-command-state'
      : 'kernel-or-provider-parity-failure',
    authorize: pass
      ? ['production-qkv-buffer-and-command-state-parity']
      : [],
    lanes: Object.fromEntries(Object.entries(lanes).map(([id, lane]) => [id, {
      process: lane.process,
      outputPath: lane.outputPath,
      outputSha256: lane.outputSha256,
    }])),
  };
  const resultPath = resolve(outDir, 'result.json');
  await writeFile(resultPath, `${JSON.stringify(result, null, 2)}\n`);
  process.stdout.write(`${JSON.stringify({ resultPath, status: result.status, decision: result.decision })}\n`);
  if (!pass) process.exitCode = 1;
}

main().catch((error) => {
  process.stderr.write(`${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
  process.exitCode = 1;
});

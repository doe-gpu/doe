import { spawn } from 'node:child_process';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { tmpdir } from 'node:os';
import { performance } from 'node:perf_hooks';
import { parseArgs } from 'node:util';

import {
  applyDebugStepLimit,
  buildErrorExecutionResult,
  buildUnsupportedExecutionResult,
  executePlanFile,
  providerSpec,
} from '../node-webgpu/executor.js';
import { normalizePlan } from '../node-webgpu/plan.js';

function parseCliArgs(defaultProvider) {
  return parseArgs({
    options: {
      provider: { type: 'string', default: defaultProvider },
      plan: { type: 'string', default: '' },
      'trace-meta': { type: 'string', default: '' },
      'trace-jsonl': { type: 'string', default: '' },
      workload: { type: 'string', default: '' },
      'dry-run': { type: 'boolean', default: false },
      'prepared-session': { type: 'boolean', default: false },
      'skip-dispatch-prewarm': { type: 'boolean', default: false },
      'resident-buffer-loads': { type: 'boolean', default: false },
      'debug-boundaries': { type: 'boolean', default: false },
      'step-limit': { type: 'string', default: '' },
      'command-repeat': { type: 'string', default: '' },
    },
  }).values;
}

function validateArgs(args, { usageCommand, providerUsage }) {
  if (!args.plan || !args['trace-meta'] || !args['trace-jsonl'] || !args.workload) {
    throw new Error(
      `usage: ${usageCommand} --provider <${providerUsage}> --plan <path> `
      + '--trace-meta <path> --trace-jsonl <path> --workload <id> '
      + '[--prepared-session] [--skip-dispatch-prewarm] [--resident-buffer-loads]',
    );
  }
}

function parseCommandRepeat(commandRepeat) {
  const normalized = typeof commandRepeat === 'string' ? commandRepeat.trim() : '';
  if (!normalized) {
    return 1;
  }
  const parsed = Number(normalized);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    throw new Error(`expected a positive integer for --command-repeat, got: ${commandRepeat}`);
  }
  return parsed;
}

function parseStepLimit(stepLimit) {
  const normalized = typeof stepLimit === 'string' ? stepLimit.trim() : '';
  if (!normalized) {
    return 0;
  }
  const parsed = Number(normalized);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    throw new Error(`expected a positive integer for --step-limit, got: ${stepLimit}`);
  }
  return parsed;
}

async function loadNormalizedPlan(planPath, stepLimit) {
  const payload = JSON.parse(await readFile(planPath, 'utf8'));
  const normalized = normalizePlan(payload);
  return applyDebugStepLimit(normalized, stepLimit);
}

async function writeArtifacts(traceMetaPath, traceJsonlPath, meta, rows) {
  await mkdir(dirname(traceMetaPath), { recursive: true });
  await writeFile(traceMetaPath, `${JSON.stringify(meta)}\n`, 'utf8');
  await mkdir(dirname(traceJsonlPath), { recursive: true });
  const payload = rows.length > 0
    ? `${rows.map((row) => JSON.stringify(row)).join('\n')}\n`
    : '';
  await writeFile(traceJsonlPath, payload, 'utf8');
}

async function traceMetaRecordsTerminalOutcome(traceMetaPath) {
  try {
    const payload = JSON.parse(await readFile(traceMetaPath, 'utf8'));
    return (
      Number(payload.executionErrorCount ?? 0) > 0
      || Number(payload.executionUnsupportedCount ?? 0) > 0
      || Number(payload.executionSkippedCount ?? 0) > 0
    );
  } catch {
    return false;
  }
}

async function readTraceMeta(traceMetaPath) {
  try {
    return JSON.parse(await readFile(traceMetaPath, 'utf8'));
  } catch {
    return null;
  }
}

export function successfulRunUnexpectedStderr(stderr) {
  return String(stderr ?? '')
    .split(/\r?\n/u)
    .map((line) => line.trim())
    .filter((line) => {
      if (!line) {
        return false;
      }
      if (isKnownSuccessfulRunStderr(line)) {
        return false;
      }
      try {
        const payload = JSON.parse(line);
        return payload?.kind !== 'package_webgpu_debug';
      } catch {
        return true;
      }
    });
}

function isKnownSuccessfulRunStderr(line) {
  return /^Warning: maxDynamic(?:Uniform|Storage)BuffersPerPipelineLayout artificially reduced from \d+ to \d+ to fit dynamic offset allocation limit\.$/u.test(line);
}

function childArgv(args, cliPath, overrides = {}) {
  const resolved = {
    provider: overrides.provider ?? args.provider,
    plan: overrides.plan ?? args.plan,
    traceMeta: overrides.traceMeta ?? args['trace-meta'],
    traceJsonl: overrides.traceJsonl ?? args['trace-jsonl'],
    workload: overrides.workload ?? args.workload,
    dryRun: overrides.dryRun ?? Boolean(args['dry-run']),
    preparedSession: overrides.preparedSession ?? Boolean(args['prepared-session']),
    skipDispatchPrewarm: overrides.skipDispatchPrewarm
      ?? Boolean(args['skip-dispatch-prewarm']),
    residentBufferLoads: overrides.residentBufferLoads ?? Boolean(args['resident-buffer-loads']),
    debugBoundaries: overrides.debugBoundaries ?? Boolean(args['debug-boundaries']),
    stepLimit: overrides.stepLimit ?? args['step-limit'],
    commandRepeat: overrides.commandRepeat ?? args['command-repeat'],
  };
  const argv = [
    cliPath,
    '--provider', resolved.provider,
    '--plan', resolved.plan,
    '--trace-meta', resolved.traceMeta,
    '--trace-jsonl', resolved.traceJsonl,
    '--workload', resolved.workload,
  ];
  if (resolved.dryRun) {
    argv.push('--dry-run');
  }
  if (resolved.preparedSession) {
    argv.push('--prepared-session');
  }
  if (resolved.skipDispatchPrewarm) {
    argv.push('--skip-dispatch-prewarm');
  }
  if (resolved.residentBufferLoads) {
    argv.push('--resident-buffer-loads');
  }
  if (resolved.debugBoundaries) {
    argv.push('--debug-boundaries');
  }
  if (resolved.stepLimit) {
    argv.push('--step-limit', String(resolved.stepLimit));
  }
  if (resolved.commandRepeat) {
    argv.push('--command-repeat', String(resolved.commandRepeat));
  }
  return argv;
}

async function probeUnsupportedBringup(args, { cliPath, childEnv, runtimeHost }) {
  const scratchDir = await mkdtemp(join(tmpdir(), `doe-${runtimeHost}-webgpu-probe-`));
  const probeMetaPath = join(scratchDir, 'probe.meta.json');
  const probeJsonlPath = join(scratchDir, 'probe.ndjson');
  try {
    const child = spawn(
      process.execPath,
      childArgv(args, cliPath, {
        traceMeta: probeMetaPath,
        traceJsonl: probeJsonlPath,
        stepLimit: parseStepLimit(args['step-limit']) > 0 ? args['step-limit'] : '1',
      }),
      {
        cwd: process.cwd(),
        env: {
          ...process.env,
          [childEnv]: '1',
        },
        stdio: ['ignore', 'ignore', 'ignore'],
      },
    );
    await new Promise((resolve, reject) => {
      child.on('error', reject);
      child.on('close', () => resolve());
    });
    const probeMeta = await readTraceMeta(probeMetaPath);
    return Boolean(
      probeMeta
      && Number(probeMeta.executionUnsupportedCount ?? 0) > 0
      && Number(probeMeta.executionErrorCount ?? 0) === 0,
    );
  } catch {
    return false;
  } finally {
    await rm(scratchDir, { recursive: true, force: true });
  }
}

async function writeSupervisorFailureArtifacts(
  args,
  started_at_ms,
  unsupported,
  { runtimeHost },
) {
  let normalizedPlan = null;
  try {
    normalizedPlan = await loadNormalizedPlan(args.plan, parseStepLimit(args['step-limit']));
  } catch {
    normalizedPlan = null;
  }
  const spec = providerSpec(args.provider, runtimeHost);
  const result = unsupported
    ? buildUnsupportedExecutionResult({
        normalizedPlan,
        spec,
        preparedSession: Boolean(args['prepared-session']),
        residentBufferLoads: Boolean(args['resident-buffer-loads']),
        hostInputReadTotalNs: 0,
        hostInputParseTotalNs: 0,
        hostWorkloadPrepareTotalNs: 0,
        hostExecutorInitTotalNs: 0,
        processWallMs: performance.now() - started_at_ms,
        workloadId: args.workload,
        planPath: args.plan,
      })
    : buildErrorExecutionResult({
        normalizedPlan,
        spec,
        preparedSession: Boolean(args['prepared-session']),
        residentBufferLoads: Boolean(args['resident-buffer-loads']),
        hostInputReadTotalNs: 0,
        hostInputParseTotalNs: 0,
        hostWorkloadPrepareTotalNs: 0,
        hostExecutorInitTotalNs: 0,
        processWallMs: performance.now() - started_at_ms,
        workloadId: args.workload,
        planPath: args.plan,
      });
  await writeArtifacts(args['trace-meta'], args['trace-jsonl'], result.meta, result.rows);
}

async function runWorker(args, { runtimeHost }) {
  await executePlanFile({
    planPath: args.plan,
    workloadId: args.workload,
    provider: args.provider,
    runtimeHost,
    traceMetaPath: args['trace-meta'],
    traceJsonlPath: args['trace-jsonl'],
    dryRun: Boolean(args['dry-run']),
    preparedSession: Boolean(args['prepared-session']),
    prewarmDispatchBindings: Boolean(args['prepared-session'])
      && !Boolean(args['skip-dispatch-prewarm']),
    residentBufferLoads: Boolean(args['resident-buffer-loads']),
    debugBoundaries: Boolean(args['debug-boundaries']),
    stepLimit: args['step-limit'] ? Number(args['step-limit']) : 0,
    commandRepeat: parseCommandRepeat(args['command-repeat']),
  });
}

function exitWorkerSuccessfully() {
  process.exit(0);
}

async function runWithSupervisor(args, {
  cliPath,
  childEnv,
  label,
  runtimeHost,
}) {
  const started_at_ms = performance.now();
  const child = spawn(
    process.execPath,
    [cliPath, ...process.argv.slice(2)],
    {
      cwd: process.cwd(),
      env: {
        ...process.env,
        [childEnv]: '1',
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    },
  );

  let stdout = '';
  let stderr = '';

  child.stdout.on('data', (chunk) => {
    const text = chunk.toString();
    stdout += text;
    process.stdout.write(text);
  });
  child.stderr.on('data', (chunk) => {
    const text = chunk.toString();
    stderr += text;
    process.stderr.write(text);
  });

  const outcome = await new Promise((resolve, reject) => {
    child.on('error', reject);
    child.on('close', (code, signal) => resolve({ code, signal }));
  });

  if (outcome.code === 0) {
    const unexpectedStderr = successfulRunUnexpectedStderr(stderr);
    if (unexpectedStderr.length > 0) {
      await writeSupervisorFailureArtifacts(args, started_at_ms, false, {
        runtimeHost,
      });
      process.stderr.write(
        `${label} supervisor rejected successful child run with stderr output\n`,
      );
      process.exitCode = 1;
      return;
    }
    return;
  }

  const trace_meta_complete = await traceMetaRecordsTerminalOutcome(args['trace-meta']);
  if (trace_meta_complete) {
    const signal_suffix = outcome.signal ? `, signal=${outcome.signal}` : '';
    process.stderr.write(
      `${label} supervisor accepted child teardown failure after complete terminal trace-meta `
      + `(code=${outcome.code ?? 'null'}${signal_suffix})\n`,
    );
    process.exitCode = 0;
    return;
  }
  if (!trace_meta_complete) {
    const unsupported = await probeUnsupportedBringup(args, {
      cliPath,
      childEnv,
      runtimeHost,
    });
    await writeSupervisorFailureArtifacts(args, started_at_ms, unsupported, {
      runtimeHost,
    });
    const signal_suffix = outcome.signal ? `, signal=${outcome.signal}` : '';
    process.stderr.write(
      `${label} supervisor captured child failure before trace-meta emission `
      + `(code=${outcome.code ?? 'null'}${signal_suffix})\n`,
    );
    if (unsupported) {
      process.stderr.write(
        `${label} supervisor classified failure as unsupported via bounded bring-up probe\n`,
      );
    }
    if (!stderr.trim() && !stdout.trim()) {
      process.stderr.write(`${label} supervisor: child exited without stdout/stderr\n`);
    }
  }

  process.exitCode = outcome.code && outcome.code > 0 ? outcome.code : 1;
}

export async function runPackageWebGpuPlanCli({
  runtimeHost,
  defaultProvider,
  cliPath,
  childEnv,
  label,
  providerUsage,
  usageCommand,
}) {
  const args = parseCliArgs(defaultProvider);
  validateArgs(args, { usageCommand, providerUsage });
  if (process.env[childEnv] === '1') {
    await runWorker(args, { runtimeHost });
    exitWorkerSuccessfully();
  }
  await runWithSupervisor(args, {
    cliPath,
    childEnv,
    label,
    runtimeHost,
  });
}

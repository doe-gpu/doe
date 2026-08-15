import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawn } from 'node:child_process';

const harnessDir = dirname(fileURLToPath(import.meta.url));
const doeRoot = resolve(harnessDir, '../../..');
const upstreamRoot = resolve(
  doeRoot,
  'bench/out/external-projects/holoscript-snn-webgpu/upstream',
);
const upstreamPackageDir = resolve(upstreamRoot, 'packages/snn-webgpu');
const upstreamCoreDir = resolve(upstreamRoot, 'packages/core');
const inputs = JSON.parse(await readFile(resolve(harnessDir, 'inputs.json'), 'utf8'));
const harness = JSON.parse(await readFile(resolve(harnessDir, 'tropical-spmv.harness.json'), 'utf8'));
const outputPath = process.argv[2] ?? resolve(
  doeRoot,
  'bench/out/external-projects/holoscript-snn-webgpu/manual/raw-matrix.json',
);
const requireFromUpstream = createRequire(pathToFileURL(resolve(upstreamPackageDir, 'package.json')));
const dawnModule = requireFromUpstream.resolve('webgpu');
const doeModule = resolve(doeRoot, 'packages/doe-gpu/src/index.js');
const ambientDawnModule = process.env.DOE_EXTERNAL_AMBIENT_DAWN_MODULE?.trim() || null;

function percentile(values, fraction) {
  const sorted = [...values].sort((a, b) => a - b);
  if (sorted.length === 0) return 0;
  return sorted[Math.min(sorted.length - 1, Math.ceil(fraction * sorted.length) - 1)];
}

function runCleanProcess(laneId, provider, receiptMode = 'enabled', selectedDawnModule = dawnModule) {
  return new Promise((resolveRun) => {
    const child = spawn(
      process.execPath,
      [
        '--no-warnings',
        '--experimental-loader',
        resolve(harnessDir, 'provider-loader.mjs'),
        resolve(harnessDir, 'run-workload.mjs'),
      ],
      {
        cwd: upstreamPackageDir,
        env: {
          ...process.env,
          DOE_EXTERNAL_WEBGPU_PROVIDER: provider,
          DOE_EXTERNAL_DAWN_MODULE: selectedDawnModule,
          DOE_EXTERNAL_DOE_MODULE: doeModule,
          DOE_EXTERNAL_UPSTREAM_PACKAGE_DIR: upstreamPackageDir,
          DOE_EXTERNAL_UPSTREAM_CORE_DIR: upstreamCoreDir,
          DOE_EXTERNAL_INPUT_PATH: resolve(harnessDir, 'inputs.json'),
          DOE_EXTERNAL_RECEIPT_MODE: receiptMode,
        },
        stdio: ['ignore', 'pipe', 'pipe'],
      },
    );
    const stdout = [];
    const stderr = [];
    let timedOut = false;
    const startedAt = performance.now();
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill('SIGKILL');
    }, 120_000);
    child.stdout.on('data', (chunk) => stdout.push(chunk));
    child.stderr.on('data', (chunk) => stderr.push(chunk));
    child.on('close', (code, signal) => {
      clearTimeout(timer);
      const stdoutText = Buffer.concat(stdout).toString('utf8').trim();
      const stderrText = Buffer.concat(stderr).toString('utf8').trim();
      let result = null;
      let parseError = '';
      if (stdoutText) {
        try {
          result = JSON.parse(stdoutText.split('\n').at(-1));
        } catch (error) {
          parseError = String(error?.message ?? error);
        }
      }
      resolveRun({
        laneId,
        provider,
        providerModulePath: provider === 'dawn-node-webgpu' ? selectedDawnModule : doeModule,
        receiptMode,
        elapsedMs: performance.now() - startedAt,
        exitCode: code,
        signal,
        timedOut,
        stdout: stdoutText,
        stderr: stderrText,
        parseError,
        result,
      });
    });
  });
}

const runs = [];
for (const [laneId, provider] of [['W0', 'dawn-node-webgpu'], ['D0', 'doe-gpu']]) {
  for (let index = 0; index < inputs.cleanProcessRuns; index += 1) {
    runs.push(await runCleanProcess(laneId, provider));
  }
}

const ownershipRuns = [...runs];
for (let index = 0; index < inputs.cleanProcessRuns; index += 1) {
  ownershipRuns.push(await runCleanProcess('I1', 'dawn-node-webgpu', 'untraced'));
}
if (ambientDawnModule) {
  for (let index = 0; index < inputs.cleanProcessRuns; index += 1) {
    ownershipRuns.push(
      await runCleanProcess('I0', 'dawn-node-webgpu', 'untraced', ambientDawnModule),
    );
  }
}

const receiptRuns = [];
for (let index = 0; index < inputs.cleanProcessRuns; index += 1) {
  const modes = index % 2 === 0 ? ['untraced', 'enabled'] : ['enabled', 'untraced'];
  for (const mode of modes) {
    receiptRuns.push(await runCleanProcess('D0', 'doe-gpu', mode));
  }
}

function ownershipLane(laneId, missingStatus = 'not-run') {
  const laneRuns = ownershipRuns.filter((run) => run.laneId === laneId);
  if (laneRuns.length === 0) {
    return {
      status: missingStatus,
      runCount: 0,
      successfulRuns: 0,
      providerModulePaths: [],
      runs: [],
    };
  }
  const successfulRuns = laneRuns.filter(
    (run) => run.exitCode === 0 && !run.timedOut && run.result,
  ).length;
  return {
    status: successfulRuns === laneRuns.length ? 'passed' : 'failed',
    runCount: laneRuns.length,
    successfulRuns,
    providerModulePaths: [...new Set(laneRuns.map((run) => run.providerModulePath))],
    runs: laneRuns,
  };
}

const ownershipPlanSha256 = createHash('sha256')
  .update(JSON.stringify(harness.runtimeOwnershipPlan))
  .digest('hex');
const ownershipLanes = {
  I0: ownershipLane('I0', 'unavailable'),
  I1: ownershipLane('I1'),
  W0: ownershipLane('W0'),
  D0: ownershipLane('D0'),
  P0: {
    status: 'not-run',
    runCount: 0,
    successfulRuns: 0,
    providerModulePaths: [],
    runs: [],
  },
};
const missingRequiredOwnershipLanes = Object.entries(ownershipLanes)
  .filter(([laneId, lane]) => (
    harness.runtimeOwnershipPlan.lanes[laneId].requirement === 'required'
    && lane.status !== 'passed'
  ))
  .map(([laneId]) => laneId);

const receiptSamples = (mode) => receiptRuns
  .filter((run) => run.receiptMode === mode && run.exitCode === 0 && run.result)
  .map((run) => run.result.receipt.workloadElapsedMs);
const untracedSamplesMs = receiptSamples('untraced');
const receiptEnabledSamplesMs = receiptSamples('enabled');

const raw = {
  schemaVersion: 1,
  artifactKind: 'holoscript-tropical-spmv-matrix',
  generatedAt: new Date().toISOString(),
  upstream: {
    repositoryUrl: 'https://github.com/brianonbased-dev/HoloScript',
    commit: '337a39a869a552c814933c587fe65b34a0a2c95d',
    licenseIdentifier: 'MIT',
  },
  host: {
    platform: process.platform,
    architecture: process.arch,
    node: process.version,
  },
  providers: {
    baseline: { id: 'dawn-node-webgpu', modulePath: dawnModule },
    comparison: { id: 'doe-gpu', modulePath: doeModule },
  },
  runs,
  receiptRuns,
  runtimeOwnership: {
    status: missingRequiredOwnershipLanes.length === 0 ? 'complete' : 'diagnostic-incomplete',
    planSha256: ownershipPlanSha256,
    claimedProperty: harness.runtimeOwnershipPlan.claimedProperty,
    missingRequiredLanes: missingRequiredOwnershipLanes,
    ambientModuleSupplied: Boolean(ambientDawnModule),
    lanes: ownershipLanes,
  },
  receiptOverhead: {
    boundary: 'complete oracle-checked workload across all topologies and measured dispatches',
    unit: 'ms',
    untracedSamplesMs,
    receiptEnabledSamplesMs,
    untracedP50: percentile(untracedSamplesMs, 0.5),
    receiptEnabledP50: percentile(receiptEnabledSamplesMs, 0.5),
  },
};
raw.sha256 = createHash('sha256').update(JSON.stringify(raw)).digest('hex');

const successfulRuns = runs.filter((run) => run.exitCode === 0 && run.result);
const receiptSummary = {
  schemaVersion: 1,
  artifactKind: 'holoscript-tropical-spmv-receipt-summary',
  generatedAt: raw.generatedAt,
  upstream: raw.upstream,
  host: raw.host,
  providers: Object.fromEntries(successfulRuns.map((run) => [
    run.provider,
    {
      provider: run.result.provider,
      adapter: run.result.adapter,
      hostRenderer: run.result.hostRenderer,
      hardwareEligible: run.result.hardwareEligible,
    },
  ])),
  shaders: [...new Set(successfulRuns.map((run) => run.result.shader.sha256))],
  dispatchShapes: [...new Set(successfulRuns.map((run) => JSON.stringify(run.result.dispatch)))].map(JSON.parse),
  synchronization: [...new Set(successfulRuns.map((run) => run.result.synchronization))],
  readback: [...new Set(successfulRuns.map((run) => run.result.readback))],
  outputIdentity: successfulRuns.map((run) => ({
    provider: run.provider,
    topologies: run.result.topologies.map((topology) => ({
      id: topology.id,
      oracleHash: topology.oracleHash,
      outputHash: topology.outputHash,
      maxDiff: topology.maxDiff,
    })),
  })),
  receiptOverhead: raw.receiptOverhead,
  runtimeOwnership: {
    status: raw.runtimeOwnership.status,
    planSha256: raw.runtimeOwnership.planSha256,
    claimedProperty: raw.runtimeOwnership.claimedProperty,
    missingRequiredLanes: raw.runtimeOwnership.missingRequiredLanes,
    lanes: Object.fromEntries(Object.entries(raw.runtimeOwnership.lanes).map(([laneId, lane]) => [
      laneId,
      {
        status: lane.status,
        runCount: lane.runCount,
        successfulRuns: lane.successfulRuns,
        providerModulePaths: lane.providerModulePaths,
      },
    ])),
  },
};

await mkdir(dirname(outputPath), { recursive: true });
await writeFile(outputPath, `${JSON.stringify(raw, null, 2)}\n`);
await writeFile(
  resolve(dirname(outputPath), 'receipt-summary.json'),
  `${JSON.stringify(receiptSummary, null, 2)}\n`,
);
process.stdout.write(`${outputPath}\n`);

if ([...ownershipRuns, ...receiptRuns].some((run) => run.exitCode !== 0 || run.timedOut || !run.result)) {
  process.exitCode = 1;
}

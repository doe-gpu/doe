import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawn } from 'node:child_process';

import { buildRuntimeOwnership } from '../../lib/runtime-ownership-matrix.mjs';

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
const outputDir = dirname(outputPath);
const requireFromUpstream = createRequire(pathToFileURL(resolve(upstreamPackageDir, 'package.json')));
const ambientDawnModule = requireFromUpstream.resolve('webgpu');
const dawnModule = resolve(dirname(ambientDawnModule), 'index.js');
const dawnPackage = JSON.parse(
  await readFile(resolve(dirname(dawnModule), 'package.json'), 'utf8'),
);
if (dawnPackage.name !== 'webgpu' || dawnPackage.version !== '0.3.10') {
  throw new Error(
    `pinned incumbent mismatch: expected webgpu@0.3.10, received ${dawnPackage.name}@${dawnPackage.version}`,
  );
}
const doeModule = resolve(doeRoot, 'packages/doe-gpu/src/index.js');

function sha256Text(value) {
  return createHash('sha256').update(value).digest('hex');
}

async function sha256File(path) {
  return createHash('sha256').update(await readFile(path)).digest('hex');
}

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

function executionEvidence(run) {
  return {
    laneId: run.laneId,
    provider: run.provider,
    providerModulePath: run.providerModulePath,
    receiptMode: run.receiptMode,
    exitCode: run.exitCode,
    signal: run.signal,
    timedOut: run.timedOut,
    parseError: run.parseError,
    result: run.result === null ? null : {
      provider: run.result.provider,
      adapter: run.result.adapter,
      hostRenderer: run.result.hostRenderer,
      hardwareEligible: run.result.hardwareEligible,
      shader: run.result.shader,
      dispatch: run.result.dispatch,
      synchronization: run.result.synchronization,
      readback: run.result.readback,
      layoutTrace: run.result.layoutTrace,
      oracle: run.result.oracle,
      topologies: run.result.topologies.map((topology) => ({
        id: topology.id,
        nnz: topology.nnz,
        oracleHash: topology.oracleHash,
        outputHash: topology.outputHash,
        maxDiff: topology.maxDiff,
      })),
    },
  };
}

async function runReceiptReplay({ laneId, provider, modulePath, sourceRun, immutableInputs }) {
  const relativeReceiptPath = `replay-receipts/${laneId}.json`;
  const receiptPath = resolve(outputDir, relativeReceiptPath);
  await mkdir(dirname(receiptPath), { recursive: true });
  const expectedEvidenceSha256 = sha256Text(JSON.stringify(executionEvidence(sourceRun)));
  const receipt = {
    schemaVersion: 1,
    artifactKind: 'holoscript-tropical-spmv-replay-receipt',
    laneId,
    provider,
    providerModulePath: modulePath,
    immutableInputs,
    expectedEvidenceSha256,
  };
  await writeFile(receiptPath, `${JSON.stringify(receipt, null, 2)}\n`);
  const loaded = JSON.parse(await readFile(receiptPath, 'utf8'));
  if (loaded.provider !== provider
    || loaded.providerModulePath !== modulePath
    || loaded.expectedEvidenceSha256 !== expectedEvidenceSha256) {
    throw new Error(`${laneId} replay receipt did not preserve the execution contract`);
  }
  const sample = await runCleanProcess(laneId, provider, 'enabled', modulePath);
  const actualEvidenceSha256 = sha256Text(JSON.stringify(executionEvidence(sample)));
  return {
    status: actualEvidenceSha256 === expectedEvidenceSha256 ? 'passed' : 'failed',
    receiptPath: relativeReceiptPath,
    receiptSha256: await sha256File(receiptPath),
    expectedEvidenceSha256,
    actualEvidenceSha256,
    sample,
  };
}

await mkdir(outputDir, { recursive: true });
const immutablePathSpecs = [
  ['repo', resolve(harnessDir, 'hardware-identity.mjs')],
  ['repo', resolve(harnessDir, 'inputs.json')],
  ['repo', resolve(harnessDir, 'oracle.md')],
  ['repo', resolve(harnessDir, 'provider-dawn.mjs')],
  ['repo', resolve(harnessDir, 'provider-doe.mjs')],
  ['repo', resolve(harnessDir, 'provider-loader.mjs')],
  ['repo', resolve(harnessDir, 'run-matrix.mjs')],
  ['repo', resolve(harnessDir, 'run-workload.mjs')],
  ['repo', resolve(harnessDir, 'tropical-spmv.harness.json')],
  ['upstream', resolve(upstreamRoot, 'pnpm-lock.yaml')],
  ['upstream', resolve(upstreamPackageDir, 'package.json')],
  ['upstream', resolve(upstreamPackageDir, 'dist/index.js')],
  ['upstream', resolve(upstreamPackageDir, 'src/shaders/tropical-graph.wgsl')],
  ['upstream', resolve(upstreamCoreDir, 'package.json')],
  ['upstream', resolve(upstreamCoreDir, 'dist/math/tropical-spmv.js')],
  ['provider-entrypoint', dawnModule],
  ['provider-entrypoint', doeModule],
  ['provider-runtime', resolve(dirname(dawnModule), 'dist/linux-x64.dawn.node')],
  ['provider-runtime', resolve(doeRoot, 'runtime/zig/zig-out/lib/libwebgpu_doe.so')],
  ['provider-runtime', resolve(doeRoot, 'runtime/zig/zig-out/share/doe-build-metadata.json')],
];
const immutableInputs = await Promise.all(immutablePathSpecs.map(async ([scope, path]) => ({
  scope,
  path: path.startsWith(`${doeRoot}/`) ? path.slice(doeRoot.length + 1) : path,
  sha256: await sha256File(path),
})));

const runs = [];
for (const [laneId, provider] of [['W0', 'dawn-node-webgpu'], ['D0', 'doe-gpu']]) {
  for (let index = 0; index < inputs.cleanProcessRuns; index += 1) {
    runs.push(await runCleanProcess(laneId, provider));
  }
}

const replays = {
  W0: await runReceiptReplay({
    laneId: 'W0',
    provider: 'dawn-node-webgpu',
    modulePath: dawnModule,
    sourceRun: runs.find((run) => run.laneId === 'W0'),
    immutableInputs,
  }),
  D0: await runReceiptReplay({
    laneId: 'D0',
    provider: 'doe-gpu',
    modulePath: doeModule,
    sourceRun: runs.find((run) => run.laneId === 'D0'),
    immutableInputs,
  }),
};
for (const run of runs) {
  run.contractComplete = replays[run.laneId].status === 'passed';
  run.constructionIssues = run.contractComplete ? [] : ['receipt replay mismatch'];
}

const ownershipRuns = [...runs];
for (let index = 0; index < inputs.cleanProcessRuns; index += 1) {
  ownershipRuns.push(await runCleanProcess('I1', 'dawn-node-webgpu', 'untraced'));
}
for (let index = 0; index < inputs.cleanProcessRuns; index += 1) {
  ownershipRuns.push(
    await runCleanProcess('I0', 'dawn-node-webgpu', 'untraced', ambientDawnModule),
  );
}

const receiptRuns = [];
for (let index = 0; index < inputs.cleanProcessRuns; index += 1) {
  const modes = index % 2 === 0 ? ['untraced', 'enabled'] : ['enabled', 'untraced'];
  for (const mode of modes) {
    receiptRuns.push(await runCleanProcess('D0', 'doe-gpu', mode));
  }
}

const ownershipPlanSha256 = createHash('sha256')
  .update(JSON.stringify(harness.runtimeOwnershipPlan))
  .digest('hex');
const runtimeOwnership = buildRuntimeOwnership({
  runs: ownershipRuns,
  plan: harness.runtimeOwnershipPlan,
  planSha256: ownershipPlanSha256,
  ambientModuleSupplied: true,
});

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
    ambient: { id: 'dawn-node-webgpu', modulePath: ambientDawnModule },
    baseline: {
      id: 'dawn-node-webgpu',
      modulePath: dawnModule,
      packageVersion: dawnPackage.version,
    },
    comparison: { id: 'doe-gpu', modulePath: doeModule },
  },
  immutableInputs,
  runs,
  receiptRuns,
  replays,
  runtimeOwnership,
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
  immutableInputs,
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
  replays: Object.fromEntries(Object.entries(replays).map(([laneId, replay]) => [
    laneId,
    {
      status: replay.status,
      receiptPath: replay.receiptPath,
      receiptSha256: replay.receiptSha256,
      expectedEvidenceSha256: replay.expectedEvidenceSha256,
      actualEvidenceSha256: replay.actualEvidenceSha256,
    },
  ])),
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

await writeFile(outputPath, `${JSON.stringify(raw, null, 2)}\n`);
await writeFile(
  resolve(dirname(outputPath), 'receipt-summary.json'),
  `${JSON.stringify(receiptSummary, null, 2)}\n`,
);
process.stdout.write(`${outputPath}\n`);

if ([...ownershipRuns, ...receiptRuns].some((run) => run.exitCode !== 0 || run.timedOut || !run.result)
  || Object.values(replays).some((replay) => replay.status !== 'passed')) {
  process.exitCode = 1;
}

#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { validateTransparentWebGPUObservation } from '../../../packages/doe-gpu/src/observe.js';

const harnessDir = dirname(fileURLToPath(import.meta.url));
const runnerPath = fileURLToPath(import.meta.url);
const doeRoot = resolve(harnessDir, '../../..');
const planPath = resolve(harnessDir, 'public-compilation-observer-qm0.plan.json');
const loaderPath = resolve(harnessDir, 'public-observer-loader.mjs');
const providerPath = resolve(harnessDir, 'public-observer-provider.mjs');
const workloadPath = resolve(harnessDir, 'semantic-oracle.mjs');
const observerPath = resolve(doeRoot, 'packages/doe-gpu/src/observe.js');
const upstreamRoot = resolve(
  process.env.DOE_WGSL_FNS_UPSTREAM
    ?? resolve(doeRoot, 'bench/out/external-projects/wgsl-fns/upstream'),
);
const outputRoot = resolve(
  process.argv[2]
    ?? resolve(
      doeRoot,
      'bench/out/external-projects/wgsl-fns/public-compilation-observer-qm0-v1',
    ),
);

function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

async function sha256File(path) {
  return sha256(await readFile(path));
}

function semanticMarker(stdout) {
  const line = stdout.split('\n')
    .find((candidate) => candidate.startsWith('DOE_WGSL_FNS_SEMANTIC_ORACLE='));
  if (!line) return null;
  return JSON.parse(line.slice(line.indexOf('=') + 1));
}

function normalizeObservation(observation) {
  return {
    shaders: observation.shaderModules.map((module) => ({
      label: module.label,
      sourceSha256: module.sourceSha256,
      sourceBytes: module.sourceBytes,
      workgroupSize: module.workgroupSize,
      creation: module.creation,
    })),
    compilationInfos: observation.compilationInfos.map((info) => ({
      status: info.status,
      messages: info.messages,
      errorName: info.errorName ?? null,
      errorMessage: info.errorMessage ?? null,
    })),
    computePipelines: observation.computePipelines.map((pipeline) => ({
      entryPoint: pipeline.entryPoint,
    })),
    commandKinds: observation.commands.map((command) => command.kind),
    dispatches: observation.dispatches.map((dispatch) => ({
      kind: dispatch.kind,
      workgroups: dispatch.workgroups ?? null,
      bindGroupCount: dispatch.bindGroups?.length ?? 0,
    })),
    submissions: observation.submissions.map((submission) => ({
      commandBufferCount: submission.commandBufferIds.length,
    })),
    synchronizations: observation.synchronizations.map((entry) => entry.kind),
    readbacks: observation.readbacks.map((readback) => ({
      bufferSize: readback.bufferSize,
      offset: readback.offset,
      size: readback.size,
      dataSha256: readback.dataSha256,
    })),
  };
}

async function runLane(laneId, providerId, modulePath) {
  const evidencePrefix = resolve(outputRoot, `${laneId}.observer`);
  const runtimeDir = resolve(outputRoot, `${laneId}.xdg`);
  await mkdir(runtimeDir, { recursive: true });
  const execution = spawnSync(
    process.execPath,
    ['--experimental-loader', loaderPath, workloadPath],
    {
      cwd: upstreamRoot,
      env: {
        ...process.env,
        DOE_EXTERNAL_WEBGPU_PROVIDER: providerId,
        DOE_EXTERNAL_WEBGPU_MODULE_PATH: modulePath,
        DOE_WGSL_FNS_OBSERVER_EVIDENCE_PATH: evidencePrefix,
        XDG_RUNTIME_DIR: runtimeDir,
      },
      encoding: 'utf8',
      maxBuffer: 16 * 1024 * 1024,
    },
  );
  const evidenceFiles = (await readdir(outputRoot))
    .filter((name) => name.startsWith(`${laneId}.observer.`) && name.endsWith('.json'));
  if (evidenceFiles.length !== 1) {
    throw new Error(`${laneId} produced ${evidenceFiles.length} observer artifacts`);
  }
  const evidencePath = resolve(outputRoot, evidenceFiles[0]);
  const worker = JSON.parse(await readFile(evidencePath, 'utf8'));
  if (worker.observations.length !== 1) {
    throw new Error(`${laneId} produced ${worker.observations.length} observations`);
  }
  const observation = worker.observations[0];
  const validation = validateTransparentWebGPUObservation(observation);
  const semantic = semanticMarker(execution.stdout);
  return {
    provider: {
      id: providerId,
      modulePath,
      moduleSha256: await sha256File(modulePath),
    },
    execution: {
      exitCode: execution.status,
      signal: execution.signal,
      stdout: execution.stdout,
      stderr: execution.stderr,
    },
    semantic,
    observerArtifact: { path: evidencePath, sha256: await sha256File(evidencePath) },
    observation,
    validation,
    normalized: normalizeObservation(observation),
  };
}

await mkdir(outputRoot, { recursive: false });
const p0ReceiptPath = resolve(
  doeRoot,
  'bench/out/external-projects/wgsl-fns/p0-webgpu-0.3.10/receipt.json',
);
const p0Receipt = JSON.parse(await readFile(p0ReceiptPath, 'utf8'));
const lanes = {
  W0: await runLane(
    'W0',
    'dawn-node-webgpu',
    resolve(doeRoot, p0Receipt.artifacts.module.path),
  ),
  D0: await runLane('D0', 'doe-gpu', resolve(doeRoot, 'packages/doe-gpu/src/index.js')),
};

const failures = [];
for (const [laneId, lane] of Object.entries(lanes)) {
  if (lane.execution.exitCode !== 0) failures.push(`${laneId}:execution-failed`);
  if (lane.validation.valid !== true) failures.push(`${laneId}:observation-invalid`);
  if (lane.semantic?.oracle?.passed !== true) failures.push(`${laneId}:oracle-failed`);
  if (lane.observation.shaderModules.length !== 1) failures.push(`${laneId}:shader-count`);
  if (lane.observation.compilationInfos.length !== 1) {
    failures.push(`${laneId}:compilation-info-count`);
  } else {
    const info = lane.observation.compilationInfos[0];
    if (info.status !== 'returned') failures.push(`${laneId}:compilation-info-failed`);
    if (info.shaderModuleId !== lane.observation.shaderModules[0]?.id) {
      failures.push(`${laneId}:compilation-info-module-mismatch`);
    }
    if (info.messages.some((message) => message.type === 'error')) {
      failures.push(`${laneId}:unexpected-compilation-error`);
    }
  }
  if (lane.observation.summary.dispatchCount !== 1
      || lane.observation.summary.readbackCount !== 1) {
    failures.push(`${laneId}:program-evidence-incomplete`);
  }
}
const normalizedIdentity = Object.fromEntries(Object.entries(lanes).map(([laneId, lane]) => [
  laneId,
  sha256(JSON.stringify(lane.normalized)),
]));
const outputIdentity = Object.fromEntries(Object.entries(lanes).map(([laneId, lane]) => [
  laneId,
  lane.semantic?.oracle?.actualSha256 ?? null,
]));
if (normalizedIdentity.W0 !== normalizedIdentity.D0) {
  failures.push('cross-lane-program-evidence-mismatch');
}
if (outputIdentity.W0 !== outputIdentity.D0) failures.push('cross-lane-output-mismatch');

const result = {
  schemaVersion: 1,
  artifactKind: 'wgsl-fns-public-compilation-observer-admission',
  status: failures.length === 0 ? 'passed' : 'failed',
  failures,
  plan: { path: planPath, sha256: await sha256File(planPath) },
  upstream: {
    root: upstreamRoot,
    commit: spawnSync('git', ['rev-parse', 'HEAD'], {
      cwd: upstreamRoot,
      encoding: 'utf8',
    }).stdout.trim(),
  },
  inputs: {
    runner: { path: runnerPath, sha256: await sha256File(runnerPath) },
    loader: { path: loaderPath, sha256: await sha256File(loaderPath) },
    provider: { path: providerPath, sha256: await sha256File(providerPath) },
    workload: { path: workloadPath, sha256: await sha256File(workloadPath) },
    observer: { path: observerPath, sha256: await sha256File(observerPath) },
    p0Receipt: { path: p0ReceiptPath, sha256: await sha256File(p0ReceiptPath) },
  },
  lanes,
  identities: { normalized: normalizedIdentity, output: outputIdentity },
  credit: {
    publicCompilationDiagnosticAdmission: failures.length === 0,
    runtimeOwnershipDecisionReopened: false,
    runtimeOwnershipCredit: false,
    performanceCredit: false,
    promotionCredit: false,
    releaseCredit: false,
  },
};
result.sha256 = sha256(JSON.stringify(result));
const resultPath = resolve(outputRoot, 'result.json');
await writeFile(resultPath, `${JSON.stringify(result, null, 2)}\n`);
process.stdout.write(`${result.status.toUpperCase()} ${resultPath}\n`);
if (failures.length > 0) process.exitCode = 1;

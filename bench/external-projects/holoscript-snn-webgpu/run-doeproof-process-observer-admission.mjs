#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const harnessDir = dirname(fileURLToPath(import.meta.url));
const runnerPath = fileURLToPath(import.meta.url);
const doeRoot = resolve(harnessDir, '../../..');
const planPath = resolve(harnessDir, 'doeproof-process-observer-admission-qm2.plan.json');
const controlRunnerPath = resolve(harnessDir, 'run-doeproof-cli-integration.mjs');
const cliPath = resolve(doeRoot, 'packages/doe-gpu/bin/doe-proof-node.js');
const observerPath = resolve(doeRoot, 'packages/doe-gpu/src/observe.js');
const processPath = resolve(doeRoot, 'packages/doe-gpu/src/node-webgpu-process.js');
const loaderPath = resolve(doeRoot, 'packages/doe-gpu/src/node-webgpu-loader.js');
const cliImplementationPath = resolve(
  doeRoot,
  'packages/doe-gpu/src/node-webgpu-process-cli.js',
);
const outputRoot = resolve(
  process.argv[2]
    ?? resolve(
      doeRoot,
      'bench/out/external-projects/holoscript-snn-webgpu'
        + '/doeproof-process-observer-admission-qm2-v1',
    ),
);

function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

async function sha256File(path) {
  return sha256(await readFile(path));
}

function execute(args) {
  const result = spawnSync(process.execPath, [cliPath, ...args], {
    cwd: doeRoot,
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
  });
  let output = null;
  try {
    output = result.stdout.trim() ? JSON.parse(result.stdout) : null;
  } catch {
    output = null;
  }
  return {
    args,
    exitCode: result.status,
    signal: result.signal,
    stderr: result.stderr.trim(),
    output,
  };
}

function normalizeProgram(observation) {
  return {
    shaders: observation.shaderModules.map((module) => ({
      label: module.label,
      sourceSha256: module.sourceSha256,
      sourceBytes: module.sourceBytes,
      workgroupSize: module.workgroupSize,
      creation: module.creation,
      errorName: module.errorName ?? null,
    })),
    computePipelines: observation.computePipelines.map((pipeline) => ({
      entryPoint: pipeline.entryPoint,
    })),
    renderPipelines: observation.renderPipelines.map((pipeline) => ({
      vertexEntryPoint: pipeline.vertexEntryPoint,
      fragmentEntryPoint: pipeline.fragmentEntryPoint,
    })),
    commandKinds: observation.commands.map((command) => command.kind),
    dispatches: observation.dispatches.map((dispatch) => ({
      kind: dispatch.kind,
      workgroups: dispatch.workgroups ?? null,
      bindGroupCount: dispatch.bindGroups?.length ?? 0,
    })),
    draws: observation.draws.map((draw) => ({ kind: draw.kind, args: draw.args })),
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

await mkdir(outputRoot, { recursive: false });
const controlRoot = resolve(outputRoot, 'unobserved-control');
const control = spawnSync(process.execPath, [controlRunnerPath, controlRoot], {
  cwd: doeRoot,
  env: {
    ...process.env,
    DOE_DOEPROOF_INTEGRATION_PROFILE: 'node-permission-read-only',
  },
  encoding: 'utf8',
  maxBuffer: 16 * 1024 * 1024,
});
let controlResult = null;
try {
  controlResult = JSON.parse(await readFile(resolve(controlRoot, 'result.json'), 'utf8'));
} catch {
  // The controller process result remains available when no artifact was produced.
}

const lanes = {};
for (const laneId of ['W0', 'D0']) {
  const controlContractPath = resolve(controlRoot, `${laneId}.contract.json`);
  const contract = JSON.parse(await readFile(controlContractPath, 'utf8'));
  contract.observeProgram = {
    metadata: {
      application: 'holoscript-tropical-spmv',
      lane: laneId,
      contract: 'doeproof-process-observer-admission-qm2',
    },
  };
  for (const runtimeFile of contract.runtimeFiles ?? []) {
    runtimeFile.sha256 = `sha256:${await sha256File(runtimeFile.path)}`;
  }
  const contractPath = resolve(outputRoot, `${laneId}.contract.json`);
  const artifactPath = resolve(outputRoot, `${laneId}.artifact.json`);
  await writeFile(contractPath, `${JSON.stringify(contract, null, 2)}\n`);
  const run = execute(['run', contractPath, '--out', artifactPath]);
  const verify = execute(['verify', artifactPath]);
  const inspect = execute(['inspect', artifactPath]);
  const artifact = JSON.parse(await readFile(artifactPath, 'utf8'));
  const observation = artifact.receipt?.programEvidence?.observation ?? null;
  lanes[laneId] = {
    provider: contract.provider,
    contract: { path: contractPath, sha256: await sha256File(contractPath) },
    artifact: { path: artifactPath, sha256: await sha256File(artifactPath) },
    run,
    verify,
    inspect,
    receipt: {
      status: artifact.receipt?.status ?? null,
      oracle: artifact.receipt?.oracle?.status ?? null,
      programEvidenceStatus: artifact.receipt?.programEvidence?.status ?? null,
      programObservationSha256:
        artifact.receipt?.programEvidence?.observationSha256 ?? null,
      programCheckpointCount: artifact.receipt?.programEvidence?.checkpointCount ?? 0,
      workloadSha256: artifact.receipt?.replay?.workloadSha256 ?? null,
      executionSha256: artifact.receipt?.replay?.executionSha256 ?? null,
    },
    program: observation ? normalizeProgram(observation) : null,
    summary: observation?.summary ?? null,
  };
}

const crossLane = execute([
  'compare',
  lanes.W0.artifact.path,
  lanes.D0.artifact.path,
]);
const replayPath = resolve(outputRoot, 'D0.replay.artifact.json');
const replay = execute(['replay', lanes.D0.artifact.path, '--out', replayPath]);
const replayVerify = execute(['verify', replayPath]);
const replayArtifact = JSON.parse(await readFile(replayPath, 'utf8'));
const replayCompare = execute(['compare', lanes.D0.artifact.path, replayPath]);

const shapeIdentity = Object.fromEntries(Object.entries(lanes).map(([laneId, lane]) => [
  laneId,
  sha256(JSON.stringify({ ...lane.program, readbacks: undefined })),
]));
const outputIdentity = Object.fromEntries(Object.entries(lanes).map(([laneId, lane]) => [
  laneId,
  sha256(JSON.stringify(lane.program?.readbacks ?? null)),
]));
const failures = [];
if (control.status !== 0 || controlResult?.status !== 'passed') {
  failures.push('unobserved-control-failed');
}
for (const [laneId, lane] of Object.entries(lanes)) {
  for (const command of ['run', 'verify', 'inspect']) {
    if (lane[command].exitCode !== 0) failures.push(`${laneId}:${command}:failed`);
  }
  if (lane.verify.output?.valid !== true) failures.push(`${laneId}:invalid-receipt`);
  if (lane.receipt.oracle !== 'pass') failures.push(`${laneId}:oracle-failed`);
  if (lane.receipt.programEvidenceStatus !== 'observed') {
    failures.push(`${laneId}:program-evidence-missing`);
  }
  if (!lane.summary
      || lane.summary.shaderModuleCount < 1
      || lane.summary.dispatchCount < 1
      || lane.summary.submissionCount < 1
      || lane.summary.synchronizationCount < 1
      || lane.summary.readbackCount < 1) {
    failures.push(`${laneId}:program-evidence-incomplete`);
  }
}
if (crossLane.exitCode !== 0 || crossLane.output?.comparable !== true) {
  failures.push('cross-lane-output-compare-failed');
}
if (shapeIdentity.W0 !== shapeIdentity.D0) failures.push('cross-lane-command-shape-mismatch');
if (outputIdentity.W0 !== outputIdentity.D0) failures.push('cross-lane-readback-mismatch');
if (replay.exitCode !== 0 || replayVerify.exitCode !== 0
    || replayCompare.exitCode !== 0 || replayCompare.output?.comparable !== true) {
  failures.push('D0-replay-failed');
}
if (replayArtifact.receipt?.programEvidence?.observationSha256
    !== lanes.D0.receipt.programObservationSha256
    || replayArtifact.receipt?.replay?.executionSha256
      !== lanes.D0.receipt.executionSha256) {
  failures.push('D0-program-observation-replay-mismatch');
}

const result = {
  schemaVersion: 1,
  artifactKind: 'holoscript-doeproof-process-observer-admission',
  status: failures.length === 0 ? 'passed' : 'failed',
  failures,
  plan: { path: planPath, sha256: await sha256File(planPath) },
  control: {
    runner: { path: controlRunnerPath, sha256: await sha256File(controlRunnerPath) },
    exitCode: control.status,
    signal: control.signal,
    stderr: control.stderr.trim(),
    resultPath: resolve(controlRoot, 'result.json'),
    resultSha256: controlResult ? await sha256File(resolve(controlRoot, 'result.json')) : null,
    status: controlResult?.status ?? null,
  },
  implementation: {
    runner: { path: runnerPath, sha256: await sha256File(runnerPath) },
    cli: { path: cliPath, sha256: await sha256File(cliPath) },
    cliImplementation: {
      path: cliImplementationPath,
      sha256: await sha256File(cliImplementationPath),
    },
    process: { path: processPath, sha256: await sha256File(processPath) },
    loader: { path: loaderPath, sha256: await sha256File(loaderPath) },
    observer: { path: observerPath, sha256: await sha256File(observerPath) },
  },
  lanes,
  crossLane,
  replay: {
    run: replay,
    verify: replayVerify,
    compare: replayCompare,
    artifact: { path: replayPath, sha256: await sha256File(replayPath) },
  },
  identities: { shape: shapeIdentity, output: outputIdentity },
  credit: {
    packageProcessObserverAdmission: failures.length === 0,
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

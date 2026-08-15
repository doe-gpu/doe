#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const harnessDir = dirname(fileURLToPath(import.meta.url));
const doeRoot = resolve(harnessDir, '../../..');
const upstreamRoot = resolve(
  doeRoot,
  'bench/out/external-projects/holoscript-snn-webgpu/upstream',
);
const upstreamPackageDir = resolve(upstreamRoot, 'packages/snn-webgpu');
const upstreamCoreDir = resolve(upstreamRoot, 'packages/core');
const workloadPath = resolve(harnessDir, 'run-workload.mjs');
const evaluatorPath = resolve(harnessDir, 'evaluate-doeproof-cli-output.mjs');
const inputPath = resolve(harnessDir, 'inputs.json');
const planPath = resolve(harnessDir, 'doeproof-cli-integration.plan.json');
const cliPath = resolve(doeRoot, 'packages/doe-gpu/bin/doe-proof-node.js');
const cliImplementationPath = resolve(
  doeRoot,
  'packages/doe-gpu/src/node-webgpu-process-cli.js',
);
const processRunnerPath = resolve(doeRoot, 'packages/doe-gpu/src/node-webgpu-process.js');
const loaderPath = resolve(doeRoot, 'packages/doe-gpu/src/node-webgpu-loader.js');
const contractSchemaPath = resolve(
  doeRoot,
  'packages/doe-gpu/assets/governed-node-webgpu-process-contract.schema.json',
);
const outputRoot = resolve(
  process.argv[2] ?? resolve(
    doeRoot,
    'bench/out/external-projects/holoscript-snn-webgpu/doeproof-cli-qm0-v1',
  ),
);

function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

async function sha256File(path) {
  return sha256(await readFile(path));
}

function tagged(value) {
  return `sha256:${value}`;
}

function executeCli(args) {
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

const requireFromUpstream = createRequire(pathToFileURL(resolve(upstreamPackageDir, 'package.json')));
const dawnEntry = requireFromUpstream.resolve('webgpu');
const providers = {
  W0: {
    id: 'dawn-node-webgpu',
    module: resolve(dirname(dawnEntry), 'index.js'),
  },
  D0: {
    id: 'doe-gpu',
    module: resolve(doeRoot, 'packages/doe-gpu/src/index.js'),
  },
};
const plan = JSON.parse(await readFile(planPath, 'utf8'));
await mkdir(outputRoot, { recursive: false });

const sourceHashes = {
  plan: await sha256File(planPath),
  cli: await sha256File(cliPath),
  cliImplementation: await sha256File(cliImplementationPath),
  processRunner: await sha256File(processRunnerPath),
  loader: await sha256File(loaderPath),
  contractSchema: await sha256File(contractSchemaPath),
  workload: await sha256File(workloadPath),
  evaluator: await sha256File(evaluatorPath),
  input: await sha256File(inputPath),
};
const lanes = {};
for (const [laneId, provider] of Object.entries(providers)) {
  const contractPath = resolve(outputRoot, `${laneId}.contract.json`);
  const artifactPath = resolve(outputRoot, `${laneId}.artifact.json`);
  const contract = {
    schema: 'doe.governed-node-webgpu-process-contract/v1',
    provider: {
      ...provider,
      sha256: tagged(await sha256File(provider.module)),
    },
    workload: {
      id: plan.planId,
      version: plan.upstreamCommit,
      implementationSha256: tagged(sourceHashes.workload),
      input: { path: inputPath, sha256: tagged(sourceHashes.input) },
      expectedOutputSha256: tagged(plan.expectedComparableSha256),
    },
    process: {
      entrypoint: { path: workloadPath, sha256: tagged(sourceHashes.workload) },
      cwd: upstreamPackageDir,
      environment: {
        mode: 'inherit',
        values: {
          DOE_EXTERNAL_WEBGPU_PROVIDER: provider.id,
          DOE_EXTERNAL_UPSTREAM_PACKAGE_DIR: upstreamPackageDir,
          DOE_EXTERNAL_UPSTREAM_CORE_DIR: upstreamCoreDir,
          DOE_EXTERNAL_INPUT_PATH: inputPath,
          DOE_EXTERNAL_RECEIPT_MODE: 'enabled',
        },
      },
      timeoutMs: 120000,
      maxOutputBytes: 4194304,
    },
    evaluator: {
      module: evaluatorPath,
      sha256: tagged(sourceHashes.evaluator),
      export: 'evaluate',
    },
  };
  await writeFile(contractPath, `${JSON.stringify(contract, null, 2)}\n`);
  const run = executeCli(['run', contractPath, '--out', artifactPath]);
  const verify = executeCli(['verify', artifactPath]);
  const inspect = executeCli(['inspect', artifactPath]);
  lanes[laneId] = {
    provider,
    contract: { path: contractPath, sha256: await sha256File(contractPath) },
    artifact: { path: artifactPath, sha256: await sha256File(artifactPath) },
    run,
    verify,
    inspect,
  };
}

const crossLane = executeCli([
  'compare',
  lanes.W0.artifact.path,
  lanes.D0.artifact.path,
]);
const replayPath = resolve(outputRoot, 'D0.replay.artifact.json');
const replay = executeCli(['replay', lanes.D0.artifact.path, '--out', replayPath]);
const replayVerify = executeCli(['verify', replayPath]);
const replayCompare = executeCli(['compare', lanes.D0.artifact.path, replayPath]);

const failures = [];
for (const [laneId, lane] of Object.entries(lanes)) {
  for (const command of ['run', 'verify', 'inspect']) {
    if (lane[command].exitCode !== 0) failures.push(`${laneId}:${command}:exit`);
  }
  if (lane.verify.output?.valid !== true) failures.push(`${laneId}:receipt-invalid`);
  if (lane.inspect.output?.oracle?.status !== 'pass') failures.push(`${laneId}:oracle-failed`);
}
if (crossLane.exitCode !== 0 || crossLane.output?.comparable !== true) {
  failures.push('cross-lane-compare-failed');
}
if (crossLane.output?.performanceInterpretable !== false
    || crossLane.output?.runtimeOwnershipCredit !== false) {
  failures.push('cross-lane-credit-boundary-failed');
}
if (replay.exitCode !== 0 || replayVerify.exitCode !== 0) failures.push('replay-failed');
if (replayCompare.exitCode !== 0 || replayCompare.output?.comparable !== true) {
  failures.push('replay-compare-failed');
}

const result = {
  schemaVersion: 1,
  artifactKind: 'holoscript-doeproof-cli-integration',
  status: failures.length === 0 ? 'passed' : 'failed',
  failures,
  plan: {
    id: plan.planId,
    path: planPath,
    sha256: sourceHashes.plan,
  },
  implementation: {
    cli: { path: cliPath, sha256: sourceHashes.cli },
    cliImplementation: {
      path: cliImplementationPath,
      sha256: sourceHashes.cliImplementation,
    },
    processRunner: { path: processRunnerPath, sha256: sourceHashes.processRunner },
    loader: { path: loaderPath, sha256: sourceHashes.loader },
    contractSchema: { path: contractSchemaPath, sha256: sourceHashes.contractSchema },
    evaluator: { path: evaluatorPath, sha256: sourceHashes.evaluator },
    workload: { path: workloadPath, sha256: sourceHashes.workload },
    input: { path: inputPath, sha256: sourceHashes.input },
  },
  lanes,
  crossLane,
  replay: {
    artifact: { path: replayPath, sha256: await sha256File(replayPath) },
    run: replay,
    verify: replayVerify,
    compare: replayCompare,
  },
  decision: {
    publicDoeProofCli: failures.length === 0 ? 'authorized' : 'not-authorized',
    runtimeOwnershipCredit: false,
    performanceCredit: false,
    releaseCredit: false,
    terminalOwnershipDecisionChanged: false,
  },
};
const resultPath = resolve(outputRoot, 'result.json');
await writeFile(resultPath, `${JSON.stringify(result, null, 2)}\n`);
process.stdout.write(`${resultPath}\n`);
process.exitCode = failures.length === 0 ? 0 : 1;

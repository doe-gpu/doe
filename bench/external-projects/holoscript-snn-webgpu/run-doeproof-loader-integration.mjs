#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import {
  runGovernedNodeWebGPUProcess,
  validateGovernedNodeWebGPUProcessReceipt,
} from '../../../packages/doe-gpu/src/node-webgpu-process.js';

const harnessDir = dirname(fileURLToPath(import.meta.url));
const doeRoot = resolve(harnessDir, '../../..');
const upstreamRoot = resolve(
  doeRoot,
  'bench/out/external-projects/holoscript-snn-webgpu/upstream',
);
const upstreamPackageDir = resolve(upstreamRoot, 'packages/snn-webgpu');
const upstreamCoreDir = resolve(upstreamRoot, 'packages/core');
const loaderPath = resolve(doeRoot, 'packages/doe-gpu/src/node-webgpu-loader.js');
const processRunnerPath = resolve(doeRoot, 'packages/doe-gpu/src/node-webgpu-process.js');
const workloadPath = resolve(harnessDir, 'run-workload.mjs');
const inputPath = resolve(harnessDir, 'inputs.json');
const planPath = resolve(harnessDir, 'doeproof-loader-integration.plan.json');
const outputPath = resolve(
  process.argv[2] ?? resolve(
    doeRoot,
    'bench/out/external-projects/holoscript-snn-webgpu/doeproof-loader-qm0-v1/result.json',
  ),
);

function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

async function sha256File(path) {
  return sha256(await readFile(path));
}

const requireFromUpstream = createRequire(pathToFileURL(resolve(upstreamPackageDir, 'package.json')));
const dawnEntry = requireFromUpstream.resolve('webgpu');
const dawnModule = resolve(dirname(dawnEntry), 'index.js');
const doeModule = resolve(doeRoot, 'packages/doe-gpu/src/index.js');
const plan = JSON.parse(await readFile(planPath, 'utf8'));

async function executeLane(laneId, providerId, providerModule) {
  const governed = await runGovernedNodeWebGPUProcess({
    provider: { id: providerId, module: providerModule },
    workload: {
      id: plan.planId,
      version: plan.upstreamCommit,
      implementationSha256: `sha256:${await sha256File(workloadPath)}`,
      input: await readFile(inputPath),
      expectedOutputSha256: `sha256:${plan.expectedComparableSha256}`,
    },
    process: {
      entrypoint: workloadPath,
      cwd: upstreamPackageDir,
      environment: {
        mode: 'inherit',
        values: {
          DOE_EXTERNAL_WEBGPU_PROVIDER: providerId,
          DOE_EXTERNAL_UPSTREAM_PACKAGE_DIR: upstreamPackageDir,
          DOE_EXTERNAL_UPSTREAM_CORE_DIR: upstreamCoreDir,
          DOE_EXTERNAL_INPUT_PATH: inputPath,
          DOE_EXTERNAL_RECEIPT_MODE: 'enabled',
        },
      },
      timeoutMs: 120_000,
      maxOutputBytes: 4_194_304,
    },
    evaluate({ stdout }) {
      const result = JSON.parse(Buffer.from(stdout).toString('utf8').trim().split('\n').at(-1));
      return {
        output: JSON.stringify(comparableIdentity(result)),
        providerIdentity: result?.provider?.doeProof,
        evidence: result,
      };
    },
  });
  const validation = governed.receipt
    ? validateGovernedNodeWebGPUProcessReceipt(governed.receipt)
    : { valid: false, errors: ['receipt missing'] };
  const evaluationFailure = governed.errors.find(
    (error) => error.code === 'DOE_GOVERNED_PROCESS_EVALUATION_FAILED',
  );
  return {
    laneId,
    providerId,
    providerModule,
    exitCode: governed.receipt?.process?.exitCode ?? null,
    signal: governed.receipt?.process?.signal ?? null,
    timedOut: governed.receipt?.process?.timedOut ?? false,
    stderr: Buffer.from(governed.stderr).toString('utf8').trim(),
    parseError: evaluationFailure?.detail ?? null,
    result: governed.receipt?.applicationEvidence ?? null,
    doeProof: {
      ok: governed.ok,
      validation,
      receipt: governed.receipt,
    },
  };
}

function laneFailures(lane) {
  const failures = [];
  if (!lane.doeProof.ok) failures.push('governed-process-failed');
  if (!lane.doeProof.validation.valid) failures.push('governed-process-receipt-invalid');
  if (lane.exitCode !== 0) failures.push(`exit=${lane.exitCode}`);
  if (lane.signal !== null) failures.push(`signal=${lane.signal}`);
  if (lane.timedOut) failures.push('timeout');
  if (lane.parseError) failures.push(`parse=${lane.parseError}`);
  if (lane.result?.artifactKind !== 'holoscript-tropical-spmv-run') {
    failures.push('wrong-artifact-kind');
  }
  if (lane.result?.provider?.id !== lane.providerId) failures.push('provider-id-mismatch');
  if (lane.result?.provider?.doeProof?.contract !== 'doe.node-webgpu-loader/v1') {
    failures.push('public-loader-identity-missing');
  }
  if (lane.result?.hardwareEligible !== true) failures.push('hardware-ineligible');
  for (const topology of lane.result?.topologies ?? []) {
    if (!topology.oracleHash || topology.outputHash !== topology.oracleHash) {
      failures.push(`oracle-mismatch:${topology.id}`);
    }
  }
  return failures;
}

function comparableIdentity(result) {
  return {
    shader: result?.shader ?? null,
    dispatch: result?.dispatch ?? null,
    synchronization: result?.synchronization ?? null,
    readback: result?.readback ?? null,
    oracle: result?.oracle ?? null,
    topologies: (result?.topologies ?? []).map((topology) => ({
      id: topology.id,
      nnz: topology.nnz,
      oracleHash: topology.oracleHash,
      outputHash: topology.outputHash,
    })),
  };
}

const lanes = {
  W0: await executeLane('W0', 'dawn-node-webgpu', dawnModule),
  D0: await executeLane('D0', 'doe-gpu', doeModule),
};
const failures = [
  ...laneFailures(lanes.W0).map((failure) => `W0:${failure}`),
  ...laneFailures(lanes.D0).map((failure) => `D0:${failure}`),
];
const w0Identity = comparableIdentity(lanes.W0.result);
const d0Identity = comparableIdentity(lanes.D0.result);
const w0Sha256 = sha256(JSON.stringify(w0Identity));
const d0Sha256 = sha256(JSON.stringify(d0Identity));
if (w0Sha256 !== d0Sha256) failures.push('cross-lane-work-identity-mismatch');
if (w0Sha256 !== plan.expectedComparableSha256) failures.push('W0:frozen-output-identity-mismatch');
if (d0Sha256 !== plan.expectedComparableSha256) failures.push('D0:frozen-output-identity-mismatch');
if (lanes.W0.doeProof.receipt?.replay?.workloadSha256
    !== lanes.D0.doeProof.receipt?.replay?.workloadSha256) {
  failures.push('cross-lane-workload-replay-identity-mismatch');
}

const artifact = {
  schemaVersion: 1,
  artifactKind: 'holoscript-doeproof-loader-integration',
  plan: {
    id: plan.planId,
    path: 'bench/external-projects/holoscript-snn-webgpu/doeproof-loader-integration.plan.json',
    sha256: await sha256File(planPath),
  },
  status: failures.length === 0 ? 'passed' : 'failed',
  failures,
  source: {
    upstreamCommit: plan.upstreamCommit,
    publicLoader: {
      path: 'packages/doe-gpu/src/node-webgpu-loader.js',
      sha256: await sha256File(loaderPath),
    },
    governedProcessRunner: {
      path: 'packages/doe-gpu/src/node-webgpu-process.js',
      sha256: await sha256File(processRunnerPath),
    },
    workloadHarness: {
      path: 'bench/external-projects/holoscript-snn-webgpu/run-workload.mjs',
      sha256: await sha256File(workloadPath),
    },
    inputs: {
      path: 'bench/external-projects/holoscript-snn-webgpu/inputs.json',
      sha256: await sha256File(inputPath),
    },
  },
  lanes,
  comparability: {
    status: w0Sha256 === d0Sha256 ? 'passed' : 'failed',
    W0: w0Sha256,
    D0: d0Sha256,
  },
  decision: {
    publicDoeProofLoader: failures.length === 0 ? 'authorized' : 'not-authorized',
    publicDoeProofProcess: failures.length === 0 ? 'authorized' : 'not-authorized',
    runtimeOwnershipCredit: false,
    performanceCredit: false,
    releaseCredit: false,
    terminalOwnershipDecisionChanged: false,
  },
};

await mkdir(dirname(outputPath), { recursive: true });
await writeFile(outputPath, `${JSON.stringify(artifact, null, 2)}\n`);
process.stdout.write(`${outputPath}\n`);
process.exitCode = failures.length === 0 ? 0 : 1;

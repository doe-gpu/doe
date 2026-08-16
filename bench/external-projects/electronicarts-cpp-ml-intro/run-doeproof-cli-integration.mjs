#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const harnessDir = dirname(fileURLToPath(import.meta.url));
const doeRoot = resolve(harnessDir, '../../..');
const upstreamRoot = resolve(
  doeRoot,
  'bench/out/external-projects/electronicarts-cpp-ml-intro/upstream',
);
const webgpuRoot = resolve(upstreamRoot, 'Demo/mnist/Gigi/out/WebGPU');
const planPath = resolve(harnessDir, 'doeproof-cli-filesystem.plan.json');
const workloadPath = resolve(harnessDir, 'doeproof-workload.mjs');
const pngjsLoaderPath = resolve(harnessDir, 'doeproof-pngjs-loader.mjs');
const oraclePath = resolve(harnessDir, 'mnist-oracle.mjs');
const evaluatorPath = resolve(harnessDir, 'evaluate-doeproof-cli-output.mjs');
const inputPath = resolve(harnessDir, 'doeproof-input.json');
const cliPath = resolve(doeRoot, 'packages/doe-gpu/bin/doe-proof-node.js');
const outputRoot = resolve(
  process.argv[2] ?? resolve(
    doeRoot,
    'bench/out/external-projects/electronicarts-cpp-ml-intro/doeproof-cli-filesystem-qm7-v1',
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

async function walkFiles(root) {
  const files = [];
  async function visit(path) {
    for (const entry of await readdir(path, { withFileTypes: true })) {
      const child = resolve(path, entry.name);
      if (entry.isDirectory()) await visit(child);
      else if (entry.isFile()) files.push(child);
    }
  }
  await visit(root);
  return files.sort();
}

function executeCli(args) {
  const result = spawnSync(process.execPath, [cliPath, ...args], {
    cwd: doeRoot,
    encoding: 'utf8',
    maxBuffer: 32 * 1024 * 1024,
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

async function commonRuntimePaths() {
  const generated = [
    resolve(webgpuRoot, 'Shared.js'),
    resolve(webgpuRoot, 'jquery-csv.js'),
    resolve(webgpuRoot, 'mnist_Module.js'),
    resolve(webgpuRoot, 'assets/Backprop_Weights.bin'),
    resolve(webgpuRoot, 'assets/instructions.png'),
    ...Array.from({ length: 10 }, (_, index) => resolve(webgpuRoot, `assets/${index}.png`)),
  ];
  return [
    pngjsLoaderPath,
    oraclePath,
    ...generated,
    resolve(doeRoot, 'bench/package.json'),
    resolve(doeRoot, 'bench/node_modules/pngjs/package.json'),
    ...await walkFiles(resolve(doeRoot, 'bench/node_modules/pngjs/lib')),
  ];
}

async function providerRuntimePaths(provider) {
  if (provider.id === 'dawn-node-webgpu') {
    const providerRoot = dirname(provider.module);
    return [
      provider.module,
      resolve(providerRoot, 'package.json'),
      resolve(providerRoot, 'dist/linux-x64.dawn.node'),
    ];
  }
  return [
    resolve(doeRoot, 'packages/doe-gpu/package.json'),
    ...await walkFiles(resolve(doeRoot, 'packages/doe-gpu/src')),
    resolve(doeRoot, 'packages/doe-gpu/build/Release/doe_napi.node'),
    resolve(doeRoot, 'packages/doe-gpu-linux-x64/package.json'),
    ...await walkFiles(resolve(doeRoot, 'packages/doe-gpu-linux-x64/bin')),
    resolve(doeRoot, 'runtime/zig/zig-out/lib/libwebgpu_doe.so'),
    resolve(doeRoot, 'runtime/zig/zig-out/share/doe-build-metadata.json'),
  ];
}

async function runtimeFileRecords(paths) {
  const unique = [...new Set(paths)].sort();
  return Promise.all(unique.map(async (path, index) => ({
    id: `runtime-file-${String(index).padStart(3, '0')}`,
    path,
    sha256: tagged(await sha256File(path)),
  })));
}

const plan = JSON.parse(await readFile(planPath, 'utf8'));
await mkdir(outputRoot, { recursive: false });
const requireFromBench = createRequire(resolve(doeRoot, 'bench/package.json'));
const providers = {
  W0: {
    id: 'dawn-node-webgpu',
    module: requireFromBench.resolve('webgpu'),
  },
  D0: {
    id: 'doe-gpu',
    module: resolve(harnessDir, 'provider-doe.mjs'),
  },
};
const sourceHashes = {
  plan: await sha256File(planPath),
  workload: await sha256File(workloadPath),
  pngjsLoader: await sha256File(pngjsLoaderPath),
  oracle: await sha256File(oraclePath),
  evaluator: await sha256File(evaluatorPath),
  input: await sha256File(inputPath),
  cli: await sha256File(cliPath),
};
const commonPaths = await commonRuntimePaths();
const implementationSha256 = tagged(sha256(JSON.stringify(await Promise.all(
  [workloadPath, ...commonPaths].sort().map(async (path) => ({
    path,
    sha256: await sha256File(path),
  })),
))));

const lanes = {};
for (const [laneId, provider] of Object.entries(providers)) {
  const contractPath = resolve(outputRoot, `${laneId}.contract.json`);
  const artifactPath = resolve(outputRoot, `${laneId}.artifact.json`);
  const runtimeFiles = await runtimeFileRecords([
    ...commonPaths,
    ...await providerRuntimePaths(provider),
  ]);
  const runtimeDir = resolve(outputRoot, 'xdg', laneId, 'source');
  await mkdir(runtimeDir, { recursive: true });
  const contract = {
    schema: 'doe.governed-node-webgpu-process-contract/v1',
    provider: {
      ...provider,
      sha256: tagged(await sha256File(provider.module)),
    },
    workload: {
      id: plan.planId,
      version: plan.upstreamCommit,
      implementationSha256,
      input: { path: inputPath, sha256: tagged(sourceHashes.input) },
      expectedOutputSha256: tagged(plan.expectedComparableSha256),
    },
    process: {
      entrypoint: { path: workloadPath, sha256: tagged(sourceHashes.workload) },
      cwd: webgpuRoot,
      environment: {
        mode: 'sealed',
        values: {
          DOE_CPP_ML_UPSTREAM: upstreamRoot,
          DOE_CPP_ML_INPUT_PATH: inputPath,
          DOE_EXTERNAL_PNGJS_MODULE: resolve(doeRoot, 'bench/node_modules/pngjs/lib/png.js'),
          ...(laneId === 'D0' ? {
            DOE_EXTERNAL_DOE_MODULE: resolve(doeRoot, 'packages/doe-gpu/src/index.js'),
          } : {}),
          HOME: outputRoot,
          XDG_RUNTIME_DIR: runtimeDir,
          PATH: process.env.PATH ?? '/usr/bin:/bin',
          LANG: 'C.UTF-8',
          LC_ALL: 'C.UTF-8',
          VK_DRIVER_FILES: '/usr/share/vulkan/icd.d/radeon_icd.json',
          VK_LOADER_LAYERS_DISABLE: '~all~'
        }
      },
      filesystem: { mode: 'node-permission-read-only' },
      timeoutMs: 120000,
      maxOutputBytes: 16777216
    },
    evaluator: {
      module: evaluatorPath,
      sha256: tagged(sourceHashes.evaluator),
      export: 'evaluate'
    },
    runtimeFiles
  };
  await writeFile(contractPath, `${JSON.stringify(contract, null, 2)}\n`);
  const run = executeCli(['run', contractPath, '--out', artifactPath]);
  const verify = executeCli(['verify', artifactPath]);
  const inspect = executeCli(['inspect', artifactPath]);
  lanes[laneId] = {
    provider,
    runtimeFileCount: runtimeFiles.length,
    contract: { path: contractPath, sha256: await sha256File(contractPath) },
    artifact: { path: artifactPath, sha256: await sha256File(artifactPath) },
    run,
    verify,
    inspect
  };
}

const crossLane = executeCli([
  'compare',
  lanes.W0.artifact.path,
  lanes.D0.artifact.path,
]);
const replays = {};
for (const laneId of ['W0', 'D0']) {
  const replayPath = resolve(outputRoot, `${laneId}.replay.artifact.json`);
  const run = executeCli(['replay', lanes[laneId].artifact.path, '--out', replayPath]);
  const verify = executeCli(['verify', replayPath]);
  const compare = executeCli(['compare', lanes[laneId].artifact.path, replayPath]);
  replays[laneId] = {
    artifact: { path: replayPath, sha256: await sha256File(replayPath) },
    run,
    verify,
    compare
  };
}

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
for (const [laneId, replay] of Object.entries(replays)) {
  if (replay.run.exitCode !== 0 || replay.verify.exitCode !== 0) {
    failures.push(`${laneId}:replay-failed`);
  }
  if (replay.compare.exitCode !== 0 || replay.compare.output?.comparable !== true) {
    failures.push(`${laneId}:replay-compare-failed`);
  }
}

const result = {
  schemaVersion: 1,
  artifactKind: 'cpp-ml-doeproof-cli-integration',
  status: failures.length === 0 ? 'passed' : 'failed',
  failures,
  plan: { id: plan.planId, path: planPath, sha256: sourceHashes.plan },
  implementation: {
    cli: { path: cliPath, sha256: sourceHashes.cli },
    workload: { path: workloadPath, sha256: sourceHashes.workload },
    pngjsLoader: { path: pngjsLoaderPath, sha256: sourceHashes.pngjsLoader },
    oracle: { path: oraclePath, sha256: sourceHashes.oracle },
    evaluator: { path: evaluatorPath, sha256: sourceHashes.evaluator },
    input: { path: inputPath, sha256: sourceHashes.input },
    implementationSha256
  },
  lanes,
  crossLane,
  replays,
  decision: {
    publicDoeProofCli: failures.length === 0 ? 'authorized' : 'not-authorized',
    nodePermissionReadOnly: failures.length === 0,
    runtimeOwnershipCredit: false,
    performanceCredit: false,
    releaseCredit: false,
    terminalOwnershipDecisionChanged: false,
    completeOsDependencyClosureCredit: false
  }
};
const resultPath = resolve(outputRoot, 'result.json');
await writeFile(resultPath, `${JSON.stringify(result, null, 2)}\n`);
process.stdout.write(`${resultPath}\n`);
process.exitCode = failures.length === 0 ? 0 : 1;

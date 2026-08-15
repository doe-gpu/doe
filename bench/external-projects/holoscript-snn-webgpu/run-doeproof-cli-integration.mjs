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
const profile = process.env.DOE_DOEPROOF_INTEGRATION_PROFILE ?? 'ambient';
if (![
  'ambient',
  'node-permission-read-only',
  'linux-bwrap-workspace-sealed',
].includes(profile)) {
  throw new Error(`Unknown DOE_DOEPROOF_INTEGRATION_PROFILE ${profile}.`);
}
const permissionProfile = profile !== 'ambient';
const bwrapProfile = profile === 'linux-bwrap-workspace-sealed';
const planPath = resolve(
  harnessDir,
  bwrapProfile
    ? 'doeproof-cli-linux-bwrap-integration.plan.json'
    : permissionProfile
      ? 'doeproof-cli-filesystem-integration.plan.json'
      : 'doeproof-cli-integration.plan.json',
);
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
const receiptSchemaPath = resolve(
  doeRoot,
  'packages/doe-gpu/assets/governed-node-webgpu-process-receipt.schema.json',
);
const artifactSchemaPath = resolve(
  doeRoot,
  'packages/doe-gpu/assets/governed-node-webgpu-process-artifact.schema.json',
);
const packageManifestPath = resolve(doeRoot, 'packages/doe-gpu/package.json');
const bwrapPath = '/usr/bin/bwrap';
const sandboxSystemReadRoots = ['/usr', '/etc', '/sys'];
const sandboxOptionalSystemReadRoots = ['/run/udev'];
const sandboxEnvironment = {
  VK_DRIVER_FILES: '/usr/share/vulkan/icd.d/radeon_icd.json',
  VK_LOADER_LAYERS_DISABLE: '~all~',
};
const outputRoot = resolve(
  process.argv[2] ?? resolve(
    doeRoot,
    bwrapProfile
      ? 'bench/out/external-projects/holoscript-snn-webgpu/doeproof-cli-linux-bwrap-qm0-v1'
      : permissionProfile
      ? 'bench/out/external-projects/holoscript-snn-webgpu/doeproof-cli-filesystem-qm0-v1'
      : 'bench/out/external-projects/holoscript-snn-webgpu/doeproof-cli-qm0-v1',
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

async function runtimePathsFor(provider) {
  if (!permissionProfile) return [];
  const paths = [
    resolve(harnessDir, 'hardware-identity.mjs'),
    resolve(upstreamCoreDir, 'package.json'),
    resolve(upstreamCoreDir, 'dist/chunk-GLEJ2TLS.js'),
    resolve(upstreamCoreDir, 'dist/chunk-X5NQT5IT.js'),
    resolve(upstreamCoreDir, 'dist/math/tropical-spmv.js'),
    resolve(upstreamPackageDir, 'package.json'),
    resolve(upstreamPackageDir, 'dist/index.js'),
    resolve(upstreamPackageDir, 'src/shaders/tropical-graph.wgsl'),
  ];
  if (provider.id === 'dawn-node-webgpu') {
    const providerRoot = dirname(provider.module);
    paths.push(
      provider.module,
      resolve(providerRoot, 'package.json'),
      resolve(providerRoot, 'dist/linux-x64.dawn.node'),
    );
  } else {
    paths.push(
      resolve(doeRoot, 'packages/doe-gpu/package.json'),
      ...[
        'index.js',
        'native.js',
        'vendor/doe-determinism-policy.js',
        'vendor/doe-namespace.js',
        'vendor/doe-numeric-stability-policy.js',
        'vendor/webgpu/build-metadata.js',
        'vendor/webgpu/index.js',
        'vendor/webgpu/platform-package.js',
        'vendor/webgpu/runtime-cli.js',
        'vendor/webgpu/shared/browser-native-canvas-backend.js',
        'vendor/webgpu/shared/browser-surface.js',
        'vendor/webgpu/shared/capabilities.js',
        'vendor/webgpu/shared/compiler-errors.js',
        'vendor/webgpu/shared/encoder-surface.js',
        'vendor/webgpu/shared/full-surface.js',
        'vendor/webgpu/shared/native-metal-canvas-backend.js',
        'vendor/webgpu/shared/public-surface.js',
        'vendor/webgpu/shared/resource-lifecycle.js',
        'vendor/webgpu/shared/validation.js',
        'vendor/webgpu/webgpu-constants.js',
      ].map((path) => resolve(doeRoot, 'packages/doe-gpu/src', path)),
      resolve(doeRoot, 'packages/doe-gpu/build/Release/doe_napi.node'),
      resolve(doeRoot, 'packages/doe-gpu-linux-x64/package.json'),
      resolve(doeRoot, 'packages/doe-gpu-linux-x64/bin/doe-build-metadata.json'),
      resolve(doeRoot, 'packages/doe-gpu-linux-x64/bin/doe_napi.node'),
      resolve(doeRoot, 'packages/doe-gpu-linux-x64/bin/libwebgpu_doe.so'),
      resolve(doeRoot, 'packages/doe-gpu-linux-x64/bin/metadata.json'),
      resolve(doeRoot, 'runtime/zig/zig-out/lib/libwebgpu_doe.so'),
    );
  }
  return [...new Set(paths)].sort();
}

function ancestorDirectories(paths) {
  const directories = new Set();
  for (const path of paths) {
    let current = dirname(path);
    while (current !== '/') {
      if (sandboxSystemReadRoots.some((root) => current === root || current.startsWith(`${root}/`))) {
        break;
      }
      directories.add(current);
      current = dirname(current);
    }
  }
  return [...directories].sort((left, right) => {
    const depthDelta = left.split('/').length - right.split('/').length;
    return depthDelta || left.localeCompare(right);
  });
}

function sandboxDeclaration(readFiles, writablePath) {
  const workspaceReadFiles = [...new Set(readFiles)].sort();
  return {
    mode: 'linux-bwrap-workspace-sealed',
    binary: bwrapPath,
    systemReadRoots: sandboxSystemReadRoots,
    optionalSystemReadRoots: sandboxOptionalSystemReadRoots,
    workspaceReadFiles,
    writablePaths: [writablePath],
    privateTmp: true,
    privateNetwork: true,
    gpuDevicePath: '/dev/dri',
    environment: sandboxEnvironment,
  };
}

function buildSandboxInvocation(readFiles, writablePath, innerCommandArgs) {
  const sandbox = sandboxDeclaration(readFiles, writablePath);
  const directories = ancestorDirectories([
    ...sandbox.workspaceReadFiles,
    writablePath,
    doeRoot,
  ]);
  return {
    sandbox,
    commandArgs: [
      '--die-with-parent',
      '--unshare-all',
      '--new-session',
      '--ro-bind', '/usr', '/usr',
      '--symlink', 'usr/bin', '/bin',
      '--symlink', 'usr/lib', '/lib',
      '--symlink', 'usr/lib64', '/lib64',
      '--symlink', 'usr/sbin', '/sbin',
      '--ro-bind', '/etc', '/etc',
      '--ro-bind', '/sys', '/sys',
      '--dir', '/run',
      '--ro-bind-try', '/run/udev', '/run/udev',
      '--proc', '/proc',
      '--dev', '/dev',
      '--dev-bind-try', '/dev/dri', '/dev/dri',
      '--tmpfs', '/dev/shm',
      '--tmpfs', '/tmp',
      '--dir', '/tmp/home',
      '--dir', '/tmp/cache',
      ...directories.flatMap((path) => ['--dir', path]),
      ...sandbox.workspaceReadFiles.flatMap((path) => ['--ro-bind', path, path]),
      '--bind', writablePath, writablePath,
      '--clearenv',
      '--setenv', 'HOME', '/tmp/home',
      '--setenv', 'XDG_CACHE_HOME', '/tmp/cache',
      '--setenv', 'PATH', '/usr/bin:/bin',
      '--setenv', 'LANG', 'C.UTF-8',
      '--setenv', 'LC_ALL', 'C.UTF-8',
      ...Object.entries(sandboxEnvironment)
        .flatMap(([name, value]) => ['--setenv', name, value]),
      '--chdir', doeRoot,
      '--',
      ...innerCommandArgs,
    ],
  };
}

function executeCli(args, { sandboxReadFiles = [], sandboxWritablePath = outputRoot } = {}) {
  let command = process.execPath;
  let commandArgs = [cliPath, ...args];
  let sandbox = null;
  if (bwrapProfile && sandboxReadFiles.length > 0) {
    const controllerFiles = [
      cliPath,
      cliImplementationPath,
      processRunnerPath,
      loaderPath,
      contractSchemaPath,
      receiptSchemaPath,
      artifactSchemaPath,
      packageManifestPath,
    ];
    const invocation = buildSandboxInvocation(
      [...controllerFiles, ...sandboxReadFiles],
      sandboxWritablePath,
      [process.execPath, cliPath, ...args],
    );
    sandbox = invocation.sandbox;
    command = bwrapPath;
    commandArgs = invocation.commandArgs;
  }
  const result = spawnSync(command, commandArgs, {
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
    ...(sandbox ? {
      sandbox: {
        ...sandbox,
        binarySha256: sourceHashes.bwrap,
        declarationSha256: sha256(JSON.stringify(sandbox)),
      },
    } : {}),
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
  receiptSchema: await sha256File(receiptSchemaPath),
  artifactSchema: await sha256File(artifactSchemaPath),
  packageManifest: await sha256File(packageManifestPath),
  ...(bwrapProfile ? { bwrap: await sha256File(bwrapPath) } : {}),
  workload: await sha256File(workloadPath),
  evaluator: await sha256File(evaluatorPath),
  input: await sha256File(inputPath),
};
let sandboxProbe = null;
if (bwrapProfile) {
  const probeOutputRoot = resolve(outputRoot, 'sandbox-probe');
  await mkdir(probeOutputRoot, { recursive: false });
  const undeclaredCanaryPath = resolve(doeRoot, 'GOALS.md');
  const probeSource = [
    "const fs = require('node:fs');",
    'const interfaces = fs.readFileSync(\'/proc/net/dev\', \'utf8\')',
    "  .split('\\n').slice(2).map((line) => line.split(':')[0].trim()).filter(Boolean);",
    'const result = {',
    '  declaredFileVisible: fs.existsSync(process.argv[1]),',
    '  undeclaredCanaryVisible: fs.existsSync(process.argv[2]),',
    '  networkInterfaces: interfaces,',
    '};',
    'process.stdout.write(JSON.stringify(result));',
    'if (!result.declaredFileVisible || result.undeclaredCanaryVisible',
    "    || result.networkInterfaces.some((name) => name !== 'lo')) process.exitCode = 1;",
  ].join('\n');
  const invocation = buildSandboxInvocation(
    [cliPath],
    probeOutputRoot,
    [process.execPath, '-e', probeSource, cliPath, undeclaredCanaryPath],
  );
  const probeRun = spawnSync(bwrapPath, invocation.commandArgs, {
    cwd: doeRoot,
    encoding: 'utf8',
    maxBuffer: 1024 * 1024,
  });
  let probeOutput = null;
  try {
    probeOutput = probeRun.stdout.trim() ? JSON.parse(probeRun.stdout) : null;
  } catch {
    probeOutput = null;
  }
  sandboxProbe = {
    mode: invocation.sandbox.mode,
    binary: bwrapPath,
    binarySha256: sourceHashes.bwrap,
    declarationSha256: sha256(JSON.stringify(invocation.sandbox)),
    declaredFile: cliPath,
    undeclaredCanary: undeclaredCanaryPath,
    exitCode: probeRun.status,
    signal: probeRun.signal,
    stderr: probeRun.stderr.trim(),
    output: probeOutput,
  };
}
const lanes = {};
for (const [laneId, provider] of Object.entries(providers)) {
  const contractPath = resolve(outputRoot, `${laneId}.contract.json`);
  const laneOutputRoot = bwrapProfile
    ? resolve(outputRoot, `${laneId}-run`)
    : outputRoot;
  if (bwrapProfile) await mkdir(laneOutputRoot, { recursive: false });
  const artifactPath = resolve(laneOutputRoot, `${laneId}.artifact.json`);
  const runtimePaths = await runtimePathsFor(provider);
  const runtimeFiles = await Promise.all(runtimePaths.map(async (path, index) => ({
    id: `runtime-file-${String(index).padStart(3, '0')}`,
    path,
    sha256: tagged(await sha256File(path)),
  })));
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
          ...(permissionProfile ? {
            DOE_EXTERNAL_RENDERER_ATTESTATION: 'omitted-by-node-permission',
          } : {}),
        },
      },
      ...(permissionProfile ? {
        filesystem: { mode: 'node-permission-read-only' },
      } : {}),
      timeoutMs: 120000,
      maxOutputBytes: 4194304,
    },
    ...(permissionProfile ? { runtimeFiles } : {}),
    evaluator: {
      module: evaluatorPath,
      sha256: tagged(sourceHashes.evaluator),
      export: 'evaluate',
    },
  };
  await writeFile(contractPath, `${JSON.stringify(contract, null, 2)}\n`);
  const sandboxReadFiles = [
    contractPath,
    workloadPath,
    evaluatorPath,
    inputPath,
    ...runtimePaths,
  ];
  const run = executeCli(
    ['run', contractPath, '--out', artifactPath],
    { sandboxReadFiles, sandboxWritablePath: laneOutputRoot },
  );
  const verify = executeCli(['verify', artifactPath]);
  const inspect = executeCli(['inspect', artifactPath]);
  lanes[laneId] = {
    provider,
    runtimeFileCount: runtimeFiles.length,
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
const replayOutputRoot = bwrapProfile
  ? resolve(outputRoot, 'D0-replay')
  : outputRoot;
if (bwrapProfile) await mkdir(replayOutputRoot, { recursive: false });
const replayPath = resolve(replayOutputRoot, 'D0.replay.artifact.json');
const replay = executeCli(
  ['replay', lanes.D0.artifact.path, '--out', replayPath],
  {
    sandboxReadFiles: [
      lanes.D0.artifact.path,
      lanes.D0.contract.path,
      workloadPath,
      evaluatorPath,
      inputPath,
      ...await runtimePathsFor(providers.D0),
    ],
    sandboxWritablePath: replayOutputRoot,
  },
);
const replayVerify = executeCli(['verify', replayPath]);
const replayCompare = executeCli(['compare', lanes.D0.artifact.path, replayPath]);

const failures = [];
if (bwrapProfile && (
  sandboxProbe?.exitCode !== 0
  || sandboxProbe?.output?.declaredFileVisible !== true
  || sandboxProbe?.output?.undeclaredCanaryVisible !== false
  || sandboxProbe?.output?.networkInterfaces?.some((name) => name !== 'lo')
)) {
  failures.push('sandbox-visibility-probe-failed');
}
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
  ...(sandboxProbe ? { sandboxProbe } : {}),
  implementation: {
    cli: { path: cliPath, sha256: sourceHashes.cli },
    cliImplementation: {
      path: cliImplementationPath,
      sha256: sourceHashes.cliImplementation,
    },
    processRunner: { path: processRunnerPath, sha256: sourceHashes.processRunner },
    loader: { path: loaderPath, sha256: sourceHashes.loader },
    contractSchema: { path: contractSchemaPath, sha256: sourceHashes.contractSchema },
    receiptSchema: { path: receiptSchemaPath, sha256: sourceHashes.receiptSchema },
    artifactSchema: { path: artifactSchemaPath, sha256: sourceHashes.artifactSchema },
    packageManifest: { path: packageManifestPath, sha256: sourceHashes.packageManifest },
    ...(bwrapProfile ? {
      sandboxBinary: { path: bwrapPath, sha256: sourceHashes.bwrap },
    } : {}),
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
    workspaceSealingCredit: bwrapProfile && failures.length === 0,
    completeOsDependencyClosureCredit: false,
  },
};
const resultPath = resolve(outputRoot, 'result.json');
await writeFile(resultPath, `${JSON.stringify(result, null, 2)}\n`);
process.stdout.write(`${resultPath}\n`);
process.exitCode = failures.length === 0 ? 0 : 1;

#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  copyFile,
  cp,
  mkdir,
  readFile,
  readdir,
  stat,
  writeFile,
} from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const harnessDir = dirname(fileURLToPath(import.meta.url));
const runnerPath = fileURLToPath(import.meta.url);
const doeRoot = resolve(harnessDir, '../../..');
const sourceUpstreamRoot = resolve(
  doeRoot,
  'bench/out/external-projects/electronicarts-cpp-ml-intro/upstream',
);
const sourceWebgpuRoot = resolve(sourceUpstreamRoot, 'Demo/mnist/Gigi/out/WebGPU');
const planPath = resolve(harnessDir, 'doeproof-cli-clean-install.plan.json');
const outputRoot = resolve(
  process.argv[2] ?? resolve(
    doeRoot,
    'bench/out/external-projects/electronicarts-cpp-ml-intro/doeproof-cli-clean-install-qm9-v1',
  ),
);
const installRoot = resolve(outputRoot, 'install');
const packRoot = resolve(outputRoot, 'packs');
const applicationRoot = resolve(installRoot, 'application');
const copiedUpstreamRoot = resolve(applicationRoot, 'upstream');
const copiedWebgpuRoot = resolve(copiedUpstreamRoot, 'Demo/mnist/Gigi/out/WebGPU');
const npm = process.platform === 'win32' ? 'npm.cmd' : 'npm';
const platformPackageName = new Map([
  ['linux-x64', 'doe-gpu-linux-x64'],
  ['darwin-arm64', 'doe-gpu-darwin-arm64'],
]).get(`${process.platform}-${process.arch}`);

function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

async function sha256File(path) {
  return sha256(await readFile(path));
}

function tagged(value) {
  return `sha256:${value}`;
}

function execute(command, args, cwd = outputRoot, options = {}) {
  return spawnSync(command, args, {
    cwd,
    encoding: 'utf8',
    maxBuffer: 32 * 1024 * 1024,
    ...options,
  });
}

function requireSuccess(execution, label) {
  if (execution.status !== 0) {
    throw new Error(
      `${label} failed: ${execution.error?.message ?? `exit=${execution.status}`}\n`
      + `${execution.stdout}\n${execution.stderr}`,
    );
  }
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

async function runtimeFileRecords(paths) {
  const unique = [...new Set(paths)].sort();
  return Promise.all(unique.map(async (path, index) => ({
    id: `runtime-file-${String(index).padStart(3, '0')}`,
    path,
    sha256: tagged(await sha256File(path)),
  })));
}

async function pack(directory, label) {
  const execution = execute(npm, [
    'pack',
    '--ignore-scripts',
    '--pack-destination',
    packRoot,
    '--json',
  ], directory);
  requireSuccess(execution, `${label} pack`);
  const manifest = JSON.parse(execution.stdout)[0];
  const tarball = resolve(packRoot, manifest.filename);
  return {
    label,
    id: manifest.id,
    filename: manifest.filename,
    bytes: manifest.size,
    sha256: await sha256File(tarball),
    tarball,
  };
}

function executeCli(cliPath, args) {
  const execution = execute(cliPath, args, installRoot);
  let output = null;
  try {
    output = execution.stdout.trim() ? JSON.parse(execution.stdout) : null;
  } catch {
    output = null;
  }
  return {
    args,
    exitCode: execution.status,
    signal: execution.signal,
    stderr: execution.stderr.trim(),
    output,
  };
}

async function copyApplication() {
  await mkdir(applicationRoot, { recursive: true });
  await mkdir(dirname(copiedWebgpuRoot), { recursive: true });
  await cp(sourceWebgpuRoot, copiedWebgpuRoot, {
    recursive: true,
    force: false,
    errorOnExist: true,
  });
  const names = [
    'doeproof-workload.mjs',
    'doeproof-pngjs-loader.mjs',
    'mnist-oracle.mjs',
    'evaluate-doeproof-cli-output.mjs',
    'doeproof-input.json',
    'provider-doe.mjs',
  ];
  for (const name of names) {
    await copyFile(resolve(harnessDir, name), resolve(applicationRoot, name));
  }
  await writeFile(resolve(applicationRoot, 'package.json'), `${JSON.stringify({
    name: 'cpp-ml-mnist-doeproof-clean-install-fixture',
    private: true,
    type: 'module',
  }, null, 2)}\n`);

  const copied = [];
  for (const name of names) {
    const source = resolve(harnessDir, name);
    const target = resolve(applicationRoot, name);
    const sourceSha256 = await sha256File(source);
    const copiedSha256 = await sha256File(target);
    if (sourceSha256 !== copiedSha256) {
      throw new Error(`application copy mismatch for ${name}`);
    }
    copied.push({ name, sourceSha256, copiedSha256 });
  }
  const sourceFiles = await walkFiles(sourceWebgpuRoot);
  const targetFiles = await walkFiles(copiedWebgpuRoot);
  const sourceRelative = sourceFiles.map((path) => path.slice(sourceWebgpuRoot.length + 1));
  const targetRelative = targetFiles.map((path) => path.slice(copiedWebgpuRoot.length + 1));
  if (JSON.stringify(sourceRelative) !== JSON.stringify(targetRelative)) {
    throw new Error('generated application file inventory changed during copy');
  }
  for (let index = 0; index < sourceFiles.length; index += 1) {
    if (await sha256File(sourceFiles[index]) !== await sha256File(targetFiles[index])) {
      throw new Error(`generated application copy mismatch for ${sourceRelative[index]}`);
    }
  }
  return {
    harnessFiles: copied,
    generatedFileCount: targetFiles.length,
    generatedInventorySha256: sha256(JSON.stringify(await Promise.all(
      targetFiles.map(async (path) => ({
        path: path.slice(copiedWebgpuRoot.length + 1),
        sha256: await sha256File(path),
      })),
    ))),
  };
}

function assertInside(path, root, label) {
  const prefix = `${resolve(root)}/`;
  if (!resolve(path).startsWith(prefix)) {
    throw new Error(`${label} escaped clean installation: ${path}`);
  }
}

async function installedNativeProbe(installedDoeModule) {
  const probePath = resolve(applicationRoot, 'native-provider-probe.mjs');
  await writeFile(probePath, `
    import { pathToFileURL } from 'node:url';
    const provider = await import(pathToFileURL(process.argv[2]).href);
    process.stdout.write(JSON.stringify(provider.providerInfo()));
  `);
  const execution = execute(process.execPath, [probePath, installedDoeModule], installRoot);
  requireSuccess(execution, 'installed Doe native provider probe');
  const providerInfo = JSON.parse(execution.stdout);
  if (providerInfo.loaded !== true || providerInfo.doeNative !== true) {
    throw new Error(`clean-installed Doe provider did not load native runtime: ${execution.stdout}`);
  }
  if (providerInfo.buildMetadataSource !== 'prebuild') {
    throw new Error(`clean-installed Doe provider did not use platform prebuild: ${execution.stdout}`);
  }
  assertInside(providerInfo.doeLibraryPath, installRoot, 'Doe shared library');
  assertInside(providerInfo.buildMetadataPath, installRoot, 'Doe build metadata');
  return {
    probePath,
    probeSha256: await sha256File(probePath),
    providerInfo,
    librarySha256: await sha256File(providerInfo.doeLibraryPath),
    buildMetadataSha256: await sha256File(providerInfo.buildMetadataPath),
  };
}

await mkdir(outputRoot, { recursive: false });
await mkdir(packRoot, { recursive: true });
await mkdir(installRoot, { recursive: true });

const plan = JSON.parse(await readFile(planPath, 'utf8'));
const result = {
  schemaVersion: 1,
  artifactKind: 'cpp-ml-doeproof-cli-clean-install',
  status: 'failed',
  failures: [],
  plan: {
    id: plan.planId,
    path: planPath,
    sha256: await sha256File(planPath),
  },
};

try {
  if (!platformPackageName) {
    throw new Error(`no clean-install platform package for ${process.platform}-${process.arch}`);
  }
  const applicationCopy = await copyApplication();
  const wrapper = await pack(resolve(doeRoot, 'packages/doe-gpu'), 'doe-gpu');
  const platform = await pack(
    resolve(doeRoot, `packages/${platformPackageName}`),
    platformPackageName,
  );
  const incumbent = await pack(resolve(doeRoot, 'bench/node_modules/webgpu'), 'webgpu');
  const pngjs = await pack(resolve(doeRoot, 'bench/node_modules/pngjs'), 'pngjs');
  const packages = { wrapper, platform, incumbent, pngjs };

  await writeFile(resolve(installRoot, 'package.json'), `${JSON.stringify({
    name: 'cpp-ml-mnist-doeproof-clean-install',
    private: true,
    type: 'module',
  }, null, 2)}\n`);
  const installation = execute(npm, [
    'install',
    '--ignore-scripts',
    '--omit=optional',
    '--package-lock=false',
    '--no-audit',
    '--no-fund',
    wrapper.tarball,
    platform.tarball,
    incumbent.tarball,
    pngjs.tarball,
  ], installRoot);
  requireSuccess(installation, 'clean package installation');

  const installedCli = resolve(installRoot, 'node_modules/.bin/doe-proof-node');
  const installedDoeRoot = resolve(installRoot, 'node_modules/doe-gpu');
  const installedPlatformRoot = resolve(installRoot, `node_modules/${platformPackageName}`);
  const installedIncumbentRoot = resolve(installRoot, 'node_modules/webgpu');
  const installedPngRoot = resolve(installRoot, 'node_modules/pngjs');
  const installedDoeModule = resolve(installedDoeRoot, 'src/index.js');
  const installedIncumbentModule = resolve(installedIncumbentRoot, 'index.js');
  const installedPngModule = resolve(installedPngRoot, 'lib/png.js');
  for (const [label, path] of Object.entries({
    installedCli,
    installedDoeModule,
    installedIncumbentModule,
    installedPngModule,
  })) {
    await stat(path);
    assertInside(path, installRoot, label);
  }
  const help = execute(installedCli, ['--help'], installRoot);
  requireSuccess(help, 'clean-installed DoeProof CLI help');
  for (const command of ['run', 'verify', 'inspect', 'compare', 'replay']) {
    if (!help.stdout.includes(`doe-proof-node ${command}`)) {
      throw new Error(`clean-installed CLI help omitted ${command}`);
    }
  }

  const nativeProbe = await installedNativeProbe(installedDoeModule);
  const installedLibrarySha256 = await sha256File(
    resolve(installedPlatformRoot, 'bin/libwebgpu_doe.so'),
  );
  if (nativeProbe.librarySha256 !== installedLibrarySha256) {
    throw new Error('loaded clean-install shared library does not match platform payload');
  }

  const workloadPath = resolve(applicationRoot, 'doeproof-workload.mjs');
  const pngjsLoaderPath = resolve(applicationRoot, 'doeproof-pngjs-loader.mjs');
  const oraclePath = resolve(applicationRoot, 'mnist-oracle.mjs');
  const evaluatorPath = resolve(applicationRoot, 'evaluate-doeproof-cli-output.mjs');
  const inputPath = resolve(applicationRoot, 'doeproof-input.json');
  const providerDoePath = resolve(applicationRoot, 'provider-doe.mjs');
  const sharedRuntimePaths = [
    workloadPath,
    pngjsLoaderPath,
    oraclePath,
    evaluatorPath,
    inputPath,
    resolve(applicationRoot, 'package.json'),
    resolve(installRoot, 'package.json'),
    ...await walkFiles(copiedWebgpuRoot),
    ...await walkFiles(installedDoeRoot),
    ...await walkFiles(installedPngRoot),
  ];
  const providers = {
    W0: {
      id: 'dawn-node-webgpu',
      module: installedIncumbentModule,
      runtimePaths: await walkFiles(installedIncumbentRoot),
    },
    D0: {
      id: 'doe-gpu',
      module: providerDoePath,
      runtimePaths: [
        providerDoePath,
        ...await walkFiles(installedPlatformRoot),
      ],
    },
  };
  const implementationSha256 = tagged(sha256(JSON.stringify(await Promise.all(
    sharedRuntimePaths.sort().map(async (path) => ({
      path: path.slice(installRoot.length + 1),
      sha256: await sha256File(path),
    })),
  ))));
  const inputSha256 = await sha256File(inputPath);
  const lanes = {};

  for (const [laneId, provider] of Object.entries(providers)) {
    const contractPath = resolve(outputRoot, `${laneId}.contract.json`);
    const artifactPath = resolve(outputRoot, `${laneId}.artifact.json`);
    const runtimeFiles = await runtimeFileRecords([
      ...sharedRuntimePaths,
      ...provider.runtimePaths,
    ]);
    if (runtimeFiles.some((entry) => !entry.path.startsWith(`${installRoot}/`))) {
      throw new Error(`${laneId} runtime file escaped clean installation`);
    }
    const runtimeDir = resolve(outputRoot, 'xdg', laneId, 'source');
    await mkdir(runtimeDir, { recursive: true });
    const contract = {
      schema: 'doe.governed-node-webgpu-process-contract/v1',
      provider: {
        id: provider.id,
        module: provider.module,
        sha256: tagged(await sha256File(provider.module)),
      },
      workload: {
        id: plan.planId,
        version: plan.upstreamCommit,
        implementationSha256,
        input: { path: inputPath, sha256: tagged(inputSha256) },
        expectedOutputSha256: tagged(plan.expectedComparableSha256),
      },
      process: {
        entrypoint: { path: workloadPath, sha256: tagged(await sha256File(workloadPath)) },
        cwd: copiedWebgpuRoot,
        environment: {
          mode: 'sealed',
          values: {
            DOE_CPP_ML_UPSTREAM: copiedUpstreamRoot,
            DOE_CPP_ML_INPUT_PATH: inputPath,
            DOE_EXTERNAL_PNGJS_MODULE: installedPngModule,
            ...(laneId === 'D0' ? { DOE_EXTERNAL_DOE_MODULE: installedDoeModule } : {}),
            HOME: installRoot,
            XDG_RUNTIME_DIR: runtimeDir,
            PATH: process.env.PATH ?? '/usr/bin:/bin',
            LANG: 'C.UTF-8',
            LC_ALL: 'C.UTF-8',
            VK_DRIVER_FILES: '/usr/share/vulkan/icd.d/radeon_icd.json',
            VK_LOADER_LAYERS_DISABLE: '~all~',
          },
        },
        filesystem: { mode: 'node-permission-read-only' },
        timeoutMs: 120000,
        maxOutputBytes: 16777216,
      },
      evaluator: {
        module: evaluatorPath,
        sha256: tagged(await sha256File(evaluatorPath)),
        export: 'evaluate',
      },
      runtimeFiles,
    };
    await writeFile(contractPath, `${JSON.stringify(contract, null, 2)}\n`);
    const run = executeCli(installedCli, ['run', contractPath, '--out', artifactPath]);
    const verify = executeCli(installedCli, ['verify', artifactPath]);
    const inspect = executeCli(installedCli, ['inspect', artifactPath]);
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

  const crossLane = executeCli(installedCli, [
    'compare',
    lanes.W0.artifact.path,
    lanes.D0.artifact.path,
  ]);
  const replays = {};
  for (const laneId of ['W0', 'D0']) {
    const replayPath = resolve(outputRoot, `${laneId}.replay.artifact.json`);
    const run = executeCli(installedCli, [
      'replay',
      lanes[laneId].artifact.path,
      '--out',
      replayPath,
    ]);
    const verify = executeCli(installedCli, ['verify', replayPath]);
    const compare = executeCli(installedCli, [
      'compare',
      lanes[laneId].artifact.path,
      replayPath,
    ]);
    replays[laneId] = {
      artifact: { path: replayPath, sha256: await sha256File(replayPath) },
      run,
      verify,
      compare,
    };
  }

  const failures = [];
  for (const [laneId, lane] of Object.entries(lanes)) {
    for (const command of ['run', 'verify', 'inspect']) {
      if (lane[command].exitCode !== 0) failures.push(`${laneId}:${command}:exit`);
    }
    if (lane.verify.output?.valid !== true) failures.push(`${laneId}:receipt-invalid`);
    if (lane.inspect.output?.oracle?.status !== 'pass') failures.push(`${laneId}:oracle-failed`);
    if (lane.run.output?.process?.stderrBytes !== 0) failures.push(`${laneId}:provider-stderr`);
  }
  if (crossLane.exitCode !== 0
      || crossLane.output?.comparable !== true
      || crossLane.output?.bothPass !== true
      || crossLane.output?.sameOutput !== true) {
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
    if (replay.compare.exitCode !== 0
        || replay.compare.output?.comparable !== true
        || replay.compare.output?.sameOutput !== true) {
      failures.push(`${laneId}:replay-compare-failed`);
    }
  }

  result.status = failures.length === 0 ? 'passed' : 'failed';
  result.failures = failures;
  result.installation = {
    root: installRoot,
    lifecycleScripts: 'disabled',
    optionalDependencies: 'omitted',
    packageLock: false,
    packages,
    installedCli: {
      path: installedCli,
      sha256: await sha256File(resolve(installedDoeRoot, 'bin/doe-proof-node.js')),
    },
    nativeProbe,
    applicationCopy,
  };
  result.implementation = {
    runner: { path: runnerPath, sha256: await sha256File(runnerPath) },
    implementationSha256,
  };
  result.lanes = lanes;
  result.crossLane = crossLane;
  result.replays = replays;
  result.decision = {
    cleanInstalledPublicDoeProofCli: failures.length === 0 ? 'authorized' : 'not-authorized',
    nodeLinuxX64AmdVulkan: failures.length === 0,
    workspaceRuntimeResolution: false,
    runtimeOwnershipCredit: false,
    performanceCredit: false,
    applicationPromotionCredit: false,
    releaseCredit: false,
    terminalOwnershipDecisionChanged: false,
    completeOsDependencyClosureCredit: false,
  };
} catch (error) {
  result.failures.push(error instanceof Error ? error.message : String(error));
}

const resultPath = resolve(outputRoot, 'result.json');
await writeFile(resultPath, `${JSON.stringify(result, null, 2)}\n`);
process.stdout.write(`${resultPath}\n`);
process.exitCode = result.status === 'passed' ? 0 : 1;

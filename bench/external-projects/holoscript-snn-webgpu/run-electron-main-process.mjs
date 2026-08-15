import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync } from 'node:fs';
import {
  cp,
  mkdir,
  mkdtemp,
  readdir,
  readFile,
  realpath,
  rm,
  stat,
  writeFile,
} from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';

const harnessDir = dirname(fileURLToPath(import.meta.url));
const runnerPath = fileURLToPath(import.meta.url);
const doeRoot = resolve(harnessDir, '../../..');
const packageRoot = resolve(doeRoot, 'packages/doe-gpu');
const platformPackageRoot = resolve(doeRoot, 'packages/doe-gpu-linux-x64');
const upstreamRoot = resolve(
  doeRoot,
  'bench/out/external-projects/holoscript-snn-webgpu/upstream',
);
const upstreamPackageDir = resolve(upstreamRoot, 'packages/snn-webgpu');
const upstreamCoreDir = resolve(upstreamRoot, 'packages/core');
const electronAppDir = resolve(harnessDir, 'electron-app');
const planPath = resolve(harnessDir, 'electron-main-process.plan.json');
const workaroundPath = resolve(harnessDir, 'electron-buffer-upload-workaround.patch');
const outputPath = resolve(process.argv[2] ?? resolve(
  doeRoot,
  'bench/out/external-projects/holoscript-snn-webgpu/electron-main-process/result.json',
));
const plan = JSON.parse(await readFile(planPath, 'utf8'));
const p0PatchPath = resolve(doeRoot, plan.p0.patch);
const inputPath = resolve(harnessDir, 'inputs.json');
const inputs = JSON.parse(await readFile(inputPath, 'utf8'));
const cleanProcessRuns = plan.workload.cleanProcessRunsPerLane;
const timeoutMs = 120_000;
const maxOutputBytes = 4 * 1024 * 1024;
const npm = process.platform === 'win32' ? 'npm.cmd' : 'npm';
const scratch = await mkdtemp(join(tmpdir(), 'doe-holoscript-electron-'));

function execute(command, args, cwd = scratch) {
  return spawnSync(command, args, {
    cwd,
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
  });
}

function requireSuccess(result, label) {
  if (result.status !== 0) {
    throw new Error(
      `${label} failed: ${result.error?.message ?? `exit=${result.status}`}\n`
      + `${result.stdout}\n${result.stderr}`,
    );
  }
}

async function sha256File(path) {
  return createHash('sha256').update(await readFile(path)).digest('hex');
}

function sha256Text(value) {
  return createHash('sha256').update(value).digest('hex');
}

function commandOutput(command, args, cwd, label) {
  const result = execute(command, args, cwd);
  requireSuccess(result, label);
  return result.stdout.trim();
}

function pack(directory, label) {
  const result = execute(npm, [
    'pack',
    '--ignore-scripts',
    '--pack-destination',
    scratch,
    '--json',
  ], directory);
  requireSuccess(result, `${label} pack`);
  const manifest = JSON.parse(result.stdout)[0];
  return { manifest, tarball: resolve(scratch, manifest.filename) };
}

async function installDoePackage() {
  const wrapper = pack(packageRoot, 'doe-gpu');
  const platform = pack(platformPackageRoot, 'doe-gpu-linux-x64');
  const installRoot = resolve(scratch, 'doe-install');
  await mkdir(installRoot, { recursive: true });
  await writeFile(resolve(installRoot, 'package.json'), `${JSON.stringify({
    name: 'doe-holoscript-electron-clean-install',
    private: true,
    type: 'module',
  }, null, 2)}\n`);
  const installed = execute(npm, [
    'install',
    '--ignore-scripts',
    '--omit=optional',
    '--no-audit',
    '--no-fund',
    wrapper.tarball,
    platform.tarball,
  ], installRoot);
  requireSuccess(installed, 'Doe package clean install');
  return {
    modulePath: resolve(installRoot, 'node_modules/doe-gpu/src/index.js'),
    wrapper: {
      id: wrapper.manifest.id,
      bytes: wrapper.manifest.size,
      sha256: await sha256File(wrapper.tarball),
    },
    platform: {
      id: platform.manifest.id,
      bytes: platform.manifest.size,
      sha256: await sha256File(platform.tarball),
    },
  };
}

async function materializeApplicationWorkaround() {
  const patchedPackageDir = resolve(scratch, 'application-workaround-snn-webgpu');
  await cp(upstreamPackageDir, patchedPackageDir, { recursive: true });
  const patched = execute('patch', ['-p1', '--input', workaroundPath], patchedPackageDir);
  requireSuccess(patched, 'bounded application workaround');
  return {
    packageDir: patchedPackageDir,
    patchSha256: await sha256File(workaroundPath),
    patchedDistSha256: await sha256File(resolve(patchedPackageDir, 'dist/index.js')),
  };
}

async function resolveP0Source() {
  const configuredRoot = process.env.DOE_HOLOSCRIPT_ELECTRON_P0_SOURCE_ROOT;
  const configuredGo = process.env.DOE_HOLOSCRIPT_ELECTRON_P0_GO_EXECUTABLE;
  if (!configuredRoot || !existsSync(configuredRoot)) {
    throw new Error(
      'DOE_HOLOSCRIPT_ELECTRON_P0_SOURCE_ROOT must name the patched source build',
    );
  }
  if (!configuredGo || !existsSync(configuredGo)) {
    throw new Error(
      'DOE_HOLOSCRIPT_ELECTRON_P0_GO_EXECUTABLE must name the pinned Go executable',
    );
  }
  const sourceRoot = await realpath(configuredRoot);
  const dawnRoot = resolve(sourceRoot, 'third_party/dawn');
  const modulePath = resolve(sourceRoot, 'index.js');
  const nativePath = resolve(sourceRoot, 'dist/linux-x64.dawn.node');
  for (const [path, label] of [
    [dawnRoot, 'Dawn source root'],
    [modulePath, 'P0 module'],
    [nativePath, 'P0 native addon'],
    [p0PatchPath, 'P0 patch'],
  ]) {
    if (!existsSync(path)) throw new Error(`${label} is missing: ${path}`);
  }

  const nodeWebgpuCommit = commandOutput(
    'git', ['rev-parse', 'HEAD'], sourceRoot, 'P0 node-webgpu commit probe',
  );
  const dawnCommit = commandOutput(
    'git', ['rev-parse', 'HEAD'], dawnRoot, 'P0 Dawn commit probe',
  );
  if (nodeWebgpuCommit !== plan.p0.nodeWebgpuCommit) {
    throw new Error(`P0 node-webgpu commit mismatch: ${nodeWebgpuCommit}`);
  }
  if (dawnCommit !== plan.p0.dawnCommit) {
    throw new Error(`P0 Dawn commit mismatch: ${dawnCommit}`);
  }
  const changedFiles = commandOutput(
    'git',
    ['diff', '--name-only'],
    dawnRoot,
    'P0 changed-file probe',
  ).split('\n').filter(Boolean);
  const expectedChangedFiles = [
    'src/dawn/node/binding/GPUBuffer.cpp',
    'src/dawn/node/binding/GPUBuffer.h',
  ];
  if (JSON.stringify(changedFiles) !== JSON.stringify(expectedChangedFiles)) {
    throw new Error(`P0 changed-file set mismatch: ${changedFiles.join(', ')}`);
  }
  const sourceDiff = commandOutput(
    'git',
    ['diff', '--', ...expectedChangedFiles],
    dawnRoot,
    'P0 source-diff probe',
  );
  const patchText = (await readFile(p0PatchPath, 'utf8')).trimEnd();
  if (sourceDiff !== patchText) {
    throw new Error(
      `P0 source diff does not match the frozen patch: `
      + `${sha256Text(sourceDiff)} != ${sha256Text(patchText)}`,
    );
  }

  const goExecutable = await realpath(configuredGo);
  const goVersion = commandOutput(
    goExecutable, ['version'], sourceRoot, 'P0 Go version probe',
  );
  if (!goVersion.startsWith(`go version ${plan.p0.go.version} `)) {
    throw new Error(`P0 Go version mismatch: ${goVersion}`);
  }
  return {
    sourceRoot,
    dawnRoot,
    modulePath,
    nativePath,
    nodeWebgpuCommit,
    dawnCommit,
    patchSha256: await sha256File(p0PatchPath),
    moduleSha256: await sha256File(modulePath),
    nativeSha256: await sha256File(nativePath),
    nativeBytes: (await stat(nativePath)).size,
    toolchain: {
      node: process.version,
      go: goVersion,
      cxx: commandOutput('c++', ['--version'], sourceRoot, 'P0 C++ version probe').split('\n')[0],
      cmake: commandOutput('cmake', ['--version'], sourceRoot, 'P0 CMake version probe').split('\n')[0],
      ninja: commandOutput('ninja', ['--version'], sourceRoot, 'P0 Ninja version probe'),
    },
  };
}

function terminate(child) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  if (process.platform !== 'win32' && child.pid) {
    try {
      process.kill(-child.pid, 'SIGKILL');
      return;
    } catch {
      // Fall through to direct-child termination.
    }
  }
  child.kill('SIGKILL');
}

async function processTreeRssBytes(rootPid) {
  const pending = [rootPid];
  const visited = new Set();
  let total = 0;
  while (pending.length > 0) {
    const pid = pending.pop();
    if (!Number.isInteger(pid) || visited.has(pid)) continue;
    visited.add(pid);
    try {
      const status = await readFile(`/proc/${pid}/status`, 'utf8');
      const rss = status.match(/^VmRSS:\s+([0-9]+)\s+kB$/m);
      if (rss) total += Number(rss[1]) * 1024;
      const tasks = await readdir(`/proc/${pid}/task`);
      for (const task of tasks) {
        try {
          const children = await readFile(
            `/proc/${pid}/task/${task}/children`,
            'utf8',
          );
          for (const childPid of children.trim().split(/\s+/)) {
            if (childPid) pending.push(Number(childPid));
          }
        } catch {
          // A task may exit while its process tree is sampled.
        }
      }
    } catch {
      // A process may exit while its process tree is sampled.
    }
  }
  return total;
}

function runElectron({
  electron,
  doeModule,
  dawnModule,
  laneId,
  provider,
  receiptMode,
  packageDir = upstreamPackageDir,
}) {
  return new Promise((resolveRun, rejectRun) => {
    const child = spawn(electron.executable, [
      ...plan.runtime.arguments,
      electronAppDir,
    ], {
      cwd: upstreamPackageDir,
      env: {
        ...process.env,
        DOE_EXTERNAL_WEBGPU_PROVIDER: provider,
        DOE_EXTERNAL_DAWN_MODULE: dawnModule,
        DOE_EXTERNAL_DOE_MODULE: doeModule,
        DOE_EXTERNAL_UPSTREAM_PACKAGE_DIR: packageDir,
        DOE_EXTERNAL_UPSTREAM_CORE_DIR: upstreamCoreDir,
        DOE_EXTERNAL_INPUT_PATH: inputPath,
        DOE_EXTERNAL_RECEIPT_MODE: receiptMode,
        DOE_EXTERNAL_RENDERER_ATTESTATION: 'vulkaninfo',
      },
      detached: process.platform !== 'win32',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const stdout = [];
    const stderr = [];
    let outputBytes = 0;
    let timedOut = false;
    let outputLimitExceeded = false;
    let peakProcessTreeRssBytes = 0;
    let rssSample = Promise.resolve();
    const sampleRss = () => {
      rssSample = rssSample.then(async () => {
        peakProcessTreeRssBytes = Math.max(
          peakProcessTreeRssBytes,
          await processTreeRssBytes(child.pid),
        );
      });
    };
    sampleRss();
    const rssTimer = setInterval(sampleRss, 5);
    const timer = setTimeout(() => {
      timedOut = true;
      terminate(child);
    }, timeoutMs);
    const collect = (target) => (chunk) => {
      outputBytes += chunk.length;
      target.push(chunk);
      if (outputBytes > maxOutputBytes) {
        outputLimitExceeded = true;
        terminate(child);
      }
    };
    child.stdout.on('data', collect(stdout));
    child.stderr.on('data', collect(stderr));
    child.once('error', (error) => {
      clearTimeout(timer);
      clearInterval(rssTimer);
      rejectRun(error);
    });
    child.once('close', async (exitCode, signal) => {
      clearTimeout(timer);
      clearInterval(rssTimer);
      await rssSample;
      const stdoutText = Buffer.concat(stdout).toString('utf8').trim();
      const stderrText = Buffer.concat(stderr).toString('utf8').trim();
      let result = null;
      let parseError = '';
      if (stdoutText) {
        try {
          result = JSON.parse(stdoutText);
        } catch (error) {
          parseError = String(error?.message ?? error);
        }
      }
      resolveRun({
        laneId,
        provider,
        receiptMode,
        exitCode,
        signal,
        timedOut,
        outputLimitExceeded,
        peakProcessTreeRssBytes,
        parseError,
        stderr: stderrText,
        stdoutSha256: createHash('sha256').update(stdoutText).digest('hex'),
        result,
      });
    });
  });
}

function semanticEvidence(run) {
  if (!run.result) {
    return {
      laneId: run.laneId,
      provider: run.provider,
      exitCode: run.exitCode,
      signal: run.signal,
      timedOut: run.timedOut,
      outputLimitExceeded: run.outputLimitExceeded,
      parseError: run.parseError,
      externalBufferFailure: run.stderr.includes(plan.acceptance.w0FailureMustContain),
    };
  }
  return {
    laneId: run.laneId,
    provider: run.provider,
    effectiveProvider: run.result.provider?.id,
    adapter: run.result.adapter,
    hardwareEligible: run.result.hardwareEligible,
    shaderSha256: run.result.shader?.sha256,
    dispatch: run.result.dispatch,
    synchronization: run.result.synchronization,
    readback: run.result.readback,
    topologies: run.result.topologies?.map((topology) => ({
      id: topology.id,
      nnz: topology.nnz,
      oracleHash: topology.oracleHash,
      outputHash: topology.outputHash,
      maxDiff: topology.maxDiff,
    })),
  };
}

function exactApplicationPass(run, expectedProvider) {
  return run.exitCode === 0
    && run.signal === null
    && !run.timedOut
    && !run.outputLimitExceeded
    && !run.parseError
    && run.result?.provider?.id === expectedProvider
    && run.result?.hardwareEligible === true
    && run.result?.topologies?.length === inputs.topologies.length
    && run.result.topologies.every((topology) => (
      topology.maxDiff < inputs.tolerance
      && topology.outputHash === topology.oracleHash
    ));
}

function summarizeLane(runs, laneId, passPredicate) {
  const selected = runs.filter((run) => run.laneId === laneId);
  return {
    runCount: selected.length,
    passingRuns: selected.filter(passPredicate).length,
    peakProcessTreeRssBytes: Math.max(
      0,
      ...selected.map((run) => run.peakProcessTreeRssBytes),
    ),
    evidence: selected.map(semanticEvidence),
  };
}

try {
  if (process.platform !== 'linux' || process.arch !== 'x64') {
    throw new Error('Electron main-process diagnostic is frozen to linux-x64');
  }
  const configuredElectron = process.env.DOE_ELECTRON_EXECUTABLE;
  if (!configuredElectron || !existsSync(configuredElectron)) {
    throw new Error('DOE_ELECTRON_EXECUTABLE must name the pinned Electron executable');
  }
  const electronExecutable = await realpath(configuredElectron);
  const versionProbe = execute(electronExecutable, [
    ...plan.runtime.arguments,
    '--version',
  ], doeRoot);
  requireSuccess(versionProbe, 'Electron version probe');
  const electronVersion = versionProbe.stdout.trim().replace(/^v/, '');
  if (electronVersion !== plan.runtime.version) {
    throw new Error(
      `Electron version mismatch: expected ${plan.runtime.version}, received ${electronVersion}`,
    );
  }
  const electron = {
    executable: electronExecutable,
    version: electronVersion,
    sha256: await sha256File(electronExecutable),
  };
  const p0 = await resolveP0Source();

  const requireFromUpstream = createRequire(
    pathToFileURL(resolve(upstreamPackageDir, 'package.json')),
  );
  const ambientDawnModule = requireFromUpstream.resolve('webgpu');
  const dawnModule = resolve(dirname(ambientDawnModule), 'index.js');
  const dawnPackage = JSON.parse(
    await readFile(resolve(dirname(dawnModule), 'package.json'), 'utf8'),
  );
  if (dawnPackage.name !== 'webgpu' || dawnPackage.version !== '0.3.10') {
    throw new Error(
      `pinned incumbent mismatch: expected webgpu@0.3.10, received `
      + `${dawnPackage.name}@${dawnPackage.version}`,
    );
  }

  const installedDoe = await installDoePackage();
  const workaround = await materializeApplicationWorkaround();
  const runArguments = {
    electron,
    doeModule: installedDoe.modulePath,
    dawnModule,
  };
  const runs = [];
  for (const [laneId, provider, receiptMode] of [
    ['I0', 'dawn-node-webgpu', 'untraced'],
    ['I1', 'dawn-node-webgpu', 'untraced'],
    ['W0', 'dawn-node-webgpu', 'enabled'],
    ['D0', 'doe-gpu', 'enabled'],
  ]) {
    for (let index = 0; index < cleanProcessRuns; index += 1) {
      runs.push(await runElectron({
        ...runArguments,
        laneId,
        provider,
        receiptMode,
      }));
    }
  }
  for (let index = 0; index < cleanProcessRuns; index += 1) {
    runs.push(await runElectron({
      ...runArguments,
      dawnModule: p0.modulePath,
      laneId: 'P0',
      provider: 'dawn-node-webgpu',
      receiptMode: 'enabled',
    }));
  }
  runs.push(await runElectron({
    ...runArguments,
    laneId: 'A0',
    provider: 'dawn-node-webgpu',
    receiptMode: 'enabled',
    packageDir: workaround.packageDir,
  }));
  const d0Replay = await runElectron({
    ...runArguments,
    laneId: 'D0',
    provider: 'doe-gpu',
    receiptMode: 'enabled',
  });
  const p0Replay = await runElectron({
    ...runArguments,
    dawnModule: p0.modulePath,
    laneId: 'P0',
    provider: 'dawn-node-webgpu',
    receiptMode: 'enabled',
  });

  const d0Runs = runs.filter((run) => run.laneId === 'D0');
  const p0Runs = runs.filter((run) => run.laneId === 'P0');
  const w0Runs = runs.filter((run) => run.laneId === 'W0');
  const incumbentRuns = runs.filter((run) => ['I0', 'I1', 'W0'].includes(run.laneId));
  const d0EvidenceSha256 = createHash('sha256')
    .update(JSON.stringify(semanticEvidence(d0Runs[0])))
    .digest('hex');
  const replayEvidenceSha256 = createHash('sha256')
    .update(JSON.stringify(semanticEvidence(d0Replay)))
    .digest('hex');
  const p0EvidenceSha256 = createHash('sha256')
    .update(JSON.stringify(semanticEvidence(p0Runs[0])))
    .digest('hex');
  const p0ReplayEvidenceSha256 = createHash('sha256')
    .update(JSON.stringify(semanticEvidence(p0Replay)))
    .digest('hex');
  const d0Pass = d0Runs.length === cleanProcessRuns
    && d0Runs.every((run) => exactApplicationPass(run, 'doe-gpu'));
  const w0ExpectedFailure = w0Runs.length === cleanProcessRuns
    && w0Runs.every((run) => (
      run.exitCode !== 0
      && !run.timedOut
      && run.stderr.includes(plan.acceptance.w0FailureMustContain)
    ));
  const incumbentExpectedFailure = incumbentRuns.every((run) => (
    run.exitCode !== 0
    && !run.timedOut
    && run.stderr.includes(plan.acceptance.w0FailureMustContain)
  ));
  const d0ReplayExact = exactApplicationPass(d0Replay, 'doe-gpu')
    && d0EvidenceSha256 === replayEvidenceSha256;
  const p0Pass = p0Runs.length === cleanProcessRuns
    && p0Runs.every((run) => exactApplicationPass(run, 'dawn-node-webgpu'));
  const p0ReplayExact = exactApplicationPass(p0Replay, 'dawn-node-webgpu')
    && p0EvidenceSha256 === p0ReplayEvidenceSha256;

  const immutablePathSpecs = [
    planPath,
    runnerPath,
    resolve(electronAppDir, 'package.json'),
    resolve(electronAppDir, 'main.mjs'),
    resolve(harnessDir, 'provider-loader.mjs'),
    resolve(harnessDir, 'provider-dawn.mjs'),
    resolve(harnessDir, 'provider-doe.mjs'),
    resolve(harnessDir, 'run-workload.mjs'),
    inputPath,
    resolve(harnessDir, 'oracle.md'),
    workaroundPath,
    p0PatchPath,
    resolve(upstreamPackageDir, 'dist/index.js'),
    resolve(upstreamPackageDir, 'src/shaders/tropical-graph.wgsl'),
    resolve(upstreamCoreDir, 'dist/math/tropical-spmv.js'),
    dawnModule,
    resolve(dirname(dawnModule), 'dist/linux-x64.dawn.node'),
    resolve(doeRoot, 'runtime/zig/zig-out/lib/libwebgpu_doe.so'),
  ];
  const immutableInputs = await Promise.all(immutablePathSpecs.map(async (path) => ({
    path: path.startsWith(`${doeRoot}/`) ? path.slice(doeRoot.length + 1) : path,
    sha256: await sha256File(path),
  })));

  const artifact = {
    schemaVersion: 1,
    artifactKind: 'holoscript-electron-main-process-diagnostic',
    generatedAt: new Date().toISOString(),
    status: d0Pass
      && w0ExpectedFailure
      && incumbentExpectedFailure
      && d0ReplayExact
      && p0Pass
      && p0ReplayExact
      ? 'passed'
      : 'failed',
    candidateId: plan.candidateId,
    plan: {
      path: 'bench/external-projects/holoscript-snn-webgpu/electron-main-process.plan.json',
      sha256: await sha256File(planPath),
    },
    tuple: {
      runtime: electron,
      platform: process.platform,
      architecture: process.arch,
      mode: plan.runtime.mode,
      arguments: plan.runtime.arguments,
      rendererCreated: false,
    },
    packages: {
      incumbent: {
        name: dawnPackage.name,
        version: dawnPackage.version,
        modulePath: dawnModule,
        moduleSha256: await sha256File(dawnModule),
      },
      doe: {
        ...installedDoe,
        modulePath: '<clean-install>/node_modules/doe-gpu/src/index.js',
      },
      incumbentP0: {
        name: dawnPackage.name,
        version: dawnPackage.version,
        modulePath: '<source-build>/index.js',
        moduleSha256: p0.moduleSha256,
        nativePath: '<source-build>/dist/linux-x64.dawn.node',
        nativeSha256: p0.nativeSha256,
        nativeBytes: p0.nativeBytes,
      },
    },
    sourceBuild: {
      nodeWebgpuCommit: p0.nodeWebgpuCommit,
      dawnCommit: p0.dawnCommit,
      patch: {
        path: plan.p0.patch,
        sha256: p0.patchSha256,
      },
      goArchive: plan.p0.go,
      changedFiles: [
        'src/dawn/node/binding/GPUBuffer.cpp',
        'src/dawn/node/binding/GPUBuffer.h',
      ],
      buildCommand: plan.p0.buildCommand,
      toolchain: p0.toolchain,
    },
    immutableInputs,
    workaround: {
      id: 'mapped-at-creation-to-queue-write-buffer-v1',
      ...workaround,
      packageDir: '<temporary-copy>',
    },
    contract: {
      cleanProcessRuns,
      timeoutMs,
      maxOutputBytes,
      exactTopologyOracle: true,
      hardwareRequired: true,
      resourceObservation: plan.workload.resourceObservation,
    },
    lanes: {
      I0: summarizeLane(runs, 'I0', () => false),
      I1: summarizeLane(runs, 'I1', () => false),
      W0: summarizeLane(runs, 'W0', () => false),
      D0: summarizeLane(runs, 'D0', (run) => exactApplicationPass(run, 'doe-gpu')),
      A0: summarizeLane(runs, 'A0', (run) => exactApplicationPass(run, 'dawn-node-webgpu')),
      P0: summarizeLane(
        runs,
        'P0',
        (run) => exactApplicationPass(run, 'dawn-node-webgpu'),
      ),
    },
    replay: {
      D0: {
        status: d0ReplayExact ? 'passed' : 'failed',
        expectedEvidenceSha256: d0EvidenceSha256,
        actualEvidenceSha256: replayEvidenceSha256,
        evidence: semanticEvidence(d0Replay),
      },
      P0: {
        status: p0ReplayExact ? 'passed' : 'failed',
        expectedEvidenceSha256: p0EvidenceSha256,
        actualEvidenceSha256: p0ReplayEvidenceSha256,
        evidence: semanticEvidence(p0Replay),
      },
    },
    observations: {
      d0Pass,
      w0ExpectedFailure,
      incumbentExpectedFailure,
      d0ReplayExact,
      p0Pass,
      p0ReplayExact,
      applicationWorkaroundPassed: exactApplicationPass(
        runs.find((run) => run.laneId === 'A0'),
        'dawn-node-webgpu',
      ),
    },
    decision: {
      compatibilityEvidence: d0Pass
        ? 'authorized-for-declared-electron-main-process-tuple'
        : false,
      uniqueCorrectionObserved: d0Pass && w0ExpectedFailure && !p0Pass,
      boundedIncumbentPatchClosesGap: p0Pass,
      runtimeOwnershipDecision: p0Pass
        ? 'rejected-for-declared-electron-main-process-tuple'
        : 'not-terminal',
      runtimeOwnershipCredit: false,
      applicationPromotionCredit: false,
      performanceCredit: false,
      releaseCredit: false,
      nextGate: p0Pass
        ? 'retain-regression-and-offer-bounded-patch-upstream'
        : 'repair-or-retire-source-built-incumbent-P0',
    },
    limitations: [
      'This is Electron main-process Node-side compute and creates no renderer.',
      'The bounded application workaround fails, while the source-built incumbent P0 closes the same application gap as Doe.',
      'The result grants no browser, Chromium, performance, ownership, promotion, or release credit.',
      'A repository-owned harness does not prove external adoption.',
    ],
  };
  await mkdir(dirname(outputPath), { recursive: true });
  await writeFile(outputPath, `${JSON.stringify(artifact, null, 2)}\n`, { flag: 'wx' });
  process.stdout.write(`${outputPath}\n`);
  if (artifact.status !== 'passed') process.exitCode = 1;
} finally {
  await rm(scratch, { recursive: true, force: true });
}

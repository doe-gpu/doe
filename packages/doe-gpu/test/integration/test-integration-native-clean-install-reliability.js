import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync } from 'node:fs';
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const runnerPath = fileURLToPath(import.meta.url);
const lifecycleFixturePath = resolve(here, '../fixtures/native-clean-install-lifecycle.mjs');
const packageRoot = resolve(here, '../..');
const packagesRoot = dirname(packageRoot);
const requireNative = process.argv.includes('--required')
  || process.env.DOE_REQUIRE_NATIVE_CLEAN_INSTALL === '1';
const runtimeIndex = process.argv.indexOf('--runtime');
const outputIndex = process.argv.indexOf('--out');
const runtimeHost = runtimeIndex === -1 ? 'node' : process.argv[runtimeIndex + 1];
if (!['node', 'bun', 'electron'].includes(runtimeHost)) {
  throw new Error('--runtime requires node, bun, or electron');
}
if (outputIndex !== -1 && !process.argv[outputIndex + 1]) {
  throw new Error('--out requires a path');
}
const outputPath = outputIndex === -1 ? null : resolve(process.argv[outputIndex + 1]);
const platformPackageName = new Map([
  ['linux-x64', 'doe-gpu-linux-x64'],
  ['darwin-arm64', 'doe-gpu-darwin-arm64'],
]).get(`${process.platform}-${process.arch}`);
const platformLibraryName = new Map([
  ['linux-x64', 'libwebgpu_doe.so'],
  ['darwin-arm64', 'libwebgpu_doe.dylib'],
]).get(`${process.platform}-${process.arch}`);
if (!platformPackageName && requireNative) {
  throw new Error(`no native reliability contract for ${process.platform}-${process.arch}`);
}
if (!platformPackageName) {
  console.log(`doe-gpu native clean-install reliability: skipped ${process.platform}-${process.arch}`);
  process.exit(0);
}

const platformPackageRoot = resolve(packagesRoot, platformPackageName);
const stagedPlatformLibrary = resolve(platformPackageRoot, 'bin', platformLibraryName);
if (!existsSync(stagedPlatformLibrary)) {
  if (!requireNative) {
    console.log(`doe-gpu native clean-install reliability: skipped unstaged ${platformPackageName}`);
    process.exit(0);
  }
  throw new Error(`required staged platform library is missing: ${stagedPlatformLibrary}`);
}

const scratch = await mkdtemp(join(tmpdir(), 'doe-gpu-native-reliability-'));
const npm = process.platform === 'win32' ? 'npm.cmd' : 'npm';
const sequentialTrials = 3;
const concurrentTrials = 2;
const timeoutMs = 120_000;
const maxOutputBytes = 4 * 1024 * 1024;
const lifecycleCycles = 12;
const lifecycleWarmupCycles = 2;
const maxPostWarmupRssSpanBytes = 256 * 1024 * 1024;
const expectedOutput = [2, 4, 6, 8, 10, 12, 14, 16];
const expectedOutputSha256 = '9d42cad41af4aaf3ae973e5a48d96f61e4708edc57bf7dd29a497ebd96f506cf';

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

function electronExecutable() {
  const configured = process.env.DOE_ELECTRON_EXECUTABLE;
  if (!configured) {
    throw new Error('Electron requires explicit DOE_ELECTRON_EXECUTABLE');
  }
  const executable = resolve(configured);
  if (!existsSync(executable)) {
    throw new Error(`configured Electron executable is missing: ${executable}`);
  }
  return executable;
}

function electronArgs(entry) {
  return ['--headless', '--no-sandbox', '--disable-gpu', entry];
}

async function sha256File(path) {
  return createHash('sha256').update(await readFile(path)).digest('hex');
}

function resolveRuntimeIdentity() {
  if (runtimeHost === 'node') {
    return { host: runtimeHost, executable: process.execPath, version: process.version };
  }
  if (runtimeHost === 'bun') {
    const probe = execute('bun', [
      '-e',
      'process.stdout.write(JSON.stringify({executable:process.execPath,version:Bun.version}))',
    ], packageRoot);
    requireSuccess(probe, 'Bun runtime identity probe');
    return { host: runtimeHost, ...JSON.parse(probe.stdout) };
  }
  const executable = electronExecutable();
  const probe = execute(executable, [
    '--headless',
    '--no-sandbox',
    '--disable-gpu',
    '--version',
  ], packageRoot);
  requireSuccess(probe, 'Electron runtime identity probe');
  const version = probe.stdout.trim().replace(/^v/, '');
  if (!/^\d+\.\d+\.\d+(?:[-+].+)?$/.test(version)) {
    throw new Error(`Electron runtime returned an invalid version: ${probe.stdout}`);
  }
  return { host: runtimeHost, executable, version };
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

function runTrial(runtime, examplePath, id, mode) {
  return new Promise((resolveTrial, rejectTrial) => {
    const runtimeArgs = runtimeHost === 'electron'
      ? electronArgs(scratch)
      : [examplePath];
    const child = spawn(runtime.executable, runtimeArgs, {
      cwd: scratch,
      env: process.env,
      detached: process.platform !== 'win32',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const stdout = [];
    const stderr = [];
    let outputBytes = 0;
    let timedOut = false;
    let outputLimitExceeded = false;
    const startedAt = performance.now();
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
      rejectTrial(error);
    });
    child.once('close', (exitCode, signal) => {
      clearTimeout(timer);
      const stdoutText = Buffer.concat(stdout).toString('utf8');
      const stderrText = Buffer.concat(stderr).toString('utf8');
      if (exitCode !== 0 || signal || timedOut || outputLimitExceeded) {
        rejectTrial(new Error(
          `${runtimeHost} ${mode} trial ${id} failed: exit=${exitCode} signal=${signal} `
          + `timeout=${timedOut} outputLimit=${outputLimitExceeded}\n${stderrText}`,
        ));
        return;
      }
      if (stderrText.trim()) {
        rejectTrial(new Error(`${runtimeHost} ${mode} trial ${id} wrote stderr: ${stderrText}`));
        return;
      }
      try {
        const receipt = JSON.parse(stdoutText);
        const providerPath = receipt.provider?.doeLibraryPath ?? '';
        if (receipt.runtimeHost !== runtimeHost
          || (runtimeHost === 'electron' && receipt.runtimeVersion !== runtime.version)
          || receipt.provider?.loaded !== true
          || receipt.provider?.doeNative !== true
          || receipt.provider?.buildMetadataSource !== 'prebuild'
          || !providerPath.includes(`/node_modules/${platformPackageName}/`)
          || JSON.stringify(receipt.result?.output) !== JSON.stringify(expectedOutput)
          || receipt.result?.outputSha256 !== expectedOutputSha256
          || (runtimeHost === 'electron' && (
            receipt.mappedRangeProbe?.objectTag !== '[object ArrayBuffer]'
            || receipt.mappedRangeProbe?.sliceAvailable !== true
            || receipt.mappedRangeProbe?.value !== 42
          ))) {
          throw new Error(`receipt failed the frozen runtime/output contract: ${stdoutText}`);
        }
        resolveTrial({
          id,
          mode,
          exitCode,
          signal,
          timedOut,
          outputLimitExceeded,
          durationMs: Number((performance.now() - startedAt).toFixed(3)),
          stdoutSha256: createHash('sha256').update(stdoutText).digest('hex'),
          receipt: {
            runtimeHost: receipt.runtimeHost,
            providerModule: receipt.provider.module,
            libraryFlavor: receipt.provider.libraryFlavor,
            buildMetadataSource: receipt.provider.buildMetadataSource,
            outputSha256: receipt.result.outputSha256,
          },
        });
      } catch (error) {
        rejectTrial(error);
      }
    });
  });
}

function runLifecycleTrial(runtime, fixturePath) {
  return new Promise((resolveTrial, rejectTrial) => {
    const runtimeArgs = runtimeHost === 'node'
      ? ['--expose-gc', fixturePath]
      : runtimeHost === 'electron'
        ? electronArgs(scratch)
        : [fixturePath];
    const child = spawn(runtime.executable, runtimeArgs, {
      cwd: scratch,
      env: {
        ...process.env,
        DOE_NATIVE_LIFECYCLE_RUNTIME: runtimeHost,
        DOE_NATIVE_LIFECYCLE_CYCLES: String(lifecycleCycles),
      },
      detached: process.platform !== 'win32',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const stdout = [];
    const stderr = [];
    let outputBytes = 0;
    let timedOut = false;
    let outputLimitExceeded = false;
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
      rejectTrial(error);
    });
    child.once('close', (exitCode, signal) => {
      clearTimeout(timer);
      const stdoutText = Buffer.concat(stdout).toString('utf8');
      const stderrText = Buffer.concat(stderr).toString('utf8');
      if (exitCode !== 0 || signal || timedOut || outputLimitExceeded) {
        rejectTrial(new Error(
          `${runtimeHost} same-process lifecycle failed: exit=${exitCode} signal=${signal} `
          + `timeout=${timedOut} outputLimit=${outputLimitExceeded}\n${stderrText}`,
        ));
        return;
      }
      if (stderrText.trim()) {
        rejectTrial(new Error(`${runtimeHost} same-process lifecycle wrote stderr: ${stderrText}`));
        return;
      }
      try {
        const sample = JSON.parse(stdoutText);
        if (sample.status !== 'passed'
          || sample.runtimeHost !== runtimeHost
          || sample.contract?.cycleCount !== lifecycleCycles
          || sample.contract?.expectedOutputSha256 !== expectedOutputSha256
          || sample.provider?.loaded !== true
          || sample.provider?.doeNative !== true
          || sample.provider?.buildMetadataSource !== 'prebuild'
          || sample.samples?.length !== lifecycleCycles
          || sample.samples.some((entry) => entry.deviceDestroyed !== true
            || entry.lostReason !== 'destroyed'
            || entry.postDestroyRejected !== true
            || !entry.postDestroyError.includes('GPUDevice was destroyed')
            || entry.outputSha256 !== expectedOutputSha256)) {
          throw new Error(`same-process lifecycle failed the frozen contract: ${stdoutText}`);
        }
        const measuredSamples = sample.samples.slice(lifecycleWarmupCycles);
        const measuredRss = measuredSamples.map((entry) => entry.rssAfterDestroyBytes);
        const minRssBytes = Math.min(...measuredRss);
        const maxRssBytes = Math.max(...measuredRss);
        const postWarmupRssSpanBytes = maxRssBytes - minRssBytes;
        if (postWarmupRssSpanBytes > maxPostWarmupRssSpanBytes) {
          throw new Error(
            `same-process RSS span ${postWarmupRssSpanBytes} exceeds `
            + `${maxPostWarmupRssSpanBytes}`,
          );
        }
        resolveTrial({
          exitCode,
          signal,
          timedOut,
          outputLimitExceeded,
          stdoutSha256: createHash('sha256').update(stdoutText).digest('hex'),
          cycleCount: sample.samples.length,
          warmupCycles: lifecycleWarmupCycles,
          rssBeforeBytes: sample.rssBeforeBytes,
          minPostWarmupRssBytes: minRssBytes,
          maxPostWarmupRssBytes: maxRssBytes,
          postWarmupRssSpanBytes,
          maxPostWarmupRssSpanBytes,
          samples: sample.samples,
        });
      } catch (error) {
        rejectTrial(error);
      }
    });
  });
}

try {
  const runtime = resolveRuntimeIdentity();
  const wrapper = pack(packageRoot, 'wrapper');
  const platform = pack(platformPackageRoot, 'platform');
  const fixtureManifest = {
    name: 'doe-gpu-native-reliability-fixture',
    private: true,
    type: 'module',
  };
  if (runtimeHost === 'electron') {
    fixtureManifest.main = 'node_modules/doe-gpu/examples/electron-first-kernel.mjs';
  }
  const fixtureManifestPath = resolve(scratch, 'package.json');
  await writeFile(fixtureManifestPath, `${JSON.stringify(fixtureManifest, null, 2)}\n`);
  const installed = execute(npm, [
    'install',
    '--ignore-scripts',
    '--omit=optional',
    '--no-audit',
    '--no-fund',
    wrapper.tarball,
    platform.tarball,
  ]);
  requireSuccess(installed, 'native reliability clean install');
  const examplePath = resolve(
    scratch,
    `node_modules/doe-gpu/examples/${runtimeHost}-first-kernel.mjs`,
  );
  const installedLifecycleFixture = resolve(scratch, 'native-clean-install-lifecycle.mjs');
  await copyFile(lifecycleFixturePath, installedLifecycleFixture);

  const trials = [];
  for (let index = 0; index < sequentialTrials; index += 1) {
    trials.push(await runTrial(runtime, examplePath, `sequential-${index}`, 'sequential'));
  }
  trials.push(...await Promise.all(
    Array.from(
      { length: concurrentTrials },
      (_, index) => runTrial(runtime, examplePath, `concurrent-${index}`, 'concurrent'),
    ),
  ));
  if (runtimeHost === 'electron') {
    fixtureManifest.main = 'native-clean-install-lifecycle.mjs';
    await writeFile(fixtureManifestPath, `${JSON.stringify(fixtureManifest, null, 2)}\n`);
  }
  const sameProcessLifecycle = await runLifecycleTrial(runtime, installedLifecycleFixture);

  if (outputPath) {
    const artifact = {
      schemaVersion: 1,
      artifactKind: 'doe-gpu-native-clean-install-reliability-diagnostic',
      status: 'passed',
      tuple: { runtime: runtimeHost, platform: process.platform, arch: process.arch },
      contract: {
        sequentialTrials,
        concurrentTrials,
        timeoutMs,
        maxOutputBytes,
        expectedOutputSha256,
        lifecycleCycles,
        lifecycleWarmupCycles,
        maxPostWarmupRssSpanBytes,
      },
      installation: {
        lifecycleScripts: 'disabled',
        optionalDependencies: 'omitted',
        workspaceLibraryResolution: false,
        sharedAcrossTrials: true,
      },
      launch: runtimeHost === 'electron'
        ? {
            mode: 'electron-main-process-node-side',
            arguments: electronArgs('<clean-install-app>'),
            rendererCreated: false,
          }
        : { mode: `${runtimeHost}-process` },
      runtime: { ...runtime, sha256: await sha256File(runtime.executable) },
      packages: {
        wrapper: {
          id: wrapper.manifest.id,
          bytes: wrapper.manifest.size,
          sha256: await sha256File(wrapper.tarball),
        },
        platform: {
          id: platform.manifest.id,
          bytes: platform.manifest.size,
          sha256: await sha256File(platform.tarball),
          stagedLibrarySha256: await sha256File(stagedPlatformLibrary),
        },
      },
      implementation: {
        runner: {
          path: 'packages/doe-gpu/test/integration/test-integration-native-clean-install-reliability.js',
          sha256: await sha256File(runnerPath),
        },
        firstKernel: {
          path: `packages/doe-gpu/examples/${runtimeHost}-first-kernel.mjs`,
          sha256: await sha256File(resolve(packageRoot, 'examples', `${runtimeHost}-first-kernel.mjs`)),
        },
        lifecycleFixture: {
          path: 'packages/doe-gpu/test/fixtures/native-clean-install-lifecycle.mjs',
          sha256: await sha256File(lifecycleFixturePath),
        },
        wrapperManifest: {
          path: 'packages/doe-gpu/package.json',
          sha256: await sha256File(resolve(packageRoot, 'package.json')),
        },
        platformManifest: {
          path: `packages/${platformPackageName}/package.json`,
          sha256: await sha256File(resolve(platformPackageRoot, 'package.json')),
        },
      },
      trials,
      sameProcessLifecycle,
      decision: {
        boundedCleanProcessReliability: 'authorized-for-declared-runtime-tuple',
        boundedSameProcessLifecycle: 'authorized-for-declared-runtime-tuple',
        boundedRssGrowthDiagnostic: 'authorized-for-declared-runtime-tuple',
        deliberateDestroyLossSemantics: 'authorized-for-declared-runtime-tuple',
        deviceLossCredit: false,
        memoryGrowthCredit: false,
        performanceCredit: false,
        applicationPromotionCredit: false,
      },
      limitations: [
        'This bounded process gate is not the full promotion reliability floor.',
        'Deliberate GPUDevice.destroy() loss notification and post-destroy rejection are exercised.',
        'Unexpected hardware or driver loss and recovery are not exercised.',
        'The same-process RSS span is a bounded diagnostic, not a long-soak leak or promotion certificate.',
        'Trial durations are lifecycle diagnostics and receive no performance interpretation.',
        'This artifact does not generalize beyond its declared runtime, platform, and architecture.',
        ...(runtimeHost === 'electron' ? [
          'Electron evidence covers main-process Node-side compute without renderer creation.',
          'This artifact grants no Electron renderer, Chromium WebGPU, or browser lifecycle credit.',
        ] : []),
      ],
    };
    await mkdir(dirname(outputPath), { recursive: true });
    await writeFile(outputPath, `${JSON.stringify(artifact, null, 2)}\n`, { flag: 'wx' });
  }
  console.log(
    `doe-gpu native clean-install reliability: ok ${runtimeHost} `
    + `${process.platform}-${process.arch}`,
  );
} finally {
  await rm(scratch, { recursive: true, force: true });
}

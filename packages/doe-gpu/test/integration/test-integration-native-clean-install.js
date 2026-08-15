import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync } from 'node:fs';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const runnerPath = fileURLToPath(import.meta.url);
const packageRoot = resolve(here, '../..');
const packagesRoot = dirname(packageRoot);
const requireNative = process.argv.includes('--required')
  || process.env.DOE_REQUIRE_NATIVE_CLEAN_INSTALL === '1';
const outputArgumentIndex = process.argv.indexOf('--out');
if (outputArgumentIndex !== -1 && !process.argv[outputArgumentIndex + 1]) {
  throw new Error('--out requires a path');
}
const outputPath = outputArgumentIndex === -1
  ? null
  : resolve(process.argv[outputArgumentIndex + 1]);
const runtimeArgumentIndex = process.argv.indexOf('--runtime');
if (runtimeArgumentIndex !== -1 && !process.argv[runtimeArgumentIndex + 1]) {
  throw new Error('--runtime requires node, bun, or electron');
}
const runtimeHost = runtimeArgumentIndex === -1
  ? 'node'
  : process.argv[runtimeArgumentIndex + 1];
if (!['node', 'bun', 'electron'].includes(runtimeHost)) {
  throw new Error(`unsupported native clean-install runtime: ${runtimeHost}`);
}
const platformPackageName = new Map([
  ['linux-x64', 'doe-gpu-linux-x64'],
  ['darwin-arm64', 'doe-gpu-darwin-arm64'],
]).get(`${process.platform}-${process.arch}`);
const platformLibraryName = new Map([
  ['linux-x64', 'libwebgpu_doe.so'],
  ['darwin-arm64', 'libwebgpu_doe.dylib'],
]).get(`${process.platform}-${process.arch}`);

if (!platformPackageName && requireNative) {
  throw new Error(`no native clean-install package contract for ${process.platform}-${process.arch}`);
}
if (!platformPackageName) {
  console.log(`doe-gpu native clean-install integration: skipped ${process.platform}-${process.arch}`);
  process.exit(0);
}

const platformPackageRoot = resolve(packagesRoot, platformPackageName);
const stagedPlatformLibrary = resolve(platformPackageRoot, 'bin', platformLibraryName);
if (!existsSync(stagedPlatformLibrary)) {
  if (requireNative) {
    throw new Error(`required staged platform library is missing: ${stagedPlatformLibrary}`);
  }
  console.log(`doe-gpu native clean-install integration: skipped unstaged ${platformPackageName}`);
  process.exit(0);
}

const scratch = await mkdtemp(join(tmpdir(), 'doe-gpu-native-clean-install-'));
const npm = process.platform === 'win32' ? 'npm.cmd' : 'npm';

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
    return {
      host: runtimeHost,
      executable: process.execPath,
      version: process.version,
    };
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

try {
  const runtime = resolveRuntimeIdentity();
  const wrapper = pack(packageRoot, 'wrapper');
  const platform = pack(platformPackageRoot, 'platform');
  const fixtureManifest = {
    name: 'doe-gpu-native-clean-install-fixture',
    private: true,
    type: 'module',
  };
  if (runtimeHost === 'electron') {
    fixtureManifest.main = 'node_modules/doe-gpu/examples/electron-first-kernel.mjs';
  }
  await writeFile(
    resolve(scratch, 'package.json'),
    `${JSON.stringify(fixtureManifest, null, 2)}\n`,
  );
  const installed = execute(npm, [
    'install',
    '--ignore-scripts',
    '--omit=optional',
    '--no-audit',
    '--no-fund',
    wrapper.tarball,
    platform.tarball,
  ]);
  requireSuccess(installed, 'native clean install');

  const examplePath = resolve(
    scratch,
    `node_modules/doe-gpu/examples/${runtimeHost}-first-kernel.mjs`,
  );
  const runtimeArgs = runtimeHost === 'electron'
    ? electronArgs(scratch)
    : [examplePath];
  const executed = execute(runtime.executable, runtimeArgs);
  requireSuccess(executed, `installed native ${runtimeHost} first kernel`);
  const receipt = JSON.parse(executed.stdout);
  if (receipt.kind !== 'doe-gpu.first-kernel.receipt') {
    throw new Error(`unexpected receipt kind: ${receipt.kind}`);
  }
  if (receipt.provider?.loaded !== true || receipt.provider?.doeNative !== true) {
    throw new Error(`installed package did not load Doe native runtime: ${executed.stdout}`);
  }
  if (receipt.runtimeHost !== runtimeHost) {
    throw new Error(`installed package reported wrong runtime host: ${executed.stdout}`);
  }
  if (runtimeHost === 'electron' && receipt.runtimeVersion !== runtime.version) {
    throw new Error(`installed package reported wrong Electron version: ${executed.stdout}`);
  }
  if (runtimeHost === 'electron' && (
    receipt.mappedRangeProbe?.objectTag !== '[object ArrayBuffer]'
    || receipt.mappedRangeProbe?.sliceAvailable !== true
    || receipt.mappedRangeProbe?.value !== 42
  )) {
    throw new Error(`Electron mapped-range probe failed: ${executed.stdout}`);
  }
  if (receipt.provider?.buildMetadataSource !== 'prebuild') {
    throw new Error(`native runtime did not resolve from platform package: ${executed.stdout}`);
  }
  if (!receipt.provider?.doeLibraryPath?.includes(`/node_modules/${platformPackageName}/`)) {
    throw new Error(`native library escaped the clean install: ${executed.stdout}`);
  }
  const expected = [2, 4, 6, 8, 10, 12, 14, 16];
  if (JSON.stringify(receipt.result?.output) !== JSON.stringify(expected)) {
    throw new Error(`installed native kernel output mismatch: ${executed.stdout}`);
  }
  if (outputPath) {
    const artifact = {
      schemaVersion: 1,
      artifactKind: 'doe-gpu-native-clean-install-diagnostic',
      status: 'passed',
      tuple: { platform: process.platform, arch: process.arch },
      runtime: {
        ...runtime,
        sha256: await sha256File(runtime.executable),
      },
      installation: {
        lifecycleScripts: 'disabled',
        optionalDependencies: 'omitted',
        workspaceLibraryResolution: false,
      },
      launch: runtimeHost === 'electron'
        ? {
            mode: 'electron-main-process-node-side',
            arguments: electronArgs('<clean-install-app>'),
            rendererCreated: false,
          }
        : { mode: `${runtimeHost}-process`, arguments: ['<first-kernel>'] },
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
          path: 'packages/doe-gpu/test/integration/test-integration-native-clean-install.js',
          sha256: await sha256File(runnerPath),
        },
        firstKernel: {
          path: `packages/doe-gpu/examples/${runtimeHost}-first-kernel.mjs`,
          sha256: await sha256File(examplePath),
        },
        wrapperManifest: {
          path: 'packages/doe-gpu/package.json',
          sha256: await sha256File(resolve(packageRoot, 'package.json')),
        },
        platformManifest: {
          path: `packages/${platformPackageName}/package.json`,
          sha256: await sha256File(resolve(platformPackageRoot, 'package.json')),
        },
        stagedAddon: {
          path: `packages/${platformPackageName}/bin/doe_napi.node`,
          sha256: await sha256File(resolve(platformPackageRoot, 'bin', 'doe_napi.node')),
        },
        stagedBuildMetadata: {
          path: `packages/${platformPackageName}/bin/doe-build-metadata.json`,
          sha256: await sha256File(resolve(
            platformPackageRoot,
            'bin',
            'doe-build-metadata.json',
          )),
        },
      },
      receipt,
      decision: {
        nativePackageCleanInstall: 'authorized-for-declared-runtime-tuple',
        runtimeOwnershipCredit: false,
        performanceCredit: false,
        applicationPromotionCredit: false,
      },
      limitations: [
        'One first-kernel execution is package installation evidence, not the promotion reliability floor.',
        'This artifact does not generalize beyond its declared runtime, platform, and architecture.',
        ...(runtimeHost === 'electron' ? [
          'Electron evidence covers main-process Node-side compute without renderer creation.',
          'This artifact grants no Electron renderer, Chromium WebGPU, or browser lifecycle credit.',
        ] : []),
        'No performance interpretation is authorized.',
      ],
    };
    await mkdir(dirname(outputPath), { recursive: true });
    await writeFile(outputPath, `${JSON.stringify(artifact, null, 2)}\n`, { flag: 'wx' });
  }
  console.log(
    `doe-gpu native clean-install integration: ok ${runtimeHost} `
    + `${process.platform}-${process.arch}`,
  );
} finally {
  await rm(scratch, { recursive: true, force: true });
}

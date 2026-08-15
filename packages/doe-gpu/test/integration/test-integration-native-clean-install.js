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
    throw new Error(`${label} failed:\n${result.stdout}\n${result.stderr}`);
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

async function sha256File(path) {
  return createHash('sha256').update(await readFile(path)).digest('hex');
}

try {
  const wrapper = pack(packageRoot, 'wrapper');
  const platform = pack(platformPackageRoot, 'platform');
  await writeFile(resolve(scratch, 'package.json'), `${JSON.stringify({
    name: 'doe-gpu-native-clean-install-fixture',
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
  ]);
  requireSuccess(installed, 'native clean install');

  const examplePath = resolve(
    scratch,
    'node_modules/doe-gpu/examples/node-first-kernel.mjs',
  );
  const executed = execute(process.execPath, [examplePath]);
  requireSuccess(executed, 'installed native first kernel');
  const receipt = JSON.parse(executed.stdout);
  if (receipt.kind !== 'doe-gpu.first-kernel.receipt') {
    throw new Error(`unexpected receipt kind: ${receipt.kind}`);
  }
  if (receipt.provider?.loaded !== true || receipt.provider?.doeNative !== true) {
    throw new Error(`installed package did not load Doe native runtime: ${executed.stdout}`);
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
      installation: {
        lifecycleScripts: 'disabled',
        optionalDependencies: 'omitted',
        workspaceLibraryResolution: false,
      },
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
        nativePackageCleanInstall: 'authorized-for-declared-tuple',
        runtimeOwnershipCredit: false,
        performanceCredit: false,
        applicationPromotionCredit: false,
      },
      limitations: [
        'One first-kernel execution is package installation evidence, not the promotion reliability floor.',
        'This artifact does not generalize beyond its declared platform and architecture.',
        'No performance interpretation is authorized.',
      ],
    };
    await mkdir(dirname(outputPath), { recursive: true });
    await writeFile(outputPath, `${JSON.stringify(artifact, null, 2)}\n`, { flag: 'wx' });
  }
  console.log(`doe-gpu native clean-install integration: ok ${process.platform}-${process.arch}`);
} finally {
  await rm(scratch, { recursive: true, force: true });
}

import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { release, tmpdir } from 'node:os';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  bundleRelativePath,
  retainPackageArtifact,
  sha256File,
  sha256Json,
  unexpectedSourceChanges,
} from '../lib/native-release-candidate-bundle.js';

const here = dirname(fileURLToPath(import.meta.url));
const runnerPath = fileURLToPath(import.meta.url);
const reliabilityRunnerPath = resolve(
  here,
  'test-integration-native-clean-install-reliability.js',
);
const candidateFixturePath = resolve(here, '../fixtures/native-release-candidate.mjs');
const packageRoot = resolve(here, '../..');
const packagesRoot = dirname(packageRoot);
const repoRoot = dirname(packagesRoot);
const requireNative = process.argv.includes('--required')
  || process.env.DOE_REQUIRE_NATIVE_CLEAN_INSTALL === '1';
const releaseCandidate = process.argv.includes('--release-candidate');
const outputArgumentIndex = process.argv.indexOf('--out');
if (outputArgumentIndex !== -1 && !process.argv[outputArgumentIndex + 1]) {
  throw new Error('--out requires a path');
}
const outputPath = outputArgumentIndex === -1
  ? null
  : resolve(process.argv[outputArgumentIndex + 1]);
const reliabilityArgumentIndex = process.argv.indexOf('--reliability');
if (reliabilityArgumentIndex !== -1 && !process.argv[reliabilityArgumentIndex + 1]) {
  throw new Error('--reliability requires a path');
}
const requestedReliabilityPath = reliabilityArgumentIndex === -1
  ? null
  : resolve(process.argv[reliabilityArgumentIndex + 1]);
if (releaseCandidate && !outputPath) {
  throw new Error('--release-candidate requires --out');
}
const reliabilityPath = requestedReliabilityPath ?? (
  releaseCandidate
    ? outputPath.replace(/\.json$/u, '.reliability.json')
    : null
);
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

function execute(command, args, cwd = scratch, env = undefined) {
  return spawnSync(command, args, {
    cwd,
    ...(env ? { env } : {}),
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

function repoRelativePath(path) {
  const resolved = resolve(path);
  const repoRelative = relative(repoRoot, resolved);
  if (repoRelative === '..' || repoRelative.startsWith(`..${sep}`)) {
    throw new Error(`release-candidate evidence must stay inside the repository: ${resolved}`);
  }
  return repoRelative.split(sep).join('/');
}

function requireCandidateRun(result, label) {
  requireSuccess(result, label);
  let artifact;
  try {
    artifact = JSON.parse(result.stdout);
  } catch (error) {
    throw new Error(`${label} emitted invalid JSON: ${error.message}\n${result.stdout}`);
  }
  const receipt = artifact.receipt;
  if (artifact.artifactKind !== 'doe-gpu-native-release-candidate-run'
      || artifact.runtimeHost !== runtimeHost
      || artifact.ok !== true
      || artifact.validation?.valid !== true
      || artifact.errors?.length !== 0
      || receipt?.schema !== 'doe.governed-node-webgpu-receipt/v1'
      || receipt?.status !== 'pass'
      || receipt?.checkpoint !== 'release-complete'
      || receipt?.provider?.selectedProviderId !== 'doe-native-0.5.0'
      || receipt?.adapterInfoStatus !== 'observed'
      || !receipt?.adapterInfo?.vendor
      || !receipt?.adapterInfo?.device
      || receipt?.oracle?.status !== 'pass'
      || receipt?.oracle?.actualOutputSha256 !== receipt?.oracle?.expectedOutputSha256
      || receipt?.lifecycle?.status !== 'release-complete'
      || receipt?.lifecycle?.globalsRestored !== true
      || !receipt?.replay?.workloadSha256
      || !receipt?.replay?.executionSha256
      || JSON.stringify(artifact.output) !== JSON.stringify([2, 4, 6, 8, 10, 12, 14, 16])) {
    throw new Error(`${label} failed the governed candidate contract: ${result.stdout}`);
  }
  return artifact;
}

function requireReliabilityEvidence(report, runtime, wrapper, platform) {
  if (report?.artifactKind !== 'doe-gpu-native-clean-install-reliability-diagnostic'
      || report?.status !== 'passed'
      || report?.tuple?.runtime !== runtime
      || report?.tuple?.platform !== process.platform
      || report?.tuple?.arch !== process.arch
      || report?.packages?.wrapper?.sha256 !== wrapper
      || report?.packages?.platform?.sha256 !== platform
      || report?.decision?.boundedCleanProcessReliability
        !== 'authorized-for-declared-runtime-tuple'
      || report?.decision?.boundedSameProcessLifecycle
        !== 'authorized-for-declared-runtime-tuple'
      || report?.decision?.deliberateDestroyLossSemantics
        !== 'authorized-for-declared-runtime-tuple') {
    throw new Error('reliability evidence does not match the release-candidate tuple and bytes');
  }
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
  let sourceCommit = null;
  if (releaseCandidate) {
    repoRelativePath(outputPath);
    repoRelativePath(reliabilityPath);
    if (!outputPath.endsWith('.json')) {
      throw new Error('release-candidate --out must end in .json');
    }
    if (dirname(outputPath) !== dirname(reliabilityPath)) {
      throw new Error('release-candidate reliability evidence must share the report directory');
    }
    const checkoutStatus = execute(
      'git',
      ['status', '--short', '--untracked-files=all'],
      repoRoot,
    );
    requireSuccess(checkoutStatus, 'release-candidate source checkout check');
    const bundleRoot = repoRelativePath(dirname(outputPath));
    const unexpectedChanges = unexpectedSourceChanges(
      checkoutStatus.stdout,
      bundleRoot,
    );
    if (unexpectedChanges.length > 0) {
      throw new Error(
        'release-candidate source checkout has changes outside its evidence bundle:\n'
        + `${unexpectedChanges.join('\n')}\n`,
      );
    }
    const revision = execute('git', ['rev-parse', 'HEAD'], repoRoot);
    requireSuccess(revision, 'release-candidate source revision');
    sourceCommit = revision.stdout.trim();
  }
  const runtime = resolveRuntimeIdentity();
  if (releaseCandidate && requestedReliabilityPath === null) {
    const reliability = execute(process.execPath, [
      reliabilityRunnerPath,
      '--required',
      '--runtime',
      runtimeHost,
      '--out',
      reliabilityPath,
    ], packageRoot);
    requireSuccess(reliability, `native ${runtimeHost} release-candidate reliability`);
  }
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
  let candidateEvidence = null;
  if (releaseCandidate) {
    const installedCandidateFixture = resolve(scratch, 'native-release-candidate.mjs');
    await copyFile(candidateFixturePath, installedCandidateFixture);
    if (runtimeHost === 'electron') {
      fixtureManifest.main = 'native-release-candidate.mjs';
      await writeFile(
        resolve(scratch, 'package.json'),
        `${JSON.stringify(fixtureManifest, null, 2)}\n`,
      );
    }
    const candidateEnv = {
      ...process.env,
      DOE_NATIVE_RELEASE_CANDIDATE_RUNTIME: runtimeHost,
    };
    const candidateArgs = runtimeHost === 'electron'
      ? electronArgs(scratch)
      : [installedCandidateFixture];
    const primary = requireCandidateRun(
      execute(runtime.executable, candidateArgs, scratch, candidateEnv),
      `installed native ${runtimeHost} governed candidate primary`,
    );
    const replay = requireCandidateRun(
      execute(runtime.executable, candidateArgs, scratch, candidateEnv),
      `installed native ${runtimeHost} governed candidate replay`,
    );
    const matches = {
      workload: primary.receipt.replay.workloadSha256
        === replay.receipt.replay.workloadSha256,
      execution: primary.receipt.replay.executionSha256
        === replay.receipt.replay.executionSha256,
      adapter: sha256Json(primary.receipt.adapterInfo)
        === sha256Json(replay.receipt.adapterInfo),
      output: primary.receipt.oracle.actualOutputSha256
        === replay.receipt.oracle.actualOutputSha256,
      lifecycle: primary.receipt.lifecycle.status === replay.receipt.lifecycle.status
        && primary.receipt.lifecycle.globalsRestored === replay.receipt.lifecycle.globalsRestored,
    };
    if (Object.values(matches).some((value) => value !== true)) {
      throw new Error(`governed ${runtimeHost} replay identity mismatch: ${JSON.stringify(matches)}`);
    }
    candidateEvidence = { primary, replay, matches };
  }
  if (outputPath) {
    const wrapperSha256 = await sha256File(wrapper.tarball);
    const platformSha256 = await sha256File(platform.tarball);
    const retainedArtifacts = releaseCandidate
      ? {
          wrapper: await retainPackageArtifact({
            packed: wrapper,
            expectedSha256: wrapperSha256,
            bundleRoot: dirname(outputPath),
          }),
          platform: await retainPackageArtifact({
            packed: platform,
            expectedSha256: platformSha256,
            bundleRoot: dirname(outputPath),
          }),
        }
      : null;
    const reliabilityReport = releaseCandidate
      ? JSON.parse(await readFile(reliabilityPath, 'utf8'))
      : null;
    if (releaseCandidate) {
      requireReliabilityEvidence(
        reliabilityReport,
        runtimeHost,
        wrapperSha256,
        platformSha256,
      );
    }
    const baseArtifact = {
      schemaVersion: 1,
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
          sha256: wrapperSha256,
          ...(retainedArtifacts ? { artifactPath: retainedArtifacts.wrapper } : {}),
        },
        platform: {
          id: platform.manifest.id,
          bytes: platform.manifest.size,
          sha256: platformSha256,
          ...(retainedArtifacts ? { artifactPath: retainedArtifacts.platform } : {}),
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
    };
    const artifact = releaseCandidate
      ? {
          ...baseArtifact,
          schemaVersion: 2,
          artifactKind: 'doe-gpu-native-release-candidate',
          generatedAt: new Date().toISOString(),
          sourceCommit,
          host: {
            platform: process.platform,
            arch: process.arch,
            kernelRelease: release(),
          },
          implementation: {
            ...baseArtifact.implementation,
            candidateFixture: {
              path: 'packages/doe-gpu/test/fixtures/native-release-candidate.mjs',
              sha256: await sha256File(candidateFixturePath),
            },
          },
          governedReplay: {
            primaryReceipt: candidateEvidence.primary.receipt,
            primaryReceiptSha256: sha256Json(candidateEvidence.primary.receipt),
            replayReceipt: candidateEvidence.replay.receipt,
            replayReceiptSha256: sha256Json(candidateEvidence.replay.receipt),
            workloadSha256: candidateEvidence.primary.receipt.replay.workloadSha256,
            executionSha256: candidateEvidence.primary.receipt.replay.executionSha256,
            adapterInfo: candidateEvidence.primary.receipt.adapterInfo,
            adapterInfoSha256: sha256Json(candidateEvidence.primary.receipt.adapterInfo),
            outputSha256: candidateEvidence.primary.receipt.oracle.actualOutputSha256,
            matches: candidateEvidence.matches,
          },
          reliabilityEvidence: {
            path: bundleRelativePath(reliabilityPath, dirname(outputPath)),
            sha256: await sha256File(reliabilityPath),
            artifactKind: reliabilityReport.artifactKind,
            status: reliabilityReport.status,
          },
          decision: {
            packageReleaseCandidate: 'eligible-for-declared-runtime-tuple',
            registryPublicationCredit: false,
            runtimeOwnershipCredit: false,
            performanceCredit: false,
            applicationPromotionCredit: false,
          },
          limitations: [
            'Candidate authority is limited to the declared runtime, platform, architecture, adapter, driver, and package bytes.',
            'Registry publication requires separately authenticated npm publication readiness.',
            ...(runtimeHost === 'electron' ? [
              'Electron evidence covers main-process Node-side compute without renderer creation.',
              'This artifact grants no Electron renderer, Chromium WebGPU, or browser lifecycle credit.',
            ] : []),
            'No performance, runtime-ownership, or application-promotion interpretation is authorized.',
          ],
        }
      : {
          ...baseArtifact,
          artifactKind: 'doe-gpu-native-clean-install-diagnostic',
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

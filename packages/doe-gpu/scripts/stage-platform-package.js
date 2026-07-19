#!/usr/bin/env node

// doe-gpu — stage a platform package bin payload from workspace native artifacts.

import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

// Repo-relative root of the WGSL compiler source tree whose sha256 the
// Zig build emits into doe-build-metadata.json. Keep in lockstep with
// runtime/zig/build.zig hashWgslCompilerSourceTreeAlloc().
const WGSL_COMPILER_SOURCE_REPO_REL_ROOT = 'runtime/zig/src/compiler/wgsl';
const WGSL_COMPILER_SOURCE_SUFFIX = '.zig';

const LIBRARY_FILENAMES = Object.freeze({
  darwin: 'libwebgpu_doe.dylib',
  linux: 'libwebgpu_doe.so',
  win32: 'webgpu_doe.dll',
});

const __dirname = dirname(fileURLToPath(import.meta.url));

function readJsonFile(path) {
  return JSON.parse(readFileSync(path, 'utf8'));
}

function resolveExistingPath(candidates, label) {
  for (const candidate of candidates) {
    if (candidate && existsSync(candidate)) {
      return candidate;
    }
  }
  throw new Error(`doe-gpu: missing ${label}. Checked: ${candidates.filter(Boolean).join(', ')}`);
}

function parseBuildMetadata(metadataPath) {
  const parsed = readJsonFile(metadataPath);
  if (parsed?.schemaVersion !== 1 || parsed?.artifact !== 'libwebgpu_doe') {
    throw new Error(`doe-gpu: unsupported Doe build metadata at "${metadataPath}".`);
  }
  return parsed;
}

// Mirror of runtime/zig/build.zig hashSourceTreeAlloc for the WGSL compiler
// source tree. Must match byte-for-byte: file list is every `.zig` under
// `runtime/zig/src/compiler/wgsl/`, sorted lexicographically by their path
// relative to that root, then hashed as:
//   sha256(
//     for each relPath:
//       repoRelRoot + '/' + relPath + '\n' + fileContents + '\n'
//   )
// If this mirror diverges from the Zig implementation, the freshness
// guard below will reject a correctly-built .so as stale — so any change
// to one side must be mirrored on the other in the same commit.
export function collectWgslCompilerSourceRelPaths(rootPath) {
  const collected = [];
  function recurse(currentPath, currentRelPrefix) {
    const entries = readdirSync(currentPath, { withFileTypes: true });
    for (const entry of entries) {
      const nextRel = currentRelPrefix === ''
        ? entry.name
        : `${currentRelPrefix}/${entry.name}`;
      const fullPath = `${currentPath}${sep}${entry.name}`;
      if (entry.isDirectory()) {
        recurse(fullPath, nextRel);
      } else if (entry.isFile() && entry.name.endsWith(WGSL_COMPILER_SOURCE_SUFFIX)) {
        collected.push(nextRel);
      }
    }
  }
  recurse(rootPath, '');
  // Byte-order sort on ASCII paths matches Zig's std.mem.lessThan(u8, ...).
  collected.sort();
  return collected;
}

export function hashWgslCompilerSourceTree(rootPath) {
  const relPaths = collectWgslCompilerSourceRelPaths(rootPath);
  const hasher = createHash('sha256');
  for (const relPath of relPaths) {
    hasher.update(`${WGSL_COMPILER_SOURCE_REPO_REL_ROOT}/${relPath}`);
    hasher.update('\n');
    hasher.update(readFileSync(`${rootPath}${sep}${relPath.split('/').join(sep)}`));
    hasher.update('\n');
  }
  return hasher.digest('hex');
}

function assertBuildMetadataIsFresh(buildMetadata, workspaceRoot, packageName) {
  if (process.env.DOE_SKIP_NATIVE_FRESHNESS_CHECK === '1') {
    console.warn(
      `doe-gpu: DOE_SKIP_NATIVE_FRESHNESS_CHECK=1 — staging ${packageName} without ` +
      'verifying libwebgpu_doe was built from the current WGSL compiler source tree. ' +
      'Use only for out-of-band testing; never for publishing.',
    );
    return;
  }
  const metadataHash = buildMetadata?.wgslCompilerSourceSha256;
  if (typeof metadataHash !== 'string' || metadataHash.length !== 64) {
    throw new Error(
      `doe-gpu: ${packageName}: doe-build-metadata.json is missing wgslCompilerSourceSha256. ` +
      'This build predates the publish-time freshness contract. Rebuild with ' +
      '`cd runtime/zig && zig build dropin -Doptimize=ReleaseFast` and re-stage.',
    );
  }
  const sourceRoot = resolve(
    workspaceRoot,
    'runtime',
    'zig',
    'src',
    'compiler',
    'wgsl',
  );
  if (!existsSync(sourceRoot)) {
    throw new Error(`doe-gpu: WGSL compiler source tree not found at ${sourceRoot}.`);
  }
  const currentHash = hashWgslCompilerSourceTree(sourceRoot);
  if (currentHash !== metadataHash) {
    throw new Error(
      `doe-gpu: ${packageName}: staged libwebgpu_doe predates the current ` +
      `WGSL compiler source. Expected wgslCompilerSourceSha256=${currentHash} (fresh), ` +
      `got ${metadataHash} (from doe-build-metadata.json). Rebuild with ` +
      '`cd runtime/zig && zig build dropin -Doptimize=ReleaseFast` before staging ' +
      'so downstream consumers do not load a SPIR-V emitter that predates source fixes. ' +
      'Set DOE_SKIP_NATIVE_FRESHNESS_CHECK=1 only when testing the staging script itself.',
    );
  }
}

function writePrebuildMetadata(sidecar, metadataPath) {
  const payload = {
    schemaVersion: 1,
    doeBuild: {
      artifact: sidecar.artifact,
      leanVerifiedBuild: sidecar.leanVerifiedBuild,
      proofArtifactSha256: sidecar.proofArtifactSha256 ?? null,
    },
  };
  writeFileSync(metadataPath, `${JSON.stringify(payload, null, 2)}\n`);
}

function currentHostTag() {
  return `${process.platform}-${process.arch}`;
}

function main() {
  const targetPackageRoot = process.cwd();
  const packageJsonPath = resolve(targetPackageRoot, 'package.json');
  if (!existsSync(packageJsonPath)) {
    throw new Error(`doe-gpu: missing package.json in "${targetPackageRoot}".`);
  }
  const packageJson = readJsonFile(packageJsonPath);
  const targetPlatform = Array.isArray(packageJson.os) ? packageJson.os[0] : null;
  const targetArch = Array.isArray(packageJson.cpu) ? packageJson.cpu[0] : null;
  if (!targetPlatform || !targetArch) {
    throw new Error(`doe-gpu: package "${packageJson.name}" must declare os/cpu for staging.`);
  }

  const workspaceRoot = resolve(targetPackageRoot, '..', '..');
  const targetHostTag = `${targetPlatform}-${targetArch}`;
  const expectedCurrentHost = currentHostTag();
  const libraryFilename = LIBRARY_FILENAMES[targetPlatform];
  if (!libraryFilename) {
    throw new Error(`doe-gpu: unsupported package platform "${targetPlatform}".`);
  }

  if (
    targetHostTag !== expectedCurrentHost
    && !process.env.DOE_NAPI_ADDON
    && !process.env.DOE_WEBGPU_LIB
    && !process.env.DOE_LIB
  ) {
    throw new Error(
      `doe-gpu: ${packageJson.name} targets ${targetHostTag}, but the current host is ${expectedCurrentHost}. ` +
      'Provide DOE_NAPI_ADDON and DOE_WEBGPU_LIB/DOE_LIB from a matching build artifact when staging cross-host packages.',
    );
  }

  const addonPath = resolveExistingPath([
    process.env.DOE_NAPI_ADDON,
    resolve(workspaceRoot, 'packages', 'doe-gpu', 'build', 'Release', 'doe_napi.node'),
    resolve(workspaceRoot, 'packages', 'doe-gpu', 'src', 'vendor', 'build', 'Release', 'doe_napi.node'),
  ], `${packageJson.name} addon`);
  const libraryPath = resolveExistingPath([
    process.env.DOE_WEBGPU_LIB,
    process.env.DOE_LIB,
    resolve(workspaceRoot, 'runtime', 'zig', 'zig-out', 'lib', libraryFilename),
  ], `${packageJson.name} shared library`);
  const buildMetadataPath = resolveExistingPath([
    process.env.DOE_BUILD_METADATA,
    resolve(workspaceRoot, 'runtime', 'zig', 'zig-out', 'share', 'doe-build-metadata.json'),
  ], `${packageJson.name} build metadata`);

  const buildMetadata = parseBuildMetadata(buildMetadataPath);
  assertBuildMetadataIsFresh(buildMetadata, workspaceRoot, packageJson.name);
  const binRoot = resolve(targetPackageRoot, 'bin');
  rmSync(binRoot, { recursive: true, force: true });
  mkdirSync(binRoot, { recursive: true });

  copyFileSync(addonPath, resolve(binRoot, 'doe_napi.node'));
  copyFileSync(libraryPath, resolve(binRoot, libraryFilename));
  copyFileSync(buildMetadataPath, resolve(binRoot, 'doe-build-metadata.json'));
  writePrebuildMetadata(buildMetadata, resolve(binRoot, 'metadata.json'));

  console.log(`doe-gpu: staged ${packageJson.name} from workspace artifacts`);
}

// Only run main() when invoked directly; imports from tests should not
// trigger staging.
if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}

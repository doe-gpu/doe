import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

const EXPECTED_SCHEMA_VERSION = 1;
const EXPECTED_ARTIFACT_TYPE = 'libwebgpu_doe';

export const UNKNOWN_DOE_BUILD_METADATA = Object.freeze({
  source: 'none',
  path: '',
  leanVerifiedBuild: null,
  proofArtifactSha256: null,
});

function isObject(value) {
  return value != null && typeof value === 'object' && !Array.isArray(value);
}

function normalizeProofArtifactSha256(value) {
  return value == null ? null : typeof value === 'string' ? value : undefined;
}

function parseDoeBuildSidecar(json, metadataPath, source) {
  if (!isObject(json)) return null;
  if (json.schemaVersion !== EXPECTED_SCHEMA_VERSION) return null;
  if (json.artifact !== EXPECTED_ARTIFACT_TYPE) return null;
  if (typeof json.leanVerifiedBuild !== 'boolean') return null;
  const proofArtifactSha256 = normalizeProofArtifactSha256(json.proofArtifactSha256);
  if (proofArtifactSha256 === undefined) return null;
  return {
    source,
    path: metadataPath,
    leanVerifiedBuild: json.leanVerifiedBuild,
    proofArtifactSha256,
  };
}

function parsePrebuildMetadata(json, metadataPath, source) {
  if (!isObject(json)) return null;
  if (json.schemaVersion !== EXPECTED_SCHEMA_VERSION) return null;
  const doeBuild = json.doeBuild;
  if (!isObject(doeBuild)) return null;
  if (doeBuild.artifact !== EXPECTED_ARTIFACT_TYPE) return null;
  if (typeof doeBuild.leanVerifiedBuild !== 'boolean') return null;
  const proofArtifactSha256 = normalizeProofArtifactSha256(doeBuild.proofArtifactSha256);
  if (proofArtifactSha256 === undefined) return null;
  return {
    source,
    path: metadataPath,
    leanVerifiedBuild: doeBuild.leanVerifiedBuild,
    proofArtifactSha256,
  };
}

function readJsonFile(metadataPath) {
  try {
    return JSON.parse(readFileSync(metadataPath, 'utf8'));
  } catch {
    return null;
  }
}

function metadataPathExists(metadataPath) {
  try {
    return existsSync(metadataPath);
  } catch {
    // Node's permission model throws for undeclared optional probes. Treat the
    // candidate as unavailable and continue to an explicitly readable sidecar.
    return false;
  }
}

export function readDoeBuildMetadataFile(metadataPath) {
  if (!metadataPath || !metadataPathExists(metadataPath)) return null;
  const parsed = readJsonFile(metadataPath);
  return parseDoeBuildSidecar(parsed, metadataPath, 'zig-out');
}

function loadMetadataCandidate(metadataPath, parser, source) {
  if (!metadataPath || !metadataPathExists(metadataPath)) return null;
  const parsed = readJsonFile(metadataPath);
  return parser(parsed, metadataPath, source);
}

export function loadDoeBuildMetadata({ packageRoot = '', libraryPath = '' } = {}) {
  const seen = new Set();
  const candidates = [];

  const pushCandidate = (metadataPath, parser, source) => {
    if (!metadataPath || seen.has(metadataPath)) return;
    seen.add(metadataPath);
    candidates.push({ metadataPath, parser, source });
  };

  pushCandidate(process.env.DOE_BUILD_METADATA ?? '', parseDoeBuildSidecar, 'env');

  if (libraryPath) {
    const libraryDir = dirname(libraryPath);
    pushCandidate(resolve(libraryDir, 'metadata.json'), parsePrebuildMetadata, 'prebuild');
    pushCandidate(resolve(libraryDir, 'doe-build-metadata.json'), parseDoeBuildSidecar, 'adjacent');
    pushCandidate(resolve(libraryDir, '..', 'share', 'doe-build-metadata.json'), parseDoeBuildSidecar, 'workspace');
  }

  if (packageRoot) {
    pushCandidate(
      resolve(packageRoot, 'prebuilds', `${process.platform}-${process.arch}`, 'metadata.json'),
      parsePrebuildMetadata,
      'package-prebuild',
    );
  }

  for (const candidate of candidates) {
    const parsed = loadMetadataCandidate(candidate.metadataPath, candidate.parser, candidate.source);
    if (parsed) return parsed;
  }

  return UNKNOWN_DOE_BUILD_METADATA;
}

import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import path from "node:path";

function nonEmptyString(...values) {
  for (const value of values) {
    if (typeof value === "string" && value.trim().length > 0) {
      return value.trim();
    }
  }
  return null;
}

function sha256Urn(value) {
  if (typeof value !== "string" || value.length === 0) {
    return null;
  }
  return value.startsWith("sha256:") ? value : `sha256:${value}`;
}

async function sha256File(filePath) {
  const bytes = await readFile(filePath);
  return `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
}

function collectMissingIdentity(identity, reasons = {}) {
  const missing = {};
  for (const [field, value] of Object.entries(identity)) {
    if (value === null || value === undefined || value === "") {
      missing[field] = { reason: reasons[field] ?? `${field}_unavailable` };
    }
  }
  return missing;
}

async function hashIfNamed(filePath, fieldName, missingReasons) {
  if (!filePath) {
    return null;
  }
  const absolute = path.resolve(filePath);
  if (!existsSync(absolute)) {
    missingReasons[fieldName] = `${fieldName}_source_file_missing`;
    return null;
  }
  return sha256File(absolute);
}

export async function collectDopplerBrowserIdentity(config, {
  modelArtifactPath,
} = {}) {
  const runtimeConfig = config?.runtimeConfig && typeof config.runtimeConfig === "object"
    ? config.runtimeConfig
    : {};
  const explicitManifestPath = nonEmptyString(
    config?.manifestPath,
    runtimeConfig.manifestPath,
  );
  const defaultManifestPath = modelArtifactPath ? path.join(modelArtifactPath, "manifest.json") : null;
  const manifestPath = explicitManifestPath
    ?? (defaultManifestPath && existsSync(defaultManifestPath) ? defaultManifestPath : null);
  const runtimeProfilePath = nonEmptyString(
    config?.runtimeProfilePath,
    runtimeConfig.runtimeProfilePath,
    runtimeConfig.profilePath,
  );
  const kernelRegistryPath = nonEmptyString(
    config?.kernelRegistryPath,
    runtimeConfig.kernelRegistryPath,
  );
  const missingReasons = {};
  const identity = {
    modelId: nonEmptyString(config?.modelId, runtimeConfig.modelId),
    manifestPath,
    manifestSha256: sha256Urn(
      config?.manifestSha256
      ?? runtimeConfig.manifestSha256
      ?? await hashIfNamed(manifestPath, "manifestSha256", missingReasons),
    ),
    runtimeProfileId: nonEmptyString(
      config?.runtimeProfileId,
      runtimeConfig.runtimeProfileId,
      runtimeConfig.profileId,
      runtimeConfig.id,
    ),
    runtimeProfilePath,
    runtimeProfileSha256: sha256Urn(
      config?.runtimeProfileSha256
      ?? runtimeConfig.runtimeProfileSha256
      ?? await hashIfNamed(runtimeProfilePath, "runtimeProfileSha256", missingReasons),
    ),
    kernelRegistryPath,
    kernelRegistrySha256: sha256Urn(
      config?.kernelRegistrySha256
      ?? runtimeConfig.kernelRegistrySha256
      ?? await hashIfNamed(kernelRegistryPath, "kernelRegistrySha256", missingReasons),
    ),
    shardSetHash: sha256Urn(config?.shardSetHash ?? runtimeConfig.shardSetHash),
    inputContractSha256: sha256Urn(
      config?.inputContractSha256 ?? runtimeConfig.inputContractSha256,
    ),
  };
  const missing = collectMissingIdentity(identity, missingReasons);
  return Object.freeze({
    ...identity,
    ...(Object.keys(missing).length > 0 ? { missing } : {}),
  });
}

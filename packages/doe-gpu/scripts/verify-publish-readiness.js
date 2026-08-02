#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const registry = process.env.npm_config_registry || 'https://registry.npmjs.org/';

function runNpm(args) {
  const command = process.platform === 'win32' ? 'npm.cmd' : 'npm';
  const result = spawnSync(command, [...args, `--registry=${registry}`], {
    cwd: packageRoot,
    encoding: 'utf8',
  });
  if (result.status !== 0) {
    throw new Error((result.stderr || result.stdout || `npm exited ${result.status}`).trim());
  }
  return result.stdout.trim();
}

function normalizeConstraint(value) {
  if (Array.isArray(value)) return value;
  return value == null ? [] : [value];
}

const packageJson = JSON.parse(await fs.readFile(path.join(packageRoot, 'package.json'), 'utf8'));
const account = runNpm(['whoami']);
if (!account) throw new Error('npm authentication returned an empty account name.');

const verifiedPlatforms = [];
for (const [name, version] of Object.entries(packageJson.optionalDependencies ?? {})) {
  if (version !== packageJson.version) {
    throw new Error(
      `${name} must use the main package version ${packageJson.version}; found ${version}.`,
    );
  }
  const metadata = JSON.parse(
    runNpm(['view', `${name}@${version}`, 'version', 'dist.integrity', 'cpu', 'os', '--json']),
  );
  if (metadata.version !== version || typeof metadata['dist.integrity'] !== 'string') {
    throw new Error(`${name}@${version} is not a complete published platform package.`);
  }
  const suffix = name.slice('doe-gpu-'.length);
  const separator = suffix.lastIndexOf('-');
  const expectedOs = suffix.slice(0, separator);
  const expectedCpu = suffix.slice(separator + 1);
  if (
    !normalizeConstraint(metadata.os).includes(expectedOs)
    || !normalizeConstraint(metadata.cpu).includes(expectedCpu)
  ) {
    throw new Error(`${name}@${version} registry cpu/os metadata does not match ${suffix}.`);
  }
  verifiedPlatforms.push({ name, version, integrity: metadata['dist.integrity'] });
}

console.log(JSON.stringify({
  ok: true,
  schema: 'doe.npm-publish-preflight/v1',
  account,
  registry,
  package: { name: packageJson.name, version: packageJson.version },
  verifiedPlatforms,
}, null, 2));

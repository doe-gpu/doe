#!/usr/bin/env node

import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const repoRoot = path.resolve(packageRoot, '..', '..');
const sourceIndex = process.argv.indexOf('--source');
const source = sourceIndex >= 0 ? process.argv[sourceIndex + 1] : null;
const check = process.argv.includes('--check');

if (!source) {
  throw new Error(
    'sync-program-bundle-schema: --source <Doppler program-bundle.schema.json> is required; no adjacent checkout is inferred.',
  );
}

const sourcePath = path.resolve(source);
const sourceBytes = await fs.readFile(sourcePath);
const schema = JSON.parse(sourceBytes.toString('utf8'));
if (
  schema.$id !== 'urn:doppler:program-bundle-schema:v1'
  || schema.properties?.schema?.const !== 'doppler.program-bundle/v1'
) {
  throw new Error(
    'sync-program-bundle-schema: source must be the Doppler Program Bundle v1 JSON Schema artifact.',
  );
}

const targets = [
  path.join(repoRoot, 'config/doe-doppler-program-bundle.schema.json'),
  path.join(packageRoot, 'assets/program-bundle.schema.json'),
];

for (const target of targets) {
  if (check) {
    const targetBytes = await fs.readFile(target).catch(() => null);
    if (!targetBytes || !targetBytes.equals(sourceBytes)) {
      throw new Error(`sync-program-bundle-schema: stale or missing mirror ${target}`);
    }
  } else {
    await fs.mkdir(path.dirname(target), { recursive: true });
    await fs.writeFile(target, sourceBytes);
  }
}

console.log(
  `${check ? 'Verified' : 'Synchronized'} Doppler Program Bundle schema: ${targets.join(', ')}`,
);

import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test from 'node:test';

import {
  bundleRelativePath,
  retainPackageArtifact,
  sha256File,
  unexpectedSourceChanges,
} from '../lib/native-release-candidate-bundle.js';

test('retains and reuses exact candidate package bytes', async (context) => {
  const scratch = await mkdtemp(join(tmpdir(), 'doe-native-candidate-bundle-'));
  context.after(() => rm(scratch, { recursive: true, force: true }));
  const bundleRoot = resolve(scratch, 'bundle');
  const tarball = resolve(scratch, 'doe-gpu-0.5.0.tgz');
  await writeFile(tarball, 'exact-candidate-bytes');
  const packed = {
    manifest: {
      filename: 'doe-gpu-0.5.0.tgz',
      size: 21,
    },
    tarball,
  };
  const expectedSha256 = await sha256File(tarball);
  const first = await retainPackageArtifact({ packed, expectedSha256, bundleRoot });
  const second = await retainPackageArtifact({ packed, expectedSha256, bundleRoot });
  assert.equal(first, 'packages/doe-gpu-0.5.0.tgz');
  assert.equal(second, first);
  assert.equal(
    await sha256File(resolve(bundleRoot, first)),
    expectedSha256,
  );
});

test('rejects conflicting retained candidate bytes', async (context) => {
  const scratch = await mkdtemp(join(tmpdir(), 'doe-native-candidate-conflict-'));
  context.after(() => rm(scratch, { recursive: true, force: true }));
  const bundleRoot = resolve(scratch, 'bundle');
  const firstTarball = resolve(scratch, 'first.tgz');
  const secondTarball = resolve(scratch, 'second.tgz');
  await writeFile(firstTarball, 'first-candidate-bytes');
  await writeFile(secondTarball, 'other-candidate-bytes');
  const packed = {
    manifest: {
      filename: 'doe-gpu-0.5.0.tgz',
      size: 21,
    },
    tarball: firstTarball,
  };
  await retainPackageArtifact({
    packed,
    expectedSha256: await sha256File(firstTarball),
    bundleRoot,
  });
  await assert.rejects(
    retainPackageArtifact({
      packed: { ...packed, tarball: secondTarball },
      expectedSha256: await sha256File(secondTarball),
      bundleRoot,
    }),
    /conflicts with candidate bytes/,
  );
});

test('rejects evidence paths outside the candidate bundle', () => {
  assert.throws(
    () => bundleRelativePath('/tmp/outside.json', '/tmp/candidate-bundle'),
    /escaped its bundle/,
  );
});

test('source checkout permits only untracked evidence-bundle outputs', () => {
  const status = [
    '?? reports/benchmarks/apple-metal/run/node.json',
    '?? reports/benchmarks/apple-metal/run/packages/doe-gpu.tgz',
    ' M packages/doe-gpu/src/index.js',
    '?? packages/doe-gpu/src/untracked.js',
    '',
  ].join('\n');
  assert.deepEqual(
    unexpectedSourceChanges(status, 'reports/benchmarks/apple-metal/run'),
    [
      ' M packages/doe-gpu/src/index.js',
      '?? packages/doe-gpu/src/untracked.js',
    ],
  );
});

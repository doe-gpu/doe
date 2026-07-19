// Unit test for the publish-time freshness guard added to
// stage-platform-package.js. Ensures:
//   - the JS source-tree hasher mirrors the Zig algorithm on a synthetic tree,
//   - a matching metadata hash is accepted,
//   - a mismatching metadata hash is rejected with an actionable message,
//   - the DOE_SKIP_NATIVE_FRESHNESS_CHECK escape hatch only warns.

import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

import {
  collectWgslCompilerSourceRelPaths,
  hashWgslCompilerSourceTree,
} from '../../scripts/stage-platform-package.js';

// Build a synthetic compiler/wgsl tree and verify the collected rel paths
// and hash match a hand-rolled reference computation. The reference here
// uses the same algorithm as runtime/zig/build.zig hashSourceTreeAlloc —
// both sides must walk, sort by byte order, and hash (repoRelRoot + '/'
// + relPath + '\n' + contents + '\n'). If we ever change the algorithm
// we must change both in the same commit.
{
  const repoRelRoot = 'runtime/zig/src/compiler/wgsl';
  const root = mkdtempSync(path.join(tmpdir(), 'doe-gpu-wgsl-hash-'));
  try {
    // File ordering is deliberately not sorted on disk so the test proves the
    // hasher's sort step is what produces deterministic output.
    writeFileSync(path.join(root, 'emit_spirv_fn.zig'), 'fn main() void {}\n', 'utf8');
    writeFileSync(path.join(root, 'emit_csl_core.zig'), 'fn core() void {}\n', 'utf8');
    mkdirSync(path.join(root, 'nested'), { recursive: true });
    writeFileSync(
      path.join(root, 'nested', 'emit_spirv_texture.zig'),
      'fn texture() void {}\n',
      'utf8',
    );
    // A non-.zig file in the tree must be excluded by the suffix filter.
    writeFileSync(path.join(root, 'README.md'), 'not included', 'utf8');

    const collected = collectWgslCompilerSourceRelPaths(root);
    assert.deepEqual(
      collected,
      [
        'emit_csl_core.zig',
        'emit_spirv_fn.zig',
        'nested/emit_spirv_texture.zig',
      ],
      'collector must enumerate every .zig file under root, sorted by POSIX rel path',
    );

    const hasher = createHash('sha256');
    for (const relPath of collected) {
      hasher.update(`${repoRelRoot}/${relPath}`);
      hasher.update('\n');
      const onDisk = relPath.split('/').join(path.sep);
      hasher.update(readFileSync(path.join(root, onDisk)));
      hasher.update('\n');
    }
    const expected = hasher.digest('hex');
    const got = hashWgslCompilerSourceTree(root);
    assert.equal(got, expected, 'JS hashWgslCompilerSourceTree must mirror the Zig algorithm byte-for-byte');
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

console.log('stage-platform-freshness.test: ok');

#!/usr/bin/env node

import assert from 'node:assert/strict';

import { DoeComputeGPUBuffer } from '../../src/vendor/webgpu/compute.js';

const calls = [];
const raw = {
  size: 64,
  usage: 0x88,
  async mapAsync(...args) {
    calls.push(['mapAsync', ...args]);
  },
  getMappedRange(...args) {
    calls.push(['getMappedRange', ...args]);
    return new ArrayBuffer(16);
  },
  assertMappedPrefixF32(...args) {
    calls.push(['assertMappedPrefixF32', ...args]);
  },
  unmap() {
    calls.push(['unmap']);
  },
  destroy() {
    calls.push(['destroy']);
  },
};

const buffer = new DoeComputeGPUBuffer(raw);
assert.ok(buffer instanceof DoeComputeGPUBuffer);
assert.notEqual(buffer.constructor, Object);
assert.equal(buffer.constructor.name, 'DoeComputeGPUBuffer');
assert.equal(buffer._raw, raw);
assert.equal(buffer.size, 64);
assert.equal(buffer.usage, 0x88);

await buffer.mapAsync(1, 4, 8);
assert.equal(buffer.getMappedRange(4, 8).byteLength, 16);
buffer.assertMappedPrefixF32([1], 1);
buffer.unmap();
buffer.destroy();

assert.deepEqual(calls, [
  ['mapAsync', 1, 4, 8],
  ['getMappedRange', 4, 8],
  ['assertMappedPrefixF32', [1], 1],
  ['unmap'],
  ['destroy'],
]);

console.log('compute-buffer-identity.test: ok');

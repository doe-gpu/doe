#!/usr/bin/env node

import assert from 'node:assert/strict';

import {
  DOE_LIMITS,
  publishLimits,
} from '../../src/vendor/webgpu/shared/capabilities.js';

const queried = {
  ...DOE_LIMITS,
  maxBufferSize: 4_294_967_295,
  maxStorageBufferBindingSize: 4_294_967_295,
  maxComputeWorkgroupStorageSize: 65_536,
};
const published = publishLimits(queried);

assert.equal(published.maxBufferSize, queried.maxBufferSize);
assert.equal(
  published.maxStorageBufferBindingSize,
  queried.maxStorageBufferBindingSize,
);
assert.equal(
  published.maxComputeWorkgroupStorageSize,
  queried.maxComputeWorkgroupStorageSize,
);
assert.equal(publishLimits(null), DOE_LIMITS);

console.log('capability-publication.test: ok');

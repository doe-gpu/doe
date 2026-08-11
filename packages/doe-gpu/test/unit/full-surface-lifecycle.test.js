#!/usr/bin/env node

import assert from 'node:assert/strict';

import {
  createFullSurfaceClasses,
  GPUDeviceLostInfo,
} from '../../src/vendor/webgpu/shared/full-surface.js';

function createTestDevice(backendOverrides = {}) {
  const backend = {
    deviceGetQueue() {
      return { kind: 'queue' };
    },
    deviceDestroy() {},
    queueHasPendingSubmissions() {
      return false;
    },
    queueMarkSubmittedWorkDone() {},
    ...backendOverrides,
  };
  const { DoeGPUDevice } = createFullSurfaceClasses({
    globals: {},
    backend,
    encoderClasses: {},
  });
  return new DoeGPUDevice({ kind: 'device' }, { kind: 'instance' });
}

async function assertRejectsOperationError(promise) {
  await assert.rejects(
    promise,
    (error) => error?.name === 'OperationError',
  );
}

{
  let destroyed = 0;
  const handlers = [];
  const device = createTestDevice({
    deviceDestroy() {
      destroyed += 1;
    },
    deviceGetOnUncapturedError(wrapper) {
      return wrapper._onuncapturederror;
    },
    deviceSetOnUncapturedError(_wrapper, _native, handler) {
      handlers.push(handler);
    },
  });

  const lostBeforeDestroy = device.lost;
  assert.equal(lostBeforeDestroy, device.lost);
  const handler = () => {};
  device.onuncapturederror = handler;
  assert.equal(device.onuncapturederror, handler);

  device.destroy();
  assert.equal(destroyed, 1);
  assert.equal(device.lost, lostBeforeDestroy);
  device.onuncapturederror = null;
  assert.equal(device.onuncapturederror, null);
  assert.deepEqual(handlers, [handler]);

  const lostInfo = await lostBeforeDestroy;
  assert.ok(lostInfo instanceof GPUDeviceLostInfo);
  assert.equal(lostInfo.reason, 'destroyed');
  assert.equal(await device.lost, lostInfo);
}

{
  const calls = [];
  const device = createTestDevice({
    devicePushErrorScope(_device, _native, filter, encodedFilter) {
      calls.push(['push', filter, encodedFilter]);
    },
    devicePopErrorScope() {
      calls.push(['pop']);
      return Promise.resolve(null);
    },
  });

  await assertRejectsOperationError(device.popErrorScope());
  device.pushErrorScope('validation');
  assert.equal(await device.popErrorScope(), null);
  await assertRejectsOperationError(device.popErrorScope());
  assert.deepEqual(calls, [
    ['push', 'validation', 1],
    ['pop'],
  ]);
}

{
  let viewDescriptor = null;
  const device = createTestDevice({
    deviceFeatures() {
      return new Set();
    },
    deviceCreateTexture() {
      return { kind: 'texture' };
    },
    textureCreateView(_texture, _native, descriptor) {
      viewDescriptor = descriptor;
      return { kind: 'texture-view' };
    },
  });
  const texture = device.createTexture({
    size: { width: 8, height: 4, depthOrArrayLayers: 3 },
    dimension: '3d',
    format: 'rgba8unorm',
    usage: 4,
  });

  texture.createView();

  assert.equal(viewDescriptor.dimension, '3d');
  assert.equal(viewDescriptor.baseArrayLayer, 0);
  assert.equal(viewDescriptor.arrayLayerCount, 1);
}

console.log('full-surface-lifecycle.test: ok');

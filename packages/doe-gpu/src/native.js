// doe-gpu/native - explicit native WebGPU provider surface.

import * as full from './vendor/webgpu/index.js';
import { createDoeNamespace } from './vendor/doe-namespace.js';

let cachedGpuNamespace = null;

function currentGpuNamespace() {
  if (cachedGpuNamespace === null) {
    cachedGpuNamespace = createDoeNamespace({
      requestDevice: full.requestDevice,
    });
  }
  return cachedGpuNamespace;
}

export const createGpuNamespace = createDoeNamespace;

// Explicit names remove the historical ambiguity between the root raw-device
// function and gpu.requestDevice(), which returns a helper bound to its device.
export const requestRawDevice = full.requestDevice;
export async function requestBoundDevice(options = {}) {
  return currentGpuNamespace().requestDevice(options);
}

export const gpu = new Proxy({}, {
  get(_target, property, receiver) {
    return Reflect.get(currentGpuNamespace(), property, receiver);
  },
  has(_target, property) {
    return Reflect.has(currentGpuNamespace(), property);
  },
  ownKeys() {
    return Reflect.ownKeys(currentGpuNamespace());
  },
  getOwnPropertyDescriptor(_target, property) {
    const descriptor = Reflect.getOwnPropertyDescriptor(currentGpuNamespace(), property);
    if (!descriptor) {
      return undefined;
    }
    return {
      ...descriptor,
      configurable: true,
    };
  },
});

export * from './vendor/webgpu/index.js';
export { createDoeNamespace } from './vendor/doe-namespace.js';

export default {
  ...full,
  gpu,
  createGpuNamespace: createDoeNamespace,
  requestRawDevice,
  requestBoundDevice,
};

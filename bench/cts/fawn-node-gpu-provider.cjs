const { resolve } = require('path');
const { pathToFileURL } = require('url');

const RUNTIME_MODULE_URL = pathToFileURL(
  resolve(__dirname, '../../packages/doe-gpu/src/index.js')
).href;
const dynamicImport = new Function('modulePath', 'return import(modulePath);');

let runtimeModulePromise;
let gpuPromise;
const wrappedObjects = new WeakMap();

function loadRuntimeModule() {
  if (!runtimeModulePromise) {
    runtimeModulePromise = dynamicImport(RUNTIME_MODULE_URL);
  }
  return runtimeModulePromise;
}

async function getGpu() {
  if (!gpuPromise) {
    gpuPromise = loadRuntimeModule().then(mod => wrapWebGpuValue(mod.setupGlobals(globalThis)));
  }
  return gpuPromise;
}

function globalConstructorNameFor(value) {
  const ctorName = value?.constructor?.name;
  if (typeof ctorName !== 'string' || ctorName.length === 0) {
    return null;
  }
  const normalized = ctorName.startsWith('Doe') ? ctorName.slice(3) : ctorName;
  if (!normalized.startsWith('GPU')) {
    return null;
  }
  return normalized;
}

function installConstructorGlobal(value) {
  const globalName = globalConstructorNameFor(value);
  if (!globalName) {
    return;
  }
  if (globalThis[globalName] === undefined) {
    Object.defineProperty(globalThis, globalName, {
      value: value.constructor,
      writable: true,
      configurable: true,
      enumerable: false,
    });
  }
}

function wrapWebGpuValue(value) {
  if (value === null || value === undefined) {
    return value;
  }
  if (value instanceof Promise) {
    return value.then(result => wrapWebGpuValue(result));
  }
  if (typeof value !== 'object' && typeof value !== 'function') {
    return value;
  }

  installConstructorGlobal(value);

  const globalName = globalConstructorNameFor(value);
  if (!globalName) {
    return value;
  }
  const cached = wrappedObjects.get(value);
  if (cached) {
    return cached;
  }

  const proxy = new Proxy(value, {
    get(target, prop, receiver) {
      const resolved = Reflect.get(target, prop, receiver);
      if (typeof resolved === 'function') {
        return (...args) => wrapWebGpuValue(Reflect.apply(resolved, target, args));
      }
      return wrapWebGpuValue(resolved);
    },
  });
  wrappedObjects.set(value, proxy);
  return proxy;
}

function createLazyGpuFacade() {
  return {
    async requestAdapter(options) {
      const gpu = await getGpu();
      return gpu.requestAdapter(options);
    },
  };
}

module.exports = {
  create() {
    return createLazyGpuFacade();
  },
};

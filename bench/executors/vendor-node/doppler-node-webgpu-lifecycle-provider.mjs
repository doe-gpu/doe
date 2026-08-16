// Bounded incumbent control for the Doppler lifecycle-ownership experiment.
// It changes no application or shader behavior: it only records devices created
// through requestDevice(), waits for submitted work, and destroys them before
// the governed provider session restores globals.

const incumbentSpecifier = process.env.DOE_DOPPLER_INCUMBENT_MODULE?.trim();
if (!incumbentSpecifier) {
  throw new Error('DOE_DOPPLER_INCUMBENT_MODULE must name the pinned incumbent module');
}

const incumbent = await import(incumbentSpecifier);
if (typeof incumbent.create !== 'function' || !incumbent.globals) {
  throw new Error('pinned incumbent module must export create() and globals');
}

export const globals = incumbent.globals;

const trackedDevices = new Set();

function bindProperty(target, property) {
  const value = Reflect.get(target, property, target);
  return typeof value === 'function' ? value.bind(target) : value;
}

function trackAdapter(adapter) {
  return new Proxy(adapter, {
    get(target, property) {
      if (property !== 'requestDevice') return bindProperty(target, property);
      return async (...args) => {
        const device = await target.requestDevice(...args);
        trackedDevices.add(device);
        return device;
      };
    },
  });
}

function trackGpu(gpu) {
  return new Proxy(gpu, {
    get(target, property) {
      if (property !== 'requestAdapter') return bindProperty(target, property);
      return async (...args) => {
        const adapter = await target.requestAdapter(...args);
        return adapter === null ? null : trackAdapter(adapter);
      };
    },
  });
}

export function create(...args) {
  return trackGpu(incumbent.create(...args));
}

export async function releaseTrackedDevices() {
  const devices = [...trackedDevices];
  const failures = [];
  for (const [index, device] of devices.entries()) {
    try {
      if (typeof device?.queue?.onSubmittedWorkDone === 'function') {
        await device.queue.onSubmittedWorkDone();
      }
      if (typeof device?.destroy === 'function') device.destroy();
    } catch (error) {
      failures.push({
        index,
        message: error instanceof Error ? error.message : String(error),
      });
    }
  }
  trackedDevices.clear();
  if (failures.length > 0) {
    throw new Error(`bounded lifecycle cleanup failed: ${JSON.stringify(failures)}`);
  }
  return {
    supported: true,
    awaitedDeviceCount: devices.length,
    destroyedDeviceCount: devices.length,
    failureCount: 0,
  };
}

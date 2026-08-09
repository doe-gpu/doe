import { create, __doeHarnessProviderIdentity } from 'webgpu';

const gpu = create([]);
const adapter = await gpu.requestAdapter();
if (!adapter) throw new Error('provider returned no WebGPU adapter');
const device = await adapter.requestDevice();
const identity = {
  provider: __doeHarnessProviderIdentity,
  adapter: adapter.info ?? null,
  isFallbackAdapter: adapter.isFallbackAdapter ?? null,
  features: [...(adapter.features ?? [])].sort(),
};
console.log(`DOE_WGSL_FNS_PROVIDER_PROBE=${JSON.stringify(identity)}`);
device.destroy();

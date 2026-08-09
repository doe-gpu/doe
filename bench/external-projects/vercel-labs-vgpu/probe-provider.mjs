import { create, __doeHarnessProviderIdentity } from 'webgpu';

const gpu = create([]);
const adapter = await gpu.requestAdapter({ featureLevel: 'compatibility' });
if (!adapter) throw new Error('provider returned no compatibility adapter');
const info = adapter.info ?? (
  typeof adapter.requestAdapterInfo === 'function'
    ? await adapter.requestAdapterInfo()
    : null
);
const adapterIdentity = info ? Object.fromEntries([
  'vendor',
  'architecture',
  'device',
  'description',
  'backendType',
  'adapterType',
  'driver',
  'driverDescription',
].flatMap((key) => info[key] === undefined ? [] : [[key, info[key]]])) : null;
console.log(`DOE_VGPU_PROVIDER_PROBE=${JSON.stringify({
  provider: __doeHarnessProviderIdentity,
  adapter: adapterIdentity,
  isFallbackAdapter: adapter.isFallbackAdapter ?? null,
  features: adapter.features ? [...adapter.features].sort() : [],
})}`);

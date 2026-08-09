import { pathToFileURL } from 'node:url';

const modulePath = process.env.DOE_EXTERNAL_PROVIDER_MODULE;
const providerId = process.env.DOE_EXTERNAL_WEBGPU_PROVIDER;
if (!modulePath) throw new Error('DOE_EXTERNAL_PROVIDER_MODULE is required.');
if (!providerId) throw new Error('DOE_EXTERNAL_WEBGPU_PROVIDER is required.');

const provider = await import(pathToFileURL(modulePath).href);
if (typeof provider.create !== 'function' || !provider.globals) {
  throw new Error(`${modulePath} does not expose create() and globals.`);
}
const gpu = provider.create([]);
const adapter = await gpu.requestAdapter();
if (!adapter) throw new Error('provider returned no adapter');
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

console.log(`DOE_WORLD_LAB_PROVIDER_PROBE=${JSON.stringify({
  provider: {
    id: providerId,
    modulePath,
    providerInfo: typeof provider.providerInfo === 'function'
      ? provider.providerInfo()
      : null,
  },
  adapter: adapterIdentity,
  isFallbackAdapter: adapter.isFallbackAdapter ?? null,
  features: adapter.features ? [...adapter.features].sort() : [],
})}`);

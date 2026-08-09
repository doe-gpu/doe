import { create, __doeHarnessProviderIdentity } from 'webgpu';

const gpu = create([]);
const adapter = await gpu.requestAdapter();
if (!adapter) throw new Error('provider returned no adapter');
const info = adapter.info ?? (
  typeof adapter.requestAdapterInfo === 'function'
    ? await adapter.requestAdapterInfo()
    : null
);
console.log(`DOE_GIGI_PROVIDER_PROBE=${JSON.stringify({
  provider: __doeHarnessProviderIdentity,
  adapter: info,
})}`);

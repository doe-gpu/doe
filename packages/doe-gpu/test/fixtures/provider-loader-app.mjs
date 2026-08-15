import { __doeProofProviderIdentity, create, globals } from 'webgpu';

const gpu = create('loader-argument');
const adapter = await gpu.requestAdapter({ powerPreference: 'high-performance' });

process.stdout.write(`${JSON.stringify({
  identity: __doeProofProviderIdentity,
  hasCreate: typeof create === 'function',
  hasGlobals: Boolean(globals?.GPUBufferUsage),
  adapterLabel: adapter.label,
})}\n`);

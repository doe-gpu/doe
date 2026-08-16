import {
  __doeProofProviderIdentity,
  __doeProofProviderRuntimeInfo,
  create,
  getProviderObservations,
  globals,
} from 'webgpu';

const gpu = create('loader-argument');
const adapter = await gpu.requestAdapter({ powerPreference: 'high-performance' });

process.stdout.write(`${JSON.stringify({
  identity: __doeProofProviderIdentity,
  runtimeInfo: __doeProofProviderRuntimeInfo,
  providerInfoCalls: getProviderObservations().providerInfoCalls,
  hasCreate: typeof create === 'function',
  hasGlobals: Boolean(globals?.GPUBufferUsage),
  adapterLabel: adapter.label,
})}\n`);

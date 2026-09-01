const providerPath = process.env.DOE_CTS_PROBE_PROVIDER || './fawn-node-gpu-provider.cjs';
const provider = require(providerPath);
const providerId = process.env.DOE_CTS_PROBE_PROVIDER_ID || 'fawn-node-gpu-provider';

const ADAPTER_INFO_FIELDS = Object.freeze([
  'vendor',
  'architecture',
  'device',
  'description',
  'isFallbackAdapter',
  'subgroupMinSize',
  'subgroupMaxSize',
  'subgroupMatrixConfigs',
  'vendorID',
  'deviceID',
  'driverVersion',
]);

function snapshotAdapterInfo(adapterInfo) {
  if (adapterInfo === null || typeof adapterInfo !== 'object') {
    throw new Error('adapter info is unavailable');
  }
  const snapshot = {};
  for (const fieldName of ADAPTER_INFO_FIELDS) {
    const value = adapterInfo[fieldName];
    if (value !== undefined) {
      snapshot[fieldName] = value;
    }
  }
  return snapshot;
}

async function main() {
  const adapter = await provider.create([]).requestAdapter();
  if (!adapter) {
    throw new Error('Doe CTS provider returned no adapter');
  }
  const device = await adapter.requestDevice();
  const adapterInfo = snapshotAdapterInfo(device?.adapterInfo ?? adapter.info ?? null);
  console.log(JSON.stringify({
    schemaVersion: 1,
    artifactKind: 'webgpu_cts_adapter_identity',
    provider: providerId,
    adapterInfo,
  }));
  device?.destroy?.();
}

main().catch(error => {
  console.error(error?.stack ?? String(error));
  process.exitCode = 1;
});

// doe-gpu/node-webgpu-loader - fail-closed provider substitution for unchanged Node apps.

export const NODE_WEBGPU_LOADER_CONTRACT = 'doe.node-webgpu-loader/v1';
const VIRTUAL_PREFIX = 'doe-node-webgpu-provider:';
const PROVIDER_ID = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;

function requiredConfiguration() {
  const providerId = process.env.DOE_NODE_WEBGPU_PROVIDER_ID?.trim();
  const providerModule = process.env.DOE_NODE_WEBGPU_PROVIDER_MODULE?.trim();
  if (!providerId || !PROVIDER_ID.test(providerId)) {
    throw new Error(
      'DOE_NODE_WEBGPU_PROVIDER_ID must be an explicit provider identifier.',
    );
  }
  if (!providerModule) {
    throw new Error(
      'DOE_NODE_WEBGPU_PROVIDER_MODULE must be an explicit module specifier.',
    );
  }
  return { providerId, providerModule };
}

function encodeVirtualIdentity(identity) {
  return Buffer.from(JSON.stringify(identity), 'utf8').toString('base64url');
}

function decodeVirtualIdentity(url) {
  return JSON.parse(
    Buffer.from(url.slice(VIRTUAL_PREFIX.length), 'base64url').toString('utf8'),
  );
}

export async function resolve(specifier, context, nextResolve) {
  if (specifier !== 'webgpu') return nextResolve(specifier, context);
  const configuration = requiredConfiguration();
  const provider = await nextResolve(configuration.providerModule, context);
  const identity = {
    contract: NODE_WEBGPU_LOADER_CONTRACT,
    requestedSpecifier: 'webgpu',
    providerId: configuration.providerId,
    providerModule: configuration.providerModule,
    resolvedProviderUrl: provider.url,
  };
  return {
    url: `${VIRTUAL_PREFIX}${encodeVirtualIdentity(identity)}`,
    shortCircuit: true,
  };
}

export async function load(url, context, nextLoad) {
  if (!url.startsWith(VIRTUAL_PREFIX)) return nextLoad(url, context);
  const identity = decodeVirtualIdentity(url);
  const providerUrl = JSON.stringify(identity.resolvedProviderUrl);
  const serializedIdentity = JSON.stringify(identity);
  return {
    format: 'module',
    shortCircuit: true,
    source: `
      import * as provider from ${providerUrl};
      if (typeof provider.create !== 'function' || !provider.globals) {
        throw new Error(
          'Declared Node WebGPU provider must export create() and globals.',
        );
      }
      export * from ${providerUrl};
      export const create = provider.create;
      export const globals = provider.globals;
      export const __doeProofProviderIdentity = Object.freeze(${serializedIdentity});
      export default provider.default;
    `,
  };
}

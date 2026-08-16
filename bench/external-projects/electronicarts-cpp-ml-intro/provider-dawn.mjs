import { pathToFileURL } from 'node:url';

const modulePath = process.env.DOE_EXTERNAL_DAWN_MODULE;
if (!modulePath) throw new Error('DOE_EXTERNAL_DAWN_MODULE is required.');
const provider = await import(pathToFileURL(modulePath).href);
if (typeof provider.create !== 'function' || !provider.globals) {
  throw new Error(`Dawn module ${modulePath} does not expose create() and globals.`);
}

export const create = provider.create;
export const globals = provider.globals;
const providerIdentity = Object.freeze({
  id: 'dawn-node-webgpu',
  modulePath,
});

export const __doeHarnessProviderIdentity = providerIdentity;
export const __doeProofProviderIdentity = providerIdentity;

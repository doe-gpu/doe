import { pathToFileURL } from 'node:url';

const modulePath = process.env.DOE_DOPPLER_QUALIFICATION_PROVIDER_TARGET;
if (!modulePath) {
  throw new Error('DOE_DOPPLER_QUALIFICATION_PROVIDER_TARGET is required.');
}

const provider = await import(pathToFileURL(modulePath).href);
if (typeof provider.create !== 'function' || !provider.globals) {
  throw new Error(`Dawn provider ${modulePath} does not expose create() and globals.`);
}

export const create = provider.create;
export const globals = provider.globals;
export const __doeHarnessProviderIdentity = Object.freeze({
  id: 'dawn-node-webgpu',
  modulePath,
});

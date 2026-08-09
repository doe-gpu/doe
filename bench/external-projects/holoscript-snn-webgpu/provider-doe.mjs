import { pathToFileURL } from 'node:url';

const modulePath = process.env.DOE_EXTERNAL_DOE_MODULE;
if (!modulePath) {
  throw new Error('DOE_EXTERNAL_DOE_MODULE is required for the Doe provider.');
}

const provider = await import(pathToFileURL(modulePath).href);
if (typeof provider.create !== 'function' || !provider.globals) {
  throw new Error(`Doe module ${modulePath} does not expose create() and globals.`);
}

export const create = provider.create;
export const globals = provider.globals;
export const __doeHarnessProviderIdentity = Object.freeze({
  id: 'doe-gpu',
  modulePath,
  providerInfo: typeof provider.providerInfo === 'function' ? provider.providerInfo() : null,
});

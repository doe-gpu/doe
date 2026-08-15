const provider = process.env.DOE_EXTERNAL_WEBGPU_PROVIDER;
const providerModules = {
  'dawn-node-webgpu': new URL('./provider-dawn.mjs', import.meta.url).href,
  'doe-gpu': new URL('./provider-doe.mjs', import.meta.url).href,
};

export async function resolve(specifier, context, nextResolve) {
  if (specifier !== 'webgpu') return nextResolve(specifier, context);
  if (provider === 'ambient-node-webgpu') return nextResolve(specifier, context);
  const url = providerModules[provider];
  if (!url) {
    throw new Error(
      `DOE_EXTERNAL_WEBGPU_PROVIDER must be ambient-node-webgpu or one of ${Object.keys(providerModules).join(', ')}; received ${JSON.stringify(provider)}`,
    );
  }
  return { url, shortCircuit: true };
}

const providerUrl = new URL('./public-observer-provider.mjs', import.meta.url).href;

export async function resolve(specifier, context, nextResolve) {
  if (specifier !== 'webgpu') return nextResolve(specifier, context);
  return { url: providerUrl, shortCircuit: true };
}

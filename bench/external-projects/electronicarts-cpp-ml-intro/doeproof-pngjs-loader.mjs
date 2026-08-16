import { pathToFileURL } from 'node:url';

export async function resolve(specifier, context, nextResolve) {
  if (specifier !== 'pngjs') return nextResolve(specifier, context);
  const modulePath = process.env.DOE_EXTERNAL_PNGJS_MODULE;
  if (!modulePath) throw new Error('DOE_EXTERNAL_PNGJS_MODULE is required.');
  return { url: pathToFileURL(modulePath).href, shortCircuit: true };
}

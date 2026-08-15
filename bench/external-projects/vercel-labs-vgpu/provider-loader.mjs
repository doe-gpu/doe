import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

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

export async function load(url, context, nextLoad) {
  if (!url.endsWith('.ts')) return nextLoad(url, context);
  const modulePath = process.env.DOE_EXTERNAL_TYPESCRIPT_MODULE;
  if (!modulePath) {
    throw new Error('DOE_EXTERNAL_TYPESCRIPT_MODULE is required for TypeScript input.');
  }
  const typescript = await import(pathToFileURL(modulePath).href);
  const source = await readFile(new URL(url), 'utf8');
  const result = typescript.transpileModule(source, {
    compilerOptions: {
      module: typescript.ModuleKind.ESNext,
      target: typescript.ScriptTarget.ES2022,
    },
    fileName: new URL(url).pathname,
  });
  return { format: 'module', source: result.outputText, shortCircuit: true };
}

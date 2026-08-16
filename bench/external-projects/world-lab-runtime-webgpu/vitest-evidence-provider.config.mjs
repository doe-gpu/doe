import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const harnessDir = dirname(fileURLToPath(import.meta.url));
const upstreamRoot = process.env.DOE_EXTERNAL_UPSTREAM_ROOT;
const providerModule = process.env.DOE_EXTERNAL_PROVIDER_MODULE;
const baseProviderModule = process.env.DOE_WORLD_LAB_BASE_PROVIDER_MODULE;
if (!upstreamRoot) throw new Error('DOE_EXTERNAL_UPSTREAM_ROOT is required.');
if (!providerModule) throw new Error('DOE_EXTERNAL_PROVIDER_MODULE is required.');
if (!baseProviderModule) throw new Error('DOE_WORLD_LAB_BASE_PROVIDER_MODULE is required.');

const packageRoot = resolve(upstreamRoot, 'packages/runtime-webgpu');
export default {
  root: packageRoot,
  plugins: [{
    name: 'doe-world-lab-base-provider',
    enforce: 'pre',
    resolveId(id) {
      return id === 'doe-world-base-provider' ? baseProviderModule : null;
    },
  }],
  resolve: {
    alias: [{ find: /^webgpu$/, replacement: providerModule }],
  },
  test: {
    setupFiles: [resolve(harnessDir, 'evidence-webgpu-setup.mjs')],
    environment: 'happy-dom',
    pool: 'forks',
    fileParallelism: false,
    maxWorkers: 1,
    testTimeout: 60_000,
    hookTimeout: 60_000,
  },
};

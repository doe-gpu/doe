import { resolve } from 'node:path';

const upstreamRoot = process.env.DOE_EXTERNAL_UPSTREAM_ROOT;
const providerModule = process.env.DOE_EXTERNAL_PROVIDER_MODULE;
if (!upstreamRoot) throw new Error('DOE_EXTERNAL_UPSTREAM_ROOT is required.');
if (!providerModule) throw new Error('DOE_EXTERNAL_PROVIDER_MODULE is required.');

const packageRoot = resolve(upstreamRoot, 'packages/runtime-webgpu');
export default {
  root: packageRoot,
  resolve: {
    alias: [{ find: /^webgpu$/, replacement: providerModule }],
  },
  test: {
    setupFiles: [resolve(packageRoot, 'test/webgpuSetup.ts')],
    environment: 'happy-dom',
    pool: 'forks',
    fileParallelism: false,
    maxWorkers: 1,
    testTimeout: 60_000,
    hookTimeout: 60_000,
  },
};

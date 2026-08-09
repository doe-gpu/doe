import { resolve } from 'node:path';

const upstreamRoot = process.env.DOE_EXTERNAL_UPSTREAM_ROOT;
const providerModule = process.env.DOE_EXTERNAL_PROVIDER_MODULE;
if (!upstreamRoot) throw new Error('DOE_EXTERNAL_UPSTREAM_ROOT is required.');
if (!providerModule) throw new Error('DOE_EXTERNAL_PROVIDER_MODULE is required.');

export default {
  root: upstreamRoot,
  resolve: {
    alias: [
      { find: /^webgpu$/, replacement: providerModule },
      {
        find: /^hnswlib-wasm$/,
        replacement: resolve(
          upstreamRoot,
          'src/__tests__/__stubs__/hnswlib-wasm.ts',
        ),
      },
    ],
  },
  test: {
    include: ['src/**/*.test.ts'],
    setupFiles: [resolve(upstreamRoot, 'src/__tests__/setup-webgpu.ts')],
    testTimeout: 60_000,
    hookTimeout: 60_000,
    fileParallelism: false,
    maxWorkers: 1,
  },
};

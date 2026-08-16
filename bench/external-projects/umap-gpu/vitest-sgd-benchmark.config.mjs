import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const upstreamRoot = process.env.DOE_EXTERNAL_UPSTREAM_ROOT;
const providerModule = process.env.DOE_EXTERNAL_PROVIDER_MODULE;
if (!upstreamRoot) throw new Error('DOE_EXTERNAL_UPSTREAM_ROOT is required.');
if (!providerModule) throw new Error('DOE_EXTERNAL_PROVIDER_MODULE is required.');

const harnessDir = resolve(fileURLToPath(new URL('.', import.meta.url)));

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
      { find: /^@umap-source\/(.*)$/, replacement: `${upstreamRoot}/src/$1` },
    ],
  },
  test: {
    include: [resolve(harnessDir, 'sgd-benchmark.workload.test.ts')],
    setupFiles: [resolve(upstreamRoot, 'src/__tests__/setup-webgpu.ts')],
    testTimeout: 120_000,
    hookTimeout: 120_000,
    fileParallelism: false,
    maxWorkers: 1,
  },
};

#!/usr/bin/env node

const contracts = [
  './unit/compute-program.test.js',
  './unit/live-simulation.test.js',
  './unit/browser-runtime-identity.test.js',
  './unit/node-webgpu-provider-v1.test.js',
  './unit/node-webgpu-governed-execution.test.js',
  './unit/node-webgpu-loader.test.js',
  './unit/build-metadata-permission.test.js',
  './unit/platform-package-root.test.js',
  './unit/node-webgpu-process.test.js',
  './unit/node-webgpu-process-cli.test.js',
  './unit/root-export-parity.test.js',
  './unit/program-bundle-runner.test.js',
  './unit/full-surface-lifecycle.test.js',
  './unit/compute-buffer-identity.test.js',
  './unit/capability-publication.test.js',
  './unit/provider-diagnostics.test.js',
  './unit/stage-platform-freshness.test.js',
  './unit/plan-contracts.test.js',
  './unit/plan-refactor-receipt.test.js',
  './unit/transparent-webgpu-observer.test.js',
  './unit/native-device-test-helper.test.js',
  './unit/native-release-candidate-bundle.test.js',
];

for (const contract of contracts) {
  await import(new URL(contract, import.meta.url));
}

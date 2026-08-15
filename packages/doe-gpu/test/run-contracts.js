#!/usr/bin/env node

const contracts = [
  './unit/browser-runtime-identity.test.js',
  './unit/node-webgpu-provider-v1.test.js',
  './unit/root-export-parity.test.js',
  './unit/program-bundle-runner.test.js',
  './unit/full-surface-lifecycle.test.js',
  './unit/compute-buffer-identity.test.js',
  './unit/stage-platform-freshness.test.js',
  './unit/plan-contracts.test.js',
  './unit/plan-refactor-receipt.test.js',
];

for (const contract of contracts) {
  await import(new URL(contract, import.meta.url));
}

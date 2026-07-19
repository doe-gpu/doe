#!/usr/bin/env node

const contracts = [
  './unit/browser-runtime-identity.test.js',
  './unit/full-surface-lifecycle.test.js',
  './unit/stage-platform-freshness.test.js',
];

for (const contract of contracts) {
  await import(new URL(contract, import.meta.url));
}

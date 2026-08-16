import assert from 'node:assert/strict';
import { isInstalledPackageRoot } from '../../src/vendor/webgpu/platform-package.js';

assert.equal(
  isInstalledPackageRoot('/opt/app/node_modules/doe-gpu'),
  true,
  'ordinary npm installations must prefer their platform package',
);
assert.equal(
  isInstalledPackageRoot('/opt/app/node_modules/.pnpm/doe-gpu@0.4.7/node_modules/doe-gpu'),
  true,
  'pnpm installations must prefer their platform package',
);
assert.equal(
  isInstalledPackageRoot('C:\\app\\node_modules\\doe-gpu'),
  true,
  'Windows npm installations must prefer their platform package',
);
assert.equal(
  isInstalledPackageRoot('/workspace/packages/doe-gpu'),
  false,
  'workspace source must retain development-artifact precedence',
);

console.log('platform package root contracts: ok');

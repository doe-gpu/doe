import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildPlanRefactorReceipt } from '../../scripts/build-plan-refactor-receipt.js';

const receipt = await buildPlanRefactorReceipt();
const packageRoot = fileURLToPath(new URL('../..', import.meta.url));
const trackedPath = resolve(
  packageRoot,
  '../../reports/refactors/doe-gpu-plan-contract-split-v1.json',
);
const tracked = JSON.parse(await readFile(trackedPath, 'utf8'));
assert.equal(receipt.artifactKind, 'doe_refactor_receipt');
assert.equal(receipt.classification, 'contract_tightening');
assert.equal(receipt.characterization.publicExportsPreserved, true);
assert.equal(receipt.status, 'pass');
assert.deepEqual(tracked, receipt, 'tracked plan refactor receipt is stale');

process.stdout.write('plan-refactor-receipt: ok\n');

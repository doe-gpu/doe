#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as plan from '../src/plan.js';

const PACKAGE_ROOT = fileURLToPath(new URL('..', import.meta.url));
const REPO_ROOT = resolve(PACKAGE_ROOT, '../..');
const SOURCE_PATH = 'packages/doe-gpu/src/plan.js';
const BASELINE_PATH = resolve(PACKAGE_ROOT, 'test/fixtures/plan-refactor-baseline.json');

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

function validPlan() {
  return {
    schemaVersion: 1,
    planKind: 'receipt',
    workloadId: 'plan-refactor-receipt',
    irPath: 'bench/ir/receipt.json',
    irScenario: 'main',
    commandCount: 1,
    bufferWriteCount: 0,
    dispatchCount: 1,
    sourceIrSha256: 'source',
    compatibilityCommandsSha256: 'commands',
    commands: [{ kind: 'dispatch' }],
  };
}

function caseRow(id, before, after, expectedRelationship) {
  const status = expectedRelationship === 'equal'
    ? (JSON.stringify(before) === JSON.stringify(after) ? 'pass' : 'fail')
    : (before === true && after === false ? 'pass' : 'fail');
  return { id, before, after, expectedRelationship, status };
}

export async function buildPlanRefactorReceipt() {
  const baseline = JSON.parse(await readFile(BASELINE_PATH, 'utf8'));
  const source = await readFile(resolve(REPO_ROOT, SOURCE_PATH));
  const publicExports = Object.keys(plan).sort();
  const defaultExportKeys = Object.keys(plan.default).sort();
  const validAccepted = plan.validateNormalizedPlan(validPlan()).ok;
  const incomplete = validPlan();
  delete incomplete.irPath;
  const incompleteAccepted = plan.validateNormalizedPlan(incomplete).ok;
  const incompletePlanArtifactAccepted = plan.validatePlanArtifact({
    schemaVersion: 1,
    artifactKind: plan.DOE_WEBGPU_CAPTURE_EVIDENCE_ARTIFACT_KIND,
  }).ok;
  const commandCount = plan.validateCommandStream([{ kind: 'dispatch' }]).commandCount;
  const cases = [
    caseRow(
      'valid-normalized-plan',
      baseline.characterization.validNormalizedPlanAccepted,
      validAccepted,
      'equal',
    ),
    caseRow(
      'incomplete-normalized-plan',
      baseline.characterization.incompleteNormalizedPlanAccepted,
      incompleteAccepted,
      'tightened',
    ),
    caseRow(
      'incomplete-plan-artifact',
      baseline.characterization.incompletePlanArtifactAccepted,
      incompletePlanArtifactAccepted,
      'tightened',
    ),
    caseRow(
      'command-stream-count',
      baseline.characterization.commandStreamCount,
      commandCount,
      'equal',
    ),
    caseRow(
      'default-export-keys',
      baseline.characterization.defaultExportKeys,
      defaultExportKeys,
      'equal',
    ),
    caseRow(
      'default-export-extensible',
      baseline.characterization.defaultExportExtensible,
      Object.isExtensible(plan.default),
      'equal',
    ),
  ];
  const publicExportsPreserved = JSON.stringify(baseline.publicExports) === JSON.stringify(publicExports);
  return {
    schemaVersion: 1,
    artifactKind: 'doe_refactor_receipt',
    refactorId: 'doe-gpu-plan-contract-split-v1',
    classification: 'contract_tightening',
    before: {
      path: baseline.sourcePath,
      sha256: baseline.sourceSha256,
      publicExports: baseline.publicExports,
    },
    after: {
      path: SOURCE_PATH,
      sha256: sha256(source),
      publicExports,
    },
    characterization: {
      publicExportsPreserved,
      cases,
    },
    status: publicExportsPreserved && cases.every((row) => row.status === 'pass')
      ? 'pass'
      : 'fail',
  };
}

const outputIndex = process.argv.indexOf('--out');
if (outputIndex >= 0) {
  const output = process.argv[outputIndex + 1];
  if (!output) throw new Error('--out requires a path');
  const receipt = await buildPlanRefactorReceipt();
  await writeFile(output, `${JSON.stringify(receipt, null, 2)}\n`);
  if (receipt.status !== 'pass') process.exitCode = 1;
} else if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const receipt = await buildPlanRefactorReceipt();
  process.stdout.write(`${JSON.stringify(receipt, null, 2)}\n`);
  if (receipt.status !== 'pass') process.exitCode = 1;
}

#!/usr/bin/env node

import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import {
  DOE_CAPTURE_GRAPH_FIELDS,
  DOE_NORMALIZED_PLAN_FIELDS,
  DOE_NORMALIZED_PLAN_REQUIRED_FIELDS,
  DOE_NORMALIZED_PLAN_SCHEMA_VERSION,
  DOE_PLAN_ARTIFACT_CONTRACTS,
  DOE_PLAN_SCHEMA_VERSIONS,
  DOE_CSL_HOST_PLAN_ARTIFACT_KIND,
  DOE_STREAM_EXECUTION_PLAN_ARTIFACT_KIND,
  DOE_STREAM_GRAPH_ARTIFACT_KIND,
  DOE_WEBGPU_CAPTURE_EVIDENCE_ARTIFACT_KIND,
  DOE_WEBGPU_CAPTURE_GRAPH_SCHEMA_VERSION,
} from '../src/plan-contracts.js';
import * as planSurface from '../src/plan.js';

const PACKAGE_ROOT = fileURLToPath(new URL('..', import.meta.url));
const REPO_ROOT = fileURLToPath(new URL('../../..', import.meta.url));

async function readJson(relativePath) {
  return JSON.parse(await readFile(new URL(relativePath, `file://${REPO_ROOT}/`), 'utf8'));
}

function sorted(values) {
  return [...values].sort();
}

export async function checkPlanSchemaParity() {
  const normalized = await readJson('bench/plans/normalized_plan.schema.json');
  const capture = await readJson('config/doe-webgpu-capture-graph.schema.json');

  assert.equal(normalized.additionalProperties, false);
  assert.equal(normalized.properties.schemaVersion.const, DOE_NORMALIZED_PLAN_SCHEMA_VERSION);
  assert.deepEqual(sorted(normalized.required), sorted(DOE_NORMALIZED_PLAN_REQUIRED_FIELDS));
  assert.deepEqual(sorted(Object.keys(normalized.properties)), sorted(DOE_NORMALIZED_PLAN_FIELDS));

  assert.equal(capture.additionalProperties, false);
  assert.equal(capture.properties.schemaVersion.const, DOE_WEBGPU_CAPTURE_GRAPH_SCHEMA_VERSION);
  assert.deepEqual(sorted(capture.required), sorted(DOE_CAPTURE_GRAPH_FIELDS));
  assert.deepEqual(sorted(Object.keys(capture.properties)), sorted(DOE_CAPTURE_GRAPH_FIELDS));

  const artifactSchemas = new Map([
    [DOE_WEBGPU_CAPTURE_EVIDENCE_ARTIFACT_KIND, 'config/doe-webgpu-capture-evidence.schema.json'],
    [DOE_STREAM_GRAPH_ARTIFACT_KIND, 'config/doe-stream-graph.schema.json'],
    [DOE_STREAM_EXECUTION_PLAN_ARTIFACT_KIND, 'config/doe-stream-execution-plan.schema.json'],
    [DOE_CSL_HOST_PLAN_ARTIFACT_KIND, 'config/doe-wgsl-host-plan.schema.json'],
  ]);
  for (const [artifactKind, schemaPath] of artifactSchemas) {
    const schema = await readJson(schemaPath);
    const contract = DOE_PLAN_ARTIFACT_CONTRACTS[artifactKind];
    assert.equal(schema.properties.schemaVersion.const, DOE_PLAN_SCHEMA_VERSIONS[artifactKind]);
    assert.equal(schema.properties.artifactKind.const, artifactKind);
    assert.deepEqual(sorted(schema.required), sorted(contract.required));
    assert.deepEqual(sorted(Object.keys(schema.properties)), sorted(contract.fields));
    assert.equal(schema.additionalProperties === false, contract.closed);
  }

  const declaration = await readFile(new URL('../src/plan.d.ts', import.meta.url), 'utf8');
  const declaredRuntimeExports = [...declaration.matchAll(
    /^export declare (?:const|function) ([A-Za-z0-9_]+)/gmu,
  )].map((match) => match[1]);
  const runtimeExports = Object.keys(planSurface).filter((name) => name !== 'default');
  assert.deepEqual(sorted(declaredRuntimeExports), sorted(runtimeExports));

  const defaultDeclaration = declaration.match(
    /declare const _default: \{([\s\S]*?)\n\};/mu,
  );
  assert.ok(defaultDeclaration, 'plan.d.ts must declare the default export shape');
  const declaredDefaultExports = [...defaultDeclaration[1].matchAll(
    /^\s{2}([A-Za-z0-9_]+):/gmu,
  )].map((match) => match[1]);
  assert.deepEqual(
    sorted(declaredDefaultExports),
    sorted(Object.keys(planSurface.default)),
  );
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  await checkPlanSchemaParity();
  process.stdout.write(`plan-schema-parity: ok (${PACKAGE_ROOT})\n`);
}

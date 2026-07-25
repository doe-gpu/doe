import assert from 'node:assert/strict';
import {
  assertNormalizedPlan,
  createCaptureProvider,
  validateCaptureGraph,
  validateNormalizedPlan,
  validatePlanArtifact,
} from '../../src/plan.js';
import { checkPlanSchemaParity } from '../../scripts/check-plan-schema-parity.js';

function normalizedPlan(overrides = {}) {
  return {
    schemaVersion: 1,
    planKind: 'test',
    workloadId: 'plan-contract-test',
    irPath: 'bench/ir/test.json',
    irScenario: 'main',
    commandCount: 1,
    bufferWriteCount: 0,
    dispatchCount: 1,
    sourceIrSha256: 'source',
    compatibilityCommandsSha256: 'commands',
    commands: [{ kind: 'dispatch' }],
    ...overrides,
  };
}

await checkPlanSchemaParity();

assert.equal(validateNormalizedPlan(normalizedPlan()).ok, true);

const missingPath = validateNormalizedPlan(normalizedPlan({ irPath: undefined }));
assert.equal(missingPath.ok, false);
assert.equal(missingPath.errors[0].code, 'type_mismatch');
assert.equal(missingPath.errors[0].path, 'plan.irPath');
assert.equal(missingPath.errors[0].expected, 'non-empty string');
assert.equal(missingPath.errors[0].received, 'undefined');

const unknownField = validateNormalizedPlan(normalizedPlan({ implicitPolicy: true }));
assert.equal(unknownField.ok, false);
assert.equal(unknownField.errors[0].code, 'unknown_field');
assert.equal(unknownField.errors[0].path, 'plan.implicitPolicy');

assert.throws(
  () => assertNormalizedPlan(normalizedPlan({ dispatchCount: -1 })),
  (error) => (
    error.code === 'type_mismatch'
    && error.path === 'plan.dispatchCount'
    && error.expected === 'integer >= 0'
  ),
);

const capture = createCaptureProvider({ metadata: { test: true } });
const graph = await capture.snapshot();
assert.equal(graph.artifactKind, 'doe_webgpu_capture_graph');
assert.match(graph.graphSha256, /^[0-9a-f]{64}$/u);

const unsupportedCapture = createCaptureProvider();
const unsupportedDevice = await unsupportedCapture.requestDevice();
assert.throws(
  () => unsupportedDevice.createTexture(),
  /does not support device\.createTexture/u,
);
const unsupportedGraph = await unsupportedCapture.snapshot();
assert.equal(unsupportedGraph.unsupported[0].id, 1);
assert.equal(unsupportedGraph.unsupported[0].method, 'device.createTexture');
const missingRecordId = validateCaptureGraph({
  ...unsupportedGraph,
  unsupported: [{ method: 'device.createTexture' }],
});
assert.equal(missingRecordId.ok, false);
assert.equal(
  missingRecordId.errors.some((error) => error.path === 'artifact.unsupported[0].id'),
  true,
);

const evidenceArtifact = {
  schemaVersion: 1,
  artifactKind: 'doe_webgpu_capture_evidence',
  modelId: 'plan-contract-test',
  sourceProgram: {},
  destinations: [],
  loweringStages: [],
  verdict: {},
};
assert.equal(validatePlanArtifact(evidenceArtifact).ok, true);
assert.equal(
  validatePlanArtifact({ ...evidenceArtifact, modelId: undefined }).ok,
  false,
);
assert.equal(
  validatePlanArtifact({
    schemaVersion: 2,
    artifactKind: 'csl_host_plan',
    target: 'wse3',
    contract: 'explicit_host_plan',
    hostPlan: {},
    compileTargets: [],
    implicitFallback: true,
  }).errors.some((error) => error.code === 'unknown_field'),
  true,
);
assert.equal(
  validatePlanArtifact({
    schemaVersion: 1,
    artifactKind: 'doe_stream_execution_plan',
    target: 'wse3',
    modelId: 'plan-contract-test',
    numTransformerLayers: 1,
    setupPhase: [],
    perLayerSchedule: [],
    prefetchPolicy: {},
    kvPolicy: {},
    steadyStatePayloadBytesPerLayer: 0,
    executorStatus: 'guessed',
  }).errors.some((error) => error.path === 'artifact.executorStatus'),
  true,
);

process.stdout.write('plan-contracts: ok\n');

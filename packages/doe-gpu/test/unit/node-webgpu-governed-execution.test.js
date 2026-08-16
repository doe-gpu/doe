import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import {
  runGovernedNodeWebGPU,
  validateGovernedNodeWebGPUReceipt,
} from '../../src/node-webgpu.js';

const fixtureUrl = new URL('../fixtures/provider-v1.js', import.meta.url).href;
const globals = {
  GPUBufferUsage: 'globals.GPUBufferUsage',
  GPUShaderStage: 'globals.GPUShaderStage',
  GPUMapMode: 'globals.GPUMapMode',
  GPUTextureUsage: 'globals.GPUTextureUsage',
};
const provider = {
  providers: [{
    id: 'governed-fixture',
    kind: 'module',
    module: fixtureUrl,
    gpu: { kind: 'factory', path: 'createFakeGPU', args: ['governed'] },
    globals,
  }],
  adapterOptions: null,
  globals: { mode: 'replace' },
};
const digest = (bytes) => `sha256:${createHash('sha256').update(bytes).digest('hex')}`;
const expected = new Uint8Array([2, 4, 6, 8]);
const implementationSha256 = digest('fixture implementation v1');

async function execute({ input }) {
  return Uint8Array.from(input, (value) => value * 2);
}

async function run(expectedOutputSha256 = digest(expected), checkpoint = undefined) {
  return runGovernedNodeWebGPU({
    provider,
    workload: {
      id: 'vector-double-u8',
      version: '1',
      implementationSha256,
      input: new Uint8Array([1, 2, 3, 4]),
      expectedOutputSha256,
    },
    execute,
    checkpoint,
  });
}

const checkpoints = [];
const first = await run(undefined, (receipt) => checkpoints.push(receipt));
assert.equal(first.ok, true);
assert.deepEqual([...first.output], [...expected]);
assert.equal(first.receipt.schema, 'doe.governed-node-webgpu-receipt/v1');
assert.equal(first.receipt.status, 'pass');
assert.equal(first.receipt.oracle.status, 'pass');
assert.equal(first.receipt.adapterInfoStatus, 'observed');
assert.equal(first.receipt.adapterInfo.vendor, 'Fixture Vendor');
assert.equal(first.receipt.adapterInfo.deviceID, 2);
assert.equal(first.receipt.lifecycle.status, 'release-complete');
assert.equal(first.receipt.lifecycle.globalsRestored, true);
assert.deepEqual(validateGovernedNodeWebGPUReceipt(first.receipt), {
  valid: true,
  errors: [],
});
assert.equal(checkpoints.length, 2);
assert.equal(checkpoints[0].checkpoint, 'inference-complete-release-pending');
assert.equal(checkpoints[0].status, 'oracle-pass');
assert.equal(checkpoints[0].lifecycle.status, 'release-pending');
assert.equal(validateGovernedNodeWebGPUReceipt(checkpoints[0]).valid, true);
assert.equal(checkpoints[1].checkpoint, 'release-complete');
assert.equal(checkpoints[1].lifecycle.globalsRestored, true);

const second = await run();
assert.equal(second.ok, true);
assert.equal(
  second.receipt.replay.workloadSha256,
  first.receipt.replay.workloadSha256,
  'semantic replay identity must not include timing or provider lifecycle state',
);
assert.equal(
  second.receipt.replay.executionSha256,
  first.receipt.replay.executionSha256,
  'execution identity must be stable for the same provider and adapter',
);

const alternateProvider = await runGovernedNodeWebGPU({
  provider: {
    ...provider,
    providers: [{ ...provider.providers[0], id: 'alternate-fixture' }],
  },
  workload: {
    id: 'vector-double-u8',
    version: '1',
    implementationSha256,
    input: new Uint8Array([1, 2, 3, 4]),
    expectedOutputSha256: digest(expected),
  },
  execute,
});
assert.equal(alternateProvider.ok, true);
assert.equal(
  alternateProvider.receipt.replay.workloadSha256,
  first.receipt.replay.workloadSha256,
);
assert.notEqual(
  alternateProvider.receipt.replay.executionSha256,
  first.receipt.replay.executionSha256,
  'execution identity must bind the selected provider declaration',
);

const mismatch = await run(digest(new Uint8Array([9])));
assert.equal(mismatch.ok, false);
assert.equal(mismatch.receipt.oracle.status, 'fail');
assert.equal(mismatch.receipt.lifecycle.globalsRestored, true);
assert.equal(mismatch.errors[0].code, 'DOE_GOVERNED_WORKLOAD_ORACLE_FAILED');

const executionFailure = await runGovernedNodeWebGPU({
  provider,
  workload: {
    id: 'execution-failure',
    version: '1',
    implementationSha256,
    input: new Uint8Array([1]),
    expectedOutputSha256: digest(new Uint8Array()),
  },
  execute: () => {
    throw new Error('workload failed');
  },
});
assert.equal(executionFailure.ok, false);
assert.equal(executionFailure.receipt.lifecycle.globalsRestored, true);
assert.equal(executionFailure.errors[0].code, 'DOE_GOVERNED_WORKLOAD_EXECUTION_FAILED');
assert.equal(validateGovernedNodeWebGPUReceipt(executionFailure.receipt).valid, true);

const sinkFailure = await run(undefined, () => {
  throw new Error('cannot persist');
});
assert.equal(sinkFailure.ok, false);
assert.equal(sinkFailure.receipt.lifecycle.globalsRestored, true);
assert.ok(sinkFailure.errors.every(
  (error) => error.code === 'DOE_GOVERNED_WORKLOAD_RECEIPT_SINK_FAILED',
));

const invalid = await runGovernedNodeWebGPU({
  provider,
  workload: {
    id: 'invalid',
    version: '1',
    implementationSha256: 'not-a-digest',
    input: new Uint8Array(),
    expectedOutputSha256: digest(new Uint8Array()),
  },
  execute,
});
assert.equal(invalid.ok, false);
assert.equal(invalid.receipt, null);
assert.equal(invalid.errors[0].code, 'DOE_GOVERNED_WORKLOAD_INVALID_CONFIGURATION');

const tampered = structuredClone(first.receipt);
tampered.workload.id = 'tampered';
const tamperedValidation = validateGovernedNodeWebGPUReceipt(tampered);
assert.equal(tamperedValidation.valid, false);
assert.ok(tamperedValidation.errors.includes(
  'replay.workloadSha256 does not match the workload contract',
));
assert.equal(validateGovernedNodeWebGPUReceipt(null).valid, false);

const observedFixtureUrl = new URL('../fixtures/provider-observed.js', import.meta.url).href;
const observedProvider = {
  providers: [{
    id: 'observed-fixture',
    kind: 'module',
    module: observedFixtureUrl,
    gpu: { kind: 'factory', path: 'createObservedGPU', args: [] },
    globals,
  }],
  adapterOptions: null,
  globals: { mode: 'replace' },
};

async function observedExecute({ adapter, input }) {
  const device = await adapter.requestDevice();
  const module = device.createShaderModule({
    code: '@compute @workgroup_size(4) fn main() {}',
  });
  const pipeline = device.createComputePipeline({
    layout: 'auto',
    compute: { module, entryPoint: 'main' },
  });
  const output = device.createBuffer({ size: input.byteLength, usage: 7 });
  device.queue.writeBuffer(output, 0, Uint8Array.from(input, (value) => value * 2));
  const encoder = device.createCommandEncoder();
  const pass = encoder.beginComputePass();
  pass.setPipeline(pipeline);
  pass.dispatchWorkgroups(1);
  pass.end();
  device.queue.submit([encoder.finish()]);
  await device.queue.onSubmittedWorkDone();
  await output.mapAsync(1, 0, input.byteLength);
  const bytes = new Uint8Array(output.getMappedRange(0, input.byteLength));
  device.destroy();
  return bytes;
}

async function runObserved() {
  return runGovernedNodeWebGPU({
    provider: observedProvider,
    workload: {
      id: 'observed-vector-double-u8',
      version: '1',
      implementationSha256,
      input: new Uint8Array([1, 2, 3, 4]),
      expectedOutputSha256: digest(expected),
    },
    observeProgram: { metadata: { contract: 'unit-observer' } },
    execute: observedExecute,
  });
}

const observedFirst = await runObserved();
assert.equal(observedFirst.ok, true);
assert.equal(observedFirst.receipt.programEvidence.status, 'observed');
assert.equal(observedFirst.receipt.programEvidence.observation.summary.shaderModuleCount, 1);
assert.equal(observedFirst.receipt.programEvidence.observation.summary.dispatchCount, 1);
assert.equal(observedFirst.receipt.programEvidence.observation.summary.submissionCount, 1);
assert.equal(observedFirst.receipt.programEvidence.observation.summary.readbackCount, 1);
assert.equal(validateGovernedNodeWebGPUReceipt(observedFirst.receipt).valid, true);
const observedSecond = await runObserved();
assert.equal(
  observedSecond.receipt.programEvidence.observationSha256,
  observedFirst.receipt.programEvidence.observationSha256,
);
assert.equal(
  observedSecond.receipt.replay.executionSha256,
  observedFirst.receipt.replay.executionSha256,
  'governed replay identity must bind stable program evidence',
);
const tamperedObservation = structuredClone(observedFirst.receipt);
tamperedObservation.programEvidence.observation.summary.dispatchCount += 1;
assert.equal(validateGovernedNodeWebGPUReceipt(tamperedObservation).valid, false);

console.log('node-webgpu governed execution contracts: ok');

// Physical-device regressions for command ordering, reset, and program lifetime.
import assert from 'node:assert/strict';
import { requestAdapter } from '../../src/native.js';
import { prepareComputeProgram } from '../../src/compute-program.js';
import { globals } from '../../src/vendor/webgpu/webgpu-constants.js';

const { GPUBufferUsage: U, GPUMapMode: M } = globals;
const descriptor = {
  schemaVersion: 1, id: 'reset_probe',
  buffers: [
    { id: 'input', size: 16, type: 'storage', role: 'input' },
    { id: 'output', size: 16, type: 'storage', role: 'output' },
  ],
  shaders: [{ id: 'add', entryPoint: 'main', code: `
    @group(0) @binding(0) var<storage, read> a: array<u32>;
    @group(0) @binding(1) var<storage, read_write> b: array<u32>;
    @compute @workgroup_size(1) fn main(@builtin(global_invocation_id) id: vec3<u32>) {
      b[id.x] = b[id.x] + a[id.x];
    }` }],
  steps: [{ shader: 'add', bindings: [
    { binding: 0, buffer: 'input' }, { binding: 1, buffer: 'output' },
  ], workgroups: [4, 1, 1] }],
  output: 'output',
};

const timed = process.argv.includes('--timestamps');
const adapter = await requestAdapter({ backend: process.platform === 'darwin' ? 'metal' : 'vulkan' });
const device = await adapter.requestDevice({ requiredFeatures: timed ? ['timestamp-query'] : [] });
const timingOptions = { gpuTiming: timed ? 'timestamp-query' : 'off' };
const createBuffer = device.createBuffer.bind(device);
let abortDuringReadback = null;
device.createBuffer = (declaration) => {
  const buffer = createBuffer(declaration);
  if (declaration.usage & U.MAP_READ) {
    const map = buffer.mapAsync.bind(buffer);
    buffer.mapAsync = async (...args) => {
      await map(...args);
      abortDuringReadback?.abort();
      abortDuringReadback = null;
    };
  }
  return buffer;
};
try {
  // Encoding a clear must not alter a buffer before submission. Copy/clear/copy
  // in one submission must observe both sides of the clear, including its range.
  const buffer = device.createBuffer({ size: 16, usage: U.COPY_SRC | U.COPY_DST });
  const readback = device.createBuffer({ size: 32, usage: U.MAP_READ | U.COPY_DST });
  device.queue.writeBuffer(buffer, 0, new Uint32Array([1, 2, 3, 4]));
  const encoder = device.createCommandEncoder();
  encoder.copyBufferToBuffer(buffer, 0, readback, 0, 16);
  encoder.clearBuffer(buffer, 4, 8);
  encoder.copyBufferToBuffer(buffer, 0, readback, 16, 16);
  device.queue.writeBuffer(buffer, 0, new Uint32Array([5, 6, 7, 8]));
  device.queue.submit([encoder.finish()]);
  await device.queue.onSubmittedWorkDone();
  await readback.mapAsync(M.READ);
  assert.deepEqual([...new Uint32Array(readback.getMappedRange())], [5, 6, 7, 8, 5, 0, 0, 8]);
  readback.unmap();
  buffer.destroy();
  readback.destroy();
  console.log('ok: clear executes at submission in copy/clear/copy order');

  const pending = device.createBuffer({ size: 16, usage: U.COPY_DST | U.MAP_READ });
  const pendingEncoder = device.createCommandEncoder();
  pendingEncoder.clearBuffer(pending);
  const pendingCommands = pendingEncoder.finish();
  device.queue.writeBuffer(pending, 0, new Uint32Array([9, 9, 9, 9]));
  device.queue.submit([pendingCommands]);
  await device.queue.onSubmittedWorkDone();
  await pending.mapAsync(M.READ);
  assert.deepEqual([...new Uint32Array(pending.getMappedRange())], [0, 0, 0, 0]);
  pending.unmap();
  device.queue.writeBuffer(pending, 0, new Uint32Array([3]));
  await pending.mapAsync(M.READ);
  assert.deepEqual([...new Uint32Array(pending.getMappedRange())], [3, 0, 0, 0]);
  pending.unmap();
  pending.destroy();
  console.log('ok: submission invalidates later uploads; partial writes cannot validate stale bytes');

  const separateInput = device.createBuffer({ size: 4, usage: U.STORAGE | U.COPY_DST });
  const separateOutput = device.createBuffer({ size: 4, usage: U.STORAGE | U.COPY_SRC });
  const separateReadback = device.createBuffer({ size: 4, usage: U.COPY_DST | U.MAP_READ });
  const iterations = 65536;
  const separateShader = device.createShaderModule({ code: `
    @group(0) @binding(0) var<storage, read> input: array<u32>;
    @group(0) @binding(1) var<storage, read_write> output: array<u32>;
    @compute @workgroup_size(1) fn main() {
      var value = input[0];
      for (var i = 0u; i < ${iterations}u; i++) { value = (value * 1664525u + 1013904223u) ^ i; }
      output[0] = value;
    }` });
  const separatePipeline = device.createComputePipeline({ layout: 'auto', compute: { module: separateShader, entryPoint: 'main' } });
  const separateBindings = device.createBindGroup({ layout: separatePipeline.getBindGroupLayout(0), entries: [
    { binding: 0, resource: { buffer: separateInput } }, { binding: 1, resource: { buffer: separateOutput } },
  ] });
  device.queue.writeBuffer(separateInput, 0, new Uint32Array([7]));
  const computeEncoder = device.createCommandEncoder();
  const separatePass = computeEncoder.beginComputePass();
  separatePass.setPipeline(separatePipeline);
  separatePass.setBindGroup(0, separateBindings);
  separatePass.dispatchWorkgroups(1);
  separatePass.end();
  device.queue.submit([computeEncoder.finish()]);
  const copyEncoder = device.createCommandEncoder();
  copyEncoder.copyBufferToBuffer(separateOutput, 0, separateReadback, 0, 4);
  device.queue.submit([copyEncoder.finish()]);
  await separateReadback.mapAsync(M.READ);
  let expectedSeparate = 7;
  for (let i = 0; i < iterations; i += 1) expectedSeparate = ((Math.imul(expectedSeparate, 1664525) + 1013904223) ^ i) >>> 0;
  assert.equal(new Uint32Array(separateReadback.getMappedRange())[0], expectedSeparate);
  separateReadback.unmap();
  separateInput.destroy();
  separateOutput.destroy();
  separateReadback.destroy();
  console.log('ok: separate copy submission waits for its preceding GPU producer');

  const modes = ['native-recorded', 'webgpu'];
  if (process.platform === 'linux') modes.push('gpu-recorded');
  for (const execution of modes) {
    const source = structuredClone(descriptor);
    const program = await prepareComputeProgram(device, source, { execution, ...timingOptions });
    source.steps[0].workgroups[0] = 1;
    source.shaders[0].code = 'invalid';
    assert.equal(program.descriptor.steps[0].workgroups[0], 4);
    assert.throws(() => program.run({ input: new Uint32Array([1]) }), { code: 'DOE_PROGRAM_INPUT' });
    assert.throws(() => program.run({ input: new Uint32Array(4), extra: new Uint32Array(4) }), { code: 'DOE_PROGRAM_INPUT' });
    for (const words of [[7, 9, 11, 13], [1, 2, 3, 4], [0, 0, 0, 0]]) {
      const input = new Uint32Array(words);
      const pending = program.run({ input });
      input.fill(99);
      assert.throws(() => program.run({ input }), { code: 'DOE_PROGRAM_BUSY' });
      const result = await pending;
      assert.deepEqual([...new Uint32Array(result.output.buffer)], words);
      assert.equal(result.receipt.dispatchCount, 1);
      if (timed) {
        assert.equal(result.receipt.schemaVersion, 3);
        assert.equal(result.receipt.gpuTiming.source, 'webgpu-nanoseconds');
        assert.equal(result.receipt.gpuTiming.periodNs, 1);
        assert.equal(result.receipt.gpuTiming.validBits, 64);
        assert(result.receipt.gpuTiming.elapsedNs > 0);
        assert(BigInt(result.receipt.gpuTiming.endTicks) > BigInt(result.receipt.gpuTiming.beginTicks));
      } else assert.equal(result.receipt.gpuTiming, null);
    }
    const abort = new AbortController();
    abort.abort();
    await assert.rejects(program.run({ input: new Uint32Array(4) }, { signal: abort.signal }), { code: 'DOE_PROGRAM_CANCELLED' });
    const during = new AbortController();
    const cancelled = program.run({ input: new Uint32Array([9, 9, 9, 9]) }, { signal: during.signal });
    during.abort();
    await assert.rejects(cancelled, { code: 'DOE_PROGRAM_CANCELLED' });
    abortDuringReadback = new AbortController();
    await assert.rejects(program.run({ input: new Uint32Array([9, 9, 9, 9]) },
      { signal: abortDuringReadback.signal }), { code: 'DOE_PROGRAM_CANCELLED' });
    const recovered = await program.run({ input: new Uint32Array([2, 3, 4, 5]) });
    assert.deepEqual([...new Uint32Array(recovered.output.buffer)], [2, 3, 4, 5]);
    assert.equal(await program.update(descriptor), program);
    const smaller = structuredClone(descriptor);
    smaller.buffers.forEach((declaration) => { declaration.size = 8; });
    smaller.steps[0].workgroups[0] = 2;
    const replacement = await program.update(smaller);
    assert.equal(program.state, 'closed');
    assert(replacement.preparation.reusedResources > 0);
    const changedOutput = await replacement.run({ input: new Uint32Array([19, 23]) });
    assert.equal(changedOutput.receipt.gpuTiming !== null, timed);
    assert.deepEqual([...new Uint32Array(changedOutput.output.buffer)], [19, 23]);
    const changedSource = structuredClone(smaller);
    changedSource.shaders[0].code = changedSource.shaders[0].code.replace('b[id.x] + a[id.x]', 'a[id.x] * 2u');
    const doubled = await replacement.update(changedSource);
    assert(doubled.preparation.reusedResources > 0);
    const invalidSource = structuredClone(changedSource);
    invalidSource.shaders[0].code = 'not valid WGSL';
    await assert.rejects(doubled.update(invalidSource));
    assert.equal(doubled.state, 'ready');
    const doubledOutput = await doubled.run({ input: new Uint32Array([19, 23]) });
    assert.deepEqual([...new Uint32Array(doubledOutput.output.buffer)], [38, 46]);
    await doubled.close();
    await replacement.close();
    await program.close();
    await program.close();
    assert.throws(() => program.run({ input: new Uint32Array(4) }), { code: 'DOE_PROGRAM_INVALIDATED' });
    console.log(`ok: ${execution} snapshots, reset, cancellation, shape/source update, reuse, rollback, close`);
  }
  if (process.platform === 'linux') {
    const first = await prepareComputeProgram(device, descriptor, { execution: 'gpu-recorded' });
    const otherDescriptor = structuredClone(descriptor);
    otherDescriptor.shaders[0].code = otherDescriptor.shaders[0].code.replace('b[id.x] + a[id.x]', 'a[id.x] * 3u');
    const second = await prepareComputeProgram(device, otherDescriptor, { execution: 'gpu-recorded' });
    const ordinary = await prepareComputeProgram(device, descriptor, { execution: 'webgpu' });
    for (const program of [first, ordinary, second, first, second]) {
      const result = await program.run({ input: new Uint32Array([2, 3, 4, 5]) });
      assert.deepEqual([...new Uint32Array(result.output.buffer)], program === second ? [6, 9, 12, 15] : [2, 3, 4, 5]);
    }
    await first.close();
    const remaining = await second.run({ input: new Uint32Array([4, 5, 6, 7]) });
    assert.deepEqual([...new Uint32Array(remaining.output.buffer)], [12, 15, 18, 21]);
    await second.close();
    await ordinary.close();
    console.log('ok: GPU recordings survive interleaved programs, ordinary cache changes, and independent close');
  }
  if (timed && process.platform === 'linux') {
    const createQuery = device.createQuerySet.bind(device);
    let retainedQuery;
    device.createQuerySet = (...args) => { retainedQuery = createQuery(...args); return retainedQuery; };
    const program = await prepareComputeProgram(device, descriptor,
      { execution: 'gpu-recorded', ...timingOptions });
    device.createQuerySet = createQuery;
    retainedQuery.destroy();
    await assert.rejects(program.run({ input: new Uint32Array([1, 2, 3, 4]) }), /DOE_PROGRAM_INVALIDATED/);
    await program.close();
    console.log('ok: destroyed timestamp query invalidates GPU recording before submission');
  }
  const lost = [];
  for (const execution of modes) lost.push(await prepareComputeProgram(device, descriptor, { execution }));
  device.destroy();
  for (const program of lost) {
    assert.throws(() => program.run({ input: new Uint32Array(4) }), { code: 'DOE_PROGRAM_INVALIDATED' });
    await program.close();
  }
  console.log('ok: destroyed device invalidates prepared program');
} finally {
  device.destroy();
}

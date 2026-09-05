// Physical GPU timestamps must preserve pass boundaries, output, and repeated readback.
import assert from 'node:assert/strict';
const useBunFfi = process.argv.includes('--bun-ffi');
const { requestAdapter, globals, providerInfo } = useBunFfi
  ? await import('../../src/bun.js') : await import('../../src/native.js');
if (useBunFfi) assert.equal(providerInfo().bunRuntimeProvider, 'doe-ffi');

const ITERATIONS = 4096;
const RUNS = 4;
const WORD_BYTES = Uint32Array.BYTES_PER_ELEMENT;
const QUERY_BYTES = BigUint64Array.BYTES_PER_ELEMENT;
const QUERY_COUNT = 4;
const { GPUBufferUsage: U, GPUMapMode: M } = globals;
const adapter = await requestAdapter({ backend: process.platform === 'darwin' ? 'metal' : 'vulkan' });
assert(adapter.features.has('timestamp-query'), 'selected adapter must support timestamp-query');
const device = await adapter.requestDevice({ requiredFeatures: ['timestamp-query'] });
const resources = [];
function buffer(size, usage) {
  const result = device.createBuffer({ size, usage });
  resources.push(result);
  return result;
}
function oracle(input) {
  let value = input;
  for (let i = 0; i < ITERATIONS; i += 1) value = ((Math.imul(value, 1664525) + 1013904223) ^ i) >>> 0;
  return value;
}
try {
  const query = device.createQuerySet({ type: 'timestamp', count: QUERY_COUNT });
  resources.push(query);
  const input = buffer(WORD_BYTES, U.STORAGE | U.COPY_DST);
  const output = buffer(WORD_BYTES, U.STORAGE | U.COPY_SRC);
  const resolved = buffer(QUERY_COUNT * QUERY_BYTES, U.QUERY_RESOLVE | U.COPY_SRC | U.COPY_DST);
  const readback = buffer(QUERY_COUNT * QUERY_BYTES + WORD_BYTES, U.MAP_READ | U.COPY_DST);
  const shader = device.createShaderModule({ code: `
    @group(0) @binding(0) var<storage, read> input: array<u32>;
    @group(0) @binding(1) var<storage, read_write> output: array<u32>;
    @compute @workgroup_size(1) fn main() {
      var value = input[0];
      for (var i = 0u; i < ${ITERATIONS}u; i++) { value = (value * 1664525u + 1013904223u) ^ i; }
      output[0] = value;
    }` });
  const pipeline = device.createComputePipeline({ layout: 'auto', compute: { module: shader, entryPoint: 'main' } });
  const bindings = device.createBindGroup({ layout: pipeline.getBindGroupLayout(0), entries: [
    { binding: 0, resource: { buffer: input } }, { binding: 1, resource: { buffer: output } },
  ] });
  let previousEnd = 0n;
  for (let run = 0; run < RUNS; run += 1) {
    device.pushErrorScope('validation');
    device.queue.writeBuffer(input, 0, new Uint32Array([run + 1]));
    const encoder = device.createCommandEncoder();
    for (const writes of [
      { beginningOfPassWriteIndex: 0, endOfPassWriteIndex: 1 },
      { beginningOfPassWriteIndex: 2 },
      { endOfPassWriteIndex: 3 },
    ]) {
      const pass = encoder.beginComputePass({ timestampWrites: { querySet: query, ...writes } });
      pass.setPipeline(pipeline);
      pass.setBindGroup(0, bindings);
      pass.dispatchWorkgroups(1);
      pass.end();
    }
    encoder.resolveQuerySet(query, 0, QUERY_COUNT, resolved, 0);
    encoder.copyBufferToBuffer(resolved, 0, readback, 0, QUERY_COUNT * QUERY_BYTES);
    encoder.copyBufferToBuffer(output, 0, readback, QUERY_COUNT * QUERY_BYTES, WORD_BYTES);
    // A later host upload cannot make the recorded query destination's shadow authoritative.
    device.queue.writeBuffer(resolved, 0, new BigUint64Array(QUERY_COUNT));
    device.queue.submit([encoder.finish()]);
    await readback.mapAsync(M.READ);
    const bytes = readback.getMappedRange();
    const stamps = [...new BigUint64Array(bytes, 0, QUERY_COUNT)];
    assert.equal(new Uint32Array(bytes, QUERY_COUNT * QUERY_BYTES, 1)[0], oracle(run + 1));
    assert(stamps[0] > previousEnd, 'query reset must produce fresh timestamps');
    assert(stamps[1] > stamps[0], 'compute pass must consume GPU time');
    assert(stamps[2] >= stamps[1] && stamps[3] > stamps[2], 'one-sided pass boundaries must stay ordered');
    previousEnd = stamps[3];
    readback.unmap();
    assert.equal(await device.popErrorScope(), null);
    console.log(`ok: timestamp run ${run}, fresh ordered queries and exact shader output`);
  }
} finally {
  for (const resource of resources.reverse()) resource.destroy();
  device.destroy();
}

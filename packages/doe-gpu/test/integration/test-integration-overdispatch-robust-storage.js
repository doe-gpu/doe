#!/usr/bin/env node

import { setupGlobals } from '../../src/index.js';

setupGlobals();

const adapter = await navigator.gpu.requestAdapter();
if (!adapter) throw new Error('no adapter');
const device = await adapter.requestDevice();

const module = device.createShaderModule({
  code: `
    @group(0) @binding(0) var<storage, read_write> output: array<u32>;
    @compute @workgroup_size(64)
    fn main(@builtin(global_invocation_id) id: vec3<u32>) {
      output[id.x] = id.x + 1u;
    }
  `,
});
const pipeline = device.createComputePipeline({
  layout: 'auto',
  compute: { module, entryPoint: 'main' },
});
const output = device.createBuffer({
  size: 10 * Uint32Array.BYTES_PER_ELEMENT,
  usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC,
});
const readback = device.createBuffer({
  size: 10 * Uint32Array.BYTES_PER_ELEMENT,
  usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
});
const bindGroup = device.createBindGroup({
  layout: pipeline.getBindGroupLayout(0),
  entries: [{ binding: 0, resource: { buffer: output } }],
});
const encoder = device.createCommandEncoder();
const pass = encoder.beginComputePass();
pass.setPipeline(pipeline);
pass.setBindGroup(0, bindGroup);
pass.dispatchWorkgroups(1);
pass.end();
encoder.copyBufferToBuffer(output, 0, readback, 0, 40);
device.queue.submit([encoder.finish()]);
await readback.mapAsync(GPUMapMode.READ);
const actual = Array.from(new Uint32Array(readback.getMappedRange()));
readback.unmap();

output.destroy();
readback.destroy();
device.destroy();

const expected = Array.from({ length: 10 }, (_, index) => index + 1);
if (actual.length !== expected.length || actual.some((value, index) => value !== expected[index])) {
  throw new Error(`robust overdispatch produced [${actual.join(', ')}]; expected [${expected.join(', ')}]`);
}
process.stdout.write('robust storage overdispatch: out-of-bounds writes discarded\n');

#!/usr/bin/env node

import { requestNativeDeviceOrSkip } from './native-device-test-helper.js';

const device = await requestNativeDeviceOrSkip('explicit-layout overdispatch');

const module = device.createShaderModule({
  code: `
    @group(0) @binding(0) var<storage, read> weights: array<f32>;
    @group(0) @binding(1) var<storage, read> hidden: array<f32>;
    @group(0) @binding(2) var<storage, read_write> output: array<f32>;

    @compute @workgroup_size(64, 1, 1)
    fn OutputLayer(@builtin(global_invocation_id) id: vec3<u32>) {
      let output_index = i32(id.x);
      let base = output_index * 2;
      let sum = weights[base] + hidden[0] * weights[base + 1];
      output[output_index] = 1.0 / (1.0 + exp(-sum));
    }
  `,
});
const layout = device.createBindGroupLayout({
  entries: [
    { binding: 0, visibility: GPUShaderStage.COMPUTE, buffer: { type: 'read-only-storage' } },
    { binding: 1, visibility: GPUShaderStage.COMPUTE, buffer: { type: 'read-only-storage' } },
    { binding: 2, visibility: GPUShaderStage.COMPUTE, buffer: { type: 'storage' } },
  ],
});
const pipeline = device.createComputePipeline({
  layout: device.createPipelineLayout({ bindGroupLayouts: [layout] }),
  compute: { module, entryPoint: 'OutputLayer' },
});

const weights = device.createBuffer({
  size: 20 * Float32Array.BYTES_PER_ELEMENT,
  usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.STORAGE,
});
const hidden = device.createBuffer({
  size: Float32Array.BYTES_PER_ELEMENT,
  usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.STORAGE,
});
const output = device.createBuffer({
  size: 10 * Float32Array.BYTES_PER_ELEMENT,
  usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC,
});
const readback = device.createBuffer({
  size: 10 * Float32Array.BYTES_PER_ELEMENT,
  usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
});
device.queue.writeBuffer(weights, 0, new Float32Array(20).fill(1));
device.queue.writeBuffer(hidden, 0, new Float32Array([0]));

const bindGroup = device.createBindGroup({
  layout,
  entries: [
    { binding: 0, resource: { buffer: weights } },
    { binding: 1, resource: { buffer: hidden } },
    { binding: 2, resource: { buffer: output } },
  ],
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
const actual = Array.from(new Float32Array(readback.getMappedRange()));
readback.unmap();

for (const buffer of [weights, hidden, output, readback]) buffer.destroy();
device.destroy();

const expected = 1 / (1 + Math.exp(-1));
if (actual.slice(0, 9).some((value) => Math.abs(value - expected) > 1e-6)) {
  throw new Error(`explicit-layout overdispatch produced [${actual.join(', ')}]; expected first nine near ${expected}`);
}
process.stdout.write('explicit-layout overdispatch: custom entry and uploaded storage passed\n');

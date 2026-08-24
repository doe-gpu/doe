#!/usr/bin/env node

import { setupGlobals } from '../../src/index.js';

setupGlobals();

const adapter = await navigator.gpu.requestAdapter();
if (!adapter) throw new Error('no adapter');
const device = await adapter.requestDevice();

const module = device.createShaderModule({
  code: `
    @group(0) @binding(0) var<storage, read_write> output: array<f32>;
    @group(0) @binding(1) var sampled: texture_2d<f32>;
    @compute @workgroup_size(1)
    fn main() {
      output[0] = textureLoad(sampled, vec2<i32>(0, 0), 0).x + 5.0;
    }
  `,
});
const bindGroupLayout = device.createBindGroupLayout({
  entries: [
    { binding: 0, visibility: GPUShaderStage.COMPUTE, buffer: { type: 'storage' } },
    {
      binding: 1,
      visibility: GPUShaderStage.COMPUTE,
      texture: { sampleType: 'float', viewDimension: '2d' },
    },
  ],
});
const pipeline = device.createComputePipeline({
  layout: device.createPipelineLayout({ bindGroupLayouts: [bindGroupLayout] }),
  compute: { module, entryPoint: 'main' },
});
const indirectWriterModule = device.createShaderModule({
  code: `
    @group(0) @binding(0) var<storage, read_write> indirect_args: array<u32>;
    @compute @workgroup_size(1)
    fn main() {
      indirect_args[0] = 1u;
      indirect_args[1] = 1u;
      indirect_args[2] = 1u;
    }
  `,
});
const indirectWriterLayout = device.createBindGroupLayout({
  entries: [{
    binding: 0,
    visibility: GPUShaderStage.COMPUTE,
    buffer: { type: 'storage' },
  }],
});
const indirectWriter = device.createComputePipeline({
  layout: device.createPipelineLayout({ bindGroupLayouts: [indirectWriterLayout] }),
  compute: { module: indirectWriterModule, entryPoint: 'main' },
});

const texture = device.createTexture({
  size: [1, 1, 1],
  format: 'rgba8unorm',
  usage: GPUTextureUsage.COPY_DST | GPUTextureUsage.TEXTURE_BINDING,
});
device.queue.writeTexture(
  { texture },
  new Uint8Array([255, 0, 0, 255]),
  { bytesPerRow: 4, rowsPerImage: 1 },
  { width: 1, height: 1, depthOrArrayLayers: 1 },
);
const output = device.createBuffer({
  size: Float32Array.BYTES_PER_ELEMENT,
  usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC,
});
const indirect = device.createBuffer({
  size: 3 * Uint32Array.BYTES_PER_ELEMENT,
  usage: GPUBufferUsage.STORAGE | GPUBufferUsage.INDIRECT | GPUBufferUsage.COPY_DST,
});
device.queue.writeBuffer(indirect, 0, new Uint32Array([0, 0, 0]));
const readback = device.createBuffer({
  size: Float32Array.BYTES_PER_ELEMENT,
  usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
});
const bindGroup = device.createBindGroup({
  layout: bindGroupLayout,
  entries: [
    { binding: 0, resource: { buffer: output } },
    { binding: 1, resource: texture.createView() },
  ],
});
const indirectWriterGroup = device.createBindGroup({
  layout: indirectWriterLayout,
  entries: [{ binding: 0, resource: { buffer: indirect } }],
});

const encoder = device.createCommandEncoder();
const writerPass = encoder.beginComputePass();
writerPass.setPipeline(indirectWriter);
writerPass.setBindGroup(0, indirectWriterGroup);
writerPass.dispatchWorkgroups(1);
writerPass.end();
const indirectPass = encoder.beginComputePass();
indirectPass.setPipeline(pipeline);
indirectPass.setBindGroup(0, bindGroup);
indirectPass.dispatchWorkgroupsIndirect(indirect, 0);
indirectPass.end();
encoder.copyBufferToBuffer(output, 0, readback, 0, Float32Array.BYTES_PER_ELEMENT);
device.queue.submit([encoder.finish()]);
await readback.mapAsync(GPUMapMode.READ);
const actual = new Float32Array(readback.getMappedRange())[0];
readback.unmap();

for (const buffer of [output, indirect, readback]) buffer.destroy();
texture.destroy();
device.destroy();

if (actual !== 6) {
  throw new Error(`indirect texture binding produced ${actual}; expected 6`);
}
process.stdout.write('indirect texture binding: GPU-authored indirect dispatch passed\n');

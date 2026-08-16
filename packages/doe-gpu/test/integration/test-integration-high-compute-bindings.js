#!/usr/bin/env node

import { setupGlobals } from '../../src/index.js';

setupGlobals();

const adapter = await navigator.gpu.requestAdapter();
if (!adapter) throw new Error('no adapter');
const device = await adapter.requestDevice();

const module = device.createShaderModule({
  code: `
    @group(0) @binding(0) var<storage, read_write> output: array<f32>;
    @group(0) @binding(16) var sampled: texture_2d<f32>;
    struct Params { value: vec4<f32> };
    @group(0) @binding(17) var<uniform> params: Params;

    @compute @workgroup_size(1)
    fn main() {
      output[0] = textureLoad(sampled, vec2<i32>(0, 0), 0).x + params.value.x;
    }
  `,
});
const layoutEntries = [
  { binding: 0, visibility: GPUShaderStage.COMPUTE, buffer: { type: 'storage' } },
  {
    binding: 16,
    visibility: GPUShaderStage.COMPUTE,
    texture: { sampleType: 'float', viewDimension: '2d' },
  },
  { binding: 17, visibility: GPUShaderStage.COMPUTE, buffer: { type: 'uniform' } },
];
const bindGroupLayout = device.createBindGroupLayout({ entries: layoutEntries });
const pipeline = device.createComputePipeline({
  layout: device.createPipelineLayout({ bindGroupLayouts: [bindGroupLayout] }),
  compute: { module, entryPoint: 'main' },
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
const params = device.createBuffer({
  size: 16,
  usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
});
const readback = device.createBuffer({
  size: Float32Array.BYTES_PER_ELEMENT,
  usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
});
device.queue.writeBuffer(params, 0, new Float32Array([5, 0, 0, 0]));

const sampledView = texture.createView();
const bindGroup = device.createBindGroup({
  layout: bindGroupLayout,
  entries: [
    { binding: 0, resource: { buffer: output } },
    { binding: 16, resource: sampledView },
    { binding: 17, resource: { buffer: params } },
  ],
});
const encoder = device.createCommandEncoder();
const pass = encoder.beginComputePass();
pass.setPipeline(pipeline);
pass.setBindGroup(0, bindGroup);
pass.dispatchWorkgroups(1);
pass.end();
encoder.copyBufferToBuffer(output, 0, readback, 0, Float32Array.BYTES_PER_ELEMENT);
device.queue.submit([encoder.finish()]);
await readback.mapAsync(GPUMapMode.READ);
const actual = new Float32Array(readback.getMappedRange())[0];
readback.unmap();

for (const buffer of [output, params, readback]) buffer.destroy();
texture.destroy();
device.destroy();

const expected = 6;
if (actual !== expected) {
  throw new Error(`high compute bindings produced ${actual}; expected ${expected}`);
}
process.stdout.write('high compute bindings: bindings 16 and 17 passed\n');

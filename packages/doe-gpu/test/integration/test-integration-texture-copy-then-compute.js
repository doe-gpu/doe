#!/usr/bin/env node

import { setupGlobals } from '../../src/index.js';

setupGlobals();

const adapter = await navigator.gpu.requestAdapter();
if (!adapter) throw new Error('no adapter');
const device = await adapter.requestDevice();

const sourceTexture = device.createTexture({
  size: [1, 1, 1],
  format: 'rgba8unorm',
  usage: GPUTextureUsage.COPY_DST | GPUTextureUsage.COPY_SRC,
});
const destinationTexture = device.createTexture({
  size: [1, 1, 1],
  format: 'rgba8unorm',
  usage: GPUTextureUsage.COPY_DST | GPUTextureUsage.COPY_SRC,
});
device.queue.writeTexture(
  { texture: sourceTexture },
  new Uint8Array([1, 2, 3, 4]),
  { bytesPerRow: 4, rowsPerImage: 1 },
  { width: 1, height: 1, depthOrArrayLayers: 1 },
);

const shader = device.createShaderModule({
  code: `
    @group(0) @binding(0) var<storage, read_write> output: array<u32>;
    @compute @workgroup_size(1) fn main() { output[0] = 42u; }
  `,
});
const pipeline = device.createComputePipeline({
  layout: 'auto',
  compute: { module: shader, entryPoint: 'main' },
});
const output = device.createBuffer({
  size: 4,
  usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC,
});
const readback = device.createBuffer({
  size: 4,
  usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
});
const bindGroup = device.createBindGroup({
  layout: pipeline.getBindGroupLayout(0),
  entries: [{ binding: 0, resource: { buffer: output } }],
});

const copyEncoder = device.createCommandEncoder();
copyEncoder.copyTextureToTexture(
  { texture: sourceTexture },
  { texture: destinationTexture },
  { width: 1, height: 1, depthOrArrayLayers: 1 },
);
const encoder = copyEncoder;
const pass = encoder.beginComputePass();
pass.setPipeline(pipeline);
pass.setBindGroup(0, bindGroup);
pass.dispatchWorkgroups(1);
pass.end();
encoder.copyBufferToBuffer(output, 0, readback, 0, 4);
device.queue.submit([encoder.finish()]);
await readback.mapAsync(GPUMapMode.READ);
const actual = new Uint32Array(readback.getMappedRange())[0];
readback.unmap();

for (const buffer of [output, readback]) buffer.destroy();
sourceTexture.destroy();
destinationTexture.destroy();
device.destroy();

if (actual !== 42) {
  throw new Error(`texture-copy then compute produced ${actual}; expected 42`);
}
process.stdout.write('texture-copy then compute: ordered submission passed\n');

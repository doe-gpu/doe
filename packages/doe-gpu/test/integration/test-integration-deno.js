#!/usr/bin/env -S deno run --allow-all

import { providerInfo, setupGlobals } from '../../src/deno.js';

setupGlobals();

const adapter = await navigator.gpu.requestAdapter();
if (!adapter) {
  throw new Error('Deno could not acquire a Doe GPU adapter');
}
const device = await adapter.requestDevice();
const output = device.createBuffer({
  size: 4,
  usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC,
});
const readback = device.createBuffer({
  size: 4,
  usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
});
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
const bindGroup = device.createBindGroup({
  layout: pipeline.getBindGroupLayout(0),
  entries: [{ binding: 0, resource: { buffer: output } }],
});
const encoder = device.createCommandEncoder();
const pass = encoder.beginComputePass({ label: 'deno-compute-pass' });
pass.setPipeline(pipeline);
pass.setBindGroup(0, bindGroup);
pass.dispatchWorkgroups(1);
pass.end();
encoder.copyBufferToBuffer(output, 0, readback, 0, 4);
device.queue.submit([encoder.finish()]);
await readback.mapAsync(GPUMapMode.READ);
const value = new Uint32Array(readback.getMappedRange())[0];
readback.unmap();
output.destroy();
readback.destroy();
device.destroy();

if (value !== 42) {
  throw new Error(`Deno compute produced ${value}; expected 42`);
}

process.stdout.write(`${JSON.stringify({ runtimeHost: 'deno', provider: providerInfo(), value })}\n`);

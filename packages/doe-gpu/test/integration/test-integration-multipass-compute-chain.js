#!/usr/bin/env node

import { setupGlobals } from '../../src/index.js';

setupGlobals();

const adapter = await navigator.gpu.requestAdapter();
if (!adapter) throw new Error('no adapter');
const device = await adapter.requestDevice();

function makePipeline(code) {
  const module = device.createShaderModule({ code });
  return device.createComputePipeline({
    layout: 'auto',
    compute: { module, entryPoint: 'main' },
  });
}

const seedPipeline = makePipeline(`
  @group(0) @binding(0) var<storage, read_write> output: array<u32>;
  @compute @workgroup_size(1) fn main() { output[0] = 5u; }
`);
const addPipeline = makePipeline(`
  @group(0) @binding(0) var<storage, read> input: array<u32>;
  @group(0) @binding(1) var<storage, read_write> output: array<u32>;
  @compute @workgroup_size(1) fn main() { output[0] = input[0] + 7u; }
`);
const multiplyPipeline = makePipeline(`
  @group(0) @binding(0) var<storage, read> input: array<u32>;
  @group(0) @binding(1) var<storage, read_write> output: array<u32>;
  @compute @workgroup_size(1) fn main() { output[0] = input[0] * 3u; }
`);

const first = device.createBuffer({
  size: 4,
  usage: GPUBufferUsage.STORAGE,
});
const second = device.createBuffer({
  size: 4,
  usage: GPUBufferUsage.STORAGE,
});
const output = device.createBuffer({
  size: 4,
  usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC,
});
const readback = device.createBuffer({
  size: 4,
  usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
});

const seedGroup = device.createBindGroup({
  layout: seedPipeline.getBindGroupLayout(0),
  entries: [{ binding: 0, resource: { buffer: first } }],
});
const addGroup = device.createBindGroup({
  layout: addPipeline.getBindGroupLayout(0),
  entries: [
    { binding: 0, resource: { buffer: first } },
    { binding: 1, resource: { buffer: second } },
  ],
});
const multiplyGroup = device.createBindGroup({
  layout: multiplyPipeline.getBindGroupLayout(0),
  entries: [
    { binding: 0, resource: { buffer: second } },
    { binding: 1, resource: { buffer: output } },
  ],
});

const encoder = device.createCommandEncoder();
for (const [pipeline, bindGroup] of [
  [seedPipeline, seedGroup],
  [addPipeline, addGroup],
  [multiplyPipeline, multiplyGroup],
]) {
  const pass = encoder.beginComputePass();
  pass.setPipeline(pipeline);
  pass.setBindGroup(0, bindGroup);
  pass.dispatchWorkgroups(1);
  pass.end();
}
encoder.copyBufferToBuffer(output, 0, readback, 0, 4);
device.queue.submit([encoder.finish()]);
await readback.mapAsync(GPUMapMode.READ);
const actual = new Uint32Array(readback.getMappedRange())[0];
readback.unmap();

for (const buffer of [first, second, output, readback]) buffer.destroy();
device.destroy();

if (actual !== 36) {
  throw new Error(`multi-pass compute chain produced ${actual}; expected 36`);
}
process.stdout.write('multi-pass compute chain: 3 dependent pipelines passed\n');

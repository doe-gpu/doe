#!/usr/bin/env node

import { setupGlobals } from '../../src/index.js';

setupGlobals();

const adapter = await navigator.gpu.requestAdapter();
if (!adapter) throw new Error('no adapter');
const device = await adapter.requestDevice();

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

async function runLabeledPass(forceNativeEncoder) {
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
  const encoder = device.createCommandEncoder();
  if (forceNativeEncoder) {
    const source = device.createBuffer({ size: 4, usage: GPUBufferUsage.COPY_SRC });
    const destination = device.createBuffer({ size: 4, usage: GPUBufferUsage.COPY_DST });
    encoder.copyBufferToBuffer(source, 0, destination, 0, 4);
  }
  const pass = encoder.beginComputePass({ label: 'labeled-compute-pass' });
  if (pass.label !== 'labeled-compute-pass') {
    throw new Error(`compute pass label was not preserved: ${JSON.stringify(pass.label)}`);
  }
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
  if (value !== 42) {
    throw new Error(`labeled compute pass produced ${value}; expected 42`);
  }
}

await runLabeledPass(false);
await runLabeledPass(true);
device.destroy();
process.stdout.write('labeled compute pass: 2 routes passed\n');

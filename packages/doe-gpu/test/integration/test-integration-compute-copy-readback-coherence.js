#!/usr/bin/env node

import { setupGlobals } from '../../src/index.js';

setupGlobals();

const adapter = await navigator.gpu.requestAdapter();
if (!adapter) throw new Error('no adapter');
const device = await adapter.requestDevice();

const shader = device.createShaderModule({
  code: `
    @group(0) @binding(0) var<storage, read_write> output: array<u32>;
    @compute @workgroup_size(1) fn main() {
      output[0] = 0x13579bdfu;
      output[1] = 0x2468ace0u;
    }
  `,
});
const pipeline = device.createComputePipeline({
  layout: 'auto',
  compute: { module: shader, entryPoint: 'main' },
});

async function readBuffer(source) {
  const staging = device.createBuffer({
    size: 8,
    usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
  });
  const encoder = device.createCommandEncoder();
  encoder.copyBufferToBuffer(source, 0, staging, 0, 8);
  device.queue.submit([encoder.finish()]);
  await staging.mapAsync(GPUMapMode.READ);
  const actual = Array.from(new Uint32Array(staging.getMappedRange().slice(0)));
  staging.unmap();
  staging.destroy();
  return actual;
}

async function runCase(label, separateSubmits) {
  const computeOutput = device.createBuffer({
    size: 8,
    usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC,
  });
  const copiedOutput = device.createBuffer({
    size: 8,
    usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.COPY_SRC,
  });
  const bindGroup = device.createBindGroup({
    layout: pipeline.getBindGroupLayout(0),
    entries: [{ binding: 0, resource: { buffer: computeOutput } }],
  });

  const computeEncoder = device.createCommandEncoder();
  const pass = computeEncoder.beginComputePass();
  pass.setPipeline(pipeline);
  pass.setBindGroup(0, bindGroup);
  pass.dispatchWorkgroups(1);
  pass.end();

  if (separateSubmits) {
    device.queue.submit([computeEncoder.finish()]);
    const copyEncoder = device.createCommandEncoder();
    copyEncoder.copyBufferToBuffer(computeOutput, 0, copiedOutput, 0, 8);
    device.queue.submit([copyEncoder.finish()]);
  } else {
    computeEncoder.copyBufferToBuffer(computeOutput, 0, copiedOutput, 0, 8);
    device.queue.submit([computeEncoder.finish()]);
  }

  const actual = await readBuffer(copiedOutput);
  computeOutput.destroy();
  copiedOutput.destroy();
  const expected = [0x13579bdf, 0x2468ace0];
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${label} compute-copy-readback produced ${actual}; expected ${expected}`);
  }
}

await runCase('same-submit', false);
await runCase('cross-submit', true);
device.destroy();
process.stdout.write('compute-copy-readback coherence: same-submit and cross-submit passed\n');

#!/usr/bin/env node

import { requestNativeDeviceOrSkip } from './native-device-test-helper.js';

const device = await requestNativeDeviceOrSkip('multidispatch submit coherence');

const buffers = Array.from({ length: 9 }, (_, index) => device.createBuffer({
  label: `multidispatch-chain-${index}`,
  size: 4,
  usage: GPUBufferUsage.STORAGE
    | (index === 0 ? GPUBufferUsage.COPY_DST : 0)
    | (index === 8 ? GPUBufferUsage.COPY_SRC : 0),
}));
device.queue.writeBuffer(buffers[0], 0, new Uint32Array([1]));

const encoder = device.createCommandEncoder();
for (let index = 0; index < 8; index += 1) {
  const module = device.createShaderModule({
    code: `
      @group(0) @binding(0) var<storage, read> input: array<u32>;
      @group(0) @binding(1) var<storage, read_write> output: array<u32>;
      @compute @workgroup_size(1) fn main() {
        output[0] = input[0] + ${index + 1}u;
      }
    `,
  });
  const pipeline = device.createComputePipeline({
    layout: 'auto',
    compute: { module, entryPoint: 'main' },
  });
  const bindGroup = device.createBindGroup({
    layout: pipeline.getBindGroupLayout(0),
    entries: [
      { binding: 0, resource: { buffer: buffers[index] } },
      { binding: 1, resource: { buffer: buffers[index + 1] } },
    ],
  });
  const pass = encoder.beginComputePass();
  pass.setPipeline(pipeline);
  pass.setBindGroup(0, bindGroup);
  pass.dispatchWorkgroups(1);
  pass.end();
}
device.queue.submit([encoder.finish()]);

const readback = device.createBuffer({
  size: 4,
  usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
});
const readbackEncoder = device.createCommandEncoder();
readbackEncoder.copyBufferToBuffer(buffers[8], 0, readback, 0, 4);
device.queue.submit([readbackEncoder.finish()]);
await readback.mapAsync(GPUMapMode.READ);
const actual = new Uint32Array(readback.getMappedRange())[0];
readback.unmap();

for (const buffer of buffers) buffer.destroy();
readback.destroy();
device.destroy();

if (actual !== 37) {
  throw new Error(`multi-dispatch submit produced ${actual}; expected 37`);
}
process.stdout.write('multi-dispatch submit coherence: 8 dependent pipelines passed\n');

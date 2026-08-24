#!/usr/bin/env node

import { requestNativeDeviceOrSkip } from './native-device-test-helper.js';

const device = await requestNativeDeviceOrSkip('storage texture visibility');

function makeWriter(value) {
  const module = device.createShaderModule({
    code: `
      @group(0) @binding(0) var target: texture_storage_2d<r32float, write>;
      @compute @workgroup_size(1)
      fn main() { textureStore(target, vec2<i32>(0, 0), vec4<f32>(${value}.0)); }
    `,
  });
  const bindGroupLayout = device.createBindGroupLayout({
    entries: [{
      binding: 0,
      visibility: GPUShaderStage.COMPUTE,
      storageTexture: { access: 'write-only', format: 'r32float', viewDimension: '2d' },
    }],
  });
  const pipeline = device.createComputePipeline({
    layout: device.createPipelineLayout({ bindGroupLayouts: [bindGroupLayout] }),
    compute: { module, entryPoint: 'main' },
  });
  return { pipeline, bindGroupLayout };
}

const readerModule = device.createShaderModule({
  code: `
    @group(0) @binding(0) var source: texture_2d<f32>;
    @group(0) @binding(1) var<storage, read_write> output: array<f32>;
    @compute @workgroup_size(1)
    fn main() { output[0] = textureLoad(source, vec2<i32>(0, 0), 0).x; }
  `,
});
const readerBindGroupLayout = device.createBindGroupLayout({
  entries: [
    {
      binding: 0,
      visibility: GPUShaderStage.COMPUTE,
      texture: { sampleType: 'float', viewDimension: '2d' },
    },
    {
      binding: 1,
      visibility: GPUShaderStage.COMPUTE,
      buffer: { type: 'storage' },
    },
  ],
});
const reader = device.createComputePipeline({
  layout: device.createPipelineLayout({ bindGroupLayouts: [readerBindGroupLayout] }),
  compute: { module: readerModule, entryPoint: 'main' },
});
const texture = device.createTexture({
  size: [1, 1, 1],
  format: 'r32float',
  usage: GPUTextureUsage.STORAGE_BINDING | GPUTextureUsage.TEXTURE_BINDING,
});
const output = device.createBuffer({
  size: 4,
  usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC,
});

const readerGroup = device.createBindGroup({
  layout: readerBindGroupLayout,
  entries: [
    {
      binding: 0,
      resource: texture.createView({
        dimension: '2d',
        format: 'r32float',
        usage: GPUTextureUsage.TEXTURE_BINDING,
      }),
    },
    { binding: 1, resource: { buffer: output } },
  ],
});

async function writeThenRead(value) {
  const { pipeline: writer, bindGroupLayout: writerBindGroupLayout } = makeWriter(value);
  const writerGroup = device.createBindGroup({
    layout: writerBindGroupLayout,
    entries: [{
      binding: 0,
      resource: texture.createView({
        dimension: '2d',
        format: 'r32float',
        usage: GPUTextureUsage.STORAGE_BINDING,
      }),
    }],
  });
  const readback = device.createBuffer({
    size: 4,
    usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
  });
  const encoder = device.createCommandEncoder();
  for (const [pipeline, bindGroup] of [[writer, writerGroup], [reader, readerGroup]]) {
    const pass = encoder.beginComputePass();
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, bindGroup);
    pass.dispatchWorkgroups(1);
    pass.end();
  }
  encoder.copyBufferToBuffer(output, 0, readback, 0, 4);
  device.queue.submit([encoder.finish()]);
  await readback.mapAsync(GPUMapMode.READ);
  const actual = new Float32Array(readback.getMappedRange())[0];
  readback.unmap();
  readback.destroy();
  return actual;
}

const actual = [await writeThenRead(11), await writeThenRead(29)];

output.destroy();
texture.destroy();
device.destroy();

if (actual[0] !== 11 || actual[1] !== 29) {
  throw new Error(`storage texture visibility produced [${actual.join(', ')}]; expected [11, 29]`);
}
process.stdout.write('storage texture visibility: repeated write-then-sample passed\n');

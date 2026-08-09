#!/usr/bin/env node

import { setupGlobals } from '../../src/index.js';

setupGlobals();

const COPY_BYTES_PER_ROW = 256;
const TEXTURE_SIZE = Object.freeze({
  width: 1,
  height: 1,
  depthOrArrayLayers: 1,
});

const adapter = await navigator.gpu.requestAdapter();
if (!adapter) throw new Error('no adapter');
const device = await adapter.requestDevice();

async function readTexture(texture) {
  const readback = device.createBuffer({
    size: COPY_BYTES_PER_ROW,
    usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
  });
  const encoder = device.createCommandEncoder();
  encoder.copyTextureToBuffer(
    { texture },
    {
      buffer: readback,
      bytesPerRow: COPY_BYTES_PER_ROW,
      rowsPerImage: TEXTURE_SIZE.height,
    },
    TEXTURE_SIZE,
  );
  device.queue.submit([encoder.finish()]);
  await readback.mapAsync(GPUMapMode.READ);
  const bytes = new Uint8Array(readback.getMappedRange()).slice(0, 4);
  readback.unmap();
  readback.destroy();
  return bytes;
}

function expectBytes(actual, expected, operation) {
  if (actual.length !== expected.length ||
      actual.some((value, index) => value !== expected[index])) {
    throw new Error(
      `${operation} produced [${actual.join(', ')}]; expected [${expected.join(', ')}]`,
    );
  }
}

const uploadedTexture = device.createTexture({
  size: TEXTURE_SIZE,
  format: 'rgba8unorm',
  usage: GPUTextureUsage.COPY_DST | GPUTextureUsage.COPY_SRC,
});
const uploadedBytes = new Uint8Array([17, 34, 51, 68]);
device.queue.writeTexture(
  { texture: uploadedTexture },
  uploadedBytes,
  { bytesPerRow: uploadedBytes.byteLength, rowsPerImage: 1 },
  TEXTURE_SIZE,
);
expectBytes(
  await readTexture(uploadedTexture),
  uploadedBytes,
  'writeTexture followed by copyTextureToBuffer',
);

const copiedTexture = device.createTexture({
  size: TEXTURE_SIZE,
  format: 'rgba8unorm',
  usage: GPUTextureUsage.COPY_DST | GPUTextureUsage.COPY_SRC,
});
const textureCopyEncoder = device.createCommandEncoder();
textureCopyEncoder.copyTextureToTexture(
  { texture: uploadedTexture },
  { texture: copiedTexture },
  TEXTURE_SIZE,
);
device.queue.submit([textureCopyEncoder.finish()]);
expectBytes(
  await readTexture(copiedTexture),
  uploadedBytes,
  'copyTextureToTexture followed by copyTextureToBuffer',
);
uploadedTexture.destroy();
copiedTexture.destroy();

const storageTexture = device.createTexture({
  size: TEXTURE_SIZE,
  format: 'rgba8unorm',
  usage: GPUTextureUsage.STORAGE_BINDING | GPUTextureUsage.COPY_SRC,
});
const shader = device.createShaderModule({
  code: `
    @group(0) @binding(0)
    var output: texture_storage_2d<rgba8unorm, write>;

    @compute @workgroup_size(1)
    fn main() {
      textureStore(output, vec2i(0, 0), vec4f(0.25, 0.5, 0.75, 1.0));
    }
  `,
});
const bindGroupLayout = device.createBindGroupLayout({
  entries: [{
    binding: 0,
    visibility: GPUShaderStage.COMPUTE,
    storageTexture: {
      access: 'write-only',
      format: 'rgba8unorm',
      viewDimension: '2d',
    },
  }],
});
const pipeline = device.createComputePipeline({
  layout: device.createPipelineLayout({ bindGroupLayouts: [bindGroupLayout] }),
  compute: { module: shader, entryPoint: 'main' },
});
for (let iteration = 0; iteration < 3; iteration += 1) {
  const bindGroup = device.createBindGroup({
    layout: bindGroupLayout,
    entries: [{ binding: 0, resource: storageTexture.createView() }],
  });
  const readback = device.createBuffer({
    size: COPY_BYTES_PER_ROW,
    usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
  });
  const encoder = device.createCommandEncoder();
  const pass = encoder.beginComputePass();
  pass.setPipeline(pipeline);
  pass.setBindGroup(0, bindGroup);
  pass.dispatchWorkgroups(1);
  pass.end();
  encoder.copyTextureToBuffer(
    { texture: storageTexture },
    {
      buffer: readback,
      bytesPerRow: COPY_BYTES_PER_ROW,
      rowsPerImage: TEXTURE_SIZE.height,
    },
    TEXTURE_SIZE,
  );
  device.queue.submit([encoder.finish()]);
  await readback.mapAsync(GPUMapMode.READ);
  const actual = new Uint8Array(readback.getMappedRange()).slice(0, 4);
  readback.unmap();
  readback.destroy();
  expectBytes(
    actual,
    new Uint8Array([64, 128, 191, 255]),
    `storage texture dispatch/readback iteration ${iteration}`,
  );
}
storageTexture.destroy();

device.destroy();
process.stdout.write('native texture commands: upload, copy, and storage dispatch passed\n');

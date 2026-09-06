import { Buffer } from 'node:buffer';
import { createHash } from 'node:crypto';

import {
  runGovernedNodeWebGPU,
  validateGovernedNodeWebGPUReceipt,
} from 'doe-gpu/node-webgpu';

const runtimeHost = process.env.DOE_NATIVE_RELEASE_CANDIDATE_RUNTIME;
if (!['node', 'bun', 'electron'].includes(runtimeHost)) {
  throw new Error('DOE_NATIVE_RELEASE_CANDIDATE_RUNTIME must be node, bun, or electron');
}

const code = `
@group(0) @binding(0) var<storage, read> input: array<f32>;
@group(0) @binding(1) var<storage, read_write> output: array<f32>;

@compute @workgroup_size(8)
fn main(@builtin(global_invocation_id) id: vec3u) {
  if (id.x < 8u) {
    output[id.x] = input[id.x] * 2.0;
  }
}
`;
const input = new Float32Array([1, 2, 3, 4, 5, 6, 7, 8]);
const expected = Float32Array.from(input, (value) => value * 2);

function byteView(value) {
  if (typeof value === 'string') return Buffer.from(value, 'utf8');
  return Buffer.from(value.buffer, value.byteOffset, value.byteLength);
}

function sha256(value) {
  return `sha256:${createHash('sha256').update(byteView(value)).digest('hex')}`;
}

async function execute({ adapter, input: inputBytes }) {
  const device = await adapter.requestDevice();
  const inputBuffer = device.createBuffer({
    size: inputBytes.byteLength,
    usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
  });
  const outputBuffer = device.createBuffer({
    size: inputBytes.byteLength,
    usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC,
  });
  const readbackBuffer = device.createBuffer({
    size: inputBytes.byteLength,
    usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
  });
  try {
    device.queue.writeBuffer(inputBuffer, 0, inputBytes);
    const shader = device.createShaderModule({ code });
    const pipeline = device.createComputePipeline({
      layout: 'auto',
      compute: { module: shader, entryPoint: 'main' },
    });
    const bindGroup = device.createBindGroup({
      layout: pipeline.getBindGroupLayout(0),
      entries: [
        { binding: 0, resource: { buffer: inputBuffer } },
        { binding: 1, resource: { buffer: outputBuffer } },
      ],
    });
    const encoder = device.createCommandEncoder();
    const pass = encoder.beginComputePass();
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, bindGroup);
    pass.dispatchWorkgroups(1);
    pass.end();
    encoder.copyBufferToBuffer(
      outputBuffer,
      0,
      readbackBuffer,
      0,
      inputBytes.byteLength,
    );
    device.queue.submit([encoder.finish()]);
    await readbackBuffer.mapAsync(GPUMapMode.READ);
    return new Uint8Array(readbackBuffer.getMappedRange()).slice();
  } finally {
    if (readbackBuffer.mapState === 'mapped') readbackBuffer.unmap();
    inputBuffer.destroy();
    outputBuffer.destroy();
    readbackBuffer.destroy();
    device.destroy();
  }
}

const result = await runGovernedNodeWebGPU({
  provider: {
    providers: [{
      id: 'doe-native-0.5.0',
      kind: 'module',
      module: 'doe-gpu',
      gpu: { kind: 'factory', path: 'create', args: [[]] },
      globals: {
        GPUBufferUsage: 'globals.GPUBufferUsage',
        GPUShaderStage: 'globals.GPUShaderStage',
        GPUMapMode: 'globals.GPUMapMode',
        GPUTextureUsage: 'globals.GPUTextureUsage',
      },
    }],
    adapterOptions: null,
    globals: { mode: 'replace' },
  },
  workload: {
    id: 'doe-gpu-release-vector-scale',
    version: '0.5.0',
    implementationSha256: sha256(code),
    input,
    expectedOutputSha256: sha256(expected),
  },
  execute,
});
const validation = result.receipt
  ? validateGovernedNodeWebGPUReceipt(result.receipt)
  : { valid: false, errors: ['governed execution did not emit a receipt'] };
const output = result.output
  ? Array.from(new Float32Array(
      result.output.buffer,
      result.output.byteOffset,
      result.output.byteLength / Float32Array.BYTES_PER_ELEMENT,
    ))
  : null;

process.stdout.write(`${JSON.stringify({
  schemaVersion: 1,
  artifactKind: 'doe-gpu-native-release-candidate-run',
  runtimeHost,
  ok: result.ok,
  output,
  receipt: result.receipt,
  validation,
  errors: result.errors,
}, null, 2)}\n`);

if (runtimeHost === 'electron') {
  const { app } = await import('electron');
  app.exit(result.ok && validation.valid ? 0 : 1);
} else {
  process.exitCode = result.ok && validation.valid ? 0 : 1;
}

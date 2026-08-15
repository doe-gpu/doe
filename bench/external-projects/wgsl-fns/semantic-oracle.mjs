#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

import * as webgpu from 'webgpu';

const functionName = 'smoothStep';
const workgroupSize = 4;
const inputs = new Float32Array([
  -0.25,
  0,
  0.125,
  0.25,
  0.5,
  0.75,
  1,
  1.25,
]);
const expected = new Float32Array([
  0,
  0,
  0.04296875,
  0.15625,
  0.5,
  0.84375,
  1,
  1,
]);

function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

function sha256Bytes(value) {
  return sha256(Buffer.from(value.buffer, value.byteOffset, value.byteLength));
}

const providerId = process.env.DOE_EXTERNAL_WEBGPU_PROVIDER;
const providerModulePath = process.env.DOE_EXTERNAL_WEBGPU_MODULE_PATH;
if (!providerId || !providerModulePath) {
  throw new Error('semantic oracle requires provider and module-path identity');
}
const providerIdentity = webgpu.__doeHarnessProviderIdentity ?? {
  id: providerId,
  modulePath: providerModulePath,
};
if (providerIdentity.id !== providerId || providerIdentity.modulePath !== providerModulePath) {
  throw new Error('semantic oracle provider identity does not match the requested lane');
}
const { create, globals } = webgpu;
if (typeof create !== 'function' || !globals) {
  throw new Error('semantic oracle provider does not expose create() and globals');
}

const upstreamModulePath = resolve(process.cwd(), 'dist/wgsl-fns.esm.js');
const { getFns } = await import(pathToFileURL(upstreamModulePath).href);
const functionSource = getFns([functionName]);
const shaderSource = `${functionSource}

struct Values {
  data: array<f32>,
}

@group(0) @binding(0) var<storage, read> input_values: Values;
@group(0) @binding(1) var<storage, read_write> output_values: Values;

@compute @workgroup_size(${workgroupSize})
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
  let index = global_id.x;
  if (index < ${inputs.length}u) {
    output_values.data[index] = smoothStep(0.0, 1.0, input_values.data[index]);
  }
}
`;

const gpu = create([]);
const adapter = await gpu.requestAdapter();
if (!adapter) throw new Error('semantic oracle received no WebGPU adapter');
const device = await adapter.requestDevice();
const { GPUBufferUsage, GPUMapMode } = globals;
const byteLength = inputs.byteLength;
const resources = [];

try {
  const shaderModule = device.createShaderModule({
    label: 'wgsl-fns smoothStep semantic oracle',
    code: shaderSource,
  });
  const compilationInfo = await shaderModule.getCompilationInfo();
  const compilationErrors = compilationInfo.messages
    .filter((message) => message.type === 'error')
    .map((message) => ({
      lineNum: message.lineNum,
      linePos: message.linePos,
      message: message.message,
    }));
  if (compilationErrors.length > 0) {
    throw new Error(`semantic shader compilation failed: ${JSON.stringify(compilationErrors)}`);
  }

  const inputBuffer = device.createBuffer({
    label: 'wgsl-fns semantic input',
    size: byteLength,
    usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
  });
  const outputBuffer = device.createBuffer({
    label: 'wgsl-fns semantic output',
    size: byteLength,
    usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC,
  });
  const readbackBuffer = device.createBuffer({
    label: 'wgsl-fns semantic readback',
    size: byteLength,
    usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
  });
  resources.push(inputBuffer, outputBuffer, readbackBuffer);
  device.queue.writeBuffer(inputBuffer, 0, inputs);

  const pipeline = device.createComputePipeline({
    label: 'wgsl-fns smoothStep semantic pipeline',
    layout: 'auto',
    compute: { module: shaderModule, entryPoint: 'main' },
  });
  const bindGroup = device.createBindGroup({
    label: 'wgsl-fns smoothStep semantic bind group',
    layout: pipeline.getBindGroupLayout(0),
    entries: [
      { binding: 0, resource: { buffer: inputBuffer } },
      { binding: 1, resource: { buffer: outputBuffer } },
    ],
  });
  const encoder = device.createCommandEncoder({ label: 'wgsl-fns semantic encoder' });
  const pass = encoder.beginComputePass({ label: 'wgsl-fns semantic pass' });
  pass.setPipeline(pipeline);
  pass.setBindGroup(0, bindGroup);
  pass.dispatchWorkgroups(Math.ceil(inputs.length / workgroupSize), 1, 1);
  pass.end();
  encoder.copyBufferToBuffer(outputBuffer, 0, readbackBuffer, 0, byteLength);
  device.queue.submit([encoder.finish()]);
  await device.queue.onSubmittedWorkDone();
  await readbackBuffer.mapAsync(GPUMapMode.READ, 0, byteLength);
  const outputBytes = new Uint8Array(readbackBuffer.getMappedRange(0, byteLength)).slice();
  const actual = new Float32Array(
    outputBytes.buffer,
    outputBytes.byteOffset,
    outputBytes.byteLength / Float32Array.BYTES_PER_ELEMENT,
  );
  readbackBuffer.unmap();

  const mismatches = [];
  for (let index = 0; index < expected.length; index += 1) {
    if (actual[index] !== expected[index]) {
      mismatches.push({ index, input: inputs[index], expected: expected[index], actual: actual[index] });
    }
  }
  if (mismatches.length > 0) {
    throw new Error(`semantic oracle mismatch: ${JSON.stringify(mismatches)}`);
  }

  const result = {
    schemaVersion: 1,
    artifactKind: 'wgsl-fns-semantic-oracle-result',
    provider: providerIdentity,
    adapter: adapter.info ?? null,
    function: {
      name: functionName,
      sourceSha256: sha256(functionSource),
    },
    shader: {
      sha256: sha256(shaderSource),
      entryPoint: 'main',
    },
    dispatch: {
      workgroups: [Math.ceil(inputs.length / workgroupSize), 1, 1],
      workgroupSize: [workgroupSize, 1, 1],
      invocationCount: inputs.length,
    },
    synchronization: 'queue.submit, queue.onSubmittedWorkDone, copyBufferToBuffer, mapAsync(READ)',
    readback: 'eight exact f32 values copied into a MAP_READ staging buffer',
    oracle: {
      kind: 'independent-cpu-exact',
      passed: true,
      inputSha256: sha256Bytes(inputs),
      expectedSha256: sha256Bytes(expected),
      actualSha256: sha256Bytes(actual),
      values: [...actual],
      tolerance: 0,
    },
  };
  process.stdout.write(`DOE_WGSL_FNS_SEMANTIC_ORACLE=${JSON.stringify(result)}\n`);
} finally {
  for (const resource of resources.reverse()) resource.destroy();
  device.destroy();
}

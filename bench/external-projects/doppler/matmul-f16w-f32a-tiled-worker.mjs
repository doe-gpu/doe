#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

import { openNodeWebGPU } from '../../../packages/doe-gpu/src/node-webgpu.js';

const scriptPath = fileURLToPath(import.meta.url);
const repoRoot = resolve(dirname(scriptPath), '../../..');
const dopplerRoot = resolve(
  repoRoot,
  '../doppler/.worktrees/doe-provider-compare-e6e8be4a',
);
const shaderPath = resolve(dopplerRoot, 'src/gpu/kernels/matmul_f16w_f32a_tiled.wgsl');
const doeProviderPath = resolve(repoRoot, 'packages/doe-gpu/src/compute.js');
const boundedProviderPath = resolve(
  repoRoot,
  'bench/executors/vendor-node/doppler-node-webgpu-lifecycle-provider.mjs',
);
const incumbentProviderPath = resolve(dopplerRoot, 'node_modules/webgpu/index.js');

const CASES = Object.freeze([
  Object.freeze({ id: 'edge', M: 5, N: 7, K: 33 }),
  Object.freeze({ id: 'production-qkv', M: 72, N: 1536, K: 640 }),
]);

const PROVIDER_GLOBALS = Object.freeze({
  GPUBufferUsage: 'globals.GPUBufferUsage',
  GPUShaderStage: 'globals.GPUShaderStage',
  GPUMapMode: 'globals.GPUMapMode',
  GPUTextureUsage: 'globals.GPUTextureUsage',
});

function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

function parseArgs(argv) {
  const options = { provider: null, output: null };
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === '--provider') options.provider = argv[++index];
    else if (argv[index] === '--output') options.output = resolve(argv[++index]);
    else throw new Error(`unknown argument: ${argv[index]}`);
  }
  if (!['P0', 'D0'].includes(options.provider)) {
    throw new Error('--provider must be P0 or D0');
  }
  if (!options.output) throw new Error('--output is required');
  return options;
}

function float32ToFloat16Bits(value) {
  const scratch = new ArrayBuffer(4);
  const f32 = new Float32Array(scratch);
  const u32 = new Uint32Array(scratch);
  f32[0] = value;
  const bits = u32[0];
  const sign = (bits >>> 16) & 0x8000;
  const exponent = (bits >>> 23) & 0xff;
  const mantissa = bits & 0x7fffff;
  if (exponent === 0xff) {
    return sign | (mantissa === 0 ? 0x7c00 : 0x7e00);
  }
  const halfExponent = exponent - 127 + 15;
  if (halfExponent >= 0x1f) return sign | 0x7c00;
  if (halfExponent <= 0) {
    if (halfExponent < -10) return sign;
    const normalized = mantissa | 0x800000;
    const shift = 14 - halfExponent;
    let halfMantissa = normalized >>> shift;
    const remainder = normalized & ((1 << shift) - 1);
    const halfway = 1 << (shift - 1);
    if (remainder > halfway || (remainder === halfway && (halfMantissa & 1) !== 0)) {
      halfMantissa += 1;
    }
    return sign | halfMantissa;
  }
  let roundedMantissa = mantissa >>> 13;
  const remainder = mantissa & 0x1fff;
  if (remainder > 0x1000 || (remainder === 0x1000 && (roundedMantissa & 1) !== 0)) {
    roundedMantissa += 1;
    if (roundedMantissa === 0x400) {
      const promotedExponent = halfExponent + 1;
      return promotedExponent >= 0x1f ? sign | 0x7c00 : sign | (promotedExponent << 10);
    }
  }
  return sign | (halfExponent << 10) | roundedMantissa;
}

function float16BitsToFloat32(bits) {
  const sign = (bits & 0x8000) === 0 ? 1 : -1;
  const exponent = (bits >>> 10) & 0x1f;
  const mantissa = bits & 0x3ff;
  if (exponent === 0) {
    return mantissa === 0 ? sign * 0 : sign * 2 ** -14 * (mantissa / 1024);
  }
  if (exponent === 0x1f) return mantissa === 0 ? sign * Infinity : NaN;
  return sign * 2 ** (exponent - 15) * (1 + mantissa / 1024);
}

function makeInputs(shape) {
  const a = new Float32Array(shape.M * shape.K);
  const b = new Uint16Array(shape.N * shape.K);
  for (let index = 0; index < a.length; index += 1) {
    a[index] = ((index * 17 + 11) % 29 - 14) / 16;
  }
  for (let index = 0; index < b.length; index += 1) {
    const value = ((index * 13 + 7) % 23 - 11) / 16;
    b[index] = float32ToFloat16Bits(value);
  }
  const uniformBytes = new Uint8Array(32);
  const uniformView = new DataView(uniformBytes.buffer);
  uniformView.setUint32(0, shape.M, true);
  uniformView.setUint32(4, shape.N, true);
  uniformView.setUint32(8, shape.K, true);
  uniformView.setFloat32(12, 1, true);
  uniformView.setUint32(16, 1, true);
  return { a, b, uniformBytes };
}

function referenceAt(shape, inputs, row, column) {
  let total = 0;
  for (let k = 0; k < shape.K; k += 1) {
    total += inputs.a[row * shape.K + k]
      * float16BitsToFloat32(inputs.b[column * shape.K + k]);
  }
  return Math.fround(total);
}

function sampleCoordinates(shape) {
  const candidates = [
    [0, 0],
    [0, shape.N - 1],
    [shape.M - 1, 0],
    [shape.M - 1, shape.N - 1],
    [Math.floor(shape.M / 2), Math.floor(shape.N / 2)],
    [Math.min(1, shape.M - 1), Math.min(1, shape.N - 1)],
    [Math.min(4, shape.M - 1), Math.min(6, shape.N - 1)],
    [Math.min(63, shape.M - 1), Math.min(63, shape.N - 1)],
    [Math.min(64, shape.M - 1), Math.min(64, shape.N - 1)],
  ];
  return [...new Map(candidates.map(([row, column]) => [`${row}:${column}`, [row, column]])).values()];
}

function summarizeOutput(shape, inputs, output) {
  let zeroCount = 0;
  let nonFiniteCount = 0;
  let maxAbs = 0;
  for (const value of output) {
    if (value === 0) zeroCount += 1;
    if (!Number.isFinite(value)) nonFiniteCount += 1;
    maxAbs = Math.max(maxAbs, Math.abs(value));
  }
  const samples = sampleCoordinates(shape).map(([row, column]) => {
    const actual = output[row * shape.N + column];
    const expected = referenceAt(shape, inputs, row, column);
    const absoluteError = Math.abs(actual - expected);
    return { row, column, actual, expected, absoluteError };
  });
  return {
    outputSha256: sha256(Buffer.from(output.buffer, output.byteOffset, output.byteLength)),
    elementCount: output.length,
    zeroCount,
    nonFiniteCount,
    maxAbs,
    maxSampleAbsoluteError: Math.max(...samples.map((sample) => sample.absoluteError)),
    samples,
  };
}

function paddedBytes(view) {
  const bytes = new Uint8Array(view.buffer, view.byteOffset, view.byteLength);
  if (bytes.byteLength % 4 === 0) return bytes;
  const padded = new Uint8Array(Math.ceil(bytes.byteLength / 4) * 4);
  padded.set(bytes);
  return padded;
}

async function compilationMessages(module) {
  if (typeof module.getCompilationInfo !== 'function') return [];
  const info = await module.getCompilationInfo();
  return (info.messages ?? []).map((message) => ({
    type: message.type,
    message: message.message,
    lineNum: message.lineNum,
    linePos: message.linePos,
  }));
}

async function runCase(device, globals, shaderCode, shape) {
  const inputs = makeInputs(shape);
  const shader = device.createShaderModule({ code: shaderCode });
  const messages = await compilationMessages(shader);
  if (messages.some((message) => message.type === 'error')) {
    throw new Error(`shader compilation failed: ${JSON.stringify(messages)}`);
  }
  const pipeline = device.createComputePipeline({
    layout: 'auto',
    compute: { module: shader, entryPoint: 'main' },
  });
  const aBytes = paddedBytes(inputs.a);
  const bBytes = paddedBytes(inputs.b);
  const outputBytes = shape.M * shape.N * Float32Array.BYTES_PER_ELEMENT;
  const uniform = device.createBuffer({
    size: inputs.uniformBytes.byteLength,
    usage: globals.GPUBufferUsage.UNIFORM | globals.GPUBufferUsage.COPY_DST,
  });
  const a = device.createBuffer({
    size: aBytes.byteLength,
    usage: globals.GPUBufferUsage.STORAGE | globals.GPUBufferUsage.COPY_DST,
  });
  const b = device.createBuffer({
    size: bBytes.byteLength,
    usage: globals.GPUBufferUsage.STORAGE | globals.GPUBufferUsage.COPY_DST,
  });
  const c = device.createBuffer({
    size: outputBytes,
    usage: globals.GPUBufferUsage.STORAGE | globals.GPUBufferUsage.COPY_SRC,
  });
  const readback = device.createBuffer({
    size: outputBytes,
    usage: globals.GPUBufferUsage.COPY_DST | globals.GPUBufferUsage.MAP_READ,
  });
  device.queue.writeBuffer(uniform, 0, inputs.uniformBytes);
  device.queue.writeBuffer(a, 0, aBytes);
  device.queue.writeBuffer(b, 0, bBytes);
  const bindGroup = device.createBindGroup({
    layout: pipeline.getBindGroupLayout(0),
    entries: [
      { binding: 0, resource: { buffer: uniform } },
      { binding: 1, resource: { buffer: a } },
      { binding: 2, resource: { buffer: b } },
      { binding: 3, resource: { buffer: c } },
    ],
  });
  const encoder = device.createCommandEncoder();
  const pass = encoder.beginComputePass();
  pass.setPipeline(pipeline);
  pass.setBindGroup(0, bindGroup);
  pass.dispatchWorkgroups(Math.ceil(shape.M / 64), Math.ceil(shape.N / 64), 1);
  pass.end();
  encoder.copyBufferToBuffer(c, 0, readback, 0, outputBytes);
  device.queue.submit([encoder.finish()]);
  await readback.mapAsync(globals.GPUMapMode.READ);
  const output = new Float32Array(readback.getMappedRange().slice(0));
  readback.unmap();
  for (const buffer of [uniform, a, b, c, readback]) buffer.destroy();
  return {
    id: shape.id,
    shape: { M: shape.M, N: shape.N, K: shape.K },
    dispatch: {
      x: Math.ceil(shape.M / 64),
      y: Math.ceil(shape.N / 64),
      z: 1,
    },
    inputs: {
      aSha256: sha256(aBytes),
      bSha256: sha256(bBytes),
      uniformsSha256: sha256(inputs.uniformBytes),
    },
    compilationMessages: messages,
    output: summarizeOutput(shape, inputs, output),
  };
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const shaderBytes = await readFile(shaderPath);
  const providerPath = options.provider === 'P0' ? boundedProviderPath : doeProviderPath;
  if (options.provider === 'P0') {
    process.env.DOE_DOPPLER_INCUMBENT_MODULE = pathToFileURL(incumbentProviderPath).href;
  }
  const session = await openNodeWebGPU({
    providers: [{
      id: options.provider,
      kind: 'module',
      module: pathToFileURL(providerPath).href,
      gpu: {
        kind: 'factory',
        path: 'create',
        args: [['enable-dawn-features=allow_unsafe_apis']],
      },
      globals: PROVIDER_GLOBALS,
    }],
    adapterOptions: null,
    globals: { mode: 'replace' },
  });
  let device = null;
  try {
    device = await session.adapter.requestDevice({
      requiredFeatures: ['shader-f16'],
    });
    const cases = [];
    for (const shape of CASES) {
      cases.push(await runCase(device, session.module.globals, shaderBytes.toString('utf8'), shape));
    }
    if (typeof device.queue.onSubmittedWorkDone === 'function') {
      await device.queue.onSubmittedWorkDone();
    }
    const lifecycle = typeof session.module.releaseTrackedDevices === 'function'
      ? await session.module.releaseTrackedDevices()
      : { supported: false };
    if (lifecycle.supported !== true && typeof device.destroy === 'function') device.destroy();
    device = null;
    const result = {
      schema: 'doe.doppler-matmul-f16w-f32a-tiled-lane/v1',
      provider: options.provider,
      shader: { path: shaderPath, sha256: sha256(shaderBytes), bytes: shaderBytes.byteLength },
      providerModule: { path: providerPath, sha256: sha256(await readFile(providerPath)) },
      incumbentModule: options.provider === 'P0'
        ? { path: incumbentProviderPath, sha256: sha256(await readFile(incumbentProviderPath)) }
        : null,
      providerReceipt: session.receipt,
      lifecycle,
      cases,
    };
    await writeFile(options.output, `${JSON.stringify(result, null, 2)}\n`);
  } finally {
    if (device && typeof device.destroy === 'function') device.destroy();
    await session.close();
  }
}

main().catch(async (error) => {
  const message = error instanceof Error ? error.stack ?? error.message : String(error);
  process.stderr.write(`${message}\n`);
  process.exitCode = 1;
});

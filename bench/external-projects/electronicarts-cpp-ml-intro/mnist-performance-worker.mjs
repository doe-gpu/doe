#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { create, globals, __doeProofProviderIdentity } from 'webgpu';

const upstreamRoot = process.env.DOE_CPP_ML_UPSTREAM;
if (!upstreamRoot) throw new Error('DOE_CPP_ML_UPSTREAM is required.');
const mode = process.env.DOE_CPP_ML_PERFORMANCE_MODE ?? 'cold';
if (!['cold', 'warm'].includes(mode)) {
  throw new Error('DOE_CPP_ML_PERFORMANCE_MODE must be cold or warm.');
}
const warmupCount = Number(process.env.DOE_CPP_ML_WARMUP_SUITES ?? (mode === 'warm' ? 5 : 0));
const sampleCount = Number(process.env.DOE_CPP_ML_SAMPLE_SUITES ?? (mode === 'warm' ? 100 : 1));
if (!Number.isInteger(warmupCount) || warmupCount < 0) {
  throw new Error('DOE_CPP_ML_WARMUP_SUITES must be a non-negative integer.');
}
if (!Number.isInteger(sampleCount) || sampleCount < 1) {
  throw new Error('DOE_CPP_ML_SAMPLE_SUITES must be a positive integer.');
}

const webgpuRoot = resolve(upstreamRoot, 'Demo/mnist/Gigi/out/WebGPU');
Object.assign(globalThis, globals);
const Shared = await import(pathToFileURL(resolve(webgpuRoot, 'Shared.js')).href);
const { default: mnist } = await import(
  pathToFileURL(resolve(webgpuRoot, 'mnist_Module.js')).href
);

function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

function sigmoid(value) {
  return 1 / (1 + Math.exp(-value));
}

function srgbByteToLinear(value) {
  const normalized = value / 255;
  return normalized <= 0.04045
    ? normalized / 12.92
    : ((normalized + 0.055) / 1.055) ** 2.4;
}

function cpuInference(input, weights) {
  const hidden = new Float32Array(30);
  for (let hiddenIndex = 0; hiddenIndex < hidden.length; hiddenIndex += 1) {
    const base = hiddenIndex * 785;
    let sum = Math.fround(weights[base + 784]);
    for (let inputIndex = 0; inputIndex < input.length; inputIndex += 1) {
      sum = Math.fround(sum + Math.fround(input[inputIndex] * weights[base + inputIndex]));
    }
    hidden[hiddenIndex] = Math.fround(sigmoid(sum));
  }
  const output = new Float32Array(10);
  for (let outputIndex = 0; outputIndex < output.length; outputIndex += 1) {
    const base = 23_550 + outputIndex * 31;
    let sum = Math.fround(weights[base + 30]);
    for (let hiddenIndex = 0; hiddenIndex < hidden.length; hiddenIndex += 1) {
      sum = Math.fround(sum + Math.fround(hidden[hiddenIndex] * weights[base + hiddenIndex]));
    }
    output[outputIndex] = Math.fround(sigmoid(sum));
  }
  return { hidden: [...hidden], output: [...output] };
}

function maxAbsError(actual, expected) {
  return Math.max(...actual.map((value, index) => Math.abs(value - expected[index])));
}

function argmax(values) {
  let index = 0;
  for (let cursor = 1; cursor < values.length; cursor += 1) {
    if (values[cursor] > values[index]) index = cursor;
  }
  return index;
}

async function readFloats(buffer, count) {
  let values = null;
  await Shared.ReadbackBuffer(buffer, (view) => {
    values = Array.from(
      { length: count },
      (_, index) => view.getFloat32(index * Float32Array.BYTES_PER_ELEMENT, true),
    );
  });
  buffer.destroy();
  return values;
}

async function readInput(buffer) {
  let values = null;
  await Shared.ReadbackBuffer(buffer, (view) => {
    values = Array.from({ length: 28 * 28 }, (_, index) => {
      const x = index % 28;
      const y = Math.floor(index / 28);
      return view.getFloat32(y * 256 + x * Float32Array.BYTES_PER_ELEMENT, true);
    });
  });
  buffer.destroy();
  return values;
}

const gpu = create(['enable-dawn-features=use_dxc']);
const adapter = await gpu.requestAdapter();
if (!adapter) throw new Error('provider returned no adapter');
if (adapter.info?.isFallbackAdapter === true) throw new Error('software fallback adapter is prohibited');
const device = await adapter.requestDevice({ requiredFeatures: ['float32-filterable'] });
device.pushErrorScope('validation');

const weightsBuffer = await readFile(resolve(webgpuRoot, 'assets/Backprop_Weights.bin'));
const weights = new Float32Array(
  weightsBuffer.buffer,
  weightsBuffer.byteOffset,
  weightsBuffer.byteLength / Float32Array.BYTES_PER_ELEMENT,
);
if (weights.length !== 23_860) throw new Error(`unexpected weight count ${weights.length}`);
mnist.buffer_NN_Weights = device.createBuffer({
  label: 'Backprop_Weights.bin',
  size: weightsBuffer.byteLength,
  usage: mnist.buffer_NN_Weights_usageFlags,
});
mnist.buffer_NN_Weights_count = weights.length;
mnist.buffer_NN_Weights_stride = Float32Array.BYTES_PER_ELEMENT;
device.queue.writeBuffer(mnist.buffer_NN_Weights, 0, weightsBuffer);
mnist.buffer_Hidden_Layer_Activations_usageFlags |= GPUBufferUsage.COPY_SRC;
mnist.buffer_Output_Layer_Activations_usageFlags |= GPUBufferUsage.COPY_SRC;
mnist.texture_NN_Input_usageFlags |= GPUTextureUsage.COPY_SRC;
mnist.variable_UseImportedImage = true;
mnist.variableChanged_UseImportedImage = true;

const idealInputs = [];
for (let digit = 0; digit < 10; digit += 1) {
  const png = Shared.LoadPNG_Node(resolve(webgpuRoot, `assets/${digit}.png`));
  idealInputs.push(Array.from(
    { length: 28 * 28 },
    (_, index) => Math.fround(srgbByteToLinear(png.data[index * 4])),
  ));
}

async function runSuite() {
  const startedAt = performance.now();
  const cases = [];
  for (let expectedDigit = 0; expectedDigit < 10; expectedDigit += 1) {
    const imagePath = resolve(webgpuRoot, `assets/${expectedDigit}.png`);
    const loaded = await Shared.CreateTextureWithPNG(
      device,
      imagePath,
      mnist.texture_Imported_Image_usageFlags,
    );
    if (!loaded) throw new Error(`could not load ${imagePath}`);
    mnist.texture_Imported_Image = loaded.texture;
    mnist.texture_Imported_Image_size = loaded.size;
    mnist.texture_Imported_Image_format = loaded.format;

    const encoder = device.createCommandEncoder();
    if (!await mnist.Execute(device, encoder, true)) {
      throw new Error(`generated workload rejected digit ${expectedDigit}`);
    }
    const outputReadback = Shared.GetReadbackBuffer_FromBuffer(
      device,
      encoder,
      mnist.buffer_Output_Layer_Activations,
    );
    const hiddenReadback = Shared.GetReadbackBuffer_FromBuffer(
      device,
      encoder,
      mnist.buffer_Hidden_Layer_Activations,
    );
    const inputReadback = Shared.GetReadbackBuffer_FromTexture(
      device,
      encoder,
      mnist.texture_NN_Input,
    );
    device.queue.submit([encoder.finish()]);
    await device.queue.onSubmittedWorkDone();

    const gpuOutput = await readFloats(outputReadback, 10);
    const gpuHidden = await readFloats(hiddenReadback, 30);
    const gpuInput = await readInput(inputReadback);
    const cpu = cpuInference(gpuInput, weights);
    const inputMaxAbsError = maxAbsError(gpuInput, idealInputs[expectedDigit]);
    const hiddenMaxAbsError = maxAbsError(gpuHidden, cpu.hidden);
    const outputMaxAbsError = maxAbsError(gpuOutput, cpu.output);
    const gpuDigit = argmax(gpuOutput);
    const cpuDigit = argmax(cpu.output);
    if (gpuDigit !== cpuDigit
        || inputMaxAbsError > 0.5 / 255
        || hiddenMaxAbsError > 1e-5
        || outputMaxAbsError > 1e-5
        || !gpuOutput.every(Number.isFinite)
        || !cpu.output.every(Number.isFinite)) {
      throw new Error(`oracle failed for digit ${expectedDigit}`);
    }
    cases.push({
      expectedDigit,
      gpuDigit,
      cpuDigit,
      inputMaxAbsError,
      hiddenMaxAbsError,
      outputMaxAbsError,
      gpuOutput,
      cpuOutput: cpu.output,
    });
    loaded.texture.destroy();
  }
  return {
    durationMs: Number((performance.now() - startedAt).toFixed(6)),
    outputSha256: sha256(JSON.stringify(cases)),
    cases,
  };
}

const warmups = [];
for (let index = 0; index < warmupCount; index += 1) warmups.push(await runSuite());
const samples = [];
for (let index = 0; index < sampleCount; index += 1) samples.push(await runSuite());
const validationError = await device.popErrorScope();
device.destroy();
if (validationError) throw new Error(`validation error: ${validationError.message}`);

const outputIdentities = new Set([...warmups, ...samples].map((sample) => sample.outputSha256));
if (outputIdentities.size !== 1) throw new Error('semantic output changed within one worker');
process.stdout.write(`${JSON.stringify({
  schemaVersion: 1,
  artifactKind: 'cpp-ml-mnist-performance-worker-result',
  status: 'passed',
  mode,
  provider: __doeProofProviderIdentity,
  adapter: adapter.info ?? null,
  warmupCount,
  sampleCount,
  outputSha256: samples[0].outputSha256,
  warmups: warmups.map(({ durationMs, outputSha256 }) => ({ durationMs, outputSha256 })),
  samples: samples.map(({ durationMs, outputSha256 }) => ({ durationMs, outputSha256 })),
})}\n`);

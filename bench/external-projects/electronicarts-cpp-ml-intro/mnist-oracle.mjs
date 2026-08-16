#!/usr/bin/env node

import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { create, globals, __doeProofProviderIdentity } from 'webgpu';

const upstreamRoot = process.env.DOE_CPP_ML_UPSTREAM;
if (!upstreamRoot) throw new Error('DOE_CPP_ML_UPSTREAM is required.');
const webgpuRoot = resolve(upstreamRoot, 'Demo/mnist/Gigi/out/WebGPU');
Object.assign(globalThis, globals);

const Shared = await import(pathToFileURL(resolve(webgpuRoot, 'Shared.js')).href);
const { default: mnist } = await import(
  pathToFileURL(resolve(webgpuRoot, 'mnist_Module.js')).href
);

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
  for (let hiddenIndex = 0; hiddenIndex < 30; hiddenIndex += 1) {
    const base = hiddenIndex * 785;
    let sum = Math.fround(weights[base + 784]);
    for (let inputIndex = 0; inputIndex < 784; inputIndex += 1) {
      const product = Math.fround(
        input[inputIndex] * weights[base + inputIndex],
      );
      sum = Math.fround(sum + product);
    }
    hidden[hiddenIndex] = Math.fround(sigmoid(sum));
  }
  const output = new Float32Array(10);
  for (let outputIndex = 0; outputIndex < 10; outputIndex += 1) {
    const base = 23_550 + outputIndex * 31;
    let sum = Math.fround(weights[base + 30]);
    for (let hiddenIndex = 0; hiddenIndex < 30; hiddenIndex += 1) {
      const product = Math.fround(hidden[hiddenIndex] * weights[base + hiddenIndex]);
      sum = Math.fround(sum + product);
    }
    output[outputIndex] = Math.fround(sigmoid(sum));
  }
  return { hidden: [...hidden], output: [...output] };
}

function maxAbsError(actual, expected) {
  return Math.max(...actual.map((value, index) => Math.abs(value - expected[index])));
}

const inputConversionTolerance = 0.5 / 255;
const networkTolerance = 1e-5;

function argmax(values) {
  let index = 0;
  for (let cursor = 1; cursor < values.length; cursor += 1) {
    if (values[cursor] > values[index]) index = cursor;
  }
  return index;
}

const gpu = create(['enable-dawn-features=use_dxc']);
const adapter = await gpu.requestAdapter();
if (!adapter) throw new Error('provider returned no adapter');
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

const cases = [];
for (let expectedDigit = 0; expectedDigit <= 9; expectedDigit += 1) {
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
  const readback = Shared.GetReadbackBuffer_FromBuffer(
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

  let gpuOutput = null;
  await Shared.ReadbackBuffer(readback, (view) => {
    gpuOutput = Array.from(
      { length: 10 },
      (_, index) => view.getFloat32(index * Float32Array.BYTES_PER_ELEMENT, true),
    );
  });
  readback.destroy();

  let gpuHidden = null;
  await Shared.ReadbackBuffer(hiddenReadback, (view) => {
    gpuHidden = Array.from(
      { length: 30 },
      (_, index) => view.getFloat32(index * Float32Array.BYTES_PER_ELEMENT, true),
    );
  });
  hiddenReadback.destroy();

  let gpuInput = null;
  await Shared.ReadbackBuffer(inputReadback, (view) => {
    gpuInput = Array.from({ length: 28 * 28 }, (_, index) => {
      const x = index % 28;
      const y = Math.floor(index / 28);
      return view.getFloat32(y * 256 + x * Float32Array.BYTES_PER_ELEMENT, true);
    });
  });
  inputReadback.destroy();

  const png = Shared.LoadPNG_Node(imagePath);
  const idealInput = Array.from(
    { length: 28 * 28 },
    (_, index) => Math.fround(srgbByteToLinear(png.data[index * 4])),
  );
  const cpu = cpuInference(gpuInput, weights);
  const cpuOutput = cpu.output;
  const gpuDigit = argmax(gpuOutput);
  const cpuDigit = argmax(cpuOutput);
  const inputMaxAbsError = maxAbsError(gpuInput, idealInput);
  const hiddenMaxAbsError = maxAbsError(gpuHidden, cpu.hidden);
  const outputMaxAbsError = maxAbsError(gpuOutput, cpuOutput);
  cases.push({
    expectedDigit,
    gpuDigit,
    cpuDigit,
    inputMaxAbsError,
    hiddenMaxAbsError,
    outputMaxAbsError,
    gpuOutput,
    cpuOutput,
  });
  loaded.texture.destroy();
}

const validationError = await device.popErrorScope();
const oraclePass = validationError === null
  && cases.every((item) =>
    item.gpuDigit === item.cpuDigit
    && item.inputMaxAbsError <= inputConversionTolerance
    && item.hiddenMaxAbsError <= networkTolerance
    && item.outputMaxAbsError <= networkTolerance
    && item.gpuOutput.every(Number.isFinite)
    && item.cpuOutput.every(Number.isFinite));
const result = {
  provider: __doeProofProviderIdentity,
  adapter: adapter.info ?? null,
  validationError: validationError?.message ?? null,
  tolerances: {
    inputConversion: inputConversionTolerance,
    hiddenNetwork: networkTolerance,
    outputNetwork: networkTolerance,
  },
  oraclePass,
  cases,
};
console.log(`DOE_CPP_ML_ORACLE=${JSON.stringify(result)}`);
device.destroy();
if (!oraclePass) process.exitCode = 1;

#!/usr/bin/env node

import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { create, globals } from 'webgpu';

const upstreamRoot = process.env.DOE_CPP_ML_UPSTREAM;
if (!upstreamRoot) throw new Error('DOE_CPP_ML_UPSTREAM is required.');
const imageDigit = process.env.DOE_CPP_ML_IMAGE_DIGIT ?? '0';
if (!/^[0-9]$/.test(imageDigit)) {
  throw new Error('DOE_CPP_ML_IMAGE_DIGIT must be one decimal digit.');
}
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

const gpu = create(['enable-dawn-features=use_dxc']);
const adapter = await gpu.requestAdapter();
if (!adapter) throw new Error('provider returned no adapter');
const device = await adapter.requestDevice({ requiredFeatures: ['float32-filterable'] });

const weightsBytes = await readFile(resolve(webgpuRoot, 'assets/Backprop_Weights.bin'));
const weights = new Float32Array(
  weightsBytes.buffer,
  weightsBytes.byteOffset,
  weightsBytes.byteLength / Float32Array.BYTES_PER_ELEMENT,
);
mnist.buffer_NN_Weights = device.createBuffer({
  label: 'Backprop_Weights.bin',
  size: weightsBytes.byteLength,
  usage: mnist.buffer_NN_Weights_usageFlags | GPUBufferUsage.COPY_SRC,
});
mnist.buffer_NN_Weights_count = weightsBytes.byteLength / Float32Array.BYTES_PER_ELEMENT;
mnist.buffer_NN_Weights_stride = Float32Array.BYTES_PER_ELEMENT;
device.queue.writeBuffer(mnist.buffer_NN_Weights, 0, weightsBytes);
mnist.buffer_Hidden_Layer_Activations_usageFlags |= GPUBufferUsage.COPY_SRC;
mnist.buffer_Output_Layer_Activations_usageFlags |= GPUBufferUsage.COPY_SRC;
mnist.texture_NN_Input_usageFlags |= GPUTextureUsage.COPY_SRC;
mnist.variable_UseImportedImage = true;
mnist.variableChanged_UseImportedImage = true;

for (let priorDigit = 0; priorDigit < Number(imageDigit); priorDigit += 1) {
  const priorImagePath = resolve(webgpuRoot, `assets/${priorDigit}.png`);
  const priorLoaded = await Shared.CreateTextureWithPNG(
    device,
    priorImagePath,
    mnist.texture_Imported_Image_usageFlags,
  );
  if (!priorLoaded) throw new Error(`could not load ${priorImagePath}`);
  mnist.texture_Imported_Image = priorLoaded.texture;
  mnist.texture_Imported_Image_size = priorLoaded.size;
  mnist.texture_Imported_Image_format = priorLoaded.format;
  const priorEncoder = device.createCommandEncoder();
  if (!await mnist.Execute(device, priorEncoder, true)) {
    throw new Error(`generated workload rejected prior digit ${priorDigit}`);
  }
  device.queue.submit([priorEncoder.finish()]);
  await device.queue.onSubmittedWorkDone();
  priorLoaded.texture.destroy();
}

const imagePath = resolve(webgpuRoot, `assets/${imageDigit}.png`);
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
if (!await mnist.Execute(device, encoder, true)) throw new Error('generated workload rejected');
const weightsReadback = Shared.GetReadbackBuffer_FromBuffer(device, encoder, mnist.buffer_NN_Weights);
const hiddenReadback = Shared.GetReadbackBuffer_FromBuffer(device, encoder, mnist.buffer_Hidden_Layer_Activations);
const outputReadback = Shared.GetReadbackBuffer_FromBuffer(device, encoder, mnist.buffer_Output_Layer_Activations);
const inputReadback = Shared.GetReadbackBuffer_FromTexture(device, encoder, mnist.texture_NN_Input);
device.queue.submit([encoder.finish()]);
await device.queue.onSubmittedWorkDone();

async function readFloats(buffer, count) {
  let values;
  await Shared.ReadbackBuffer(buffer, (view) => {
    values = Array.from({ length: count }, (_, index) => view.getFloat32(index * 4, true));
  });
  return values;
}

let gpuInput;
await Shared.ReadbackBuffer(inputReadback, (view) => {
  gpuInput = Array.from({ length: 28 * 28 }, (_, index) => {
    const x = index % 28;
    const y = Math.floor(index / 28);
    return view.getFloat32(y * 256 + x * Float32Array.BYTES_PER_ELEMENT, true);
  });
});

const png = Shared.LoadPNG_Node(imagePath);
const expectedInput = Array.from(
  { length: 28 * 28 },
  (_, index) => Math.fround(srgbByteToLinear(png.data[index * 4])),
);
const cpuFromGpuInput = cpuInference(gpuInput, weights);
const cpuFromPng = cpuInference(expectedInput, weights);
const largestInputDiffs = gpuInput
  .map((actual, index) => ({
    index,
    sourceByte: png.data[index * 4],
    actual,
    expected: expectedInput[index],
    absError: Math.abs(actual - expectedInput[index]),
  }))
  .sort((left, right) => right.absError - left.absError)
  .slice(0, 8);

const gpuHidden = await readFloats(hiddenReadback, 30);
const gpuOutput = await readFloats(outputReadback, 10);

const result = {
  weights: await readFloats(weightsReadback, 8),
  hidden: gpuHidden,
  output: gpuOutput,
  inputComparison: {
    maxAbsError: maxAbsError(gpuInput, expectedInput),
    differingValues: gpuInput.reduce(
      (count, value, index) => count + Number(value !== expectedInput[index]),
      0,
    ),
    largestDiffs: largestInputDiffs,
  },
  cpuFromGpuInput: {
    hiddenMaxAbsError: maxAbsError(gpuHidden, cpuFromGpuInput.hidden),
    outputMaxAbsError: maxAbsError(gpuOutput, cpuFromGpuInput.output),
  },
  cpuFromPng: {
    hiddenMaxAbsError: maxAbsError(gpuHidden, cpuFromPng.hidden),
    outputMaxAbsError: maxAbsError(gpuOutput, cpuFromPng.output),
  },
};

const isolatedHiddenGroup = device.createBindGroup({
  layout: mnist.BindGroupLayout_Compute_Hidden_Layer,
  entries: [
    {
      binding: 0,
      resource: mnist.texture_NN_Input.createView({
        dimension: '2d',
        format: mnist.texture_NN_Input_format,
        usage: GPUTextureUsage.TEXTURE_BINDING,
      }),
    },
    { binding: 1, resource: { buffer: mnist.buffer_NN_Weights } },
    { binding: 2, resource: { buffer: mnist.buffer_Hidden_Layer_Activations } },
  ],
});
const isolatedEncoder = device.createCommandEncoder();
const isolatedPass = isolatedEncoder.beginComputePass();
isolatedPass.setPipeline(mnist.Pipeline_Compute_Hidden_Layer);
isolatedPass.setBindGroup(0, isolatedHiddenGroup);
isolatedPass.dispatchWorkgroups(1, 1, 1);
isolatedPass.end();
const isolatedHiddenReadback = Shared.GetReadbackBuffer_FromBuffer(
  device,
  isolatedEncoder,
  mnist.buffer_Hidden_Layer_Activations,
);
device.queue.submit([isolatedEncoder.finish()]);
await device.queue.onSubmittedWorkDone();
result.isolatedHidden = await readFloats(isolatedHiddenReadback, 30);

const pipelineFields = {
  Draw: 'Pipeline_Compute_Draw',
  CalculateExtents: 'Pipeline_Compute_CalculateExtents',
  Shrink: 'Pipeline_Compute_Shrink',
  Hidden: 'Pipeline_Compute_Hidden_Layer',
  Output: 'Pipeline_Compute_Output_Layer',
  Presentation: 'Pipeline_Compute_Presentation',
};
const savedPipelines = Object.fromEntries(
  Object.entries(pipelineFields).map(([name, field]) => [name, mnist[field]]),
);

async function runPipelineVariant(names) {
  const active = new Set(names);
  for (const [name, field] of Object.entries(pipelineFields)) {
    mnist[field] = active.has(name) ? savedPipelines[name] : null;
  }
  device.queue.writeBuffer(
    mnist.buffer_Hidden_Layer_Activations,
    0,
    new Float32Array(30),
  );
  const variantEncoder = device.createCommandEncoder();
  await mnist.FillEncoder(device, variantEncoder);
  const variantReadback = Shared.GetReadbackBuffer_FromBuffer(
    device,
    variantEncoder,
    mnist.buffer_Hidden_Layer_Activations,
  );
  device.queue.submit([variantEncoder.finish()]);
  await device.queue.onSubmittedWorkDone();
  const values = await readFloats(variantReadback, 30);
  variantReadback.destroy();
  return values;
}

result.variants = {};
for (const names of [
  ['Hidden'],
  ['Shrink', 'Hidden'],
  ['CalculateExtents', 'Shrink', 'Hidden'],
  ['Draw', 'CalculateExtents', 'Shrink', 'Hidden'],
  ['Hidden', 'Output'],
]) {
  result.variants[names.join('+')] = await runPipelineVariant(names);
}
for (const [name, field] of Object.entries(pipelineFields)) {
  mnist[field] = savedPipelines[name];
}
console.log(`DOE_CPP_ML_STAGE_DIAGNOSTIC=${JSON.stringify(result)}`);

for (const buffer of [
  weightsReadback,
  hiddenReadback,
  outputReadback,
  inputReadback,
  isolatedHiddenReadback,
]) {
  buffer.destroy();
}
loaded.texture.destroy();
device.destroy();

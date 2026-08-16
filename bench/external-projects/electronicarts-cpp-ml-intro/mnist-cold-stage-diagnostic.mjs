#!/usr/bin/env node

import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { create, globals } from 'webgpu';

const upstreamRoot = process.env.DOE_CPP_ML_UPSTREAM;
if (!upstreamRoot) throw new Error('DOE_CPP_ML_UPSTREAM is required.');

const stageLimit = process.env.DOE_CPP_ML_STAGE_LIMIT ?? 'Presentation';
const readInputTexture = process.env.DOE_CPP_ML_COLD_READBACK === 'input';
const stageNames = [
  'CopiesOnly',
  'Draw',
  'CalculateExtents',
  'Shrink',
  'Hidden',
  'Output',
  'Presentation',
];
const stageIndex = stageNames.indexOf(stageLimit);
if (stageIndex < 0) {
  throw new Error(`DOE_CPP_ML_STAGE_LIMIT must be one of ${stageNames.join(', ')}.`);
}

function milestone(name, detail = {}) {
  process.stderr.write(`DOE_CPP_ML_COLD_STAGE=${JSON.stringify({ name, ...detail })}\n`);
}

const webgpuRoot = resolve(upstreamRoot, 'Demo/mnist/Gigi/out/WebGPU');
Object.assign(globalThis, globals);
const Shared = await import(pathToFileURL(resolve(webgpuRoot, 'Shared.js')).href);
const { default: mnist } = await import(
  pathToFileURL(resolve(webgpuRoot, 'mnist_Module.js')).href
);

milestone('provider-create:start');
const gpu = create(['enable-dawn-features=use_dxc']);
const adapter = await gpu.requestAdapter();
if (!adapter) throw new Error('provider returned no adapter');
const device = await adapter.requestDevice({ requiredFeatures: ['float32-filterable'] });
milestone('provider-create:done');

let textureWriteCount = 0;
const writeTexture = device.queue.writeTexture.bind(device.queue);
device.queue.writeTexture = (...args) => {
  textureWriteCount += 1;
  const size = args[4] ?? {};
  milestone('writeTexture:start', {
    textureWriteCount,
    width: size.width,
    height: size.height,
    depthOrArrayLayers: size.depthOrArrayLayers ?? 1,
  });
  const result = writeTexture(...args);
  milestone('writeTexture:done', { textureWriteCount });
  return result;
};

milestone('weights:start');
const weightsBytes = await readFile(resolve(webgpuRoot, 'assets/Backprop_Weights.bin'));
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
milestone('weights:done', { bytes: weightsBytes.byteLength });

milestone('imported-image:start');
const imagePath = resolve(webgpuRoot, 'assets/0.png');
const loaded = await Shared.CreateTextureWithPNG(
  device,
  imagePath,
  mnist.texture_Imported_Image_usageFlags,
);
if (!loaded) throw new Error(`could not load ${imagePath}`);
mnist.texture_Imported_Image = loaded.texture;
mnist.texture_Imported_Image_size = loaded.size;
mnist.texture_Imported_Image_format = loaded.format;
mnist.variable_UseImportedImage = true;
mnist.variableChanged_UseImportedImage = true;
milestone('imported-image:done');

if (!await mnist.ValidateImports()) throw new Error('generated import validation failed');
await mnist.SetVarsBefore();
milestone('init:start');
await mnist.Init(device, device.createCommandEncoder(), true);
milestone('init:done', { textureWriteCount });

const pipelineFields = [
  ['Draw', 'Pipeline_Compute_Draw'],
  ['CalculateExtents', 'Pipeline_Compute_CalculateExtents'],
  ['Shrink', 'Pipeline_Compute_Shrink'],
  ['Hidden', 'Pipeline_Compute_Hidden_Layer'],
  ['Output', 'Pipeline_Compute_Output_Layer'],
  ['Presentation', 'Pipeline_Compute_Presentation'],
];
const savedPipelines = Object.fromEntries(
  pipelineFields.map(([name, field]) => [name, mnist[field]]),
);
for (let index = 0; index < pipelineFields.length; index += 1) {
  const [name, field] = pipelineFields[index];
  mnist[field] = index < stageIndex ? savedPipelines[name] : null;
}

milestone('fill:start', { stageLimit });
const encoder = device.createCommandEncoder();
await mnist.FillEncoder(device, encoder);
milestone('fill:done', { stageLimit });
const inputReadback = readInputTexture
  ? Shared.GetReadbackBuffer_FromTexture(device, encoder, mnist.texture_NN_Input)
  : null;
const commandBuffer = encoder.finish();
milestone('submit:start', { stageLimit });
device.queue.submit([commandBuffer]);
milestone('submit:done', { stageLimit });
await device.queue.onSubmittedWorkDone();
milestone('wait:done', { stageLimit });
if (inputReadback) {
  await Shared.ReadbackBuffer(inputReadback, () => {});
  inputReadback.destroy();
  milestone('readback:input:done', { stageLimit });
}

loaded.texture.destroy();
device.destroy();
console.log(JSON.stringify({
  status: 'passed',
  stageLimit,
  textureWriteCount,
  readInputTexture,
}));

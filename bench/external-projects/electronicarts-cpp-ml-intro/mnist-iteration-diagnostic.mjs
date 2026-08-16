#!/usr/bin/env node

import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { create, globals } from 'webgpu';

const upstreamRoot = process.env.DOE_CPP_ML_UPSTREAM;
if (!upstreamRoot) throw new Error('DOE_CPP_ML_UPSTREAM is required.');
const iterationCount = Number(process.env.DOE_CPP_ML_ITERATION_COUNT ?? 10);
if (!Number.isInteger(iterationCount) || iterationCount < 1 || iterationCount > 10) {
  throw new Error('DOE_CPP_ML_ITERATION_COUNT must be an integer from 1 through 10.');
}
const requestedReadbacks = new Set(
  (process.env.DOE_CPP_ML_READBACKS ?? 'output,hidden,input')
    .split(',')
    .map((name) => name.trim())
    .filter(Boolean),
);
for (const name of requestedReadbacks) {
  if (!['output', 'hidden', 'input'].includes(name)) {
    throw new Error('DOE_CPP_ML_READBACKS may contain only output, hidden, and input.');
  }
}

function milestone(name, detail = {}) {
  process.stderr.write(`DOE_CPP_ML_ITERATION=${JSON.stringify({ name, ...detail })}\n`);
}

const webgpuRoot = resolve(upstreamRoot, 'Demo/mnist/Gigi/out/WebGPU');
Object.assign(globalThis, globals);
const Shared = await import(pathToFileURL(resolve(webgpuRoot, 'Shared.js')).href);
const { default: mnist } = await import(
  pathToFileURL(resolve(webgpuRoot, 'mnist_Module.js')).href
);

const gpu = create(['enable-dawn-features=use_dxc']);
const adapter = await gpu.requestAdapter();
if (!adapter) throw new Error('provider returned no adapter');
const device = await adapter.requestDevice({ requiredFeatures: ['float32-filterable'] });
const weightsBytes = await readFile(resolve(webgpuRoot, 'assets/Backprop_Weights.bin'));
mnist.buffer_NN_Weights = device.createBuffer({
  label: 'Backprop_Weights.bin',
  size: weightsBytes.byteLength,
  usage: mnist.buffer_NN_Weights_usageFlags,
});
mnist.buffer_NN_Weights_count = weightsBytes.byteLength / Float32Array.BYTES_PER_ELEMENT;
mnist.buffer_NN_Weights_stride = Float32Array.BYTES_PER_ELEMENT;
device.queue.writeBuffer(mnist.buffer_NN_Weights, 0, weightsBytes);
mnist.buffer_Hidden_Layer_Activations_usageFlags |= GPUBufferUsage.COPY_SRC;
mnist.buffer_Output_Layer_Activations_usageFlags |= GPUBufferUsage.COPY_SRC;
mnist.texture_NN_Input_usageFlags |= GPUTextureUsage.COPY_SRC;
mnist.variable_UseImportedImage = true;
mnist.variableChanged_UseImportedImage = true;

for (let iteration = 0; iteration < iterationCount; iteration += 1) {
  milestone('image:start', { iteration });
  const imagePath = resolve(webgpuRoot, `assets/${iteration}.png`);
  const loaded = await Shared.CreateTextureWithPNG(
    device,
    imagePath,
    mnist.texture_Imported_Image_usageFlags,
  );
  if (!loaded) throw new Error(`could not load ${imagePath}`);
  mnist.texture_Imported_Image = loaded.texture;
  mnist.texture_Imported_Image_size = loaded.size;
  mnist.texture_Imported_Image_format = loaded.format;
  milestone('image:done', { iteration });

  const encoder = device.createCommandEncoder();
  milestone('execute:start', { iteration });
  if (!await mnist.Execute(device, encoder, true)) {
    throw new Error(`generated workload rejected iteration ${iteration}`);
  }
  milestone('execute:done', { iteration });
  const outputReadback = requestedReadbacks.has('output')
    ? Shared.GetReadbackBuffer_FromBuffer(
      device,
      encoder,
      mnist.buffer_Output_Layer_Activations,
    )
    : null;
  const hiddenReadback = requestedReadbacks.has('hidden')
    ? Shared.GetReadbackBuffer_FromBuffer(
      device,
      encoder,
      mnist.buffer_Hidden_Layer_Activations,
    )
    : null;
  const inputReadback = requestedReadbacks.has('input')
    ? Shared.GetReadbackBuffer_FromTexture(
      device,
      encoder,
      mnist.texture_NN_Input,
    )
    : null;
  milestone('submit:start', { iteration });
  device.queue.submit([encoder.finish()]);
  milestone('submit:done', { iteration });
  await device.queue.onSubmittedWorkDone();
  milestone('wait:done', { iteration });
  if (outputReadback) {
    await Shared.ReadbackBuffer(outputReadback, () => {});
    milestone('readback:output:done', { iteration });
    outputReadback.destroy();
  }
  if (hiddenReadback) {
    await Shared.ReadbackBuffer(hiddenReadback, () => {});
    milestone('readback:hidden:done', { iteration });
    hiddenReadback.destroy();
  }
  if (inputReadback) {
    await Shared.ReadbackBuffer(inputReadback, () => {});
    milestone('readback:input:done', { iteration });
    inputReadback.destroy();
  }
  loaded.texture.destroy();
  milestone('destroy:done', { iteration });
}

device.destroy();
console.log(JSON.stringify({
  status: 'passed',
  iterationCount,
  readbacks: [...requestedReadbacks],
}));

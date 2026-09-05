import { app } from 'electron';
import { globals } from 'doe-gpu/native';
import { runFirstKernel } from './first-kernel.js';

async function probeMappedRange(rawDevice) {
  const shader = rawDevice.createShaderModule({
    code: `
      @group(0) @binding(0) var<storage, read_write> output: array<u32>;
      @compute @workgroup_size(1)
      fn main() { output[0] = 42u; }
    `,
  });
  const pipeline = rawDevice.createComputePipeline({
    layout: "auto",
    compute: { module: shader, entryPoint: "main" },
  });
  const output = rawDevice.createBuffer({
    size: 4,
    usage: globals.GPUBufferUsage.STORAGE | globals.GPUBufferUsage.COPY_SRC,
  });
  const readback = rawDevice.createBuffer({
    size: 4,
    usage: globals.GPUBufferUsage.COPY_DST | globals.GPUBufferUsage.MAP_READ,
  });
  try {
    const bindGroup = rawDevice.createBindGroup({
      layout: pipeline.getBindGroupLayout(0),
      entries: [{ binding: 0, resource: { buffer: output } }],
    });
    const encoder = rawDevice.createCommandEncoder();
    const pass = encoder.beginComputePass();
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, bindGroup);
    pass.dispatchWorkgroups(1);
    pass.end();
    encoder.copyBufferToBuffer(output, 0, readback, 0, 4);
    rawDevice.queue.submit([encoder.finish()]);
    await readback.mapAsync(globals.GPUMapMode.READ);
    const mappedRange = readback.getMappedRange();
    if (Object.prototype.toString.call(mappedRange) !== "[object ArrayBuffer]"
      || typeof mappedRange.slice !== "function") {
      throw new Error(
        `GPUBuffer.getMappedRange returned ${Object.prototype.toString.call(mappedRange)}`,
      );
    }
    const value = new Uint32Array(mappedRange.slice(0))[0];
    if (value !== 42) {
      throw new Error(`GPUBuffer.getMappedRange probe produced ${value}; expected 42`);
    }
    return {
      objectTag: Object.prototype.toString.call(mappedRange),
      sliceAvailable: true,
      value,
    };
  } finally {
    readback.unmap();
    output.destroy();
    readback.destroy();
  }
}

try {
  let mappedRangeProbe;
  const receipt = await runFirstKernel('electron', async (device) => {
    mappedRangeProbe = await probeMappedRange(device);
  });
  receipt.runtimeVersion = process.versions.electron;
  receipt.mappedRangeProbe = mappedRangeProbe;
  process.stdout.write(`${JSON.stringify(receipt, null, 2)}\n`);
  app.exit(0);
} catch (error) {
  process.stderr.write(`${error?.stack ?? error}\n`);
  app.exit(1);
}

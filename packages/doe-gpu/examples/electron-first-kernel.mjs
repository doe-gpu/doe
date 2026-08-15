import { createHash } from "node:crypto";
import { Buffer } from "node:buffer";
import { app } from "electron";
import { globals, gpu, providerInfo } from "doe-gpu";

const input = new Float32Array([1, 2, 3, 4, 5, 6, 7, 8]);
const elementCount = input.length;
const code = `
@group(0) @binding(0) var<storage, read> input: array<f32>;
@group(0) @binding(1) var<storage, read_write> output: array<f32>;

@compute @workgroup_size(${elementCount})
fn main(@builtin(global_invocation_id) id: vec3u) {
  if (id.x >= ${elementCount}u) {
    return;
  }
  output[id.x] = input[id.x] * 2.0;
}
`;

function sha256(value) {
  const bytes = typeof value === "string"
    ? Buffer.from(value, "utf8")
    : Buffer.from(value.buffer, value.byteOffset, value.byteLength);
  return createHash("sha256").update(bytes).digest("hex");
}

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
  readback.unmap();
  output.destroy();
  readback.destroy();
  if (value !== 42) {
    throw new Error(`GPUBuffer.getMappedRange probe produced ${value}; expected 42`);
  }
  return {
    objectTag: Object.prototype.toString.call(mappedRange),
    sliceAvailable: true,
    value,
  };
}

try {
  const runtime = providerInfo();
  const startedAt = performance.now();
  const device = await gpu.requestDevice();
  const output = await device.compute({
    code,
    inputs: [input],
    output: { type: Float32Array, size: input.byteLength },
    workgroups: 1,
  });
  const mappedRangeProbe = await probeMappedRange(device.device);
  const finishedAt = performance.now();
  device.device.destroy();

  const receipt = {
    kind: "doe-gpu.first-kernel.receipt",
    schemaVersion: 1,
    runtimeHost: "electron",
    runtimeVersion: process.versions.electron,
    provider: runtime,
    workload: {
      id: "vector-scale-f32",
      elementCount,
      wgslSha256: sha256(code),
      inputSha256: sha256(input),
    },
    result: {
      output: Array.from(output),
      outputSha256: sha256(output),
      durationMs: Number((finishedAt - startedAt).toFixed(3)),
    },
    mappedRangeProbe,
  };

  process.stdout.write(`${JSON.stringify(receipt, null, 2)}\n`);
  app.exit(0);
} catch (error) {
  process.stderr.write(`${error?.stack ?? error}\n`);
  app.exit(1);
}

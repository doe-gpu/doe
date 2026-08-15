import { createHash } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { runGovernedNodeWebGPU } from "doe-gpu/node-webgpu";

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

function sha256(value) {
  const bytes = typeof value === "string"
    ? Buffer.from(value, "utf8")
    : Buffer.from(value.buffer, value.byteOffset, value.byteLength);
  return `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
}

const externalModule = process.env.DOE_GOVERNED_NODE_WEBGPU_MODULE?.trim();
const provider = externalModule
  ? {
      id: "explicit-incumbent",
      kind: "module",
      module: externalModule,
      gpu: {
        kind: "factory",
        path: "create",
        args: [["enable-dawn-features=allow_unsafe_apis"]],
      },
      globals: {
        GPUBufferUsage: "globals.GPUBufferUsage",
        GPUShaderStage: "globals.GPUShaderStage",
        GPUMapMode: "globals.GPUMapMode",
        GPUTextureUsage: "globals.GPUTextureUsage",
      },
    }
  : {
      id: "doe-native",
      kind: "module",
      module: new URL("../src/native.js", import.meta.url).href,
      gpu: {
        kind: "factory",
        path: "createNativeDirect",
        args: [["enable-dawn-features=allow_unsafe_apis"]],
      },
      globals: {
        GPUBufferUsage: "globals.GPUBufferUsage",
        GPUShaderStage: "globals.GPUShaderStage",
        GPUMapMode: "globals.GPUMapMode",
        GPUTextureUsage: "globals.GPUTextureUsage",
      },
    };

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
    const bindGroupLayout = device.createBindGroupLayout({
      entries: [
        {
          binding: 0,
          visibility: GPUShaderStage.COMPUTE,
          buffer: { type: "read-only-storage" },
        },
        {
          binding: 1,
          visibility: GPUShaderStage.COMPUTE,
          buffer: { type: "storage" },
        },
      ],
    });
    const pipelineLayout = device.createPipelineLayout({
      bindGroupLayouts: [bindGroupLayout],
    });
    const pipeline = device.createComputePipeline({
      layout: pipelineLayout,
      compute: { module: shader, entryPoint: "main" },
    });
    const bindGroup = device.createBindGroup({
      layout: bindGroupLayout,
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
    encoder.copyBufferToBuffer(outputBuffer, 0, readbackBuffer, 0, inputBytes.byteLength);
    device.queue.submit([encoder.finish()]);
    await readbackBuffer.mapAsync(GPUMapMode.READ);
    return new Uint8Array(readbackBuffer.getMappedRange()).slice();
  } finally {
    if (readbackBuffer.mapState === "mapped") readbackBuffer.unmap();
    inputBuffer.destroy();
    outputBuffer.destroy();
    readbackBuffer.destroy();
    device.destroy();
  }
}

const checkpointPath = process.env.DOE_GOVERNED_RECEIPT_PATH?.trim();
const result = await runGovernedNodeWebGPU({
  provider: {
    providers: [provider],
    adapterOptions: null,
    globals: { mode: "replace" },
  },
  workload: {
    id: "vector-scale-f32-governed",
    version: "1",
    implementationSha256: sha256(code),
    input,
    expectedOutputSha256: sha256(expected),
  },
  execute,
  checkpoint: checkpointPath
    ? async (receipt) => {
        await mkdir(dirname(checkpointPath), { recursive: true });
        await writeFile(checkpointPath, `${JSON.stringify(receipt, null, 2)}\n`);
      }
    : undefined,
});

const output = result.output
  ? Array.from(new Float32Array(
      result.output.buffer,
      result.output.byteOffset,
      result.output.byteLength / Float32Array.BYTES_PER_ELEMENT,
    ))
  : null;
console.log(JSON.stringify({ ...result, output }, null, 2));
process.exitCode = result.ok ? 0 : 1;

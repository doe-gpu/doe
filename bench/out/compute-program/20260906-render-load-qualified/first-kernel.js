import { createHash } from "node:crypto";
import { Buffer } from "node:buffer";
import assert from "node:assert/strict";
import { gpu, providerInfo, requestAdapter } from "doe-gpu/native";

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

export async function runFirstKernel(runtimeHost, beforeRelease = null) {
  const startedAt = performance.now();
  const adapter = await requestAdapter();
  if (!adapter) throw new Error('Doe native provider returned no adapter');
  const device = await adapter.requestDevice();
  try {
    const output = await gpu.bind(device).compute({
      code,
      inputs: [input],
      output: { type: Float32Array, size: input.byteLength },
      workgroups: 1,
    });
    assert.deepEqual(Array.from(output), [2, 4, 6, 8, 10, 12, 14, 16]);
    await beforeRelease?.(device);
    const finishedAt = performance.now();
    return {
      kind: 'doe-gpu.first-kernel.receipt',
      schemaVersion: 1,
      runtimeHost,
      provider: providerInfo(),
      workload: {
        id: 'vector-scale-f32',
        elementCount,
        wgslSha256: sha256(code),
        inputSha256: sha256(input),
      },
      result: {
        output: Array.from(output),
        outputSha256: sha256(output),
        durationMs: Number((finishedAt - startedAt).toFixed(3)),
      },
    };
  } finally {
    device.destroy();
  }
}

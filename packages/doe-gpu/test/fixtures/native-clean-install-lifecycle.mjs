import { createHash } from 'node:crypto';
import { Buffer } from 'node:buffer';
import { gpu, providerInfo } from 'doe-gpu';

const runtimeHost = process.env.DOE_NATIVE_LIFECYCLE_RUNTIME;
const cycleCount = Number.parseInt(process.env.DOE_NATIVE_LIFECYCLE_CYCLES ?? '', 10);
if (!['node', 'bun', 'electron'].includes(runtimeHost)) {
  throw new Error('DOE_NATIVE_LIFECYCLE_RUNTIME must be node, bun, or electron');
}
if (!Number.isSafeInteger(cycleCount) || cycleCount < 3) {
  throw new Error('DOE_NATIVE_LIFECYCLE_CYCLES must be an integer of at least 3');
}

const input = new Float32Array([1, 2, 3, 4, 5, 6, 7, 8]);
const expected = [2, 4, 6, 8, 10, 12, 14, 16];
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

function sha256(value) {
  const bytes = typeof value === 'string'
    ? Buffer.from(value, 'utf8')
    : Buffer.from(value.buffer, value.byteOffset, value.byteLength);
  return createHash('sha256').update(bytes).digest('hex');
}

function collectGarbage() {
  if (typeof globalThis.gc === 'function') {
    globalThis.gc();
    return 'host-gc';
  }
  if (typeof globalThis.Bun?.gc === 'function') {
    globalThis.Bun.gc(true);
    return 'bun-gc';
  }
  return 'unavailable';
}

async function awaitDeviceLost(lost, timeoutMs = 2_000) {
  let timer;
  try {
    return await Promise.race([
      lost,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('GPUDevice.lost did not resolve')), timeoutMs);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

const provider = providerInfo();
const samples = [];
const rssBeforeBytes = process.memoryUsage().rss;
for (let index = 0; index < cycleCount; index += 1) {
  const bound = await gpu.requestDevice();
  const output = await bound.compute({
    code,
    inputs: [input],
    output: { type: Float32Array, size: input.byteLength },
    workgroups: 1,
  });
  const actual = Array.from(output);
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`cycle ${index} output mismatch: ${JSON.stringify(actual)}`);
  }
  const lost = bound.device.lost;
  bound.device.destroy();
  const lostInfo = await awaitDeviceLost(lost);
  if (lostInfo?.reason !== 'destroyed') {
    throw new Error(`cycle ${index} device loss reason mismatch: ${lostInfo?.reason}`);
  }
  let postDestroyRejected = false;
  let postDestroyError = '';
  try {
    bound.device.createCommandEncoder();
  } catch (error) {
    postDestroyError = String(error?.message ?? error);
    postDestroyRejected = postDestroyError.includes('GPUDevice was destroyed');
  }
  if (!postDestroyRejected) {
    throw new Error(`cycle ${index} post-destroy use did not fail closed: ${postDestroyError}`);
  }
  const collection = collectGarbage();
  samples.push({
    index,
    outputSha256: sha256(output),
    deviceDestroyed: true,
    lostReason: lostInfo.reason,
    lostMessage: lostInfo.message,
    postDestroyRejected,
    postDestroyError,
    collection,
    rssAfterDestroyBytes: process.memoryUsage().rss,
  });
}

process.stdout.write(`${JSON.stringify({
  artifactKind: 'doe-gpu-native-same-process-lifecycle-sample',
  schemaVersion: 1,
  status: 'passed',
  runtimeHost,
  provider,
  contract: {
    cycleCount,
    expectedOutputSha256: sha256(new Float32Array(expected)),
  },
  rssBeforeBytes,
  samples,
})}\n`);
if (runtimeHost === 'electron') {
  const { app } = await import('electron');
  app.exit(0);
}

// Linux DRM checkpoints exercise explicit cleanup while closed programs remain reachable.
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { requestAdapter } from '../../src/native.js';
import { prepareComputeProgram } from '../../src/compute-program.js';

const CYCLES = 8;
const descriptor = {
  schemaVersion: 1, id: 'resource_retention',
  buffers: [{ id: 'output', size: 65536, type: 'storage', role: 'output' }],
  shaders: [{ id: 'fill', entryPoint: 'main', code: `
    @group(0) @binding(0) var<storage, read_write> output: array<u32>;
    @compute @workgroup_size(64) fn main(@builtin(global_invocation_id) id: vec3<u32>) {
      output[id.x] = id.x + 1u;
    }` }],
  steps: [{ shader: 'fill', bindings: [{ binding: 0, buffer: 'output' }], workgroups: [256, 1, 1] }],
  output: 'output',
};

function drmClients() {
  const clients = new Map();
  for (const fd of readdirSync('/proc/self/fdinfo')) {
    let text;
    try { text = readFileSync(`/proc/self/fdinfo/${fd}`, 'utf8'); }
    catch (error) { if (error.code === 'ENOENT') continue; throw error; }
    const id = text.match(/^drm-client-id:\s*(\d+)/m)?.[1];
    if (!id) continue;
    const device = text.match(/^drm-pdev:\s*(.+)$/m)?.[1];
    assert(device, 'DRM checkpoint requires a physical device identity');
    const key = `${device}:${id}`;
    const values = clients.get(key) ?? new Map();
    for (const [, pool, amount] of text.matchAll(/^drm-total-(\S+):\s*(\d+) KiB$/gm)) {
      values.set(pool, Math.max(values.get(pool) ?? 0, Number(amount)));
    }
    assert(values.size > 0, 'DRM checkpoint requires driver-reported allocation totals');
    clients.set(key, values);
  }
  return clients;
}

function allocationTotal(clients, excluded) {
  let bytes = 0;
  for (const [id, values] of clients) {
    if (!excluded.has(id)) bytes += [...values.values()].reduce((sum, value) => sum + value, 0) * 1024;
  }
  return bytes;
}

if (process.platform !== 'linux') {
  console.log('native resource retention: skipped Linux DRM checkpoints on this platform');
} else {
  for (const execution of ['webgpu', 'native-recorded', 'gpu-recorded']) {
    for (const gpuTiming of ['off', 'timestamp-query']) {
      const before = drmClients();
      const adapter = await requestAdapter({ backend: 'vulkan' });
      const device = await adapter.requestDevice({
        requiredFeatures: gpuTiming === 'off' ? [] : ['timestamp-query'],
        defaultQueue: { label: 'resource-retention' },
      });
      const closed = [];
      const totals = [];
      try {
        for (let cycle = 0; cycle < CYCLES; cycle += 1) {
          const program = await prepareComputeProgram(device, descriptor, { execution, gpuTiming });
          try {
            for (let run = 0; run < 2; run += 1) {
              const result = await program.run();
              const output = new Uint32Array(result.output.buffer, result.output.byteOffset, result.output.byteLength / 4);
              assert(output.every((value, index) => value === index + 1));
            }
          } finally { await program.close(); }
          closed.push(program);
          totals.push(allocationTotal(drmClients(), before));
        }
        assert(closed.every((program) => program.state === 'closed'));
        assert(totals[0] > 0, 'expected an observed Vulkan device allocation');
        assert(totals.every((total) => total === totals[0]), `${execution}/${gpuTiming}: post-close allocation growth: ${totals}`);
      } finally {
        device.destroy();
        adapter.destroy();
      }
      assert.deepEqual([...drmClients().keys()].sort(), [...before.keys()].sort(),
        `${execution}/${gpuTiming}: device teardown retained a DRM client`);
      console.log(`ok: ${execution}/${gpuTiming} bounded program allocations and released device ownership`);
    }
  }
}

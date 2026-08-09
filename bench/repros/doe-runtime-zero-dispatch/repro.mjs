// Minimum repro for the Doe runtime zero-dispatch bug.
//
// A 3-line WGSL compute kernel that writes `u32(42)` to index 0 of a
// storage buffer. Through doe-gpu's compute facade in Node, every
// intermediate call succeeds (createShaderModule, createComputePipeline,
// createBuffer, createBindGroup, dispatchWorkgroups, queue.submit,
// copyBufferToBuffer, mapAsync) but the readback returns 0 instead
// of 42. See docs/status/bugs/doe-runtime-zero-dispatch.md.
//
// Usage:
//     node bench/repros/doe-runtime-zero-dispatch/repro.mjs
//
// Expected when the bug is fixed:
//     dispatched u32: 42 (expect 42)
//
// Add --label to cover a labeled compute pass and --native to force a native
// command encoder before the pass begins.

import { setupGlobals } from '../../../packages/doe-gpu/src/compute.js';

setupGlobals();

const adapter = await navigator.gpu.requestAdapter();
if (!adapter) {
  throw new Error('no adapter');
}
console.log('adapter.info:', adapter.info);

const device = await adapter.requestDevice();
if (!device) {
  throw new Error('no device');
}
console.log('device.features:', Array.from(device.features).slice(0, 5));

const shader = device.createShaderModule({
  code: `
    @group(0) @binding(0) var<storage, read_write> out: array<u32>;
    @compute @workgroup_size(1) fn main() { out[0] = 42u; }
  `,
});

const pipeline = device.createComputePipeline({
  layout: 'auto',
  compute: { module: shader, entryPoint: 'main' },
});

// STORAGE | COPY_SRC
const storageBuf = device.createBuffer({ size: 4, usage: 0x80 | 0x04 });

const bindGroup = device.createBindGroup({
  layout: pipeline.getBindGroupLayout(0),
  entries: [{ binding: 0, resource: { buffer: storageBuf } }],
});

const encoder = device.createCommandEncoder();
if (process.argv.includes('--native')) {
  const nativeRouteSource = device.createBuffer({ size: 4, usage: 0x04 });
  const nativeRouteDestination = device.createBuffer({ size: 4, usage: 0x08 });
  encoder.copyBufferToBuffer(nativeRouteSource, 0, nativeRouteDestination, 0, 4);
}
const pass = encoder.beginComputePass(
  process.argv.includes('--label') ? { label: 'zero-dispatch-repro' } : undefined,
);
pass.setPipeline(pipeline);
pass.setBindGroup(0, bindGroup);
pass.dispatchWorkgroups(1);
pass.end();

// COPY_DST | MAP_READ
const readBuf = device.createBuffer({ size: 4, usage: 0x08 | 0x01 });
encoder.copyBufferToBuffer(storageBuf, 0, readBuf, 0, 4);
device.queue.submit([encoder.finish()]);

await readBuf.mapAsync(1); // GPUMapMode.READ
const view = new Uint32Array(readBuf.getMappedRange());
const value = view[0];
console.log(`dispatched u32: ${value} (expect 42)`);

process.exit(value === 42 ? 0 : 1);

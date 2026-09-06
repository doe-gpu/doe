// Raw addon handles allow releasing caller ownership without destroying resources.
import assert from 'node:assert/strict';
import { requestAdapter, globals } from '../../src/native.js';
import { loadNativeAddon } from './native-addon-test-helper.js';

const adapter = await requestAdapter({ backend: process.platform === 'darwin' ? 'metal' : 'vulkan' });
const device = await adapter.requestDevice();
const addon = await loadNativeAddon();
const usage = globals.GPUBufferUsage;
const rowBytes = 256;
const shaderSource = `
  @vertex fn vertex(@location(0) position: vec2<f32>) -> @builtin(position) vec4<f32> {
    return vec4<f32>(position, 0.0, 1.0);
  }
  @fragment fn fragment() -> @location(0) vec4<f32> {
    return vec4<f32>(1.0, 0.0, 0.0, 1.0);
  }`;

try {
  for (const bundled of [false, true]) {
    const cleanup = new Map();
    function own(handle, release) { cleanup.set(handle, release); return handle; }
    function release(handle) {
      const action = cleanup.get(handle);
      assert(action, 'caller reference must be released exactly once');
      cleanup.delete(handle);
      action(handle);
    }
    const readback = own(addon.createBuffer(device._native,
      { size: rowBytes, usage: usage.MAP_READ | usage.COPY_DST }), addon.bufferRelease);
    try {
      const shader = own(addon.createShaderModule(device._native, shaderSource), addon.shaderModuleRelease);
      const pipeline = own(addon.createRenderPipeline(device._native, {
        vertex: { module: shader, entryPoint: 'vertex', buffers: [{ arrayStride: 8,
          attributes: [{ format: 'float32x2', offset: 0, shaderLocation: 0 }] }] },
        fragment: { module: shader, entryPoint: 'fragment', targets: [{ format: 'rgba8unorm' }] },
        primitive: { topology: 'triangle-list' },
      }), addon.renderPipelineRelease);
      release(shader);
      const texture = own(addon.createTexture(device._native, {
        width: 2, height: 1, format: 'rgba8unorm',
        usage: globals.GPUTextureUsage.RENDER_ATTACHMENT | globals.GPUTextureUsage.COPY_SRC,
      }), addon.textureRelease);
      const view = own(addon.textureCreateView(texture), addon.textureViewRelease);
      const vertex = own(addon.createBuffer(device._native, { size: 24, usage: usage.VERTEX | usage.COPY_DST }), addon.bufferRelease);
      const index = own(addon.createBuffer(device._native, { size: 12, usage: usage.INDEX | usage.COPY_DST }), addon.bufferRelease);
      const indirect = own(addon.createBuffer(device._native, { size: 20, usage: usage.INDIRECT | usage.COPY_DST }), addon.bufferRelease);
      addon.queueWriteBuffer(device.queue._native, vertex, 0, new Float32Array(6));
      addon.queueWriteBuffer(device.queue._native, index, 0, new Uint32Array([0, 1, 2]));
      addon.queueWriteBuffer(device.queue._native, indirect, 0, new Uint32Array([3, 1, 0, 0, 0]));
      const encoder = own(addon.createCommandEncoder(device._native, 'retained-render'), addon.commandEncoderRelease);
      const pass = own(addon.beginRenderPass(encoder, { colorAttachments: [{ view,
        loadOp: 'clear', storeOp: 'store', clearValue: { r: 0, g: 0, b: 1, a: 1 } }] }), addon.renderPassRelease);
      let drawEncoder = pass;
      if (bundled) {
        drawEncoder = own(addon.createRenderBundleEncoder(device._native, ['rgba8unorm'], undefined, 1, false, false),
          addon.renderBundleEncoderRelease);
      }
      const prefix = bundled ? 'renderBundleEncoder' : 'renderPass';
      addon.renderPassSetScissorRect(pass, 0, 0, 1, 1);
      addon[`${prefix}SetPipeline`](drawEncoder, pipeline);
      addon[`${prefix}SetVertexBuffer`](drawEncoder, 0, vertex, 0, 24);
      addon[`${prefix}SetIndexBuffer`](drawEncoder, index, 'uint32', 0, 12);
      addon[`${prefix}DrawIndexedIndirect`](drawEncoder, indirect, 0);
      if (!bundled) {
        addon.renderPassSetScissorRect(pass, 1, 0, 1, 1);
        addon.renderPassDrawIndexedIndirect(pass, indirect, 0);
      }
      // A write after recording must be visible when the command buffer is submitted.
      addon.queueWriteBuffer(device.queue._native, vertex, 0, new Float32Array([-1, -1, 3, -1, -1, 3]));
      for (const handle of [pipeline, vertex, index, indirect]) release(handle);
      if (bundled) {
        const bundle = own(addon.renderBundleEncoderFinish(drawEncoder), addon.renderBundleRelease);
        release(drawEncoder);
        addon.renderPassExecuteBundles(pass, [bundle]);
        addon.renderPassSetScissorRect(pass, 1, 0, 1, 1);
        addon.renderPassExecuteBundles(pass, [bundle]);
        release(bundle);
      }
      addon.renderPassEnd(pass);
      const loadPass = own(addon.beginRenderPass(encoder, { colorAttachments: [{ view,
        loadOp: 'load', storeOp: 'store' }] }), addon.renderPassRelease);
      release(view);
      addon.renderPassEnd(loadPass);
      addon.commandEncoderCopyTextureToBuffer(encoder, texture, 0, 0, 0, 0, 1,
        readback, 0, rowBytes, 1, 2, 1, 1);
      release(texture);
      const commands = own(addon.commandEncoderFinish(encoder), addon.commandBufferRelease);
      release(encoder);
      release(pass);
      release(loadPass);
      addon.queueSubmit(device.queue._native, [commands]);
      await device.queue.onSubmittedWorkDone();
      release(commands);
      addon.bufferMapSync(device._instance, readback, globals.GPUMapMode.READ, 0, rowBytes);
      assert.deepEqual(new Uint8Array(addon.bufferReadCopy(readback, 0, rowBytes)).slice(0, 8),
        new Uint8Array([255, 0, 0, 255, 255, 0, 0, 255]));
      addon.bufferUnmap(readback);
      release(readback);
      assert.equal(cleanup.size, 0);
      console.log(`ok: ${bundled ? 'bundle' : 'direct'} draws preserve color through a load pass and caller release`);
    } finally {
      for (const [handle, action] of [...cleanup].reverse()) action(handle);
    }
  }
} finally {
  device.destroy();
  adapter.destroy();
}

// Execute the production conversion shader against an independent BigInt oracle.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { requestAdapter, globals } from '../../src/native.js';

const shader = readFileSync(new URL('../../../../runtime/zig/src/backend/vulkan/vk_timestamp_normalize.wgsl', import.meta.url), 'utf8');
const policy = JSON.parse(readFileSync(new URL('../../../../config/vulkan-timestamp-policy.json', import.meta.url), 'utf8'));
const COUNT = 257;
const UINT64_MASK = (1n << 64n) - 1n;
const PERIODS = [0.5, 1, 2.5, 10.019036293029785, 1 + 2 ** -23,
  2 ** -149, 2 ** -80, 2 ** 50, Math.fround(3.4028234663852886e38)];
const WIDTHS = [1, 32, 48, 64];
const values = new BigUint64Array(COUNT);
values.set([0n, 1n, 65535n, 65536n, (1n << 32n) - 1n, 1n << 32n,
  (1n << 48n) - 1n, 1n << 48n, (1n << 63n) - 1n, 1n << 63n, UINT64_MASK]);
let state = 12345n;
for (let i = 11; i < COUNT; i += 1) {
  state = (state * 6364136223846793005n + 1442695040888963407n) & UINT64_MASK;
  values[i] = state;
}
const { GPUBufferUsage: U, GPUMapMode: M } = globals;
const adapter = await requestAdapter({ backend: process.platform === 'darwin' ? 'metal' : 'vulkan' });
const device = await adapter.requestDevice();
const data = device.createBuffer({ size: values.byteLength, usage: U.STORAGE | U.COPY_DST | U.COPY_SRC });
const readback = device.createBuffer({ size: values.byteLength, usage: U.MAP_READ | U.COPY_DST });
try {
  for (const period of PERIODS) {
    const bits = new Uint32Array(new Float32Array([period]).buffer)[0];
    const exponent = (bits >>> 23) & 255;
    const mantissa = (bits & 0x7fffff) | (exponent === 0 ? 0 : 1 << 23);
    const shift = exponent === 0 ? -149 : exponent - 150;
    for (const width of WIDTHS) {
      device.pushErrorScope('validation');
      const mask = (1n << BigInt(width)) - 1n;
      const code = `const MANTISSA = ${mantissa}u; const PERIOD_SHIFT = ${shift}i;
        const MASK_LOW = ${mask & 0xffffffffn}u; const MASK_HIGH = ${mask >> 32n}u;
        const WORKGROUP_SIZE = ${policy.workgroupSize}u;\n${shader}`;
      const pipeline = device.createComputePipeline({ layout: 'auto', compute: {
        module: device.createShaderModule({ code }), entryPoint: 'main',
      } });
      const bindings = device.createBindGroup({ layout: pipeline.getBindGroupLayout(0), entries: [
        { binding: 0, resource: { buffer: data } },
      ] });
      device.queue.writeBuffer(data, 0, values);
      const encoder = device.createCommandEncoder();
      const pass = encoder.beginComputePass();
      pass.setPipeline(pipeline);
      pass.setBindGroup(0, bindings);
      pass.dispatchWorkgroups(Math.ceil(COUNT / policy.workgroupSize));
      pass.end();
      encoder.copyBufferToBuffer(data, 0, readback, 0, values.byteLength);
      device.queue.submit([encoder.finish()]);
      await readback.mapAsync(M.READ);
      const actual = new BigUint64Array(readback.getMappedRange());
      for (let i = 0; i < COUNT; i += 1) {
        const product = (values[i] & mask) * BigInt(mantissa);
        const expected = (shift < 0 ? product >> BigInt(-shift) : product << BigInt(shift)) & UINT64_MASK;
        assert.equal(actual[i], expected, `period=${period}, width=${width}, ticks=${values[i]}`);
      }
      readback.unmap();
      assert.equal(await device.popErrorScope(), null);
    }
  }
  console.log('ok: production timestamp shader matches exact BigInt conversion, masks, carry and overflow');
} finally {
  readback.destroy();
  data.destroy();
  device.destroy();
}

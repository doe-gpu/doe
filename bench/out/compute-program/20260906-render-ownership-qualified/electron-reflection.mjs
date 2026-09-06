// Exercise native reflection failures across the actual addon boundary.
import assert from 'node:assert/strict';
import { requestAdapter } from 'doe-gpu/native';
import { loadNativeAddon } from './native-addon-test-helper.js';

const device = await (await requestAdapter({ backend: process.platform === 'darwin' ? 'metal' : 'vulkan' })).requestDevice();
const addon = await loadNativeAddon();
const valid = device.createShaderModule({ code: '@compute @workgroup_size(1) fn main() {}' });
const invalid = device.createShaderModule({ code: 'not WGSL' });
try {
  assert.deepEqual(addon.shaderModuleGetBindings(valid._native), []);
  assert.throws(() => addon.shaderModuleGetBindingsForEntryPoint(valid._native, 'missing'),
    { code: 'DOE_SHADER_REFLECTION_ERROR' });
  assert.throws(() => addon.shaderModuleGetBindings(invalid._native),
    { code: 'DOE_SHADER_REFLECTION_ERROR' });
  assert.deepEqual(addon.shaderModuleGetBindingsForEntryPoint(valid._native, 'main'), []);
  assert((await invalid.getCompilationInfo()).messages.some((message) => message.type === 'error'));
  assert.deepEqual((await valid.getCompilationInfo()).messages, []);
  console.log('ok: native reflection rejects failures, preserves empty success, and keeps module diagnostics');
} finally {
  valid.destroy?.();
  invalid.destroy?.();
  device.destroy();
}

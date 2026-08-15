import { create, globals } from 'webgpu';

Object.assign(globalThis, globals);
const result = {
  schemaVersion: 2,
  capability: 'GPUDevice.onuncapturederror post-destroy lifecycle',
  setterAccepted: false,
  postDestroySetterAccepted: false,
  postDestroyClearAccepted: false,
  errors: [],
};
let device;
try {
  const adapter = await create([]).requestAdapter({ featureLevel: 'compatibility' });
  if (!adapter) throw new Error('provider returned no compatibility adapter');
  device = await adapter.requestDevice();
  device.onuncapturederror = () => {};
  result.setterAccepted = true;
  device.destroy();
  device.onuncapturederror = () => {};
  result.postDestroySetterAccepted = true;
  device.onuncapturederror = null;
  result.postDestroyClearAccepted = true;
} catch (error) {
  result.errors.push(`${error?.name ?? 'Error'}: ${error?.message ?? String(error)}`);
} finally {
  try { device?.destroy(); } catch {}
}
console.log(`DOE_VGPU_COMPATIBILITY_REPRO=${JSON.stringify(result)}`);
if (!result.setterAccepted
  || !result.postDestroySetterAccepted
  || !result.postDestroyClearAccepted) {
  process.exitCode = 1;
}

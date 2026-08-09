import { create, globals } from 'webgpu';

Object.assign(globalThis, globals);
const result = {
  schemaVersion: 1,
  capability: 'GPUDevice.onuncapturederror setter',
  setterAccepted: false,
  error: '',
};
let device;
try {
  const adapter = await create([]).requestAdapter({ featureLevel: 'compatibility' });
  if (!adapter) throw new Error('provider returned no compatibility adapter');
  device = await adapter.requestDevice();
  device.onuncapturederror = () => {};
  result.setterAccepted = true;
} catch (error) {
  result.error = `${error?.name ?? 'Error'}: ${error?.message ?? String(error)}`;
} finally {
  try { device?.destroy(); } catch {}
}
console.log(`DOE_VGPU_COMPATIBILITY_REPRO=${JSON.stringify(result)}`);
if (!result.setterAccepted) process.exitCode = 1;

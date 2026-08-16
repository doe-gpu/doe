import { create, globals } from 'webgpu';

Object.assign(globalThis, globals);
const navigatorRef = globalThis.navigator ?? {};
if (!globalThis.navigator) {
  Object.defineProperty(globalThis, 'navigator', {
    value: navigatorRef,
    configurable: true,
    writable: true,
  });
}
navigatorRef.gpu = create([]);

if (process.env.REQUIRE_WEBGPU === '1') {
  const adapter = await navigatorRef.gpu.requestAdapter();
  if (!adapter) throw new Error('governed evidence provider returned no adapter');
}

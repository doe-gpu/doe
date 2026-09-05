// Private provider registration for immutable native program recordings.
const NATIVE_PROGRAM_PROVIDERS = new WeakMap();

function registerNativeProgramProvider(device, provider) {
  NATIVE_PROGRAM_PROVIDERS.set(device, provider);
}

function nativeProgramProvider(device) {
  return NATIVE_PROGRAM_PROVIDERS.get(device);
}

export { registerNativeProgramProvider, nativeProgramProvider };

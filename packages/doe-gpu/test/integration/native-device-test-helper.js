// Shared native-device admission for integration entrypoints.

import { setupGlobals } from '../../src/index.js';

const SKIPPABLE_PROVIDER_FAILURE_REASON = 'native_addon_unavailable';

function isSkippableNativeAvailabilityError(error) {
  return error?.providerFailureReason === SKIPPABLE_PROVIDER_FAILURE_REASON;
}

function exitSkipped(label, reason) {
  console.log(`${label}: skipped (${reason})`);
  process.exit(0);
}

async function requestNativeDeviceOrSkip(label) {
  try {
    setupGlobals();
    const adapter = await navigator.gpu.requestAdapter();
    if (!adapter) {
      exitSkipped(label, 'GPU adapter unavailable');
    }
    return await adapter.requestDevice();
  } catch (error) {
    if (isSkippableNativeAvailabilityError(error)) {
      exitSkipped(label, 'native add-on unavailable');
    }
    throw error;
  }
}

export {
  isSkippableNativeAvailabilityError,
  requestNativeDeviceOrSkip,
};

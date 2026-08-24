import assert from 'node:assert/strict';

import {
  isSkippableNativeAvailabilityError,
} from '../integration/native-device-test-helper.js';

assert.equal(
  isSkippableNativeAvailabilityError({
    providerFailureReason: 'native_addon_unavailable',
  }),
  true,
);
assert.equal(
  isSkippableNativeAvailabilityError({
    providerFailureReason: 'runtime_library_unavailable',
  }),
  false,
);
assert.equal(
  isSkippableNativeAvailabilityError(new Error('native addon unavailable')),
  false,
);

console.log('native device test helper contract: ok');

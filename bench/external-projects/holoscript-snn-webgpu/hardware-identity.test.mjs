import assert from 'node:assert/strict';

import {
  adapterUsesSoftwareRenderer,
  classifyVulkanSummary,
} from './hardware-identity.mjs';

const mixedSummary = `
deviceType = PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU
deviceName = Radeon 8060S Graphics (RADV STRIX_HALO)
driverName = radv
deviceType = PHYSICAL_DEVICE_TYPE_CPU
deviceName = llvmpipe (LLVM 21.1.8, 256 bits)
driverName = llvmpipe
`;
const host = classifyVulkanSummary(mixedSummary, true, true);

assert.equal(host.physicalGpuAvailable, true);
assert.equal(host.softwareRendererAvailable, true);
assert.equal(host.hardwareEligible, true);
assert.equal(adapterUsesSoftwareRenderer({ vendor: 'AMD', isFallbackAdapter: false }), false);
assert.equal(adapterUsesSoftwareRenderer({ vendor: 'Mesa', device: 'llvmpipe' }), true);

process.stdout.write('HoloScript hardware identity classification passed\n');

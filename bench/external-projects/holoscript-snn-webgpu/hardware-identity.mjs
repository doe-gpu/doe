export function adapterUsesSoftwareRenderer(identity) {
  const joined = Object.values(identity).join(' ').toLowerCase();
  return identity.isFallbackAdapter || /llvmpipe|lavapipe|swiftshader|software/.test(joined);
}

export function classifyVulkanSummary(output, probeSucceeded, renderNodeReadWriteAccess) {
  const summaryLines = output
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => /deviceName|driverName|driverInfo|deviceType/i.test(line));
  const softwareRendererAvailable = /llvmpipe|lavapipe|swiftshader|software/i.test(output);
  const physicalGpuAvailable = /PHYSICAL_DEVICE_TYPE_(?:INTEGRATED|DISCRETE)_GPU/i.test(output);
  return {
    summaryLines,
    softwareRendererAvailable,
    physicalGpuAvailable,
    hardwareEligible: probeSucceeded && renderNodeReadWriteAccess && physicalGpuAvailable,
  };
}

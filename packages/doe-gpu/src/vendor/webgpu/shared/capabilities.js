const FEATURE_CORE_FEATURES_AND_LIMITS = 0x00000001;
const FEATURE_DEPTH_CLIP_CONTROL = 0x00000002;
const FEATURE_DEPTH32FLOAT_STENCIL8 = 0x00000003;
const FEATURE_TEXTURE_COMPRESSION_BC = 0x00000004;
const FEATURE_TEXTURE_COMPRESSION_BC_SLICED_3D = 0x00000005;
const FEATURE_TEXTURE_COMPRESSION_ETC2 = 0x00000006;
const FEATURE_TEXTURE_COMPRESSION_ASTC = 0x00000007;
const FEATURE_TEXTURE_COMPRESSION_ASTC_SLICED_3D = 0x00000008;
const FEATURE_TIMESTAMP_QUERY = 0x00000009;
const FEATURE_INDIRECT_FIRST_INSTANCE = 0x0000000A;
const FEATURE_SHADER_F16 = 0x0000000B;
const FEATURE_RG11B10UFLOAT_RENDERABLE = 0x0000000C;
const FEATURE_BGRA8UNORM_STORAGE = 0x0000000D;
const FEATURE_FLOAT32_FILTERABLE = 0x0000000E;
const FEATURE_FLOAT32_BLENDABLE = 0x0000000F;
const FEATURE_CLIP_DISTANCES = 0x00000010;
const FEATURE_DUAL_SOURCE_BLENDING = 0x00000011;
const FEATURE_SUBGROUPS = 0x00000012;
const FEATURE_TEXTURE_FORMATS_TIER1 = 0x00000013;
const FEATURE_TEXTURE_FORMATS_TIER2 = 0x00000014;
const FEATURE_PRIMITIVE_INDEX = 0x00000015;
const FEATURE_TEXTURE_COMPONENT_SWIZZLE = 0x00000016;

const SHADER_F16_FEATURE = FEATURE_SHADER_F16;

const KNOWN_FEATURES = Object.freeze([
  ['core-features-and-limits', FEATURE_CORE_FEATURES_AND_LIMITS],
  ['depth-clip-control', FEATURE_DEPTH_CLIP_CONTROL],
  ['depth32float-stencil8', FEATURE_DEPTH32FLOAT_STENCIL8],
  ['texture-compression-bc', FEATURE_TEXTURE_COMPRESSION_BC],
  ['texture-compression-bc-sliced-3d', FEATURE_TEXTURE_COMPRESSION_BC_SLICED_3D],
  ['texture-compression-etc2', FEATURE_TEXTURE_COMPRESSION_ETC2],
  ['texture-compression-astc', FEATURE_TEXTURE_COMPRESSION_ASTC],
  ['texture-compression-astc-sliced-3d', FEATURE_TEXTURE_COMPRESSION_ASTC_SLICED_3D],
  ['rg11b10ufloat-renderable', FEATURE_RG11B10UFLOAT_RENDERABLE],
  ['timestamp-query', FEATURE_TIMESTAMP_QUERY],
  ['bgra8unorm-storage', FEATURE_BGRA8UNORM_STORAGE],
  ['shader-f16', FEATURE_SHADER_F16],
  ['indirect-first-instance', FEATURE_INDIRECT_FIRST_INSTANCE],
  ['float32-filterable', FEATURE_FLOAT32_FILTERABLE],
  ['float32-blendable', FEATURE_FLOAT32_BLENDABLE],
  ['clip-distances', FEATURE_CLIP_DISTANCES],
  ['dual-source-blending', FEATURE_DUAL_SOURCE_BLENDING],
  ['subgroups', FEATURE_SUBGROUPS],
  ['texture-formats-tier1', FEATURE_TEXTURE_FORMATS_TIER1],
  ['texture-formats-tier2', FEATURE_TEXTURE_FORMATS_TIER2],
  ['primitive-index', FEATURE_PRIMITIVE_INDEX],
  ['texture-component-swizzle', FEATURE_TEXTURE_COMPONENT_SWIZZLE],
]);

const DOE_LIMITS = Object.freeze({
  maxTextureDimension1D: 16384,
  maxTextureDimension2D: 16384,
  maxTextureDimension3D: 2048,
  maxTextureArrayLayers: 2048,
  maxBindGroups: 4,
  maxBindGroupsPlusVertexBuffers: 24,
  maxBindingsPerBindGroup: 1000,
  maxDynamicUniformBuffersPerPipelineLayout: 8,
  maxDynamicStorageBuffersPerPipelineLayout: 4,
  maxSampledTexturesPerShaderStage: 16,
  maxSamplersPerShaderStage: 16,
  maxStorageBuffersPerShaderStage: 8,
  maxStorageTexturesPerShaderStage: 4,
  maxUniformBuffersPerShaderStage: 12,
  maxUniformBufferBindingSize: 65536,
  maxStorageBufferBindingSize: 134217728,
  minUniformBufferOffsetAlignment: 256,
  minStorageBufferOffsetAlignment: 32,
  maxVertexBuffers: 8,
  maxBufferSize: 268435456,
  maxVertexAttributes: 16,
  maxVertexBufferArrayStride: 2048,
  maxInterStageShaderVariables: 16,
  maxColorAttachments: 8,
  maxColorAttachmentBytesPerSample: 32,
  maxComputeWorkgroupStorageSize: 32768,
  maxComputeInvocationsPerWorkgroup: 1024,
  maxComputeWorkgroupSizeX: 1024,
  maxComputeWorkgroupSizeY: 1024,
  maxComputeWorkgroupSizeZ: 64,
  maxComputeWorkgroupsPerDimension: 65535,
  maxImmediateSize: 64,
  maxStorageBuffersInVertexStage: 8,
  maxStorageBuffersInFragmentStage: 8,
  maxStorageTexturesInVertexStage: 4,
  maxStorageTexturesInFragmentStage: 4,
});

const WEBGPU_DEFAULT_LIMITS = Object.freeze({
  maxTextureDimension1D: 8192,
  maxTextureDimension2D: 8192,
  maxTextureDimension3D: 2048,
  maxTextureArrayLayers: 256,
  maxBindGroups: 4,
  maxBindGroupsPlusVertexBuffers: 24,
  maxBindingsPerBindGroup: 1000,
  maxDynamicUniformBuffersPerPipelineLayout: 8,
  maxDynamicStorageBuffersPerPipelineLayout: 4,
  maxSampledTexturesPerShaderStage: 16,
  maxSamplersPerShaderStage: 16,
  maxStorageBuffersInFragmentStage: 8,
  maxStorageBuffersInVertexStage: 8,
  maxStorageBuffersPerShaderStage: 8,
  maxStorageTexturesInFragmentStage: 4,
  maxStorageTexturesInVertexStage: 4,
  maxStorageTexturesPerShaderStage: 4,
  maxUniformBuffersPerShaderStage: 12,
  maxUniformBufferBindingSize: 65536,
  maxStorageBufferBindingSize: 134217728,
  minUniformBufferOffsetAlignment: 256,
  minStorageBufferOffsetAlignment: 256,
  maxVertexBuffers: 8,
  maxBufferSize: 268435456,
  maxVertexAttributes: 16,
  maxVertexBufferArrayStride: 2048,
  maxInterStageShaderVariables: 16,
  maxColorAttachments: 8,
  maxColorAttachmentBytesPerSample: 32,
  maxComputeWorkgroupStorageSize: 16384,
  maxComputeInvocationsPerWorkgroup: 256,
  maxComputeWorkgroupSizeX: 256,
  maxComputeWorkgroupSizeY: 256,
  maxComputeWorkgroupSizeZ: 64,
  maxComputeWorkgroupsPerDimension: 65535,
  maxImmediateSize: 64,
});

const DOE_LIMIT_NAMES = Object.freeze(Object.keys(DOE_LIMITS));
const DOE_FEATURES = Object.freeze(new Set());
const ALIGNMENT_LIMIT_NAMES = Object.freeze(new Set([
  'minUniformBufferOffsetAlignment',
  'minStorageBufferOffsetAlignment',
]));

function featureSet(hasFeature) {
  const supported = [];
  for (const [name, value] of KNOWN_FEATURES) {
    if (hasFeature(value)) supported.push(name);
  }
  return supported.length === 0 ? DOE_FEATURES : Object.freeze(new Set(supported));
}

function isPublishedLimitValue(value) {
  return typeof value === 'number' && Number.isFinite(value) && value > 0;
}

function publishLimits(queried) {
  if (!queried || typeof queried !== 'object') {
    return DOE_LIMITS;
  }
  let sawNativeValue = false;
  const published = {};
  for (const name of DOE_LIMIT_NAMES) {
    const value = queried[name];
    if (isPublishedLimitValue(value)) {
      published[name] = ALIGNMENT_LIMIT_NAMES.has(name) ? value : Math.min(value, DOE_LIMITS[name]);
      sawNativeValue = true;
      continue;
    }
    published[name] = DOE_LIMITS[name];
  }
  return sawNativeValue ? Object.freeze(published) : DOE_LIMITS;
}

function publishFeatures(hasFeature) {
  if (typeof hasFeature !== 'function') {
    return DOE_FEATURES;
  }
  return featureSet(hasFeature);
}

export {
  FEATURE_DEPTH_CLIP_CONTROL,
  FEATURE_DEPTH32FLOAT_STENCIL8,
  FEATURE_TEXTURE_COMPRESSION_BC,
  FEATURE_TEXTURE_COMPRESSION_BC_SLICED_3D,
  FEATURE_TEXTURE_COMPRESSION_ETC2,
  FEATURE_TEXTURE_COMPRESSION_ASTC,
  FEATURE_TEXTURE_COMPRESSION_ASTC_SLICED_3D,
  FEATURE_RG11B10UFLOAT_RENDERABLE,
  FEATURE_TIMESTAMP_QUERY,
  FEATURE_BGRA8UNORM_STORAGE,
  FEATURE_SHADER_F16,
  FEATURE_INDIRECT_FIRST_INSTANCE,
  FEATURE_FLOAT32_FILTERABLE,
  FEATURE_SUBGROUPS,
  FEATURE_FLOAT32_BLENDABLE,
  FEATURE_CLIP_DISTANCES,
  FEATURE_DUAL_SOURCE_BLENDING,
  FEATURE_CORE_FEATURES_AND_LIMITS,
  FEATURE_TEXTURE_FORMATS_TIER1,
  FEATURE_TEXTURE_FORMATS_TIER2,
  FEATURE_PRIMITIVE_INDEX,
  FEATURE_TEXTURE_COMPONENT_SWIZZLE,
  SHADER_F16_FEATURE,
  KNOWN_FEATURES,
  DOE_LIMITS,
  WEBGPU_DEFAULT_LIMITS,
  DOE_LIMIT_NAMES,
  DOE_FEATURES,
  featureSet,
  publishLimits,
  publishFeatures,
};

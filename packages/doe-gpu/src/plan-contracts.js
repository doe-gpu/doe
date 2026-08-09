// Schema-derived constants for doe-gpu plan and capture contracts.

export const DOE_COMMAND_STREAM_KIND = 'doe_command_stream';
export const DOE_NORMALIZED_PLAN_SCHEMA_VERSION = 1;
export const DOE_WEBGPU_CAPTURE_GRAPH_ARTIFACT_KIND = 'doe_webgpu_capture_graph';
export const DOE_WEBGPU_CAPTURE_GRAPH_SCHEMA_VERSION = 1;
export const DOE_WEBGPU_CAPTURE_EVIDENCE_ARTIFACT_KIND = 'doe_webgpu_capture_evidence';
export const DOE_WEBGPU_CAPTURE_EVIDENCE_SCHEMA_VERSION = 1;
export const DOE_STREAM_GRAPH_ARTIFACT_KIND = 'doe_stream_graph';
export const DOE_STREAM_EXECUTION_PLAN_ARTIFACT_KIND = 'doe_stream_execution_plan';
export const DOE_CSL_HOST_PLAN_ARTIFACT_KIND = 'csl_host_plan';

export const DOE_CAPTURE_SUPPORTED_WEBGPU_METHODS = Object.freeze([
  'requestAdapter',
  'requestDevice',
  'device.createBuffer',
  'device.queue.writeBuffer',
  'device.createShaderModule',
  'device.createBindGroupLayout',
  'device.createPipelineLayout',
  'device.createComputePipeline',
  'device.createBindGroup',
  'device.createCommandEncoder',
  'encoder.beginComputePass',
  'pass.setPipeline',
  'pass.setBindGroup',
  'pass.dispatchWorkgroups',
  'pass.end',
  'encoder.copyBufferToBuffer',
  'encoder.finish',
  'queue.submit',
  'buffer.mapAsync',
  'buffer.getMappedRange',
  'buffer.unmap',
]);

export const DOE_CAPTURE_UNSUPPORTED_CSL_FEATURES = Object.freeze([
  'render_passes',
  'textures',
  'samplers',
  'atomics',
  'generic_subgroups',
  'host_branching_from_uncaptured_readback',
]);

export const DOE_CAPTURE_LOWERING_STAGES = Object.freeze([
  'capture',
  'wgsl_classification',
  'host_plan',
  'stream_plan',
  'sdk_layout_python',
  'csl_emit',
  'compile',
  'simulate',
  'hardware',
  'parity',
]);

export const DOE_CAPTURE_EVIDENCE_STATUSES = Object.freeze([
  'pass',
  'blocked',
  'pending',
  'not_attempted',
  'metadata_bound',
]);

export const DOE_PLAN_ARTIFACT_KINDS = Object.freeze([
  DOE_WEBGPU_CAPTURE_GRAPH_ARTIFACT_KIND,
  DOE_WEBGPU_CAPTURE_EVIDENCE_ARTIFACT_KIND,
  DOE_STREAM_GRAPH_ARTIFACT_KIND,
  DOE_STREAM_EXECUTION_PLAN_ARTIFACT_KIND,
  DOE_CSL_HOST_PLAN_ARTIFACT_KIND,
]);

export const DOE_PLAN_SCHEMA_VERSIONS = Object.freeze({
  [DOE_WEBGPU_CAPTURE_GRAPH_ARTIFACT_KIND]: DOE_WEBGPU_CAPTURE_GRAPH_SCHEMA_VERSION,
  [DOE_WEBGPU_CAPTURE_EVIDENCE_ARTIFACT_KIND]: DOE_WEBGPU_CAPTURE_EVIDENCE_SCHEMA_VERSION,
  [DOE_STREAM_GRAPH_ARTIFACT_KIND]: 1,
  [DOE_STREAM_EXECUTION_PLAN_ARTIFACT_KIND]: 1,
  [DOE_CSL_HOST_PLAN_ARTIFACT_KIND]: 3,
});

export const DOE_PLAN_ARTIFACT_CONTRACTS = Object.freeze({
  [DOE_WEBGPU_CAPTURE_EVIDENCE_ARTIFACT_KIND]: Object.freeze({
    required: Object.freeze([
      'schemaVersion',
      'artifactKind',
      'modelId',
      'sourceProgram',
      'destinations',
      'loweringStages',
      'verdict',
    ]),
    fields: Object.freeze([
      'schemaVersion',
      'artifactKind',
      'generatedAt',
      'modelId',
      'sourceProgram',
      'destinations',
      'loweringStages',
      'verdict',
    ]),
    closed: true,
    consts: Object.freeze({}),
    types: Object.freeze({
      generatedAt: 'string',
      modelId: 'string',
      sourceProgram: 'object',
      destinations: 'array',
      loweringStages: 'array',
      verdict: 'object',
    }),
  }),
  [DOE_STREAM_GRAPH_ARTIFACT_KIND]: Object.freeze({
    required: Object.freeze([
      'schemaVersion',
      'artifactKind',
      'target',
      'modelId',
      'residencyMode',
      'codeRegions',
      'streams',
      'prefetchSchedule',
      'kvPolicy',
      'compileArtifactCache',
    ]),
    fields: Object.freeze([
      'schemaVersion',
      'artifactKind',
      'target',
      'modelId',
      'residencyMode',
      'codeRegions',
      'streams',
      'prefetchSchedule',
      'kvPolicy',
      'compileArtifactCache',
      'validation',
    ]),
    closed: false,
    consts: Object.freeze({
      target: 'wse3',
      residencyMode: 'layer_streaming',
    }),
    types: Object.freeze({
      modelId: 'string',
      codeRegions: 'array',
      streams: 'array',
      prefetchSchedule: 'object',
      kvPolicy: 'object',
      compileArtifactCache: 'object',
      validation: 'object',
    }),
  }),
  [DOE_STREAM_EXECUTION_PLAN_ARTIFACT_KIND]: Object.freeze({
    required: Object.freeze([
      'schemaVersion',
      'artifactKind',
      'target',
      'modelId',
      'numTransformerLayers',
      'setupPhase',
      'perLayerSchedule',
      'prefetchPolicy',
      'kvPolicy',
      'steadyStatePayloadBytesPerLayer',
      'executorStatus',
    ]),
    fields: Object.freeze([
      'schemaVersion',
      'artifactKind',
      'target',
      'modelId',
      'numTransformerLayers',
      'setupPhase',
      'perLayerSchedule',
      'prefetchPolicy',
      'kvPolicy',
      'steadyStatePayloadBytesPerLayer',
      'executorStatus',
      'executorStatusReason',
      'source',
    ]),
    closed: false,
    consts: Object.freeze({ target: 'wse3' }),
    enums: Object.freeze({
      executorStatus: Object.freeze(['plan_only', 'executor_ready', 'executed']),
    }),
    types: Object.freeze({
      modelId: 'string',
      numTransformerLayers: 'integer',
      setupPhase: 'array',
      perLayerSchedule: 'array',
      prefetchPolicy: 'object',
      kvPolicy: 'object',
      steadyStatePayloadBytesPerLayer: 'integer',
      executorStatus: 'string',
      executorStatusReason: 'string',
      source: 'object',
    }),
  }),
  [DOE_CSL_HOST_PLAN_ARTIFACT_KIND]: Object.freeze({
    required: Object.freeze([
      'schemaVersion',
      'artifactKind',
      'target',
      'contract',
      'hostPlan',
      'compileTargets',
    ]),
    fields: Object.freeze([
      'schemaVersion',
      'artifactKind',
      'target',
      'contract',
      'hostPlan',
      'compileTargets',
      'cslc',
    ]),
    closed: true,
    consts: Object.freeze({
      target: 'wse3',
      contract: 'explicit_host_plan',
    }),
    types: Object.freeze({
      hostPlan: 'object',
      compileTargets: 'array',
      cslc: 'object',
    }),
  }),
});

export const DOE_NORMALIZED_PLAN_REQUIRED_FIELDS = Object.freeze([
  'schemaVersion',
  'planKind',
  'workloadId',
  'irPath',
  'irScenario',
  'commandCount',
  'bufferWriteCount',
  'dispatchCount',
  'sourceIrSha256',
  'compatibilityCommandsSha256',
  'commands',
]);

export const DOE_NORMALIZED_PLAN_FIELDS = Object.freeze([
  ...DOE_NORMALIZED_PLAN_REQUIRED_FIELDS,
  'description',
  'planPath',
  'commandsPath',
  'matmulGemvVariant',
  'bufferLoadCount',
  'planSha256',
]);

export const DOE_CAPTURE_GRAPH_ARRAY_FIELDS = Object.freeze([
  'supportedWebgpuMethods',
  'unsupportedCslFeatures',
  'buffers',
  'bufferEvents',
  'bufferWrites',
  'shaderModules',
  'bindGroupLayouts',
  'pipelineLayouts',
  'computePipelines',
  'bindGroups',
  'commandEncoders',
  'commandBuffers',
  'submissions',
  'readbacks',
  'unsupported',
]);

export const DOE_CAPTURE_GRAPH_FIELDS = Object.freeze([
  'schemaVersion',
  'artifactKind',
  'provider',
  'metadata',
  ...DOE_CAPTURE_GRAPH_ARRAY_FIELDS,
  'graphSha256',
]);

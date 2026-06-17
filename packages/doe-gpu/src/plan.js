// doe-gpu/plan - JSON command and execution plan contracts.

import { globals as webgpuGlobals } from './vendor/webgpu/webgpu-constants.js';

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
  [DOE_CSL_HOST_PLAN_ARTIFACT_KIND]: 2,
});

export const globals = webgpuGlobals;
export const GPUBufferUsage = globals.GPUBufferUsage;
export const GPUShaderStage = globals.GPUShaderStage;
export const GPUMapMode = globals.GPUMapMode;
export const GPUTextureUsage = globals.GPUTextureUsage;

const CAPTURE_REF = Symbol('doeCaptureRef');
const CAPTURE_SHADER_F16_FEATURE = 'shader-f16';
const BYTES_PER_GIB = 1024 ** 3;
const CAPTURE_MAX_BUFFER_SIZE_BYTES = 8 * BYTES_PER_GIB;
const CAPTURE_MAX_STORAGE_BUFFER_BINDING_SIZE_BYTES = 2 * BYTES_PER_GIB;
const CAPTURE_MAX_COMPUTE_WORKGROUP_SIZE_X = 1024;
const CAPTURE_MAX_COMPUTE_WORKGROUP_SIZE_Y = 1024;
const CAPTURE_MAX_COMPUTE_WORKGROUP_SIZE_Z = 64;
const CAPTURE_MAX_COMPUTE_INVOCATIONS_PER_WORKGROUP = 1024;
const CAPTURE_MAX_COMPUTE_WORKGROUP_STORAGE_SIZE = 32 * 1024;
const CAPTURE_MAX_STORAGE_BUFFERS_PER_SHADER_STAGE = 32;
const CAPTURE_MAX_UNIFORM_BUFFER_BINDING_SIZE = 64 * 1024;
const CAPTURE_MAX_COMPUTE_WORKGROUPS_PER_DIMENSION = 65535;

const CAPTURE_LIMITS = Object.freeze({
  maxBufferSize: CAPTURE_MAX_BUFFER_SIZE_BYTES,
  maxStorageBufferBindingSize: CAPTURE_MAX_STORAGE_BUFFER_BINDING_SIZE_BYTES,
  maxComputeWorkgroupSizeX: CAPTURE_MAX_COMPUTE_WORKGROUP_SIZE_X,
  maxComputeWorkgroupSizeY: CAPTURE_MAX_COMPUTE_WORKGROUP_SIZE_Y,
  maxComputeWorkgroupSizeZ: CAPTURE_MAX_COMPUTE_WORKGROUP_SIZE_Z,
  maxComputeInvocationsPerWorkgroup: CAPTURE_MAX_COMPUTE_INVOCATIONS_PER_WORKGROUP,
  maxComputeWorkgroupStorageSize: CAPTURE_MAX_COMPUTE_WORKGROUP_STORAGE_SIZE,
  maxStorageBuffersPerShaderStage: CAPTURE_MAX_STORAGE_BUFFERS_PER_SHADER_STAGE,
  maxUniformBufferBindingSize: CAPTURE_MAX_UNIFORM_BUFFER_BINDING_SIZE,
  maxComputeWorkgroupsPerDimension: CAPTURE_MAX_COMPUTE_WORKGROUPS_PER_DIMENSION,
});

const CAPTURE_ADAPTER_INFO = Object.freeze({
  vendor: 'Doe',
  architecture: 'capture',
  device: 'WebGPU capture provider',
  description: 'Doe record-only WebGPU provider',
});

const CAPTURE_FEATURES = Object.freeze([CAPTURE_SHADER_F16_FEATURE]);
const CAPTURE_GRAPH_ARRAY_FIELDS = Object.freeze([
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

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function pushError(errors, path, message) {
  errors.push({ path, message });
}

function validateCommand(command, index, errors) {
  const path = `commands[${index}]`;
  if (!isObject(command)) {
    pushError(errors, path, 'command must be an object');
    return;
  }
  if (typeof command.kind !== 'string' || command.kind.length === 0) {
    pushError(errors, `${path}.kind`, 'kind must be a non-empty string');
  }
}

export function validateCommandStream(commands) {
  const errors = [];
  if (!Array.isArray(commands)) {
    pushError(errors, 'commands', 'command stream must be an array');
  } else {
    commands.forEach((command, index) => validateCommand(command, index, errors));
  }
  return {
    ok: errors.length === 0,
    kind: DOE_COMMAND_STREAM_KIND,
    commandCount: Array.isArray(commands) ? commands.length : 0,
    errors,
  };
}

export function assertCommandStream(commands) {
  const result = validateCommandStream(commands);
  if (!result.ok) {
    throw new Error(`Invalid Doe command stream: ${result.errors[0].path} ${result.errors[0].message}`);
  }
  return commands;
}

export function validateNormalizedPlan(plan) {
  const errors = [];
  if (!isObject(plan)) {
    pushError(errors, 'plan', 'normalized plan must be an object');
  } else {
    if (plan.schemaVersion !== DOE_NORMALIZED_PLAN_SCHEMA_VERSION) {
      pushError(errors, 'plan.schemaVersion', `schemaVersion must be ${DOE_NORMALIZED_PLAN_SCHEMA_VERSION}`);
    }
    if (typeof plan.planKind !== 'string' || plan.planKind.length === 0) {
      pushError(errors, 'plan.planKind', 'planKind must be a non-empty string');
    }
    if (typeof plan.workloadId !== 'string' || plan.workloadId.length === 0) {
      pushError(errors, 'plan.workloadId', 'workloadId must be a non-empty string');
    }
    const commandResult = validateCommandStream(plan.commands);
    for (const error of commandResult.errors) {
      pushError(errors, `plan.${error.path}`, error.message);
    }
  }
  return {
    ok: errors.length === 0,
    kind: 'doe_normalized_plan',
    schemaVersion: isObject(plan) ? plan.schemaVersion : undefined,
    errors,
  };
}

export function assertNormalizedPlan(plan) {
  const result = validateNormalizedPlan(plan);
  if (!result.ok) {
    throw new Error(`Invalid Doe normalized plan: ${result.errors[0].path} ${result.errors[0].message}`);
  }
  return plan;
}

export function validatePlanArtifact(artifact) {
  const errors = [];
  if (!isObject(artifact)) {
    pushError(errors, 'artifact', 'plan artifact must be an object');
  } else {
    const expectedVersion = DOE_PLAN_SCHEMA_VERSIONS[artifact.artifactKind];
    if (typeof artifact.artifactKind !== 'string' || expectedVersion == null) {
      pushError(errors, 'artifact.artifactKind', `artifactKind must be one of: ${DOE_PLAN_ARTIFACT_KINDS.join(', ')}`);
    } else if (artifact.schemaVersion !== expectedVersion) {
      pushError(errors, 'artifact.schemaVersion', `schemaVersion must be ${expectedVersion} for ${artifact.artifactKind}`);
    } else if (artifact.artifactKind === DOE_WEBGPU_CAPTURE_GRAPH_ARTIFACT_KIND) {
      const captureResult = validateCaptureGraph(artifact);
      for (const error of captureResult.errors) {
        pushError(errors, error.path, error.message);
      }
    }
  }
  return {
    ok: errors.length === 0,
    artifactKind: isObject(artifact) ? artifact.artifactKind : undefined,
    schemaVersion: isObject(artifact) ? artifact.schemaVersion : undefined,
    errors,
  };
}

export function assertPlanArtifact(artifact) {
  const result = validatePlanArtifact(artifact);
  if (!result.ok) {
    throw new Error(`Invalid Doe plan artifact: ${result.errors[0].path} ${result.errors[0].message}`);
  }
  return artifact;
}

export function validateCaptureGraph(graph) {
  const errors = [];
  if (!isObject(graph)) {
    pushError(errors, 'artifact', 'capture graph must be an object');
  } else {
    if (graph.schemaVersion !== DOE_WEBGPU_CAPTURE_GRAPH_SCHEMA_VERSION) {
      pushError(
        errors,
        'artifact.schemaVersion',
        `schemaVersion must be ${DOE_WEBGPU_CAPTURE_GRAPH_SCHEMA_VERSION}`
      );
    }
    if (graph.artifactKind !== DOE_WEBGPU_CAPTURE_GRAPH_ARTIFACT_KIND) {
      pushError(
        errors,
        'artifact.artifactKind',
        `artifactKind must be ${DOE_WEBGPU_CAPTURE_GRAPH_ARTIFACT_KIND}`
      );
    }
    if (!isObject(graph.provider)) {
      pushError(errors, 'artifact.provider', 'provider must be an object');
    }
    if (!isObject(graph.metadata)) {
      pushError(errors, 'artifact.metadata', 'metadata must be an object');
    }
    for (const field of CAPTURE_GRAPH_ARRAY_FIELDS) {
      if (!Array.isArray(graph[field])) {
        pushError(errors, `artifact.${field}`, `${field} must be an array`);
      }
    }
    if (graph.graphSha256 !== undefined) {
      if (
        typeof graph.graphSha256 !== 'string' ||
        !/^[0-9a-f]{64}$/.test(graph.graphSha256)
      ) {
        pushError(
          errors,
          'artifact.graphSha256',
          'graphSha256 must be a 64-character lowercase hex SHA-256'
        );
      }
    }
  }
  return {
    ok: errors.length === 0,
    artifactKind: isObject(graph) ? graph.artifactKind : undefined,
    schemaVersion: isObject(graph) ? graph.schemaVersion : undefined,
    errors,
  };
}

export function assertCaptureGraph(graph) {
  const result = validateCaptureGraph(graph);
  if (!result.ok) {
    throw new Error(`Invalid Doe capture graph: ${result.errors[0].path} ${result.errors[0].message}`);
  }
  return graph;
}

export function classifyPlan(value) {
  if (Array.isArray(value)) {
    return validateCommandStream(value);
  }
  if (isObject(value) && Array.isArray(value.commands)) {
    return validateNormalizedPlan(value);
  }
  return validatePlanArtifact(value);
}

function captureRef(kind, id) {
  return { kind, id };
}

function markCaptureObject(object, kind, id) {
  Object.defineProperty(object, CAPTURE_REF, {
    value: captureRef(kind, id),
    enumerable: false,
  });
  return object;
}

function readCaptureRef(value, expectedKind, label) {
  const ref = value?.[CAPTURE_REF];
  if (!ref || (expectedKind && ref.kind !== expectedKind)) {
    throw new Error(`${label} must be a Doe capture ${expectedKind ?? 'object'}.`);
  }
  return ref;
}

function cloneDescriptor(value) {
  if (value == null || typeof value !== 'object') {
    return value;
  }
  const ref = value[CAPTURE_REF];
  if (ref) {
    return { ref: `${ref.kind}:${ref.id}`, kind: ref.kind, id: ref.id };
  }
  if (ArrayBuffer.isView(value)) {
    return {
      type: value.constructor?.name ?? 'ArrayBufferView',
      byteLength: value.byteLength,
    };
  }
  if (value instanceof ArrayBuffer) {
    return {
      type: 'ArrayBuffer',
      byteLength: value.byteLength,
    };
  }
  if (Array.isArray(value)) {
    return value.map(cloneDescriptor);
  }
  const copy = {};
  for (const [key, item] of Object.entries(value)) {
    if (typeof item !== 'function') {
      copy[key] = cloneDescriptor(item);
    }
  }
  return copy;
}

function normalizePositiveDimension(value, label) {
  const dimension = value ?? 1;
  if (!Number.isInteger(dimension) || dimension < 1) {
    throw new Error(`${label} must be a positive integer.`);
  }
  return dimension;
}

function bytesFromWriteData(data, dataOffset = 0, size = undefined) {
  let bytes;
  if (ArrayBuffer.isView(data)) {
    bytes = new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
  } else if (data instanceof ArrayBuffer) {
    bytes = new Uint8Array(data);
  } else {
    throw new Error('queue.writeBuffer data must be an ArrayBuffer or ArrayBufferView.');
  }
  const start = dataOffset ?? 0;
  if (!Number.isInteger(start) || start < 0 || start > bytes.byteLength) {
    throw new Error('queue.writeBuffer dataOffset must be a valid byte offset.');
  }
  const length = size == null ? bytes.byteLength - start : size;
  if (!Number.isInteger(length) || length < 0 || start + length > bytes.byteLength) {
    throw new Error('queue.writeBuffer size must fit within data.');
  }
  return bytes.slice(start, start + length);
}

function stableStringify(value) {
  if (value === null) return 'null';
  const type = typeof value;
  if (type === 'number' || type === 'boolean') return JSON.stringify(value);
  if (type === 'string') return JSON.stringify(value);
  if (Array.isArray(value)) {
    return `[${value.map(stableStringify).join(',')}]`;
  }
  if (isObject(value)) {
    const entries = Object.keys(value)
      .filter((key) => value[key] !== undefined)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`);
    return `{${entries.join(',')}}`;
  }
  return 'null';
}

async function sha256Bytes(bytes) {
  if (globalThis.crypto?.subtle) {
    const digest = await globalThis.crypto.subtle.digest('SHA-256', bytes);
    return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('');
  }
  const crypto = await import('node:crypto');
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

async function sha256Text(text) {
  return sha256Bytes(new TextEncoder().encode(text));
}

function unsupported(graph, method, reason) {
  graph.unsupported.push({ method, reason });
  throw new Error(`Doe capture provider does not support ${method}: ${reason}`);
}

function sha256Urn(value) {
  if (typeof value !== 'string' || value.length === 0) {
    return null;
  }
  return value.startsWith('sha256:') ? value : `sha256:${value}`;
}

function parseWgslWorkgroupSize(code) {
  if (typeof code !== 'string') {
    return null;
  }
  const match = code.match(/@workgroup_size\s*\(\s*(\d+)(?:\s*,\s*(\d+))?(?:\s*,\s*(\d+))?\s*\)/u);
  if (!match) {
    return null;
  }
  return [
    Number(match[1]),
    Number(match[2] ?? 1),
    Number(match[3] ?? 1),
  ];
}

export function collectCaptureDispatchShaderEvidence(graph) {
  const shaderModulesSource = Array.isArray(graph?.shaderModules) ? graph.shaderModules : [];
  const computePipelines = Array.isArray(graph?.computePipelines) ? graph.computePipelines : [];
  const commandBuffers = Array.isArray(graph?.commandBuffers) ? graph.commandBuffers : [];
  const readbacks = Array.isArray(graph?.readbacks) ? graph.readbacks : [];
  const missing = [];
  const modulesById = new Map(shaderModulesSource.map((module) => [module.id, module]));
  const pipelinesById = new Map(computePipelines.map((pipeline) => [pipeline.id, pipeline]));
  const shaderModules = shaderModulesSource.map((module) => {
    const sourceSha256 = sha256Urn(module.wgslSha256);
    const workgroupSize = parseWgslWorkgroupSize(module.code);
    if (!sourceSha256) {
      missing.push({
        field: 'shaderModules.sourceSha256',
        moduleId: module.id,
        reason: 'materialized_shader_hash_unavailable',
      });
    }
    if (!workgroupSize) {
      missing.push({
        field: 'shaderModules.workgroupSize',
        moduleId: module.id,
        reason: 'workgroup_size_unavailable',
      });
    }
    missing.push({
      field: 'shaderModules.sourcePath',
      moduleId: module.id,
      reason: 'capture_graph_source_path_unavailable',
    });
    return {
      moduleId: String(module.id),
      sourcePath: null,
      sourceSha256,
      entryPoint: null,
      workgroupSize,
    };
  });
  const dispatches = [];
  for (const commandBuffer of commandBuffers) {
    for (const command of commandBuffer.commands ?? []) {
      if (command?.kind !== 'beginComputePass') {
        continue;
      }
      for (const passCommand of command.commands ?? []) {
        if (passCommand?.kind !== 'dispatchWorkgroups') {
          continue;
        }
        const pipeline = pipelinesById.get(passCommand.pipeline) ?? null;
        const shaderModule = pipeline ? modulesById.get(pipeline.module) : null;
        dispatches.push({
          dispatchIndex: dispatches.length,
          pipelineId: pipeline ? String(pipeline.id) : null,
          shaderModuleId: shaderModule ? String(shaderModule.id) : null,
          entryPoint: pipeline?.entryPoint ?? null,
          workgroups: [
            Number(passCommand.x ?? 1),
            Number(passCommand.y ?? 1),
            Number(passCommand.z ?? 1),
          ],
        });
      }
    }
  }
  const digestReadback = [...readbacks]
    .reverse()
    .find((readback) => typeof readback?.sha256 === 'string' && readback.sha256);
  const outputDigest = sha256Urn(digestReadback?.sha256);
  if (!outputDigest) {
    missing.push({
      field: 'outputDigest',
      reason: 'readback_digest_unavailable',
    });
  }
  return Object.freeze({
    shaderModules,
    dispatches,
    outputDigest,
    ...(missing.length > 0 ? { missing } : {}),
  });
}

export function createCaptureProvider(options = {}) {
  let nextId = 1;
  const graph = {
    schemaVersion: DOE_WEBGPU_CAPTURE_GRAPH_SCHEMA_VERSION,
    artifactKind: DOE_WEBGPU_CAPTURE_GRAPH_ARTIFACT_KIND,
    provider: {
      name: 'doe-gpu/plan',
      mode: 'capture',
      contract: 'webgpu-capture-provider',
    },
    metadata: cloneDescriptor(options.metadata ?? {}),
    supportedWebgpuMethods: [...DOE_CAPTURE_SUPPORTED_WEBGPU_METHODS],
    unsupportedCslFeatures: [...DOE_CAPTURE_UNSUPPORTED_CSL_FEATURES],
    buffers: [],
    bufferEvents: [],
    bufferWrites: [],
    shaderModules: [],
    bindGroupLayouts: [],
    pipelineLayouts: [],
    computePipelines: [],
    bindGroups: [],
    commandEncoders: [],
    commandBuffers: [],
    submissions: [],
    readbacks: [],
    unsupported: [],
  };

  function allocateId() {
    return nextId++;
  }

  function record(type, recordValue) {
    graph[type].push(recordValue);
    return recordValue;
  }

  function createBuffer(descriptor = {}) {
    const id = allocateId();
    const size = descriptor.size ?? 0;
    if (!Number.isInteger(size) || size < 0) {
      throw new Error('device.createBuffer descriptor.size must be a non-negative integer.');
    }
    const usage = descriptor.usage ?? 0;
    const buffer = {
      label: descriptor.label ?? '',
      size,
      usage,
      mapState: descriptor.mappedAtCreation ? 'mapped' : 'unmapped',
      async mapAsync(mode, offset = 0, mapSize = size - offset) {
        record('readbacks', {
          id: allocateId(),
          buffer: id,
          mode,
          offset,
          size: mapSize,
          checkpoint: true,
        });
        this.mapState = 'mapped';
      },
      getMappedRange(offset = 0, mappedSize = size - offset) {
        return new ArrayBuffer(mappedSize);
      },
      unmap() {
        this.mapState = 'unmapped';
      },
      destroy() {
        record('bufferEvents', {
          id: allocateId(),
          kind: 'buffer_destroy',
          buffer: id,
        });
      },
    };
    markCaptureObject(buffer, 'buffer', id);
    record('buffers', {
      id,
      label: descriptor.label ?? null,
      size,
      usage,
      mappedAtCreation: Boolean(descriptor.mappedAtCreation),
      descriptor: cloneDescriptor(descriptor),
    });
    return buffer;
  }

  function createShaderModule(descriptor = {}) {
    if (typeof descriptor.code !== 'string' || descriptor.code.length === 0) {
      throw new Error('device.createShaderModule descriptor.code must be a non-empty WGSL string.');
    }
    const id = allocateId();
    const module = { label: descriptor.label ?? '' };
    markCaptureObject(module, 'shaderModule', id);
    record('shaderModules', {
      id,
      label: descriptor.label ?? null,
      code: descriptor.code,
      hints: cloneDescriptor(descriptor.hints ?? null),
    });
    return module;
  }

  function createBindGroupLayout(descriptor = {}) {
    const id = allocateId();
    const layout = { label: descriptor.label ?? '' };
    markCaptureObject(layout, 'bindGroupLayout', id);
    record('bindGroupLayouts', {
      id,
      label: descriptor.label ?? null,
      entries: cloneDescriptor(descriptor.entries ?? []),
    });
    return layout;
  }

  function createPipelineLayout(descriptor = {}) {
    const id = allocateId();
    const layout = { label: descriptor.label ?? '' };
    markCaptureObject(layout, 'pipelineLayout', id);
    record('pipelineLayouts', {
      id,
      label: descriptor.label ?? null,
      bindGroupLayouts: cloneDescriptor(descriptor.bindGroupLayouts ?? []),
    });
    return layout;
  }

  function createComputePipeline(descriptor = {}) {
    const moduleRef = readCaptureRef(
      descriptor.compute?.module,
      'shaderModule',
      'device.createComputePipeline descriptor.compute.module'
    );
    const id = allocateId();
    const pipeline = {
      label: descriptor.label ?? '',
      getBindGroupLayout(index) {
        if (!Number.isInteger(index) || index < 0) {
          throw new Error('pipeline.getBindGroupLayout index must be a non-negative integer.');
        }
        const layoutId = allocateId();
        const layout = { label: `${descriptor.label ?? 'pipeline'}_auto_bind_group_${index}` };
        markCaptureObject(layout, 'bindGroupLayout', layoutId);
        record('bindGroupLayouts', {
          id: layoutId,
          label: layout.label,
          entries: [],
          derivedFromPipeline: id,
          bindGroupIndex: index,
        });
        return layout;
      },
    };
    markCaptureObject(pipeline, 'computePipeline', id);
    record('computePipelines', {
      id,
      label: descriptor.label ?? null,
      layout: cloneDescriptor(descriptor.layout ?? 'auto'),
      module: moduleRef.id,
      entryPoint: descriptor.compute?.entryPoint ?? 'main',
      constants: cloneDescriptor(descriptor.compute?.constants ?? null),
    });
    return pipeline;
  }

  function createBindGroup(descriptor = {}) {
    const id = allocateId();
    const bindGroup = { label: descriptor.label ?? '' };
    markCaptureObject(bindGroup, 'bindGroup', id);
    record('bindGroups', {
      id,
      label: descriptor.label ?? null,
      layout: cloneDescriptor(descriptor.layout),
      entries: cloneDescriptor(descriptor.entries ?? []),
    });
    return bindGroup;
  }

  function createCommandEncoder(descriptor = {}) {
    const id = allocateId();
    const commands = [];
    const encoder = {
      label: descriptor.label ?? '',
      beginComputePass(passDescriptor = {}) {
        const passId = allocateId();
        const passCommands = [];
        const state = {
          pipeline: null,
          bindGroups: new Map(),
        };
        commands.push({
          kind: 'beginComputePass',
          pass: passId,
          descriptor: cloneDescriptor(passDescriptor),
          commands: passCommands,
        });
        return {
          setPipeline(pipeline) {
            const ref = readCaptureRef(pipeline, 'computePipeline', 'pass.setPipeline pipeline');
            state.pipeline = ref.id;
            passCommands.push({ kind: 'setPipeline', pipeline: ref.id });
          },
          setBindGroup(index, bindGroup, dynamicOffsets = []) {
            if (!Number.isInteger(index) || index < 0) {
              throw new Error('pass.setBindGroup index must be a non-negative integer.');
            }
            const ref = readCaptureRef(bindGroup, 'bindGroup', 'pass.setBindGroup bindGroup');
            state.bindGroups.set(index, ref.id);
            passCommands.push({
              kind: 'setBindGroup',
              index,
              bindGroup: ref.id,
              dynamicOffsets: cloneDescriptor(dynamicOffsets),
            });
          },
          dispatchWorkgroups(x, y = 1, z = 1) {
            if (state.pipeline == null) {
              throw new Error('pass.dispatchWorkgroups requires a pipeline.');
            }
            const command = {
              kind: 'dispatchWorkgroups',
              pipeline: state.pipeline,
              bindGroups: [...state.bindGroups.entries()]
                .sort(([left], [right]) => left - right)
                .map(([index, bindGroup]) => ({ index, bindGroup })),
              x: normalizePositiveDimension(x, 'pass.dispatchWorkgroups x'),
              y: normalizePositiveDimension(y, 'pass.dispatchWorkgroups y'),
              z: normalizePositiveDimension(z, 'pass.dispatchWorkgroups z'),
            };
            passCommands.push(command);
          },
          end() {
            passCommands.push({ kind: 'endComputePass' });
          },
        };
      },
      copyBufferToBuffer(source, sourceOffset, target, targetOffset, size) {
        const sourceRef = readCaptureRef(source, 'buffer', 'encoder.copyBufferToBuffer source');
        const targetRef = readCaptureRef(target, 'buffer', 'encoder.copyBufferToBuffer target');
        commands.push({
          kind: 'copyBufferToBuffer',
          source: sourceRef.id,
          sourceOffset,
          target: targetRef.id,
          targetOffset,
          size,
        });
      },
      finish(finishDescriptor = {}) {
        const commandBufferId = allocateId();
        const commandBuffer = { label: finishDescriptor.label ?? '' };
        markCaptureObject(commandBuffer, 'commandBuffer', commandBufferId);
        record('commandBuffers', {
          id: commandBufferId,
          encoder: id,
          descriptor: cloneDescriptor(finishDescriptor),
          commands: cloneDescriptor(commands),
        });
        return commandBuffer;
      },
    };
    markCaptureObject(encoder, 'commandEncoder', id);
    record('commandEncoders', {
      id,
      label: descriptor.label ?? null,
      descriptor: cloneDescriptor(descriptor),
    });
    return encoder;
  }

  const queue = {
    writeBuffer(buffer, bufferOffset, data, dataOffset = 0, size = undefined) {
      const ref = readCaptureRef(buffer, 'buffer', 'queue.writeBuffer buffer');
      const bytes = bytesFromWriteData(data, dataOffset, size);
      record('bufferWrites', {
        id: allocateId(),
        buffer: ref.id,
        bufferOffset,
        byteLength: bytes.byteLength,
        _bytes: bytes,
      });
    },
    submit(commandBuffers) {
      if (!Array.isArray(commandBuffers)) {
        throw new Error('queue.submit commandBuffers must be an array.');
      }
      record('submissions', {
        id: allocateId(),
        commandBuffers: commandBuffers.map((commandBuffer) =>
          readCaptureRef(commandBuffer, 'commandBuffer', 'queue.submit commandBuffer').id
        ),
      });
    },
    async onSubmittedWorkDone() {},
  };

  const device = {
    label: options.deviceLabel ?? 'Doe capture device',
    features: new Set(CAPTURE_FEATURES),
    limits: { ...CAPTURE_LIMITS },
    queue,
    lost: new Promise(() => {}),
    createBuffer,
    createShaderModule,
    createBindGroupLayout,
    createPipelineLayout,
    createComputePipeline,
    createComputePipelineAsync(descriptor) {
      return Promise.resolve(createComputePipeline(descriptor));
    },
    createBindGroup,
    createCommandEncoder,
    createTexture() {
      return unsupported(graph, 'device.createTexture', 'textures are not lowerable to CSL yet');
    },
    createSampler() {
      return unsupported(graph, 'device.createSampler', 'samplers are not lowerable to CSL yet');
    },
    createRenderPipeline() {
      return unsupported(graph, 'device.createRenderPipeline', 'render pipelines are not part of the CSL capture subset');
    },
    createRenderPipelineAsync() {
      graph.unsupported.push({
        method: 'device.createRenderPipelineAsync',
        reason: 'render pipelines are not part of the CSL capture subset',
      });
      return Promise.reject(
        new Error('Doe capture provider does not support device.createRenderPipelineAsync: render pipelines are not part of the CSL capture subset')
      );
    },
    destroy() {},
  };

  const adapter = {
    features: new Set(CAPTURE_FEATURES),
    limits: { ...CAPTURE_LIMITS },
    info: { ...CAPTURE_ADAPTER_INFO },
    async requestDevice() {
      return device;
    },
  };

  async function materializeGraph() {
    const shaderModules = await Promise.all(graph.shaderModules.map(async (module) => ({
      ...module,
      wgslSha256: await sha256Text(module.code),
    })));
    const bufferWrites = await Promise.all(graph.bufferWrites.map(async (write) => {
      const { _bytes, ...publicWrite } = write;
      return {
        ...publicWrite,
        dataSha256: await sha256Bytes(_bytes),
      };
    }));
    const materialized = {
      ...graph,
      shaderModules,
      bufferWrites,
    };
    materialized.graphSha256 = await sha256Text(stableStringify(materialized));
    return materialized;
  }

  function currentGraph() {
    return {
      ...graph,
      shaderModules: graph.shaderModules.map((module) => ({ ...module })),
      bufferWrites: graph.bufferWrites.map(({ _bytes, ...write }) => ({ ...write })),
    };
  }

  return {
    kind: 'doe_capture_provider',
    graph: currentGraph,
    snapshot: materializeGraph,
    async requestAdapter() {
      return adapter;
    },
    async requestDevice() {
      return device;
    },
  };
}

const defaultCaptureProvider = createCaptureProvider();

export const requestAdapter = defaultCaptureProvider.requestAdapter;
export const requestDevice = defaultCaptureProvider.requestDevice;
export const snapshotCaptureGraph = defaultCaptureProvider.snapshot;
export const captureGraph = defaultCaptureProvider.graph;
export const gpu = Object.freeze({ requestAdapter });
export const webgpu = gpu;

export default {
  DOE_COMMAND_STREAM_KIND,
  DOE_NORMALIZED_PLAN_SCHEMA_VERSION,
  DOE_WEBGPU_CAPTURE_GRAPH_ARTIFACT_KIND,
  DOE_WEBGPU_CAPTURE_GRAPH_SCHEMA_VERSION,
  DOE_WEBGPU_CAPTURE_EVIDENCE_ARTIFACT_KIND,
  DOE_WEBGPU_CAPTURE_EVIDENCE_SCHEMA_VERSION,
  DOE_STREAM_GRAPH_ARTIFACT_KIND,
  DOE_STREAM_EXECUTION_PLAN_ARTIFACT_KIND,
  DOE_CSL_HOST_PLAN_ARTIFACT_KIND,
  DOE_CAPTURE_SUPPORTED_WEBGPU_METHODS,
  DOE_CAPTURE_UNSUPPORTED_CSL_FEATURES,
  DOE_CAPTURE_LOWERING_STAGES,
  DOE_CAPTURE_EVIDENCE_STATUSES,
  DOE_PLAN_ARTIFACT_KINDS,
  DOE_PLAN_SCHEMA_VERSIONS,
  globals,
  GPUBufferUsage,
  GPUShaderStage,
  GPUMapMode,
  GPUTextureUsage,
  validateCommandStream,
  assertCommandStream,
  validateNormalizedPlan,
  assertNormalizedPlan,
  validatePlanArtifact,
  assertPlanArtifact,
  validateCaptureGraph,
  assertCaptureGraph,
  classifyPlan,
  createCaptureProvider,
  requestAdapter,
  requestDevice,
  snapshotCaptureGraph,
  captureGraph,
  gpu,
  webgpu,
};

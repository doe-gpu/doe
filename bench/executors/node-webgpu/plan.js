import { createHash } from 'node:crypto';
import { existsSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { basename, extname, resolve } from 'node:path';
import { normalizeDeterminismConfig } from './determinism.js';
import { readSyntheticAssetData } from './synthetic-assets.js';

const ALLOWED_BUFFER_USAGES = new Set([
  'storage',
  'copy_dst',
  'copy_src',
  'map_read',
  'map_write',
  'uniform',
]);

const ALLOWED_DATA_KINDS = new Set(['u8', 'u32', 'f32', 'bytes', 'utf8', 'file']);
const ALLOWED_STEP_KINDS = new Set(['writeBuffer', 'dispatch', 'copyBufferToBuffer', 'readBuffer']);
const ALLOWED_BINDING_BUFFER_TYPES = new Set(['storage', 'read-only-storage', 'uniform']);
const BUFFER_USAGE_ORDER = ['storage', 'copy_dst', 'copy_src', 'map_read', 'map_write', 'uniform'];
const SHA256_HEX_PATTERN = /^[0-9a-f]{64}$/u;
const REPO_ROOT = resolve(fileURLToPath(new URL('../../..', import.meta.url)));

function isPlainObject(value) {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

function stableStringify(value) {
  if (value === undefined) {
    return 'null';
  }
  if (value === null || typeof value !== 'object') {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map((entry) => stableStringify(entry)).join(',')}]`;
  }
  const entries = Object.keys(value)
    .sort()
    .map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`);
  return `{${entries.join(',')}}`;
}

function sha256Text(text) {
  return createHash('sha256').update(text, 'utf8').digest('hex');
}

function loadJsonFile(path) {
  return readFile(path, 'utf8').then((text) => JSON.parse(text));
}

function normalizeCommandBindingType(value) {
  const normalized = typeof value === 'string' ? value.trim().toLowerCase() : '';
  if (normalized === 'readonly' || normalized === 'read-only-storage') {
    return 'read-only-storage';
  }
  if (normalized === 'uniform') {
    return 'uniform';
  }
  return 'storage';
}

function inferKernelSourcePath(kernel) {
  const candidates = [
    resolve(REPO_ROOT, 'bench/inference-pipeline/kernels', kernel),
    resolve(REPO_ROOT, 'bench/kernels', kernel),
  ];
  for (const candidate of candidates) {
    if (existsSync(candidate)) {
      return candidate.slice(REPO_ROOT.length + 1);
    }
  }
  return `bench/inference-pipeline/kernels/${kernel}`;
}

function captureReadbackBufferId(commandIndex, handle) {
  return `capture_${commandIndex}_${handle}`;
}

function omitUndefinedFields(value) {
  return Object.fromEntries(
    Object.entries(value).filter(([, entry]) => entry !== undefined),
  );
}

function normalizeStringList(value) {
  if (!Array.isArray(value)) {
    return [];
  }
  return [...new Set(value
    .map((entry) => String(entry).trim())
    .filter((entry) => entry.length > 0))]
    .sort();
}

function commandPlanAdapterDescriptor(plan) {
  const adapter = isPlainObject(plan.adapter) ? plan.adapter : {};
  const requiredFeatures = normalizeStringList(
    adapter.requiredFeatures
      ?? adapter.required_features
      ?? plan.requiredFeatures
      ?? plan.required_features
      ?? [],
  );
  const requiredLimits = isPlainObject(adapter.requiredLimits)
    ? adapter.requiredLimits
    : isPlainObject(adapter.required_limits)
      ? adapter.required_limits
      : isPlainObject(plan.requiredLimits)
        ? plan.requiredLimits
        : isPlainObject(plan.required_limits)
          ? plan.required_limits
          : {};
  return {
    powerPreference: typeof adapter.powerPreference === 'string'
      ? adapter.powerPreference
      : typeof adapter.power_preference === 'string'
        ? adapter.power_preference
        : typeof plan.powerPreference === 'string'
          ? plan.powerPreference
          : typeof plan.power_preference === 'string'
            ? plan.power_preference
            : 'high-performance',
    requiredFeatures,
    requiredLimits,
  };
}

function commandCaptureValidate(command) {
  const explicit = command.captureValidate ?? command.capture_validate ?? command.validate;
  if (isPlainObject(explicit)) {
    return explicit;
  }
  const expectedU32Le = command.captureExpectedU32Le
    ?? command.capture_expected_u32_le
    ?? command.expectedU32Le
    ?? command.expected_u32_le;
  const parsed = Number(expectedU32Le);
  if (Number.isInteger(parsed) && parsed >= 0) {
    return { kind: 'u32PrefixEquals', values: [parsed] };
  }
  return undefined;
}

function commandPlanToNeutralPlan(plan) {
  const commands = Array.isArray(plan.commands) ? plan.commands : [];
  const buffers = new Map();
  const modules = new Map();
  const steps = [];

  function ensureBuffer(handle, size, options = {}) {
    const {
      bindingType = '',
      writable = false,
      readableCopySource = false,
      readableMap = false,
    } = options;
    const id = `buffer_${handle}`;
    const existing = buffers.get(id) ?? {
      id,
      size,
      usage: new Set(),
    };
    existing.size = Math.max(existing.size, size);
    if (bindingType === 'uniform') {
      existing.usage.add('uniform');
    } else if (bindingType) {
      existing.usage.add('storage');
    }
    if (writable) {
      existing.usage.add('copy_dst');
    }
    if (readableCopySource) {
      existing.usage.add('copy_src');
    }
    if (readableMap) {
      existing.usage.add('map_read');
    }
    buffers.set(id, existing);
    return id;
  }

  function appendCaptureSteps(command, index) {
    const captureHandle = Number(command.captureBufferHandle ?? command.capture_buffer_handle);
    const captureSize = Number(command.captureSize ?? command.capture_size ?? 0);
    const captureOffset = Number(command.captureOffset ?? command.capture_offset ?? 0);
    if (!Number.isInteger(captureHandle) || captureHandle < 0) {
      return;
    }
    if (!Number.isInteger(captureSize) || captureSize <= 0) {
      return;
    }
    if (!Number.isInteger(captureOffset) || captureOffset < 0) {
      return;
    }
    const sourceBufferId = ensureBuffer(
      captureHandle,
      captureOffset + captureSize,
      { bindingType: 'storage', readableCopySource: true },
    );
    const readbackBufferId = ensureBuffer(
      captureReadbackBufferId(index, captureHandle),
      captureSize,
      { writable: true, readableMap: true },
    );
    const validate = commandCaptureValidate(command);
    steps.push({
      id: `step-${index}-capture-copy`,
      kind: 'copyBufferToBuffer',
      srcBufferId: sourceBufferId,
      dstBufferId: readbackBufferId,
      srcOffset: captureOffset,
      dstOffset: 0,
      sizeBytes: captureSize,
    });
    steps.push(omitUndefinedFields({
      id: `step-${index}-capture-read`,
      kind: 'readBuffer',
      bufferId: readbackBufferId,
      semanticOpId: typeof command.semanticOpId === 'string'
        ? command.semanticOpId
        : typeof command.semantic_op_id === 'string'
          ? command.semantic_op_id
          : undefined,
      semanticStage: typeof command.semanticStage === 'string'
        ? command.semanticStage
        : typeof command.semantic_stage === 'string'
          ? command.semantic_stage
          : undefined,
      semanticPhase: typeof command.semanticPhase === 'string'
        ? command.semanticPhase
        : typeof command.semantic_phase === 'string'
          ? command.semantic_phase
          : undefined,
      semanticTokenIndex: Number.isInteger(Number(command.semanticTokenIndex ?? command.semantic_token_index))
        ? Number(command.semanticTokenIndex ?? command.semantic_token_index)
        : undefined,
      semanticLayerIndex: Number.isInteger(Number(command.semanticLayerIndex ?? command.semantic_layer_index))
        ? Number(command.semanticLayerIndex ?? command.semantic_layer_index)
        : undefined,
      semanticExecutionPlanHash: typeof command.semanticExecutionPlanHash === 'string'
        ? command.semanticExecutionPlanHash
        : typeof command.semantic_execution_plan_hash === 'string'
          ? command.semantic_execution_plan_hash
          : undefined,
      captureSourceBufferId: sourceBufferId,
      captureOffset,
      captureSize,
      captureDecode: typeof command.decode === 'string' ? command.decode : undefined,
      validate,
    }));
  }

  commands.forEach((command, index) => {
    if (!isPlainObject(command)) {
      return;
    }
    const kind = typeof command.kind === 'string' ? command.kind : '';
    if (kind === 'buffer_write') {
      const handle = Number(command.handle);
      const bufferSize = Number(command.bufferSize ?? 0);
      const values = Array.isArray(command.data)
        ? command.data.map((value) => Number(value) >>> 0)
        : [];
      const bufferId = ensureBuffer(handle, bufferSize, { writable: true });
      steps.push({
        id: `step-${index}`,
        kind: 'writeBuffer',
        bufferId,
        offset: 0,
        data: { kind: 'u32', values },
      });
      appendCaptureSteps(command, index);
      return;
    }
    if (kind === 'buffer_load') {
      const handle = Number(command.handle);
      const bufferSize = Number(command.bufferSize ?? command.byteLength ?? 0);
      const offset = Number(command.offset ?? 0);
      const bufferId = ensureBuffer(handle, bufferSize, { writable: true });
      steps.push(omitUndefinedFields({
        id: `step-${index}`,
        kind: 'writeBuffer',
        bufferId,
        offset,
        data: {
          kind: 'file',
          cacheNamespace: typeof command.cacheNamespace === 'string' ? command.cacheNamespace : '',
          cacheKey: typeof command.cacheKey === 'string' ? command.cacheKey : '',
          sizeBytes: Number(command.byteLength ?? command.bufferSize ?? 0),
        },
        semanticPhase: typeof command.semanticPhase === 'string'
          ? command.semanticPhase
          : typeof command.semantic_phase === 'string'
            ? command.semantic_phase
            : 'buffer_load',
      }));
      appendCaptureSteps(command, index);
      return;
    }
    if (kind === 'kernel_dispatch') {
      const kernel = typeof command.kernel === 'string' ? command.kernel : '';
      const moduleId = basename(kernel, extname(kernel)) || `module_${index}`;
      const entryPoint = typeof command.entryPoint === 'string'
        ? command.entryPoint
        : typeof command.entry_point === 'string'
          ? command.entry_point
          : 'main';
      if (!modules.has(moduleId)) {
        modules.set(moduleId, {
          id: moduleId,
          kind: 'compute',
          entryPoint,
          source: {
            kind: 'file',
            path: inferKernelSourcePath(kernel),
          },
        });
      }
      const bindings = Array.isArray(command.bindings)
        ? command.bindings.map((binding) => {
            const bufferType = normalizeCommandBindingType(binding.buffer_type);
            const bufferId = ensureBuffer(
              Number(binding.resource_handle),
              Number(binding.buffer_size ?? 0),
              { bindingType: bufferType },
            );
            return {
              binding: Number(binding.binding ?? 0),
              bufferId,
              bufferType,
              visibility: ['compute'],
            };
          })
        : [];
      steps.push({
        id: `step-${index}`,
        kind: 'dispatch',
        moduleId,
        entryPoint,
        workgroups: [
          Number(command.x ?? 1),
          Number(command.y ?? 1),
          Number(command.z ?? 1),
        ],
        bindings,
        semanticOpId: typeof command.semanticOpId === 'string'
          ? command.semanticOpId
          : typeof command.semantic_op_id === 'string'
            ? command.semantic_op_id
            : undefined,
        semanticStage: typeof command.semanticStage === 'string'
          ? command.semanticStage
          : typeof command.semantic_stage === 'string'
            ? command.semantic_stage
            : undefined,
        semanticPhase: typeof command.semanticPhase === 'string'
          ? command.semanticPhase
          : typeof command.semantic_phase === 'string'
            ? command.semantic_phase
            : undefined,
        semanticTokenIndex: Number.isInteger(Number(command.semanticTokenIndex ?? command.semantic_token_index))
          ? Number(command.semanticTokenIndex ?? command.semantic_token_index)
          : undefined,
        semanticLayerIndex: Number.isInteger(Number(command.semanticLayerIndex ?? command.semantic_layer_index))
          ? Number(command.semanticLayerIndex ?? command.semantic_layer_index)
          : undefined,
        semanticExecutionPlanHash: typeof command.semanticExecutionPlanHash === 'string'
          ? command.semanticExecutionPlanHash
          : typeof command.semantic_execution_plan_hash === 'string'
            ? command.semantic_execution_plan_hash
            : undefined,
      });
      appendCaptureSteps(command, index);
    }
  });

  const comparable = typeof plan.comparable === 'boolean' ? plan.comparable : false;
  const domain = typeof plan.domain === 'string' && plan.domain.length > 0
    ? plan.domain
    : 'unknown';

  return {
    schemaVersion: 1,
    planId: plan.planSha256 ?? plan.compatibilityCommandsSha256 ?? plan.workloadId,
    executorId: 'node_webgpu_package',
    workloadId: typeof plan.workloadId === 'string' ? plan.workloadId : 'generated_command_plan',
    domain,
    comparable,
    description: typeof plan.description === 'string' ? plan.description : '',
    ...(plan.determinism && typeof plan.determinism === 'object' && !Array.isArray(plan.determinism)
      ? { determinism: plan.determinism }
      : {}),
    timing: {
      iterations: 1,
      warmup: 0,
      timingSource: 'doe-execution-total-ns',
      timingClass: 'operation',
    },
    adapter: commandPlanAdapterDescriptor(plan),
    buffers: [...buffers.values()].map((buffer) => ({
      id: buffer.id,
      size: buffer.size,
      usage: BUFFER_USAGE_ORDER.filter((entry) => buffer.usage.has(entry)),
    })),
    modules: [...modules.values()],
    steps,
  };
}

function canonicalizePlan(plan) {
  if (isPlainObject(plan) && Array.isArray(plan.commands) && !Array.isArray(plan.steps)) {
    return commandPlanToNeutralPlan(plan);
  }
  return plan;
}

function normalizeUsageList(usage) {
  if (!Array.isArray(usage)) {
    return [];
  }
  const deduped = new Set();
  for (const entry of usage) {
    if (typeof entry === 'string' && ALLOWED_BUFFER_USAGES.has(entry)) {
      deduped.add(entry);
    }
  }
  return BUFFER_USAGE_ORDER.filter((entry) => deduped.has(entry));
}

function normalizeData(data) {
  if (!isPlainObject(data)) {
    return null;
  }
  const kind = typeof data.kind === 'string' ? data.kind : '';
  if (!ALLOWED_DATA_KINDS.has(kind)) {
    return null;
  }
  if (kind === 'file') {
    const cacheNamespace = typeof data.cacheNamespace === 'string' ? data.cacheNamespace : '';
    const cacheKey = typeof data.cacheKey === 'string' ? data.cacheKey : '';
    const sizeBytes = Number(data.sizeBytes);
    if (!cacheNamespace || !cacheKey || !Number.isInteger(sizeBytes) || sizeBytes <= 0) {
      return null;
    }
    return { kind, cacheNamespace, cacheKey, sizeBytes };
  }
  if (kind === 'utf8') {
    return { kind, text: String(data.text ?? '') };
  }
  if (kind === 'bytes') {
    return { kind, values: Array.isArray(data.values) ? data.values.map((value) => Number(value) & 0xff) : [] };
  }
  const values = Array.isArray(data.values) ? data.values.map((value) => Number(value)) : [];
  return { kind, values };
}

function normalizeWorkgroups(workgroups, location, problems) {
  if (Array.isArray(workgroups) && workgroups.length === 3) {
    const normalized = workgroups.map((value) => Number(value));
    if (normalized.every((value) => Number.isInteger(value) && value > 0)) {
      return normalized;
    }
  }
  problems.push(`${location}: workgroups must be an array of three positive integers`);
  return [1, 1, 1];
}

function normalizeBinding(binding, index, location, problems) {
  if (!isPlainObject(binding)) {
    problems.push(`${location}[${index}] must be an object`);
    return null;
  }
  const bindingIndex = Number(binding.binding);
  const bufferId = typeof binding.bufferId === 'string' ? binding.bufferId : '';
  const bufferType = typeof binding.bufferType === 'string' ? binding.bufferType : 'storage';
  const visibility = Array.isArray(binding.visibility) ? binding.visibility.map((value) => String(value)) : ['compute'];
  const offset = Number(binding.offset ?? 0);
  const size = binding.size === undefined ? undefined : Number(binding.size);
  if (!Number.isInteger(bindingIndex) || bindingIndex < 0) {
    problems.push(`${location}[${index}].binding must be a non-negative integer`);
  }
  if (!bufferId) {
    problems.push(`${location}[${index}].bufferId must be a non-empty string`);
  }
  if (!ALLOWED_BINDING_BUFFER_TYPES.has(bufferType)) {
    problems.push(`${location}[${index}].bufferType must be one of ${[...ALLOWED_BINDING_BUFFER_TYPES].join(', ')}`);
  }
  if (!Number.isInteger(offset) || offset < 0) {
    problems.push(`${location}[${index}].offset must be a non-negative integer`);
  }
  if (size !== undefined && (!Number.isInteger(size) || size <= 0)) {
    problems.push(`${location}[${index}].size must be a positive integer when present`);
  }
  return {
    binding: Number.isInteger(bindingIndex) && bindingIndex >= 0 ? bindingIndex : 0,
    bufferId,
    bufferType,
    visibility,
    offset: Number.isInteger(offset) && offset >= 0 ? offset : 0,
    ...(size === undefined || !Number.isInteger(size) || size <= 0 ? {} : { size }),
  };
}

function normalizeBuffer(buffer, index, problems) {
  if (!isPlainObject(buffer)) {
    problems.push(`buffers[${index}] must be an object`);
    return null;
  }
  const id = typeof buffer.id === 'string' ? buffer.id : '';
  const size = Number(buffer.size);
  const usage = normalizeUsageList(buffer.usage);
  const data = normalizeData(buffer.initialData ?? buffer.data ?? null);
  if (!id) {
    problems.push(`buffers[${index}].id must be a non-empty string`);
  }
  if (!Number.isInteger(size) || size <= 0) {
    problems.push(`buffers[${index}].size must be a positive integer`);
  }
  if (!usage.length) {
    problems.push(`buffers[${index}].usage must include at least one valid usage`);
  }
  if (data && data.kind !== 'utf8') {
    const elementCount = Array.isArray(data.values) ? data.values.length : 0;
    if (data.kind === 'file') {
      if (data.sizeBytes > size) {
        problems.push(`buffers[${index}].data exceeds declared size`);
      }
    } else if (data.kind === 'bytes') {
      if (elementCount > size) {
        problems.push(`buffers[${index}].data exceeds declared size`);
      }
    } else {
      const byteLength = data.kind === 'u8' ? elementCount : elementCount * 4;
      if (byteLength > size) {
        problems.push(`buffers[${index}].data exceeds declared size`);
      }
    }
  }
  if (data && data.kind === 'utf8' && new TextEncoder().encode(data.text).length > size) {
    problems.push(`buffers[${index}].data exceeds declared size`);
  }
  return {
    id,
    size: Number.isInteger(size) && size > 0 ? size : 0,
    usage,
    data,
    label: typeof buffer.label === 'string' ? buffer.label : undefined,
  };
}

function normalizeModule(module, index, problems) {
  if (!isPlainObject(module)) {
    problems.push(`modules[${index}] must be an object`);
    return null;
  }
  const id = typeof module.id === 'string' ? module.id : '';
  const kind = typeof module.kind === 'string' ? module.kind : 'compute';
  const entryPoint = typeof module.entryPoint === 'string' ? module.entryPoint : 'main';
  const source = isPlainObject(module.source) ? module.source : null;
  if (!id) {
    problems.push(`modules[${index}].id must be a non-empty string`);
  }
  if (kind !== 'compute') {
    problems.push(`modules[${index}].kind must be compute`);
  }
  if (!source) {
    problems.push(`modules[${index}].source must be an object`);
  } else if (source.kind !== 'inline' && source.kind !== 'file') {
    problems.push(`modules[${index}].source.kind must be inline or file`);
  } else if (source.kind === 'inline' && typeof source.code !== 'string') {
    problems.push(`modules[${index}].source.code must be a string`);
  } else if (source.kind === 'file' && typeof source.path !== 'string') {
    problems.push(`modules[${index}].source.path must be a string`);
  }
  return {
    id,
    kind,
    entryPoint,
    source,
    label: typeof module.label === 'string' ? module.label : undefined,
  };
}

function normalizeSemanticMetadata(step, index, problems) {
  const semanticOpId = step.semanticOpId;
  const semanticStage = step.semanticStage;
  const semanticPhase = step.semanticPhase;
  const semanticTokenIndex = step.semanticTokenIndex;
  const semanticLayerIndex = step.semanticLayerIndex;
  const semanticExecutionPlanHash = step.semanticExecutionPlanHash;
  const captureSourceBufferId = step.captureSourceBufferId;
  const captureOffset = step.captureOffset;
  const captureSize = step.captureSize;
  const captureDecode = step.captureDecode;
  const metadata = {};
  if (semanticOpId !== undefined) {
    if (typeof semanticOpId !== 'string' || semanticOpId.length === 0) {
      problems.push(`steps[${index}].semanticOpId must be a non-empty string when provided`);
    } else {
      metadata.semanticOpId = semanticOpId;
    }
  }
  if (semanticStage !== undefined) {
    if (typeof semanticStage !== 'string' || semanticStage.length === 0) {
      problems.push(`steps[${index}].semanticStage must be a non-empty string when provided`);
    } else {
      metadata.semanticStage = semanticStage;
    }
  }
  if (semanticPhase !== undefined) {
    if (typeof semanticPhase !== 'string' || semanticPhase.length === 0) {
      problems.push(`steps[${index}].semanticPhase must be a non-empty string when provided`);
    } else {
      metadata.semanticPhase = semanticPhase;
    }
  }
  if (semanticTokenIndex !== undefined) {
    const parsed = Number(semanticTokenIndex);
    if (!Number.isInteger(parsed) || parsed < 0) {
      problems.push(`steps[${index}].semanticTokenIndex must be a non-negative integer when provided`);
    } else {
      metadata.semanticTokenIndex = parsed;
    }
  }
  if (semanticLayerIndex !== undefined) {
    const parsed = Number(semanticLayerIndex);
    if (!Number.isInteger(parsed) || parsed < 0) {
      problems.push(`steps[${index}].semanticLayerIndex must be a non-negative integer when provided`);
    } else {
      metadata.semanticLayerIndex = parsed;
    }
  }
  if (semanticExecutionPlanHash !== undefined) {
    if (typeof semanticExecutionPlanHash !== 'string' || semanticExecutionPlanHash.length === 0) {
      problems.push(`steps[${index}].semanticExecutionPlanHash must be a non-empty string when provided`);
    } else {
      metadata.semanticExecutionPlanHash = semanticExecutionPlanHash;
    }
  }
  if (captureSourceBufferId !== undefined) {
    if (typeof captureSourceBufferId !== 'string' || captureSourceBufferId.length === 0) {
      problems.push(`steps[${index}].captureSourceBufferId must be a non-empty string when provided`);
    } else {
      metadata.captureSourceBufferId = captureSourceBufferId;
    }
  }
  if (captureOffset !== undefined) {
    const parsed = Number(captureOffset);
    if (!Number.isInteger(parsed) || parsed < 0) {
      problems.push(`steps[${index}].captureOffset must be a non-negative integer when provided`);
    } else {
      metadata.captureOffset = parsed;
    }
  }
  if (captureSize !== undefined) {
    const parsed = Number(captureSize);
    if (!Number.isInteger(parsed) || parsed <= 0) {
      problems.push(`steps[${index}].captureSize must be a positive integer when provided`);
    } else {
      metadata.captureSize = parsed;
    }
  }
  if (captureDecode !== undefined) {
    if (typeof captureDecode !== 'string' || captureDecode.length === 0) {
      problems.push(`steps[${index}].captureDecode must be a non-empty string when provided`);
    } else {
      metadata.captureDecode = captureDecode;
    }
  }
  return metadata;
}

function normalizeReadbackExpectation(expectation, index, problems) {
  if (expectation === undefined || expectation === null) {
    return null;
  }
  if (!isPlainObject(expectation)) {
    problems.push(`steps[${index}].validate must be an object when provided`);
    return null;
  }
  if (expectation.kind !== 'sha256Equals') {
    return expectation;
  }
  const sha256 = typeof expectation.sha256 === 'string'
    ? expectation.sha256.trim().toLowerCase()
    : '';
  if (!SHA256_HEX_PATTERN.test(sha256)) {
    problems.push(`steps[${index}].validate.sha256 must be 64 lowercase hexadecimal characters`);
  }
  return {
    kind: 'sha256Equals',
    sha256,
  };
}

function normalizeStep(step, index, problems) {
  if (!isPlainObject(step)) {
    problems.push(`steps[${index}] must be an object`);
    return null;
  }
  const kind = typeof step.kind === 'string' ? step.kind : '';
  if (!ALLOWED_STEP_KINDS.has(kind)) {
    problems.push(`steps[${index}].kind must be one of ${[...ALLOWED_STEP_KINDS].join(', ')}`);
    return null;
  }

  if (kind === 'writeBuffer') {
    const bufferId = typeof step.bufferId === 'string' ? step.bufferId : '';
    const offset = Number(step.offset ?? 0);
    const data = normalizeData(step.data ?? null);
    if (!bufferId) {
      problems.push(`steps[${index}].bufferId must be a non-empty string`);
    }
    if (!Number.isInteger(offset) || offset < 0) {
      problems.push(`steps[${index}].offset must be a non-negative integer`);
    }
    if (!data) {
      problems.push(`steps[${index}].data must be present and valid`);
    }
    return {
      kind,
      bufferId,
      offset,
      data,
      ...(typeof step.id === 'string' ? { id: step.id } : {}),
    };
  }

  if (kind === 'dispatch') {
    const moduleId = typeof step.moduleId === 'string' ? step.moduleId : '';
    if (!moduleId) {
      problems.push(`steps[${index}].moduleId must be a non-empty string`);
    }
    return {
      kind,
      moduleId,
      ...(typeof step.id === 'string' ? { id: step.id } : {}),
      entryPoint: typeof step.entryPoint === 'string' ? step.entryPoint : undefined,
      workgroups: normalizeWorkgroups(step.workgroups, `steps[${index}].workgroups`, problems),
      bindings: Array.isArray(step.bindings)
        ? step.bindings.map((binding, bindingIndex) => normalizeBinding(binding, bindingIndex, `steps[${index}].bindings`, problems)).filter(Boolean)
        : [],
      ...normalizeSemanticMetadata(step, index, problems),
    };
  }

  if (kind === 'copyBufferToBuffer') {
    const srcBufferId = typeof step.srcBufferId === 'string' ? step.srcBufferId : '';
    const dstBufferId = typeof step.dstBufferId === 'string' ? step.dstBufferId : '';
    const sizeBytes = Number(step.sizeBytes);
    const srcOffset = Number(step.srcOffset ?? 0);
    const dstOffset = Number(step.dstOffset ?? 0);
    if (!srcBufferId) {
      problems.push(`steps[${index}].srcBufferId must be a non-empty string`);
    }
    if (!dstBufferId) {
      problems.push(`steps[${index}].dstBufferId must be a non-empty string`);
    }
    if (!Number.isInteger(sizeBytes) || sizeBytes <= 0) {
      problems.push(`steps[${index}].sizeBytes must be a positive integer`);
    }
    if (!Number.isInteger(srcOffset) || srcOffset < 0) {
      problems.push(`steps[${index}].srcOffset must be a non-negative integer when provided`);
    }
    if (!Number.isInteger(dstOffset) || dstOffset < 0) {
      problems.push(`steps[${index}].dstOffset must be a non-negative integer when provided`);
    }
    return {
      kind,
      srcBufferId,
      dstBufferId,
      sizeBytes: Number.isInteger(sizeBytes) && sizeBytes > 0 ? sizeBytes : 0,
      srcOffset: Number.isInteger(srcOffset) && srcOffset >= 0 ? srcOffset : 0,
      dstOffset: Number.isInteger(dstOffset) && dstOffset >= 0 ? dstOffset : 0,
      ...(typeof step.id === 'string' ? { id: step.id } : {}),
      ...normalizeSemanticMetadata(step, index, problems),
    };
  }

  const bufferId = typeof step.bufferId === 'string' ? step.bufferId : '';
  if (!bufferId) {
    problems.push(`steps[${index}].bufferId must be a non-empty string`);
  }
  return {
    kind,
    bufferId,
    validate: normalizeReadbackExpectation(step.validate, index, problems),
    ...(typeof step.id === 'string' ? { id: step.id } : {}),
    ...normalizeSemanticMetadata(step, index, problems),
  };
}

export function validatePlan(plan) {
  const candidate = canonicalizePlan(plan);
  const problems = [];
  if (!isPlainObject(candidate)) {
    return ['plan must be a JSON object'];
  }
  if (Number(candidate.schemaVersion) !== 1) {
    problems.push('schemaVersion must equal 1');
  }
  if (typeof candidate.planId !== 'string' || candidate.planId.length === 0) {
    problems.push('planId must be a non-empty string');
  }
  if (typeof candidate.executorId !== 'string' || candidate.executorId.length === 0) {
    problems.push('executorId must be a non-empty string');
  }
  if (typeof candidate.workloadId !== 'string' || candidate.workloadId.length === 0) {
    problems.push('workloadId must be a non-empty string');
  }
  if (typeof candidate.domain !== 'string' || candidate.domain.length === 0) {
    problems.push('domain must be a non-empty string');
  }
  if (typeof candidate.comparable !== 'boolean') {
    problems.push('comparable must be a boolean');
  }
  const normalizedDeterminism = normalizeDeterminismConfig(candidate.determinism, problems, 'determinism');

  const timing = isPlainObject(candidate.timing) ? candidate.timing : null;
  if (!timing) {
    problems.push('timing must be an object');
  } else {
    for (const field of ['iterations', 'warmup']) {
      const value = Number(timing[field]);
      if (!Number.isInteger(value) || value < 0) {
        problems.push(`timing.${field} must be a non-negative integer`);
      }
    }
    if (typeof timing.timingSource !== 'string' || timing.timingSource.length === 0) {
      problems.push('timing.timingSource must be a non-empty string');
    }
    if (typeof timing.timingClass !== 'string' || timing.timingClass.length === 0) {
      problems.push('timing.timingClass must be a non-empty string');
    }
  }

  const buffers = Array.isArray(candidate.buffers) ? candidate.buffers : [];
  const modules = Array.isArray(candidate.modules) ? candidate.modules : [];
  const steps = Array.isArray(candidate.steps) ? candidate.steps : [];

  if (buffers.length === 0) {
    problems.push('buffers must contain at least one buffer definition');
  }
  const hasDispatchStep = steps.some((step) => isPlainObject(step) && step.kind === 'dispatch');
  if (modules.length === 0 && hasDispatchStep) {
    problems.push('modules must contain at least one module definition');
  }
  if (steps.length === 0) {
    problems.push('steps must contain at least one step');
  }

  const normalizedBuffers = buffers.map((buffer, index) => normalizeBuffer(buffer, index, problems)).filter(Boolean);
  const normalizedModules = modules.map((module, index) => normalizeModule(module, index, problems)).filter(Boolean);
  const normalizedSteps = steps.map((step, index) => normalizeStep(step, index, problems)).filter(Boolean);

  const bufferIds = new Set();
  for (const buffer of normalizedBuffers) {
    if (bufferIds.has(buffer.id)) {
      problems.push(`duplicate buffer id: ${buffer.id}`);
    }
    bufferIds.add(buffer.id);
  }

  const moduleIds = new Set();
  for (const module of normalizedModules) {
    if (moduleIds.has(module.id)) {
      problems.push(`duplicate module id: ${module.id}`);
    }
    moduleIds.add(module.id);
  }

  let seenReadbackStep = false;
  normalizedSteps.forEach((step, index) => {
    if (step.kind === 'readBuffer') {
      seenReadbackStep = !step.semanticOpId;
      return;
    }
    if (seenReadbackStep) {
      problems.push(`steps[${index}].kind=${step.kind} cannot appear after readBuffer steps`);
    }
  });

  for (const step of normalizedSteps) {
    if (step.kind === 'dispatch') {
      if (!moduleIds.has(step.moduleId)) {
        problems.push(`dispatch references unknown module: ${step.moduleId}`);
      }
      for (const binding of step.bindings) {
        if (!bufferIds.has(binding.bufferId)) {
          problems.push(`dispatch references unknown buffer: ${binding.bufferId}`);
        }
      }
    } else if (step.kind === 'writeBuffer') {
      if (!bufferIds.has(step.bufferId)) {
        problems.push(`writeBuffer references unknown buffer: ${step.bufferId}`);
      }
    } else if (step.kind === 'copyBufferToBuffer') {
      if (!bufferIds.has(step.srcBufferId)) {
        problems.push(`copyBufferToBuffer references unknown source buffer: ${step.srcBufferId}`);
      }
      if (!bufferIds.has(step.dstBufferId)) {
        problems.push(`copyBufferToBuffer references unknown destination buffer: ${step.dstBufferId}`);
      }
    } else if (step.kind === 'readBuffer') {
      if (!bufferIds.has(step.bufferId)) {
        problems.push(`readBuffer references unknown buffer: ${step.bufferId}`);
      }
      if (step.captureSourceBufferId && !bufferIds.has(step.captureSourceBufferId)) {
        problems.push(`readBuffer capture source references unknown buffer: ${step.captureSourceBufferId}`);
      }
    }
  }

  const bufferById = new Map(normalizedBuffers.map((buffer) => [buffer.id, buffer]));
  for (const buffer of normalizedBuffers) {
    if (buffer.data && !buffer.usage.includes('copy_dst')) {
      problems.push(`buffer ${buffer.id}: initial data requires copy_dst usage`);
    }
  }
  for (const step of normalizedSteps) {
    if (step.kind === 'writeBuffer') {
      const buffer = bufferById.get(step.bufferId);
      if (buffer && !buffer.usage.includes('copy_dst')) {
        problems.push(`writeBuffer target ${step.bufferId} requires copy_dst usage`);
      }
    } else if (step.kind === 'readBuffer') {
      const buffer = bufferById.get(step.bufferId);
      if (buffer && !buffer.usage.includes('map_read')) {
        problems.push(`readBuffer target ${step.bufferId} requires map_read usage`);
      }
    } else if (step.kind === 'dispatch') {
      for (const binding of step.bindings) {
        const buffer = bufferById.get(binding.bufferId);
        if (!buffer) continue;
        if (binding.bufferType === 'uniform' && !buffer.usage.includes('uniform')) {
          problems.push(`dispatch binding ${binding.bufferId} requires uniform usage`);
        }
        if ((binding.bufferType === 'storage' || binding.bufferType === 'read-only-storage') && !buffer.usage.includes('storage')) {
          problems.push(`dispatch binding ${binding.bufferId} requires storage usage`);
        }
      }
    }
  }

  return problems;
}

export function normalizePlan(plan) {
  const candidate = canonicalizePlan(plan);
  const problems = validatePlan(candidate);
  if (problems.length) {
    throw new Error(`invalid neutral plan:\n- ${problems.join('\n- ')}`);
  }
  const normalizedDeterminism = normalizeDeterminismConfig(candidate.determinism, [], 'determinism');

  const normalized = {
    schemaVersion: 1,
    planId: candidate.planId,
    executorId: candidate.executorId,
    workloadId: candidate.workloadId,
    domain: candidate.domain,
    comparable: candidate.comparable,
    description: typeof candidate.description === 'string' ? candidate.description : '',
    ...(normalizedDeterminism ? { determinism: normalizedDeterminism } : {}),
    timing: {
      iterations: Number(candidate.timing.iterations),
      warmup: Number(candidate.timing.warmup),
      timingSource: candidate.timing.timingSource,
      timingClass: candidate.timing.timingClass,
    },
    adapter: isPlainObject(candidate.adapter)
      ? {
          powerPreference: typeof candidate.adapter.powerPreference === 'string' ? candidate.adapter.powerPreference : 'high-performance',
          requiredFeatures: Array.isArray(candidate.adapter.requiredFeatures)
            ? candidate.adapter.requiredFeatures.map((value) => String(value)).sort()
            : [],
          requiredLimits: isPlainObject(candidate.adapter.requiredLimits) ? candidate.adapter.requiredLimits : {},
        }
      : {
          powerPreference: 'high-performance',
          requiredFeatures: [],
          requiredLimits: {},
        },
    buffers: candidate.buffers.map((buffer) => ({
      id: buffer.id,
      size: buffer.size,
      usage: normalizeUsageList(buffer.usage),
      data: normalizeData(buffer.initialData ?? buffer.data ?? null),
      label: typeof buffer.label === 'string' ? buffer.label : undefined,
    })),
    modules: candidate.modules.map((module) => ({
      id: module.id,
      kind: module.kind,
      entryPoint: module.entryPoint,
      source: module.source.kind === 'file'
        ? { kind: 'file', path: module.source.path }
        : { kind: 'inline', code: module.source.code },
      label: typeof module.label === 'string' ? module.label : undefined,
    })),
    steps: candidate.steps.map((step) => {
      if (step.kind === 'dispatch') {
        return omitUndefinedFields({
          kind: step.kind,
          moduleId: step.moduleId,
          entryPoint: step.entryPoint,
          workgroups: step.workgroups,
          bindings: step.bindings,
          ...(typeof step.id === 'string' ? { id: step.id } : {}),
          ...normalizeSemanticMetadata(step, -1, []),
        });
      }
      if (step.kind === 'copyBufferToBuffer') {
        return omitUndefinedFields({
          kind: step.kind,
          srcBufferId: step.srcBufferId,
          dstBufferId: step.dstBufferId,
          sizeBytes: step.sizeBytes,
          srcOffset: step.srcOffset,
          dstOffset: step.dstOffset,
          ...(typeof step.id === 'string' ? { id: step.id } : {}),
          ...normalizeSemanticMetadata(step, -1, []),
        });
      }
      if (step.kind === 'writeBuffer') {
        return omitUndefinedFields({
          kind: step.kind,
          bufferId: step.bufferId,
          offset: step.offset,
          data: step.data,
          ...(typeof step.id === 'string' ? { id: step.id } : {}),
        });
      }
      return omitUndefinedFields({
        kind: step.kind,
        bufferId: step.bufferId,
        validate: step.validate,
        ...(typeof step.id === 'string' ? { id: step.id } : {}),
        ...normalizeSemanticMetadata(step, -1, []),
      });
    }),
  };

  const stable = JSON.parse(stableStringify(normalized));
  const planHash = sha256Text(stableStringify(stable));
  const executionShape = {
    bufferCount: normalized.buffers.length,
    moduleCount: normalized.modules.length,
    stepCount: normalized.steps.length,
    writeBufferCount: normalized.steps.filter((step) => step.kind === 'writeBuffer').length,
    dispatchCount: normalized.steps.filter((step) => step.kind === 'dispatch').length,
    copyBufferToBufferCount: normalized.steps.filter((step) => step.kind === 'copyBufferToBuffer').length,
    readBufferCount: normalized.steps.filter((step) => step.kind === 'readBuffer').length,
  };

  return {
    ...stable,
    planHash,
    executionShape,
  };
}

export function planSummary(plan) {
  const normalized = normalizePlan(plan);
  return {
    schemaVersion: normalized.schemaVersion,
    planId: normalized.planId,
    executorId: normalized.executorId,
    workloadId: normalized.workloadId,
    domain: normalized.domain,
    comparable: normalized.comparable,
    timing: normalized.timing,
    planHash: normalized.planHash,
    executionShape: normalized.executionShape,
  };
}

export function materializeBufferData(bufferData) {
  if (!bufferData) {
    return null;
  }
  if (bufferData.kind === 'file') {
    return readSyntheticAssetData(bufferData);
  }
  if (bufferData.kind === 'u8' || bufferData.kind === 'bytes') {
    return Uint8Array.from(bufferData.values);
  }
  if (bufferData.kind === 'u32') {
    return Uint32Array.from(bufferData.values);
  }
  if (bufferData.kind === 'f32') {
    return Float32Array.from(bufferData.values);
  }
  if (bufferData.kind === 'utf8') {
    return new TextEncoder().encode(bufferData.text);
  }
  return null;
}

export function validateSampleExpectation(view, expectation) {
  if (!isPlainObject(expectation)) {
    return { ok: true };
  }
  if (expectation.kind === 'f32PrefixEquals') {
    const values = Array.isArray(expectation.values) ? expectation.values.map((value) => Number(value)) : [];
    const actual = new Float32Array(view.buffer, view.byteOffset, Math.min(values.length, view.byteLength / 4));
    for (let index = 0; index < values.length; index += 1) {
      if (actual[index] !== values[index]) {
        return {
          ok: false,
          detail: `expected float32[${index}] === ${values[index]}, got ${actual[index]}`,
        };
      }
    }
    return { ok: true };
  }
  if (expectation.kind === 'u32PrefixEquals') {
    const values = Array.isArray(expectation.values) ? expectation.values.map((value) => Number(value)) : [];
    const actual = new Uint32Array(view.buffer, view.byteOffset, Math.min(values.length, view.byteLength / 4));
    for (let index = 0; index < values.length; index += 1) {
      if (actual[index] !== values[index]) {
        return {
          ok: false,
          detail: `expected uint32[${index}] === ${values[index]}, got ${actual[index]}`,
        };
      }
    }
    return { ok: true };
  }
  if (expectation.kind === 'bytesPrefixEquals') {
    const values = Array.isArray(expectation.values) ? expectation.values.map((value) => Number(value) & 0xff) : [];
    const actual = new Uint8Array(view.buffer, view.byteOffset, Math.min(values.length, view.byteLength));
    for (let index = 0; index < values.length; index += 1) {
      if (actual[index] !== values[index]) {
        return {
          ok: false,
          detail: `expected bytes[${index}] === ${values[index]}, got ${actual[index]}`,
        };
      }
    }
    return { ok: true };
  }
  if (expectation.kind === 'sha256Equals') {
    const expected = typeof expectation.sha256 === 'string'
      ? expectation.sha256.trim().toLowerCase()
      : '';
    if (!SHA256_HEX_PATTERN.test(expected)) {
      return {
        ok: false,
        detail: 'sha256Equals requires a 64-character lowercase hexadecimal sha256 value',
      };
    }
    const actual = createHash('sha256').update(view).digest('hex');
    if (actual !== expected) {
      return {
        ok: false,
        detail: `expected sha256 ${expected}, got ${actual}`,
      };
    }
    return { ok: true };
  }
  return {
    ok: false,
    detail: `unknown expectation kind: ${expectation.kind}`,
  };
}

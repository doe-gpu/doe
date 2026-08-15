// doe-gpu/node-webgpu - strict, receipt-backed Node WebGPU provider contract.

import { createHash } from 'node:crypto';
import { isAbsolute, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

export const NODE_WEBGPU_PROVIDER_SCHEMA = 'doe.webgpu-provider/v1';
export const NODE_WEBGPU_PROVIDER_RECEIPT_SCHEMA = 'doe.webgpu-provider-receipt/v1';
export const NODE_WEBGPU_GOVERNED_RECEIPT_SCHEMA = 'doe.governed-node-webgpu-receipt/v1';

export const NODE_WEBGPU_PROVIDER_ERROR_CODES = Object.freeze([
  'DOE_PROVIDER_INVALID_CONFIGURATION',
  'DOE_PROVIDER_IMPORT_FAILED',
  'DOE_PROVIDER_BINDING_MISSING',
  'DOE_PROVIDER_FACTORY_FAILED',
  'DOE_PROVIDER_GPU_INVALID',
  'DOE_PROVIDER_GLOBAL_MISSING',
  'DOE_PROVIDER_GLOBAL_CONFLICT',
  'DOE_PROVIDER_ADAPTER_UNAVAILABLE',
  'DOE_PROVIDER_ALL_FAILED',
  'DOE_PROVIDER_RESTORE_FAILED',
]);

export const NODE_WEBGPU_GOVERNED_ERROR_CODES = Object.freeze([
  'DOE_GOVERNED_WORKLOAD_INVALID_CONFIGURATION',
  'DOE_GOVERNED_WORKLOAD_PROVIDER_FAILED',
  'DOE_GOVERNED_WORKLOAD_EXECUTION_FAILED',
  'DOE_GOVERNED_WORKLOAD_ORACLE_FAILED',
  'DOE_GOVERNED_WORKLOAD_RECEIPT_SINK_FAILED',
  'DOE_GOVERNED_WORKLOAD_RELEASE_FAILED',
]);

const REQUIRED_WEBGPU_GLOBALS = Object.freeze([
  'GPUBufferUsage',
  'GPUShaderStage',
  'GPUMapMode',
  'GPUTextureUsage',
]);
const PROVIDER_KEYS = new Set(['id', 'kind', 'module', 'gpu', 'globals']);
const GPU_BINDING_KEYS = new Set(['kind', 'path', 'args', 'resultPath']);
const GLOBAL_POLICY_KEYS = new Set(['mode']);
const OPEN_OPTIONS_KEYS = new Set(['providers', 'adapterOptions', 'globals']);
const SAFE_PATH_SEGMENT = /^[A-Za-z_$][A-Za-z0-9_$]*$/;
const SHA256_PATTERN = /^sha256:[a-f0-9]{64}$/;
const ADAPTER_INFO_FIELDS = Object.freeze([
  'vendor',
  'architecture',
  'device',
  'description',
  'backendType',
  'adapterType',
  'vendorID',
  'deviceID',
  'driverVersion',
  'subgroupMinSize',
  'subgroupMaxSize',
]);

function own(object, key) {
  return Object.prototype.hasOwnProperty.call(object, key);
}

function assertPlainObject(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new NodeWebGPUProviderError(
      'DOE_PROVIDER_INVALID_CONFIGURATION',
      `${label} must be an object.`,
      { stage: 'configuration' },
    );
  }
  return value;
}

function assertKnownKeys(value, allowed, label) {
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) {
      throw new NodeWebGPUProviderError(
        'DOE_PROVIDER_INVALID_CONFIGURATION',
        `${label} contains unsupported field "${key}".`,
        { stage: 'configuration' },
      );
    }
  }
}

function normalizePath(path, label) {
  if (typeof path !== 'string' || path.length === 0) {
    throw new NodeWebGPUProviderError(
      'DOE_PROVIDER_INVALID_CONFIGURATION',
      `${label} must be a non-empty dotted export path.`,
      { stage: 'configuration' },
    );
  }
  const segments = path.split('.');
  if (segments.some((segment) => !SAFE_PATH_SEGMENT.test(segment))) {
    throw new NodeWebGPUProviderError(
      'DOE_PROVIDER_INVALID_CONFIGURATION',
      `${label} contains an invalid path segment.`,
      { stage: 'configuration' },
    );
  }
  return segments;
}

function resolvePath(root, path, label) {
  const segments = normalizePath(path, label);
  let parent = null;
  let value = root;
  for (const segment of segments) {
    if (value == null || !(segment in Object(value))) {
      return { found: false, parent: null, value: undefined };
    }
    parent = value;
    value = value[segment];
  }
  return { found: true, parent, value };
}

function normalizeModuleSpecifier(specifier) {
  if (typeof specifier !== 'string' || specifier.trim().length === 0) {
    throw new NodeWebGPUProviderError(
      'DOE_PROVIDER_INVALID_CONFIGURATION',
      'provider.module must be a non-empty module specifier.',
      { stage: 'configuration' },
    );
  }
  const trimmed = specifier.trim();
  if (trimmed.startsWith('file:') || trimmed.startsWith('node:') || trimmed.startsWith('data:')) {
    return trimmed;
  }
  if (isAbsolute(trimmed) || trimmed.startsWith('./') || trimmed.startsWith('../')) {
    return pathToFileURL(isAbsolute(trimmed) ? trimmed : resolve(process.cwd(), trimmed)).href;
  }
  return trimmed;
}

function cloneReceiptValue(value) {
  if (value === undefined) return null;
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return value;
  if (typeof value === 'number') return Number.isFinite(value) ? value : String(value);
  if (Array.isArray(value)) return value.map(cloneReceiptValue);
  if (typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, cloneReceiptValue(item)]));
  }
  return String(value);
}

function stableReceiptValue(value) {
  if (Array.isArray(value)) return value.map(stableReceiptValue);
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, stableReceiptValue(value[key])]),
    );
  }
  return value;
}

function sha256(value) {
  const bytes = typeof value === 'string' ? Buffer.from(value, 'utf8') : value;
  return `sha256:${createHash('sha256').update(bytes).digest('hex')}`;
}

function stableSha256(value) {
  return sha256(JSON.stringify(stableReceiptValue(value)));
}

function byteView(value, label) {
  if (typeof value === 'string') return Buffer.from(value, 'utf8');
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  if (ArrayBuffer.isView(value)) {
    return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  }
  throw new TypeError(`${label} must be a string, ArrayBuffer, or ArrayBuffer view.`);
}

function assertGovernedSha256(value, label) {
  if (typeof value !== 'string' || !SHA256_PATTERN.test(value)) {
    throw new TypeError(`${label} must be a lowercase sha256:<64 hex> digest.`);
  }
}

function normalizeGovernedWorkload(workload) {
  if (!workload || typeof workload !== 'object' || Array.isArray(workload)) {
    throw new TypeError('workload must be an object.');
  }
  for (const field of ['id', 'version']) {
    if (typeof workload[field] !== 'string' || workload[field].trim().length === 0) {
      throw new TypeError(`workload.${field} must be a non-empty string.`);
    }
  }
  assertGovernedSha256(workload.implementationSha256, 'workload.implementationSha256');
  assertGovernedSha256(workload.expectedOutputSha256, 'workload.expectedOutputSha256');
  const input = byteView(workload.input, 'workload.input');
  return {
    id: workload.id,
    version: workload.version,
    implementationSha256: workload.implementationSha256,
    expectedOutputSha256: workload.expectedOutputSha256,
    input,
    inputSha256: sha256(input),
    inputBytes: input.byteLength,
  };
}

async function readAdapterInfo(adapter) {
  try {
    const info = adapter?.info
      ?? (typeof adapter?.getInfo === 'function' ? await adapter.getInfo() : null)
      ?? (
        typeof adapter?.requestAdapterInfo === 'function'
          ? await adapter.requestAdapterInfo()
          : null
      );
    if (!info || typeof info !== 'object') return {};
    const normalized = cloneReceiptValue(info);
    for (const field of ADAPTER_INFO_FIELDS) {
      try {
        if (info[field] !== undefined) normalized[field] = cloneReceiptValue(info[field]);
      } catch {
        // Keep any independently readable identity fields.
      }
    }
    return normalized;
  } catch (error) {
    return { queryError: error instanceof Error ? error.message : String(error) };
  }
}

function adapterInfoStatus(adapterInfo) {
  if (adapterInfo?.queryError) return 'query-failed';
  return Object.keys(adapterInfo ?? {}).length > 0 ? 'observed' : 'absent';
}

function selectedProviderFromReceipt(providerReceipt) {
  return providerReceipt?.providers?.find(
    (provider) => provider.id === providerReceipt?.selectedProviderId,
  ) ?? null;
}

function governedExecutionIdentity(receipt) {
  return stableSha256({
    workloadReplaySha256: receipt.replay.workloadSha256,
    providerContract: receipt.provider.receipt?.contract ?? null,
    selectedProviderId: receipt.provider.receipt?.selectedProviderId ?? null,
    selectedProvider: selectedProviderFromReceipt(receipt.provider.receipt),
    adapterInfo: receipt.adapterInfo,
    oracleStatus: receipt.oracle.status,
    actualOutputSha256: receipt.oracle.actualOutputSha256,
    outputBytes: receipt.oracle.outputBytes,
  });
}

function governedError(code, stage, error) {
  return {
    code,
    stage,
    detail: error instanceof Error ? error.message : String(error),
  };
}

async function emitGovernedCheckpoint(sink, receipt, errors) {
  if (typeof sink !== 'function') return;
  try {
    await sink(cloneReceiptValue(receipt));
  } catch (error) {
    errors.push(governedError(
      'DOE_GOVERNED_WORKLOAD_RECEIPT_SINK_FAILED',
      'receipt.sink',
      error,
    ));
  }
}

function normalizeProvider(provider, index) {
  assertPlainObject(provider, `providers[${index}]`);
  assertKnownKeys(provider, PROVIDER_KEYS, `providers[${index}]`);
  if (typeof provider.id !== 'string' || provider.id.trim().length === 0) {
    throw new NodeWebGPUProviderError(
      'DOE_PROVIDER_INVALID_CONFIGURATION',
      `providers[${index}].id must be a non-empty string.`,
      { stage: 'configuration' },
    );
  }
  if (provider.kind !== 'global' && provider.kind !== 'module') {
    throw new NodeWebGPUProviderError(
      'DOE_PROVIDER_INVALID_CONFIGURATION',
      `providers[${index}].kind must be "global" or "module".`,
      { stage: 'configuration', providerId: provider.id },
    );
  }
  if (provider.kind === 'global') {
    if (provider.module !== undefined || provider.gpu !== undefined || provider.globals !== undefined) {
      throw new NodeWebGPUProviderError(
        'DOE_PROVIDER_INVALID_CONFIGURATION',
        `global provider "${provider.id}" must not declare module, gpu, or globals.`,
        { stage: 'configuration', providerId: provider.id },
      );
    }
    return Object.freeze({ id: provider.id, kind: 'global' });
  }

  const gpu = assertPlainObject(provider.gpu, `provider "${provider.id}" gpu`);
  assertKnownKeys(gpu, GPU_BINDING_KEYS, `provider "${provider.id}" gpu`);
  if (gpu.kind !== 'export' && gpu.kind !== 'factory') {
    throw new NodeWebGPUProviderError(
      'DOE_PROVIDER_INVALID_CONFIGURATION',
      `provider "${provider.id}" gpu.kind must be "export" or "factory".`,
      { stage: 'configuration', providerId: provider.id },
    );
  }
  normalizePath(gpu.path, `provider "${provider.id}" gpu.path`);
  if (gpu.kind === 'export' && (gpu.args !== undefined || gpu.resultPath !== undefined)) {
    throw new NodeWebGPUProviderError(
      'DOE_PROVIDER_INVALID_CONFIGURATION',
      `export provider "${provider.id}" must not declare args or resultPath.`,
      { stage: 'configuration', providerId: provider.id },
    );
  }
  if (gpu.kind === 'factory' && gpu.args !== undefined && !Array.isArray(gpu.args)) {
    throw new NodeWebGPUProviderError(
      'DOE_PROVIDER_INVALID_CONFIGURATION',
      `factory provider "${provider.id}" gpu.args must be an array.`,
      { stage: 'configuration', providerId: provider.id },
    );
  }
  if (gpu.resultPath !== undefined && gpu.resultPath !== null) {
    normalizePath(gpu.resultPath, `provider "${provider.id}" gpu.resultPath`);
  }

  const globals = assertPlainObject(provider.globals, `provider "${provider.id}" globals`);
  for (const name of REQUIRED_WEBGPU_GLOBALS) {
    normalizePath(globals[name], `provider "${provider.id}" globals.${name}`);
  }
  for (const name of Object.keys(globals)) {
    if (!REQUIRED_WEBGPU_GLOBALS.includes(name)) {
      throw new NodeWebGPUProviderError(
        'DOE_PROVIDER_INVALID_CONFIGURATION',
        `provider "${provider.id}" globals contains unsupported binding "${name}".`,
        { stage: 'configuration', providerId: provider.id },
      );
    }
  }

  return Object.freeze({
    id: provider.id,
    kind: 'module',
    module: normalizeModuleSpecifier(provider.module),
    gpu: Object.freeze({
      kind: gpu.kind,
      path: gpu.path,
      args: Object.freeze([...(gpu.args ?? [])]),
      resultPath: gpu.resultPath ?? null,
    }),
    globals: Object.freeze({ ...globals }),
  });
}

function normalizeOpenOptions(options) {
  assertPlainObject(options, 'provider-v1 options');
  assertKnownKeys(options, OPEN_OPTIONS_KEYS, 'provider-v1 options');
  if (!Array.isArray(options.providers) || options.providers.length === 0) {
    throw new NodeWebGPUProviderError(
      'DOE_PROVIDER_INVALID_CONFIGURATION',
      'provider-v1 options.providers must be a non-empty ordered array.',
      { stage: 'configuration' },
    );
  }
  const providers = options.providers.map(normalizeProvider);
  const providerIds = new Set();
  for (const provider of providers) {
    if (providerIds.has(provider.id)) {
      throw new NodeWebGPUProviderError(
        'DOE_PROVIDER_INVALID_CONFIGURATION',
        `provider id "${provider.id}" is duplicated.`,
        { stage: 'configuration', providerId: provider.id },
      );
    }
    providerIds.add(provider.id);
  }

  const globalPolicy = assertPlainObject(options.globals, 'provider-v1 options.globals');
  assertKnownKeys(globalPolicy, GLOBAL_POLICY_KEYS, 'provider-v1 options.globals');
  if (!['none', 'install-missing', 'replace'].includes(globalPolicy.mode)) {
    throw new NodeWebGPUProviderError(
      'DOE_PROVIDER_INVALID_CONFIGURATION',
      'provider-v1 options.globals.mode must be "none", "install-missing", or "replace".',
      { stage: 'configuration' },
    );
  }
  if (options.adapterOptions !== null) {
    assertPlainObject(options.adapterOptions, 'provider-v1 options.adapterOptions');
  }
  return Object.freeze({
    providers: Object.freeze(providers),
    adapterOptions: options.adapterOptions,
    globals: Object.freeze({ mode: globalPolicy.mode }),
  });
}

function errorDetail(error) {
  return error instanceof Error ? error.message : String(error);
}

function createReceipt(options) {
  return {
    schema: NODE_WEBGPU_PROVIDER_RECEIPT_SCHEMA,
    contract: NODE_WEBGPU_PROVIDER_SCHEMA,
    providers: options.providers.map((provider) => cloneReceiptValue(provider)),
    providerOrder: options.providers.map((provider) => provider.id),
    adapterOptions: cloneReceiptValue(options.adapterOptions),
    globals: {
      mode: options.globals.mode,
      installed: [],
      restored: false,
    },
    attempts: [],
    selectedProviderId: null,
    ok: false,
  };
}

function attemptFailure(provider, error) {
  const normalized = error instanceof NodeWebGPUProviderError
    ? error
    : new NodeWebGPUProviderError('DOE_PROVIDER_GPU_INVALID', errorDetail(error), {
      stage: 'provider',
      providerId: provider.id,
      cause: error,
    });
  return {
    providerId: provider.id,
    kind: provider.kind,
    module: provider.kind === 'module' ? provider.module : null,
    ok: false,
    stage: normalized.stage,
    code: normalized.code,
    detail: normalized.message,
  };
}

function snapshotProperty(target, key) {
  return {
    target,
    key,
    descriptor: Object.getOwnPropertyDescriptor(target, key),
  };
}

function defineRestorable(target, key, value, mode, snapshots, installedNames, receiptName = key) {
  const current = target[key];
  if (mode === 'install-missing' && current !== undefined) {
    if (current !== value) {
      throw new NodeWebGPUProviderError(
        'DOE_PROVIDER_GLOBAL_CONFLICT',
        `global "${key}" already exists and differs from the selected provider.`,
        { stage: 'globals.install' },
      );
    }
    return;
  }
  snapshots.push(snapshotProperty(target, key));
  try {
    Object.defineProperty(target, key, {
      value,
      writable: true,
      configurable: true,
      enumerable: false,
    });
    installedNames.push(receiptName);
  } catch (cause) {
    throw new NodeWebGPUProviderError(
      'DOE_PROVIDER_GLOBAL_CONFLICT',
      `global "${key}" cannot be installed.`,
      { stage: 'globals.install', cause },
    );
  }
}

function installProviderGlobals(gpu, enumValues, mode) {
  const snapshots = [];
  const installedNames = [];
  if (mode === 'none') {
    return { snapshots, installedNames };
  }

  try {
    let navigatorObject = globalThis.navigator;
    if (navigatorObject === undefined) {
      snapshots.push(snapshotProperty(globalThis, 'navigator'));
      navigatorObject = {};
      Object.defineProperty(globalThis, 'navigator', {
        value: navigatorObject,
        writable: true,
        configurable: true,
        enumerable: false,
      });
      installedNames.push('navigator');
    }
    defineRestorable(navigatorObject, 'gpu', gpu, mode, snapshots, installedNames, 'navigator.gpu');
    for (const name of REQUIRED_WEBGPU_GLOBALS) {
      defineRestorable(globalThis, name, enumValues[name], mode, snapshots, installedNames);
    }
    return { snapshots, installedNames };
  } catch (error) {
    restoreSnapshots(snapshots);
    throw error;
  }
}

function restoreSnapshots(snapshots) {
  const failures = [];
  for (let index = snapshots.length - 1; index >= 0; index -= 1) {
    const snapshot = snapshots[index];
    try {
      if (snapshot.descriptor) {
        Object.defineProperty(snapshot.target, snapshot.key, snapshot.descriptor);
      } else {
        delete snapshot.target[snapshot.key];
      }
    } catch (error) {
      failures.push(`${snapshot.key}: ${errorDetail(error)}`);
    }
  }
  if (failures.length > 0) {
    throw new NodeWebGPUProviderError(
      'DOE_PROVIDER_RESTORE_FAILED',
      `failed to restore provider globals: ${failures.join('; ')}`,
      { stage: 'globals.restore' },
    );
  }
}

async function loadProvider(provider) {
  if (provider.kind === 'global') {
    const gpu = globalThis.navigator?.gpu;
    if (!gpu || typeof gpu.requestAdapter !== 'function') {
      throw new NodeWebGPUProviderError(
        'DOE_PROVIDER_GPU_INVALID',
        'global navigator.gpu.requestAdapter is unavailable.',
        { stage: 'provider.resolve', providerId: provider.id },
      );
    }
    const enums = {};
    for (const name of REQUIRED_WEBGPU_GLOBALS) {
      if (globalThis[name] === undefined) {
        throw new NodeWebGPUProviderError(
          'DOE_PROVIDER_GLOBAL_MISSING',
          `global provider is missing ${name}.`,
          { stage: 'provider.resolveGlobals', providerId: provider.id },
        );
      }
      enums[name] = globalThis[name];
    }
    return { gpu, enums, module: null };
  }

  let moduleNamespace;
  try {
    moduleNamespace = await import(provider.module);
  } catch (cause) {
    throw new NodeWebGPUProviderError(
      'DOE_PROVIDER_IMPORT_FAILED',
      `failed to import "${provider.module}": ${errorDetail(cause)}`,
      { stage: 'provider.import', providerId: provider.id, cause },
    );
  }

  const binding = resolvePath(moduleNamespace, provider.gpu.path, `provider "${provider.id}" gpu.path`);
  if (!binding.found) {
    throw new NodeWebGPUProviderError(
      'DOE_PROVIDER_BINDING_MISSING',
      `provider "${provider.id}" does not export "${provider.gpu.path}".`,
      { stage: 'provider.resolveGpu', providerId: provider.id },
    );
  }

  let gpu = binding.value;
  if (provider.gpu.kind === 'factory') {
    if (typeof gpu !== 'function') {
      throw new NodeWebGPUProviderError(
        'DOE_PROVIDER_BINDING_MISSING',
        `provider "${provider.id}" binding "${provider.gpu.path}" is not a factory.`,
        { stage: 'provider.resolveGpu', providerId: provider.id },
      );
    }
    try {
      gpu = await gpu.apply(binding.parent, provider.gpu.args);
    } catch (cause) {
      throw new NodeWebGPUProviderError(
        'DOE_PROVIDER_FACTORY_FAILED',
        `provider "${provider.id}" factory failed: ${errorDetail(cause)}`,
        { stage: 'provider.createGpu', providerId: provider.id, cause },
      );
    }
    if (provider.gpu.resultPath !== null) {
      const result = resolvePath(gpu, provider.gpu.resultPath, `provider "${provider.id}" gpu.resultPath`);
      if (!result.found) {
        throw new NodeWebGPUProviderError(
          'DOE_PROVIDER_BINDING_MISSING',
          `provider "${provider.id}" factory result is missing "${provider.gpu.resultPath}".`,
          { stage: 'provider.createGpu', providerId: provider.id },
        );
      }
      gpu = result.value;
    }
  }
  if (!gpu || typeof gpu.requestAdapter !== 'function') {
    throw new NodeWebGPUProviderError(
      'DOE_PROVIDER_GPU_INVALID',
      `provider "${provider.id}" did not resolve a GPU object with requestAdapter().`,
      { stage: 'provider.resolveGpu', providerId: provider.id },
    );
  }

  const enums = {};
  for (const name of REQUIRED_WEBGPU_GLOBALS) {
    const bindingValue = resolvePath(
      moduleNamespace,
      provider.globals[name],
      `provider "${provider.id}" globals.${name}`,
    );
    if (!bindingValue.found || bindingValue.value == null) {
      throw new NodeWebGPUProviderError(
        'DOE_PROVIDER_GLOBAL_MISSING',
        `provider "${provider.id}" is missing ${name} at "${provider.globals[name]}".`,
        { stage: 'provider.resolveGlobals', providerId: provider.id },
      );
    }
    enums[name] = bindingValue.value;
  }
  return { gpu, enums, module: moduleNamespace };
}

async function requestDeclaredAdapter(provider, gpu, adapterOptions) {
  try {
    const adapter = adapterOptions === null
      ? await gpu.requestAdapter()
      : await gpu.requestAdapter(adapterOptions);
    if (!adapter) {
      throw new NodeWebGPUProviderError(
        'DOE_PROVIDER_ADAPTER_UNAVAILABLE',
        `provider "${provider.id}" returned no adapter for the declared adapterOptions.`,
        { stage: 'provider.requestAdapter', providerId: provider.id },
      );
    }
    return adapter;
  } catch (cause) {
    if (cause instanceof NodeWebGPUProviderError) throw cause;
    throw new NodeWebGPUProviderError(
      'DOE_PROVIDER_ADAPTER_UNAVAILABLE',
      `provider "${provider.id}" requestAdapter failed: ${errorDetail(cause)}`,
      { stage: 'provider.requestAdapter', providerId: provider.id, cause },
    );
  }
}

export class NodeWebGPUProviderError extends Error {
  constructor(code, message, options = {}) {
    super(message, options.cause === undefined ? undefined : { cause: options.cause });
    this.name = 'NodeWebGPUProviderError';
    this.code = code;
    this.stage = options.stage ?? 'provider';
    this.providerId = options.providerId ?? null;
    this.receipt = options.receipt ?? null;
  }
}

export function hasNavigatorGpu() {
  return typeof globalThis.navigator !== 'undefined'
    && !!globalThis.navigator?.gpu
    && typeof globalThis.navigator.gpu.requestAdapter === 'function';
}

export function hasGpuEnums() {
  return REQUIRED_WEBGPU_GLOBALS.every((name) => globalThis[name] !== undefined);
}

// Compatibility helper. New code should use openNodeWebGPU() so restoration is owned.
export function installNavigatorGpu(gpu, options = {}) {
  if (!gpu || typeof gpu.requestAdapter !== 'function') return false;
  const mode = options.force === true ? 'replace' : 'install-missing';
  try {
    let navigatorObject = globalThis.navigator;
    if (navigatorObject === undefined) {
      Object.defineProperty(globalThis, 'navigator', {
        value: {},
        writable: true,
        configurable: true,
        enumerable: false,
      });
      navigatorObject = globalThis.navigator;
    }
    if (mode === 'install-missing' && navigatorObject.gpu !== undefined) {
      return navigatorObject.gpu === gpu;
    }
    Object.defineProperty(navigatorObject, 'gpu', {
      value: gpu,
      writable: true,
      configurable: true,
      enumerable: false,
    });
  } catch {
    return false;
  }
  return true;
}

export async function openNodeWebGPU(options) {
  const normalized = normalizeOpenOptions(options);
  const receipt = createReceipt(normalized);

  for (const provider of normalized.providers) {
    let installed = null;
    try {
      const resolved = await loadProvider(provider);
      const adapter = await requestDeclaredAdapter(provider, resolved.gpu, normalized.adapterOptions);
      installed = installProviderGlobals(
        resolved.gpu,
        resolved.enums,
        normalized.globals.mode,
      );
      receipt.attempts.push({
        providerId: provider.id,
        kind: provider.kind,
        module: provider.kind === 'module' ? provider.module : null,
        ok: true,
        stage: 'complete',
        code: null,
        detail: null,
      });
      receipt.selectedProviderId = provider.id;
      receipt.ok = true;
      receipt.globals.installed = [...installed.installedNames];

      let closed = false;
      return Object.freeze({
        gpu: resolved.gpu,
        adapter,
        module: resolved.module,
        receipt,
        async close() {
          if (closed) return;
          restoreSnapshots(installed.snapshots);
          receipt.globals.restored = true;
          closed = true;
        },
      });
    } catch (error) {
      if (installed?.snapshots?.length > 0) {
        restoreSnapshots(installed.snapshots);
      }
      receipt.attempts.push(attemptFailure(provider, error));
    }
  }

  throw new NodeWebGPUProviderError(
    'DOE_PROVIDER_ALL_FAILED',
    `all declared Node WebGPU providers failed: ${receipt.attempts.map((attempt) => `${attempt.providerId}:${attempt.code}`).join(', ')}`,
    { stage: 'provider.select', receipt },
  );
}

export async function probeNodeWebGPU(options) {
  try {
    const session = await openNodeWebGPU(options);
    return { ok: true, session, receipt: session.receipt, error: null };
  } catch (error) {
    if (!(error instanceof NodeWebGPUProviderError)) throw error;
    return { ok: false, session: null, receipt: error.receipt, error };
  }
}

export function validateGovernedNodeWebGPUReceipt(receipt) {
  const errors = [];
  if (!receipt || typeof receipt !== 'object' || Array.isArray(receipt)) {
    return { valid: false, errors: ['receipt must be an object'] };
  }
  if (receipt.schema !== NODE_WEBGPU_GOVERNED_RECEIPT_SCHEMA) {
    errors.push(`schema must be ${NODE_WEBGPU_GOVERNED_RECEIPT_SCHEMA}`);
  }
  if (!['oracle-pass', 'pass', 'failed'].includes(receipt.status)) {
    errors.push('status is invalid');
  }
  if (!['inference-complete-release-pending', 'release-complete'].includes(receipt.checkpoint)) {
    errors.push('checkpoint is invalid');
  }
  for (const [field, value] of [
    ['workload', receipt.workload],
    ['provider', receipt.provider],
    ['adapterInfo', receipt.adapterInfo],
    ['oracle', receipt.oracle],
    ['execution', receipt.execution],
    ['lifecycle', receipt.lifecycle],
    ['replay', receipt.replay],
  ]) {
    if (!value || typeof value !== 'object' || Array.isArray(value)) {
      errors.push(`${field} must be an object`);
    }
  }
  if (!Array.isArray(receipt.errors)) errors.push('errors must be an array');
  if (errors.length > 0) return { valid: false, errors };

  if (!['pass', 'fail'].includes(receipt.oracle.status)) {
    errors.push('oracle.status is invalid');
  }
  if (!['release-pending', 'release-complete', 'release-failed', 'not-opened'].includes(
    receipt.lifecycle.status,
  )) {
    errors.push('lifecycle.status is invalid');
  }
  if (!Number.isInteger(receipt.workload.inputBytes) || receipt.workload.inputBytes < 0) {
    errors.push('workload.inputBytes must be a non-negative integer');
  }
  if (
    receipt.oracle.outputBytes !== null
    && (!Number.isInteger(receipt.oracle.outputBytes) || receipt.oracle.outputBytes < 0)
  ) {
    errors.push('oracle.outputBytes must be null or a non-negative integer');
  }
  if (
    receipt.execution.durationMs !== null
    && (!Number.isFinite(receipt.execution.durationMs) || receipt.execution.durationMs < 0)
  ) {
    errors.push('execution.durationMs must be null or a non-negative finite number');
  }
  for (const [index, error] of receipt.errors.entries()) {
    if (
      !error
      || typeof error !== 'object'
      || typeof error.code !== 'string'
      || typeof error.stage !== 'string'
      || typeof error.detail !== 'string'
    ) {
      errors.push(`errors[${index}] is invalid`);
    } else if (!NODE_WEBGPU_GOVERNED_ERROR_CODES.includes(error.code)) {
      errors.push(`errors[${index}].code is not recognized by schema v1`);
    }
  }

  for (const [field, value] of [
    ['workload.implementationSha256', receipt.workload.implementationSha256],
    ['workload.inputSha256', receipt.workload.inputSha256],
    ['workload.oracle.expectedOutputSha256', receipt.workload.oracle?.expectedOutputSha256],
    ['oracle.expectedOutputSha256', receipt.oracle.expectedOutputSha256],
    ['replay.workloadSha256', receipt.replay.workloadSha256],
    ['replay.executionSha256', receipt.replay.executionSha256],
  ]) {
    if (typeof value !== 'string' || !SHA256_PATTERN.test(value)) {
      errors.push(`${field} must be a lowercase SHA-256 digest`);
    }
  }
  if (
    receipt.oracle.actualOutputSha256 !== null
    && (typeof receipt.oracle.actualOutputSha256 !== 'string'
      || !SHA256_PATTERN.test(receipt.oracle.actualOutputSha256))
  ) {
    errors.push('oracle.actualOutputSha256 must be null or a lowercase SHA-256 digest');
  }
  if (receipt.workload.oracle?.kind !== 'sha256-exact' || receipt.oracle.kind !== 'sha256-exact') {
    errors.push('only the sha256-exact oracle is valid for schema v1');
  }
  if (receipt.workload.oracle?.expectedOutputSha256 !== receipt.oracle.expectedOutputSha256) {
    errors.push('workload and oracle expected-output identities differ');
  }
  if (
    receipt.oracle.status === 'pass'
    && receipt.oracle.actualOutputSha256 !== receipt.oracle.expectedOutputSha256
  ) {
    errors.push('passing oracle requires matching actual and expected output identities');
  }
  if (
    receipt.provider.selectedProviderId
    !== (receipt.provider.receipt?.selectedProviderId ?? null)
  ) {
    errors.push('provider selected identity does not match the provider receipt');
  }
  const expectedWorkloadSha256 = stableSha256(receipt.workload);
  if (receipt.replay.workloadSha256 !== expectedWorkloadSha256) {
    errors.push('replay.workloadSha256 does not match the workload contract');
  }
  const expectedExecutionSha256 = governedExecutionIdentity(receipt);
  if (receipt.replay.executionSha256 !== expectedExecutionSha256) {
    errors.push('replay.executionSha256 does not match provider and adapter identity');
  }
  if (!['observed', 'absent', 'query-failed'].includes(receipt.adapterInfoStatus)) {
    errors.push('adapterInfoStatus is invalid');
  } else if (receipt.adapterInfoStatus !== adapterInfoStatus(receipt.adapterInfo)) {
    errors.push('adapterInfoStatus does not match adapterInfo');
  }
  if (receipt.status === 'oracle-pass') {
    if (receipt.checkpoint !== 'inference-complete-release-pending') {
      errors.push('oracle-pass status requires the pre-release checkpoint');
    }
    if (receipt.oracle.status !== 'pass' || receipt.lifecycle.status !== 'release-pending') {
      errors.push('oracle-pass status requires a passing oracle and pending release');
    }
    if (receipt.errors.length !== 0) {
      errors.push('oracle-pass status cannot contain errors');
    }
  }
  if (receipt.status === 'pass') {
    if (receipt.checkpoint !== 'release-complete') {
      errors.push('pass status requires the terminal checkpoint');
    }
    if (
      receipt.oracle.status !== 'pass'
      || receipt.lifecycle.status !== 'release-complete'
      || receipt.lifecycle.globalsRestored !== true
      || receipt.errors.length !== 0
    ) {
      errors.push('pass status requires oracle pass, completed release, restored globals, and no errors');
    }
  }
  if (receipt.status === 'failed' && receipt.errors.length === 0) {
    errors.push('failed status requires at least one error');
  }
  return { valid: errors.length === 0, errors };
}

/**
 * Execute one exact-output workload through an explicitly declared Node WebGPU
 * provider. The checkpoint sink is called once before provider release and
 * once after release so a native teardown failure cannot erase completed-work
 * evidence already persisted by the caller.
 */
export async function runGovernedNodeWebGPU(options) {
  let workload;
  try {
    if (!options || typeof options !== 'object' || Array.isArray(options)) {
      throw new TypeError('governed execution options must be an object.');
    }
    if (typeof options.execute !== 'function') {
      throw new TypeError('execute must be a function.');
    }
    if (options.checkpoint !== undefined && typeof options.checkpoint !== 'function') {
      throw new TypeError('checkpoint must be a function when provided.');
    }
    workload = normalizeGovernedWorkload(options.workload);
  } catch (error) {
    return {
      ok: false,
      output: null,
      receipt: null,
      errors: [governedError(
        'DOE_GOVERNED_WORKLOAD_INVALID_CONFIGURATION',
        'configuration',
        error,
      )],
    };
  }

  const errors = [];
  let session = null;
  let output = null;
  let outputSha256 = null;
  let durationMs = null;
  let adapterInfo = {};
  let providerReceipt = null;

  try {
    session = await openNodeWebGPU(options.provider);
    providerReceipt = session.receipt;
    adapterInfo = await readAdapterInfo(session.adapter);
  } catch (error) {
    errors.push(governedError(
      'DOE_GOVERNED_WORKLOAD_PROVIDER_FAILED',
      'provider.open',
      error,
    ));
    providerReceipt = error instanceof NodeWebGPUProviderError ? error.receipt : null;
  }

  const workloadIdentity = {
    id: workload.id,
    version: workload.version,
    implementationSha256: workload.implementationSha256,
    inputSha256: workload.inputSha256,
    inputBytes: workload.inputBytes,
    oracle: {
      kind: 'sha256-exact',
      expectedOutputSha256: workload.expectedOutputSha256,
    },
  };
  const workloadReplaySha256 = stableSha256(workloadIdentity);

  if (session) {
    const start = performance.now();
    try {
      output = byteView(await options.execute({
        gpu: session.gpu,
        adapter: session.adapter,
        module: session.module,
        input: workload.input,
      }), 'execute output');
      durationMs = performance.now() - start;
      outputSha256 = sha256(output);
      if (outputSha256 !== workload.expectedOutputSha256) {
        errors.push({
          code: 'DOE_GOVERNED_WORKLOAD_ORACLE_FAILED',
          stage: 'oracle.output-sha256',
          detail: `expected ${workload.expectedOutputSha256}, got ${outputSha256}`,
        });
      }
    } catch (error) {
      durationMs = performance.now() - start;
      errors.push(governedError(
        'DOE_GOVERNED_WORKLOAD_EXECUTION_FAILED',
        'workload.execute',
        error,
      ));
    }
  }

  const receipt = {
    schema: NODE_WEBGPU_GOVERNED_RECEIPT_SCHEMA,
    status: errors.length === 0 ? 'oracle-pass' : 'failed',
    checkpoint: 'inference-complete-release-pending',
    workload: workloadIdentity,
    provider: {
      selectedProviderId: providerReceipt?.selectedProviderId ?? null,
      receipt: cloneReceiptValue(providerReceipt),
    },
    adapterInfo,
    adapterInfoStatus: adapterInfoStatus(adapterInfo),
    oracle: {
      kind: 'sha256-exact',
      status: outputSha256 === workload.expectedOutputSha256 ? 'pass' : 'fail',
      expectedOutputSha256: workload.expectedOutputSha256,
      actualOutputSha256: outputSha256,
      outputBytes: output?.byteLength ?? null,
    },
    execution: {
      durationMs,
    },
    lifecycle: {
      status: session ? 'release-pending' : 'not-opened',
      globalsRestored: providerReceipt?.globals?.restored ?? false,
    },
    replay: {
      workloadSha256: workloadReplaySha256,
      executionSha256: null,
    },
    errors,
  };
  receipt.replay.executionSha256 = governedExecutionIdentity(receipt);

  await emitGovernedCheckpoint(options.checkpoint, receipt, errors);

  if (session) {
    try {
      await session.close();
      receipt.lifecycle.status = 'release-complete';
      receipt.lifecycle.globalsRestored = session.receipt.globals.restored;
    } catch (error) {
      receipt.lifecycle.status = 'release-failed';
      errors.push(governedError(
        'DOE_GOVERNED_WORKLOAD_RELEASE_FAILED',
        'provider.release',
        error,
      ));
    }
  }
  receipt.provider.receipt = cloneReceiptValue(providerReceipt);
  receipt.checkpoint = 'release-complete';
  receipt.status = errors.length === 0 ? 'pass' : 'failed';

  await emitGovernedCheckpoint(options.checkpoint, receipt, errors);
  receipt.status = errors.length === 0 ? 'pass' : 'failed';

  return {
    ok: receipt.status === 'pass',
    output,
    receipt,
    errors,
  };
}

function compatibilityGlobals() {
  return {
    GPUBufferUsage: 'globals.GPUBufferUsage',
    GPUShaderStage: 'globals.GPUShaderStage',
    GPUMapMode: 'globals.GPUMapMode',
    GPUTextureUsage: 'globals.GPUTextureUsage',
  };
}

function compatibilityProvider(providerSpecifier, id = 'explicit') {
  return {
    id,
    kind: 'module',
    module: providerSpecifier,
    gpu: {
      kind: 'factory',
      path: 'create',
      args: [['enable-dawn-features=allow_unsafe_apis']],
    },
    globals: compatibilityGlobals(),
  };
}

export async function bootstrapNodeWebGPUProvider(providerSpecifier, options = {}) {
  const provider = options.provider ?? compatibilityProvider(providerSpecifier);
  const session = await openNodeWebGPU({
    providers: [provider],
    adapterOptions: options.adapterOptions ?? null,
    globals: { mode: options.force === false ? 'install-missing' : 'replace' },
  });
  return {
    ok: true,
    provider: session.receipt.selectedProviderId,
    module: session.module,
    session,
    receipt: session.receipt,
  };
}

export async function bootstrapNodeWebGPU(options = {}) {
  const explicitModule = typeof process.env.DOE_NODE_WEBGPU_MODULE === 'string'
    ? process.env.DOE_NODE_WEBGPU_MODULE.trim()
    : '';
  const providers = explicitModule
    ? [compatibilityProvider(explicitModule, 'environment')]
    : [
      { id: 'pre-installed', kind: 'global' },
      {
        id: 'doe-native',
        kind: 'module',
        module: new URL('./native.js', import.meta.url).href,
        gpu: { kind: 'factory', path: 'createNativeDirect', args: [['enable-dawn-features=allow_unsafe_apis']] },
        globals: compatibilityGlobals(),
      },
      compatibilityProvider('webgpu', 'webgpu'),
    ];
  const result = await probeNodeWebGPU({
    providers,
    adapterOptions: options.adapterOptions ?? null,
    globals: { mode: 'replace' },
  });
  if (!result.ok) {
    return {
      ok: false,
      provider: null,
      detail: result.error.message,
      receipt: result.receipt,
      error: result.error,
    };
  }
  return {
    ok: true,
    provider: result.receipt.selectedProviderId,
    detail: null,
    session: result.session,
    receipt: result.receipt,
  };
}

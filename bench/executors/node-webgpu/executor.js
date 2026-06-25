import { existsSync, mkdirSync, readdirSync, writeFileSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { performance } from 'node:perf_hooks';
import { createHash } from 'node:crypto';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join, resolve } from 'node:path';
import os from 'node:os';

import {
  materializeBufferData,
  normalizePlan,
  planSummary,
  validateSampleExpectation,
} from './plan.js';
import {
  evaluateExecutionDeterminism,
} from './determinism.js';
import {
  describeUnusableAdapterInfo,
} from '../adapter_health.js';

const REPO_ROOT = resolve(fileURLToPath(new URL('../../..', import.meta.url)));
const FALLBACK_WEBGPU_PATH = join(
  REPO_ROOT,
  'bench/vendor/node-webgpu-package/index.js',
);
const DOE_PACKAGE_PATH = join(
  REPO_ROOT,
  'packages/doe-gpu/src/index.js',
);
const FALLBACK_BUN_WEBGPU_PATH = join(
  REPO_ROOT,
  'bench/vendor/bun-webgpu-package/index.js',
);
const DOE_BUN_PACKAGE_PATH = join(
  REPO_ROOT,
  'packages/doe-gpu/src/bun.js',
);
const DOE_BUN_FFI_PACKAGE_PATH = join(
  REPO_ROOT,
  'packages/doe-gpu/src/vendor/webgpu/bun-ffi.js',
);
const PACKAGE_EXECUTION_POLICY_PATH = join(
  REPO_ROOT,
  'config/package-execution-policy.json',
);
const DOE_DIRECT_READBACK_DIAG_FIELDS = Object.freeze([
  ['__doe_diag_map_read_copy_unmap_queue_wait_completed_ms', 'readbackMapReadCopyUnmapQueueWaitCompletedTotalNs'],
  ['__doe_diag_map_read_copy_unmap_deferred_copy_ms', 'readbackMapReadCopyUnmapDeferredCopyTotalNs'],
  ['__doe_diag_map_read_copy_unmap_deferred_resolve_ms', 'readbackMapReadCopyUnmapDeferredResolveTotalNs'],
  ['__doe_diag_map_read_copy_unmap_map_ms', 'readbackMapReadCopyUnmapMapTotalNs'],
  ['__doe_diag_map_read_copy_unmap_copy_ms', 'readbackMapReadCopyUnmapCopyTotalNs'],
  ['__doe_diag_map_read_copy_unmap_unmap_ms', 'readbackMapReadCopyUnmapUnmapTotalNs'],
]);

const PROVIDERS_BY_RUNTIME = Object.freeze({
  node: Object.freeze({
    'node-webgpu': {
      provider: 'node-webgpu',
      providerName: 'node-webgpu',
      executionBackend: 'node_webgpu_package',
      loader: 'node-dawn',
    },
    doe: {
      provider: 'doe',
      providerName: 'doe-gpu',
      executionBackend: 'doe_node_webgpu',
      loader: 'node-doe',
    },
    'doe-direct': {
      provider: 'doe-direct',
      providerName: 'doe-gpu/native-direct',
      executionBackend: 'doe_node_native_direct',
      loader: 'node-doe-direct',
    },
  }),
  bun: Object.freeze({
    'bun-webgpu': {
      provider: 'bun-webgpu',
      providerName: 'bun-webgpu',
      executionBackend: 'bun_webgpu_package',
      loader: 'bun-webgpu',
    },
    doe: {
      provider: 'doe',
      providerName: 'doe-gpu',
      executionBackend: 'doe_bun_package',
      loader: 'bun-doe',
    },
    'doe-ffi': {
      provider: 'doe-ffi',
      providerName: 'doe-gpu/bun-ffi',
      executionBackend: 'doe_bun_package',
      loader: 'bun-doe-ffi',
    },
  }),
});

const TRACE_META_PROCESS_WALL_SOURCE = 'trace-meta-process-wall';
const DEBUG_PROGRESS_INTERVAL = 64;
const NODE_WEBGPU_UNSUPPORTED_ERROR_CODE = 'NODE_WEBGPU_UNSUPPORTED';
const PACKAGE_QUEUE_SYNC_MODE = 'per-command';
const PACKAGE_QUEUE_WAIT_MODE = 'queue.onSubmittedWorkDone';
const NODE_PACKAGE_QUEUE_WAIT_MODE = 'readback-or-fence.mapAsync';
const PACKAGE_QUEUE_WAIT_SCOPE = 'terminal-or-readback';
const NODE_PACKAGE_QUEUE_WAIT_SCOPE = PACKAGE_QUEUE_WAIT_SCOPE;
const NODE_PACKAGE_QUEUE_WAIT_SUBMIT_CADENCE = 0;
const QUEUE_WAIT_FENCE_SIZE_BYTES = 4;
const PACKAGE_WRITE_BATCH_METHOD_NONE = 'none';
const PACKAGE_WRITE_BATCH_METHOD_MIXED = 'mixed';
const PACKAGE_WRITE_BATCH_METHOD_DIRECT_QUEUE = 'queue.writeBufferBatch.compact';
const PACKAGE_WRITE_BATCH_METHOD_DOE_QUEUE = 'queue.__doeWriteBufferBatch';
const MAX_COMPACT_WRITE_BATCH_BYTES = 0xffffffff;
const READBACK_DIGEST_CACHE_MAX_BYTES = 4096;
const READBACK_DIGEST_PROCESS_CACHE_MAX_ENTRIES = 1024;
const readbackDigestProcessCache = new Map();
const PACKAGE_READBACK_MODE_NATIVE = 'native-map-read-copy-unmap';
const PACKAGE_READBACK_MODE_MAP_ASYNC = 'mapAsync';
const PACKAGE_READBACK_RESULT_NATIVE = 'map-read-copy-unmap';
let packageExecutionPolicyPromise = null;

export const PROVIDER_FAILURE_REASONS = Object.freeze([
  'native_webgpu_unavailable',
  'native_addon_unavailable',
  'runtime_library_unavailable',
  'provider_unavailable',
  'adapter_unavailable',
  'provider_import_failed',
  'unsupported_runtime_host',
  'runner_error',
]);

const PROVIDER_FAILURE_REASON_SET = new Set(PROVIDER_FAILURE_REASONS);

export function normalizeProviderFailureReason(reason) {
  return PROVIDER_FAILURE_REASON_SET.has(reason) ? reason : 'runner_error';
}

export function providerAvailabilityFailure({
  reason,
  provider = '',
  providerName = '',
  runtimeHost = '',
  loader = '',
  stage = '',
  detail = '',
  externalCode = '',
}) {
  return Object.freeze({
    ok: false,
    reason: normalizeProviderFailureReason(reason),
    provider,
    providerName,
    runtimeHost,
    loader,
    stage,
    detail: String(detail ?? ''),
    ...(externalCode ? { externalCode } : {}),
  });
}

function providerAvailabilityOk({
  provider = '',
  providerName = '',
  runtimeHost = '',
  loader = '',
  stage = '',
  module = null,
}) {
  return Object.freeze({
    ok: true,
    reason: null,
    provider,
    providerName,
    runtimeHost,
    loader,
    stage,
    module,
  });
}

function attachProviderAvailability(error, availability) {
  if (!error || !availability) {
    return error;
  }
  error.providerAvailability = availability;
  error.providerFailureReason = availability.reason;
  return error;
}

function nsFromMs(ms) {
  return Math.max(0, Math.round(ms * 1_000_000));
}

function envFlagEnabled(value) {
  if (value === undefined || value === null) {
    return false;
  }
  const normalized = String(value).trim().toLowerCase();
  return normalized === '1' || normalized === 'true' || normalized === 'yes' || normalized === 'on';
}

const DOE_WEBGPU_SUBMIT_BREAKDOWN = envFlagEnabled(process.env.DOE_WEBGPU_SUBMIT_BREAKDOWN);
const VALIDATION_OK = { ok: true };

function readbackDigestCacheKey(view) {
  if (!(view instanceof Uint8Array) || view.byteLength > READBACK_DIGEST_CACHE_MAX_BYTES) {
    return '';
  }
  if (view.byteLength === 4) {
    const value = (
      view[0]
      | (view[1] << 8)
      | (view[2] << 16)
      | (view[3] << 24)
    ) >>> 0;
    return `4u32:${value}`;
  }
  if (view.byteLength === 8) {
    const low = (
      view[0]
      | (view[1] << 8)
      | (view[2] << 16)
      | (view[3] << 24)
    ) >>> 0;
    const high = (
      view[4]
      | (view[5] << 8)
      | (view[6] << 16)
      | (view[7] << 24)
    ) >>> 0;
    return `8u32:${low}:${high}`;
  }
  let key = `${view.byteLength}:`;
  for (let index = 0; index < view.byteLength; index += 1) {
    key += String.fromCharCode(view[index]);
  }
  return key;
}

function rememberProcessReadbackDigest(cacheKey, digest) {
  if (cacheKey === '' || cacheKey === undefined || cacheKey === null) {
    return;
  }
  readbackDigestProcessCache.set(cacheKey, digest);
  if (readbackDigestProcessCache.size > READBACK_DIGEST_PROCESS_CACHE_MAX_ENTRIES) {
    const oldestKey = readbackDigestProcessCache.keys().next().value;
    readbackDigestProcessCache.delete(oldestKey);
  }
}

function digestBytes(view, cache = null, decodedU32Le = undefined) {
  if (view instanceof Uint8Array && view.byteLength === 4) {
    const cacheKey = decodedU32Le !== undefined ? decodedU32Le : decodeU32Le(view);
    if (cacheKey !== undefined) {
      const cachedDigest = cache?.get(cacheKey) ?? readbackDigestProcessCache.get(cacheKey);
      if (cachedDigest) {
        cache?.set(cacheKey, cachedDigest);
        return cachedDigest;
      }
      const digest = createHash('sha256').update(view).digest('hex');
      cache?.set(cacheKey, digest);
      rememberProcessReadbackDigest(cacheKey, digest);
      return digest;
    }
  }
  const cacheKey = readbackDigestCacheKey(view);
  if (cacheKey) {
    const cachedDigest = cache?.get(cacheKey) ?? readbackDigestProcessCache.get(cacheKey);
    if (cachedDigest) {
      cache?.set(cacheKey, cachedDigest);
      return cachedDigest;
    }
  }
  const digest = createHash('sha256').update(view).digest('hex');
  if (cacheKey) {
    cache?.set(cacheKey, digest);
    rememberProcessReadbackDigest(cacheKey, digest);
  }
  return digest;
}

function stableArtifactHash(payload) {
  return createHash('sha256').update(JSON.stringify(payload), 'utf8').digest('hex');
}

function digestText(text) {
  return createHash('sha256').update(text, 'utf8').digest('hex');
}

export function buildShaderSourceReceipt(moduleDef, code) {
  if (typeof code !== 'string') {
    throw new Error(`shader module ${moduleDef?.id ?? '<unknown>'} source must be a string`);
  }
  const source = moduleDef?.source ?? {};
  const receipt = {
    moduleId: moduleDef?.id ?? '',
    sourceKind: source.kind ?? '',
    byteLength: Buffer.byteLength(code, 'utf8'),
    sha256: digestText(code),
  };
  if (typeof source.path === 'string') {
    receipt.path = source.path;
  }
  if (typeof moduleDef?.entryPoint === 'string') {
    receipt.entryPoint = moduleDef.entryPoint;
  }
  return receipt;
}

function shaderSourceReceiptFields(shaderSourceReceipts) {
  return {
    shaderSourceReceipts,
    shaderSourceReceiptsHash: stableArtifactHash(shaderSourceReceipts),
  };
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

function sha256Urn(value) {
  if (typeof value !== 'string' || value.length === 0) {
    return null;
  }
  return value.startsWith('sha256:') ? value : `sha256:${value}`;
}

export function collectPackageDispatchShaderEvidence({
  normalizedPlan,
  shaderSourceReceipts = [],
  shaderModuleEvidenceInputs = [],
  dispatchStates = [],
  readbackCaptures = [],
}) {
  const modules = Array.isArray(normalizedPlan?.modules) ? normalizedPlan.modules : [];
  const steps = Array.isArray(normalizedPlan?.steps) ? normalizedPlan.steps : [];
  const receiptsByModule = new Map(
    shaderSourceReceipts.map((receipt) => [receipt.moduleId, receipt]),
  );
  const evidenceInputsByModule = new Map(
    shaderModuleEvidenceInputs.map((entry) => [entry.moduleId, entry]),
  );
  const missing = [];
  const shaderModules = modules.map((moduleDef) => {
    const receipt = receiptsByModule.get(moduleDef.id) ?? {};
    const evidenceInput = evidenceInputsByModule.get(moduleDef.id) ?? {};
    const sourcePath = (
      typeof evidenceInput.sourcePath === 'string'
        ? evidenceInput.sourcePath
        : typeof receipt.path === 'string'
          ? receipt.path
        : moduleDef.source?.kind === 'file' && typeof moduleDef.source?.path === 'string'
          ? moduleDef.source.path
          : null
    );
    const sourceSha256 = sha256Urn(evidenceInput.sourceSha256 ?? receipt.sha256);
    const workgroupSize = Array.isArray(evidenceInput.workgroupSize)
      ? [...evidenceInput.workgroupSize]
      : Array.isArray(moduleDef.workgroupSize)
        ? [...moduleDef.workgroupSize]
      : null;
    if (!sourceSha256) {
      missing.push({
        field: 'shaderModules.sourceSha256',
        moduleId: moduleDef.id,
        reason: 'shader_source_receipt_unavailable',
      });
    }
    if (!workgroupSize) {
      missing.push({
        field: 'shaderModules.workgroupSize',
        moduleId: moduleDef.id,
        reason: 'workgroup_size_unavailable',
      });
    }
    return {
      moduleId: moduleDef.id,
      sourcePath,
      sourceSha256,
      entryPoint: evidenceInput.entryPoint ?? receipt.entryPoint ?? moduleDef.entryPoint ?? null,
      workgroupSize,
    };
  });
  const moduleEntryPoints = new Map(
    modules.map((moduleDef) => [moduleDef.id, moduleDef.entryPoint ?? null]),
  );
  let dispatchIndex = 0;
  const dispatches = [];
  for (const step of steps) {
    if (step?.kind !== 'dispatch') {
      continue;
    }
    const state = dispatchStates[dispatchIndex] ?? null;
    const entryPoint = (
      state?.entryPoint
      ?? step.entryPoint
      ?? moduleEntryPoints.get(step.moduleId)
      ?? null
    );
    dispatches.push({
      dispatchIndex,
      pipelineId: state?.pipelineId ?? null,
      shaderModuleId: state?.shaderModuleId ?? step.moduleId ?? null,
      entryPoint,
      workgroups: Array.isArray(step.workgroups) ? [...step.workgroups] : null,
    });
    if (!state?.pipelineId) {
      missing.push({
        field: 'dispatches.pipelineId',
        dispatchIndex,
        reason: 'pipeline_state_unavailable',
      });
    }
    dispatchIndex += 1;
  }
  const lastDigestCapture = [...readbackCaptures]
    .reverse()
    .find((capture) => typeof capture?.sha256 === 'string' && capture.sha256);
  const outputDigest = sha256Urn(lastDigestCapture?.sha256);
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

async function readShaderSource(moduleDef) {
  if (moduleDef.source.kind === 'inline') {
    return moduleDef.source.code;
  }
  return readFile(resolve(REPO_ROOT, moduleDef.source.path), 'utf8');
}

async function collectShaderSourceReceipts(normalizedPlan) {
  const receipts = [];
  for (const moduleDef of normalizedPlan.modules) {
    const code = await readShaderSource(moduleDef);
    receipts.push(buildShaderSourceReceipt(moduleDef, code));
  }
  return receipts;
}

function decodeU32Le(view) {
  if (!(view instanceof Uint8Array) || view.byteLength < 4) {
    return undefined;
  }
  return (
    view[0]
    | (view[1] << 8)
    | (view[2] << 16)
    | (view[3] << 24)
  ) >>> 0;
}

function buildReadbackCaptureTemplate(stepIndex, step) {
  const fields = {};
  if (typeof step?.bufferId === 'string') fields.bufferId = step.bufferId;
  if (typeof step?.semanticOpId === 'string') fields.semanticOpId = step.semanticOpId;
  if (typeof step?.semanticStage === 'string') fields.semanticStage = step.semanticStage;
  if (typeof step?.semanticPhase === 'string') fields.semanticPhase = step.semanticPhase;
  if (Number.isInteger(step?.semanticTokenIndex)) fields.semanticTokenIndex = step.semanticTokenIndex;
  if (Number.isInteger(step?.semanticLayerIndex)) fields.semanticLayerIndex = step.semanticLayerIndex;
  if (typeof step?.semanticExecutionPlanHash === 'string') {
    fields.semanticExecutionPlanHash = step.semanticExecutionPlanHash;
  }
  if (typeof step?.captureSourceBufferId === 'string') {
    fields.captureSourceBufferId = step.captureSourceBufferId;
  }
  if (Number.isInteger(step?.captureOffset)) fields.captureOffset = step.captureOffset;
  if (Number.isInteger(step?.captureSize)) fields.captureSize = step.captureSize;
  if (typeof step?.captureDecode === 'string') fields.captureDecode = step.captureDecode;
  let expectedU32Le;
  let expectedU32Sha256;
  if (
    step?.validate?.kind === 'u32PrefixEquals'
    && Array.isArray(step.validate.values)
    && step.validate.values.length === 1
  ) {
    const value = Number(step.validate.values[0]);
    if (Number.isInteger(value) && value >= 0 && value <= 0xffffffff) {
      expectedU32Le = value >>> 0;
      const expectedBytes = Buffer.allocUnsafe(4);
      expectedBytes.writeUInt32LE(expectedU32Le, 0);
      expectedU32Sha256 = createHash('sha256').update(expectedBytes).digest('hex');
    }
  }
  return {
    stepIndex,
    stepId: typeof step?.id === 'string' ? step.id : `step-${stepIndex}`,
    fields,
    expectedU32Le,
    expectedU32Sha256,
  };
}

function buildDeterminismCaptureTemplate(step) {
  if (typeof step?.semanticPhase !== 'string') {
    return null;
  }
  const semanticTokenIndex = Number.isInteger(step.semanticTokenIndex) ? step.semanticTokenIndex : 0;
  return {
    key: `${semanticTokenIndex}:${step.semanticPhase}`,
    row: {
      bytes: null,
      semanticOpId: typeof step.semanticOpId === 'string' ? step.semanticOpId : null,
      semanticStage: typeof step.semanticStage === 'string' ? step.semanticStage : null,
      semanticPhase: step.semanticPhase,
      semanticTokenIndex,
    },
  };
}

function buildValidationTemplate(expectation) {
  if (!expectation || typeof expectation !== 'object' || Array.isArray(expectation)) {
    return null;
  }
  if (expectation.kind === 'f32PrefixEquals' || expectation.kind === 'u32PrefixEquals') {
    const values = Array.isArray(expectation.values) ? expectation.values.map((value) => Number(value)) : [];
    return {
      kind: expectation.kind,
      values,
      singleU32Expected: expectation.kind === 'u32PrefixEquals' && values.length === 1
        ? values[0] >>> 0
        : undefined,
      cachePrefix: `${expectation.kind}:${values.join(',')}:`,
    };
  }
  return { expectation };
}

function validatePreparedSampleExpectation(view, template, cache = null) {
  if (!template) {
    return VALIDATION_OK;
  }
  if (template.singleU32Expected !== undefined) {
    const expected = template.singleU32Expected;
    const actual = decodeU32Le(view);
    if (actual !== expected) {
      return {
        ok: false,
        detail: `expected uint32[0] === ${expected}, got ${actual}`,
      };
    }
    return VALIDATION_OK;
  }
  const cacheKey = cache && template.cachePrefix
    ? `${template.cachePrefix}${readbackDigestCacheKey(view)}`
    : '';
  if (cacheKey && cache.get(cacheKey) === true) {
    return { ok: true };
  }
  if (template.kind === 'f32PrefixEquals') {
    const { values } = template;
    const actual = new Float32Array(view.buffer, view.byteOffset, Math.min(values.length, view.byteLength / 4));
    for (let index = 0; index < values.length; index += 1) {
      if (actual[index] !== values[index]) {
        return {
          ok: false,
          detail: `expected float32[${index}] === ${values[index]}, got ${actual[index]}`,
        };
      }
    }
    if (cacheKey) cache.set(cacheKey, true);
    return VALIDATION_OK;
  }
  if (template.kind === 'u32PrefixEquals') {
    const { values } = template;
    const actual = new Uint32Array(view.buffer, view.byteOffset, Math.min(values.length, view.byteLength / 4));
    for (let index = 0; index < values.length; index += 1) {
      if (actual[index] !== values[index]) {
        return {
          ok: false,
          detail: `expected uint32[${index}] === ${values[index]}, got ${actual[index]}`,
        };
      }
    }
    if (cacheKey) cache.set(cacheKey, true);
    return VALIDATION_OK;
  }
  return validateSampleExpectation(view, template.expectation);
}

function summarizePreparedReadbackCapture(repeatIndex, view, captureTemplate, digestCache) {
  const decodedU32Le = decodeU32Le(view);
  const sha256 = (
    view.byteLength === 4
    && decodedU32Le !== undefined
    && decodedU32Le === captureTemplate.expectedU32Le
    && typeof captureTemplate.expectedU32Sha256 === 'string'
  )
    ? captureTemplate.expectedU32Sha256
    : digestBytes(view, digestCache, decodedU32Le);
  const summary = {
    repeatIndex,
    stepIndex: captureTemplate.stepIndex,
    stepId: captureTemplate.stepId,
    byteLength: view.byteLength,
    sha256,
  };
  if (decodedU32Le !== undefined) summary.decodedU32Le = decodedU32Le;
  Object.assign(summary, captureTemplate.fields);
  return summary;
}

export function summarizeReadbackCapture({
  repeatIndex,
  stepIndex,
  step,
  bytes,
  digestCache = null,
  template = null,
}) {
  const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes ?? []);
  const captureTemplate = template ?? buildReadbackCaptureTemplate(stepIndex, step);
  return summarizePreparedReadbackCapture(repeatIndex, view, captureTemplate, digestCache);
}

export function materializeWriteBufferDataForStep(cache, stepIndex, bufferData) {
  if (cache.has(stepIndex)) {
    return cache.get(stepIndex);
  }
  const materialized = materializeBufferData(bufferData);
  cache.set(stepIndex, materialized);
  return materialized;
}

function nsDelta(startedAtMs) {
  return nsFromMs(performance.now() - startedAtMs);
}

function emptyReadbackBreakdownNs() {
  return {
    readbackMapReadCopyUnmapTotalNs: 0,
    readbackMapReadCopyUnmapQueueWaitCompletedTotalNs: 0,
    readbackMapReadCopyUnmapDeferredCopyTotalNs: 0,
    readbackMapReadCopyUnmapDeferredResolveTotalNs: 0,
    readbackMapReadCopyUnmapMapTotalNs: 0,
    readbackMapReadCopyUnmapCopyTotalNs: 0,
    readbackMapReadCopyUnmapUnmapTotalNs: 0,
    readbackMapAsyncTotalNs: 0,
    readbackGetMappedRangeTotalNs: 0,
    readbackHostCopyTotalNs: 0,
    readbackNativeReadCopyTotalNs: 0,
    readbackUnmapTotalNs: 0,
    readbackValidationTotalNs: 0,
    readbackCaptureTotalNs: 0,
  };
}

function addReadbackBreakdown(target, source) {
  for (const [key, value] of Object.entries(source)) {
    target[key] = (target[key] ?? 0) + value;
  }
}

function readDoeDirectReadbackDiagnosticsNs(buffer) {
  if (!DOE_WEBGPU_SUBMIT_BREAKDOWN) {
    return null;
  }
  const values = {};
  const jsBreakdown = buffer?.__doe_readback_breakdown_ns;
  if (jsBreakdown && typeof jsBreakdown === 'object') {
    for (const [, breakdownName] of DOE_DIRECT_READBACK_DIAG_FIELDS) {
      const value = Number(jsBreakdown[breakdownName]);
      if (Number.isFinite(value) && value > 0) {
        values[breakdownName] = Math.round(value);
      }
    }
  }
  for (const [propertyName, breakdownName] of DOE_DIRECT_READBACK_DIAG_FIELDS) {
    const value = Number(buffer?.[propertyName]);
    if (Number.isFinite(value) && value > 0) {
      values[breakdownName] = nsFromMs(value);
    }
  }
  return values;
}

function viewFromReadbackCopy(value, expectedBytes) {
  let view;
  if (value instanceof Uint8Array) {
    view = value;
  } else if (ArrayBuffer.isView(value)) {
    view = new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  } else if (value instanceof ArrayBuffer) {
    view = new Uint8Array(value);
  } else {
    throw new Error('readback copy did not return an ArrayBuffer-compatible value');
  }
  if (view.byteLength !== expectedBytes) {
    throw new Error(`readback copy returned ${view.byteLength} bytes, expected ${expectedBytes}`);
  }
  return view;
}

function packageReadbackModeFromEnv() {
  if (process.env.DOE_PACKAGE_READBACK_MODE === PACKAGE_READBACK_MODE_MAP_ASYNC) {
    return PACKAGE_READBACK_MODE_MAP_ASYNC;
  }
  if (process.env.DOE_PACKAGE_READBACK_MODE === PACKAGE_READBACK_MODE_NATIVE) {
    return PACKAGE_READBACK_MODE_NATIVE;
  }
  return '';
}

export function effectivePackageReadbackPath(readbackPath) {
  return readbackPath === PACKAGE_READBACK_RESULT_NATIVE
    ? PACKAGE_READBACK_MODE_NATIVE
    : PACKAGE_READBACK_MODE_MAP_ASYNC;
}

export async function copyReadBufferBytes({
  buffer,
  globals,
  sizeBytes,
  readbackMode = PACKAGE_READBACK_MODE_NATIVE,
}) {
  const expectedBytes = normalizePositiveInt(sizeBytes, 'readBuffer.sizeBytes');
  const breakdownNs = emptyReadbackBreakdownNs();

  if (
    readbackMode !== PACKAGE_READBACK_MODE_MAP_ASYNC
    && typeof buffer?._mapReadCopyUnmap === 'function'
  ) {
    const fastStartedAt = performance.now();
    const copied = buffer._mapReadCopyUnmap(globals.GPUMapMode.READ, 0, expectedBytes);
    const fastNs = nsDelta(fastStartedAt);
    if (copied !== null && copied !== undefined) {
      breakdownNs.readbackMapReadCopyUnmapTotalNs += fastNs;
      const directDiagnostics = readDoeDirectReadbackDiagnosticsNs(buffer);
      if (directDiagnostics) {
        addReadbackBreakdown(breakdownNs, directDiagnostics);
      }
      return {
        bytes: viewFromReadbackCopy(copied, expectedBytes),
        breakdownNs,
        path: 'map-read-copy-unmap',
      };
    }
  }

  const mapStartedAt = performance.now();
  await buffer.mapAsync(globals.GPUMapMode.READ);
  breakdownNs.readbackMapAsyncTotalNs += nsDelta(mapStartedAt);

  try {
    if (typeof buffer?._readCopy === 'function') {
      const readCopyStartedAt = performance.now();
      const copied = buffer._readCopy(0, expectedBytes);
      breakdownNs.readbackNativeReadCopyTotalNs += nsDelta(readCopyStartedAt);
      if (copied !== null && copied !== undefined) {
        return {
          bytes: viewFromReadbackCopy(copied, expectedBytes),
          breakdownNs,
          path: 'mapped-native-read-copy',
        };
      }
    }

    const mappedRangeStartedAt = performance.now();
    const mappedRange = buffer.getMappedRange(0, expectedBytes);
    breakdownNs.readbackGetMappedRangeTotalNs += nsDelta(mappedRangeStartedAt);
    const copyStartedAt = performance.now();
    const bytes = new Uint8Array(mappedRange).slice();
    breakdownNs.readbackHostCopyTotalNs += nsDelta(copyStartedAt);
    return {
      bytes,
      breakdownNs,
      path: 'mapped-range-host-copy',
    };
  } finally {
    const unmapStartedAt = performance.now();
    buffer.unmap();
    breakdownNs.readbackUnmapTotalNs += nsDelta(unmapStartedAt);
  }
}

function parseOptionalPositiveInt(value) {
  const normalized = typeof value === 'string' ? value.trim() : '';
  if (!normalized) {
    return 0;
  }
  const parsed = Number(normalized);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    throw new Error(`expected a positive integer, got: ${value}`);
  }
  return parsed;
}

function normalizePositiveInt(value, fieldName) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    throw new Error(`expected a positive integer for ${fieldName}, got: ${value}`);
  }
  return parsed;
}

function createDebugLogger(enabled) {
  return (phase, fields = {}) => {
    if (!enabled) {
      return;
    }
    process.stderr.write(`${JSON.stringify({
      kind: 'package_webgpu_debug',
      phase,
      ...fields,
    })}\n`);
  };
}

function queueWaitSubmitCadenceForRuntimeHost(runtimeHost) {
  return runtimeHost === 'node' ? NODE_PACKAGE_QUEUE_WAIT_SUBMIT_CADENCE : 0;
}

function queueWaitModeForRuntimeHost(runtimeHost) {
  return runtimeHost === 'node' || runtimeHost === 'bun'
    ? NODE_PACKAGE_QUEUE_WAIT_MODE
    : PACKAGE_QUEUE_WAIT_MODE;
}

function providerCreateOptions(spec) {
  return [];
}

function queueWaitScopeForRuntimeHost(runtimeHost) {
  return queueWaitSubmitCadenceForRuntimeHost(runtimeHost) > 0
    ? NODE_PACKAGE_QUEUE_WAIT_SCOPE
    : PACKAGE_QUEUE_WAIT_SCOPE;
}

export function queueWaitNeedsPreYield(runtime) {
  return runtime.queueWaitMode === NODE_PACKAGE_QUEUE_WAIT_MODE
    && !String(runtime.providerSpec?.provider ?? '').startsWith('doe');
}

async function maybeYieldBeforeQueueWait(runtime) {
  if (!queueWaitNeedsPreYield(runtime)) {
    return;
  }
  await new Promise((resolve) => setTimeout(resolve, 0));
}

function createQueueWaitFence(device, queue, globals) {
  const signal = device.createBuffer({
    size: QUEUE_WAIT_FENCE_SIZE_BYTES,
    usage: globals.GPUBufferUsage.COPY_SRC | globals.GPUBufferUsage.COPY_DST,
  });
  queue.writeBuffer(signal, 0, new Uint32Array(1));
  const readback = device.createBuffer({
    size: QUEUE_WAIT_FENCE_SIZE_BYTES,
    usage: globals.GPUBufferUsage.COPY_DST | globals.GPUBufferUsage.MAP_READ,
  });
  return { signal, readback };
}

function appendQueueWaitFenceCopy(runtime, encoder) {
  if (!runtime.queueWaitFence) {
    return;
  }
  encoder.copyBufferToBuffer(
    runtime.queueWaitFence.signal,
    0,
    runtime.queueWaitFence.readback,
    0,
    QUEUE_WAIT_FENCE_SIZE_BYTES,
  );
}

async function awaitQueueCompletion(runtime) {
  if (runtime.queueWaitMode === NODE_PACKAGE_QUEUE_WAIT_MODE) {
    await maybeYieldBeforeQueueWait(runtime);
    await runtime.queueWaitFence.readback.mapAsync(runtime.globals.GPUMapMode.READ);
    runtime.queueWaitFence.readback.getMappedRange(0, QUEUE_WAIT_FENCE_SIZE_BYTES);
    runtime.queueWaitFence.readback.unmap();
    return;
  }
  await maybeYieldBeforeQueueWait(runtime);
  await runtime.queue.onSubmittedWorkDone?.();
}

async function waitForQueuedWrites(runtime) {
  if (runtime.queueWaitFence) {
    const encoder = runtime.device.createCommandEncoder();
    appendQueueWaitFenceCopy(runtime, encoder);
    runtime.queue.submit([encoder.finish()]);
    await awaitQueueCompletion(runtime);
    return;
  }
  await awaitQueueCompletion(runtime);
}

export function readBufferMapCanCompleteSubmit(steps, index, step) {
  if (index !== steps.length - 1 || step?.kind !== 'readBuffer') {
    return false;
  }
  const previous = steps[index - 1];
  if (!previous) {
    return false;
  }
  if (previous.kind === 'copyBufferToBuffer') {
    return previous.dstBufferId === step.bufferId;
  }
  if (previous.kind === 'writeBuffer') {
    return previous.bufferId === step.bufferId;
  }
  return false;
}

function shouldLogProgress(index, total) {
  if (total <= 0) {
    return false;
  }
  return index < 3 || index === total - 1 || (index + 1) % DEBUG_PROGRESS_INTERVAL === 0;
}

function executionShapeForPlan(plan) {
  return {
    bufferCount: plan.buffers.length,
    moduleCount: plan.modules.length,
    stepCount: plan.steps.length,
    writeBufferCount: plan.steps.filter((step) => step.kind === 'writeBuffer').length,
    dispatchCount: plan.steps.filter((step) => step.kind === 'dispatch').length,
    copyBufferToBufferCount: plan.steps.filter((step) => step.kind === 'copyBufferToBuffer').length,
    readBufferCount: plan.steps.filter((step) => step.kind === 'readBuffer').length,
  };
}

export function applyDebugStepLimit(normalizedPlan, stepLimit) {
  if (!stepLimit || stepLimit >= normalizedPlan.steps.length) {
    return normalizedPlan;
  }
  const steps = normalizedPlan.steps.slice(0, stepLimit);
  const referencedBuffers = new Set();
  const referencedModules = new Set();
  for (const step of steps) {
    if (step.kind === 'writeBuffer' || step.kind === 'readBuffer') {
      referencedBuffers.add(step.bufferId);
      continue;
    }
    if (step.kind === 'copyBufferToBuffer') {
      referencedBuffers.add(step.srcBufferId);
      referencedBuffers.add(step.dstBufferId);
      continue;
    }
    if (step.kind === 'dispatch') {
      referencedModules.add(step.moduleId);
      for (const binding of step.bindings ?? []) {
        referencedBuffers.add(binding.bufferId);
      }
    }
  }
  const limitedPlan = {
    ...normalizedPlan,
    buffers: normalizedPlan.buffers.filter((buffer) => referencedBuffers.has(buffer.id)),
    modules: normalizedPlan.modules.filter((module) => referencedModules.has(module.id)),
    steps,
  };
  return {
    ...limitedPlan,
    planHash: stableArtifactHash({
      schemaVersion: limitedPlan.schemaVersion,
      planId: limitedPlan.planId,
      executorId: limitedPlan.executorId,
      workloadId: limitedPlan.workloadId,
      domain: limitedPlan.domain,
      comparable: limitedPlan.comparable,
      timing: limitedPlan.timing,
      adapter: limitedPlan.adapter,
      buffers: limitedPlan.buffers,
      modules: limitedPlan.modules,
      steps: limitedPlan.steps,
    }),
    executionShape: executionShapeForPlan(limitedPlan),
  };
}

async function loadJsonFile(path) {
  const text = await readFile(path, 'utf8');
  const payload = JSON.parse(text);
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    throw new Error(`${path}: expected a JSON object`);
  }
  return payload;
}

async function loadPackageExecutionPolicy() {
  if (!packageExecutionPolicyPromise) {
    packageExecutionPolicyPromise = loadJsonFile(PACKAGE_EXECUTION_POLICY_PATH)
      .catch((error) => {
        packageExecutionPolicyPromise = null;
        throw error;
      });
  }
  return await packageExecutionPolicyPromise;
}

function zeroHostTotals() {
  return {
    hostInputReadTotalNs: 0,
    hostInputParseTotalNs: 0,
    hostWorkloadPrepareTotalNs: 0,
    hostExecutorInitTotalNs: 0,
    hostUploadPrewarmTotalNs: 0,
    hostKernelPrewarmTotalNs: 0,
    hostCommandOrchestrationTotalNs: 0,
    hostArtifactFinalizeTotalNs: 0,
  };
}

export function boundaryScopedHostTotals({
  preparedSession,
  hostInputReadTotalNs,
  hostInputParseTotalNs,
  hostWorkloadPrepareTotalNs,
  hostExecutorInitTotalNs,
  hostUploadPrewarmTotalNs,
  hostKernelPrewarmTotalNs,
  hostCommandOrchestrationTotalNs,
  hostArtifactFinalizeTotalNs,
}) {
  return {
    hostInputReadTotalNs: preparedSession ? 0 : hostInputReadTotalNs,
    hostInputParseTotalNs: preparedSession ? 0 : hostInputParseTotalNs,
    hostWorkloadPrepareTotalNs: preparedSession ? 0 : hostWorkloadPrepareTotalNs,
    hostExecutorInitTotalNs: preparedSession ? 0 : hostExecutorInitTotalNs,
    hostUploadPrewarmTotalNs,
    hostKernelPrewarmTotalNs,
    hostCommandOrchestrationTotalNs,
    hostArtifactFinalizeTotalNs: preparedSession ? 0 : hostArtifactFinalizeTotalNs,
  };
}

function zeroPackageSetupBreakdown() {
  return {
    bufferCreateTotalNs: 0,
    initialDataWriteTotalNs: 0,
    shaderModuleCreateTotalNs: 0,
    bindGroupLayoutCreateTotalNs: 0,
    pipelineLayoutCreateTotalNs: 0,
    pipelineCreateTotalNs: 0,
    bindGroupCreateTotalNs: 0,
    dispatchPrewarmTotalNs: 0,
  };
}

function zeroPackageStepBreakdown() {
  return {
    writeMaterializeTotalNs: 0,
    writeQueueWriteTotalNs: 0,
    dispatchEncodeApiTotalNs: 0,
    copyEncodeApiTotalNs: 0,
    submitCommandEncoderFinishTotalNs: 0,
    submitQueueSubmitTotalNs: 0,
    submitQueueWaitTotalNs: 0,
    submitCommandPrepTotalNs: 0,
    submitAddonCallTotalNs: 0,
    submitAddonCommandReplayTotalNs: 0,
    submitAddonCommandReplayPrepareTotalNs: 0,
    submitAddonCommandReplayRecordTotalNs: 0,
    submitAddonCommandReplayCopyTotalNs: 0,
    submitAddonQueueSubmitTotalNs: 0,
    submitAddonCommandBufferEndTotalNs: 0,
    submitAddonSyncPrepareTotalNs: 0,
    submitAddonDriverSubmitTotalNs: 0,
    submitAddonFlushTotalNs: 0,
    submitPostSubmitBookkeepingTotalNs: 0,
    submitQueueFlushTotalNs: 0,
    submitQueueFlushWaitCompletedTotalNs: 0,
    submitQueueFlushDeferredCopyTotalNs: 0,
    submitQueueFlushDeferredResolveTotalNs: 0,
    submitQueueWaitBookkeepingTotalNs: 0,
    readbackTotalNs: 0,
    ...emptyReadbackBreakdownNs(),
  };
}

export function zeroPackageWriteBreakdown() {
  return {
    totalCount: 0,
    totalBytes: 0,
    staticBufferLoadCount: 0,
    staticBufferLoadBytes: 0,
    dynamicWriteCount: 0,
    dynamicWriteBytes: 0,
    unbatchedWriteCount: 0,
    batchCallCount: 0,
    batchedWriteCount: 0,
    batchMethod: PACKAGE_WRITE_BATCH_METHOD_NONE,
    byDataKind: {},
    bySemanticPhase: {},
  };
}

function incrementWriteBucket(target, key, byteLength) {
  const normalizedKey = typeof key === 'string' && key ? key : 'unknown';
  const bucket = target[normalizedKey] ?? { count: 0, bytes: 0 };
  bucket.count += 1;
  bucket.bytes += byteLength;
  target[normalizedKey] = bucket;
}

export function recordPackageWriteBreakdown(target, step, byteLength) {
  const safeByteLength = Number.isFinite(byteLength) && byteLength > 0 ? Math.trunc(byteLength) : 0;
  const dataKind = typeof step?.data?.kind === 'string' ? step.data.kind : 'unknown';
  const semanticPhase = typeof step?.semanticPhase === 'string' ? step.semanticPhase : '';
  const isStaticBufferLoad = dataKind === 'file' || semanticPhase === 'buffer_load';
  target.totalCount += 1;
  target.totalBytes += safeByteLength;
  if (isStaticBufferLoad) {
    target.staticBufferLoadCount += 1;
    target.staticBufferLoadBytes += safeByteLength;
  } else {
    target.dynamicWriteCount += 1;
    target.dynamicWriteBytes += safeByteLength;
  }
  incrementWriteBucket(target.byDataKind, dataKind, safeByteLength);
  incrementWriteBucket(target.bySemanticPhase, semanticPhase || (isStaticBufferLoad ? 'buffer_load' : 'dynamic_write'), safeByteLength);
}

function recordPackageUnbatchedWrite(target) {
  target.unbatchedWriteCount += 1;
}

function recordPackageBatchedWrites(target, writeCount, method) {
  target.batchCallCount += 1;
  target.batchedWriteCount += writeCount;
  if (target.batchMethod === PACKAGE_WRITE_BATCH_METHOD_NONE) {
    target.batchMethod = method;
  } else if (target.batchMethod !== method) {
    target.batchMethod = PACKAGE_WRITE_BATCH_METHOD_MIXED;
  }
}

function packageWriteBatchMethod(queue) {
  if (typeof queue?.writeBufferBatch === 'function') {
    return PACKAGE_WRITE_BATCH_METHOD_DIRECT_QUEUE;
  }
  if (typeof queue?.__doeWriteBufferBatch === 'function') {
    return PACKAGE_WRITE_BATCH_METHOD_DOE_QUEUE;
  }
  return PACKAGE_WRITE_BATCH_METHOD_NONE;
}

function buildCompactQueueWriteBatch(entries) {
  let totalBytes = 0;
  for (const entry of entries) {
    const byteLength = entry.data.byteLength;
    totalBytes += byteLength;
    if (byteLength > MAX_COMPACT_WRITE_BATCH_BYTES) {
      throw new Error(`writeBufferBatch entry exceeds compact size limit: ${byteLength}`);
    }
  }
  const buffers = new Array(entries.length);
  const offsets = new BigUint64Array(entries.length);
  const sizes = new Uint32Array(entries.length);
  const data = new Uint8Array(totalBytes);
  let dataOffset = 0;
  for (const [index, entry] of entries.entries()) {
    const offset = entry.offset ?? 0;
    if (!Number.isSafeInteger(offset) || offset < 0) {
      throw new Error(`writeBufferBatch entry offset must be a non-negative safe integer: ${offset}`);
    }
    buffers[index] = entry.buffer;
    offsets[index] = BigInt(offset);
    sizes[index] = entry.data.byteLength;
    const byteView = entry.data instanceof Uint8Array
      ? entry.data
      : new Uint8Array(entry.data.buffer, entry.data.byteOffset, entry.data.byteLength);
    data.set(byteView, dataOffset);
    dataOffset += entry.data.byteLength;
  }
  return { buffers, offsets, sizes, data };
}

function compactWriteBatchCacheKey(batchedSteps) {
  const first = batchedSteps[0]?.index ?? -1;
  const last = batchedSteps[batchedSteps.length - 1]?.index ?? -1;
  return `${first}:${last}:${batchedSteps.length}`;
}

function prepareQueueWriteBufferBatch(method, entries, compactCache, cacheKey) {
  if (method !== PACKAGE_WRITE_BATCH_METHOD_DIRECT_QUEUE) {
    return null;
  }
  if (compactCache?.has(cacheKey)) {
    return compactCache.get(cacheKey);
  }
  const compact = buildCompactQueueWriteBatch(entries);
  compactCache?.set(cacheKey, compact);
  return compact;
}

function queueWriteBufferBatch(queue, method, entries, preparedCompact = null) {
    if (method === PACKAGE_WRITE_BATCH_METHOD_DIRECT_QUEUE) {
    const compact = preparedCompact ?? buildCompactQueueWriteBatch(entries);
    return queue.writeBufferBatch(compact.buffers, compact.offsets, compact.sizes, compact.data);
  }
  if (method === PACKAGE_WRITE_BATCH_METHOD_DOE_QUEUE) {
    return queue.__doeWriteBufferBatch(entries);
  }
  throw new Error(`unsupported queue write batch method: ${method}`);
}

function isDynamicWriteBufferStep(step) {
  return step?.kind === 'writeBuffer' && !isStaticBufferLoadStep(step);
}

export function zeroPackageResidentBufferLoadBreakdown() {
  return {
    count: 0,
    bytes: 0,
    materializeTotalNs: 0,
    queueWriteTotalNs: 0,
    queueWaitTotalNs: 0,
  };
}

function snapshotPackageFastPathStats(providerModule) {
  const stats = providerModule?.fastPathStats;
  if (!stats || typeof stats !== 'object') {
    return null;
  }
  return {
    dispatchFlush: Math.max(0, Number(stats.dispatchFlush ?? 0) || 0),
    flushAndMap: Math.max(0, Number(stats.flushAndMap ?? 0) || 0),
    commandBufferBuild: Math.max(0, Number(stats.commandBufferBuild ?? 0) || 0),
  };
}

function snapshotPackageNativeFastPaths(providerModule) {
  if (typeof providerModule?.nativeFastPathInfo !== 'function') {
    return null;
  }
  let info = null;
  try {
    info = providerModule.nativeFastPathInfo();
  } catch {
    return null;
  }
  if (!info || typeof info !== 'object') {
    return null;
  }
  return {
    appleFastPathCompiled: Boolean(info.appleFastPathCompiled),
    queueFlush: Boolean(info.queueFlush),
    queueFlushBreakdown: Boolean(info.queueFlushBreakdown),
    queueWriteBufferBatch: Boolean(info.queueWriteBufferBatch),
    queueWriteBufferBatchDataPtrs: Boolean(info.queueWriteBufferBatchDataPtrs),
    computeDispatchFlush: Boolean(info.computeDispatchFlush),
    computeDispatchFlushBreakdown: Boolean(info.computeDispatchFlushBreakdown),
    computeDispatchBatchFlush: Boolean(info.computeDispatchBatchFlush),
    computeDispatchBatchCopyFlush: Boolean(info.computeDispatchBatchCopyFlush),
    computeDispatchBatchCopyFlushBreakdown: Boolean(info.computeDispatchBatchCopyFlushBreakdown),
    computePrewarmDispatchBindings: Boolean(info.computePrewarmDispatchBindings),
    bufferMapReadCopyUnmap: Boolean(info.bufferMapReadCopyUnmap),
  };
}

function snapshotPackageNativeQueueSyncInfo(providerModule, queue) {
  if (typeof providerModule?.nativeQueueSyncInfo !== 'function' || !queue) {
    return null;
  }
  let info = null;
  try {
    info = providerModule.nativeQueueSyncInfo(queue);
  } catch {
    return null;
  }
  if (!info || typeof info !== 'object') {
    return null;
  }
  const result = {
    backendVulkan: Boolean(info.backendVulkan),
    timelineSemaphore: Boolean(info.timelineSemaphore),
    fencePool: Boolean(info.fencePool),
    deferredSubmissions: Boolean(info.deferredSubmissions),
  };
  if (typeof info.queueFamilyPolicy === 'string') {
    result.queueFamilyPolicy = info.queueFamilyPolicy;
  }
  if (typeof info.deferredSubmissionSyncPolicy === 'string') {
    result.deferredSubmissionSyncPolicy = info.deferredSubmissionSyncPolicy;
  }
  if (typeof info.queueFamilyKind === 'string') {
    result.queueFamilyKind = info.queueFamilyKind;
  }
  if (Number.isInteger(info.queueFamilyIndex)) {
    result.queueFamilyIndex = info.queueFamilyIndex;
  }
  if (Number.isInteger(info.queueFamilyQueueCount)) {
    result.queueFamilyQueueCount = info.queueFamilyQueueCount;
  }
  if (Number.isInteger(info.queueFamilyTimestampValidBits)) {
    result.queueFamilyTimestampValidBits = info.queueFamilyTimestampValidBits;
  }
  if (typeof info.queueFamilySupportsGraphics === 'boolean') {
    result.queueFamilySupportsGraphics = info.queueFamilySupportsGraphics;
  }
  return result;
}

function snapshotPackagePipelineCacheInfo(providerModule, queue, flushNs = 0) {
  if (typeof providerModule?.nativePipelineCacheInfo !== 'function' || !queue) {
    return null;
  }
  let info = null;
  try {
    info = providerModule.nativePipelineCacheInfo(queue);
  } catch {
    return null;
  }
  if (!info || typeof info !== 'object') {
    return null;
  }
  const backend = typeof info.backend === 'string' ? info.backend : '';
  const state = typeof info.state === 'string' ? info.state : '';
  const reason = typeof info.reason === 'string' ? info.reason : '';
  if (!backend || !state || !reason) {
    return null;
  }
  return {
    backend,
    state,
    reason,
    warmupCount: Math.max(0, Number(info.warmupCount ?? 0) || 0),
    warmupNs: Math.max(0, Number(info.warmupNs ?? 0) || 0),
    flushNs: Math.max(0, Number(flushNs) || 0),
  };
}

function flushPackagePipelineCache(providerModule, queue, debugLog) {
  if (typeof providerModule?.packagePipelineCacheFlush !== 'function' || !queue) {
    return 0;
  }
  const startedAt = performance.now();
  try {
    providerModule.packagePipelineCacheFlush(queue);
  } catch (error) {
    debugLog('runtime.pipelineCacheFlush.failed', {
      detail: String(error?.message ?? error),
    });
    return 0;
  }
  return nsDelta(startedAt);
}

function diffPackageFastPathStats(start, end) {
  if (!start || !end) {
    return null;
  }
  return {
    dispatchFlush: Math.max(0, end.dispatchFlush - start.dispatchFlush),
    flushAndMap: Math.max(0, end.flushAndMap - start.flushAndMap),
    commandBufferBuild: Math.max(0, end.commandBufferBuild - start.commandBufferBuild),
  };
}

export function isStaticBufferLoadStep(step) {
  return (
    step?.kind === 'writeBuffer'
    && (
      step?.data?.kind === 'file'
      || step?.semanticPhase === 'buffer_load'
    )
  );
}

export function validateResidentBufferLoadPlan(normalizedPlan) {
  const staticBufferIds = new Set();
  const dynamicBufferIds = new Set();
  for (const step of normalizedPlan?.steps ?? []) {
    if (step?.kind !== 'writeBuffer') {
      continue;
    }
    if (isStaticBufferLoadStep(step)) {
      staticBufferIds.add(step.bufferId);
    } else {
      dynamicBufferIds.add(step.bufferId);
    }
  }
  const conflicts = [...staticBufferIds]
    .filter((bufferId) => dynamicBufferIds.has(bufferId))
    .sort();
  if (conflicts.length > 0) {
    throw new Error(
      '--resident-buffer-loads cannot preload buffers that also receive dynamic writes: '
      + conflicts.join(', '),
    );
  }
}

function selectedExecutionSteps(steps, residentBufferLoads) {
  if (!residentBufferLoads) {
    return steps;
  }
  return steps.filter((step) => !isStaticBufferLoadStep(step));
}

function fallbackExecutionShape() {
  return {
    stepCount: 0,
    dispatchCount: 0,
    bufferCount: 0,
    moduleCount: 0,
    writeBufferCount: 0,
    copyBufferToBufferCount: 0,
    readBufferCount: 0,
  };
}

function fallbackPlanSummary({ workloadId, planPath }) {
  const executionShape = fallbackExecutionShape();
  const planId = `unparsed:${workloadId || 'unknown'}`;
  const planHash = stableArtifactHash({
    workloadId: workloadId || '',
    planPath: planPath || '',
    executionShape,
  });
  return {
    workloadId: workloadId || '',
    canonicalWorkloadId: workloadId || '',
    planId,
    planHash,
    executionShape,
    planSummary: {
      schemaVersion: 1,
      planId,
      executorId: 'node_webgpu_package',
      workloadId: workloadId || '',
      domain: 'unknown',
      comparable: false,
      timing: {
        iterations: 1,
        warmup: 0,
        timingSource: 'doe-execution-total-ns',
        timingClass: 'operation',
      },
      planHash,
      executionShape,
      planPath: planPath || '',
    },
  };
}

function resolvePlanMetadata({ normalizedPlan = null, workloadId = '', planPath = '' }) {
  if (normalizedPlan) {
    return {
      workloadId: normalizedPlan.workloadId,
      canonicalWorkloadId: normalizedPlan.workloadId,
      planId: normalizedPlan.planId,
      planHash: normalizedPlan.planHash,
      executionShape: normalizedPlan.executionShape,
      planSummary: {
        schemaVersion: normalizedPlan.schemaVersion,
        planId: normalizedPlan.planId,
        executorId: normalizedPlan.executorId,
        workloadId: normalizedPlan.workloadId,
        domain: normalizedPlan.domain,
        comparable: normalizedPlan.comparable,
        timing: normalizedPlan.timing,
        planHash: normalizedPlan.planHash,
        executionShape: normalizedPlan.executionShape,
      },
    };
  }
  return fallbackPlanSummary({ workloadId, planPath });
}

function buildPreparedDispatchPrewarmCommands(dispatchStates) {
  const commands = [];
  for (const state of dispatchStates) {
    if (!state?.pipeline) {
      continue;
    }
    const command = { t: 0, p: state.pipeline };
    if (state.bindGroup) {
      command.b = state.bindGroup;
    }
    commands.push(command);
  }
  return commands;
}

function prewarmPreparedDispatches(runtime, debugLog) {
  if (typeof runtime?.providerModule?.prewarmPreparedDispatches !== 'function') {
    return 0;
  }
  const commands = buildPreparedDispatchPrewarmCommands(runtime.dispatchStates);
  if (commands.length === 0) {
    return 0;
  }
  const startedAt = performance.now();
  let result = null;
  try {
    result = runtime.providerModule.prewarmPreparedDispatches(runtime.queue, commands);
  } catch (error) {
    debugLog('runtime.setup.dispatchPrewarm.failed', {
      detail: String(error?.message ?? error),
    });
    return 0;
  }
  const elapsedNs = nsDelta(startedAt);
  debugLog('runtime.setup.dispatchPrewarm.done', {
    requestedCount: commands.length,
    preparedCount: Number(result?.preparedCount ?? 0) || 0,
    available: Boolean(result?.available),
    elapsedNs,
  });
  return elapsedNs;
}

function makeUnsupportedNodeWebGpuError({
  unsupportedCode,
  message,
  detail = '',
  hostExecutorInitTotalNs = 0,
  availability = null,
}) {
  const error = new Error(message);
  error.code = NODE_WEBGPU_UNSUPPORTED_ERROR_CODE;
  error.unsupportedCode = unsupportedCode;
  error.unsupportedDetail = detail;
  error.hostExecutorInitTotalNs = hostExecutorInitTotalNs;
  attachProviderAvailability(error, availability);
  return error;
}

function isUnsupportedNodeWebGpuError(error) {
  return Boolean(error && error.code === NODE_WEBGPU_UNSUPPORTED_ERROR_CODE);
}

export function classifyBringupUnsupported(stage, error) {
  const message = String(error?.message ?? error ?? '');
  const code = String(error?.code ?? '');
  const normalized = message.toLowerCase();
  const unavailable = (
    normalized.includes('status=3')
    || normalized.includes('unavailable')
    || normalized.includes('no adapter found')
    || normalized.includes('runtime init failed')
  );
  if (!unavailable && code !== 'DOE_REQUEST_ADAPTER_ERROR' && code !== 'DOE_REQUEST_DEVICE_ERROR') {
    return null;
  }
  return {
    reason: 'adapter_unavailable',
    unsupportedCode: stage === 'requestDevice' ? 'device_unavailable' : 'adapter_unavailable',
    detail: message,
  };
}

export function buildUnsupportedExecutionResult({
  normalizedPlan = null,
  spec,
  preparedSession,
  hostInputReadTotalNs,
  hostInputParseTotalNs,
  hostWorkloadPrepareTotalNs,
  hostExecutorInitTotalNs,
  processWallMs,
  unsupportedCode = '',
  unsupportedDetail = '',
  providerFailureReason = '',
  evidenceBlockerCode = '',
  workloadId = '',
  planPath = '',
  queueWaitMode = PACKAGE_QUEUE_WAIT_MODE,
  queueWaitScope = PACKAGE_QUEUE_WAIT_SCOPE,
  queueWaitSubmitCadence = 0,
  residentBufferLoads = false,
}) {
  const planMeta = resolvePlanMetadata({ normalizedPlan, workloadId, planPath });
  const scopedHostTotals = boundaryScopedHostTotals({
    preparedSession,
    hostInputReadTotalNs,
    hostInputParseTotalNs,
    hostWorkloadPrepareTotalNs,
    hostExecutorInitTotalNs,
    hostUploadPrewarmTotalNs: 0,
    hostKernelPrewarmTotalNs: 0,
    hostCommandOrchestrationTotalNs: 0,
    hostArtifactFinalizeTotalNs: 0,
  });
  const meta = {
    schemaVersion: 1,
    kind: 'trace_meta',
    provider: spec.provider,
    providerName: spec.providerName,
    executionBackend: spec.executionBackend,
    executionProvider: spec.provider,
    executionProviderName: spec.providerName,
    executionRowCount: 0,
    executionSuccessCount: 0,
    executionErrorCount: 0,
    executionSkippedCount: 0,
    executionUnsupportedCount: 1,
    executionDispatchCount: 0,
    executionSubmitCount: 0,
    executionTotalNs: 0,
    executionSetupTotalNs: 0,
    executionEncodeTotalNs: 0,
    executionSubmitWaitTotalNs: 0,
    ...scopedHostTotals,
    timingMs: 0,
    elapsedMs: processWallMs,
    processWallMs,
    timingSource: 'doe-execution-total-ns',
    timingClass: 'operation',
    queueSyncMode: PACKAGE_QUEUE_SYNC_MODE,
    queueWaitMode,
    queueWaitScope,
    queueWaitSubmitCadence,
    executionQueueSyncMode: PACKAGE_QUEUE_SYNC_MODE,
    executionQueueWaitMode: queueWaitMode,
    executionQueueWaitScope: queueWaitScope,
    executionQueueWaitSubmitCadence: queueWaitSubmitCadence,
    ...(unsupportedCode ? { unsupportedCode } : {}),
    ...(unsupportedDetail ? { unsupportedDetail } : {}),
    ...(providerFailureReason ? { providerFailureReason } : {}),
    ...(evidenceBlockerCode ? { evidenceBlockerCode } : {}),
    workload: planMeta.workloadId,
    canonicalWorkloadId: planMeta.canonicalWorkloadId,
    planId: planMeta.planId,
    planHash: planMeta.planHash,
    planSummary: planMeta.planSummary,
    executionShape: planMeta.executionShape,
    packagePreparedSession: preparedSession,
    packageSetupIncludedInSelectedTiming: !preparedSession,
    packageSetupTotalNs: 0,
    packageSetupBreakdownNs: zeroPackageSetupBreakdown(),
    packageStepBreakdownNs: zeroPackageStepBreakdown(),
    packageWriteBreakdown: zeroPackageWriteBreakdown(),
    packageResidentBufferLoads: residentBufferLoads,
    packageResidentBufferLoadBreakdown: zeroPackageResidentBufferLoadBreakdown(),
    ...(preparedSession ? { workloadUnitWallSource: TRACE_META_PROCESS_WALL_SOURCE } : {}),
    samplesMs: [0],
    stats: {
      count: 1,
      min: 0,
      max: 0,
      median: 0,
      p95: 0,
      p99: 0,
      mean: 0,
      stdev: 0,
    },
  };
  meta.artifactHash = stableArtifactHash(meta);
  return { meta, rows: [] };
}

export function buildErrorExecutionResult({
  normalizedPlan = null,
  spec,
  preparedSession,
  hostInputReadTotalNs,
  hostInputParseTotalNs,
  hostWorkloadPrepareTotalNs,
  hostExecutorInitTotalNs,
  processWallMs,
  providerFailureReason = '',
  evidenceBlockerCode = '',
  workloadId = '',
  planPath = '',
  queueWaitMode = PACKAGE_QUEUE_WAIT_MODE,
  queueWaitScope = PACKAGE_QUEUE_WAIT_SCOPE,
  queueWaitSubmitCadence = 0,
  residentBufferLoads = false,
}) {
  const planMeta = resolvePlanMetadata({ normalizedPlan, workloadId, planPath });
  const scopedHostTotals = boundaryScopedHostTotals({
    preparedSession,
    hostInputReadTotalNs,
    hostInputParseTotalNs,
    hostWorkloadPrepareTotalNs,
    hostExecutorInitTotalNs,
    hostUploadPrewarmTotalNs: 0,
    hostKernelPrewarmTotalNs: 0,
    hostCommandOrchestrationTotalNs: 0,
    hostArtifactFinalizeTotalNs: 0,
  });
  const meta = {
    schemaVersion: 1,
    kind: 'trace_meta',
    provider: spec.provider,
    providerName: spec.providerName,
    executionBackend: spec.executionBackend,
    executionProvider: spec.provider,
    executionProviderName: spec.providerName,
    executionRowCount: 0,
    executionSuccessCount: 0,
    executionErrorCount: 1,
    executionSkippedCount: 0,
    executionUnsupportedCount: 0,
    executionDispatchCount: 0,
    executionSubmitCount: 0,
    executionTotalNs: 0,
    executionSetupTotalNs: 0,
    executionEncodeTotalNs: 0,
    executionSubmitWaitTotalNs: 0,
    ...scopedHostTotals,
    timingMs: 0,
    elapsedMs: processWallMs,
    processWallMs,
    timingSource: 'doe-execution-total-ns',
    timingClass: 'operation',
    queueSyncMode: PACKAGE_QUEUE_SYNC_MODE,
    queueWaitMode,
    queueWaitScope,
    queueWaitSubmitCadence,
    executionQueueSyncMode: PACKAGE_QUEUE_SYNC_MODE,
    executionQueueWaitMode: queueWaitMode,
    executionQueueWaitScope: queueWaitScope,
    executionQueueWaitSubmitCadence: queueWaitSubmitCadence,
    ...(providerFailureReason ? { providerFailureReason } : {}),
    ...(evidenceBlockerCode ? { evidenceBlockerCode } : {}),
    workload: planMeta.workloadId,
    canonicalWorkloadId: planMeta.canonicalWorkloadId,
    planId: planMeta.planId,
    planHash: planMeta.planHash,
    planSummary: planMeta.planSummary,
    executionShape: planMeta.executionShape,
    packagePreparedSession: preparedSession,
    packageSetupIncludedInSelectedTiming: !preparedSession,
    packageSetupTotalNs: 0,
    packageSetupBreakdownNs: zeroPackageSetupBreakdown(),
    packageStepBreakdownNs: zeroPackageStepBreakdown(),
    packageWriteBreakdown: zeroPackageWriteBreakdown(),
    packageResidentBufferLoads: residentBufferLoads,
    packageResidentBufferLoadBreakdown: zeroPackageResidentBufferLoadBreakdown(),
    ...(preparedSession ? { workloadUnitWallSource: TRACE_META_PROCESS_WALL_SOURCE } : {}),
    samplesMs: [0],
    stats: {
      count: 1,
      min: 0,
      max: 0,
      median: 0,
      p95: 0,
      p99: 0,
      mean: 0,
      stdev: 0,
    },
  };
  meta.artifactHash = stableArtifactHash(meta);
  return { meta, rows: [] };
}

async function writeExecutorArtifacts(traceMetaPath, traceJsonlPath, meta, rows) {
  if (traceMetaPath) {
    mkdirSync(dirname(resolve(traceMetaPath)), { recursive: true });
    writeFileSync(traceMetaPath, `${JSON.stringify(meta)}\n`, 'utf8');
  }
  if (traceJsonlPath) {
    mkdirSync(dirname(resolve(traceJsonlPath)), { recursive: true });
    const payload = rows.length > 0
      ? `${rows.map((row) => JSON.stringify(row)).join('\n')}\n`
      : '';
    writeFileSync(traceJsonlPath, payload, 'utf8');
  }
}

function bufferUsageMask(globals, usage) {
  let mask = 0;
  for (const entry of usage) {
    if (entry === 'storage') mask |= globals.GPUBufferUsage.STORAGE;
    if (entry === 'copy_dst') mask |= globals.GPUBufferUsage.COPY_DST;
    if (entry === 'copy_src') mask |= globals.GPUBufferUsage.COPY_SRC;
    if (entry === 'map_read') mask |= globals.GPUBufferUsage.MAP_READ;
    if (entry === 'map_write') mask |= globals.GPUBufferUsage.MAP_WRITE;
    if (entry === 'uniform') mask |= globals.GPUBufferUsage.UNIFORM;
  }
  return mask;
}

export function providerSpec(provider, runtimeHost = 'node') {
  const runtimeProviders = PROVIDERS_BY_RUNTIME[runtimeHost] ?? {};
  const normalized = typeof provider === 'string' ? provider.trim().toLowerCase() : '';
  const spec = runtimeProviders[normalized];
  if (!spec) {
    const detail = (
      `unsupported provider: ${provider} for runtime ${runtimeHost} `
      + `(expected one of ${Object.keys(runtimeProviders).join(', ')})`
    );
    throw attachProviderAvailability(
      new Error(detail),
      providerAvailabilityFailure({
        reason: 'unsupported_runtime_host',
        provider: normalized,
        runtimeHost,
        stage: 'providerSpec',
        detail,
      }),
    );
  }
  return spec;
}

export function buildRequestDeviceDescriptor(adapterDescriptor = null) {
  const requiredFeatures = adapterDescriptor?.requiredFeatures ?? [];
  const requiredLimits = adapterDescriptor?.requiredLimits ?? {};
  const requestDeviceDescriptor = {};
  if (requiredFeatures.length > 0) {
    requestDeviceDescriptor.requiredFeatures = requiredFeatures;
  }
  if (Object.keys(requiredLimits).length > 0) {
    requestDeviceDescriptor.requiredLimits = requiredLimits;
  }
  return requestDeviceDescriptor;
}

function hostPolicyValueMatches(actual, expected) {
  if (expected === undefined || expected === null || expected === '') {
    return true;
  }
  if (Array.isArray(expected)) {
    return expected.includes(actual);
  }
  return actual === expected;
}

export function lookupUnsupportedPackageExecutionEntry(policy, {
  runtimeHost,
  provider,
  workloadId,
  platform,
  arch,
  hostname,
  osRelease,
}) {
  const entries = Array.isArray(policy?.unsupportedExecutions)
    ? policy.unsupportedExecutions
    : [];
  return entries.find((entry) => {
    if (!hostPolicyValueMatches(runtimeHost, entry.runtimeHost)) {
      return false;
    }
    if (!hostPolicyValueMatches(provider, entry.provider)) {
      return false;
    }
    if (!hostPolicyValueMatches(workloadId, entry.workloadId)) {
      return false;
    }
    if (!hostPolicyValueMatches(platform, entry.host?.platform)) {
      return false;
    }
    if (!hostPolicyValueMatches(arch, entry.host?.arch)) {
      return false;
    }
    if (!hostPolicyValueMatches(hostname, entry.host?.hostname)) {
      return false;
    }
    if (!hostPolicyValueMatches(osRelease, entry.host?.osRelease)) {
      return false;
    }
    return true;
  }) ?? null;
}

export function lookupPackageWriteBatchingEntry(policy, {
  runtimeHost,
  provider,
  method,
}) {
  const entries = Array.isArray(policy?.writeBatching)
    ? policy.writeBatching
    : [];
  return entries.find((entry) => {
    if (!hostPolicyValueMatches(runtimeHost, entry.runtimeHost)) {
      return false;
    }
    if (!hostPolicyValueMatches(provider, entry.provider)) {
      return false;
    }
    if (!hostPolicyValueMatches(method, entry.method)) {
      return false;
    }
    return true;
  }) ?? null;
}

export function lookupPackageReadbackModeEntry(policy, {
  runtimeHost,
  provider,
  workloadId,
  packagePreparedSession,
}) {
  const entries = Array.isArray(policy?.readbackMode)
    ? policy.readbackMode
    : [];
  return entries.find((entry) => {
    if (!hostPolicyValueMatches(runtimeHost, entry.runtimeHost)) {
      return false;
    }
    if (!hostPolicyValueMatches(provider, entry.provider)) {
      return false;
    }
    if (!hostPolicyValueMatches(workloadId, entry.workloadId)) {
      return false;
    }
    if (
      typeof entry.packagePreparedSession === 'boolean'
      && entry.packagePreparedSession !== Boolean(packagePreparedSession)
    ) {
      return false;
    }
    return true;
  }) ?? null;
}

function packageReadbackModeForExecution(policy, {
  runtimeHost,
  provider,
  workloadId,
  packagePreparedSession,
}) {
  const envMode = packageReadbackModeFromEnv();
  if (envMode) {
    return envMode;
  }
  const entry = lookupPackageReadbackModeEntry(policy, {
    runtimeHost,
    provider,
    workloadId,
    packagePreparedSession,
  });
  return entry?.mode === PACKAGE_READBACK_MODE_MAP_ASYNC
    ? PACKAGE_READBACK_MODE_MAP_ASYNC
    : PACKAGE_READBACK_MODE_NATIVE;
}

function packagePolicyProvider(runtime) {
  const provider = runtime?.providerSpec?.provider;
  if (
    provider === 'doe'
    && runtime?.runtimeHost === 'bun'
    && typeof runtime?.providerModule?.providerInfo === 'function'
  ) {
    const info = runtime.providerModule.providerInfo();
    if (info?.bunRuntimeProvider === 'doe-ffi') {
      return 'doe-ffi';
    }
  }
  return provider;
}

function packageWriteBatchMinConsecutiveWrites(policy, {
  runtimeHost,
  provider,
  method,
}) {
  const entry = lookupPackageWriteBatchingEntry(policy, {
    runtimeHost,
    provider,
    method,
  });
  const value = Number(entry?.minConsecutiveWrites ?? 2);
  return Number.isInteger(value) && value >= 2 ? value : 2;
}

function globalsFromGlobalThis() {
  const required = [
    'GPUBufferUsage',
    'GPUShaderStage',
    'GPUMapMode',
    'GPUTextureUsage',
  ];
  const globals = {};
  for (const name of required) {
    const value = globalThis[name];
    if (value === undefined) {
      throw new Error(`global ${name} is not available after Bun WebGPU setup`);
    }
    globals[name] = value;
  }
  return globals;
}

function resolveInstalledBunWebGpuModulePath() {
  const homeDir = typeof process.env.HOME === 'string' && process.env.HOME.trim() !== ''
    ? process.env.HOME.trim()
    : '';
  if (!homeDir) {
    return null;
  }
  const cacheRoot = resolve(homeDir, '.bun', 'install', 'cache');
  if (!existsSync(cacheRoot)) {
    return null;
  }
  const entries = readdirSync(cacheRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && entry.name.startsWith('bun-webgpu@'))
    .map((entry) => entry.name)
    .sort()
    .reverse();
  for (const entry of entries) {
    const candidate = resolve(cacheRoot, entry, 'index.js');
    if (existsSync(candidate)) {
      return candidate;
    }
  }
  return null;
}

async function resolveBunWebGpuModule() {
  let mod;
  try {
    mod = await import(pathToFileURL(FALLBACK_BUN_WEBGPU_PATH).href);
  } catch (_err) {
    try {
      mod = await import('bun-webgpu');
    } catch (error) {
      const fallbackPath = resolveInstalledBunWebGpuModulePath();
      if (!fallbackPath) {
        throw error;
      }
      mod = await import(pathToFileURL(fallbackPath).href);
    }
  }
  if (typeof mod.setupGlobals !== 'function') {
    throw new Error('bun-webgpu does not export setupGlobals()');
  }
  await mod.setupGlobals();
  if (typeof navigator === 'undefined' || !navigator.gpu) {
    throw new Error('bun-webgpu did not install navigator.gpu');
  }
  return {
    create: () => navigator.gpu,
    globals: globalsFromGlobalThis(),
  };
}

async function resolveProviderModule(spec) {
  switch (spec.loader) {
    case 'node-doe':
      return await import(pathToFileURL(DOE_PACKAGE_PATH).href);
    case 'node-doe-direct': {
      const mod = await import(pathToFileURL(DOE_PACKAGE_PATH).href);
      if (typeof mod.createNativeDirect !== 'function') {
        throw new Error('doe-gpu package does not export createNativeDirect()');
      }
      return {
        ...mod,
        create: mod.createNativeDirect,
      };
    }
    case 'node-dawn':
      try {
        return await import(pathToFileURL(FALLBACK_WEBGPU_PATH).href);
      } catch (_err) {
        return await import('webgpu');
      }
    case 'bun-doe':
      return await import(pathToFileURL(DOE_BUN_PACKAGE_PATH).href);
    case 'bun-doe-ffi':
      return await import(pathToFileURL(DOE_BUN_FFI_PACKAGE_PATH).href);
    case 'bun-webgpu':
      return await resolveBunWebGpuModule();
    default:
      throw new Error(`unsupported provider loader: ${spec.loader}`);
  }
}

function classifyProviderModuleFailure(error) {
  const message = String(error?.message ?? error ?? '');
  const normalized = message.toLowerCase();
  if (
    normalized.includes('native addon not found')
    || normalized.includes('doe_napi.node')
  ) {
    return 'native_addon_unavailable';
  }
  if (
    normalized.includes('libwebgpu_doe not found')
    || normalized.includes('doe_webgpu_lib')
  ) {
    return 'runtime_library_unavailable';
  }
  if (normalized.includes('unsupported provider loader')) {
    return 'unsupported_runtime_host';
  }
  if (
    normalized.includes('cannot find package')
    || normalized.includes('cannot find module')
    || normalized.includes('err_module_not_found')
    || normalized.includes('module not found')
  ) {
    return 'provider_import_failed';
  }
  if (
    normalized.includes('does not export')
    || normalized.includes('did not install navigator.gpu')
    || normalized.includes('global gpu')
    || normalized.includes('global gpubufferusage')
    || normalized.includes('global gpushaderstage')
    || normalized.includes('global gpumapmode')
    || normalized.includes('global gputextureusage')
  ) {
    return 'native_webgpu_unavailable';
  }
  return 'runner_error';
}

export async function resolveProviderModuleAvailability(spec, {
  runtimeHost = '',
} = {}) {
  try {
    const module = await resolveProviderModule(spec);
    return providerAvailabilityOk({
      provider: spec.provider,
      providerName: spec.providerName,
      runtimeHost,
      loader: spec.loader,
      stage: 'provider.resolve',
      module,
    });
  } catch (error) {
    const sourceAvailability = error?.providerAvailability ?? null;
    return providerAvailabilityFailure({
      reason: sourceAvailability?.reason ?? classifyProviderModuleFailure(error),
      provider: spec.provider,
      providerName: spec.providerName,
      runtimeHost,
      loader: spec.loader,
      stage: 'provider.resolve',
      detail: sourceAvailability?.detail ?? String(error?.message ?? error ?? ''),
    });
  }
}

function makeProviderAvailabilityError(availability) {
  const error = new Error(availability.detail || availability.reason);
  return attachProviderAvailability(error, availability);
}

function buildBindingDescriptor(binding, buffers, globals) {
  const buffer = buffers.get(binding.bufferId);
  if (!buffer) {
    throw new Error(`unknown buffer in binding: ${binding.bufferId}`);
  }
  return {
    layout: {
      binding: binding.binding,
      visibility: globals.GPUShaderStage.COMPUTE,
      buffer: {
        type: binding.bufferType,
        ...(binding.size !== undefined ? { minBindingSize: binding.size } : {}),
      },
    },
    entry: {
      binding: binding.binding,
      resource: {
        buffer,
        offset: binding.offset ?? 0,
        ...(binding.size !== undefined ? { size: binding.size } : {}),
      },
    },
  };
}

function cacheKeyPart(value) {
  const text = value === undefined || value === null ? '' : String(value);
  return `${text.length}:${text}`;
}

function bindingCacheKey(bindings, fields) {
  return (bindings ?? []).map((binding) => fields.map((field) => {
    if (field === 'visibility') {
      return cacheKeyPart((binding.visibility ?? []).join(','));
    }
    if (field === 'offset') {
      return cacheKeyPart(binding.offset ?? 0);
    }
    if (field === 'size') {
      return cacheKeyPart(binding.size ?? null);
    }
    return cacheKeyPart(binding[field]);
  }).join(',')).join('|');
}

export function buildDispatchBindingLayoutCacheKey(step) {
  return bindingCacheKey(step.bindings, [
    'binding',
    'bufferType',
    'visibility',
    'size',
  ]);
}

export function buildDispatchBindingCacheKey(step) {
  return bindingCacheKey(step.bindings, [
    'binding',
    'bufferId',
    'bufferType',
    'offset',
    'size',
  ]);
}

async function createRuntime(normalizedPlan, webgpu, spec, {
  debugLog,
  runtimeHost,
  prewarmDispatchBindings = false,
}) {
  const { create, globals } = webgpu;
  debugLog('runtime.create.start', {
    provider: spec.provider,
    executionBackend: spec.executionBackend,
    executionShape: normalizedPlan.executionShape,
  });
  const executorInitStartedAt = performance.now();
  const gpu = create(providerCreateOptions(spec));
  const preferredPower = normalizedPlan.adapter?.powerPreference ?? 'high-performance';
  const adapterRequests = [];
  if (preferredPower) {
    adapterRequests.push({ powerPreference: preferredPower });
  }
  adapterRequests.push({});
  if (preferredPower !== 'low-power') {
    adapterRequests.push({ powerPreference: 'low-power' });
  }
  let adapter = null;
  const adapterAttemptDetails = [];
  for (const [requestIndex, request] of adapterRequests.entries()) {
    debugLog('runtime.requestAdapter.start', {
      requestIndex,
      request,
    });
    try {
      adapter = await gpu.requestAdapter(request);
    } catch (error) {
      const unsupported = classifyBringupUnsupported('requestAdapter', error);
      if (!unsupported) {
        throw error;
      }
      adapterAttemptDetails.push(unsupported.detail);
      debugLog('runtime.requestAdapter.result', {
        requestIndex,
        found: false,
        unsupportedCode: unsupported.unsupportedCode,
        reason: unsupported.reason,
        detail: unsupported.detail,
      });
      continue;
    }
    debugLog('runtime.requestAdapter.result', {
      requestIndex,
      found: Boolean(adapter),
    });
    if (adapter) {
      break;
    }
  }
  if (!adapter) {
    const detail = adapterAttemptDetails.join('; ') || 'requestAdapter returned null for all requests';
    throw makeUnsupportedNodeWebGpuError({
      unsupportedCode: 'adapter_unavailable',
      message: `node-webgpu adapter unavailable for provider ${spec.provider}`,
      detail,
      hostExecutorInitTotalNs: nsDelta(executorInitStartedAt),
      availability: providerAvailabilityFailure({
        reason: 'adapter_unavailable',
        provider: spec.provider,
        providerName: spec.providerName,
        runtimeHost,
        loader: spec.loader,
        stage: 'requestAdapter',
        detail,
        externalCode: 'adapter_unavailable',
      }),
    });
  }
  const adapterIssue = describeUnusableAdapterInfo(adapter?.info ?? null, spec.providerName);
  if (adapterIssue) {
    throw makeUnsupportedNodeWebGpuError({
      unsupportedCode: 'adapter_unavailable',
      message: `node-webgpu adapter unavailable for provider ${spec.provider}`,
      detail: adapterIssue,
      hostExecutorInitTotalNs: nsDelta(executorInitStartedAt),
      availability: providerAvailabilityFailure({
        reason: 'adapter_unavailable',
        provider: spec.provider,
        providerName: spec.providerName,
        runtimeHost,
        loader: spec.loader,
        stage: 'requestAdapter',
        detail: adapterIssue,
        externalCode: 'adapter_unavailable',
      }),
    });
  }

  const requiredFeatures = normalizedPlan.adapter?.requiredFeatures ?? [];
  const requiredLimits = normalizedPlan.adapter?.requiredLimits ?? {};
  const requestDeviceDescriptor = buildRequestDeviceDescriptor(normalizedPlan.adapter);
  debugLog('runtime.requestDevice.start', {
    requiredFeatureCount: requiredFeatures.length,
    requiredLimitCount: Object.keys(requiredLimits).length,
  });
  let device;
  try {
    device = await adapter.requestDevice(requestDeviceDescriptor);
  } catch (error) {
    const unsupported = classifyBringupUnsupported('requestDevice', error);
    if (!unsupported) {
      throw error;
    }
    throw makeUnsupportedNodeWebGpuError({
      unsupportedCode: unsupported.unsupportedCode,
      message: `node-webgpu device unavailable for provider ${spec.provider}`,
      detail: unsupported.detail,
      hostExecutorInitTotalNs: nsDelta(executorInitStartedAt),
      availability: providerAvailabilityFailure({
        reason: unsupported.reason,
        provider: spec.provider,
        providerName: spec.providerName,
        runtimeHost,
        loader: spec.loader,
        stage: 'requestDevice',
        detail: unsupported.detail,
        externalCode: unsupported.unsupportedCode,
      }),
    });
  }
  debugLog('runtime.requestDevice.done', {});
  const deviceIssue = describeUnusableAdapterInfo(
    device?.adapterInfo ?? adapter?.info ?? null,
    spec.providerName,
  );
  if (deviceIssue) {
    throw makeUnsupportedNodeWebGpuError({
      unsupportedCode: 'device_unavailable',
      message: `node-webgpu device unavailable for provider ${spec.provider}`,
      detail: deviceIssue,
      hostExecutorInitTotalNs: nsDelta(executorInitStartedAt),
      availability: providerAvailabilityFailure({
        reason: 'adapter_unavailable',
        provider: spec.provider,
        providerName: spec.providerName,
        runtimeHost,
        loader: spec.loader,
        stage: 'requestDevice',
        detail: deviceIssue,
        externalCode: 'device_unavailable',
      }),
    });
  }
  const hostExecutorInitTotalNs = nsDelta(executorInitStartedAt);
  const queue = device.queue;
  const queueWaitMode = queueWaitModeForRuntimeHost(runtimeHost);
  const buffers = new Map();
  const shaderModules = new Map();
  const dispatchStates = [];
  const bindGroupLayoutCache = new Map();
  const pipelineLayoutCache = new Map();
  const pipelineCache = new Map();
  const bindGroupCache = new Map();
  const setupBreakdownNs = zeroPackageSetupBreakdown();
  const shaderSourceInputs = [];
  const shaderModuleEvidenceInputs = [];
  debugLog('runtime.setup.start', {
    bufferCount: normalizedPlan.buffers.length,
    moduleCount: normalizedPlan.modules.length,
    dispatchCount: normalizedPlan.executionShape.dispatchCount,
  });

  const setupStartedAt = performance.now();
  for (const [bufferIndex, bufferDef] of normalizedPlan.buffers.entries()) {
    if (shouldLogProgress(bufferIndex, normalizedPlan.buffers.length)) {
      debugLog('runtime.setup.buffer', {
        bufferIndex,
        bufferCount: normalizedPlan.buffers.length,
        bufferId: bufferDef.id,
        size: bufferDef.size,
      });
    }
    const createStartedAt = performance.now();
    const buffer = device.createBuffer({
      size: bufferDef.size,
      usage: bufferUsageMask(globals, bufferDef.usage),
      ...(bufferDef.label ? { label: bufferDef.label } : {}),
    });
    setupBreakdownNs.bufferCreateTotalNs += nsDelta(createStartedAt);
    buffers.set(bufferDef.id, buffer);
    if (bufferDef.data) {
      const writeStartedAt = performance.now();
      const materialized = materializeBufferData(bufferDef.data);
      if (materialized) {
        queue.writeBuffer(buffer, 0, materialized);
      }
      setupBreakdownNs.initialDataWriteTotalNs += nsDelta(writeStartedAt);
    }
  }

  for (const [moduleIndex, moduleDef] of normalizedPlan.modules.entries()) {
    if (shouldLogProgress(moduleIndex, normalizedPlan.modules.length)) {
      debugLog('runtime.setup.module', {
        moduleIndex,
        moduleCount: normalizedPlan.modules.length,
        moduleId: moduleDef.id,
        sourceKind: moduleDef.source.kind,
      });
    }
    const moduleStartedAt = performance.now();
    const code = await readShaderSource(moduleDef);
    shaderModules.set(moduleDef.id, device.createShaderModule({ code }));
    setupBreakdownNs.shaderModuleCreateTotalNs += nsDelta(moduleStartedAt);
    shaderSourceInputs.push({ moduleDef, code });
    shaderModuleEvidenceInputs.push({
      moduleId: moduleDef.id,
      sourcePath: moduleDef.source?.kind === 'file' ? moduleDef.source.path : null,
      sourceSha256: sha256Urn(digestText(code)),
      entryPoint: moduleDef.entryPoint ?? null,
      workgroupSize: parseWgslWorkgroupSize(code),
    });
  }

  let dispatchSetupIndex = 0;
  for (const step of normalizedPlan.steps) {
    if (step.kind !== 'dispatch') {
      continue;
    }
    if (shouldLogProgress(dispatchSetupIndex, normalizedPlan.executionShape.dispatchCount)) {
      debugLog('runtime.setup.dispatch', {
        dispatchSetupIndex,
        dispatchCount: normalizedPlan.executionShape.dispatchCount,
        moduleId: step.moduleId,
        bindingCount: step.bindings.length,
      });
    }
    const shaderModule = shaderModules.get(step.moduleId);
    if (!shaderModule) {
      throw new Error(`dispatch references unknown module: ${step.moduleId}`);
    }
    let bindingLayouts = null;
    let bindEntries = null;
    const ensureBindingDescriptors = () => {
      if (bindingLayouts !== null && bindEntries !== null) {
        return;
      }
      bindingLayouts = [];
      bindEntries = [];
      for (const binding of step.bindings) {
        const { layout, entry } = buildBindingDescriptor(binding, buffers, globals);
        bindingLayouts.push(layout);
        bindEntries.push(entry);
      }
    };
    const layoutKey = buildDispatchBindingLayoutCacheKey(step);
    const bindGroupKey = `${layoutKey}:${buildDispatchBindingCacheKey(step)}`;
    const pipelineKey = `${step.moduleId}:${step.entryPoint ?? 'main'}:${layoutKey}`;
    let bindGroupLayout = bindGroupLayoutCache.get(layoutKey);
    let pipelineLayout = pipelineLayoutCache.get(layoutKey);
    let pipeline = pipelineCache.get(pipelineKey);
    let bindGroup = bindGroupCache.get(bindGroupKey);
    const dispatchState = () => ({
      step,
      pipeline,
      bindGroup,
      pipelineId: pipelineKey,
      shaderModuleId: step.moduleId,
      entryPoint: step.entryPoint ?? 'main',
    });

    if (bindGroupLayout && pipelineLayout && pipeline && bindGroup) {
      dispatchStates.push(dispatchState());
      dispatchSetupIndex += 1;
      continue;
    }
    if (!bindGroupLayout) {
      ensureBindingDescriptors();
      const bindGroupLayoutStartedAt = performance.now();
      bindGroupLayout = device.createBindGroupLayout({ entries: bindingLayouts });
      setupBreakdownNs.bindGroupLayoutCreateTotalNs += nsDelta(bindGroupLayoutStartedAt);
      bindGroupLayoutCache.set(layoutKey, bindGroupLayout);
    }
    if (!pipelineLayout) {
      const pipelineLayoutStartedAt = performance.now();
      pipelineLayout = device.createPipelineLayout({ bindGroupLayouts: [bindGroupLayout] });
      setupBreakdownNs.pipelineLayoutCreateTotalNs += nsDelta(pipelineLayoutStartedAt);
      pipelineLayoutCache.set(layoutKey, pipelineLayout);
    }
    if (!pipeline) {
      const pipelineStartedAt = performance.now();
      pipeline = device.createComputePipeline({
        layout: pipelineLayout,
        compute: {
          module: shaderModule,
          entryPoint: step.entryPoint ?? 'main',
        },
      });
      setupBreakdownNs.pipelineCreateTotalNs += nsDelta(pipelineStartedAt);
      pipelineCache.set(pipelineKey, pipeline);
    }
    if (!bindGroup) {
      ensureBindingDescriptors();
      const bindGroupStartedAt = performance.now();
      bindGroup = device.createBindGroup({
        layout: bindGroupLayout,
        entries: bindEntries,
      });
      setupBreakdownNs.bindGroupCreateTotalNs += nsDelta(bindGroupStartedAt);
      bindGroupCache.set(bindGroupKey, bindGroup);
    }
    dispatchStates.push(dispatchState());
    dispatchSetupIndex += 1;
  }
  const dispatchPrewarmTotalNs = prewarmDispatchBindings
    ? prewarmPreparedDispatches({
      providerModule: webgpu,
      queue,
      dispatchStates,
    }, debugLog)
    : 0;
  setupBreakdownNs.dispatchPrewarmTotalNs += dispatchPrewarmTotalNs;
  const setupTotalNs = nsFromMs(performance.now() - setupStartedAt);
  debugLog('runtime.setup.done', {
    setupTotalNs,
    setupBreakdownNs,
  });
  const shaderSourceReceipts = shaderSourceInputs.map(({ moduleDef, code }) => (
    buildShaderSourceReceipt(moduleDef, code)
  ));

  return {
    // Keep the provider module and JS GPU root alive until the run fully drains.
    // Dawn's Node AsyncRunner schedules future ProcessEvents() callbacks against
    // the native Instance reachable from this JS object.
    providerModule: webgpu,
    providerRoot: gpu,
    adapter,
    device,
    queue,
    queueWaitMode,
    queueWaitFence: queueWaitMode === NODE_PACKAGE_QUEUE_WAIT_MODE &&
      NODE_PACKAGE_QUEUE_WAIT_MODE !== PACKAGE_QUEUE_WAIT_MODE
      ? createQueueWaitFence(device, queue, globals)
      : null,
    globals,
    providerSpec: spec,
    runtimeHost,
    policyProvider: null,
    buffers,
    dispatchStates,
    hostExecutorInitTotalNs,
    hostKernelPrewarmTotalNs: dispatchPrewarmTotalNs,
    setupTotalNs,
    setupBreakdownNs,
    shaderSourceReceipts,
    shaderModuleEvidenceInputs,
  };
}

async function preloadResidentBufferLoads(
  normalizedPlan,
  runtime,
  materializedWriteDataCache,
  residentBufferLoadBreakdown,
  debugLog,
) {
  for (const [index, step] of normalizedPlan.steps.entries()) {
    if (!isStaticBufferLoadStep(step)) {
      continue;
    }
    const buffer = runtime.buffers.get(step.bufferId);
    if (!buffer) {
      throw new Error(`resident buffer load references unknown buffer: ${step.bufferId}`);
    }
    const materializeStartedAt = performance.now();
    const materialized = materializeWriteBufferDataForStep(
      materializedWriteDataCache,
      index,
      step.data,
    );
    const materializeNs = nsDelta(materializeStartedAt);
    const writeStartedAt = performance.now();
    runtime.queue.writeBuffer(buffer, step.offset ?? 0, materialized);
    const queueWriteNs = nsDelta(writeStartedAt);
    residentBufferLoadBreakdown.count += 1;
    residentBufferLoadBreakdown.bytes += materialized.byteLength;
    residentBufferLoadBreakdown.materializeTotalNs += materializeNs;
    residentBufferLoadBreakdown.queueWriteTotalNs += queueWriteNs;
    debugLog('residentBufferLoad.write', {
      stepIndex: index,
      stepId: step.id ?? `step-${index}`,
      byteLength: materialized.byteLength,
      materializeNs,
      queueWriteNs,
    });
  }
  if (residentBufferLoadBreakdown.count > 0) {
    const waitStartedAt = performance.now();
    await waitForQueuedWrites(runtime);
    residentBufferLoadBreakdown.queueWaitTotalNs += nsDelta(waitStartedAt);
  }
}

async function executeSample(
  normalizedPlan,
  runtime,
  {
    includeSetupInSelectedTiming,
    debugLog,
    queueWaitScope,
    queueWaitSubmitCadence,
    commandRepeat,
    residentBufferLoads,
    packageExecutionPolicy,
    runtimeHost,
  },
) {
  const rows = [];
  const determinismCaptureRows = new Map();
  const readbackCaptures = [];
  const packageEffectiveReadbackPaths = new Set();
  const readbackDigestCache = new Map();
  const readbackValidationCache = new Map();
  const readbackCaptureTemplates = normalizedPlan.steps.map((step, index) => (
    step.kind === 'readBuffer' ? buildReadbackCaptureTemplate(index, step) : null
  ));
  const determinismCaptureTemplates = normalizedPlan.steps.map((step) => (
    step.kind === 'readBuffer' ? buildDeterminismCaptureTemplate(step) : null
  ));
  const validationTemplates = normalizedPlan.steps.map((step) => (
    step.kind === 'readBuffer' ? buildValidationTemplate(step.validate) : null
  ));
  const materializedWriteDataCache = new Map();
  const compactWriteBatchCache = new Map();
  const packageFastPathStatsStart = snapshotPackageFastPathStats(runtime.providerModule);
  const policyProvider = runtime.policyProvider ?? packagePolicyProvider(runtime);
  runtime.policyProvider = policyProvider;
  const packageReadbackMode = packageReadbackModeForExecution(packageExecutionPolicy, {
    runtimeHost,
    provider: policyProvider,
    workloadId: normalizedPlan.workloadId,
    packagePreparedSession: !includeSetupInSelectedTiming,
  });
  let executionSetupTotalNs = 0;
  let executionEncodeTotalNs = 0;
  let executionSubmitWaitTotalNs = 0;
  let executionDispatchCount = 0;
  let executionSuccessCount = 0;
  const stepBreakdownNs = zeroPackageStepBreakdown();
  const writeBreakdown = zeroPackageWriteBreakdown();
  const residentBufferLoadBreakdown = zeroPackageResidentBufferLoadBreakdown();
  let encoder = null;
  let pass = null;
  let dispatchStateIndex = 0;
  let submitCount = 0;
  let queueCompletionKnown = false;
  async function flushEncoder({ waitForCompletion }) {
    if (!encoder) {
      if (waitForCompletion && runtime.queueWaitFence && !queueCompletionKnown) {
        const submitStartedAt = performance.now();
        const finishStartedAt = submitStartedAt;
        submitCount += 1;
        const syncEncoder = runtime.device.createCommandEncoder();
        appendQueueWaitFenceCopy(runtime, syncEncoder);
        const commandBuffer = syncEncoder.finish();
        const finishNs = nsDelta(finishStartedAt);
        const queueSubmitStartedAt = performance.now();
        runtime.queue.submit([commandBuffer]);
        const queueSubmitNs = nsDelta(queueSubmitStartedAt);
        const queueWaitStartedAt = performance.now();
        await awaitQueueCompletion(runtime);
        const queueWaitNs = nsDelta(queueWaitStartedAt);
        const submitNs = nsFromMs(performance.now() - submitStartedAt);
        queueCompletionKnown = true;
        stepBreakdownNs.submitCommandEncoderFinishTotalNs += finishNs;
        stepBreakdownNs.submitQueueSubmitTotalNs += queueSubmitNs;
        stepBreakdownNs.submitQueueWaitTotalNs += queueWaitNs;
        executionSubmitWaitTotalNs += submitNs;
        debugLog('execution.submit.done', {
          submitIndex: submitCount,
          finishNs,
          queueSubmitNs,
          queueWaitNs,
          submitWaitNs: submitNs,
          waitedForCompletion: true,
          waitReason: 'terminal-or-readback',
          writeOnlyDrain: true,
        });
      }
      return;
    }
    if (pass) {
      pass.end();
      pass = null;
    }
    const submitStartedAt = performance.now();
    const finishStartedAt = submitStartedAt;
    submitCount += 1;
    const isFirstSubmit = submitCount === 1;
    const waitReason = waitForCompletion
      ? 'terminal-or-readback'
      : (
        queueWaitSubmitCadence > 0
        && submitCount % queueWaitSubmitCadence === 0
          ? 'submit-cadence'
          : ''
      );
    debugLog('execution.submit.finish.start', {
      submitIndex: submitCount,
      dispatchesEncoded: dispatchStateIndex,
      waitForCompletion,
    });
    if (isFirstSubmit) {
      debugLog('execution.firstSubmit.finish.start', {
        dispatchesEncoded: dispatchStateIndex,
      });
    }
    if (waitReason && runtime.queueWaitFence) {
      appendQueueWaitFenceCopy(runtime, encoder);
    }
    const commandBuffer = encoder.finish();
    const finishNs = nsDelta(finishStartedAt);
    encoder = null;
    debugLog('execution.submit.finish.done', {
      submitIndex: submitCount,
      finishNs,
      dispatchesEncoded: dispatchStateIndex,
      waitForCompletion,
    });
    if (isFirstSubmit) {
      debugLog('execution.firstSubmit.start', {
        dispatchesEncoded: dispatchStateIndex,
      });
      debugLog('execution.firstSubmit.finish.done', {
        finishNs,
        dispatchesEncoded: dispatchStateIndex,
      });
    }
    const queueSubmitStartedAt = performance.now();
    debugLog('execution.submit.queueSubmit.start', {
      submitIndex: submitCount,
      dispatchesEncoded: dispatchStateIndex,
      waitForCompletion,
    });
    if (isFirstSubmit) {
      debugLog('execution.firstSubmit.queueSubmit.start', {
        dispatchesEncoded: dispatchStateIndex,
      });
    }
    runtime.queue.submit([commandBuffer]);
    const queueSubmitNs = nsDelta(queueSubmitStartedAt);
    queueCompletionKnown = false;
    debugLog('execution.submit.queueSubmit.done', {
      submitIndex: submitCount,
      queueSubmitNs,
      dispatchesEncoded: dispatchStateIndex,
      waitForCompletion,
    });
    if (isFirstSubmit) {
      debugLog('execution.firstSubmit.queueSubmit.done', {
        queueSubmitNs,
        dispatchesEncoded: dispatchStateIndex,
      });
    }
    let queueWaitNs = 0;
    if (waitReason) {
      const queueWaitStartedAt = performance.now();
      debugLog('execution.submit.queueWait.start', {
        submitIndex: submitCount,
        dispatchesEncoded: dispatchStateIndex,
        waitReason,
      });
      if (isFirstSubmit) {
        debugLog('execution.firstSubmit.queueWait.start', {
          dispatchesEncoded: dispatchStateIndex,
          waitReason,
        });
      }
      await awaitQueueCompletion(runtime);
      queueWaitNs = nsDelta(queueWaitStartedAt);
      queueCompletionKnown = true;
      debugLog('execution.submit.queueWait.done', {
        submitIndex: submitCount,
        queueWaitNs,
        dispatchesEncoded: dispatchStateIndex,
        waitReason,
      });
      if (isFirstSubmit) {
        debugLog('execution.firstSubmit.queueWait.done', {
          queueWaitNs,
          dispatchesEncoded: dispatchStateIndex,
          waitReason,
        });
      }
    }
    const submitNs = nsFromMs(performance.now() - submitStartedAt);
    stepBreakdownNs.submitCommandEncoderFinishTotalNs += finishNs;
    stepBreakdownNs.submitQueueSubmitTotalNs += queueSubmitNs;
    stepBreakdownNs.submitQueueWaitTotalNs += queueWaitNs;
    executionSubmitWaitTotalNs += submitNs;
    debugLog('execution.submit.done', {
      submitIndex: submitCount,
      finishNs,
      queueSubmitNs,
      queueWaitNs,
      submitWaitNs: submitNs,
      waitedForCompletion: Boolean(waitReason),
      waitReason,
    });
    if (isFirstSubmit) {
      debugLog('execution.firstSubmit.done', {
        finishNs,
        queueSubmitNs,
        queueWaitNs,
        submitWaitNs: submitNs,
        waitedForCompletion: Boolean(waitReason),
        waitReason,
      });
    }
  }

  if (residentBufferLoads) {
    await preloadResidentBufferLoads(
      normalizedPlan,
      runtime,
      materializedWriteDataCache,
      residentBufferLoadBreakdown,
      debugLog,
    );
  }

  const commandLoopStartedAt = performance.now();
  for (let repeatIndex = 0; repeatIndex < commandRepeat; repeatIndex += 1) {
    dispatchStateIndex = 0;
    for (let index = 0; index < normalizedPlan.steps.length; index += 1) {
      const step = normalizedPlan.steps[index];
      debugLog('execution.step.start', {
        repeatIndex,
        commandRepeat,
        stepIndex: index,
        stepCount: normalizedPlan.steps.length,
        stepKind: step.kind,
        ...(typeof step.bufferId === 'string' ? { bufferId: step.bufferId } : {}),
        ...(typeof step.moduleId === 'string' ? { moduleId: step.moduleId } : {}),
      });
      if (residentBufferLoads && isStaticBufferLoadStep(step)) {
        debugLog('execution.step.residentBufferLoad.skip', {
          repeatIndex,
          commandRepeat,
          stepIndex: index,
          stepId: step.id ?? `step-${index}`,
        });
        continue;
      }
      if (step.kind === 'writeBuffer') {
        const batchMethod = packageWriteBatchMethod(runtime.queue);
        const batchedSteps = [];
        if (batchMethod !== PACKAGE_WRITE_BATCH_METHOD_NONE && isDynamicWriteBufferStep(step)) {
          for (
            let batchIndex = index;
            batchIndex < normalizedPlan.steps.length;
            batchIndex += 1
          ) {
            const batchStep = normalizedPlan.steps[batchIndex];
            if (!isDynamicWriteBufferStep(batchStep)) {
              break;
            }
            batchedSteps.push({ index: batchIndex, step: batchStep });
          }
        }

        const minConsecutiveWrites = packageWriteBatchMinConsecutiveWrites(packageExecutionPolicy, {
          runtimeHost,
          provider: runtime.policyProvider ?? runtime.providerSpec.provider,
          method: batchMethod,
        });

        if (batchedSteps.length >= minConsecutiveWrites) {
          await flushEncoder({ waitForCompletion: false });
          const batchEntries = [];
          const batchRows = [];
          let materializeTotalNs = 0;
          for (const batched of batchedSteps) {
            const buffer = runtime.buffers.get(batched.step.bufferId);
            if (!buffer) {
              throw new Error(`writeBuffer references unknown buffer: ${batched.step.bufferId}`);
            }
            const materializeStartedAt = performance.now();
            const materialized = materializeWriteBufferDataForStep(
              materializedWriteDataCache,
              batched.index,
              batched.step.data,
            );
            const materializeNs = nsDelta(materializeStartedAt);
            materializeTotalNs += materializeNs;
            batchEntries.push({
              buffer,
              offset: batched.step.offset ?? 0,
              data: materialized,
            });
            batchRows.push({
              index: batched.index,
              step: batched.step,
              materializeNs,
              byteLength: materialized.byteLength,
            });
            recordPackageWriteBreakdown(writeBreakdown, batched.step, materialized.byteLength);
          }
          let preparedCompact = null;
          if (batchMethod === PACKAGE_WRITE_BATCH_METHOD_DIRECT_QUEUE) {
            const compactStartedAt = performance.now();
            preparedCompact = prepareQueueWriteBufferBatch(
              batchMethod,
              batchEntries,
              compactWriteBatchCache,
              compactWriteBatchCacheKey(batchedSteps),
            );
            materializeTotalNs += nsDelta(compactStartedAt);
          }
          const writeStartedAt = performance.now();
          queueWriteBufferBatch(runtime.queue, batchMethod, batchEntries, preparedCompact);
          const queueWriteNs = nsDelta(writeStartedAt);
          recordPackageBatchedWrites(writeBreakdown, batchedSteps.length, batchMethod);
          queueCompletionKnown = false;
          stepBreakdownNs.writeMaterializeTotalNs += materializeTotalNs;
          stepBreakdownNs.writeQueueWriteTotalNs += queueWriteNs;
          executionSetupTotalNs += materializeTotalNs + queueWriteNs;
          const queueWriteShareNs = Math.floor(queueWriteNs / batchRows.length);
          let queueWriteRemainderNs = queueWriteNs - queueWriteShareNs * batchRows.length;
          for (const batchRow of batchRows) {
            const rowQueueWriteNs = queueWriteShareNs + (queueWriteRemainderNs > 0 ? 1 : 0);
            if (queueWriteRemainderNs > 0) {
              queueWriteRemainderNs -= 1;
            }
            const writeNs = batchRow.materializeNs + rowQueueWriteNs;
            rows.push({
              schemaVersion: 1,
              kind: 'node_webgpu_step',
              stepIndex: batchRow.index,
              stepId: batchRow.step.id ?? `step-${batchRow.index}`,
              stepKind: batchRow.step.kind,
              executionBackend: runtime.providerSpec.executionBackend,
              executionProvider: runtime.providerSpec.provider,
              executionProviderName: runtime.providerSpec.providerName,
              executionDurationNs: writeNs,
              executionSetupNs: writeNs,
              executionEncodeNs: 0,
              executionSubmitWaitNs: 0,
              executionSuccess: true,
              ...(typeof batchRow.step.semanticOpId === 'string' ? { semanticOpId: batchRow.step.semanticOpId } : {}),
              ...(typeof batchRow.step.semanticStage === 'string' ? { semanticStage: batchRow.step.semanticStage } : {}),
              ...(typeof batchRow.step.semanticPhase === 'string' ? { semanticPhase: batchRow.step.semanticPhase } : {}),
              ...(Number.isInteger(batchRow.step.semanticTokenIndex) ? { semanticTokenIndex: batchRow.step.semanticTokenIndex } : {}),
              timingSource: 'doe-execution-total-ns',
              timingClass: 'operation',
              workloadId: normalizedPlan.workloadId,
              planId: normalizedPlan.planId,
              planHash: normalizedPlan.planHash,
            });
          }
          executionSuccessCount += batchedSteps.length;
          index = batchedSteps[batchedSteps.length - 1].index;
        } else {
          await flushEncoder({ waitForCompletion: false });
          const buffer = runtime.buffers.get(step.bufferId);
          if (!buffer) {
            throw new Error(`writeBuffer references unknown buffer: ${step.bufferId}`);
          }
          const materializeStartedAt = performance.now();
          const materialized = materializeWriteBufferDataForStep(
            materializedWriteDataCache,
            index,
            step.data,
          );
          const materializeNs = nsDelta(materializeStartedAt);
          const writeStartedAt = performance.now();
          runtime.queue.writeBuffer(buffer, step.offset ?? 0, materialized);
          const queueWriteNs = nsDelta(writeStartedAt);
          recordPackageWriteBreakdown(writeBreakdown, step, materialized.byteLength);
          recordPackageUnbatchedWrite(writeBreakdown);
          queueCompletionKnown = false;
          const writeNs = materializeNs + queueWriteNs;
          stepBreakdownNs.writeMaterializeTotalNs += materializeNs;
          stepBreakdownNs.writeQueueWriteTotalNs += queueWriteNs;
          executionSetupTotalNs += writeNs;
          rows.push({
            schemaVersion: 1,
            kind: 'node_webgpu_step',
            stepIndex: index,
            stepId: step.id ?? `step-${index}`,
            stepKind: step.kind,
            executionBackend: runtime.providerSpec.executionBackend,
            executionProvider: runtime.providerSpec.provider,
            executionProviderName: runtime.providerSpec.providerName,
            executionDurationNs: writeNs,
            executionSetupNs: writeNs,
            executionEncodeNs: 0,
            executionSubmitWaitNs: 0,
            executionSuccess: true,
            ...(typeof step.semanticOpId === 'string' ? { semanticOpId: step.semanticOpId } : {}),
            ...(typeof step.semanticStage === 'string' ? { semanticStage: step.semanticStage } : {}),
            ...(typeof step.semanticPhase === 'string' ? { semanticPhase: step.semanticPhase } : {}),
            ...(Number.isInteger(step.semanticTokenIndex) ? { semanticTokenIndex: step.semanticTokenIndex } : {}),
            timingSource: 'doe-execution-total-ns',
            timingClass: 'operation',
            workloadId: normalizedPlan.workloadId,
            planId: normalizedPlan.planId,
            planHash: normalizedPlan.planHash,
          });
          executionSuccessCount += 1;
        }
        continue;
      }

    if (step.kind === 'dispatch') {
      if (!encoder) {
        encoder = runtime.device.createCommandEncoder();
      }
      if (!pass) {
        pass = encoder.beginComputePass();
      }
      const state = runtime.dispatchStates[dispatchStateIndex++];
      if (!state || state.step.moduleId !== step.moduleId) {
        throw new Error(`dispatch plan mismatch at step ${index}`);
      }
      const opStartedAt = performance.now();
      pass.setPipeline(state.pipeline);
      pass.setBindGroup(0, state.bindGroup);
      pass.dispatchWorkgroups(step.workgroups[0], step.workgroups[1], step.workgroups[2]);
      const opNs = nsDelta(opStartedAt);
      stepBreakdownNs.dispatchEncodeApiTotalNs += opNs;
      executionEncodeTotalNs += opNs;
      rows.push({
        schemaVersion: 1,
        kind: 'node_webgpu_step',
        stepIndex: index,
        stepId: step.id ?? `step-${index}`,
        stepKind: step.kind,
        executionBackend: runtime.providerSpec.executionBackend,
        executionProvider: runtime.providerSpec.provider,
        executionProviderName: runtime.providerSpec.providerName,
        executionDurationNs: opNs,
        executionSetupNs: 0,
        executionEncodeNs: opNs,
        executionSubmitWaitNs: 0,
        executionSuccess: true,
        timingSource: 'doe-execution-total-ns',
        timingClass: 'operation',
        workloadId: normalizedPlan.workloadId,
        planId: normalizedPlan.planId,
        planHash: normalizedPlan.planHash,
      });
      executionDispatchCount += 1;
      executionSuccessCount += 1;
      continue;
    }

    if (step.kind === 'copyBufferToBuffer') {
      if (!encoder) {
        encoder = runtime.device.createCommandEncoder();
      }
      if (pass) {
        pass.end();
        pass = null;
      }
      const src = runtime.buffers.get(step.srcBufferId);
      const dst = runtime.buffers.get(step.dstBufferId);
      if (!src || !dst) {
        throw new Error(`copyBufferToBuffer references unknown buffer(s): ${step.srcBufferId} -> ${step.dstBufferId}`);
      }
      const opStartedAt = performance.now();
      encoder.copyBufferToBuffer(src, step.srcOffset ?? 0, dst, step.dstOffset ?? 0, step.sizeBytes);
      const opNs = nsDelta(opStartedAt);
      stepBreakdownNs.copyEncodeApiTotalNs += opNs;
      executionEncodeTotalNs += opNs;
      rows.push({
        schemaVersion: 1,
        kind: 'node_webgpu_step',
        stepIndex: index,
        stepId: step.id ?? `step-${index}`,
        stepKind: step.kind,
        executionBackend: runtime.providerSpec.executionBackend,
        executionProvider: runtime.providerSpec.provider,
        executionProviderName: runtime.providerSpec.providerName,
        executionDurationNs: opNs,
        executionSetupNs: 0,
        executionEncodeNs: opNs,
        executionSubmitWaitNs: 0,
        executionSuccess: true,
        ...(typeof step.semanticOpId === 'string' ? { semanticOpId: step.semanticOpId } : {}),
        ...(typeof step.semanticStage === 'string' ? { semanticStage: step.semanticStage } : {}),
        ...(typeof step.semanticPhase === 'string' ? { semanticPhase: step.semanticPhase } : {}),
        ...(Number.isInteger(step.semanticTokenIndex) ? { semanticTokenIndex: step.semanticTokenIndex } : {}),
        timingSource: 'doe-execution-total-ns',
        timingClass: 'operation',
        workloadId: normalizedPlan.workloadId,
        planId: normalizedPlan.planId,
        planHash: normalizedPlan.planHash,
      });
      executionSuccessCount += 1;
      continue;
    }

    if (step.kind === 'readBuffer') {
      const readbackMapCompletesSubmit = runtime.queueWaitMode === NODE_PACKAGE_QUEUE_WAIT_MODE
        && readBufferMapCanCompleteSubmit(normalizedPlan.steps, index, step);
      await flushEncoder({ waitForCompletion: !readbackMapCompletesSubmit });
      const buffer = runtime.buffers.get(step.bufferId);
      if (!buffer) {
        throw new Error(`readBuffer references unknown buffer: ${step.bufferId}`);
      }
      const determinismCaptureTemplate = determinismCaptureTemplates[index];
      const readStartedAt = performance.now();
      const readback = await copyReadBufferBytes({
        buffer,
        globals: runtime.globals,
        sizeBytes: buffer.size,
        readbackMode: packageReadbackMode,
      });
      packageEffectiveReadbackPaths.add(effectivePackageReadbackPath(readback.path));
      const validationStartedAt = performance.now();
      const validation = validatePreparedSampleExpectation(
        readback.bytes,
        validationTemplates[index],
        readbackValidationCache,
      );
      readback.breakdownNs.readbackValidationTotalNs += nsDelta(validationStartedAt);
      if (!validation.ok) {
        throw new Error(`validation failed for ${step.bufferId}: ${validation.detail}`);
      }
      const captureTemplate = readbackCaptureTemplates[index];
      const captureStartedAt = performance.now();
      const readbackView = readback.bytes instanceof Uint8Array
        ? readback.bytes
        : new Uint8Array(readback.bytes ?? []);
      readbackCaptures.push(summarizePreparedReadbackCapture(
        repeatIndex,
        readbackView,
        captureTemplate,
        readbackDigestCache,
      ));
      if (determinismCaptureTemplate) {
        determinismCaptureTemplate.row.bytes = readbackView;
        determinismCaptureRows.set(determinismCaptureTemplate.key, determinismCaptureTemplate.row);
      }
      readback.breakdownNs.readbackCaptureTotalNs += nsDelta(captureStartedAt);
      if (readbackMapCompletesSubmit) {
        queueCompletionKnown = true;
      }
      const stepNs = nsDelta(readStartedAt);
      stepBreakdownNs.readbackTotalNs += stepNs;
      addReadbackBreakdown(stepBreakdownNs, readback.breakdownNs);
      executionSubmitWaitTotalNs += stepNs;
      rows.push({
        schemaVersion: 1,
        kind: 'node_webgpu_step',
        stepIndex: index,
        stepId: step.id ?? `step-${index}`,
        stepKind: step.kind,
        executionBackend: runtime.providerSpec.executionBackend,
        executionProvider: runtime.providerSpec.provider,
        executionProviderName: runtime.providerSpec.providerName,
        executionDurationNs: stepNs,
        executionSetupNs: 0,
        executionEncodeNs: 0,
        executionSubmitWaitNs: stepNs,
        executionSuccess: true,
        ...(typeof step.semanticOpId === 'string' ? { semanticOpId: step.semanticOpId } : {}),
        ...(typeof step.semanticStage === 'string' ? { semanticStage: step.semanticStage } : {}),
        ...(typeof step.semanticPhase === 'string' ? { semanticPhase: step.semanticPhase } : {}),
        ...(Number.isInteger(step.semanticTokenIndex) ? { semanticTokenIndex: step.semanticTokenIndex } : {}),
        timingSource: 'doe-execution-total-ns',
        timingClass: 'operation',
        workloadId: normalizedPlan.workloadId,
        planId: normalizedPlan.planId,
        planHash: normalizedPlan.planHash,
      });
      executionSuccessCount += 1;
      continue;
    }

    throw new Error(`unsupported step kind during execution: ${step.kind}`);
  }
  }

  await flushEncoder({ waitForCompletion: true });
  if (runtime.queue?._submitBreakdownNs) {
    stepBreakdownNs.submitCommandPrepTotalNs = runtime.queue._submitBreakdownNs.submitCommandPrepTotalNs ?? 0;
    stepBreakdownNs.submitAddonCallTotalNs = runtime.queue._submitBreakdownNs.submitAddonCallTotalNs ?? 0;
    stepBreakdownNs.submitAddonCommandReplayTotalNs = runtime.queue._submitBreakdownNs.submitAddonCommandReplayTotalNs ?? 0;
    stepBreakdownNs.submitAddonCommandReplayPrepareTotalNs = runtime.queue._submitBreakdownNs.submitAddonCommandReplayPrepareTotalNs ?? 0;
    stepBreakdownNs.submitAddonCommandReplayRecordTotalNs = runtime.queue._submitBreakdownNs.submitAddonCommandReplayRecordTotalNs ?? 0;
    stepBreakdownNs.submitAddonCommandReplayCopyTotalNs = runtime.queue._submitBreakdownNs.submitAddonCommandReplayCopyTotalNs ?? 0;
    stepBreakdownNs.submitAddonQueueSubmitTotalNs = runtime.queue._submitBreakdownNs.submitAddonQueueSubmitTotalNs ?? 0;
    stepBreakdownNs.submitAddonCommandBufferEndTotalNs = runtime.queue._submitBreakdownNs.submitAddonCommandBufferEndTotalNs ?? 0;
    stepBreakdownNs.submitAddonSyncPrepareTotalNs = runtime.queue._submitBreakdownNs.submitAddonSyncPrepareTotalNs ?? 0;
    stepBreakdownNs.submitAddonDriverSubmitTotalNs = runtime.queue._submitBreakdownNs.submitAddonDriverSubmitTotalNs ?? 0;
    stepBreakdownNs.submitAddonFlushTotalNs = runtime.queue._submitBreakdownNs.submitAddonFlushTotalNs ?? 0;
    stepBreakdownNs.submitPostSubmitBookkeepingTotalNs = runtime.queue._submitBreakdownNs.submitPostSubmitBookkeepingTotalNs ?? 0;
    stepBreakdownNs.submitQueueFlushTotalNs = runtime.queue._submitBreakdownNs.submitQueueFlushTotalNs ?? 0;
    stepBreakdownNs.submitQueueFlushWaitCompletedTotalNs = runtime.queue._submitBreakdownNs.submitQueueFlushWaitCompletedTotalNs ?? 0;
    stepBreakdownNs.submitQueueFlushDeferredCopyTotalNs = runtime.queue._submitBreakdownNs.submitQueueFlushDeferredCopyTotalNs ?? 0;
    stepBreakdownNs.submitQueueFlushDeferredResolveTotalNs = runtime.queue._submitBreakdownNs.submitQueueFlushDeferredResolveTotalNs ?? 0;
    stepBreakdownNs.submitQueueWaitBookkeepingTotalNs = runtime.queue._submitBreakdownNs.submitQueueWaitBookkeepingTotalNs ?? 0;
  }
  const commandLoopWallNs = nsDelta(commandLoopStartedAt);
  const selectedLoopTotalNs = executionSetupTotalNs + executionEncodeTotalNs + executionSubmitWaitTotalNs;
  const executionTotalNs = (
    (includeSetupInSelectedTiming ? runtime.setupTotalNs : 0)
    + selectedLoopTotalNs
  );
  const hostCommandOrchestrationTotalNs = Math.max(0, commandLoopWallNs - selectedLoopTotalNs);
  const timingMs = executionTotalNs / 1_000_000;
  const determinismResult = await evaluateExecutionDeterminism({
    determinismConfig: normalizedPlan.determinism ?? null,
    provider: runtime.providerSpec.provider,
    captureRows: determinismCaptureRows,
  });
  debugLog('execution.done', {
    includeSetupInSelectedTiming,
    executionTotalNs,
    executionSetupTotalNs: (includeSetupInSelectedTiming ? runtime.setupTotalNs : 0) + executionSetupTotalNs,
    executionEncodeTotalNs,
    executionSubmitWaitTotalNs,
    hostCommandOrchestrationTotalNs,
  });
  const hostUploadPrewarmTotalNs = (
    residentBufferLoadBreakdown.materializeTotalNs
    + residentBufferLoadBreakdown.queueWriteTotalNs
    + residentBufferLoadBreakdown.queueWaitTotalNs
  );
  const packageFastPathStats = diffPackageFastPathStats(
    packageFastPathStatsStart,
    snapshotPackageFastPathStats(runtime.providerModule),
  );
  const packageNativeFastPaths = snapshotPackageNativeFastPaths(runtime.providerModule);
  const packageNativeQueueSyncInfo = snapshotPackageNativeQueueSyncInfo(
    runtime.providerModule,
    runtime.queue,
  );
  const packagePipelineCacheFlushNs = flushPackagePipelineCache(
    runtime.providerModule,
    runtime.queue,
    debugLog,
  );
  const pipelineCache = snapshotPackagePipelineCacheInfo(
    runtime.providerModule,
    runtime.queue,
    packagePipelineCacheFlushNs,
  );
  runtime.internalDispatchShaderEvidence = collectPackageDispatchShaderEvidence({
    normalizedPlan,
    shaderSourceReceipts: runtime.shaderSourceReceipts,
    shaderModuleEvidenceInputs: runtime.shaderModuleEvidenceInputs,
    dispatchStates: runtime.dispatchStates,
    readbackCaptures,
  });

  const meta = {
    schemaVersion: 1,
    kind: 'trace_meta',
    provider: runtime.providerSpec.provider,
    providerName: runtime.providerSpec.providerName,
    executionBackend: runtime.providerSpec.executionBackend,
    executionProvider: runtime.providerSpec.provider,
    executionProviderName: runtime.providerSpec.providerName,
    executionRowCount: rows.length,
    executionSuccessCount,
    executionErrorCount: 0,
    executionSkippedCount: 0,
    executionUnsupportedCount: 0,
    executionDispatchCount,
    executionSubmitCount: submitCount,
    executionTotalNs,
    executionSetupTotalNs: (includeSetupInSelectedTiming ? runtime.setupTotalNs : 0) + executionSetupTotalNs,
    executionEncodeTotalNs,
    executionSubmitWaitTotalNs,
    hostInputReadTotalNs: 0,
    hostInputParseTotalNs: 0,
    hostWorkloadPrepareTotalNs: 0,
    hostExecutorInitTotalNs: runtime.hostExecutorInitTotalNs,
    hostUploadPrewarmTotalNs,
    hostKernelPrewarmTotalNs: runtime.hostKernelPrewarmTotalNs ?? 0,
    hostCommandOrchestrationTotalNs,
    hostArtifactFinalizeTotalNs: 0,
    timingMs,
    timingSource: 'doe-execution-total-ns',
    timingClass: 'operation',
    queueSyncMode: PACKAGE_QUEUE_SYNC_MODE,
    queueWaitMode: runtime.queueWaitMode,
    queueWaitScope,
    queueWaitSubmitCadence,
    executionQueueSyncMode: PACKAGE_QUEUE_SYNC_MODE,
    executionQueueWaitMode: runtime.queueWaitMode,
    executionQueueWaitScope: queueWaitScope,
    executionQueueWaitSubmitCadence: queueWaitSubmitCadence,
    workload: normalizedPlan.workloadId,
    canonicalWorkloadId: normalizedPlan.workloadId,
    planId: normalizedPlan.planId,
    planHash: normalizedPlan.planHash,
    adapterInfo: runtime.adapter.info ?? null,
    adapterLimits: runtime.adapter.limits ?? null,
    planSummary: planSummary(normalizedPlan),
    executionShape: normalizedPlan.executionShape,
    ...shaderSourceReceiptFields(runtime.shaderSourceReceipts),
    packagePreparedSession: !includeSetupInSelectedTiming,
    packageSetupIncludedInSelectedTiming: includeSetupInSelectedTiming,
    packageSetupTotalNs: runtime.setupTotalNs,
    packageSetupBreakdownNs: runtime.setupBreakdownNs,
    packageStepBreakdownNs: stepBreakdownNs,
    packageWriteBreakdown: writeBreakdown,
    packageResidentBufferLoads: residentBufferLoads,
    packageResidentBufferLoadBreakdown: residentBufferLoadBreakdown,
    packageReadbackMode,
    packageEffectiveReadbackPaths: Array.from(packageEffectiveReadbackPaths).sort(),
    ...(packageNativeFastPaths ? { packageNativeFastPaths } : {}),
    ...(packageNativeQueueSyncInfo ? { packageNativeQueueSyncInfo } : {}),
    ...(pipelineCache ? { pipelineCache } : {}),
    ...(packageFastPathStats ? { packageFastPathStats } : {}),
    ...(readbackCaptures.length > 0 ? { readbackCaptures } : {}),
    ...(determinismResult ? { determinism: determinismResult.determinism } : {}),
    samplesMs: [timingMs],
    stats: {
      count: 1,
      min: timingMs,
      max: timingMs,
      median: timingMs,
      p95: timingMs,
      p99: timingMs,
      mean: timingMs,
      stdev: 0,
    },
  };
  meta.artifactHash = stableArtifactHash(meta);

  return { meta, rows };
}

export async function executePlanFile({
  planPath,
  workloadId,
  provider = 'dawn',
  runtimeHost = 'node',
  traceMetaPath,
  traceJsonlPath,
  dryRun = false,
  preparedSession = false,
  debugBoundaries = false,
  stepLimit = 0,
  commandRepeat = 1,
  residentBufferLoads = false,
}) {
  const normalizedCommandRepeat = normalizePositiveInt(commandRepeat, 'commandRepeat');
  if (residentBufferLoads && !preparedSession) {
    throw new Error('--resident-buffer-loads requires --prepared-session');
  }
  const debugEnabled = (
    debugBoundaries
    || process.env.DOE_NODE_WEBGPU_DEBUG_BOUNDARIES === '1'
    || (runtimeHost === 'bun' && process.env.DOE_BUN_WEBGPU_DEBUG_BOUNDARIES === '1')
  );
  const queueWaitSubmitCadence = queueWaitSubmitCadenceForRuntimeHost(runtimeHost);
  const queueWaitMode = queueWaitModeForRuntimeHost(runtimeHost);
  const queueWaitScope = queueWaitScopeForRuntimeHost(runtimeHost);
  const effectiveStepLimit = stepLimit || parseOptionalPositiveInt(
    process.env.DOE_NODE_WEBGPU_STEP_LIMIT
      ?? (runtimeHost === 'bun' ? process.env.DOE_BUN_WEBGPU_STEP_LIMIT : '')
      ?? '',
  );
  const debugLog = createDebugLogger(debugEnabled);
  debugLog('execute.start', {
    runtimeHost,
    provider,
    planPath,
    workloadId,
    preparedSession,
    dryRun,
    stepLimit: effectiveStepLimit,
    commandRepeat: normalizedCommandRepeat,
    residentBufferLoads,
  });
  const spec = providerSpec(provider, runtimeHost);
  const hostInputReadStartedAt = performance.now();
  const planText = await readFile(planPath, 'utf8');
  const hostInputReadTotalNs = nsDelta(hostInputReadStartedAt);
  const hostInputParseStartedAt = performance.now();
  const plan = JSON.parse(planText);
  const hostInputParseTotalNs = nsDelta(hostInputParseStartedAt);
  const hostWorkloadPrepareStartedAt = performance.now();
  let normalizedPlan = normalizePlan(plan);
  const hostWorkloadPrepareTotalNs = nsDelta(hostWorkloadPrepareStartedAt);
  debugLog('plan.normalized', {
    planBytes: planText.length,
    executionShape: normalizedPlan.executionShape,
  });
  if (effectiveStepLimit > 0) {
    normalizedPlan = applyDebugStepLimit(normalizedPlan, effectiveStepLimit);
    debugLog('plan.stepLimit.applied', {
      stepLimit: effectiveStepLimit,
      executionShape: normalizedPlan.executionShape,
    });
  }
  if (workloadId && workloadId !== normalizedPlan.workloadId) {
    throw new Error(`workload mismatch: expected ${workloadId}, got ${normalizedPlan.workloadId}`);
  }
  if (residentBufferLoads) {
    validateResidentBufferLoadPlan(normalizedPlan);
  }
  if (dryRun) {
    const executionSteps = selectedExecutionSteps(normalizedPlan.steps, residentBufferLoads);
    const shaderSourceReceipts = await collectShaderSourceReceipts(normalizedPlan);
    const meta = {
      schemaVersion: 1,
      kind: 'trace_meta',
      provider: spec.provider,
      providerName: spec.providerName,
      executionBackend: spec.executionBackend,
      executionProvider: spec.provider,
      executionProviderName: spec.providerName,
      executionErrorCount: 0,
      executionSkippedCount: 0,
      executionUnsupportedCount: 0,
      executionRowCount: executionSteps.length * normalizedCommandRepeat,
      executionSuccessCount: executionSteps.length * normalizedCommandRepeat,
      executionDispatchCount: normalizedPlan.executionShape.dispatchCount * normalizedCommandRepeat,
      executionSubmitCount: 0,
      executionTotalNs: 0,
      executionSetupTotalNs: 0,
      executionEncodeTotalNs: 0,
      executionSubmitWaitTotalNs: 0,
      ...zeroHostTotals(),
      timingMs: 0,
      elapsedMs: 0,
      processWallMs: 0,
      timingSource: 'doe-execution-total-ns',
      timingClass: 'operation',
      queueSyncMode: PACKAGE_QUEUE_SYNC_MODE,
      queueWaitMode,
      queueWaitScope,
      queueWaitSubmitCadence,
      executionQueueSyncMode: PACKAGE_QUEUE_SYNC_MODE,
      executionQueueWaitMode: queueWaitMode,
      executionQueueWaitScope: queueWaitScope,
      executionQueueWaitSubmitCadence: queueWaitSubmitCadence,
      workload: normalizedPlan.workloadId,
      canonicalWorkloadId: normalizedPlan.workloadId,
      planId: normalizedPlan.planId,
      planHash: normalizedPlan.planHash,
      planSummary: planSummary(normalizedPlan),
      executionShape: normalizedPlan.executionShape,
      ...shaderSourceReceiptFields(shaderSourceReceipts),
      packagePreparedSession: preparedSession,
      packageSetupIncludedInSelectedTiming: !preparedSession,
      packageSetupTotalNs: 0,
      packageSetupBreakdownNs: zeroPackageSetupBreakdown(),
      packageStepBreakdownNs: zeroPackageStepBreakdown(),
      packageWriteBreakdown: zeroPackageWriteBreakdown(),
      packageResidentBufferLoads: residentBufferLoads,
      packageResidentBufferLoadBreakdown: zeroPackageResidentBufferLoadBreakdown(),
      ...(preparedSession ? { workloadUnitWallSource: TRACE_META_PROCESS_WALL_SOURCE } : {}),
      samplesMs: [0],
      stats: {
        count: 1,
        min: 0,
        max: 0,
        median: 0,
        p95: 0,
        p99: 0,
        mean: 0,
        stdev: 0,
      },
    };
    meta.artifactHash = stableArtifactHash(meta);
    const rows = [];
    for (let repeatIndex = 0; repeatIndex < normalizedCommandRepeat; repeatIndex += 1) {
      for (const [index, step] of normalizedPlan.steps.entries()) {
        if (residentBufferLoads && isStaticBufferLoadStep(step)) {
          continue;
        }
        rows.push({
          schemaVersion: 1,
          kind: 'node_webgpu_step',
          stepIndex: index,
          stepId: step.id ?? `step-${index}`,
          stepKind: step.kind,
          executionBackend: spec.executionBackend,
          executionProvider: spec.provider,
          executionProviderName: spec.providerName,
          executionDurationNs: 0,
          executionSetupNs: 0,
          executionEncodeNs: 0,
          executionSubmitWaitNs: 0,
          executionSuccess: true,
          timingSource: 'doe-execution-total-ns',
          timingClass: 'operation',
          workloadId: normalizedPlan.workloadId,
          planId: normalizedPlan.planId,
          planHash: normalizedPlan.planHash,
        });
      }
    }
    await writeExecutorArtifacts(traceMetaPath, traceJsonlPath, meta, rows);
    return { meta, rows };
  }

  const executionEnvelopeStartedAt = performance.now();
  const packageExecutionPolicy = await loadPackageExecutionPolicy();
  const unsupportedEntry = lookupUnsupportedPackageExecutionEntry(
    packageExecutionPolicy,
    {
      runtimeHost,
      provider: spec.provider,
      workloadId: normalizedPlan.workloadId,
      platform: process.platform,
      arch: process.arch,
      hostname: os.hostname(),
      osRelease: os.release(),
    },
  );
  if (unsupportedEntry) {
    const unsupportedResult = buildUnsupportedExecutionResult({
      normalizedPlan,
      spec,
      preparedSession,
      hostInputReadTotalNs,
      hostInputParseTotalNs,
      hostWorkloadPrepareTotalNs,
      hostExecutorInitTotalNs: 0,
      processWallMs: performance.now() - executionEnvelopeStartedAt,
      unsupportedCode: unsupportedEntry.unsupportedCode,
      unsupportedDetail: unsupportedEntry.detail ?? '',
      queueWaitMode,
      queueWaitScope,
      queueWaitSubmitCadence,
      residentBufferLoads,
    });
    const artifactFinalizeStartedAt = performance.now();
    await writeExecutorArtifacts(traceMetaPath, traceJsonlPath, unsupportedResult.meta, unsupportedResult.rows);
    unsupportedResult.meta.hostArtifactFinalizeTotalNs = nsDelta(artifactFinalizeStartedAt);
    unsupportedResult.meta.artifactHash = stableArtifactHash(unsupportedResult.meta);
    await writeExecutorArtifacts(traceMetaPath, null, unsupportedResult.meta, unsupportedResult.rows);
    return unsupportedResult;
  }
  let runtime = null;
  let providerModuleResolveTotalNs = 0;
  try {
    const webgpuResolveStartedAt = performance.now();
    debugLog('provider.resolve.start', {
      provider: spec.provider,
    });
    const providerAvailability = await resolveProviderModuleAvailability(spec, {
      runtimeHost,
    });
    providerModuleResolveTotalNs = nsDelta(webgpuResolveStartedAt);
    if (!providerAvailability.ok) {
      debugLog('provider.resolve.failed', {
        provider: spec.provider,
        reason: providerAvailability.reason,
        detail: providerAvailability.detail,
        providerModuleResolveTotalNs,
      });
      throw makeProviderAvailabilityError(providerAvailability);
    }
    const webgpu = providerAvailability.module;
    debugLog('provider.resolve.done', {
      provider: spec.provider,
      providerModuleResolveTotalNs,
    });
    const timedEnvelopeStartedAt = performance.now();
    runtime = await createRuntime(normalizedPlan, webgpu, spec, {
      debugLog,
      runtimeHost,
      prewarmDispatchBindings: preparedSession,
    });
    runtime.hostExecutorInitTotalNs += providerModuleResolveTotalNs;
    const executionStartedAt = preparedSession ? performance.now() : timedEnvelopeStartedAt;
    const result = await executeSample(normalizedPlan, runtime, {
      includeSetupInSelectedTiming: !preparedSession,
      debugLog,
      queueWaitScope,
      queueWaitSubmitCadence,
      commandRepeat: normalizedCommandRepeat,
      residentBufferLoads,
      packageExecutionPolicy,
      runtimeHost,
    });
    const processWallMs = (performance.now() - executionStartedAt);
    const artifactFinalizeStartedAt = performance.now();
    if (traceJsonlPath) {
      debugLog('artifact.write.traceJsonl.start', {
        traceJsonlPath,
        rowCount: result.rows.length,
      });
      await writeExecutorArtifacts(null, traceJsonlPath, result.meta, result.rows);
      debugLog('artifact.write.traceJsonl.done', {
        traceJsonlPath,
        rowCount: result.rows.length,
      });
    }
    Object.assign(result.meta, boundaryScopedHostTotals({
      preparedSession,
      hostInputReadTotalNs,
      hostInputParseTotalNs,
      hostWorkloadPrepareTotalNs,
        hostExecutorInitTotalNs: runtime.hostExecutorInitTotalNs,
        hostUploadPrewarmTotalNs: result.meta.hostUploadPrewarmTotalNs,
        hostKernelPrewarmTotalNs: result.meta.hostKernelPrewarmTotalNs,
      hostCommandOrchestrationTotalNs: result.meta.hostCommandOrchestrationTotalNs,
      hostArtifactFinalizeTotalNs: nsDelta(artifactFinalizeStartedAt),
    }));
    result.meta.elapsedMs = processWallMs;
    result.meta.processWallMs = processWallMs;
    if (preparedSession) {
      result.meta.workloadUnitWallSource = TRACE_META_PROCESS_WALL_SOURCE;
    }
    result.meta.artifactHash = stableArtifactHash(result.meta);
    debugLog('artifact.write.traceMeta.start', {
      traceMetaPath,
      rowCount: result.rows.length,
    });
    await writeExecutorArtifacts(traceMetaPath, null, result.meta, result.rows);
    debugLog('artifact.write.traceMeta.done', {
      traceMetaPath,
      rowCount: result.rows.length,
    });

    return result;
  } catch (error) {
    if (isUnsupportedNodeWebGpuError(error)) {
      const providerFailureReason = normalizeProviderFailureReason(
        error.providerFailureReason ?? error.providerAvailability?.reason,
      );
      debugLog('runtime.unsupported', {
        unsupportedCode: error.unsupportedCode,
        providerFailureReason,
        detail: error.unsupportedDetail ?? '',
      });
      const unsupportedResult = buildUnsupportedExecutionResult({
        normalizedPlan,
        spec,
        preparedSession,
        hostInputReadTotalNs,
        hostInputParseTotalNs,
        hostWorkloadPrepareTotalNs,
        hostExecutorInitTotalNs: providerModuleResolveTotalNs + (error.hostExecutorInitTotalNs ?? 0),
        processWallMs: performance.now() - executionEnvelopeStartedAt,
        unsupportedCode: error.unsupportedCode ?? '',
        unsupportedDetail: error.unsupportedDetail ?? '',
        providerFailureReason,
        evidenceBlockerCode: providerFailureReason,
        queueWaitMode,
        queueWaitScope,
        queueWaitSubmitCadence,
        residentBufferLoads,
      });
      const artifactFinalizeStartedAt = performance.now();
      await writeExecutorArtifacts(traceMetaPath, traceJsonlPath, unsupportedResult.meta, unsupportedResult.rows);
      unsupportedResult.meta.hostArtifactFinalizeTotalNs = nsDelta(artifactFinalizeStartedAt);
      unsupportedResult.meta.artifactHash = stableArtifactHash(unsupportedResult.meta);
      await writeExecutorArtifacts(traceMetaPath, null, unsupportedResult.meta, unsupportedResult.rows);
      return unsupportedResult;
    }
    const errorResult = buildErrorExecutionResult({
      normalizedPlan,
      spec,
      preparedSession,
      hostInputReadTotalNs,
      hostInputParseTotalNs,
      hostWorkloadPrepareTotalNs,
      hostExecutorInitTotalNs: providerModuleResolveTotalNs + (runtime?.hostExecutorInitTotalNs ?? 0),
      processWallMs: performance.now() - executionEnvelopeStartedAt,
      providerFailureReason: normalizeProviderFailureReason(
        error.providerFailureReason ?? error.providerAvailability?.reason,
      ),
      evidenceBlockerCode: normalizeProviderFailureReason(
        error.providerFailureReason ?? error.providerAvailability?.reason,
      ),
      queueWaitMode,
      queueWaitScope,
      queueWaitSubmitCadence,
      residentBufferLoads,
    });
    const artifactFinalizeStartedAt = performance.now();
    await writeExecutorArtifacts(traceMetaPath, traceJsonlPath, errorResult.meta, errorResult.rows);
    errorResult.meta.hostArtifactFinalizeTotalNs = nsDelta(artifactFinalizeStartedAt);
    errorResult.meta.artifactHash = stableArtifactHash(errorResult.meta);
    await writeExecutorArtifacts(traceMetaPath, null, errorResult.meta, errorResult.rows);
    throw error;
  } finally {
    debugLog('runtime.destroy.start', {
      provider: spec.provider,
    });
    debugLog('runtime.destroy.done', {
      provider: spec.provider,
    });
  }
}

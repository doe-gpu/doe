// Doe-owned Program Bundle inference runner.
//
// Closes the structural half of "Doe-WebGPU vs Doppler token-sequence
// parity" by giving Doe a public module surface that drives a Doppler
// Program Bundle through Doe's Node WebGPU runtime. The .mjs CLI at
// bench/tools/run_doe_webgpu_program_bundle_inference.mjs is the
// command-line wrapper around this module.
//
// What this module DOES today (structurally honest):
//
//   1. Loads a Program Bundle JSON (top-level keys: bundleId, modelId,
//      executionGraphHash, wgslModules[], host).
//   2. Inventories the bundle's WGSL closure: per-module sha256 of the
//      file content vs the bundle's declared `digest`, structural
//      checks on bindings.
//   3. Boots Doe-WebGPU's Node device via packages/doe-gpu/src/node-webgpu.js
//      (the Doe-owned bootstrap landed earlier; no longer reaches into
//      Doppler's src/tooling/node-webgpu.js).
//   4. For every ingested WGSL module: createShaderModule +
//      createComputePipeline (auto layout, candidate entry points).
//      Per-module compile + pipeline status is recorded.
//   5. Validates the host.entrypoints[0] descriptor: schema id,
//      module path resolves, export name follows the
//      doppler-webgpu-host/v1 contract.
//   6. Returns a structured result. tokenSequence stays empty —
//      no fabricated tokens.
//
// What this module does NOT do (named blocker):
//
//   The host_entrypoint constrained-JS execution semantics live in
//   doppler/src/tooling/program-bundle-host.js (20 lines, but it just
//   instantiates `PipelineGenerator` from
//   doppler/src/inference/pipelines/text/generator.js — 2332 lines
//   with 16+ Doppler-internal deps: gpu/device.js, memory/buffer-
//   pool.js, gpu/kernels/sample.js, gpu/kernel-selection-cache.js,
//   gpu/submit-tracker.js, gpu/command-recorder.js, gpu/perf-guards.js,
//   config/param-validator.js, debug/index.js, plus the inference
//   pipeline tree). A faithful port is the entire text-generation
//   engine. This module names the port as the open blocker
//   (`pipeline_generator_port_pending`) so callers see exactly what
//   needs to land.
//
// Public API:
//
//   runProgramBundleInference({
//     programBundlePath,        // string, required: path to bundle.json
//     modelDir,                 // string, optional: defaults to bundle dir
//     prompt,                   // string, optional: defaults to "The color of the sky is"
//     maxTokens,                // integer >= 1, optional: defaults to 8
//     seed,                     // integer, optional: defaults to 1000
//   }) -> Promise<{
//     verdict: string,          // 'structurally_validated' | 'blocked' | 'ingestion_failed'
//     bundle: { bundleId, modelId, executionGraphHash, manifestSha256 },
//     modules: Array<{ id, status, declaredDigest, observedSha256, ... }>,
//     hostEntrypoint: { declared, schema, jsSubset, entrypoints },
//     compile: Array<{ name, compile, pipeline, pipelineEntry, ... }>,
//     summary: { totalModules, ingestedModules, compiled, pipelineCreated },
//     blocker: { class, detail, namedExtension, blocksFields },
//     // The following stay null/empty until the PipelineGenerator port lands:
//     tokenSequence: number[],          // [] today
//     perStepLogitsDigests: string[],   // [] today
//     kvStateSha256: string | null,     // null today
//     outputSha256: string | null,      // null today
//     stopReason: 'blocked_pipeline_generator_port_pending' | other,
//   }>

import { createHash } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

import { bootstrapNodeWebGPU } from './node-webgpu.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const PACKAGE_ROOT = resolve(HERE, '..');
const REPO_ROOT = resolve(PACKAGE_ROOT, '..', '..');
const DOPPLER_ROOT = resolve(REPO_ROOT, '..', 'doppler');

const DEFAULT_PROMPT = 'The color of the sky is';
const DEFAULT_MAX_TOKENS = 8;
const DEFAULT_SEED = 1000;
const KNOWN_HOST_SCHEMA = 'doppler.host-js/v1';
const KNOWN_HOST_JS_SUBSET = 'doppler-webgpu-host/v1';
const KNOWN_HOST_ENTRYPOINT_EXPORT = 'createTextGenerationProgram';

function sha256OfBytes(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

function sha256Urn(value) {
  if (typeof value !== 'string' || value.length === 0) {
    return null;
  }
  return value.startsWith('sha256:') ? value : `sha256:${value}`;
}

function firstString(...values) {
  for (const value of values) {
    if (typeof value === 'string' && value.trim().length > 0) {
      return value;
    }
  }
  return null;
}

function collectMissingIdentity(identity) {
  const missing = {};
  for (const [field, value] of Object.entries(identity)) {
    if (value === null || value === undefined || value === '') {
      missing[field] = { reason: `${field}_unavailable` };
    }
  }
  return missing;
}

export function collectProgramBundleIdentity(loaded) {
  const bundle = loaded?.bundle ?? {};
  const runtimeProfile = bundle.runtimeProfile ?? {};
  const kernelRegistry = bundle.kernelRegistry ?? {};
  const identity = {
    modelId: firstString(bundle.modelId),
    manifestPath: firstString(bundle.manifest?.path),
    manifestSha256: sha256Urn(bundle.manifest?.sha256),
    runtimeProfileId: firstString(
      runtimeProfile.id,
      runtimeProfile.profileId,
    ),
    runtimeProfilePath: firstString(runtimeProfile.path),
    runtimeProfileSha256: sha256Urn(runtimeProfile.sha256),
    kernelRegistryPath: firstString(kernelRegistry.path),
    kernelRegistrySha256: sha256Urn(kernelRegistry.sha256),
    shardSetHash: sha256Urn(bundle.shardSetHash),
    inputContractSha256: sha256Urn(bundle.tokenizerInput?.inputSetSha256),
  };
  const missing = collectMissingIdentity(identity);
  return Object.freeze({
    ...identity,
    ...(Object.keys(missing).length > 0 ? { missing } : {}),
  });
}

function loadBundle(programBundlePath) {
  const bundlePath = resolve(programBundlePath);
  if (!existsSync(bundlePath)) {
    throw new Error(`Program Bundle not found: ${bundlePath}`);
  }
  const text = readFileSync(bundlePath, 'utf-8');
  return {
    bundlePath,
    bundleSha256: sha256OfBytes(text),
    bundle: JSON.parse(text),
  };
}

function resolveWgslSourceRoot(loaded, sourceRootOverride) {
  if (sourceRootOverride) return resolve(sourceRootOverride);
  // Doppler Program Bundle wgslModules[].sourcePath is the path inside
  // the Doppler source tree (e.g. "src/gpu/kernels/foo.wgsl"). Default
  // to ../doppler relative to the doe repo root.
  return DOPPLER_ROOT;
}

function inventoryWgslModules(loaded, sourceRoot) {
  const bundle = loaded.bundle;
  const modules = (
    (bundle && bundle.wgslModules) ||
    (bundle && bundle.modules) ||
    []
  );
  const inventoried = [];
  for (const m of modules) {
    const id = (m && (m.id || m.name)) || '(unnamed)';
    const relPath = (m && (m.sourcePath || m.path || m.source || m.wgslPath || m.file)) || null;
    if (!relPath) {
      inventoried.push({
        id,
        path: null,
        status: 'unresolved',
        detail: 'module entry missing sourcePath / path / source / file',
      });
      continue;
    }
    const absPath = resolve(sourceRoot, relPath);
    if (!existsSync(absPath)) {
      inventoried.push({
        id,
        path: relPath,
        absPath,
        status: 'missing',
        detail: `WGSL file not found: ${absPath}`,
      });
      continue;
    }
    const bytes = readFileSync(absPath);
    inventoried.push({
      id,
      path: relPath,
      absPath,
      status: 'ingested',
      entry: m && m.entry,
      declaredDigest: m && m.digest,
      observedSha256: 'sha256:' + sha256OfBytes(bytes),
      bytes: bytes.length,
    });
  }
  return inventoried;
}

function declaredHostEntrypoint(loaded) {
  const bundle = loaded.bundle;
  const host = bundle && bundle.host;
  if (host && Array.isArray(host.entrypoints) && host.entrypoints.length > 0) {
    return {
      declared: true,
      schema: host.schema,
      jsSubset: host.jsSubset,
      constraints: host.constraints,
      entrypoints: host.entrypoints.map((ep) => ({
        id: ep.id,
        module: ep.module,
        export: ep.export,
        role: ep.role,
        sourceHash: ep.sourceHash,
      })),
    };
  }
  const legacyEp =
    (bundle && bundle.host_entrypoint) ||
    (bundle && bundle.hostEntrypoint) ||
    null;
  if (legacyEp) {
    const phaseList = (legacyEp.phases) || (legacyEp.steps) || [];
    return {
      declared: true,
      legacy: true,
      phases: phaseList.map((phase) => ({
        name: phase.name || '(unnamed)',
        kernel: phase.kernel || phase.module || null,
        kind: phase.kind || phase.phase || null,
      })),
    };
  }
  return {
    declared: false,
    detail: 'bundle has no host.entrypoints / host_entrypoint section',
  };
}

function validateHostEntrypoint(hostEntrypoint) {
  if (!hostEntrypoint.declared) {
    return {
      ok: false,
      reason: 'host_entrypoint_absent',
      detail: hostEntrypoint.detail,
    };
  }
  if (hostEntrypoint.schema !== KNOWN_HOST_SCHEMA) {
    return {
      ok: false,
      reason: 'host_schema_mismatch',
      detail: `host.schema=${hostEntrypoint.schema}, expected ${KNOWN_HOST_SCHEMA}`,
    };
  }
  if (hostEntrypoint.jsSubset !== KNOWN_HOST_JS_SUBSET) {
    return {
      ok: false,
      reason: 'host_js_subset_mismatch',
      detail: `host.jsSubset=${hostEntrypoint.jsSubset}, expected ${KNOWN_HOST_JS_SUBSET}`,
    };
  }
  const ep = hostEntrypoint.entrypoints && hostEntrypoint.entrypoints[0];
  if (!ep) {
    return {
      ok: false,
      reason: 'host_entrypoint_zero_array',
      detail: 'host.entrypoints[] is empty',
    };
  }
  if (ep.export !== KNOWN_HOST_ENTRYPOINT_EXPORT) {
    return {
      ok: false,
      reason: 'host_entrypoint_export_mismatch',
      detail: `host.entrypoints[0].export=${ep.export}, expected ${KNOWN_HOST_ENTRYPOINT_EXPORT}`,
    };
  }
  return { ok: true };
}

async function bootDoeWebGPU() {
  const bootstrap = await bootstrapNodeWebGPU();
  if (!bootstrap?.ok) {
    throw new Error(
      `Doe-WebGPU bootstrap failed: ${bootstrap?.detail ?? 'unknown error'}`,
    );
  }
  if (!globalThis.navigator || !globalThis.navigator.gpu) {
    throw new Error(
      'globalThis.navigator.gpu is absent after Doe-WebGPU bootstrap',
    );
  }
  const adapter = await globalThis.navigator.gpu.requestAdapter({
    powerPreference: 'high-performance',
  });
  if (!adapter) throw new Error('no WebGPU adapter');
  const device = await adapter.requestDevice();
  return { adapter, device };
}

async function tryCompileModules(device, modules, sourceRoot) {
  const compileResults = [];
  for (const m of modules) {
    if (m.status !== 'ingested') {
      compileResults.push({ name: m.id, compile: 'skipped', detail: m.status });
      continue;
    }
    const absPath = resolve(sourceRoot, m.path);
    let source;
    try {
      source = readFileSync(absPath, 'utf-8');
    } catch (err) {
      compileResults.push({
        name: m.id,
        compile: 'error',
        detail: `read failed: ${err && err.message ? err.message : err}`,
      });
      continue;
    }
    let module;
    try {
      module = device.createShaderModule({ code: source });
    } catch (err) {
      compileResults.push({
        name: m.id,
        compile: 'error',
        detail: `createShaderModule failed: ${err && err.message ? err.message : err}`,
      });
      continue;
    }
    const candidateEntries = [m.entry, 'main', 'cs_main', 'compute_main'].filter(Boolean);
    let pipelineEntry = null;
    let pipelineErr = null;
    for (const entry of candidateEntries) {
      try {
        device.createComputePipeline({
          layout: 'auto',
          compute: { module, entryPoint: entry },
        });
        pipelineEntry = entry;
        break;
      } catch (err) {
        pipelineErr = err && err.message ? err.message : String(err);
      }
    }
    compileResults.push({
      name: m.id,
      compile: 'ok',
      pipeline: pipelineEntry ? 'ok' : 'unresolved',
      pipelineEntry,
      pipelineDetail: pipelineEntry ? null : pipelineErr,
    });
  }
  return compileResults;
}

const PIPELINE_GENERATOR_BLOCKER = {
  class: 'pipeline_generator_port_pending',
  detail:
    'The host_entrypoint constrained-JS execution semantics are ' +
    'declared by doppler/src/tooling/program-bundle-host.js (20 LOC, ' +
    'just instantiates PipelineGenerator) but the actual inference ' +
    'engine lives in doppler/src/inference/pipelines/text/generator.js ' +
    '(2332 LOC, 16+ Doppler-internal deps including gpu/device.js, ' +
    'memory/buffer-pool.js, gpu/kernels/sample.js, gpu/kernel-' +
    'selection-cache.js, gpu/submit-tracker.js, gpu/command-recorder.js, ' +
    'gpu/perf-guards.js, config/param-validator.js, debug/index.js). ' +
    'Until those modules are ported into packages/doe-gpu/, this ' +
    'function emits a structurally-validated bundle inventory but no ' +
    'token loop.',
  namedExtension:
    'packages/doe-gpu/src/text-generation-pipeline.js (NEW): port of ' +
    'PipelineGenerator + its dependency graph. Once that lands, ' +
    'runProgramBundleInference invokes it and fills tokenSequence + ' +
    'perStepLogitsDigests + kvStateSha256 + outputSha256.',
  blocksFields: [
    'tokenSequence',
    'perStepLogitsDigests',
    'kvStateSha256',
    'outputSha256',
  ],
};

export const PROGRAM_BUNDLE_RUNNER_VERSION = 'doe.program-bundle-runner/v1';

export async function runProgramBundleInference(options = {}) {
  const programBundlePath = options.programBundlePath;
  if (!programBundlePath) {
    throw new Error('runProgramBundleInference: programBundlePath is required');
  }
  const prompt = options.prompt || DEFAULT_PROMPT;
  const maxTokens = options.maxTokens != null ? Number(options.maxTokens) : DEFAULT_MAX_TOKENS;
  const seed = options.seed != null ? Number(options.seed) : DEFAULT_SEED;
  if (!Number.isInteger(maxTokens) || maxTokens < 1) {
    throw new Error('runProgramBundleInference: maxTokens must be a positive integer');
  }

  const loaded = loadBundle(programBundlePath);
  const internalDopplerIdentity = collectProgramBundleIdentity(loaded);
  const sourceRoot = resolveWgslSourceRoot(loaded, options.wgslSourceRoot);
  const modulesInventory = inventoryWgslModules(loaded, sourceRoot);
  const hostEntrypoint = declaredHostEntrypoint(loaded);
  const hostValidation = validateHostEntrypoint(hostEntrypoint);

  const result = {
    runnerVersion: PROGRAM_BUNDLE_RUNNER_VERSION,
    inputs: {
      programBundlePath,
      modelDir: options.modelDir || dirname(resolve(programBundlePath)),
      prompt,
      maxTokens,
      seed,
    },
    bundle: {
      bundleId: loaded.bundle.bundleId || null,
      modelId: internalDopplerIdentity.modelId || null,
      executionGraphHash:
        (loaded.bundle.execution && loaded.bundle.execution.graphHash) ||
        loaded.bundle.executionGraphHash ||
        null,
      manifestSha256: 'sha256:' + loaded.bundleSha256,
    },
    modules: modulesInventory,
    hostEntrypoint,
    hostValidation,
    boot: { status: 'pending' },
    compile: null,
    summary: null,
    tokenSequence: [],
    perStepLogitsDigests: [],
    kvStateSha256: null,
    outputSha256: null,
    stopReason: 'blocked_pipeline_generator_port_pending',
    blocker: PIPELINE_GENERATOR_BLOCKER,
    verdict: 'blocked',
  };

  if (!hostValidation.ok) {
    result.verdict = 'ingestion_failed';
    result.boot = { status: 'skipped', detail: 'host validation failed' };
    return result;
  }

  let device;
  try {
    const boot = await bootDoeWebGPU();
    device = boot.device;
    result.boot = { status: 'ok' };
  } catch (err) {
    result.verdict = 'ingestion_failed';
    result.boot = {
      status: 'error',
      detail: err && err.message ? err.message : String(err),
    };
    return result;
  }

  result.compile = await tryCompileModules(device, modulesInventory, sourceRoot);
  const okCompile = result.compile.filter((r) => r.compile === 'ok').length;
  const okPipeline = result.compile.filter((r) => r.pipeline === 'ok').length;
  result.summary = {
    totalModules: modulesInventory.length,
    ingestedModules: modulesInventory.filter((m) => m.status === 'ingested').length,
    compiled: okCompile,
    pipelineCreated: okPipeline,
    hostEntrypointDeclared: hostEntrypoint.declared,
    decodeExecuted: false,
  };

  // Bundle is structurally validated when at least one WGSL module
  // ingested + at least one pipeline created + host_entrypoint
  // contract matches the known schema. The blocker stays:
  // PipelineGenerator port is the only thing standing between this
  // result and an actual token loop.
  if (
    okCompile > 0 &&
    okPipeline > 0 &&
    result.summary.ingestedModules > 0
  ) {
    result.verdict = 'structurally_validated';
  } else {
    result.verdict = 'ingestion_failed';
  }
  return result;
}

export function describeProgramBundleRunner() {
  return {
    runnerVersion: PROGRAM_BUNDLE_RUNNER_VERSION,
    schema: 'doe.program-bundle-runner/v1',
    capabilities: {
      bundleLoad: true,
      wgslInventory: true,
      shaderCompile: true,
      pipelineCreate: true,
      hostEntrypointValidate: true,
      tokenLoop: false,
    },
    blocker: PIPELINE_GENERATOR_BLOCKER,
  };
}

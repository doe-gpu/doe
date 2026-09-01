#!/usr/bin/env node

import { createHash } from 'node:crypto';
import {
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const SCRIPT_PATH = fileURLToPath(import.meta.url);
const REPO_ROOT = path.resolve(path.dirname(SCRIPT_PATH), '..', '..');
const DEFAULT_DOPPLER_ROOT = '/home/x/deco/doppler';
const DEFAULT_MODEL_DIR =
  '/home/x/deco/doppler/models/local/gemma-4-e2b-it-q4k-ehf16-af32-int4ple';
const DEFAULT_PROMPT =
  'What color is the sky on a clear day? Answer in one word.';
const DEFAULT_RUNTIME_PROFILE = 'profiles/production';
const DEFAULT_OUT_DIR =
  'bench/out/doppler-reference/gemma-4-e2b-int4ple-production-final-logits';
const DEFAULT_ATOL = 1e-3;
const DEFAULT_RTOL = 0;
const DEFAULT_DECODE_STEPS = 8;
const DEFAULT_TEMPERATURE = 0;
const DEFAULT_TOP_K = 1;
const DEFAULT_TOP_P = 1;
const DEFAULT_REPETITION_PENALTY = 1.0;
const DEFAULT_KERNEL_PATH_POLICY_MODE = 'capability-aware';
const DEFAULT_KERNEL_PATH_POLICY_ON_INCOMPATIBLE = 'remap';
const DEFAULT_KERNEL_PATH_POLICY_SOURCE_SCOPE = Object.freeze([
  'model',
  'manifest',
  'config',
]);
const PREVIEW_LIMIT = 8;

function stableValue(value) {
  if (Array.isArray(value)) {
    return value.map((item) => stableValue(item));
  }
  if (value && typeof value === 'object') {
    const sorted = {};
    for (const key of Object.keys(value).sort()) {
      if (value[key] !== undefined) {
        sorted[key] = stableValue(value[key]);
      }
    }
    return sorted;
  }
  return value;
}

function stableStringify(value) {
  return `${JSON.stringify(stableValue(value), null, 2)}\n`;
}

function sha256Bytes(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

function sha256File(filePath) {
  return sha256Bytes(readFileSync(filePath));
}

function sha256Json(value) {
  return sha256Bytes(Buffer.from(stableStringify(value), 'utf8'));
}

function writeJson(filePath, value) {
  writeFileSync(filePath, stableStringify(value), 'utf8');
}

function repoRelative(filePath) {
  const absolute = path.resolve(filePath);
  const relative = path.relative(REPO_ROOT, absolute);
  if (relative.startsWith('..') || path.isAbsolute(relative)) {
    return absolute;
  }
  return relative.split(path.sep).join('/');
}

function parseNumber(value, label) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < 0) {
    throw new Error(`${label} must be a non-negative finite number.`);
  }
  return parsed;
}

function parseNonNegativeInteger(value, label) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 0) {
    throw new Error(`${label} must be a non-negative integer.`);
  }
  return parsed;
}

function parsePositiveInteger(value, label) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1) {
    throw new Error(`${label} must be a positive integer.`);
  }
  return parsed;
}

function parseProbability(value, label) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0 || parsed > 1) {
    throw new Error(`${label} must be a finite number in (0, 1].`);
  }
  return parsed;
}

function parseCommaSeparatedStrings(value, label) {
  const entries = String(value)
    .split(',')
    .map((entry) => entry.trim())
    .filter(Boolean);
  if (entries.length === 0) {
    throw new Error(`${label} must include at least one value.`);
  }
  return entries;
}

function isPlainObject(value) {
  return value != null && typeof value === 'object' && !Array.isArray(value);
}

function mergePlainObjects(base, patch) {
  const output = { ...(isPlainObject(base) ? base : {}) };
  for (const [key, value] of Object.entries(patch)) {
    if (isPlainObject(value) && isPlainObject(output[key])) {
      output[key] = mergePlainObjects(output[key], value);
    } else {
      output[key] = value;
    }
  }
  return output;
}

function parseArgs(argv) {
  const parsed = {
    dopplerRoot: DEFAULT_DOPPLER_ROOT,
    modelDir: DEFAULT_MODEL_DIR,
    modelId: null,
    prompt: DEFAULT_PROMPT,
    runtimeProfile: DEFAULT_RUNTIME_PROFILE,
    outDir: DEFAULT_OUT_DIR,
    useChatTemplate: true,
    atol: DEFAULT_ATOL,
    rtol: DEFAULT_RTOL,
    decodeSteps: DEFAULT_DECODE_STEPS,
    temperature: DEFAULT_TEMPERATURE,
    topK: DEFAULT_TOP_K,
    topP: DEFAULT_TOP_P,
    repetitionPenalty: DEFAULT_REPETITION_PENALTY,
    seed: null,
    kernelPathPolicyMode: DEFAULT_KERNEL_PATH_POLICY_MODE,
    kernelPathPolicyOnIncompatible: DEFAULT_KERNEL_PATH_POLICY_ON_INCOMPATIBLE,
    kernelPathPolicySourceScope: [...DEFAULT_KERNEL_PATH_POLICY_SOURCE_SCOPE],
    help: false,
  };

  for (let index = 2; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--help' || arg === '-h') {
      parsed.help = true;
      continue;
    }
    if (arg === '--doppler-root') {
      parsed.dopplerRoot = requireValue(argv, index, arg);
      index += 1;
      continue;
    }
    if (arg === '--model-dir') {
      parsed.modelDir = requireValue(argv, index, arg);
      index += 1;
      continue;
    }
    if (arg === '--model-id') {
      parsed.modelId = requireValue(argv, index, arg);
      index += 1;
      continue;
    }
    if (arg === '--prompt') {
      parsed.prompt = requireValue(argv, index, arg);
      index += 1;
      continue;
    }
    if (arg === '--runtime-profile') {
      parsed.runtimeProfile = requireValue(argv, index, arg);
      index += 1;
      continue;
    }
    if (arg === '--out-dir') {
      parsed.outDir = requireValue(argv, index, arg);
      index += 1;
      continue;
    }
    if (arg === '--atol') {
      parsed.atol = parseNumber(requireValue(argv, index, arg), arg);
      index += 1;
      continue;
    }
    if (arg === '--rtol') {
      parsed.rtol = parseNumber(requireValue(argv, index, arg), arg);
      index += 1;
      continue;
    }
    if (arg === '--decode-steps') {
      parsed.decodeSteps = parseNonNegativeInteger(
        requireValue(argv, index, arg),
        arg
      );
      index += 1;
      continue;
    }
    if (arg === '--temperature') {
      parsed.temperature = parseNumber(requireValue(argv, index, arg), arg);
      index += 1;
      continue;
    }
    if (arg === '--top-k') {
      parsed.topK = parsePositiveInteger(requireValue(argv, index, arg), arg);
      index += 1;
      continue;
    }
    if (arg === '--top-p') {
      parsed.topP = parseProbability(requireValue(argv, index, arg), arg);
      index += 1;
      continue;
    }
    if (arg === '--repetition-penalty') {
      parsed.repetitionPenalty = parseNumber(requireValue(argv, index, arg), arg);
      index += 1;
      continue;
    }
    if (arg === '--seed') {
      parsed.seed = parseNonNegativeInteger(requireValue(argv, index, arg), arg);
      index += 1;
      continue;
    }
    if (arg === '--kernel-path-policy-mode') {
      parsed.kernelPathPolicyMode = requireValue(argv, index, arg);
      if (
        parsed.kernelPathPolicyMode !== 'locked'
        && parsed.kernelPathPolicyMode !== 'capability-aware'
      ) {
        throw new Error(`${arg} must be "locked" or "capability-aware".`);
      }
      index += 1;
      continue;
    }
    if (arg === '--kernel-path-policy-on-incompatible') {
      parsed.kernelPathPolicyOnIncompatible = requireValue(argv, index, arg);
      if (
        parsed.kernelPathPolicyOnIncompatible !== 'error'
        && parsed.kernelPathPolicyOnIncompatible !== 'remap'
      ) {
        throw new Error(`${arg} must be "error" or "remap".`);
      }
      index += 1;
      continue;
    }
    if (arg === '--kernel-path-policy-source-scope') {
      parsed.kernelPathPolicySourceScope = parseCommaSeparatedStrings(
        requireValue(argv, index, arg),
        arg
      );
      index += 1;
      continue;
    }
    if (arg === '--no-chat-template') {
      parsed.useChatTemplate = false;
      continue;
    }
    throw new Error(`Unknown argument "${arg}".`);
  }

  return parsed;
}

function requireValue(argv, index, flag) {
  const value = argv[index + 1];
  if (value === undefined || value === '') {
    throw new Error(`${flag} requires a value.`);
  }
  return value;
}

function printHelp() {
  console.log(
    [
      'Usage: <node|bun> bench/tools/export_doppler_int4ple_reference.mjs [options]',
      '',
      'Exports one production Doppler INT4 PLE RDRR WebGPU tensor:',
      'final_logits.f32 plus doppler_int4ple_reference_export.json.',
      '',
      'Options:',
      `  --doppler-root <path>     Doppler checkout (default: ${DEFAULT_DOPPLER_ROOT})`,
      `  --model-dir <path>        Local INT4 PLE RDRR artifact (default: ${DEFAULT_MODEL_DIR})`,
      '  --model-id <id>           Override modelId passed to Doppler',
      '  --prompt <text>           Fixed prompt for prefill logits',
      `  --runtime-profile <id>    Doppler runtime profile (default: ${DEFAULT_RUNTIME_PROFILE})`,
      `  --out-dir <path>          Output directory (default: ${DEFAULT_OUT_DIR})`,
      `  --atol <value>            Promotion max-abs tolerance (default: ${DEFAULT_ATOL})`,
      `  --rtol <value>            Promotion relative tolerance (default: ${DEFAULT_RTOL})`,
      `  --decode-steps <count>    Greedy transcript steps (default: ${DEFAULT_DECODE_STEPS})`,
      `  --temperature <value>     Sampling temperature (default: ${DEFAULT_TEMPERATURE})`,
      `  --top-k <count>           Sampling top-k (default: ${DEFAULT_TOP_K})`,
      `  --top-p <value>           Sampling top-p (default: ${DEFAULT_TOP_P})`,
      `  --repetition-penalty <x>  Decode sampling penalty (default: ${DEFAULT_REPETITION_PENALTY})`,
      '  --seed <value>            Optional deterministic sampling seed',
      `  --kernel-path-policy-mode <mode>  Execution kernel policy mode (default: ${DEFAULT_KERNEL_PATH_POLICY_MODE})`,
      `  --kernel-path-policy-on-incompatible <mode>  Incompatible kernel action (default: ${DEFAULT_KERNEL_PATH_POLICY_ON_INCOMPATIBLE})`,
      `  --kernel-path-policy-source-scope <csv>  Allowed kernel policy sources (default: ${DEFAULT_KERNEL_PATH_POLICY_SOURCE_SCOPE.join(',')})`,
      '  --no-chat-template        Disable Doppler chat-template expansion',
      '  --help, -h                Show this help',
    ].join('\n')
  );
}

async function importDopplerModule(dopplerRoot, relPath) {
  const modulePath = path.join(dopplerRoot, relPath);
  return import(pathToFileURL(modulePath).href);
}

async function loadDopplerModules(dopplerRoot) {
  const [
    runtime,
    testHarness,
    runtimeHelpers,
    nodeFileFetch,
    nodeWebgpu,
    sampling,
    bufferPool,
    harnessText,
    tooling,
  ] = await Promise.all([
    importDopplerModule(dopplerRoot, 'src/config/runtime.js'),
    importDopplerModule(dopplerRoot, 'src/inference/test-harness.js'),
    importDopplerModule(
      dopplerRoot,
      'src/inference/browser-harness-runtime-helpers.js'
    ),
    importDopplerModule(dopplerRoot, 'src/tooling/node-file-fetch.js'),
    importDopplerModule(dopplerRoot, 'src/tooling/node-webgpu.js'),
    importDopplerModule(dopplerRoot, 'src/inference/pipelines/text/sampling.js'),
    importDopplerModule(dopplerRoot, 'src/memory/buffer-pool.js'),
    importDopplerModule(
      dopplerRoot,
      'src/inference/browser-harness-text-helpers.js'
    ),
    importDopplerModule(dopplerRoot, 'src/tooling-exports.shared.js'),
  ]);
  return {
    getRuntimeConfig: runtime.getRuntimeConfig,
    setRuntimeConfig: runtime.setRuntimeConfig,
    initializeInference: testHarness.initializeInference,
    applyRuntimeProfile: runtimeHelpers.applyRuntimeProfile,
    installNodeFileFetchShim: nodeFileFetch.installNodeFileFetchShim,
    bootstrapNodeWebGPU: nodeWebgpu.bootstrapNodeWebGPU,
    applyRepetitionPenalty: sampling.applyRepetitionPenalty,
    sample: sampling.sample,
    releaseBuffer: bufferPool.releaseBuffer,
    captureKvCacheByteProof: harnessText.captureKvCacheByteProof,
    buildModelCheckpointEvidence: tooling.buildModelCheckpointEvidence,
    flattenModelCheckpointDigests: tooling.flattenModelCheckpointDigests,
  };
}

function cloneValue(value) {
  if (typeof structuredClone === 'function') {
    return structuredClone(value);
  }
  return JSON.parse(JSON.stringify(value));
}

function buildRuntimeConfig(baseRuntimeConfig, args) {
  return mergePlainObjects(cloneValue(baseRuntimeConfig), {
    inference: {
      kernelPathPolicy: {
        mode: args.kernelPathPolicyMode,
        sourceScope: [...args.kernelPathPolicySourceScope],
        allowSources: [...args.kernelPathPolicySourceScope],
        onIncompatible: args.kernelPathPolicyOnIncompatible,
      },
    },
    shared: {
      harness: {
        referenceTranscript: {
          enabled: true,
          captureLogits: true,
          captureKvBytes: true,
        },
      },
    },
  });
}

const zeroDigestCache = new Map();

function normalizeDigest(value) {
  const text = String(value ?? '');
  return text.startsWith('sha256:') ? text.slice('sha256:'.length) : text;
}

function zeroDigest(byteLength) {
  const size = Number(byteLength);
  if (!Number.isInteger(size) || size < 1) return null;
  if (!zeroDigestCache.has(size)) {
    zeroDigestCache.set(size, sha256Bytes(Buffer.alloc(size)));
  }
  return zeroDigestCache.get(size);
}

function digestProvesNonZero(digest, byteLength) {
  const normalized = normalizeDigest(digest);
  const zero = zeroDigest(byteLength);
  return normalized.length > 0 && normalized !== 'pending' && zero !== null && normalized !== zero;
}

function kvProofHasNonZeroBytes(layers) {
  return layers.some((layer) => (
    digestProvesNonZero(layer?.keyDigest, layer?.keyBytes)
    || digestProvesNonZero(layer?.valueDigest, layer?.valueBytes)
  ));
}

function buildKvCacheEvidence(proof) {
  if (!proof || typeof proof !== 'object') {
    return {
      status: 'not_captured',
      realKvCache: false,
      blocker: 'Doppler WebGPU exporter did not return KV/cache byte proof.',
    };
  }
  const layers = Array.isArray(proof.layers) ? proof.layers : [];
  const seqLen = layers.reduce((max, layer) => {
    const value = Number(layer?.seqLen);
    return Number.isFinite(value) ? Math.max(max, Math.floor(value)) : max;
  }, 0);
  const hasNonZeroBytes = kvProofHasNonZeroBytes(layers);
  return {
    status: hasNonZeroBytes ? 'output_ready' : 'not_captured',
    realKvCache: hasNonZeroBytes,
    blocker: hasNonZeroBytes
      ? ''
      : 'KV/cache byte proof contains only zero key/value buffers; cache writes were not proven.',
    mode: proof.mode ?? 'sha256-layer-kv-bytes',
    layout: proof.layout ?? null,
    kvDtype: proof.kvDtype ?? null,
    byteDigest: proof.digest ?? 'pending',
    layerDigestCount: layers.length,
    seqLen,
    byteDigests: layers,
  };
}

function loadManifest(modelDir) {
  const manifestPath = path.join(modelDir, 'manifest.json');
  if (!existsSync(manifestPath)) {
    throw new Error(`Doppler manifest not found: ${manifestPath}`);
  }
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
  return { manifest, manifestPath };
}

function normalizeShardIdentities(manifest) {
  const shards = Array.isArray(manifest?.shards) ? manifest.shards : [];
  if (shards.length === 0) {
    throw new Error('Doppler manifest has no declared shards.');
  }
  return shards.map((shard) => {
    const sha256 = shard.sha256 ?? shard.hash;
    if (!sha256) {
      throw new Error(`Manifest shard ${shard.index} has no hash.`);
    }
    const identity = {
      index: Number(shard.index),
      filename: String(shard.filename),
      sha256: String(sha256),
      sizeBytes: Number(shard.sizeBytes ?? shard.size),
      identitySource: 'manifest_declared',
    };
    if (Number.isFinite(Number(shard.offsetBytes ?? shard.offset))) {
      identity.offsetBytes = Number(shard.offsetBytes ?? shard.offset);
    }
    return identity;
  });
}

function resolveModelUrl(modelDir) {
  return pathToFileURL(path.resolve(modelDir)).href;
}

function normalizeTokens(tokens) {
  if (Array.isArray(tokens)) {
    return tokens.map((token) => Number(token));
  }
  if (ArrayBuffer.isView(tokens)) {
    return Array.from(tokens, (token) => Number(token));
  }
  return [];
}

function normalizeLogits(logits) {
  if (logits instanceof Float32Array) {
    return logits;
  }
  if (ArrayBuffer.isView(logits) || Array.isArray(logits)) {
    return Float32Array.from(logits);
  }
  return new Float32Array();
}

function writeTypedArray(filePath, typedArray) {
  const bytes = Buffer.from(
    typedArray.buffer,
    typedArray.byteOffset,
    typedArray.byteLength
  );
  writeFileSync(filePath, bytes);
}

function releaseLogitsStepResult(modules, stepResult) {
  if (stepResult?.logitsBuffer) {
    modules.releaseBuffer(stepResult.logitsBuffer);
  }
}

function stopTokenSet(pipeline) {
  const ids = new Set();
  for (const id of pipeline?.modelConfig?.stopTokenIds ?? []) {
    if (Number.isInteger(id) && id >= 0) ids.add(id);
  }
  const eos = pipeline?.tokenizer?.getSpecialTokens?.()?.eos;
  if (Number.isInteger(eos) && eos >= 0) ids.add(eos);
  return ids;
}

function eosTokenIds(pipeline) {
  const ids = new Set();
  for (const source of [
    pipeline?.tokenizer?.getSpecialTokens?.()?.eos,
    pipeline?.modelConfig?.eosTokenId,
    pipeline?.modelConfig?.eosTokenIds,
    pipeline?.modelConfig?.eos_token_id,
  ]) {
    if (Array.isArray(source)) {
      for (const id of source) {
        if (Number.isInteger(id) && id >= 0) ids.add(id);
      }
    } else if (Number.isInteger(source) && source >= 0) {
      ids.add(source);
    }
  }
  return ids;
}

function decodeTokenText(pipeline, tokenId) {
  try {
    return pipeline?.tokenizer?.decode?.([tokenId], true, false) ?? '';
  } catch {
    return '';
  }
}

function selectTokenFromLogits(modules, logits, contextTokens, samplingConfig) {
  const samplingLogits = Float32Array.from(logits);
  modules.applyRepetitionPenalty(
    samplingLogits,
    contextTokens,
    samplingConfig.repetitionPenalty
  );
  return modules.sample(samplingLogits, {
    temperature: samplingConfig.temperature,
    topK: samplingConfig.topK,
    topP: samplingConfig.topP,
    padTokenId:
      samplingConfig.padTokenId === null ? undefined : samplingConfig.padTokenId,
    seed: samplingConfig.seed === null ? undefined : samplingConfig.seed,
  });
}

async function buildDecodeTranscript(options) {
  const {
    modules,
    pipeline,
    modelId,
    manifestSha256,
    executionGraphSha256,
    inputSetSha256,
    initialLogits,
    initialLogitsPath,
    initialLogitsSha256,
    promptTokenIds,
    generatedTokensPath,
    transcriptPath,
    decodeSteps,
    samplingConfig,
    manifestEosTokenIds = [],
  } = options;
  if (decodeSteps <= 0) {
    return null;
  }

  const contextTokens = [...promptTokenIds];
  const generatedTokenIds = [];
  const stopTokens = stopTokenSet(pipeline);
  const eosTokens = eosTokenIds(pipeline);
  for (const id of Array.isArray(manifestEosTokenIds)
    ? manifestEosTokenIds
    : [manifestEosTokenIds]) {
    if (Number.isInteger(id) && id >= 0) eosTokens.add(id);
  }
  const logitsDigests = [];
  let stopReason = 'decode_steps_exhausted';

  const recordStep = (stepIndex, phase, logits, logitsPath, logitsSha256) => {
    const selectedTokenId = selectTokenFromLogits(
      modules,
      logits,
      contextTokens,
      samplingConfig
    );
    const digest = {
      stepIndex,
      phase,
      contextTokenCount: contextTokens.length,
      selectedTokenId,
      selectedText: decodeTokenText(pipeline, selectedTokenId),
      dtype: 'float32',
      shape: [logits.length],
      path: repoRelative(logitsPath),
      sha256: logitsSha256,
      byteLength: logits.byteLength,
      preview: Array.from(logits.slice(0, PREVIEW_LIMIT)),
    };
    logitsDigests.push(digest);
    generatedTokenIds.push(selectedTokenId);
    contextTokens.push(selectedTokenId);
    if (stopTokens.has(selectedTokenId)) {
      stopReason = eosTokens.has(selectedTokenId) ? 'eos_token' : 'stop_token';
    }
    return selectedTokenId;
  };

  let tokenId = recordStep(
    0,
    'prefill',
    initialLogits,
    initialLogitsPath,
    initialLogitsSha256
  );

  for (let stepIndex = 1; stepIndex < decodeSteps; stepIndex += 1) {
    if (stopTokens.has(tokenId)) {
      break;
    }
    let stepResult = null;
    try {
      stepResult = await pipeline.decodeStepLogits(contextTokens, {
        useChatTemplate: false,
      });
      const stepLogits = normalizeLogits(stepResult?.logits);
      if (stepLogits.length === 0) {
        throw new Error(`decodeStepLogits returned no logits at step ${stepIndex}`);
      }
      const stepPath = path.join(
        path.dirname(transcriptPath),
        `logits_step_${String(stepIndex).padStart(3, '0')}.f32`
      );
      writeTypedArray(stepPath, stepLogits);
      tokenId = recordStep(
        stepIndex,
        'decode',
        stepLogits,
        stepPath,
        sha256File(stepPath)
      );
    } finally {
      releaseLogitsStepResult(modules, stepResult);
    }
  }

  const generatedTokenArray = Uint32Array.from(generatedTokenIds);
  writeTypedArray(generatedTokensPath, generatedTokenArray);
  const generatedTokenSha256 = sha256File(generatedTokensPath);
  const transcript = {
    schemaVersion: 1,
    artifactKind: 'doppler_int4ple_decode_transcript',
    modelId,
    manifestSha256,
    executionGraphSha256,
    inputSetSha256,
    requestedDecodeSteps: decodeSteps,
    actualDecodeSteps: generatedTokenIds.length,
    decodeStepsRequested: decodeSteps,
    decodeStepsProduced: generatedTokenIds.length,
    stopReason,
    sampling: samplingConfig,
    promptTokenCount: promptTokenIds.length,
    generatedTokenIds,
    generatedTokenIdsSha256: generatedTokenSha256,
    steps: logitsDigests,
  };
  writeJson(transcriptPath, transcript);

  return {
    status: 'output_ready',
    transcript: {
      path: repoRelative(transcriptPath),
      sha256: sha256File(transcriptPath),
      source: 'prefill_decode_logit_steps',
    },
    requestedDecodeSteps: decodeSteps,
    actualDecodeSteps: generatedTokenIds.length,
    decodeStepsRequested: decodeSteps,
    decodeStepsProduced: generatedTokenIds.length,
    stopReason,
    sampling: samplingConfig,
    generatedTokenIds: {
      path: repoRelative(generatedTokensPath),
      sha256: generatedTokenSha256,
      dtype: 'uint32',
      tokenCount: generatedTokenIds.length,
      preview: generatedTokenIds.slice(0, PREVIEW_LIMIT),
    },
    logitsDigests,
  };
}

function assertSameTokenIds(expected, actual) {
  if (expected.length !== actual.length) {
    throw new Error(
      `diagnostic checkpoint token count mismatch: expected ${expected.length}, received ${actual.length}`
    );
  }
  for (let index = 0; index < expected.length; index += 1) {
    if (expected[index] !== actual[index]) {
      throw new Error(
        `diagnostic checkpoint token mismatch at step ${index}: expected ${expected[index]}, received ${actual[index]}`
      );
    }
  }
}

async function captureModelCheckpoints(options) {
  const {
    modules,
    pipeline,
    prompt,
    useChatTemplate,
    decodeSteps,
    samplingConfig,
    expectedTokenIds,
    expectedKvCacheByteProof,
  } = options;
  if (decodeSteps <= 0) return null;

  pipeline.reset();
  const generationOptions = {
    maxTokens: decodeSteps,
    temperature: samplingConfig.temperature,
    topK: samplingConfig.topK,
    topP: samplingConfig.topP,
    repetitionPenalty: samplingConfig.repetitionPenalty,
    useChatTemplate,
    diagnostics: {
      enabled: true,
      captureConfig: {
        defaultLevel: 'full',
        targetLevel: 'full',
      },
    },
  };
  if (samplingConfig.seed !== null) {
    generationOptions.seed = samplingConfig.seed;
  }
  const generation = await pipeline.generateTokenIds(prompt, generationOptions);
  const generatedTokenIds = normalizeTokens(generation?.tokenIds);
  assertSameTokenIds(expectedTokenIds, generatedTokenIds);

  const kvCacheByteProof = await modules.captureKvCacheByteProof(pipeline, true);
  if (
    expectedKvCacheByteProof?.digest
    && kvCacheByteProof?.digest !== expectedKvCacheByteProof.digest
  ) {
    throw new Error(
      'diagnostic checkpoint KV digest differs from the governed prefill/decode transcript'
    );
  }
  const evidence = modules.buildModelCheckpointEvidence({
    operatorDiagnostics: generation?.stats?.operatorDiagnostics ?? null,
    kvCacheByteProof,
    expectedStepCount: decodeSteps,
    minimumDecodeSteps: 2,
  });
  if (!evidence || evidence.status !== 'complete') {
    const stepMissing = evidence?.steps
      ?.filter((step) => step.missing.length > 0)
      .map((step) => `${step.phase}[${step.stepIndex}]=${step.missing.join(',')}`)
      .join('; ');
    throw new Error(
      `full-model checkpoint evidence is incomplete: ${(evidence?.blockers ?? ['missing evidence']).join('; ')}`
      + (stepMissing ? `; ${stepMissing}` : '')
    );
  }
  const checkpointDigests = modules.flattenModelCheckpointDigests(evidence).map((entry) => ({
    stage: entry.stage,
    phase: entry.phase,
    stepIndex: entry.stepIndex,
    digest: entry.digest,
    recordCount: entry.recordCount,
  }));
  return {
    evidence,
    checkpointDigests,
    kvCacheByteProof,
  };
}

function materializeModelCheckpointValues(evidence, valuesPath) {
  const chunks = [];
  let byteOffset = 0;
  for (const step of evidence.steps) {
    for (const checkpoint of Object.values(step.checkpoints)) {
      for (const record of checkpoint.records) {
        if (!Array.isArray(record.data)) {
          throw new Error(
            `checkpoint ${checkpoint.stage} ${record.opId ?? 'unknown'} has no full tensor data`
          );
        }
        const values = Float32Array.from(record.data);
        const bytes = Buffer.from(values.buffer, values.byteOffset, values.byteLength);
        record.dataArtifact = {
          path: path.basename(valuesPath),
          dtype: 'float32',
          byteOffset,
          byteLength: bytes.byteLength,
          elementCount: values.length,
          sha256: sha256Bytes(bytes),
        };
        delete record.data;
        chunks.push(bytes);
        byteOffset += bytes.byteLength;
      }
    }
  }
  const output = Buffer.concat(chunks, byteOffset);
  writeFileSync(valuesPath, output);
  return {
    path: repoRelative(valuesPath),
    sha256: sha256File(valuesPath),
    byteLength: output.byteLength,
    recordCount: chunks.length,
  };
}

async function main() {
  const args = parseArgs(process.argv);
  if (args.help) {
    printHelp();
    return 0;
  }

  const dopplerRoot = path.resolve(args.dopplerRoot);
  const modelDir = path.resolve(args.modelDir);
  const outDir = path.resolve(REPO_ROOT, args.outDir);
  mkdirSync(outDir, { recursive: true });

  const { manifest, manifestPath } = loadManifest(modelDir);
  const modelId = args.modelId ?? manifest.modelId ?? path.basename(modelDir);
  const execution = manifest?.inference?.execution;
  if (!execution || typeof execution !== 'object') {
    throw new Error('Doppler manifest does not expose inference.execution.');
  }

  const modules = await loadDopplerModules(dopplerRoot);
  modules.installNodeFileFetchShim();
  const originalRuntime = cloneValue(modules.getRuntimeConfig());

  let harness = null;
  try {
    if (args.runtimeProfile) {
      await modules.applyRuntimeProfile(args.runtimeProfile);
    }

    const providerContractModule =
      process.env.DOE_DOPPLER_QUALIFICATION_PROVIDER_CONTRACT?.trim() || undefined;
    const bootstrap = await modules.bootstrapNodeWebGPU(
      providerContractModule === undefined ? {} : { providerContractModule }
    );
    if (!bootstrap?.ok) {
      throw new Error(
        `WebGPU bootstrap failed: ${bootstrap?.detail ?? 'unknown error'}`
      );
    }

    const runtimeConfig = buildRuntimeConfig(modules.getRuntimeConfig(), args);
    harness = await modules.initializeInference(resolveModelUrl(modelDir), {
      modelId,
      runtime: { runtimeConfig },
    });

    const prefill = await harness.pipeline.prefillWithLogits(args.prompt, {
      useChatTemplate: args.useChatTemplate,
    });
    const logits = normalizeLogits(prefill?.logits);
    if (logits.length === 0) {
      throw new Error('Doppler prefillWithLogits returned no logits.');
    }

    const promptTokenIds = normalizeTokens(prefill?.tokens);
    const promptPath = path.join(outDir, 'prompt.txt');
    const tokenizedPromptPath = path.join(outDir, 'tokenized_prompt.u32');
    const logitsPath = path.join(outDir, 'final_logits.f32');
    const generatedTokensPath = path.join(outDir, 'generated_tokens.u32');
    const transcriptPath = path.join(outDir, 'decode_transcript.json');
    const modelCheckpointsPath = path.join(outDir, 'model_checkpoints.json');
    const modelCheckpointValuesPath = path.join(outDir, 'model_checkpoint_values.f32');
    const executionGraphPath = path.join(outDir, 'execution_graph.json');
    const receiptPath = path.join(
      outDir,
      'doppler_int4ple_reference_export.json'
    );

    writeFileSync(promptPath, args.prompt, 'utf8');
    const tokenArray = Uint32Array.from(promptTokenIds);
    writeTypedArray(tokenizedPromptPath, tokenArray);
    writeTypedArray(logitsPath, logits);

    const manifestSha256 = sha256File(manifestPath);
    const executionGraph = {
      schemaVersion: 1,
      artifactKind: 'doppler_manifest_execution_graph',
      source: 'manifest.inference.execution',
      modelId,
      manifestSha256,
      execution,
    };
    writeJson(executionGraphPath, executionGraph);
    const executionGraphSha256 = sha256File(executionGraphPath);

    const promptSha256 = sha256File(promptPath);
    const tokenizedPromptSha256 = sha256File(tokenizedPromptPath);
    const logitsSha256 = sha256File(logitsPath);
    const shardIdentities = normalizeShardIdentities(manifest);
    const weightSetId =
      manifest?.artifactIdentity?.weightPackId ??
      manifest?.weightSetId ??
      `${modelId}-declared-shards`;
    const weightSetSha256 = sha256Json({ weightSetId, shardIdentities });
    const padTokenId = harness.pipeline.tokenizer?.getSpecialTokens?.()?.pad;
    const samplingConfig = {
      temperature: args.temperature,
      topK: args.topK,
      topP: args.topP,
      repetitionPenalty: args.repetitionPenalty,
      padTokenId: Number.isInteger(padTokenId) && padTokenId >= 0
        ? padTokenId
        : null,
      seed: args.seed,
    };
    const samplingSha256 = sha256Json(samplingConfig);
    const inputSetComponents = {
      modelId,
      promptSha256,
      runtimeProfile: args.runtimeProfile,
      decodeSteps: args.decodeSteps,
      samplingSha256,
      tokenCount: promptTokenIds.length,
      tokenizedPromptSha256,
      useChatTemplate: args.useChatTemplate,
    };
    const inputSetSha256 = sha256Json(inputSetComponents);
    const decodeTranscript = await buildDecodeTranscript({
      modules,
      pipeline: harness.pipeline,
      modelId,
      manifestSha256,
      executionGraphSha256,
      inputSetSha256,
      initialLogits: logits,
      initialLogitsPath: logitsPath,
      initialLogitsSha256: logitsSha256,
      promptTokenIds,
      generatedTokensPath,
      transcriptPath,
      decodeSteps: args.decodeSteps,
      samplingConfig,
      manifestEosTokenIds: manifest?.eos_token_id,
    });
    const transcriptKvCacheByteProof = await modules.captureKvCacheByteProof(
      harness.pipeline,
      true
    );
    const decodedTranscript = decodeTranscript
      ? JSON.parse(readFileSync(transcriptPath, 'utf8'))
      : null;
    const modelCheckpointCapture = await captureModelCheckpoints({
      modules,
      pipeline: harness.pipeline,
      prompt: args.prompt,
      useChatTemplate: args.useChatTemplate,
      decodeSteps: args.decodeSteps,
      samplingConfig,
      expectedTokenIds: decodedTranscript?.generatedTokenIds ?? [],
      expectedKvCacheByteProof: transcriptKvCacheByteProof,
    });
    const kvCacheByteProof = modelCheckpointCapture?.kvCacheByteProof
      ?? transcriptKvCacheByteProof;
    const kvCacheEvidence = buildKvCacheEvidence(kvCacheByteProof);
    const modelCheckpointValues = modelCheckpointCapture
      ? materializeModelCheckpointValues(
        modelCheckpointCapture.evidence,
        modelCheckpointValuesPath
      )
      : null;
    if (modelCheckpointCapture) {
      writeJson(modelCheckpointsPath, modelCheckpointCapture.evidence);
    }
    const stats = harness.pipeline.getStats?.() ?? {};
    const receipt = {
      schemaVersion: 1,
      artifactKind: 'doppler_int4ple_reference_export',
      referenceKind:
        args.decodeSteps > 0 ? 'prefill_decode_transcript' : 'final_logits',
      exportStatus: 'output_ready',
      modelId,
      manifestPath,
      manifestSha256,
      executionGraphSha256,
      executionGraph: {
        path: repoRelative(executionGraphPath),
        sha256: executionGraphSha256,
        source: 'manifest.inference.execution',
      },
      weightSetId,
      weightSetSha256,
      shardIdentities,
      inputSetSha256,
      inputSetComponents,
      prompt: {
        path: repoRelative(promptPath),
        sha256: promptSha256,
        source: 'fixed_text_prompt',
      },
      tokenizedPrompt: {
        path: repoRelative(tokenizedPromptPath),
        sha256: tokenizedPromptSha256,
        dtype: 'uint32',
        tokenCount: promptTokenIds.length,
        preview: promptTokenIds.slice(0, PREVIEW_LIMIT),
      },
      tensorDigest: {
        name: 'final_logits',
        status: 'output_ready',
        dtype: 'float32',
        shape: [logits.length],
        path: repoRelative(logitsPath),
        sha256: logitsSha256,
        byteLength: logits.byteLength,
        preview: Array.from(logits.slice(0, PREVIEW_LIMIT)),
      },
      checkpointDigests: modelCheckpointCapture?.checkpointDigests ?? [],
      modelCheckpointEvidence: modelCheckpointCapture
        ? {
          status: modelCheckpointCapture.evidence.status,
          path: repoRelative(modelCheckpointsPath),
          sha256: sha256File(modelCheckpointsPath),
          stepCount: modelCheckpointCapture.evidence.stepCount,
          decodeStepCount: modelCheckpointCapture.evidence.decodeStepCount,
          capturedStages: modelCheckpointCapture.evidence.capturedStages,
          values: modelCheckpointValues,
        }
        : null,
      kvCacheEvidence,
      ...(decodeTranscript ? { decodeTranscript } : {}),
      producer: {
        runtime: process.versions.electron
          ? 'doppler_electron_main_process_webgpu'
          : 'doppler_node_webgpu',
        toolPath: repoRelative(SCRIPT_PATH),
        dopplerRoot,
        runtimeProfile: args.runtimeProfile,
        webgpuProvider: bootstrap.provider ?? 'node-webgpu',
        kernelPathId: stats.kernelPathId ?? harness.pipeline.resolvedKernelPath?.id ?? null,
        kernelPathSource:
          stats.kernelPathSource ?? harness.pipeline.kernelPathSource ?? null,
        nodeVersion: process.version,
        electronVersion: process.versions.electron ?? null,
        emittedAt: new Date().toISOString(),
      },
      inputsSynthetic: false,
      weightsSynthetic: false,
      tolerancePolicy: {
        comparison: 'max_abs',
        atol: args.atol,
        rtol: args.rtol,
        notes:
          'Exact sha256 identity is preferred when Doe CSL reproduces Doppler bit-for-bit; max_abs is the promotion tolerance when platform f32 reduction order differs.',
      },
      claimBoundary: {
        claimable: false,
        scope:
          args.decodeSteps > 0
            ? 'Production Doppler INT4 PLE RDRR WebGPU prefill+decode transcript reference. It becomes Cerebras evidence only after Doe CSL simfabric and hardware receipts bind the same manifest, graph, weights, input set, per-step logits, and token IDs.'
            : 'Production Doppler INT4 PLE RDRR WebGPU final-logits reference only. It becomes Cerebras evidence only after Doe CSL simfabric and hardware receipts bind the same manifest, graph, weights, and input set.',
        blockedUntil: [
          args.decodeSteps > 0
            ? 'Doe CSL simfabric bounded prefill+decode transcript for the same source program'
            : 'Doe CSL simfabric final_logits receipt for the same source program',
          'Doe CSL reference parity gate promotion criteria pass',
          'Cerebras hardware receipt binds the same reference receipt',
        ],
      },
    };

    writeJson(receiptPath, receipt);
    console.log(
      JSON.stringify(
        {
          ok: true,
          receipt: repoRelative(receiptPath),
          tensor: repoRelative(logitsPath),
          tensorSha256: logitsSha256,
          tokenCount: promptTokenIds.length,
          logitsShape: [logits.length],
          decodeStepsRequested: args.decodeSteps,
          decodeStepsProduced:
            decodeTranscript?.decodeStepsProduced ?? 0,
        },
        null,
        2
      )
    );
    return 0;
  } finally {
    try {
      await harness?.pipeline?.unload?.();
    } catch {
      // Best-effort cleanup after production export.
    }
    try {
      harness?.pipeline?.releaseGPUResources?.();
    } catch {
      // Best-effort cleanup after production export.
    }
    modules.setRuntimeConfig(originalRuntime);
  }
}

main()
  .then((code) => {
    process.exit(code);
  })
  .catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  });

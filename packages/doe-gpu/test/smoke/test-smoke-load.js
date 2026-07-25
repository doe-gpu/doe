#!/usr/bin/env node
// Smoke test for doe-gpu.
// Verifies the package loads and key exports have the expected shape.
// No GPU required — pure export/shape validation only.
//
// Usage:
//   node test/smoke/test-smoke-load.js
//
// Exit codes:
//   0  All checks passed
//   1  A check failed (actionable error printed)

import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

let passed = 0;
let failed = 0;
const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../../../..');

function check(label, condition, detail) {
  if (condition) {
    passed++;
    console.log(`  ok: ${label}`);
  } else {
    failed++;
    console.error(`  FAIL: ${label}${detail ? ' — ' + detail : ''}`);
  }
}

function latestInPathNumericStabilityCommandsPath() {
  const root = resolve(REPO_ROOT, 'bench/out/apple-metal-in-path-numeric-stability');
  if (!existsSync(root)) {
    return null;
  }
  const timestampDirs = readdirSync(root, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort()
    .reverse();
  for (const timestampDir of timestampDirs) {
    const caseRoot = resolve(root, timestampDir);
    const manifestPath = resolve(caseRoot, 'apple_metal_in_path_numeric_stability.manifest.json');
    if (!existsSync(manifestPath)) {
      continue;
    }
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
    for (const entry of manifest.cases ?? []) {
      const commandsPath = resolve(REPO_ROOT, entry.commandsPath);
      if (existsSync(commandsPath)) {
        return commandsPath;
      }
    }
  }
  return null;
}

function decodeSampledCommandsPath() {
  const path = resolve(REPO_ROOT, 'examples/numeric-stability-decode-sampled.commands.json');
  return existsSync(path) ? path : null;
}

function shouldSkipOptionalRuntimeExercise(err) {
  const message = String(err?.message ?? err ?? '');
  return (
    message.includes('FileNotFound') ||
    message.includes('ENOENT') ||
    message.includes('EPERM') ||
    message.includes('module-core-runner') ||
    message.includes('doe-zig-runtime binary not found')
  );
}

console.log('=== doe-gpu smoke test ===\n');

// ── 1. Import the main package surface ──────────────────────────────────

let mod;
try {
  mod = await import('../../src/index.js');
  check('import succeeds', true);
} catch (err) {
  check('import succeeds', false, err.message);
  process.exit(1);
}

// ── 2. Key named exports exist ──────────────────────────────────────────

check('exports gpu', mod.gpu != null);
check('exports createGpuNamespace', typeof mod.createGpuNamespace === 'function');
check('exports createDoeNamespace', typeof mod.createDoeNamespace === 'function');
check('exports create', typeof mod.create === 'function');
check('exports createNativeDirect', typeof mod.createNativeDirect === 'function');
check('exports requestDevice', typeof mod.requestDevice === 'function');
check('exports requestAdapter', typeof mod.requestAdapter === 'function');
check('exports providerInfo', typeof mod.providerInfo === 'function');
check('exports nativeFastPathInfo', typeof mod.nativeFastPathInfo === 'function');
check('exports globals', mod.globals != null && typeof mod.globals === 'object');
check('exports createDoeRuntime', typeof mod.createDoeRuntime === 'function');

// ── 3. gpu namespace shape ──────────────────────────────────────────────

console.log('\ngpu namespace shape:');
check('gpu is an object', typeof mod.gpu === 'object');
check('gpu.requestDevice is a function', typeof mod.gpu.requestDevice === 'function');
check('gpu.bind is a function', typeof mod.gpu.bind === 'function');

console.log('\ngpu determinism shape:');
const boundWithoutGpu = mod.gpu.bind({});
check('gpu.bind({}) exposes determinism namespace', boundWithoutGpu.determinism != null && typeof boundWithoutGpu.determinism === 'object');
check('gpu.bind({}).determinism.stableToken is a function', typeof boundWithoutGpu.determinism?.stableToken === 'function');
check('gpu.bind({}).determinism.stableChoice is a function', typeof boundWithoutGpu.determinism?.stableChoice === 'function');
check('gpu.bind({}).determinism.reviewedChoice is a function', typeof boundWithoutGpu.determinism?.reviewedChoice === 'function');
console.log('\ngpu numericStability shape:');
check('gpu.ordinaryExecution is a function', typeof mod.gpu?.ordinaryExecution === 'function');
check('gpu.bind({}).ordinaryExecution is a function', typeof boundWithoutGpu.ordinaryExecution === 'function');
check('gpu.bind({}) exposes numericStability namespace', boundWithoutGpu.numericStability != null && typeof boundWithoutGpu.numericStability === 'object');
check('gpu.bind({}).numericStability.matmulLogitsSlice is a function', typeof boundWithoutGpu.numericStability?.matmulLogitsSlice === 'function');
check('gpu.bind({}).numericStability.ordinaryExecution is a function', typeof boundWithoutGpu.numericStability?.ordinaryExecution === 'function');
check(
  'gpu.bind({}).ordinaryExecution aliases numericStability.ordinaryExecution',
  boundWithoutGpu.ordinaryExecution === boundWithoutGpu.numericStability?.ordinaryExecution,
);
try {
  const stable = await boundWithoutGpu.determinism.stableToken({
    logits: new Float32Array([0, 7, 7, 3]),
  });
  check('stableToken returns lowest max index for host logits', stable.token === 1, JSON.stringify(stable));
  check('stableToken receipt reports policy registry path', stable.receipt?.policyRegistryPath === 'config/determinism-policy.json');
  check('stableToken receipt reports policy registry version', stable.receipt?.policyRegistryVersion === '2026-03-28');
  check('stableToken receipt reports policy id', stable.receipt?.policyId === 'stable-token/lowest-index-among-max-v1');
  check('stableToken receipt reports host-bytes source', stable.receipt?.sourceKind === 'host-bytes');
  check('stableToken receipt reports tied max count', stable.receipt?.tiedMaxCount === 2);
  check('stableToken receipt reports explicit tie-break rule', stable.receipt?.tieBreakRule === 'lowest-index-among-max');
  check('stableToken receipt reports selectedBy policy', stable.receipt?.selectedBy === 'stable-token-policy');
  check('stableToken receipt exposes proof links', Array.isArray(stable.receipt?.proofLinks) && stable.receipt.proofLinks.length >= 1);
} catch (err) {
  check('stableToken host-logit helper succeeds', false, err.message);
}
try {
  const choice = await boundWithoutGpu.determinism.stableChoice({
    logits: new Float32Array([0, 7, 7, 3]),
    candidates: [
      { token: 2, label: 'unsafe' },
      { token: 1, label: 'safe' },
    ],
    ambiguityTrigger: { mode: 'exact-max-tie' },
    policyId: 'smoke/fixed-priority-safe-last',
    triggerPolicyId: 'exact-max-tie-v1',
    candidateSetId: 'safety.safe_unsafe',
    candidateSetSource: 'fixture-declared',
  });
  check('stableChoice exact tie follows fixed-priority order', choice.token === 2, JSON.stringify(choice));
  check('stableChoice receipt reports stable-choice mode', choice.receipt?.mode === 'stable-choice');
  check('stableChoice receipt reports policy registry path', choice.receipt?.policyRegistryPath === 'config/determinism-policy.json');
  check('stableChoice receipt reports policy registry version', choice.receipt?.policyRegistryVersion === '2026-03-28');
  check('stableChoice receipt reports policy trigger', choice.receipt?.ambiguityTriggered === true);
  check('stableChoice receipt records selectedBy policy', choice.receipt?.selectedBy === 'stable-choice-policy');
  check('stableChoice receipt preserves policyId', choice.receipt?.policyId === 'smoke/fixed-priority-safe-last');
  check('stableChoice receipt preserves triggerPolicyId', choice.receipt?.triggerPolicyId === 'exact-max-tie-v1');
  check('stableChoice receipt preserves candidateSetId', choice.receipt?.candidateSetId === 'safety.safe_unsafe');
  check('stableChoice receipt preserves candidateSetSource', choice.receipt?.candidateSetSource === 'fixture-declared');
  check('stableChoice receipt exposes proof links', Array.isArray(choice.receipt?.proofLinks) && choice.receipt.proofLinks.length >= 3);
} catch (err) {
  check('stableChoice host-logit helper succeeds', false, err.message);
}
try {
  const reviewed = await boundWithoutGpu.determinism.reviewedChoice({
    logits: new Float32Array([0, 7, 7, 3]),
    candidates: [
      { token: 2, label: 'unsafe' },
      { token: 1, label: 'safe' },
    ],
    ambiguityTrigger: { mode: 'exact-max-tie' },
    reviewPolicyId: 'smoke/reviewer-v1',
    triggerPolicyId: 'exact-max-tie-v1',
    candidateSetId: 'safety.safe_unsafe',
    candidateSetSource: 'fixture-declared',
    decision: {
      token: 1,
      label: 'safe',
      reviewerId: 'smoke/reviewer-v1',
      decisionId: 'smoke-review-001',
    },
  });
  check('reviewedChoice exact tie honors reviewed token', reviewed.token === 1, JSON.stringify(reviewed));
  check('reviewedChoice receipt reports reviewed-choice mode', reviewed.receipt?.mode === 'reviewed-choice');
  check('reviewedChoice receipt reports policy registry path', reviewed.receipt?.policyRegistryPath === 'config/determinism-policy.json');
  check('reviewedChoice receipt reports policy registry version', reviewed.receipt?.policyRegistryVersion === '2026-03-28');
  check('reviewedChoice receipt records decision acceptance', reviewed.receipt?.decisionAccepted === true);
  check('reviewedChoice receipt records selectedBy decision', reviewed.receipt?.selectedBy === 'reviewed-choice-decision');
  check('reviewedChoice receipt preserves reviewerId', reviewed.receipt?.decision?.reviewerId === 'smoke/reviewer-v1');
  check('reviewedChoice receipt exposes proof links', Array.isArray(reviewed.receipt?.proofLinks) && reviewed.receipt.proofLinks.length >= 3);
} catch (err) {
  check('reviewedChoice host-logit helper succeeds', false, err.message);
}

// ── 4. globals has standard WebGPU enum objects ─────────────────────────

console.log('\nglobals shape:');
const g = mod.globals;
check('globals.GPUBufferUsage exists', g.GPUBufferUsage != null);
check('globals.GPUBufferUsage.STORAGE', typeof g.GPUBufferUsage?.STORAGE === 'number');
check('globals.GPUShaderStage exists', g.GPUShaderStage != null);
check('globals.GPUShaderStage.COMPUTE', typeof g.GPUShaderStage?.COMPUTE === 'number');
check('globals.GPUMapMode exists', g.GPUMapMode != null);
check('globals.GPUMapMode.READ', typeof g.GPUMapMode?.READ === 'number');

// ── 5. createGpuNamespace returns same shape as gpu ─────────────────────

console.log('\ncreateGpuNamespace shape:');
const ns = mod.createGpuNamespace();
check('createGpuNamespace() returns object', typeof ns === 'object' && ns != null);
check('namespace.requestDevice', typeof ns.requestDevice === 'function');
check('namespace.bind', typeof ns.bind === 'function');

// ── 6. Compute surface ──────────────────────────────────────────────────

console.log('\ncompute surface:');
let compute;
try {
  compute = await import('../../src/compute.js');
  check('compute import succeeds', true);
} catch (err) {
  check('compute import succeeds', false, err.message);
}

if (compute) {
  check('compute.gpu exists', compute.gpu != null);
  check('compute.createGpuNamespace', typeof compute.createGpuNamespace === 'function');
  check('compute.create', typeof compute.create === 'function');
  check('compute.requestDevice', typeof compute.requestDevice === 'function');
  check('compute.requestAdapter', typeof compute.requestAdapter === 'function');
  check('compute.providerInfo', typeof compute.providerInfo === 'function');
  check('compute.globals exists', compute.globals != null && typeof compute.globals === 'object');
  check('compute.gpu.requestDevice', typeof compute.gpu?.requestDevice === 'function');
  check('compute.gpu.bind', typeof compute.gpu?.bind === 'function');
}

// ── 7. Split package surfaces ───────────────────────────────────────────

console.log('\nsplit package surfaces:');
let api;
try {
  api = await import('doe-gpu/api');
  check('api import succeeds', true);
} catch (err) {
  check('api import succeeds', false, err.message);
}
if (api) {
  check('api.createDoeNamespace', typeof api.createDoeNamespace === 'function');
  check('api.createGpuNamespace', typeof api.createGpuNamespace === 'function');
  check('api.gpu.bind', typeof api.gpu?.bind === 'function');
}

let native;
try {
  native = await import('doe-gpu/native');
  check('native import succeeds', true);
} catch (err) {
  check('native import succeeds', false, err.message);
}
if (native) {
  check('native.requestDevice', typeof native.requestDevice === 'function');
  check('native.providerInfo', typeof native.providerInfo === 'function');
  check('native.gpu.requestDevice', typeof native.gpu?.requestDevice === 'function');
}

let nodeWebgpu;
try {
  nodeWebgpu = await import('doe-gpu/node-webgpu');
  check('node-webgpu import succeeds', true);
} catch (err) {
  check('node-webgpu import succeeds', false, err.message);
}
if (nodeWebgpu) {
  check('node-webgpu exports bootstrapNodeWebGPU', typeof nodeWebgpu.bootstrapNodeWebGPU === 'function');
  check('node-webgpu exports bootstrapNodeWebGPUProvider', typeof nodeWebgpu.bootstrapNodeWebGPUProvider === 'function');
  check('node-webgpu exports hasNavigatorGpu', typeof nodeWebgpu.hasNavigatorGpu === 'function');
  check('node-webgpu exports installNavigatorGpu', typeof nodeWebgpu.installNavigatorGpu === 'function');
}

let plan;
try {
  plan = await import('doe-gpu/plan');
  check('plan import succeeds', true);
} catch (err) {
  check('plan import succeeds', false, err.message);
}
if (plan) {
  const commandValidation = plan.validateCommandStream([
    { kind: 'buffer_write', handle: 1, bufferSize: 4, data: [1] },
    { kind: 'kernel_dispatch', kernel: 'demo.wgsl', x: 1, y: 1, z: 1 },
  ]);
  check('plan validates command streams', commandValidation.ok === true);
  const evidenceArtifactValidation = plan.validatePlanArtifact({
    schemaVersion: 1,
    artifactKind: plan.DOE_WEBGPU_CAPTURE_EVIDENCE_ARTIFACT_KIND,
    modelId: 'smoke',
    sourceProgram: {},
    destinations: [],
    loweringStages: [],
    verdict: {},
  });
  check('plan recognizes capture evidence artifact kind', evidenceArtifactValidation.ok === true);
  check('plan exposes lowering stages', plan.DOE_CAPTURE_LOWERING_STAGES.includes('parity'));
  check('plan exposes WebGPU globals', typeof plan.globals?.GPUBufferUsage?.STORAGE === 'number');
  check('plan exposes capture gpu provider', typeof plan.gpu?.requestAdapter === 'function');
  check('plan exposes capture provider', typeof plan.createCaptureProvider === 'function');
}

let capture;
try {
  capture = await import('doe-gpu/capture');
  check('capture import succeeds', true);
} catch (err) {
  check('capture import succeeds', false, err.message);
}
if (capture) {
  check('capture.requestDevice', typeof capture.requestDevice === 'function');
  const provider = capture.createCaptureProvider({
    metadata: { smoke: true },
  });
  const device = await provider.requestDevice();
  const buffer = device.createBuffer({ label: 'data', size: 16, usage: 0x88 });
  device.queue.writeBuffer(buffer, 0, new Uint32Array([1, 2, 3, 4]));
  const shader = device.createShaderModule({
    label: 'double',
    code: '@group(0) @binding(0) var<storage, read_write> data: array<u32>; @compute @workgroup_size(1) fn main() { data[0] = data[0] + 1u; }',
  });
  const bindGroupLayout = device.createBindGroupLayout({
    entries: [{ binding: 0, visibility: 4, buffer: { type: 'storage' } }],
  });
  const pipelineLayout = device.createPipelineLayout({
    bindGroupLayouts: [bindGroupLayout],
  });
  const pipeline = device.createComputePipeline({
    layout: pipelineLayout,
    compute: { module: shader, entryPoint: 'main' },
  });
  const bindGroup = device.createBindGroup({
    layout: bindGroupLayout,
    entries: [{ binding: 0, resource: { buffer } }],
  });
  const encoder = device.createCommandEncoder();
  const pass = encoder.beginComputePass();
  pass.setPipeline(pipeline);
  pass.setBindGroup(0, bindGroup);
  pass.dispatchWorkgroups(1);
  pass.end();
  const commandBuffer = encoder.finish();
  device.queue.submit([commandBuffer]);
  const graph = await provider.snapshot();
  check('capture snapshot is capture graph', graph.artifactKind === capture.DOE_WEBGPU_CAPTURE_GRAPH_ARTIFACT_KIND);
  check('capture snapshot validates as artifact', capture.validatePlanArtifact(graph).ok === true);
  check('capture snapshot validates as capture graph', capture.validateCaptureGraph(graph).ok === true);
  check('capture snapshot hashes WGSL', typeof graph.shaderModules?.[0]?.wgslSha256 === 'string' && graph.shaderModules[0].wgslSha256.length === 64);
  check('capture snapshot hashes buffer writes', typeof graph.bufferWrites?.[0]?.dataSha256 === 'string' && graph.bufferWrites[0].dataSha256.length === 64);
  check('capture snapshot records submit', graph.submissions?.length === 1);
  check('capture exports WebGPU enum globals', typeof capture.GPUShaderStage?.COMPUTE === 'number');
  check('capture exports gpu provider', typeof capture.gpu?.requestAdapter === 'function');
}

// ── 8. Doe runtime tooling surface ──────────────────────────────────────

console.log('\ndoe runtime tooling surface:');
try {
  const runtime = mod.createDoeRuntime();
  check('createDoeRuntime() returns object', typeof runtime === 'object' && runtime != null);
  check('runtime.runBench is a function', typeof runtime.runBench === 'function');
  check('runtime.runModule is a function', typeof runtime.runModule === 'function');
  check('runtime.runOrdinaryExecution is a function', typeof runtime.runOrdinaryExecution === 'function');
  check('runtime.runNumericStabilityMatmulLogitsSlice is a function', typeof runtime.runNumericStabilityMatmulLogitsSlice === 'function');
  check('runtime.runNumericStabilityOrdinaryExecution is a function', typeof runtime.runNumericStabilityOrdinaryExecution === 'function');
  if (typeof runtime.runNumericStabilityMatmulLogitsSlice === 'function') {
    try {
      const numeric = await boundWithoutGpu.numericStability.matmulLogitsSlice({
        runtime,
        hiddenState: [1, 1, 1],
        candidates: [
          { tokenId: 11, label: 'keep', weights: [10000, 0.01, -10000] },
          { tokenId: 22, label: 'flip', weights: [0, 0.001, 0] },
        ],
      });
      check('numericStability host helper returns prefer-stable route', numeric.routeDecision === 'prefer-stable', JSON.stringify(numeric));
      check('numericStability host helper returns stable token', numeric.token === 11, JSON.stringify(numeric));
      check('numericStability receipt reports numeric-stability mode', numeric.receipt?.mode === 'numeric-stability');
      check('numericStability receipt reports policy registry path', numeric.receipt?.policyRegistryPath === 'config/numeric-stability-policy.json');
      check('numericStability receipt reports policy registry version', numeric.receipt?.policyRegistryVersion === '2026-03-29-execution-profiles-v1');
      check('numericStability receipt reports route taxonomy version', numeric.receipt?.routeTaxonomyVersion === 'numeric-stability-routes-v1');
      check('numericStability receipt reports route selection mode', numeric.receipt?.route?.selectionMode === 'stable');
      const acceptFast = await boundWithoutGpu.numericStability.matmulLogitsSlice({
        runtime,
        hiddenState: [1, 2],
        candidates: [
          { tokenId: 11, label: 'fast-ref', weights: [0.25, 0.75] },
          { tokenId: 22, label: 'stable-drift', weights: [0.1, 0.2] },
        ],
      });
      check('numericStability host helper returns accept-fast route', acceptFast.routeDecision === 'accept-fast', JSON.stringify(acceptFast));
      check('numericStability host helper returns fast token for accept-fast', acceptFast.token === 11, JSON.stringify(acceptFast));
      const abstain = await boundWithoutGpu.numericStability.matmulLogitsSlice({
        runtime,
        routingPolicyId: 'numeric-stability/abstain-on-selected-token-disagreement-v1',
        hiddenState: [1, 1, 1],
        candidates: [
          { tokenId: 11, label: 'keep', weights: [10000, 0.01, -10000] },
          { tokenId: 22, label: 'flip', weights: [0, 0.001, 0] },
        ],
      });
      check('numericStability host helper returns abstain route', abstain.routeDecision === 'abstain', JSON.stringify(abstain));
      check('numericStability host helper returns null token for abstain', abstain.token == null, JSON.stringify(abstain));
    } catch (err) {
      if (shouldSkipOptionalRuntimeExercise(err)) {
        console.log(`  skip: numericStability host helper (${err.message})`);
      } else {
        check('numericStability host helper succeeds', false, err.message);
      }
    }
  }
  if (typeof runtime.runOrdinaryExecution === 'function') {
    const commandsPath = latestInPathNumericStabilityCommandsPath();
    if (commandsPath) {
      try {
        const numeric = await boundWithoutGpu.ordinaryExecution({
          runtime,
          commandsPath,
          vendor: 'apple',
          api: 'metal',
          family: 'apple-gpu',
          driver: '1.0.0',
        });
        check(
          'ordinaryExecution returns at least one route decision',
          Array.isArray(numeric.routeDecisions) && numeric.routeDecisions.length >= 1,
          JSON.stringify(numeric),
        );
        check(
          'ordinaryExecution returns latest receipt',
          numeric.latestReceipt?.mode === 'numeric-stability',
          JSON.stringify(numeric.latestReceipt),
        );
        check(
          'ordinaryExecution reports selected execution profile',
          numeric.executionProfileId === 'numeric-stability/default-ordinary-execution-v1',
          JSON.stringify({ executionProfileId: numeric.executionProfileId }),
        );
        check(
          'ordinaryExecution receipt has kernel basename',
          typeof numeric.latestReceipt?.executionIdentity?.kernelBasename === 'string' &&
            numeric.latestReceipt.executionIdentity.kernelBasename.length > 0,
          JSON.stringify(numeric.latestReceipt?.executionIdentity),
        );
        check(
          'ordinaryExecution receipt has layout fingerprint',
          typeof numeric.latestReceipt?.executionIdentity?.layoutFingerprint === 'string' &&
            numeric.latestReceipt.executionIdentity.layoutFingerprint.length > 0,
          JSON.stringify(numeric.latestReceipt?.executionIdentity),
        );
        check(
          'ordinaryExecution receipt has compiled plan hash',
          typeof numeric.latestReceipt?.executionIdentity?.compiledPlanHash === 'string' &&
            numeric.latestReceipt.executionIdentity.compiledPlanHash.length > 0,
          JSON.stringify(numeric.latestReceipt?.executionIdentity),
        );
        check(
          'ordinaryExecution receipt records route effect fields',
          typeof numeric.latestReceipt?.route?.effectApplied === 'boolean' &&
            typeof numeric.latestReceipt?.route?.committedResultMode === 'string' &&
            typeof numeric.latestReceipt?.route?.downstreamAction === 'string',
          JSON.stringify(numeric.latestReceipt?.route),
        );
      } catch (err) {
        check('ordinaryExecution helper succeeds', false, err.message);
      }
    } else {
      console.log('  skip: ordinaryExecution (no in-path artifacts found)');
    }

    const decodeCommandsPath = decodeSampledCommandsPath();
    if (decodeCommandsPath && process.platform === 'darwin') {
      try {
        const decode = await boundWithoutGpu.ordinaryExecution({
          runtime,
          commandsPath: decodeCommandsPath,
          vendor: 'apple',
          api: 'metal',
          family: 'apple-gpu',
          driver: '1.0.0',
        });
        if (!decode.latestReceipt) {
          console.log('  skip: ordinaryExecution decode demo (no numeric-stability receipt emitted)');
        } else {
          check(
            'ordinaryExecution decode demo emits decode.sample_token receipt',
            decode.latestReceipt?.semanticOpId === 'decode.sample_token',
            JSON.stringify(decode.latestReceipt),
          );
          check(
            'ordinaryExecution decode demo exposes decodeBoundary block',
            decode.latestReceipt?.decodeBoundary != null &&
              typeof decode.latestReceipt.decodeBoundary === 'object',
            JSON.stringify(decode.latestReceipt?.decodeBoundary),
          );
          check(
            'ordinaryExecution decode demo reports sampled full-vocab boundary',
            decode.latestReceipt?.decodeBoundary?.decodeMode === 'sampled-cdf' &&
              decode.latestReceipt?.decodeBoundary?.logitsCoverage === 'full-vocab',
            JSON.stringify(decode.latestReceipt?.decodeBoundary),
          );
          check(
            'ordinaryExecution decode demo exposes sampled replay metrics',
            typeof decode.latestReceipt?.decodeBoundary?.metrics?.fastTop1Margin === 'number' &&
              typeof decode.latestReceipt?.decodeBoundary?.metrics?.actualSelectedTokenChanged === 'boolean' &&
              typeof decode.latestReceipt?.decodeBoundary?.rngDraw === 'number',
            JSON.stringify(decode.latestReceipt?.decodeBoundary?.metrics),
          );
          check(
            'ordinaryExecution decode demo links upstream decode.final_logits receipt',
            Array.isArray(decode.latestReceipt?.decodeBoundary?.upstreamLinks) &&
              decode.latestReceipt.decodeBoundary.upstreamLinks[0]?.semanticOpId ===
                'decode.final_logits',
            JSON.stringify(decode.latestReceipt?.decodeBoundary?.upstreamLinks),
          );
          check(
            'ordinaryExecution decode demo keeps live token aligned with committed selection',
            decode.latestReceipt?.decodeBoundary?.liveSelectedMatchesCommittedSelection === true,
            JSON.stringify(decode.latestReceipt?.decodeBoundary),
          );
          check(
            'ordinaryExecution decode demo records a real selected-token change under sampled replay',
            decode.latestReceipt?.decodeBoundary?.metrics?.actualSelectedTokenChanged === true &&
              (
                decode.latestReceipt?.selectedToken?.fast !== decode.latestReceipt?.selectedToken?.stable ||
                decode.latestReceipt?.selectedToken?.fast !== decode.latestReceipt?.selectedToken?.reference
              ) &&
              decode.latestReceipt?.decodeBoundary?.liveSelectedToken ===
                decode.latestReceipt?.selectedToken?.fast,
            JSON.stringify({
              selectedToken: decode.latestReceipt?.selectedToken,
              metrics: decode.latestReceipt?.decodeBoundary?.metrics,
            }),
          );
        }
      } catch (err) {
        check('ordinaryExecution decode demo succeeds', false, err.message);
      }
    } else if (decodeCommandsPath) {
      console.log('  skip: ordinaryExecution decode demo (requires darwin metal lane)');
    } else {
      console.log('  skip: ordinaryExecution decode demo (example commands not found)');
    }
  }
} catch {
  // createDoeRuntime throws when doe-zig-runtime binary is not built/found.
  // This is expected in CI or before building the runtime — skip gracefully.
  console.log('  skip: createDoeRuntime (doe-zig-runtime binary not found)');
}

// ── Results ─────────────────────────────────────────────────────────────

console.log(`\nResults: ${passed} passed, ${failed} failed`);
process.exitCode = failed > 0 ? 1 : 0;

import { createHash } from 'node:crypto';
import { constants as fsConstants } from 'node:fs';
import { access } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

import {
  adapterUsesSoftwareRenderer,
  classifyVulkanSummary,
} from './hardware-identity.mjs';

function requireEnv(name) {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required.`);
  return value;
}

function sha256Bytes(value) {
  return createHash('sha256')
    .update(Buffer.from(value.buffer, value.byteOffset, value.byteLength))
    .digest('hex');
}

function percentile(values, fraction) {
  const sorted = [...values].sort((a, b) => a - b);
  if (sorted.length === 0) return 0;
  return sorted[Math.min(sorted.length - 1, Math.ceil(fraction * sorted.length) - 1)];
}

function summarize(values) {
  return {
    p50: percentile(values, 0.50),
    p95: percentile(values, 0.95),
    p99: percentile(values, 0.99),
  };
}

function adapterIdentity(adapter) {
  const info = adapter.info ?? {};
  return {
    vendor: String(info.vendor ?? 'unknown'),
    architecture: String(info.architecture ?? 'unknown'),
    device: String(info.device ?? 'unknown'),
    description: String(info.description ?? 'unknown'),
    isFallbackAdapter: Boolean(info.isFallbackAdapter),
  };
}

async function inspectLinuxRenderer() {
  if (process.platform !== 'linux') {
    return {
      probe: 'not-linux',
      renderNode: null,
      renderNodeReadWriteAccess: null,
      summaryLines: [],
      softwareRendererAvailable: false,
      physicalGpuAvailable: false,
      hardwareEligible: true,
    };
  }
  const renderNode = '/dev/dri/renderD128';
  let renderNodeReadWriteAccess = false;
  try {
    await access(renderNode, fsConstants.R_OK | fsConstants.W_OK);
    renderNodeReadWriteAccess = true;
  } catch {
    // Missing or inaccessible render nodes make hardware claims ineligible.
  }
  const probe = spawnSync('vulkaninfo', ['--summary'], {
    encoding: 'utf8',
    timeout: 10_000,
  });
  const output = `${probe.stdout ?? ''}\n${probe.stderr ?? ''}`;
  const classification = classifyVulkanSummary(
    output,
    probe.status === 0,
    renderNodeReadWriteAccess,
  );
  return {
    probe: probe.status === 0 ? 'vulkaninfo' : 'vulkaninfo-unavailable',
    renderNode,
    renderNodeReadWriteAccess,
    ...classification,
  };
}

function buildGraph(core, topology, n, rng) {
  if (topology.kind === 'erdos-renyi') {
    return core.erdosRenyiCsr(n, topology.probability, rng);
  }
  if (topology.kind === 'barabasi-albert') {
    return core.barabasiAlbertCsr(n, topology.edgesPerVertex, rng);
  }
  if (topology.kind === 'layered-neural') {
    return core.layeredNeuralCsr(n, topology.layers, topology.skipProbability, rng);
  }
  throw new Error(`Unknown topology kind ${topology.kind}.`);
}

const providerId = requireEnv('DOE_EXTERNAL_WEBGPU_PROVIDER');
const upstreamPackageDir = requireEnv('DOE_EXTERNAL_UPSTREAM_PACKAGE_DIR');
const upstreamCoreDir = requireEnv('DOE_EXTERNAL_UPSTREAM_CORE_DIR');
const inputPath = requireEnv('DOE_EXTERNAL_INPUT_PATH');
const receiptMode = process.env.DOE_EXTERNAL_RECEIPT_MODE ?? 'enabled';
if (!['enabled', 'untraced'].includes(receiptMode)) {
  throw new Error(`Unknown DOE_EXTERNAL_RECEIPT_MODE ${receiptMode}.`);
}
const receiptEnabled = receiptMode === 'enabled';
const inputs = JSON.parse(await readFile(inputPath, 'utf8'));

const providerModule = await import('webgpu');
const proofProviderIdentity = providerModule.__doeProofProviderIdentity;
const providerIdentity = providerModule.__doeHarnessProviderIdentity ?? (
  proofProviderIdentity
    ? Object.freeze({
        id: proofProviderIdentity.providerId,
        modulePath: proofProviderIdentity.resolvedProviderUrl,
        doeProof: proofProviderIdentity,
      })
    : null
);
if (providerIdentity?.id !== providerId) {
  throw new Error(
    `Provider substitution failed: expected ${providerId}, loaded ${providerIdentity?.id ?? 'unknown'}.`,
  );
}

const snn = await import(pathToFileURL(`${upstreamPackageDir}/dist/index.js`).href);
const core = await import(pathToFileURL(`${upstreamCoreDir}/dist/math/tropical-spmv.js`).href);
const shaderPath = `${upstreamPackageDir}/src/shaders/tropical-graph.wgsl`;
const shaderSource = await readFile(shaderPath);

const initializedAt = performance.now();
const ctx = new snn.GPUContext();
await ctx.initialize();
const initializationMs = performance.now() - initializedAt;
const identity = adapterIdentity(ctx.adapter);
const hostRenderer = await inspectLinuxRenderer();
const layoutTrace = [];
if (receiptEnabled) {
  const createBindGroupLayout = ctx.device.createBindGroupLayout.bind(ctx.device);
  ctx.device.createBindGroupLayout = (descriptor) => {
    layoutTrace.push(descriptor.entries.map((entry) => ({
      binding: entry.binding,
      bufferType: entry.buffer?.type ?? null,
    })));
    return createBindGroupLayout(descriptor);
  };
}

const tropical = new snn.TropicalShortestPaths(ctx, {
  preferGPU: true,
  sparseCpuThreshold: 1,
});
const rng = core.mulberry32(inputs.seed);
const topologyResults = [];
let peakMemoryBytes = process.resourceUsage().maxRSS * 1024;
const workloadStartedAt = performance.now();

try {
  for (const topology of inputs.topologies) {
    const graph = buildGraph(core, topology, inputs.nodeCount, rng);
    const dist = new Float32Array(inputs.nodeCount).fill(core.TROPICAL_INF);
    dist[0] = 0;
    const oracle = new Float32Array(inputs.nodeCount);
    core.tropicalMinPlusSpmv(graph, dist, oracle);
    const oracleHash = receiptEnabled ? sha256Bytes(oracle) : null;

    const coldStartedAt = performance.now();
    const coldOutput = await tropical.tropicalSpmv(graph, dist);
    const coldMs = performance.now() - coldStartedAt;
    const coldDiff = core.maxAbsDiff(coldOutput, oracle);
    if (!(coldDiff < inputs.tolerance)) {
      const mismatchIndices = [];
      for (let index = 0; index < oracle.length && mismatchIndices.length < 32; index += 1) {
        if (oracle[index] !== coldOutput[index]) mismatchIndices.push(index);
      }
      throw new Error(
        `${topology.id} cold oracle mismatch: ${coldDiff}; ` +
        `expected=${JSON.stringify([...oracle.slice(0, 16)])}; ` +
        `actual=${JSON.stringify([...coldOutput.slice(0, 16)])}; ` +
        `mismatchIndices=${JSON.stringify(mismatchIndices)}; ` +
        `layouts=${JSON.stringify(layoutTrace)}.`,
      );
    }

    for (let run = 1; run < inputs.warmupRuns; run += 1) {
      const warmupOutput = await tropical.tropicalSpmv(graph, dist);
      const diff = core.maxAbsDiff(warmupOutput, oracle);
      if (!(diff < inputs.tolerance)) {
        throw new Error(`${topology.id} warmup ${run} oracle mismatch: ${diff}.`);
      }
    }

    const warmSamplesMs = [];
    const outputHashes = [];
    let maxDiff = coldDiff;
    for (let run = 0; run < inputs.measuredRuns; run += 1) {
      const startedAt = performance.now();
      const output = await tropical.tropicalSpmv(graph, dist);
      warmSamplesMs.push(performance.now() - startedAt);
      const diff = core.maxAbsDiff(output, oracle);
      maxDiff = Math.max(maxDiff, diff);
      if (!(diff < inputs.tolerance)) {
        throw new Error(`${topology.id} measured run ${run} oracle mismatch: ${diff}.`);
      }
      if (receiptEnabled) outputHashes.push(sha256Bytes(output));
      peakMemoryBytes = Math.max(peakMemoryBytes, process.resourceUsage().maxRSS * 1024);
    }

    const uniqueOutputHashes = [...new Set(outputHashes)];
    if (receiptEnabled && (uniqueOutputHashes.length !== 1 || uniqueOutputHashes[0] !== oracleHash)) {
      throw new Error(
        `${topology.id} output identity mismatch: oracle=${oracleHash}, outputs=${uniqueOutputHashes.join(',')}.`,
      );
    }

    topologyResults.push({
      id: topology.id,
      nnz: graph.values.length,
      oracleHash,
      outputHash: uniqueOutputHashes[0] ?? null,
      maxDiff,
      coldMs,
      warmSamplesMs,
      warm: summarize(warmSamplesMs),
    });
  }
} finally {
  tropical.destroy();
  ctx.destroy();
}
const workloadElapsedMs = performance.now() - workloadStartedAt;

const allWarmSamples = topologyResults.flatMap((result) => result.warmSamplesMs);
const result = {
  schemaVersion: 1,
  artifactKind: 'holoscript-tropical-spmv-run',
  provider: providerIdentity,
  adapter: identity,
  hostRenderer,
  hostFallbackDetected: adapterUsesSoftwareRenderer(identity),
  hardwareEligible: !adapterUsesSoftwareRenderer(identity) && hostRenderer.hardwareEligible,
  receipt: {
    mode: receiptMode,
    workloadElapsedMs,
  },
  shader: {
    path: 'packages/snn-webgpu/src/shaders/tropical-graph.wgsl',
    sha256: createHash('sha256').update(shaderSource).digest('hex'),
    entryPoint: 'tropical_spmv',
  },
  dispatch: {
    workgroups: [Math.ceil(inputs.nodeCount / 256), 1, 1],
    workgroupSize: [256, 1, 1],
  },
  synchronization: 'queue.submit, queue.onSubmittedWorkDone, copyBufferToBuffer, mapAsync(READ)',
  readback: 'Float32Array over a mapped staging-buffer copy',
  layoutTrace,
  oracle: {
    implementation: '@holoscript/core/math/tropical-spmv',
    tolerance: inputs.tolerance,
  },
  initializationMs,
  cold: summarize(topologyResults.map((result) => result.coldMs)),
  warm: summarize(allWarmSamples),
  peakMemoryBytes,
  topologies: topologyResults,
};

process.stdout.write(`${JSON.stringify(result)}\n`);

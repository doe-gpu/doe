import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { constants as fsConstants } from 'node:fs';
import { access, readFile } from 'node:fs/promises';
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

function sha256(view) {
  return createHash('sha256')
    .update(Buffer.from(view.buffer, view.byteOffset, view.byteLength))
    .digest('hex');
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
  const renderNode = '/dev/dri/renderD128';
  let renderNodeReadWriteAccess = false;
  try {
    await access(renderNode, fsConstants.R_OK | fsConstants.W_OK);
    renderNodeReadWriteAccess = true;
  } catch {
    // Missing or inaccessible render nodes make hardware evidence ineligible.
  }
  const probe = spawnSync('vulkaninfo', ['--summary'], {
    encoding: 'utf8',
    timeout: 10_000,
  });
  const output = `${probe.stdout ?? ''}\n${probe.stderr ?? ''}`;
  return {
    probe: probe.status === 0 ? 'vulkaninfo' : 'vulkaninfo-unavailable',
    renderNode,
    renderNodeReadWriteAccess,
    ...classifyVulkanSummary(output, probe.status === 0, renderNodeReadWriteAccess),
  };
}

function compareTwin(cpuMembrane, gpuMembrane, cpuSpikes, gpuSpikes) {
  let maxAbsDiff = 0;
  let maxRelDiff = 0;
  let spikeMismatches = 0;
  for (let index = 0; index < cpuMembrane.length; index += 1) {
    const absDiff = Math.abs(cpuMembrane[index] - gpuMembrane[index]);
    const relDiff = absDiff / (Math.abs(cpuMembrane[index]) + 1e-6);
    maxAbsDiff = Math.max(maxAbsDiff, absDiff);
    maxRelDiff = Math.max(maxRelDiff, relDiff);
    if (cpuSpikes[index] !== gpuSpikes[index]) spikeMismatches += 1;
  }
  return { maxAbsDiff, maxRelDiff, spikeMismatches };
}

const providerId = requireEnv('DOE_EXTERNAL_WEBGPU_PROVIDER');
const packageDir = requireEnv('DOE_EXTERNAL_UPSTREAM_PACKAGE_DIR');
const inputPath = requireEnv('DOE_EXTERNAL_INPUT_PATH');
const receiptMode = process.env.DOE_EXTERNAL_RECEIPT_MODE ?? 'enabled';
if (!['enabled', 'untraced'].includes(receiptMode)) {
  throw new Error(`Unknown DOE_EXTERNAL_RECEIPT_MODE ${receiptMode}.`);
}

const providerModule = await import('webgpu');
const providerIdentity = providerModule.__doeHarnessProviderIdentity;
if (providerIdentity?.id !== providerId) {
  throw new Error(
    `Provider substitution failed: expected ${providerId}, loaded `
    + `${providerIdentity?.id ?? 'unknown'}.`,
  );
}

const inputs = JSON.parse(await readFile(inputPath, 'utf8'));
const snn = await import(pathToFileURL(`${packageDir}/dist/index.js`).href);
const shaderPath = `${packageDir}/src/shaders/lif-neuron.wgsl`;
const shaderSha256 = createHash('sha256')
  .update(await readFile(shaderPath))
  .digest('hex');
const context = new snn.GPUContext();
await context.initialize();
const adapter = adapterIdentity(context.adapter);
const hostRenderer = await inspectLinuxRenderer();
const caseResults = [];

try {
  for (const testCase of inputs.cases) {
    const stimulus = snn.generateSynapticInput(
      testCase.neuronCount,
      testCase.stimulusSeed,
      testCase.stimulusMin,
      testCase.stimulusMax,
    );
    const cpu = new snn.CPUReferenceSimulator(
      testCase.neuronCount,
      testCase.params,
    );
    cpu.stepN(testCase.tickCount, stimulus);

    const gpu = new snn.LIFSimulator(
      context,
      testCase.neuronCount,
      testCase.params,
    );
    try {
      await gpu.initialize();
      gpu.resetState();
      gpu.setSynapticInput(stimulus);
      await gpu.stepN(testCase.tickCount);
      const gpuMembrane = (await gpu.readMembranePotentials()).data;
      const gpuSpikes = (await gpu.readSpikes()).data;
      const cpuMembrane = cpu.getMembraneV();
      const cpuSpikes = cpu.getSpikes();
      const delta = compareTwin(cpuMembrane, gpuMembrane, cpuSpikes, gpuSpikes);
      caseResults.push({
        ...testCase,
        delta,
        oraclePass: delta.maxAbsDiff < inputs.absoluteTolerance
          && delta.maxRelDiff < inputs.relativeTolerance
          && delta.spikeMismatches === 0,
        cpuMembraneSha256: sha256(cpuMembrane),
        gpuMembraneSha256: sha256(gpuMembrane),
        cpuSpikesSha256: sha256(cpuSpikes),
        gpuSpikesSha256: sha256(gpuSpikes),
        gpuMemoryBytes: gpu.gpuMemoryBytes,
      });
    } finally {
      gpu.destroy();
    }
  }

  const repeatHashes = [];
  for (let index = 0; index < 3; index += 1) {
    const bytes = await snn.runLIFDeterminismProbe(
      context,
      snn.PAPER_2_CANONICAL_CONFIG,
    );
    repeatHashes.push(sha256(bytes));
  }
  const seedVariant = await snn.runLIFDeterminismProbe(context, {
    ...snn.PAPER_2_CANONICAL_CONFIG,
    stimulusSeed: 43,
  });
  const tickVariant = await snn.runLIFDeterminismProbe(context, {
    ...snn.PAPER_2_CANONICAL_CONFIG,
    tickCount: 10,
  });
  const uniqueRepeatHashes = [...new Set(repeatHashes)];
  const nondegenerate = uniqueRepeatHashes.length === 1
    && sha256(seedVariant) !== repeatHashes[0]
    && sha256(tickVariant) !== repeatHashes[0];
  const allCasesPass = caseResults.every((result) => result.oraclePass);
  const result = {
    schemaVersion: 1,
    artifactKind: 'holoscript-lif-determinism-run',
    provider: providerIdentity,
    adapter,
    hostRenderer,
    hardwareEligible: !adapterUsesSoftwareRenderer(adapter)
      && hostRenderer.hardwareEligible,
    receiptMode,
    shader: {
      path: 'packages/snn-webgpu/src/shaders/lif-neuron.wgsl',
      sha256: shaderSha256,
      entryPoint: 'lif_step',
    },
    dispatch: {
      workgroupSize: [256, 1, 1],
      cases: caseResults.map((result) => ({
        id: result.id,
        workgroups: [Math.ceil(result.neuronCount / 256), 1, 1],
        dispatches: result.tickCount,
      })),
    },
    synchronization: 'one queue.submit plus queue.onSubmittedWorkDone per tick',
    readback: 'membrane Float32Array and spike Float32Array via mapped staging copies',
    oracle: {
      implementation: '@holoscript/snn-webgpu CPUReferenceSimulator',
      absoluteTolerance: inputs.absoluteTolerance,
      relativeTolerance: inputs.relativeTolerance,
      exactSpikeMask: true,
    },
    cases: caseResults,
    sameBackendDeterminism: {
      repeatCount: repeatHashes.length,
      repeatHashes,
      uniqueHashCount: uniqueRepeatHashes.length,
      seedVariantSha256: sha256(seedVariant),
      tickVariantSha256: sha256(tickVariant),
      nondegenerate,
    },
    peakMemoryBytes: process.resourceUsage().maxRSS * 1024,
    passed: allCasesPass && nondegenerate,
  };
  process.stdout.write(`${JSON.stringify(result)}\n`);
  if (!result.passed || !result.hardwareEligible) process.exitCode = 1;
} finally {
  context.destroy();
}

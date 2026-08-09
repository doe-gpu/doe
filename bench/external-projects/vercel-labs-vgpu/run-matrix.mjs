#!/usr/bin/env node

import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { constants as fsConstants } from 'node:fs';
import { access, mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const harnessDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(harnessDir, '../../..');
const defaultUpstream = resolve(
  repoRoot,
  'bench/out/external-projects/vercel-labs-vgpu/upstream',
);
const expectedCommit = '86f2cadbd7a087f1695d736a12e218ab1ea2fc63';
const expectedModelSha256 = '7764d8e16dff9245360a3dccbdbe7c545ccf52ddfcf0b22e0ef14f15d803e692';

function parseArgs(argv) {
  const options = {
    upstream: defaultUpstream,
    runId: new Date().toISOString().replaceAll(':', '').replaceAll('.', ''),
    cleanProcessRuns: 3,
    timeoutMs: 120_000,
    requireAllPass: false,
    preparationReceipt: null,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === '--upstream') options.upstream = resolve(argv[++index]);
    else if (value === '--run-id') options.runId = argv[++index];
    else if (value === '--clean-process-runs') {
      options.cleanProcessRuns = Number.parseInt(argv[++index], 10);
    } else if (value === '--timeout-ms') {
      options.timeoutMs = Number.parseInt(argv[++index], 10);
    } else if (value === '--preparation-receipt') {
      options.preparationReceipt = resolve(argv[++index]);
    } else if (value === '--require-all-pass') options.requireAllPass = true;
    else throw new Error(`unknown argument: ${value}`);
  }
  if (!Number.isInteger(options.cleanProcessRuns) || options.cleanProcessRuns < 1) {
    throw new Error('--clean-process-runs must be a positive integer');
  }
  if (!Number.isInteger(options.timeoutMs) || options.timeoutMs < 1) {
    throw new Error('--timeout-ms must be a positive integer');
  }
  if (!/^[A-Za-z0-9._-]+$/.test(options.runId)) {
    throw new Error('--run-id must contain only letters, numbers, dot, underscore, or hyphen');
  }
  return options;
}

async function sha256(path) {
  return createHash('sha256').update(await readFile(path)).digest('hex');
}

async function readPreparationEvidence(path) {
  if (path === null) return null;
  const relativePath = path.startsWith(`${repoRoot}/`)
    ? path.slice(repoRoot.length + 1)
    : null;
  if (relativePath === null) {
    throw new Error(`preparation receipt escapes repository root: ${path}`);
  }
  const receipt = JSON.parse(await readFile(path, 'utf8'));
  if (receipt.artifactKind !== 'external-project-preparation-receipt') {
    throw new Error('preparation receipt has the wrong artifact kind');
  }
  if (receipt.actorId !== 'vercel-labs-vgpu' || receipt.harnessId !== 'node-ort-snapshot') {
    throw new Error('preparation receipt actor or harness identity does not match');
  }
  if (receipt.status !== 'passed' || receipt.hardware?.status !== 'passed') {
    throw new Error('preparation receipt does not prove a passing physical hardware probe');
  }
  if (receipt.source?.actualCommit !== expectedCommit) {
    throw new Error('preparation receipt upstream commit does not match');
  }
  return {
    path: relativePath,
    sha256: await sha256(path),
    receiptSha256: receipt.receiptSha256,
    sourceCommit: receipt.source.actualCommit,
    hardwareStatus: receipt.hardware.status,
    hardwareProbe: {
      id: receipt.hardware.probe.id,
      stdoutPath: receipt.hardware.probe.stdoutPath,
      stdoutSha256: receipt.hardware.probe.stdoutSha256,
      stderrPath: receipt.hardware.probe.stderrPath,
      stderrSha256: receipt.hardware.probe.stderrSha256,
    },
    supportTarget: receipt.supportTarget,
    runtimeArtifacts: receipt.artifacts,
  };
}

function sha256Text(value) {
  return createHash('sha256').update(value).digest('hex');
}

async function runProcess(command, args, { cwd, env, timeoutMs }) {
  const started = process.hrtime.bigint();
  const child = spawn(command, args, { cwd, env, stdio: ['ignore', 'pipe', 'pipe'] });
  let stdout = '';
  let stderr = '';
  let peakMemoryBytes = 0;
  let timedOut = false;
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', (chunk) => { stdout += chunk; });
  child.stderr.on('data', (chunk) => { stderr += chunk; });
  const memoryPoll = setInterval(async () => {
    try {
      const status = await readFile(`/proc/${child.pid}/status`, 'utf8');
      const match = /^VmHWM:\s+(\d+)\s+kB$/m.exec(status);
      if (match) peakMemoryBytes = Math.max(peakMemoryBytes, Number(match[1]) * 1024);
    } catch {
      // Process exit races with /proc reads; retain the last observed high-water mark.
    }
  }, 10);
  const timeout = setTimeout(() => {
    timedOut = true;
    child.kill('SIGKILL');
  }, timeoutMs);
  const result = await new Promise((resolveResult, reject) => {
    child.once('error', reject);
    child.once('exit', (exitCode, signal) => resolveResult({ exitCode, signal }));
  });
  clearTimeout(timeout);
  clearInterval(memoryPoll);
  return {
    ...result,
    timedOut,
    crashed: !timedOut && result.signal !== null,
    durationMs: Number(process.hrtime.bigint() - started) / 1e6,
    peakMemoryBytes,
    stdout: stdout.slice(-32_768),
    stderr: stderr.slice(-32_768),
  };
}

async function inspectHostHardware() {
  let renderNodes = [];
  try {
    renderNodes = (await readdir('/dev/dri'))
      .filter((name) => name.startsWith('renderD'))
      .map((name) => `/dev/dri/${name}`);
  } catch {
    return { renderNodes, accessibleRenderNodes: [], physicalGpuEligible: false };
  }
  const accessibleRenderNodes = [];
  for (const path of renderNodes) {
    try {
      await access(path, fsConstants.R_OK | fsConstants.W_OK);
      accessibleRenderNodes.push(path);
    } catch {
      // Listed but inaccessible devices cannot support hardware evidence.
    }
  }
  return {
    renderNodes,
    accessibleRenderNodes,
    physicalGpuEligible: accessibleRenderNodes.length > 0,
  };
}

function providerEnvironment(provider, modules) {
  return {
    ...process.env,
    DOE_EXTERNAL_WEBGPU_PROVIDER: provider,
    DOE_EXTERNAL_DAWN_MODULE: modules.dawn,
    DOE_EXTERNAL_DOE_MODULE: modules.doe,
    DOE_EXTERNAL_TYPESCRIPT_MODULE: modules.typescript,
  };
}

async function probeProvider(options, experimentRoot, provider, modules, hostHardware) {
  const result = await runProcess(
    process.execPath,
    [
      '--no-warnings',
      '--experimental-loader',
      resolve(harnessDir, 'provider-loader.mjs'),
      resolve(harnessDir, 'probe-provider.mjs'),
    ],
    {
      cwd: experimentRoot,
      env: providerEnvironment(provider, modules),
      timeoutMs: options.timeoutMs,
    },
  );
  const marker = result.stdout
    .split('\n')
    .find((line) => line.startsWith('DOE_VGPU_PROVIDER_PROBE='));
  let identity = null;
  try {
    if (marker) identity = JSON.parse(marker.slice(marker.indexOf('=') + 1));
  } catch {
    identity = null;
  }
  const identityText = JSON.stringify(identity ?? {}).toLowerCase();
  const softwareRenderer = /llvmpipe|swiftshader|software renderer|software-renderer/.test(identityText);
  const identityMatches = identity?.provider?.id === provider;
  return {
    ...result,
    identity,
    identityMatches,
    softwareRenderer,
    hardwareEligible: result.exitCode === 0
      && identityMatches
      && !softwareRenderer
      && hostHardware.physicalGpuEligible,
  };
}

async function runCompatibilityRepro(options, experimentRoot, provider, modules) {
  const result = await runProcess(
    process.execPath,
    [
      '--no-warnings',
      '--experimental-loader',
      resolve(harnessDir, 'provider-loader.mjs'),
      resolve(harnessDir, 'repro-onuncapturederror.mjs'),
    ],
    {
      cwd: experimentRoot,
      env: providerEnvironment(provider, modules),
      timeoutMs: options.timeoutMs,
    },
  );
  const marker = result.stdout
    .split('\n')
    .find((line) => line.startsWith('DOE_VGPU_COMPATIBILITY_REPRO='));
  let evidence = null;
  try {
    if (marker) evidence = JSON.parse(marker.slice(marker.indexOf('=') + 1));
  } catch {
    evidence = null;
  }
  return {
    ...result,
    evidence,
    success: result.exitCode === 0
      && !result.timedOut
      && !result.crashed
      && evidence?.setterAccepted === true,
  };
}

function upstreamPass(evidence) {
  return evidence?.status === 'PASS'
    && Object.keys(evidence.assertions ?? {}).length > 0
    && Object.values(evidence.assertions).every(Boolean);
}

async function runWorkload(options, experimentRoot, outDir, provider, index, modules) {
  const processDir = resolve(outDir, 'processes', provider, String(index + 1));
  const evidenceDir = resolve(processDir, 'evidence');
  const cacheDir = resolve(processDir, 'cache');
  const runtimeDir = resolve(
    repoRoot,
    'bench/out/.xdg',
    sha256Text(outDir).slice(0, 8),
    provider === 'dawn-node-webgpu' ? 'dawn' : 'doe',
    String(index + 1),
  );
  await Promise.all([
    mkdir(evidenceDir, { recursive: true }),
    mkdir(cacheDir, { recursive: true }),
    mkdir(runtimeDir, { recursive: true }),
  ]);
  const result = await runProcess(
    process.execPath,
    [
      '--no-warnings',
      '--experimental-loader',
      resolve(harnessDir, 'provider-loader.mjs'),
      resolve(experimentRoot, 'node/run.ts'),
    ],
    {
      cwd: experimentRoot,
      env: {
        ...providerEnvironment(provider, modules),
        ORT_EVIDENCE_DIR: evidenceDir,
        VGPU_CACHE_DIR: cacheDir,
        XDG_RUNTIME_DIR: runtimeDir,
      },
      timeoutMs: options.timeoutMs,
    },
  );
  let upstreamEvidence = null;
  let evidenceReadError = '';
  try {
    upstreamEvidence = JSON.parse(await readFile(resolve(evidenceDir, 'node.json'), 'utf8'));
  } catch (error) {
    evidenceReadError = String(error?.message ?? error);
  }
  const success = result.exitCode === 0
    && !result.timedOut
    && !result.crashed
    && upstreamPass(upstreamEvidence);
  return {
    provider,
    cleanProcessIndex: index + 1,
    success,
    ...result,
    evidenceReadError,
    upstreamEvidence,
  };
}

function percentile(values, fraction) {
  const sorted = [...values].sort((left, right) => left - right);
  if (sorted.length === 0) return 0;
  return sorted[Math.min(sorted.length - 1, Math.ceil(fraction * sorted.length) - 1)];
}

function summarize(runs) {
  const durations = runs.map((run) => run.durationMs);
  return {
    cleanProcessRuns: runs.length,
    successes: runs.filter((run) => run.success).length,
    failures: runs.filter((run) => !run.success).length,
    crashes: runs.filter((run) => run.crashed).length,
    hangs: runs.filter((run) => run.timedOut).length,
    timeouts: runs.filter((run) => run.timedOut).length,
    peakMemoryBytes: Math.max(0, ...runs.map((run) => run.peakMemoryBytes)),
    cleanProcessLatencyMs: {
      p50: percentile(durations, 0.50),
      p95: percentile(durations, 0.95),
      p99: percentile(durations, 0.99),
    },
  };
}

function extractWgsl(pipelineSource) {
  const match = /const WGSL = `([\s\S]*?)`;/m.exec(pipelineSource);
  if (!match) throw new Error('could not locate the upstream WGSL constant');
  return match[1];
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const experimentRoot = resolve(options.upstream, 'experiments/ort-init-device');
  const outDir = resolve(
    repoRoot,
    'bench/out/external-projects/vercel-labs-vgpu',
    options.runId,
  );
  await mkdir(outDir, { recursive: true });

  const gitResult = await runProcess('git', ['rev-parse', 'HEAD'], {
    cwd: options.upstream,
    env: process.env,
    timeoutMs: options.timeoutMs,
  });
  const commit = gitResult.stdout.trim();
  if (commit !== expectedCommit) throw new Error(`unexpected vgpu commit: ${commit}`);

  const modelPath = resolve(experimentRoot, 'fixtures/models/identity-1x1x4x4.onnx');
  const pipelinePath = resolve(experimentRoot, 'shared/pipeline.ts');
  const workloadPath = resolve(experimentRoot, 'node/run.ts');
  const modelSha256 = await sha256(modelPath);
  if (modelSha256 !== expectedModelSha256) {
    throw new Error(`unexpected ONNX model hash: ${modelSha256}`);
  }
  const pipelineSource = await readFile(pipelinePath, 'utf8');
  const wgsl = extractWgsl(pipelineSource);
  const immutableInputs = {
    model: { path: 'experiments/ort-init-device/fixtures/models/identity-1x1x4x4.onnx', sha256: modelSha256 },
    workload: { path: 'experiments/ort-init-device/node/run.ts', sha256: await sha256(workloadPath) },
    pipeline: { path: 'experiments/ort-init-device/shared/pipeline.ts', sha256: await sha256(pipelinePath) },
    shader: { source: 'WGSL constant in shared/pipeline.ts', sha256: sha256Text(wgsl) },
    compatibilityRepro: {
      path: 'bench/external-projects/vercel-labs-vgpu/repro-onuncapturederror.mjs',
      sha256: await sha256(resolve(harnessDir, 'repro-onuncapturederror.mjs')),
    },
  };
  const preparationEvidence = await readPreparationEvidence(options.preparationReceipt);
  const modules = {
    dawn: resolve(experimentRoot, 'node_modules/webgpu/index.js'),
    doe: resolve(repoRoot, 'packages/doe-gpu/src/index.js'),
    typescript: resolve(experimentRoot, 'node_modules/typescript/lib/typescript.js'),
  };
  await Promise.all(Object.values(modules).map((modulePath) => access(modulePath)));

  const hostHardware = await inspectHostHardware();
  const providerIds = ['dawn-node-webgpu', 'doe-gpu'];
  const providers = {};
  for (const provider of providerIds) {
    const probe = await probeProvider(options, experimentRoot, provider, modules, hostHardware);
    const compatibilityRepro = await runCompatibilityRepro(
      options,
      experimentRoot,
      provider,
      modules,
    );
    const runs = [];
    for (let index = 0; index < options.cleanProcessRuns; index += 1) {
      const run = await runWorkload(options, experimentRoot, outDir, provider, index, modules);
      runs.push(run);
      process.stdout.write(`[${provider}] process ${index + 1}: ${run.success ? 'PASS' : 'FAIL'}\n`);
    }
    providers[provider] = { probe, compatibilityRepro, summary: summarize(runs), runs };
  }

  const generatedAt = new Date().toISOString();
  const raw = {
    schemaVersion: 1,
    artifactKind: 'vgpu-node-ort-snapshot-matrix',
    generatedAt,
    actorId: 'vercel-labs-vgpu',
    harnessId: 'node-ort-snapshot',
    upstream: {
      repositoryUrl: 'https://github.com/vercel-labs/vgpu',
      commit,
      licenseIdentifier: 'MIT',
    },
    host: {
      platform: process.platform,
      architecture: process.arch,
      node: process.version,
      ...hostHardware,
    },
    providerSubstitution: {
      seam: 'ESM resolution of webgpu only',
      applicationSourceUnchanged: true,
      shaderSourceUnchanged: true,
      modules,
    },
    immutableInputs,
    preparationReceipt: preparationEvidence,
    providers,
  };
  raw.sha256 = sha256Text(JSON.stringify(raw));

  const outputIdentity = {};
  for (const provider of providerIds) {
    outputIdentity[provider] = providers[provider].runs.map((run) => ({
      cleanProcessIndex: run.cleanProcessIndex,
      status: run.upstreamEvidence?.status ?? 'NO-EVIDENCE',
      assertions: run.upstreamEvidence?.assertions ?? null,
      snapshot: run.upstreamEvidence?.snapshot ?? null,
      reference: run.upstreamEvidence?.reference ?? null,
      errors: run.upstreamEvidence?.errors ?? [],
    }));
  }
  const receiptSummary = {
    schemaVersion: 1,
    artifactKind: 'vgpu-node-ort-snapshot-receipt-summary',
    generatedAt,
    upstream: raw.upstream,
    host: raw.host,
    providers: Object.fromEntries(providerIds.map((provider) => [provider, {
      requestedProvider: provider,
      identity: providers[provider].probe.identity,
      identityMatches: providers[provider].probe.identityMatches,
      softwareRenderer: providers[provider].probe.softwareRenderer,
      hardwareEligible: providers[provider].probe.hardwareEligible,
      compatibilityRepro: providers[provider].compatibilityRepro,
      reliability: providers[provider].summary,
    }])),
    shader: immutableInputs.shader,
    preparationReceipt: preparationEvidence,
    dispatchShape: {
      workgroupSize: [16, 1, 1],
      workgroups: [1, 1, 1],
      invocations: 16,
      modes: ['snapshot', 'reference'],
    },
    synchronization: 'vgpu device queue flush after consumer dispatch',
    readback: 'destination Buffer.read(64) after queue flush',
    outputIdentity,
    diagnosis: {
      firstDoeFailure: providers['doe-gpu'].runs.find((run) => !run.success) ?? null,
    },
  };

  const rawPath = resolve(outDir, 'raw-matrix.json');
  const receiptPath = resolve(outDir, 'receipt-summary.json');
  await writeFile(rawPath, `${JSON.stringify(raw, null, 2)}\n`);
  await writeFile(receiptPath, `${JSON.stringify(receiptSummary, null, 2)}\n`);
  process.stdout.write(`WROTE ${rawPath}\nWROTE ${receiptPath}\n`);

  const allPass = providerIds.every((provider) => (
    providers[provider].compatibilityRepro.success
    && providers[provider].summary.failures === 0
  ));
  if (options.requireAllPass && !allPass) process.exitCode = 1;
}

await main();

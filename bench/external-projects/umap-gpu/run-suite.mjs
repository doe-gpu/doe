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
  'bench/out/external-projects/umap-gpu/upstream',
);
const expectedCommit = '7884b287f49bc057df7e0856c5539f130a20e0ad';
const expectedAssertions = [
  'all embedding values are finite (no NaN or Inf)',
  'embedding is not collapsed (points have non-trivial spread)',
  'kNN graph only carries within-cluster edges (precondition)',
  'every point is closer to its own cluster centroid than to the other cluster centroid',
  'mean intra-cluster distance is much less than mean inter-cluster distance',
  'nearest neighbour in embedding belongs to the same cluster for every point',
  'GPU: edges do not fire at epoch 0 — epoch_of_next_sample is deferred',
  'GPU: edges fire on the second epoch after initialisation',
];

function parseArgs(argv) {
  const options = {
    upstream: defaultUpstream,
    runId: new Date().toISOString().replaceAll(':', '').replaceAll('.', ''),
    cleanProcessRuns: 3,
    timeoutMs: 120_000,
    requireAllPass: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === '--upstream') options.upstream = resolve(argv[++index]);
    else if (value === '--run-id') options.runId = argv[++index];
    else if (value === '--clean-process-runs') {
      options.cleanProcessRuns = Number.parseInt(argv[++index], 10);
    } else if (value === '--timeout-ms') {
      options.timeoutMs = Number.parseInt(argv[++index], 10);
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
      // Listed but inaccessible render nodes cannot support hardware evidence.
    }
  }
  return {
    renderNodes,
    accessibleRenderNodes,
    physicalGpuEligible: accessibleRenderNodes.length > 0,
  };
}

function providerEnvironment(provider, modulePath, upstreamRoot, runtimeDir) {
  return {
    ...process.env,
    DOE_EXTERNAL_WEBGPU_PROVIDER: provider,
    DOE_EXTERNAL_PROVIDER_MODULE: modulePath,
    DOE_EXTERNAL_UPSTREAM_ROOT: upstreamRoot,
    XDG_RUNTIME_DIR: runtimeDir,
  };
}

async function probeProvider(options, provider, modulePath, outDir, hostHardware) {
  const runtimeDir = resolve(
    repoRoot,
    'bench/out/.xdg',
    sha256Text(outDir).slice(0, 8),
    provider === 'dawn-node-webgpu' ? 'umap-dawn-probe' : 'umap-doe-probe',
  );
  await mkdir(runtimeDir, { recursive: true });
  const result = await runProcess(
    process.execPath,
    [resolve(harnessDir, 'provider-probe.mjs')],
    {
      cwd: options.upstream,
      env: providerEnvironment(provider, modulePath, options.upstream, runtimeDir),
      timeoutMs: options.timeoutMs,
    },
  );
  const marker = result.stdout
    .split('\n')
    .find((line) => line.startsWith('DOE_UMAP_PROVIDER_PROBE='));
  let identity = null;
  try {
    if (marker) identity = JSON.parse(marker.slice(marker.indexOf('=') + 1));
  } catch {
    identity = null;
  }
  const identityText = JSON.stringify(identity ?? {}).toLowerCase();
  const softwareRenderer = /llvmpipe|swiftshader|software renderer|software-renderer/.test(identityText);
  const identityMatches = identity?.provider?.id === provider
    && identity?.provider?.modulePath === modulePath;
  return {
    ...result,
    identity,
    identityMatches,
    softwareRenderer,
    hardwareEligible: result.exitCode === 0
      && identityMatches
      && identity?.adapter !== null
      && !softwareRenderer
      && hostHardware.physicalGpuEligible,
  };
}

function normalizeAssertions(report) {
  return (report?.testResults ?? [])
    .flatMap((suite) => suite.assertionResults ?? [])
    .map((assertion) => ({ title: assertion.title, status: assertion.status }))
    .sort((left, right) => left.title.localeCompare(right.title));
}

function oraclePass(report, assertions) {
  const titles = assertions.map((assertion) => assertion.title);
  const titleSet = new Set(titles);
  return report?.success === true
    && report.numTotalTests === expectedAssertions.length
    && report.numPassedTests === expectedAssertions.length
    && report.numFailedTests === 0
    && assertions.every((assertion) => assertion.status === 'passed')
    && titleSet.size === expectedAssertions.length
    && expectedAssertions.every((title) => titleSet.has(title));
}

async function runSuite(options, provider, modulePath, outDir, index) {
  const processDir = resolve(outDir, 'processes', provider, String(index + 1));
  const runtimeDir = resolve(
    repoRoot,
    'bench/out/.xdg',
    sha256Text(outDir).slice(0, 8),
    provider === 'dawn-node-webgpu' ? 'umap-dawn' : 'umap-doe',
    String(index + 1),
  );
  await Promise.all([
    mkdir(processDir, { recursive: true }),
    mkdir(runtimeDir, { recursive: true }),
  ]);
  const reportPath = resolve(processDir, 'vitest.json');
  const result = await runProcess(
    process.execPath,
    [
      resolve(options.upstream, 'node_modules/vitest/vitest.mjs'),
      'run',
      'src/__tests__/umap-output-gpu.test.ts',
      '--config',
      resolve(harnessDir, 'vitest-provider.config.mjs'),
      '--reporter=json',
      `--outputFile=${reportPath}`,
    ],
    {
      cwd: options.upstream,
      env: providerEnvironment(provider, modulePath, options.upstream, runtimeDir),
      timeoutMs: options.timeoutMs,
    },
  );
  let vitestReport = null;
  let reportReadError = '';
  try {
    vitestReport = JSON.parse(await readFile(reportPath, 'utf8'));
  } catch (error) {
    reportReadError = String(error?.message ?? error);
  }
  const assertions = normalizeAssertions(vitestReport);
  const success = result.exitCode === 0
    && !result.timedOut
    && !result.crashed
    && oraclePass(vitestReport, assertions);
  return {
    provider,
    cleanProcessIndex: index + 1,
    success,
    ...result,
    reportReadError,
    vitestSummary: vitestReport ? {
      success: vitestReport.success,
      numTotalTests: vitestReport.numTotalTests,
      numPassedTests: vitestReport.numPassedTests,
      numFailedTests: vitestReport.numFailedTests,
      numPendingTests: vitestReport.numPendingTests,
    } : null,
    assertions,
    assertionIdentitySha256: sha256Text(JSON.stringify(assertions)),
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

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const outDir = resolve(repoRoot, 'bench/out/external-projects/umap-gpu', options.runId);
  await mkdir(outDir, { recursive: true });
  const gitResult = await runProcess('git', ['rev-parse', 'HEAD'], {
    cwd: options.upstream,
    env: process.env,
    timeoutMs: options.timeoutMs,
  });
  const commit = gitResult.stdout.trim();
  if (commit !== expectedCommit) throw new Error(`unexpected umap-gpu commit: ${commit}`);

  const modules = {
    'dawn-node-webgpu': resolve(options.upstream, 'node_modules/webgpu/index.js'),
    'doe-gpu': resolve(repoRoot, 'packages/doe-gpu/src/index.js'),
  };
  await Promise.all(Object.values(modules).map((path) => access(path)));
  const immutableInputs = {
    oracleTest: {
      path: 'src/__tests__/umap-output-gpu.test.ts',
      sha256: await sha256(resolve(options.upstream, 'src/__tests__/umap-output-gpu.test.ts')),
    },
    sgdShader: {
      path: 'src/gpu/shaders/sgd.wgsl',
      sha256: await sha256(resolve(options.upstream, 'src/gpu/shaders/sgd.wgsl')),
    },
    applyForcesShader: {
      path: 'src/gpu/shaders/apply-forces.wgsl',
      sha256: await sha256(resolve(options.upstream, 'src/gpu/shaders/apply-forces.wgsl')),
    },
    packageLock: {
      path: 'package-lock.json',
      sha256: await sha256(resolve(options.upstream, 'package-lock.json')),
    },
    harnessConfig: {
      path: 'bench/external-projects/umap-gpu/vitest-provider.config.mjs',
      sha256: await sha256(resolve(harnessDir, 'vitest-provider.config.mjs')),
    },
  };
  const hostHardware = await inspectHostHardware();
  const providers = {};
  for (const [provider, modulePath] of Object.entries(modules)) {
    const probe = await probeProvider(options, provider, modulePath, outDir, hostHardware);
    const runs = [];
    for (let index = 0; index < options.cleanProcessRuns; index += 1) {
      const run = await runSuite(options, provider, modulePath, outDir, index);
      runs.push(run);
      process.stdout.write(`[${provider}] process ${index + 1}: ${run.success ? 'PASS' : 'FAIL'}\n`);
    }
    providers[provider] = { probe, summary: summarize(runs), runs };
  }

  const generatedAt = new Date().toISOString();
  const raw = {
    schemaVersion: 1,
    artifactKind: 'umap-gpu-sgd-output-correctness-suite',
    generatedAt,
    actorId: 'umap-gpu',
    harnessId: 'sgd-output-correctness',
    upstream: {
      repositoryUrl: 'https://github.com/Achuttarsing/umap-gpu',
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
      seam: 'external Vitest resolve alias for the exact webgpu package specifier',
      applicationSourceUnchanged: true,
      shaderSourceUnchanged: true,
      modules,
    },
    immutableInputs,
    oracle: {
      assertionCount: expectedAssertions.length,
      expectedAssertions,
      outputClass: 'upstream structural correctness assertions',
      byteIdentityAvailable: false,
    },
    providers,
  };
  raw.sha256 = sha256Text(JSON.stringify(raw));

  const receiptSummary = {
    schemaVersion: 1,
    artifactKind: 'umap-gpu-sgd-output-receipt-summary',
    generatedAt,
    upstream: raw.upstream,
    host: raw.host,
    providers: Object.fromEntries(Object.entries(providers).map(([provider, value]) => [provider, {
      requestedProvider: provider,
      identity: value.probe.identity,
      identityMatches: value.probe.identityMatches,
      softwareRenderer: value.probe.softwareRenderer,
      hardwareEligible: value.probe.hardwareEligible,
      reliability: value.summary,
    }])),
    shaders: [immutableInputs.sgdShader, immutableInputs.applyForcesShader],
    dispatchShape: {
      workgroupSize: [256, 1, 1],
      primaryFixture: {
        vertices: 24,
        components: 2,
        embeddingElements: 48,
        epochs: 500,
        sgdWorkgroups: 'ceil(runtime graph edge count / 256)',
        applyForcesWorkgroups: 1,
      },
      controlledEpochFixtures: {
        vertices: 2,
        components: 2,
        sgdWorkgroups: 1,
        applyForcesWorkgroups: 1,
        epochs: [1, 2],
      },
      concretePrimaryEdgeCountRecorded: false,
    },
    synchronization: 'both compute passes share one command encoder and submit; queue.onSubmittedWorkDone every ten epochs; mapAsync readback is the terminal boundary',
    readback: 'copy embedding storage buffer to MAP_READ buffer, await mapAsync, copy mapped bytes into Float32Array, then unmap and destroy',
    outputIdentity: Object.fromEntries(Object.entries(providers).map(([provider, value]) => [provider, value.runs.map((run) => ({
      cleanProcessIndex: run.cleanProcessIndex,
      success: run.success,
      assertionIdentitySha256: run.assertionIdentitySha256,
      assertions: run.assertions,
    }))])),
    limitations: {
      exactEmbeddingBytesRecorded: false,
      concretePrimaryEdgeCountRecorded: false,
    },
  };

  const rawPath = resolve(outDir, 'raw-suite.json');
  const receiptPath = resolve(outDir, 'receipt-summary.json');
  await writeFile(rawPath, `${JSON.stringify(raw, null, 2)}\n`);
  await writeFile(receiptPath, `${JSON.stringify(receiptSummary, null, 2)}\n`);
  process.stdout.write(`WROTE ${rawPath}\nWROTE ${receiptPath}\n`);

  const allPass = Object.values(providers).every(({ probe, summary }) => (
    probe.exitCode === 0
    && probe.identityMatches
    && summary.failures === 0
  ));
  if (options.requireAllPass && !allPass) process.exitCode = 1;
}

await main();

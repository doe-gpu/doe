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
  'bench/out/external-projects/world-lab-runtime-webgpu/upstream',
);
const expectedCommit = '4ef19794501d565586a73b991ea569834c54afad';
const testFiles = [
  'src/consumers/vegetationCandidates.test.ts',
  'src/consumers/fullscreenFragment.test.ts',
  'test/consumerDeviceCompile.test.ts',
];
const expectedAssertions = [
  'device-compiles every representative consumer shader with zero error-severity messages',
  'documents the pre-fix fullscreen-fragment params bug as a compile regression',
  'packs iResolution and iTime at the expected offsets',
  'includes node-driven vertex grid, fragment entry, uniform block, and cosine_palette call',
  'declares GraphParams for a constant.f32 param node and device-compiles',
  'returns RGBA8 matching cosine palette at origin when iTime=0',
  'executes a constant.f32 fragment graph without pipeline errors',
  'throws RangeError for invalid patch width',
  'throws RangeError for non-unit tangentX',
  'throws RangeError for invalid spacingMeters',
  'throws RangeError for invalid channel',
  'throws RangeError for negative maxCandidates',
  'throws RangeError when placementThreshold is out of range',
  'GPU parity with CPU two-peak fixture',
  'plateau placement produces zero candidates',
  'reports overflow when maxCandidates is 1',
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
    stdout: stdout.slice(-65_536),
    stderr: stderr.slice(-65_536),
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
    REQUIRE_WEBGPU: '1',
    XDG_RUNTIME_DIR: runtimeDir,
  };
}

async function probeProvider(options, provider, modulePath, outDir, hostHardware) {
  const runtimeDir = resolve(
    repoRoot,
    'bench/out/.xdg',
    sha256Text(outDir).slice(0, 8),
    provider === 'dawn-node-webgpu' ? 'world-dawn-probe' : 'world-doe-probe',
  );
  await mkdir(runtimeDir, { recursive: true });
  const result = await runProcess(process.execPath, [resolve(harnessDir, 'provider-probe.mjs')], {
    cwd: options.upstream,
    env: providerEnvironment(provider, modulePath, options.upstream, runtimeDir),
    timeoutMs: options.timeoutMs,
  });
  const marker = result.stdout
    .split('\n')
    .find((line) => line.startsWith('DOE_WORLD_LAB_PROVIDER_PROBE='));
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
    .map((assertion) => ({
      title: assertion.title,
      status: assertion.status,
      failureMessages: assertion.failureMessages ?? [],
    }))
    .sort((left, right) => left.title.localeCompare(right.title));
}

function oraclePass(report, assertions) {
  const titleSet = new Set(assertions.map((assertion) => assertion.title));
  return report?.success === true
    && report.numTotalTests === expectedAssertions.length
    && report.numPassedTests === expectedAssertions.length
    && report.numFailedTests === 0
    && report.numPendingTests === 0
    && assertions.length === expectedAssertions.length
    && assertions.every((assertion) => assertion.status === 'passed')
    && titleSet.size === expectedAssertions.length
    && expectedAssertions.every((title) => titleSet.has(title));
}

async function runSuite(options, packageRoot, provider, modulePath, outDir, index) {
  const processDir = resolve(outDir, 'processes', provider, String(index + 1));
  const runtimeDir = resolve(
    repoRoot,
    'bench/out/.xdg',
    sha256Text(outDir).slice(0, 8),
    provider === 'dawn-node-webgpu' ? 'world-dawn' : 'world-doe',
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
      ...testFiles,
      '--config',
      resolve(harnessDir, 'vitest-provider.config.mjs'),
      '--reporter=json',
      `--outputFile=${reportPath}`,
    ],
    {
      cwd: packageRoot,
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
    assertionIdentitySha256: sha256Text(JSON.stringify(
      assertions.map(({ title, status }) => ({ title, status })),
    )),
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
  const packageRoot = resolve(options.upstream, 'packages/runtime-webgpu');
  const outDir = resolve(
    repoRoot,
    'bench/out/external-projects/world-lab-runtime-webgpu',
    options.runId,
  );
  await mkdir(outDir, { recursive: true });
  const gitResult = await runProcess('git', ['rev-parse', 'HEAD'], {
    cwd: options.upstream,
    env: process.env,
    timeoutMs: options.timeoutMs,
  });
  const commit = gitResult.stdout.trim();
  if (commit !== expectedCommit) throw new Error(`unexpected world-lab commit: ${commit}`);

  const modules = {
    'dawn-node-webgpu': resolve(options.upstream, 'node_modules/webgpu/index.js'),
    'doe-gpu': resolve(repoRoot, 'packages/doe-gpu/src/index.js'),
  };
  await Promise.all(Object.values(modules).map((path) => access(path)));
  const immutableInputs = {
    packageLock: {
      path: 'package-lock.json',
      sha256: await sha256(resolve(options.upstream, 'package-lock.json')),
    },
    harnessConfig: {
      path: 'bench/external-projects/world-lab-runtime-webgpu/vitest-provider.config.mjs',
      sha256: await sha256(resolve(harnessDir, 'vitest-provider.config.mjs')),
    },
    tests: await Promise.all(testFiles.map(async (path) => ({
      path: `packages/runtime-webgpu/${path}`,
      sha256: await sha256(resolve(packageRoot, path)),
    }))),
    shaderAssemblers: await Promise.all([
      'src/consumers/vegetationCandidates.ts',
      'src/consumers/fullscreenFragment.ts',
      'src/consumers/planeScalarPreview.ts',
      'src/consumers/surfaceMeshPreview.ts',
    ].map(async (path) => ({
      path: `packages/runtime-webgpu/${path}`,
      sha256: await sha256(resolve(packageRoot, path)),
    }))),
  };
  const hostHardware = await inspectHostHardware();
  const providers = {};
  for (const [provider, modulePath] of Object.entries(modules)) {
    const probe = await probeProvider(options, provider, modulePath, outDir, hostHardware);
    const runs = [];
    for (let index = 0; index < options.cleanProcessRuns; index += 1) {
      const run = await runSuite(options, packageRoot, provider, modulePath, outDir, index);
      runs.push(run);
      process.stdout.write(`[${provider}] process ${index + 1}: ${run.success ? 'PASS' : 'FAIL'}\n`);
    }
    providers[provider] = { probe, summary: summarize(runs), runs };
  }

  const generatedAt = new Date().toISOString();
  const raw = {
    schemaVersion: 1,
    artifactKind: 'world-lab-consumer-execution-oracles-suite',
    generatedAt,
    actorId: 'world-lab-runtime-webgpu',
    harnessId: 'consumer-execution-oracles',
    upstream: {
      repositoryUrl: 'https://github.com/saabi/world-lab',
      commit,
      licenseIdentifier: 'MIT',
      packagePath: 'packages/runtime-webgpu',
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
      requireWebGpu: true,
      modules,
    },
    immutableInputs,
    oracle: {
      assertionCount: expectedAssertions.length,
      expectedAssertions,
      outputClasses: [
        'CPU/GPU vegetation record parity',
        'independent RGBA8 first-pixel tolerance',
        'negative shader validation',
        'representative shader compilation',
      ],
    },
    providers,
  };
  raw.sha256 = sha256Text(JSON.stringify(raw));

  const comparisonRuns = providers['doe-gpu'].runs;
  const receiptSummary = {
    schemaVersion: 1,
    artifactKind: 'world-lab-consumer-execution-receipt-summary',
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
    shaderSourceOwners: immutableInputs.shaderAssemblers,
    shaderHashes: 'not-emitted-by-upstream-dynamic-assembly',
    dispatchShape: {
      vegetation: 'runtime fixture dimensions and workgroup count are not emitted by the upstream test report',
      fullscreenRender: { width: 64, height: 64, vertexCount: 6 },
      constantFragmentRender: { width: 32, height: 32, vertexCount: 6 },
      concreteVegetationWorkgroupsRecorded: false,
    },
    synchronization: 'upstream compute and render submissions complete through mapAsync-backed readback before assertions',
    readback: 'vegetation metadata and candidate buffers plus fullscreen RGBA8 staging buffers are mapped and copied before oracle evaluation',
    outputIdentity: Object.fromEntries(Object.entries(providers).map(([provider, value]) => [provider, value.runs.map((run) => ({
      cleanProcessIndex: run.cleanProcessIndex,
      success: run.success,
      assertionIdentitySha256: run.assertionIdentitySha256,
      assertions: run.assertions.map(({ title, status }) => ({ title, status })),
    }))])),
    diagnosis: {
      firstComparisonFailure: comparisonRuns.find((run) => !run.success) ?? null,
      repeatedFailureCount: comparisonRuns.filter((run) => !run.success).length,
    },
    limitations: {
      dynamicallyAssembledShaderHashesRecorded: false,
      exactOutputBytesRecorded: false,
      concreteVegetationWorkgroupsRecorded: false,
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

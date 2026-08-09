#!/usr/bin/env node

import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { constants as fsConstants } from 'node:fs';
import { access, mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const harnessDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(harnessDir, '../../..');
const defaultUpstream = resolve(repoRoot, 'bench/out/external-projects/wgsl-fns/upstream');
const expectedCommit = 'e1068da8c1ad213842c6332440fe1308def091cc';
const expectedAssertions = 13;
const sourcePaths = [
  'src/animation.ts',
  'src/color.ts',
  'src/dependencies.ts',
  'src/functions.ts',
  'src/index.ts',
  'src/math.ts',
  'src/noise.ts',
  'src/sdf-modifiers.ts',
  'src/sdf-operations.ts',
  'src/sdf-transforms.ts',
  'src/sdf-utils.ts',
  'src/sdf.ts',
  'src/waves.ts',
  'test/index.test.js',
  'package-lock.json',
  'dist/wgsl-fns.esm.js',
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
    processCrashed: !timedOut && result.signal !== null,
    durationMs: Number(process.hrtime.bigint() - started) / 1e6,
    peakMemoryBytes,
    stdout: stdout.slice(-131_072),
    stderr: stderr.slice(-131_072),
  };
}

async function gitHead(upstream) {
  const result = await runProcess('git', ['rev-parse', 'HEAD'], {
    cwd: upstream,
    env: process.env,
    timeoutMs: 10_000,
  });
  if (result.exitCode !== 0) throw new Error(`cannot read upstream commit: ${result.stderr}`);
  return result.stdout.trim();
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

function providerEnvironment(provider, modulePath, runtimeDir) {
  const env = {
    ...process.env,
    DOE_EXTERNAL_WEBGPU_PROVIDER: provider,
    XDG_RUNTIME_DIR: runtimeDir,
  };
  delete env.CI;
  delete env.GITHUB_ACTIONS;
  if (provider === 'dawn-node-webgpu') env.DOE_EXTERNAL_DAWN_MODULE = modulePath;
  else env.DOE_EXTERNAL_DOE_MODULE = modulePath;
  return env;
}

async function probeProvider(options, provider, modulePath, outDir, hostHardware) {
  const runtimeDir = resolve(
    repoRoot,
    'bench/out/.xdg',
    sha256Text(outDir).slice(0, 8),
    provider === 'dawn-node-webgpu' ? 'wgsl-fns-dawn-probe' : 'wgsl-fns-doe-probe',
  );
  await mkdir(runtimeDir, { recursive: true });
  const result = await runProcess(
    process.execPath,
    ['--experimental-loader', resolve(harnessDir, 'provider-loader.mjs'), resolve(harnessDir, 'provider-probe.mjs')],
    {
      cwd: options.upstream,
      env: providerEnvironment(provider, modulePath, runtimeDir),
      timeoutMs: options.timeoutMs,
    },
  );
  const marker = result.stdout
    .split('\n')
    .find((line) => line.startsWith('DOE_WGSL_FNS_PROVIDER_PROBE='));
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

function tapInteger(stdout, name) {
  const match = new RegExp(`^# ${name} (\\d+)$`, 'm').exec(stdout);
  return match ? Number.parseInt(match[1], 10) : null;
}

function classifyTap(stdout) {
  const workerSignals = [...stdout.matchAll(/^\s*signal: '([^']+)'$/gm)].map((match) => match[1]);
  return {
    tests: tapInteger(stdout, 'tests'),
    suites: tapInteger(stdout, 'suites'),
    passed: tapInteger(stdout, 'pass'),
    failed: tapInteger(stdout, 'fail'),
    cancelled: tapInteger(stdout, 'cancelled'),
    skipped: tapInteger(stdout, 'skipped'),
    todo: tapInteger(stdout, 'todo'),
    workerSignals,
  };
}

function nativeDiagnostics(output) {
  const lines = output.split('\n').map((line) => line.trim()).filter(Boolean);
  const shaderTranslationFailures = lines.filter((line) =>
    line.includes('WGSL→SPIR-V translation failed')
    || line.includes('WGSL->SPIR-V translation failed'));
  const shaderModuleFailures = lines.filter((line) =>
    line.includes('createShaderModule') && line.includes('failed'));
  return {
    shaderTranslationFailureCount: shaderTranslationFailures.length,
    shaderModuleFailureCount: shaderModuleFailures.length,
    firstShaderTranslationFailure: shaderTranslationFailures[0] ?? null,
    firstShaderModuleFailure: shaderModuleFailures[0] ?? null,
  };
}

async function runSuite(options, provider, modulePath, outDir, index) {
  const runtimeDir = resolve(
    repoRoot,
    'bench/out/.xdg',
    sha256Text(outDir).slice(0, 8),
    provider === 'dawn-node-webgpu' ? 'wgsl-fns-dawn' : 'wgsl-fns-doe',
    String(index + 1),
  );
  await mkdir(runtimeDir, { recursive: true });
  const result = await runProcess(
    process.execPath,
    [
      '--experimental-loader',
      resolve(harnessDir, 'provider-loader.mjs'),
      '--test',
      '--test-reporter=tap',
      'test/index.test.js',
    ],
    {
      cwd: options.upstream,
      env: providerEnvironment(provider, modulePath, runtimeDir),
      timeoutMs: options.timeoutMs,
    },
  );
  const tap = classifyTap(result.stdout);
  // Node's test reporter forwards worker stderr as TAP comments on stdout, so
  // classify the combined parent stream rather than trusting stderr alone.
  const diagnostics = nativeDiagnostics(`${result.stdout}\n${result.stderr}`);
  const nativeCompilerErrorCount = diagnostics.shaderTranslationFailureCount
    + diagnostics.shaderModuleFailureCount;
  const success = result.exitCode === 0
    && result.signal === null
    && !result.timedOut
    && tap.workerSignals.length === 0
    && tap.tests === expectedAssertions
    && tap.passed === expectedAssertions
    && tap.failed === 0
    && tap.cancelled === 0
    && tap.skipped === 0
    && nativeCompilerErrorCount === 0;
  return {
    cleanProcessIndex: index + 1,
    success,
    ...result,
    tap,
    diagnostics,
    nativeCompilerErrorCount,
    outputIdentitySha256: sha256Text(JSON.stringify({ tap, diagnostics })),
  };
}

function percentile(values, quantile) {
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.min(sorted.length - 1, Math.ceil(quantile * sorted.length) - 1)];
}

function summarize(processes) {
  const durations = processes.map((item) => item.durationMs);
  const crashed = (item) => item.processCrashed || item.tap.workerSignals.length > 0;
  return {
    cleanProcessRuns: processes.length,
    successes: processes.filter((item) => item.success).length,
    failures: processes.filter((item) => !item.success && !item.timedOut && !crashed(item)).length,
    crashes: processes.filter(crashed).length,
    hangs: 0,
    timeouts: processes.filter((item) => item.timedOut).length,
    peakMemoryBytes: Math.max(...processes.map((item) => item.peakMemoryBytes)),
    cleanProcessLatencyMs: {
      p50: percentile(durations, 0.50),
      p95: percentile(durations, 0.95),
      p99: percentile(durations, 0.99),
    },
  };
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const actualCommit = await gitHead(options.upstream);
  if (actualCommit !== expectedCommit) {
    throw new Error(`upstream commit mismatch: expected ${expectedCommit}, received ${actualCommit}`);
  }
  for (const path of sourcePaths) await access(resolve(options.upstream, path), fsConstants.R_OK);

  const outDir = resolve(
    repoRoot,
    'bench/out/external-projects/wgsl-fns',
    options.runId,
  );
  await mkdir(outDir, { recursive: true });
  const hostHardware = await inspectHostHardware();
  const modules = {
    'dawn-node-webgpu': resolve(options.upstream, 'node_modules/webgpu/index.js'),
    'doe-gpu': resolve(repoRoot, 'packages/doe-gpu/src/index.js'),
  };
  const providers = {};
  for (const [provider, modulePath] of Object.entries(modules)) {
    const probe = await probeProvider(options, provider, modulePath, outDir, hostHardware);
    const processes = [];
    for (let index = 0; index < options.cleanProcessRuns; index += 1) {
      const sample = await runSuite(options, provider, modulePath, outDir, index);
      processes.push(sample);
      console.log(`[${provider}] process ${index + 1}: ${sample.success ? 'PASS' : 'FAIL'}`);
    }
    providers[provider] = {
      requestedProvider: provider,
      modulePath,
      probe,
      processes,
      reliability: summarize(processes),
    };
  }

  const immutableInputs = await Promise.all(sourcePaths.map(async (path) => ({
    path,
    sha256: await sha256(resolve(options.upstream, path)),
  })));
  const generatedAt = new Date().toISOString();
  const raw = {
    schemaVersion: 1,
    artifactKind: 'wgsl-fns-compilation-suite-raw',
    actorId: 'wgsl-fns',
    harnessId: 'wgsl-compilation-suite',
    runId: options.runId,
    generatedAt,
    upstream: {
      repositoryUrl: 'https://github.com/koole/wgsl-fns',
      commit: actualCommit,
      licenseIdentifier: 'MIT',
      packageVersion: '0.0.4',
      incumbentProviderVersion: '0.3.0',
    },
    host: {
      platform: process.platform,
      architecture: process.arch,
      node: process.version,
      ...hostHardware,
    },
    providerSubstitution: {
      loaderPath: 'bench/external-projects/wgsl-fns/provider-loader.mjs',
      exactSpecifier: 'webgpu',
      applicationSourceUnchanged: true,
      shaderSourceUnchanged: true,
    },
    oracle: {
      expectedAssertions,
      rejectWorkerSignals: true,
      rejectNativeCompilerDiagnostics: true,
      executionOracle: false,
    },
    immutableInputs,
    providers,
  };
  const receipt = {
    schemaVersion: 1,
    artifactKind: 'wgsl-fns-compilation-receipt-summary',
    generatedAt,
    upstream: raw.upstream,
    host: raw.host,
    providers: Object.fromEntries(Object.entries(providers).map(([provider, item]) => [
      provider,
      {
        requestedProvider: provider,
        identity: item.probe.identity,
        probeExitCode: item.probe.exitCode,
        probeSignal: item.probe.signal,
        identityMatches: item.probe.identityMatches,
        softwareRenderer: item.probe.softwareRenderer,
        hardwareEligible: item.probe.hardwareEligible,
        reliability: item.reliability,
      },
    ])),
    shaderSourceOwners: immutableInputs.filter((item) => item.path.startsWith('src/')),
    generatedCorpusBundle: immutableInputs.find((item) => item.path === 'dist/wgsl-fns.esm.js'),
    dynamicallyGeneratedShaderHashes: 'not-emitted-by-unchanged-upstream-test',
    dispatchShape: 'not-applicable-compilation-only-workload',
    synchronization: 'not-applicable-no-command-submission',
    readback: 'not-applicable-no-dispatch-or-output-buffer',
    outputIdentity: Object.fromEntries(Object.entries(providers).map(([provider, item]) => [
      provider,
      item.processes.map((sample) => ({
        cleanProcessIndex: sample.cleanProcessIndex,
        success: sample.success,
        exitCode: sample.exitCode,
        signal: sample.signal,
        workerSignals: sample.tap.workerSignals,
        tap: sample.tap,
        nativeCompilerErrorCount: sample.nativeCompilerErrorCount,
        outputIdentitySha256: sample.outputIdentitySha256,
      })),
    ])),
    diagnosis: {
      dawnProbeFailure: {
        exitCode: providers['dawn-node-webgpu'].probe.exitCode,
        signal: providers['dawn-node-webgpu'].probe.signal,
        stderr: providers['dawn-node-webgpu'].probe.stderr,
      },
      dawnRepeatedWorkerSignals: providers['dawn-node-webgpu'].processes
        .map((sample) => sample.tap.workerSignals),
      doeFirstNativeCompilerFailure: providers['doe-gpu'].processes[0]
        .diagnostics.firstShaderTranslationFailure,
      doeRepeatedNativeCompilerFailureCounts: providers['doe-gpu'].processes
        .map((sample) => sample.nativeCompilerErrorCount),
    },
    limitations: {
      dynamicallyGeneratedShaderHashesRecorded: false,
      shaderExecutionPerformed: false,
      exactOutputBytesRecorded: false,
    },
  };

  const rawPath = resolve(outDir, 'raw-suite.json');
  const receiptPath = resolve(outDir, 'receipt-summary.json');
  await Promise.all([
    writeFile(rawPath, `${JSON.stringify(raw, null, 2)}\n`),
    writeFile(receiptPath, `${JSON.stringify(receipt, null, 2)}\n`),
  ]);
  console.log(`WROTE ${rawPath}`);
  console.log(`WROTE ${receiptPath}`);

  const allPassed = Object.values(providers).every((provider) =>
    provider.processes.every((sample) => sample.success));
  if (options.requireAllPass && !allPassed) process.exitCode = 1;
}

main().catch((error) => {
  console.error(error?.stack ?? String(error));
  process.exitCode = 1;
});

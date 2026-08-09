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
  'bench/out/external-projects/electronicarts-cpp-ml-intro/upstream',
);
const expectedCommit = 'c46a47b4fcee5ec48dbda7321210b1287b262b06';
const generatedRoot = 'Demo/mnist/Gigi/out/WebGPU';
const generatedInputs = [
  'index.js',
  'mnist_Module.js',
  'Shared.js',
  'assets/Backprop_Weights.bin',
  ...Array.from({ length: 10 }, (_, index) => `assets/${index}.png`),
];
const diagnosticPatterns = [
  ['wgslTranslationFailure', /WGSL(?:→|->)SPIR-V translation failed/],
  ['shaderModuleFailure', /createShaderModule.*failed/i],
  ['textureCopyFailure', /copyTextureToTexture.*(?:failed|InvalidState)/i],
  ['spirvBindingFailure', /set_compute_shader_spirv.*failed/i],
  ['missingSpirvDispatch', /recorded dispatch missing SPIR-V/i],
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
    stdout,
    stderr,
  };
}

async function gitHead(upstream, timeoutMs) {
  const result = await runProcess('git', ['rev-parse', 'HEAD'], {
    cwd: upstream,
    env: process.env,
    timeoutMs,
  });
  if (result.exitCode !== 0) throw new Error(`cannot read upstream commit: ${result.stderr}`);
  return result.stdout.trim();
}

async function gitWorktreeDirty(repository, timeoutMs) {
  const result = await runProcess('git', ['status', '--porcelain=v1'], {
    cwd: repository,
    env: process.env,
    timeoutMs,
  });
  if (result.exitCode !== 0) throw new Error(`cannot read worktree status: ${result.stderr}`);
  return result.stdout.trim().length > 0;
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
      // A listed but inaccessible render node cannot support hardware evidence.
    }
  }
  return {
    renderNodes,
    accessibleRenderNodes,
    physicalGpuEligible: accessibleRenderNodes.length > 0,
  };
}

function providerEnvironment(provider, modulePath, upstream, runtimeDir) {
  const env = {
    ...process.env,
    DOE_CPP_ML_UPSTREAM: upstream,
    DOE_EXTERNAL_WEBGPU_PROVIDER: provider,
    XDG_RUNTIME_DIR: runtimeDir,
  };
  if (provider === 'dawn-node-webgpu') env.DOE_EXTERNAL_DAWN_MODULE = modulePath;
  else env.DOE_EXTERNAL_DOE_MODULE = modulePath;
  return env;
}

function parseMarker(stdout, prefix) {
  const line = stdout.split('\n').find((candidate) => candidate.startsWith(prefix));
  if (!line) return null;
  try {
    return JSON.parse(line.slice(prefix.length));
  } catch {
    return null;
  }
}

function stripMarker(stdout, prefix) {
  return stdout.split('\n').filter((line) => !line.startsWith(prefix)).join('\n').slice(-65_536);
}

function classifyDiagnostics(output) {
  const lines = output.split('\n').map((line) => line.trim()).filter(Boolean);
  const byCode = Object.fromEntries(diagnosticPatterns.map(([code, pattern]) => {
    const matches = lines.filter((line) => pattern.test(line));
    return [code, { count: matches.length, first: matches[0] ?? null }];
  }));
  return {
    total: Object.values(byCode).reduce((sum, item) => sum + item.count, 0),
    byCode,
  };
}

async function probeProvider(options, provider, modulePath, outDir, hostHardware) {
  const runtimeDir = resolve(repoRoot, 'bench/out/.xdg', sha256Text(outDir).slice(0, 8), `${provider}-probe`);
  await mkdir(runtimeDir, { recursive: true });
  const result = await runProcess(
    process.execPath,
    ['--experimental-loader', resolve(harnessDir, 'provider-loader.mjs'), resolve(harnessDir, 'provider-probe.mjs')],
    {
      cwd: resolve(options.upstream, generatedRoot),
      env: providerEnvironment(provider, modulePath, options.upstream, runtimeDir),
      timeoutMs: options.timeoutMs,
    },
  );
  const identity = parseMarker(result.stdout, 'DOE_CPP_ML_PROVIDER_PROBE=');
  const identityText = JSON.stringify(identity ?? {}).toLowerCase();
  const softwareRenderer = /llvmpipe|swiftshader|software renderer|software-renderer/.test(identityText);
  const identityMatches = identity?.provider?.id === provider
    && identity?.provider?.modulePath === modulePath;
  return {
    ...result,
    stdout: stripMarker(result.stdout, 'DOE_CPP_ML_PROVIDER_PROBE='),
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

async function runOracle(options, provider, modulePath, outDir, index) {
  const runtimeDir = resolve(
    repoRoot,
    'bench/out/.xdg',
    sha256Text(outDir).slice(0, 8),
    provider,
    String(index + 1),
  );
  await mkdir(runtimeDir, { recursive: true });
  const result = await runProcess(
    process.execPath,
    ['--experimental-loader', resolve(harnessDir, 'provider-loader.mjs'), resolve(harnessDir, 'mnist-oracle.mjs')],
    {
      cwd: resolve(options.upstream, generatedRoot),
      env: providerEnvironment(provider, modulePath, options.upstream, runtimeDir),
      timeoutMs: options.timeoutMs,
    },
  );
  const oracle = parseMarker(result.stdout, 'DOE_CPP_ML_ORACLE=');
  const diagnostics = classifyDiagnostics(`${result.stdout}\n${result.stderr}`);
  const providerIdentityMatches = oracle?.provider?.id === provider
    && oracle?.provider?.modulePath === modulePath;
  const success = result.exitCode === 0
    && result.signal === null
    && !result.timedOut
    && oracle?.oraclePass === true
    && oracle?.cases?.length === 10
    && providerIdentityMatches
    && diagnostics.total === 0;
  const outputIdentity = oracle?.cases?.map((item) => ({
    expectedDigit: item.expectedDigit,
    gpuDigit: item.gpuDigit,
    cpuDigit: item.cpuDigit,
    maxAbsError: item.maxAbsError,
    gpuOutput: item.gpuOutput,
    cpuOutput: item.cpuOutput,
  })) ?? null;
  return {
    cleanProcessIndex: index + 1,
    success,
    ...result,
    stdout: stripMarker(result.stdout, 'DOE_CPP_ML_ORACLE='),
    diagnostics,
    oracle: oracle ? {
      provider: oracle.provider,
      adapter: oracle.adapter,
      validationError: oracle.validationError,
      oraclePass: oracle.oraclePass,
      cases: oracle.cases,
    } : null,
    providerIdentityMatches,
    outputIdentitySha256: outputIdentity === null ? null : sha256Text(JSON.stringify(outputIdentity)),
  };
}

function percentile(values, quantile) {
  const sorted = [...values].sort((left, right) => left - right);
  if (sorted.length === 0) return 0;
  return sorted[Math.min(sorted.length - 1, Math.ceil(quantile * sorted.length) - 1)];
}

function summarize(processes) {
  const durations = processes.map((item) => item.durationMs);
  const crashed = (item) => item.processCrashed;
  return {
    cleanProcessRuns: processes.length,
    successes: processes.filter((item) => item.success).length,
    failures: processes.filter((item) => !item.success && !item.timedOut && !crashed(item)).length,
    crashes: processes.filter(crashed).length,
    hangs: 0,
    timeouts: processes.filter((item) => item.timedOut).length,
    peakMemoryBytes: Math.max(0, ...processes.map((item) => item.peakMemoryBytes)),
    cleanProcessLatencyMs: {
      p50: percentile(durations, 0.50),
      p95: percentile(durations, 0.95),
      p99: percentile(durations, 0.99),
    },
  };
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const actualCommit = await gitHead(options.upstream, options.timeoutMs);
  if (actualCommit !== expectedCommit) {
    throw new Error(`upstream commit mismatch: expected ${expectedCommit}, received ${actualCommit}`);
  }
  const doeSource = {
    commit: await gitHead(repoRoot, options.timeoutMs),
    worktreeDirty: await gitWorktreeDirty(repoRoot, options.timeoutMs),
  };
  const outDir = resolve(
    repoRoot,
    'bench/out/external-projects/electronicarts-cpp-ml-intro',
    options.runId,
  );
  await mkdir(outDir, { recursive: true });
  for (const path of generatedInputs) {
    await access(resolve(options.upstream, generatedRoot, path), fsConstants.R_OK);
  }

  const modules = {
    'dawn-node-webgpu': resolve(repoRoot, 'bench/node_modules/webgpu/index.js'),
    'doe-gpu': resolve(repoRoot, 'packages/doe-gpu/src/index.js'),
  };
  for (const modulePath of Object.values(modules)) await access(modulePath, fsConstants.R_OK);
  const hostHardware = await inspectHostHardware();
  const providers = {};
  for (const [provider, modulePath] of Object.entries(modules)) {
    const probe = await probeProvider(options, provider, modulePath, outDir, hostHardware);
    const processes = [];
    for (let index = 0; index < options.cleanProcessRuns; index += 1) {
      const sample = await runOracle(options, provider, modulePath, outDir, index);
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
  const doeProviderInfo = providers['doe-gpu'].probe.identity?.provider?.providerInfo ?? null;
  let doeBuildMetadata = null;
  let doeBuildMetadataSha256 = null;
  if (doeProviderInfo?.buildMetadataPath) {
    const metadataBytes = await readFile(doeProviderInfo.buildMetadataPath);
    doeBuildMetadata = JSON.parse(metadataBytes.toString('utf8'));
    doeBuildMetadataSha256 = createHash('sha256').update(metadataBytes).digest('hex');
  }

  const immutableInputs = await Promise.all(generatedInputs.map(async (path) => ({
    path: `${generatedRoot}/${path}`,
    sha256: await sha256(resolve(options.upstream, generatedRoot, path)),
  })));
  const harnessInputs = await Promise.all([
    'mnist-webgpu-demo.harness.json',
    'oracle.md',
    'mnist-oracle.mjs',
    'provider-loader.mjs',
    'provider-dawn.mjs',
    'provider-doe.mjs',
    'provider-probe.mjs',
    'run-suite.mjs',
  ].map(async (path) => ({
    path: `bench/external-projects/electronicarts-cpp-ml-intro/${path}`,
    sha256: await sha256(resolve(harnessDir, path)),
  })));
  const generatedAt = new Date().toISOString();
  const raw = {
    schemaVersion: 1,
    artifactKind: 'cpp-ml-mnist-webgpu-suite-raw',
    actorId: 'electronicarts-cpp-ml-intro',
    harnessId: 'mnist-webgpu-demo',
    runId: options.runId,
    generatedAt,
    upstream: {
      repositoryUrl: 'https://github.com/electronicarts/cpp-ml-intro',
      commit: actualCommit,
      licenseIdentifier: 'LicenseRef-EA-BSD-3-Clause-With-Marks',
    },
    doeSource,
    host: {
      platform: process.platform,
      architecture: process.arch,
      node: process.version,
      ...hostHardware,
    },
    providerSubstitution: {
      loaderPath: 'bench/external-projects/electronicarts-cpp-ml-intro/provider-loader.mjs',
      exactSpecifier: 'webgpu',
      applicationSourceUnchanged: true,
      shaderSourceUnchanged: true,
      modules,
    },
    oracle: {
      cases: 10,
      networkShape: [784, 30, 10],
      maximumAbsoluteError: 0.0025,
      requireGpuCpuArgmaxEquality: true,
      requireFiniteGpuOutput: true,
    },
    immutableInputs,
    harnessInputs,
    providers,
  };
  raw.sha256 = sha256Text(JSON.stringify(raw));

  const receipt = {
    schemaVersion: 1,
    artifactKind: 'cpp-ml-mnist-webgpu-receipt-summary',
    generatedAt,
    upstream: raw.upstream,
    doeSource,
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
    runtimeBuildIdentity: {
      providerInfo: doeProviderInfo,
      buildMetadata: doeBuildMetadata,
      buildMetadataSha256: doeBuildMetadataSha256,
    },
    shaderSourceOwner: immutableInputs.find((item) => item.path.endsWith('/mnist_Module.js')),
    modelWeights: immutableInputs.find((item) => item.path.endsWith('/Backprop_Weights.bin')),
    imageInputs: immutableInputs.filter((item) => /\/assets\/\d\.png$/.test(item.path)),
    dispatchShape: [
      { pass: 'Draw', workgroups: [32, 32, 1] },
      { pass: 'CalculateExtents', workgroups: [32, 32, 1] },
      { pass: 'Shrink', workgroups: [4, 4, 1] },
      { pass: 'HiddenLayer', workgroups: [1, 1, 1] },
      { pass: 'OutputLayer', workgroups: [1, 1, 1] },
      { pass: 'Presentation', workgroups: [60, 124, 1] },
    ],
    synchronization: 'each image submits the generated six-pass command buffer and awaits queue.onSubmittedWorkDone before readback',
    readback: 'copy the 10-f32 output activation buffer to MAP_READ, await mapAsync through generated Shared.js, copy values, unmap, and destroy',
    outputIdentity: Object.fromEntries(Object.entries(providers).map(([provider, item]) => [
      provider,
      item.processes.map((sample) => ({
        cleanProcessIndex: sample.cleanProcessIndex,
        success: sample.success,
        outputIdentitySha256: sample.outputIdentitySha256,
        oraclePass: sample.oracle?.oraclePass ?? false,
        cases: sample.oracle?.cases?.map((item) => ({
          expectedDigit: item.expectedDigit,
          gpuDigit: item.gpuDigit,
          cpuDigit: item.cpuDigit,
          maxAbsError: item.maxAbsError,
        })) ?? [],
      })),
    ])),
    diagnosis: {
      doeFirstWgslTranslationFailure: providers['doe-gpu'].processes
        .map((sample) => sample.diagnostics.byCode.wgslTranslationFailure.first)
        .find(Boolean) ?? null,
      doeRepeatedDiagnosticCounts: providers['doe-gpu'].processes
        .map((sample) => sample.diagnostics.total),
    },
    limitations: {
      dynamicallyGeneratedEntryPointShaderHashesRecorded: false,
      driverIdentityRecorded: false,
      receiptOverheadMeasured: false,
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

  const allPassed = Object.values(providers).every((item) =>
    item.probe.exitCode === 0
    && item.probe.identityMatches
    && item.processes.every((sample) => sample.success));
  if (options.requireAllPass && !allPassed) process.exitCode = 1;
}

main().catch((error) => {
  console.error(error?.stack ?? String(error));
  process.exitCode = 1;
});

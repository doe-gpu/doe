#!/usr/bin/env node

import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { constants as fsConstants } from 'node:fs';
import { access, mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { buildRuntimeOwnership } from '../../lib/runtime-ownership-matrix.mjs';

const harnessDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(harnessDir, '../../..');
const defaultUpstream = resolve(repoRoot, 'bench/out/external-projects/wgsl-fns/upstream');
const expectedCommit = 'e1068da8c1ad213842c6332440fe1308def091cc';
const expectedAssertions = 13;
const expectedP0Integrity = 'sha512-5QKDzvwlPaYshQAmhG0WImX5cvWsY5XRiukUwtKaoMEk0csi4tRSH/cwsoNn9S7JJFHnkSDA/NzfuHmcavNBmw==';
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
const harnessPaths = [
  'bench/external-projects/wgsl-fns/oracle.md',
  'bench/external-projects/wgsl-fns/provider-loader.mjs',
  'bench/external-projects/wgsl-fns/semantic-oracle.mjs',
];

function parseArgs(argv) {
  const options = {
    upstream: defaultUpstream,
    runId: new Date().toISOString().replaceAll(':', '').replaceAll('.', ''),
    cleanProcessRuns: 3,
    timeoutMs: 120_000,
    requireAllPass: false,
    patchedDawnReceipt: resolve(
      repoRoot,
      'bench/out/external-projects/wgsl-fns/p0-webgpu-0.3.10/receipt.json',
    ),
  };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === '--upstream') options.upstream = resolve(argv[++index]);
    else if (value === '--run-id') options.runId = argv[++index];
    else if (value === '--clean-process-runs') {
      options.cleanProcessRuns = Number.parseInt(argv[++index], 10);
    } else if (value === '--timeout-ms') {
      options.timeoutMs = Number.parseInt(argv[++index], 10);
    } else if (value === '--patched-dawn-receipt') {
      options.patchedDawnReceipt = resolve(argv[++index]);
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

async function readPatchedDawnReceipt(path) {
  if (!path.startsWith(`${repoRoot}/bench/out/external-projects/wgsl-fns/`)) {
    throw new Error('P0 receipt must remain under bench/out/external-projects/wgsl-fns');
  }
  const receipt = JSON.parse(await readFile(path, 'utf8'));
  if (receipt.artifactKind !== 'wgsl-fns-p0-package-receipt'
    || receipt.package?.name !== 'webgpu'
    || receipt.package?.version !== '0.3.10'
    || receipt.package?.integrity !== expectedP0Integrity
    || receipt.platform?.os !== process.platform
    || receipt.platform?.architecture !== process.arch) {
    throw new Error('P0 receipt does not match the frozen package and platform contract');
  }
  for (const [name, artifact] of Object.entries(receipt.artifacts ?? {})) {
    const artifactPath = resolve(repoRoot, artifact.path);
    if (!artifactPath.startsWith(`${repoRoot}/bench/out/external-projects/wgsl-fns/`)) {
      throw new Error(`P0 ${name} artifact escapes the governed output root`);
    }
    if (await sha256(artifactPath) !== artifact.sha256) {
      throw new Error(`P0 ${name} artifact hash mismatch`);
    }
  }
  const modulePath = resolve(repoRoot, receipt.artifacts?.module?.path ?? '');
  await access(modulePath, fsConstants.R_OK);
  return {
    path: path.slice(repoRoot.length + 1),
    sha256: await sha256(path),
    receipt,
    modulePath,
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
    DOE_EXTERNAL_WEBGPU_MODULE_PATH: modulePath,
    XDG_RUNTIME_DIR: runtimeDir,
  };
  delete env.CI;
  delete env.GITHUB_ACTIONS;
  if (provider === 'dawn-node-webgpu') env.DOE_EXTERNAL_DAWN_MODULE = modulePath;
  else if (provider === 'doe-gpu') env.DOE_EXTERNAL_DOE_MODULE = modulePath;
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

async function runSuite(options, laneId, provider, modulePath, outDir, index) {
  const runtimeDir = resolve(
    repoRoot,
    'bench/out/.xdg',
    sha256Text(outDir).slice(0, 8),
    `wgsl-fns-${laneId.toLowerCase()}`,
    String(index + 1),
  );
  await mkdir(runtimeDir, { recursive: true });
  const compilation = await runProcess(
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
  const semantic = await runProcess(
    process.execPath,
    [
      '--experimental-loader',
      resolve(harnessDir, 'provider-loader.mjs'),
      resolve(harnessDir, 'semantic-oracle.mjs'),
    ],
    {
      cwd: options.upstream,
      env: providerEnvironment(provider, modulePath, runtimeDir),
      timeoutMs: options.timeoutMs,
    },
  );
  const tap = classifyTap(compilation.stdout);
  // Node's test reporter forwards worker stderr as TAP comments on stdout, so
  // classify the combined parent stream rather than trusting stderr alone.
  const diagnostics = nativeDiagnostics(
    `${compilation.stdout}\n${compilation.stderr}\n${semantic.stdout}\n${semantic.stderr}`,
  );
  const nativeCompilerErrorCount = diagnostics.shaderTranslationFailureCount
    + diagnostics.shaderModuleFailureCount;
  const semanticMarker = semantic.stdout
    .split('\n')
    .find((line) => line.startsWith('DOE_WGSL_FNS_SEMANTIC_ORACLE='));
  let semanticResult = null;
  try {
    if (semanticMarker) {
      semanticResult = JSON.parse(semanticMarker.slice(semanticMarker.indexOf('=') + 1));
    }
  } catch {
    semanticResult = null;
  }
  const compilationSuccess = compilation.exitCode === 0
    && compilation.signal === null
    && !compilation.timedOut
    && tap.workerSignals.length === 0
    && tap.tests === expectedAssertions
    && tap.passed === expectedAssertions
    && tap.failed === 0
    && tap.cancelled === 0
    && tap.skipped === 0
    && nativeCompilerErrorCount === 0;
  const semanticSuccess = semantic.exitCode === 0
    && semantic.signal === null
    && !semantic.timedOut
    && semanticResult?.artifactKind === 'wgsl-fns-semantic-oracle-result'
    && semanticResult?.provider?.id === provider
    && semanticResult?.provider?.modulePath === modulePath
    && semanticResult?.oracle?.passed === true
    && semanticResult?.oracle?.expectedSha256 === semanticResult?.oracle?.actualSha256;
  const success = compilationSuccess && semanticSuccess;
  return {
    laneId,
    provider,
    providerModulePath: modulePath,
    cleanProcessIndex: index + 1,
    success,
    exitCode: compilation.exitCode !== 0 ? compilation.exitCode : semantic.exitCode,
    signal: compilation.signal ?? semantic.signal,
    timedOut: compilation.timedOut || semantic.timedOut,
    processCrashed: compilation.processCrashed || semantic.processCrashed,
    durationMs: compilation.durationMs + semantic.durationMs,
    peakMemoryBytes: Math.max(compilation.peakMemoryBytes, semantic.peakMemoryBytes),
    stdout: `${compilation.stdout}\n${semantic.stdout}`.slice(-131_072),
    stderr: `${compilation.stderr}\n${semantic.stderr}`.slice(-131_072),
    compilation: {
      success: compilationSuccess,
      ...compilation,
    },
    semantic: {
      success: semanticSuccess,
      ...semantic,
      result: semanticResult,
    },
    tap,
    diagnostics,
    nativeCompilerErrorCount,
    outputIdentitySha256: sha256Text(JSON.stringify({
      tap,
      diagnostics,
      semantic: semanticResult,
    })),
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

function executionEvidence(sample) {
  return {
    success: sample.success,
    exitCode: sample.exitCode,
    signal: sample.signal,
    timedOut: sample.timedOut,
    processCrashed: sample.processCrashed,
    tap: sample.tap,
    diagnostics: sample.diagnostics,
    nativeCompilerErrorCount: sample.nativeCompilerErrorCount,
    compilationSuccess: sample.compilation.success,
    semanticSuccess: sample.semantic.success,
    semanticResult: sample.semantic.result,
    outputIdentitySha256: sample.outputIdentitySha256,
  };
}

async function runReceiptReplay({
  options,
  laneId,
  provider,
  modulePath,
  outDir,
  sourceSample,
  immutableInputs,
}) {
  const relativeReceiptPath = `replay-receipts/${laneId}.json`;
  const receiptPath = resolve(outDir, relativeReceiptPath);
  await mkdir(dirname(receiptPath), { recursive: true });
  const expectedEvidenceSha256 = sha256Text(JSON.stringify(executionEvidence(sourceSample)));
  const receipt = {
    schemaVersion: 1,
    artifactKind: 'wgsl-fns-compilation-replay-receipt',
    laneId,
    provider,
    providerModulePath: modulePath,
    immutableInputs,
    expectedEvidenceSha256,
  };
  await writeFile(receiptPath, `${JSON.stringify(receipt, null, 2)}\n`);
  const loadedReceipt = JSON.parse(await readFile(receiptPath, 'utf8'));
  if (loadedReceipt.provider !== provider
    || loadedReceipt.providerModulePath !== modulePath
    || loadedReceipt.expectedEvidenceSha256 !== expectedEvidenceSha256) {
    throw new Error(`${laneId} replay receipt did not preserve the frozen execution contract`);
  }
  const sample = await runSuite(
    options,
    laneId,
    provider,
    modulePath,
    outDir,
    options.cleanProcessRuns,
  );
  const actualEvidenceSha256 = sha256Text(JSON.stringify(executionEvidence(sample)));
  return {
    status: actualEvidenceSha256 === expectedEvidenceSha256 ? 'passed' : 'failed',
    receiptPath: relativeReceiptPath,
    receiptSha256: await sha256(receiptPath),
    expectedEvidenceSha256,
    actualEvidenceSha256,
    sample,
  };
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const harness = JSON.parse(
    await readFile(resolve(harnessDir, 'wgsl-compilation-suite.harness.json'), 'utf8'),
  );
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
  const immutableInputs = await Promise.all([
    ...sourcePaths.map(async (path) => ({
      scope: 'upstream',
      path,
      sha256: await sha256(resolve(options.upstream, path)),
    })),
    ...harnessPaths.map(async (path) => ({
      scope: 'repo',
      path,
      sha256: await sha256(resolve(repoRoot, path)),
    })),
  ]);
  const ambientDawnModule = createRequire(
    resolve(options.upstream, 'package.json'),
  ).resolve('webgpu');
  const patchedDawnEvidence = await readPatchedDawnReceipt(options.patchedDawnReceipt);
  const patchedDawnModule = patchedDawnEvidence.modulePath;
  const modules = {
    'dawn-node-webgpu': resolve(options.upstream, 'node_modules/webgpu/index.js'),
    'doe-gpu': resolve(repoRoot, 'packages/doe-gpu/src/index.js'),
  };
  const providers = {};
  for (const [provider, modulePath] of Object.entries(modules)) {
    const laneId = provider === 'dawn-node-webgpu' ? 'W0' : 'D0';
    const probe = await probeProvider(options, provider, modulePath, outDir, hostHardware);
    const processes = [];
    for (let index = 0; index < options.cleanProcessRuns; index += 1) {
      const sample = await runSuite(options, laneId, provider, modulePath, outDir, index);
      processes.push(sample);
      console.log(`[${provider}] process ${index + 1}: ${sample.success ? 'PASS' : 'FAIL'}`);
    }
    const replay = await runReceiptReplay({
      options,
      laneId,
      provider,
      modulePath,
      outDir,
      sourceSample: processes[0],
      immutableInputs,
    });
    console.log(`[${provider}] receipt replay: ${replay.status.toUpperCase()}`);
    providers[provider] = {
      requestedProvider: provider,
      modulePath,
      probe,
      processes,
      replay,
      reliability: summarize(processes),
    };
  }

  let patchedControl = null;
  {
    const provider = 'dawn-node-webgpu';
    const probe = await probeProvider(
      options,
      provider,
      patchedDawnModule,
      outDir,
      hostHardware,
    );
    const processes = [];
    for (let index = 0; index < options.cleanProcessRuns; index += 1) {
      const sample = await runSuite(
        options,
        'P0',
        provider,
        patchedDawnModule,
        outDir,
        index,
      );
      processes.push(sample);
      console.log(`[P0 webgpu@0.3.10] process ${index + 1}: ${sample.success ? 'PASS' : 'FAIL'}`);
    }
    const replay = await runReceiptReplay({
      options,
      laneId: 'P0',
      provider,
      modulePath: patchedDawnModule,
      outDir,
      sourceSample: processes[0],
      immutableInputs,
    });
    console.log(`[P0 webgpu@0.3.10] receipt replay: ${replay.status.toUpperCase()}`);
    patchedControl = {
      requestedProvider: provider,
      modulePath: patchedDawnModule,
      moduleSha256: await sha256(patchedDawnModule),
      packageVersion: '0.3.10',
      packageReceipt: {
        path: patchedDawnEvidence.path,
        sha256: patchedDawnEvidence.sha256,
      },
      probe,
      processes,
      replay,
      reliability: summarize(processes),
    };
  }

  const ownershipRuns = [];
  for (const [laneId, provider, modulePath] of [
    ['I0', 'ambient-node-webgpu', ambientDawnModule],
    ['I1', 'dawn-node-webgpu', modules['dawn-node-webgpu']],
  ]) {
    for (let index = 0; index < options.cleanProcessRuns; index += 1) {
      ownershipRuns.push(await runSuite(
        options,
        laneId,
        provider,
        modulePath,
        outDir,
        index,
      ));
    }
  }
  for (const [laneId, providerResult] of [
    ['W0', providers['dawn-node-webgpu']],
    ['D0', providers['doe-gpu']],
    ['P0', patchedControl],
  ]) {
    if (providerResult === null) continue;
    ownershipRuns.push({
      laneId,
      provider: providerResult.requestedProvider,
      providerModulePath: providerResult.modulePath,
      success: providerResult.probe.hardwareEligible
        && providerResult.reliability.failures === 0
        && providerResult.reliability.crashes === 0
        && providerResult.reliability.timeouts === 0
        && providerResult.replay.status === 'passed',
      contractComplete: ['passed', 'failed'].includes(providerResult.replay.status),
      constructionIssues: [],
      probe: providerResult.probe,
      replay: providerResult.replay,
      reliability: providerResult.reliability,
    });
  }
  const runtimeOwnership = buildRuntimeOwnership({
    runs: ownershipRuns,
    plan: harness.runtimeOwnershipPlan,
    planSha256: sha256Text(JSON.stringify(harness.runtimeOwnershipPlan)),
    ambientModuleSupplied: true,
  });
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
      executionOracle: true,
      semanticFunction: 'smoothStep',
      semanticExactness: 'exact-f32',
    },
    immutableInputs,
    providers,
    patchedControl,
    runtimeOwnership,
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
        replay: item.replay,
        reliability: item.reliability,
      },
    ])),
    shaderSourceOwners: immutableInputs.filter((item) => item.path.startsWith('src/')),
    generatedCorpusBundle: immutableInputs.find((item) => item.path === 'dist/wgsl-fns.esm.js'),
    dynamicallyGeneratedShaderHashes: Object.fromEntries(Object.entries(providers).map(
      ([provider, item]) => [
        provider,
        item.processes.map((sample) => sample.semantic.result?.shader?.sha256 ?? null),
      ],
    )),
    dispatchShape: 'two workgroups of four invocations execute eight smoothStep calls',
    synchronization: 'queue.submit, queue.onSubmittedWorkDone, copyBufferToBuffer, mapAsync(READ)',
    readback: 'eight exact f32 values copied into a MAP_READ staging buffer',
    outputIdentity: Object.fromEntries([
      ...Object.entries(providers),
      ['patched-webgpu-0.3.10', patchedControl],
    ].map(([provider, item]) => [
      provider,
      item.processes.map((sample) => ({
        cleanProcessIndex: sample.cleanProcessIndex,
        success: sample.success,
        exitCode: sample.exitCode,
        signal: sample.signal,
        workerSignals: sample.tap.workerSignals,
        tap: sample.tap,
        nativeCompilerErrorCount: sample.nativeCompilerErrorCount,
        compilationSuccess: sample.compilation.success,
        semanticSuccess: sample.semantic.success,
        semanticResult: sample.semantic.result,
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
      patchedControl: patchedControl === null ? null : {
        modulePath: patchedControl.modulePath,
        moduleSha256: patchedControl.moduleSha256,
        packageVersion: patchedControl.packageVersion,
        identity: patchedControl.probe.identity,
        hardwareEligible: patchedControl.probe.hardwareEligible,
        replay: patchedControl.replay,
        reliability: patchedControl.reliability,
      },
    },
    runtimeOwnership: {
      status: raw.runtimeOwnership.status,
      planSha256: raw.runtimeOwnership.planSha256,
      claimedProperty: raw.runtimeOwnership.claimedProperty,
      missingRequiredLanes: raw.runtimeOwnership.missingRequiredLanes,
      lanes: Object.fromEntries(Object.entries(raw.runtimeOwnership.lanes).map(([laneId, lane]) => [
        laneId,
        {
          status: lane.status,
          runCount: lane.runCount,
          successfulRuns: lane.successfulRuns,
          contractCompleteRuns: lane.contractCompleteRuns,
          constructionIssues: lane.constructionIssues,
          providerModulePaths: lane.providerModulePaths,
        },
      ])),
    },
    limitations: {
      completeUpstreamCorpusIsCompilationOnly: true,
      semanticDispatchFunctionCount: 1,
      semanticDispatchDoesNotEstablishFullCorpusSemantics: true,
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

  const allPassed = [...Object.values(providers), patchedControl].every((provider) =>
    provider.processes.every((sample) => sample.success)
      && provider.replay.status === 'passed');
  if (options.requireAllPass && !allPassed) process.exitCode = 1;
}

main().catch((error) => {
  console.error(error?.stack ?? String(error));
  process.exitCode = 1;
});

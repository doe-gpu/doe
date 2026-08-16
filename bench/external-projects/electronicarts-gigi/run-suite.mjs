#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { access, readFile, readdir, mkdir, writeFile } from 'node:fs/promises';
import { constants as fsConstants } from 'node:fs';
import { spawn } from 'node:child_process';
import { dirname, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { buildRuntimeOwnership } from '../../lib/runtime-ownership-matrix.mjs';
import {
  evidenceSha256,
  semanticLaneEvidence,
  summarize,
} from './suite-evidence.mjs';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const harnessDir = dirname(fileURLToPath(import.meta.url));
const defaultUpstream = resolve(
  repoRoot,
  'bench/out/external-projects/electronicarts-gigi/upstream',
);

function parseArgs(argv) {
  const options = {
    upstream: defaultUpstream,
    providers: ['dawn-node-webgpu', 'doe-gpu'],
    runId: new Date().toISOString().replaceAll(':', '').replaceAll('.', ''),
    pattern: '',
    limit: 0,
    timeoutMs: 120_000,
    requireAllPass: false,
    runtimeOwnership: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === '--upstream') options.upstream = resolve(argv[++index]);
    else if (value === '--providers') options.providers = argv[++index].split(',');
    else if (value === '--run-id') options.runId = argv[++index];
    else if (value === '--pattern') options.pattern = argv[++index];
    else if (value === '--limit') options.limit = Number.parseInt(argv[++index], 10);
    else if (value === '--timeout-ms') options.timeoutMs = Number.parseInt(argv[++index], 10);
    else if (value === '--require-all-pass') options.requireAllPass = true;
    else if (value === '--runtime-ownership') options.runtimeOwnership = true;
    else throw new Error(`unknown argument: ${value}`);
  }
  return options;
}

async function findCases(root) {
  const cases = [];
  async function walk(directory) {
    const entries = await readdir(directory, { withFileTypes: true });
    if (entries.some((entry) => entry.isFile() && entry.name === 'index.js')) {
      cases.push(directory);
      return;
    }
    await Promise.all(
      entries
        .filter((entry) => entry.isDirectory())
        .map((entry) => walk(resolve(directory, entry.name))),
    );
  }
  await walk(root);
  return cases.sort();
}

async function sha256(path) {
  return createHash('sha256').update(await readFile(path)).digest('hex');
}

async function hashTree(root) {
  const files = [];
  async function walk(directory) {
    const entries = (await readdir(directory, { withFileTypes: true }))
      .sort((left, right) => left.name.localeCompare(right.name));
    for (const entry of entries) {
      if (entry.name === 'node_modules' || entry.name === '.git') continue;
      const path = resolve(directory, entry.name);
      if (entry.isDirectory()) await walk(path);
      else if (entry.isFile()) files.push(path);
    }
  }
  await walk(root);
  const digest = createHash('sha256');
  for (const path of files) {
    digest.update(relative(root, path));
    digest.update('\0');
    digest.update(await sha256(path));
    digest.update('\0');
  }
  return { fileCount: files.length, sha256: digest.digest('hex') };
}

function providerEnvironment(suiteRoot, provider, providerModulePath) {
  return {
    ...process.env,
    DOE_EXTERNAL_WEBGPU_PROVIDER: provider,
    DOE_EXTERNAL_DAWN_MODULE: provider === 'dawn-node-webgpu'
      ? providerModulePath
      : resolve(suiteRoot, 'node_modules/webgpu/index.js'),
    DOE_EXTERNAL_DOE_MODULE: resolve(
      repoRoot,
      'packages/doe-gpu/src/vendor/webgpu/index.js',
    ),
  };
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
      // Process exit races with /proc reads; the final observed peak remains valid.
    }
  }, 10);
  const timeout = setTimeout(() => {
    timedOut = true;
    child.kill('SIGKILL');
  }, timeoutMs);
  const result = await new Promise((resolveResult, reject) => {
    child.once('error', reject);
    child.once('exit', (code, signal) => resolveResult({ code, signal }));
  });
  clearTimeout(timeout);
  clearInterval(memoryPoll);
  return {
    exitCode: result.code,
    signal: result.signal,
    timedOut,
    crashed: !timedOut && result.signal !== null,
    durationMs: Number(process.hrtime.bigint() - started) / 1e6,
    peakMemoryBytes,
    stdout: stdout.slice(-16_384),
    stderr: stderr.slice(-16_384),
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
      // A listed but inaccessible render node cannot support hardware evidence.
    }
  }
  return {
    renderNodes,
    accessibleRenderNodes,
    physicalGpuEligible: accessibleRenderNodes.length > 0,
  };
}

async function probeProvider(options, suiteRoot, lane, hostHardware) {
  const result = await runProcess(
    process.execPath,
    ['--loader', resolve(harnessDir, 'provider-loader.mjs'), resolve(harnessDir, 'probe-provider.mjs')],
    {
      cwd: suiteRoot,
      env: providerEnvironment(suiteRoot, lane.provider, lane.providerModulePath),
      timeoutMs: options.timeoutMs,
    },
  );
  const marker = result.stdout
    .split('\n')
    .find((line) => line.startsWith('DOE_GIGI_PROVIDER_PROBE='));
  const identity = marker ? JSON.parse(marker.slice(marker.indexOf('=') + 1)) : null;
  const identityText = JSON.stringify(identity ?? {}).toLowerCase();
  const softwareRenderer = /llvmpipe|swiftshader|software renderer/.test(identityText);
  return {
    ...result,
    identity,
    softwareRenderer,
    hardwareEligible: result.exitCode === 0
      && identity !== null
      && !softwareRenderer
      && hostHardware.physicalGpuEligible,
  };
}

async function runCase(options, suiteRoot, caseDirectory, lane) {
  const args = lane.ambient
    ? ['.']
    : ['--loader', resolve(harnessDir, 'provider-loader.mjs'), '.'];
  const result = await runProcess(
    process.execPath,
    args,
    {
      cwd: caseDirectory,
      env: lane.ambient
        ? process.env
        : providerEnvironment(suiteRoot, lane.provider, lane.providerModulePath),
      timeoutMs: options.timeoutMs,
    },
  );
  return {
    caseId: relative(resolve(suiteRoot, 'UnitTests'), caseDirectory),
    indexSha256: await sha256(resolve(caseDirectory, 'index.js')),
    success: result.exitCode === 0 && !result.timedOut && !result.crashed,
    ...result,
  };
}

async function runLane(options, suiteRoot, cases, lane, hostHardware) {
  const probe = await probeProvider(options, suiteRoot, lane, hostHardware);
  if (probe.exitCode !== 0 || probe.identity?.provider?.id !== lane.provider) {
    throw new Error(`provider identity probe failed for ${lane.laneId}: ${probe.stderr}`);
  }
  const results = [];
  for (const caseDirectory of cases) {
    const result = await runCase(options, suiteRoot, caseDirectory, lane);
    results.push(result);
    console.log(`[${lane.laneId}/${lane.provider}] ${result.success ? 'PASS' : 'FAIL'} ${result.caseId}`);
  }
  const summary = summarize(results);
  return {
    laneId: lane.laneId,
    provider: lane.provider,
    providerModulePath: lane.providerModulePath,
    providerModuleSha256: await sha256(lane.providerModulePath),
    ambient: lane.ambient,
    receiptMode: lane.receiptMode,
    probe,
    summary,
    results,
    success: summary.failures === 0,
    contractComplete: !lane.replayRequired,
    constructionIssues: lane.replayRequired ? ['semantic replay pending'] : [],
  };
}

async function immutableInputs(options, suiteRoot, providerPaths) {
  const pathSpecs = [
    ['repo', resolve(harnessDir, 'generated-webgpu-suite.harness.json')],
    ['repo', resolve(harnessDir, 'oracle.md')],
    ['repo', resolve(harnessDir, 'probe-provider.mjs')],
    ['repo', resolve(harnessDir, 'provider-dawn.mjs')],
    ['repo', resolve(harnessDir, 'provider-doe.mjs')],
    ['repo', resolve(harnessDir, 'provider-loader.mjs')],
    ['repo', resolve(harnessDir, 'run-suite.mjs')],
    ['repo', resolve(harnessDir, 'suite-evidence.mjs')],
    ['upstream', resolve(suiteRoot, 'Shared.js')],
    ['upstream', resolve(suiteRoot, 'UnitTestLogic.js')],
    ['incumbent-package', resolve(dirname(providerPaths.pinnedDawn), 'package.json')],
    ['incumbent-entrypoint', providerPaths.pinnedDawn],
    ['incumbent-runtime', resolve(dirname(providerPaths.pinnedDawn), 'dist/linux-x64.dawn.node')],
    ['doe-entrypoint', providerPaths.doe],
    ['doe-runtime', resolve(repoRoot, 'runtime/zig/zig-out/lib/libwebgpu_doe.so')],
    ['doe-runtime', resolve(repoRoot, 'runtime/zig/zig-out/share/doe-build-metadata.json')],
  ];
  const files = await Promise.all(pathSpecs.map(async ([scope, path]) => ({
    scope,
    path: path.startsWith(`${repoRoot}/`)
      ? relative(repoRoot, path)
      : path.startsWith(`${options.upstream}/`)
        ? relative(options.upstream, path)
        : path,
    sha256: await sha256(path),
  })));
  return {
    files,
    generatedSuiteTree: await hashTree(suiteRoot),
  };
}

async function runReceiptReplay({
  options,
  suiteRoot,
  cases,
  lane,
  sourceRun,
  hostHardware,
  immutable,
  outputDir,
}) {
  const receiptRelativePath = `replay-receipts/${lane.laneId}.json`;
  const receiptPath = resolve(outputDir, receiptRelativePath);
  await mkdir(dirname(receiptPath), { recursive: true });
  const expectedEvidenceSha256 = evidenceSha256(semanticLaneEvidence(sourceRun));
  const receipt = {
    schemaVersion: 1,
    artifactKind: 'gigi-generated-webgpu-suite-replay-receipt',
    laneId: lane.laneId,
    provider: lane.provider,
    providerModulePath: lane.providerModulePath,
    immutableInputsSha256: evidenceSha256(immutable),
    expectedEvidenceSha256,
  };
  await writeFile(receiptPath, `${JSON.stringify(receipt, null, 2)}\n`);
  const loaded = JSON.parse(await readFile(receiptPath, 'utf8'));
  if (loaded.laneId !== lane.laneId
    || loaded.provider !== lane.provider
    || loaded.providerModulePath !== lane.providerModulePath
    || loaded.expectedEvidenceSha256 !== expectedEvidenceSha256) {
    throw new Error(`${lane.laneId} replay receipt did not preserve the frozen contract`);
  }
  const sample = await runLane(options, suiteRoot, cases, lane, hostHardware);
  const actualEvidenceSha256 = evidenceSha256(semanticLaneEvidence(sample));
  return {
    status: actualEvidenceSha256 === expectedEvidenceSha256 ? 'passed' : 'failed',
    receiptPath: receiptRelativePath,
    receiptSha256: await sha256(receiptPath),
    expectedEvidenceSha256,
    actualEvidenceSha256,
    sample,
  };
}

function compactOwnership(runtimeOwnership) {
  return {
    ...runtimeOwnership,
    lanes: Object.fromEntries(Object.entries(runtimeOwnership.lanes).map(([laneId, lane]) => [
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
  };
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const suiteRoot = resolve(options.upstream, '_GeneratedCode/UnitTests/WebGPU');
  const commit = (await runProcess('git', ['rev-parse', 'HEAD'], {
    cwd: options.upstream,
    env: process.env,
    timeoutMs: options.timeoutMs,
  })).stdout.trim();
  if (commit !== '401386cfd7c6e39e549d939e44d99bd5b49cd14d') {
    throw new Error(`unexpected Gigi commit: ${commit}`);
  }
  let cases = await findCases(resolve(suiteRoot, 'UnitTests'));
  if (options.pattern) cases = cases.filter((path) => relative(suiteRoot, path).includes(options.pattern));
  if (options.limit > 0) cases = cases.slice(0, options.limit);

  const hostHardware = await inspectHostHardware();
  const harness = JSON.parse(
    await readFile(resolve(harnessDir, 'generated-webgpu-suite.harness.json'), 'utf8'),
  );
  const requireFromSuite = createRequire(resolve(suiteRoot, 'ambient-resolution.cjs'));
  const providerPaths = {
    ambientDawn: requireFromSuite.resolve('webgpu'),
    pinnedDawn: resolve(suiteRoot, 'node_modules/webgpu/index.js'),
    doe: resolve(repoRoot, 'packages/doe-gpu/src/vendor/webgpu/index.js'),
  };
  const incumbentPackage = JSON.parse(
    await readFile(resolve(dirname(providerPaths.pinnedDawn), 'package.json'), 'utf8'),
  );
  if (incumbentPackage.name !== 'webgpu' || incumbentPackage.version !== '0.4.0') {
    throw new Error(
      `pinned incumbent mismatch: expected webgpu@0.4.0, received ${incumbentPackage.name}@${incumbentPackage.version}`,
    );
  }
  if (providerPaths.ambientDawn !== providerPaths.pinnedDawn) {
    throw new Error(
      `ambient incumbent resolved outside the pinned application package: ${providerPaths.ambientDawn}`,
    );
  }
  const outDir = resolve(
    repoRoot,
    'bench/out/external-projects/electronicarts-gigi',
    options.runId,
  );
  await mkdir(outDir, { recursive: true });

  const providers = {};
  let ownershipLanes = null;
  let replays = null;
  let runtimeOwnership = null;
  let immutable = null;
  if (options.runtimeOwnership) {
    const laneConfigs = {
      I0: {
        laneId: 'I0',
        provider: 'dawn-node-webgpu',
        providerModulePath: providerPaths.ambientDawn,
        ambient: true,
        receiptMode: 'disabled',
        replayRequired: false,
      },
      I1: {
        laneId: 'I1',
        provider: 'dawn-node-webgpu',
        providerModulePath: providerPaths.pinnedDawn,
        ambient: false,
        receiptMode: 'disabled',
        replayRequired: false,
      },
      W0: {
        laneId: 'W0',
        provider: 'dawn-node-webgpu',
        providerModulePath: providerPaths.pinnedDawn,
        ambient: false,
        receiptMode: 'enabled',
        replayRequired: true,
      },
      D0: {
        laneId: 'D0',
        provider: 'doe-gpu',
        providerModulePath: providerPaths.doe,
        ambient: false,
        receiptMode: 'enabled',
        replayRequired: true,
      },
    };
    immutable = await immutableInputs(options, suiteRoot, providerPaths);
    ownershipLanes = {};
    for (const laneId of ['I0', 'I1', 'W0', 'D0']) {
      ownershipLanes[laneId] = await runLane(
        options,
        suiteRoot,
        cases,
        laneConfigs[laneId],
        hostHardware,
      );
    }
    replays = {};
    for (const laneId of ['W0', 'D0']) {
      const replay = await runReceiptReplay({
        options,
        suiteRoot,
        cases,
        lane: laneConfigs[laneId],
        sourceRun: ownershipLanes[laneId],
        hostHardware,
        immutable,
        outputDir: outDir,
      });
      replays[laneId] = replay;
      ownershipLanes[laneId].contractComplete = replay.status === 'passed';
      ownershipLanes[laneId].constructionIssues = replay.status === 'passed'
        ? []
        : ['semantic replay mismatch'];
    }
    const ownershipPlanSha256 = evidenceSha256(harness.runtimeOwnershipPlan);
    runtimeOwnership = compactOwnership(buildRuntimeOwnership({
      runs: Object.values(ownershipLanes),
      plan: harness.runtimeOwnershipPlan,
      planSha256: ownershipPlanSha256,
      ambientModuleSupplied: true,
    }));
    providers['dawn-node-webgpu'] = ownershipLanes.W0;
    providers['doe-gpu'] = ownershipLanes.D0;
  } else {
    for (const provider of options.providers) {
      const lane = {
        laneId: provider,
        provider,
        providerModulePath: provider === 'dawn-node-webgpu'
          ? providerPaths.pinnedDawn
          : providerPaths.doe,
        ambient: false,
        receiptMode: 'diagnostic',
        replayRequired: false,
      };
      providers[provider] = await runLane(options, suiteRoot, cases, lane, hostHardware);
    }
  }

  const generatedSuiteTree = immutable?.generatedSuiteTree ?? await hashTree(suiteRoot);
  const payload = {
    schemaVersion: 1,
    artifactKind: 'gigi-generated-webgpu-suite-run',
    generatedAt: new Date().toISOString(),
    actorId: 'electronicarts-gigi',
    harnessId: 'generated-webgpu-suite',
    upstream: {
      repositoryUrl: 'https://github.com/electronicarts/gigi',
      commit,
      licenseIdentifier: 'LicenseRef-EA-BSD-3-Clause-With-Marks',
    },
    sameWork: {
      caseCount: cases.length,
      caseIds: cases.map((path) => relative(resolve(suiteRoot, 'UnitTests'), path)),
      applicationSourceUnchanged: true,
      shaderSourceUnchanged: true,
      generatedSuiteTree,
    },
    hostHardware,
    providerPackages: {
      ambientDawnModule: providerPaths.ambientDawn,
      pinnedDawnModule: providerPaths.pinnedDawn,
      pinnedDawnVersion: incumbentPackage.version,
      doeModule: providerPaths.doe,
    },
    immutableInputs: immutable,
    providers,
    ownershipLanes,
    replays,
    runtimeOwnership,
  };
  const outPath = resolve(outDir, 'raw-suite.json');
  await writeFile(outPath, `${JSON.stringify(payload, null, 2)}\n`);
  if (options.runtimeOwnership) {
    const receiptSummary = {
      schemaVersion: 1,
      artifactKind: 'gigi-generated-webgpu-suite-receipt-summary',
      generatedAt: payload.generatedAt,
      upstream: payload.upstream,
      sameWork: payload.sameWork,
      hostHardware,
      providerPackages: payload.providerPackages,
      immutableInputsSha256: evidenceSha256(immutable),
      rawSuiteSha256: await sha256(outPath),
      lanes: Object.fromEntries(Object.entries(ownershipLanes).map(([laneId, lane]) => [
        laneId,
        {
          provider: lane.provider,
          providerModulePath: lane.providerModulePath,
          providerModuleSha256: lane.providerModuleSha256,
          ambient: lane.ambient,
          receiptMode: lane.receiptMode,
          summary: lane.summary,
          contractComplete: lane.contractComplete,
          constructionIssues: lane.constructionIssues,
        },
      ])),
      replays: Object.fromEntries(Object.entries(replays).map(([laneId, replay]) => [
        laneId,
        {
          status: replay.status,
          receiptPath: replay.receiptPath,
          receiptSha256: replay.receiptSha256,
          expectedEvidenceSha256: replay.expectedEvidenceSha256,
          actualEvidenceSha256: replay.actualEvidenceSha256,
        },
      ])),
      runtimeOwnership,
      receiptOverhead: {
        status: 'not-isolated',
        reason: 'The diagnostic binds replay and receipt construction but does not isolate receipt overhead from process and provider variance.',
      },
    };
    await writeFile(
      resolve(outDir, 'receipt-summary.json'),
      `${JSON.stringify(receiptSummary, null, 2)}\n`,
    );
  }
  console.log(`WROTE ${outPath}`);
  if (options.requireAllPass && Object.values(providers).some(({ summary }) => summary.failures > 0)) {
    process.exitCode = 1;
  }
}

await main();

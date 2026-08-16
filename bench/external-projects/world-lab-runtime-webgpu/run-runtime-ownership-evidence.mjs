#!/usr/bin/env node

import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { constants as fsConstants } from 'node:fs';
import { access, mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const harnessDir = dirname(fileURLToPath(import.meta.url));
const runnerPath = fileURLToPath(import.meta.url);
const repoRoot = resolve(harnessDir, '../../..');
const upstreamRoot = resolve(
  repoRoot,
  'bench/out/external-projects/world-lab-runtime-webgpu/upstream',
);
const packageRoot = resolve(upstreamRoot, 'packages/runtime-webgpu');
const expectedCommit = '4ef19794501d565586a73b991ea569834c54afad';
const planPath = resolve(harnessDir, 'runtime-ownership-evidence-qm0.plan.json');
const evidenceProviderPath = resolve(harnessDir, 'evidence-provider.mjs');
const directConfigPath = resolve(harnessDir, 'vitest-provider.config.mjs');
const governedConfigPath = resolve(harnessDir, 'vitest-evidence-provider.config.mjs');
const providerProbePath = resolve(harnessDir, 'provider-probe.mjs');
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
    runId: 'world-lab-consumer-execution-runtime-ownership-qm0-v1',
    cleanProcessRuns: 3,
    timeoutMs: 120_000,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === '--run-id') options.runId = argv[++index];
    else if (value === '--clean-process-runs') {
      options.cleanProcessRuns = Number.parseInt(argv[++index], 10);
    } else if (value === '--timeout-ms') {
      options.timeoutMs = Number.parseInt(argv[++index], 10);
    } else throw new Error(`unknown argument: ${value}`);
  }
  if (!/^[A-Za-z0-9._-]+$/.test(options.runId)) {
    throw new Error('--run-id must contain only letters, numbers, dot, underscore, or hyphen');
  }
  if (!Number.isInteger(options.cleanProcessRuns) || options.cleanProcessRuns < 1) {
    throw new Error('--clean-process-runs must be a positive integer');
  }
  return options;
}

function sha256Text(value) {
  return createHash('sha256').update(value).digest('hex');
}

async function sha256File(path) {
  return sha256Text(await readFile(path));
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
      // Process exit races with /proc reads; retain the last observation.
    }
  }, 10);
  const timeout = setTimeout(() => {
    timedOut = true;
    child.kill('SIGKILL');
  }, timeoutMs);
  const termination = await new Promise((accept, reject) => {
    child.once('error', reject);
    child.once('exit', (exitCode, signal) => accept({ exitCode, signal }));
  });
  clearInterval(memoryPoll);
  clearTimeout(timeout);
  return {
    ...termination,
    timedOut,
    crashed: !timedOut && termination.signal !== null,
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
      // An inaccessible render node cannot support hardware evidence.
    }
  }
  return {
    renderNodes,
    accessibleRenderNodes,
    physicalGpuEligible: accessibleRenderNodes.length > 0,
  };
}

function providerEnvironment({ providerId, baseModule, providerModule, evidencePrefix, runtimeDir }) {
  return {
    ...process.env,
    DOE_EXTERNAL_WEBGPU_PROVIDER: providerId,
    DOE_EXTERNAL_PROVIDER_MODULE: providerModule,
    DOE_WORLD_LAB_BASE_PROVIDER_MODULE: baseModule,
    DOE_WORLD_LAB_EVIDENCE_PATH: evidencePrefix,
    DOE_EXTERNAL_UPSTREAM_ROOT: upstreamRoot,
    REQUIRE_WEBGPU: '1',
    XDG_RUNTIME_DIR: runtimeDir,
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
  const titles = new Set(assertions.map((assertion) => assertion.title));
  return report?.success === true
    && report.numTotalTests === expectedAssertions.length
    && report.numPassedTests === expectedAssertions.length
    && report.numFailedTests === 0
    && report.numPendingTests === 0
    && assertions.every((assertion) => assertion.status === 'passed')
    && expectedAssertions.every((title) => titles.has(title));
}

function normalizeWorkerEvidence(worker) {
  const moduleSourceById = new Map(worker.shaderModules
    .filter((module) => module.id !== null)
    .map((module) => [module.id, module.sourceSha256]));
  const computeById = new Map(worker.computePipelines.map((pipeline) => [pipeline.id, {
    sourceSha256: moduleSourceById.get(pipeline.moduleId) ?? null,
    entryPoint: pipeline.entryPoint,
  }]));
  const renderById = new Map(worker.renderPipelines.map((pipeline) => [pipeline.id, {
    vertexSourceSha256: moduleSourceById.get(pipeline.vertexModuleId) ?? null,
    vertexEntryPoint: pipeline.vertexEntryPoint,
    fragmentSourceSha256: moduleSourceById.get(pipeline.fragmentModuleId) ?? null,
    fragmentEntryPoint: pipeline.fragmentEntryPoint,
  }]));
  return {
    shaderAttempts: worker.shaderModules.map((module) => ({
      label: module.label,
      sourceSha256: module.sourceSha256,
      sourceBytes: module.sourceBytes,
      workgroupSize: module.workgroupSize,
      creation: module.creation,
      errorName: module.errorName ?? null,
    })),
    computePipelines: [...computeById.values()],
    renderPipelines: [...renderById.values()],
    dispatches: worker.dispatches.map((dispatch) => ({
      pipeline: computeById.get(dispatch.pipelineId) ?? null,
      workgroups: dispatch.workgroups,
    })),
    draws: worker.draws.map((draw) => ({
      pipeline: renderById.get(draw.pipelineId) ?? null,
      vertexCount: draw.vertexCount,
      instanceCount: draw.instanceCount,
      firstVertex: draw.firstVertex,
      firstInstance: draw.firstInstance,
    })),
    submissions: worker.submissions,
    readbacks: worker.readbacks.map((readback) => ({
      bufferSize: readback.bufferSize,
      offset: readback.offset,
      size: readback.size,
      sha256: readback.sha256,
    })),
  };
}

function evidenceSummary(workers) {
  const normalized = workers.map(normalizeWorkerEvidence)
    .sort((left, right) => JSON.stringify(left).localeCompare(JSON.stringify(right)));
  const shape = normalized.map((worker) => ({
    shaderSources: worker.shaderAttempts.map((shader) => ({
      label: shader.label,
      sourceSha256: shader.sourceSha256,
      sourceBytes: shader.sourceBytes,
      workgroupSize: shader.workgroupSize,
    })),
    computePipelines: worker.computePipelines,
    renderPipelines: worker.renderPipelines,
    dispatches: worker.dispatches,
    draws: worker.draws,
    submissions: worker.submissions,
  }));
  return {
    workerCount: normalized.length,
    shaderAttemptCount: normalized.reduce((sum, worker) => sum + worker.shaderAttempts.length, 0),
    dispatchCount: normalized.reduce((sum, worker) => sum + worker.dispatches.length, 0),
    drawCount: normalized.reduce((sum, worker) => sum + worker.draws.length, 0),
    submissionCount: normalized.reduce((sum, worker) => sum + worker.submissions.length, 0),
    readbackCount: normalized.reduce((sum, worker) => sum + worker.readbacks.length, 0),
    shapeIdentitySha256: sha256Text(JSON.stringify(shape)),
    semanticEvidenceSha256: sha256Text(JSON.stringify(normalized)),
    outputIdentitySha256: sha256Text(JSON.stringify(
      normalized.map((worker) => worker.readbacks),
    )),
    workers: normalized,
  };
}

async function collectEvidence(processDir, prefix, providerId) {
  const names = (await readdir(processDir))
    .filter((name) => name.startsWith(`${prefix}.`) && name.endsWith('.json'))
    .sort();
  const workers = [];
  for (const name of names) {
    const worker = JSON.parse(await readFile(resolve(processDir, name), 'utf8'));
    if (worker.providerId !== providerId) {
      throw new Error(`evidence provider mismatch in ${name}`);
    }
    workers.push(worker);
  }
  return evidenceSummary(workers);
}

async function runLaneProcess(options, lane, outDir, index) {
  const processDir = resolve(outDir, 'processes', lane.id, String(index + 1));
  const runtimeDir = resolve(outDir, 'runtime', lane.id, String(index + 1));
  await Promise.all([
    mkdir(processDir, { recursive: true }),
    mkdir(runtimeDir, { recursive: true }),
  ]);
  const reportPath = resolve(processDir, 'vitest.json');
  const evidencePrefix = resolve(processDir, 'provider-evidence');
  const result = await runProcess(process.execPath, [
    resolve(upstreamRoot, 'node_modules/vitest/vitest.mjs'),
    'run',
    ...testFiles,
    '--config',
    lane.governed ? governedConfigPath : directConfigPath,
    '--reporter=json',
    `--outputFile=${reportPath}`,
  ], {
    cwd: packageRoot,
    env: providerEnvironment({
      providerId: lane.providerId,
      baseModule: lane.baseModule,
      providerModule: lane.governed ? evidenceProviderPath : lane.baseModule,
      evidencePrefix,
      runtimeDir,
    }),
    timeoutMs: options.timeoutMs,
  });
  let vitestReport = null;
  try {
    vitestReport = JSON.parse(await readFile(reportPath, 'utf8'));
  } catch {
    // The process result retains the execution failure when no report exists.
  }
  const assertions = normalizeAssertions(vitestReport);
  const governedEvidence = lane.governed
    ? await collectEvidence(processDir, 'provider-evidence', lane.providerId)
    : null;
  const evidenceComplete = !lane.governed || (
    governedEvidence.workerCount > 0
    && governedEvidence.shaderAttemptCount > 0
    && governedEvidence.submissionCount > 0
    && governedEvidence.readbackCount > 0
    && (governedEvidence.dispatchCount > 0 || governedEvidence.drawCount > 0)
  );
  return {
    laneId: lane.id,
    providerId: lane.providerId,
    cleanProcessIndex: index + 1,
    success: result.exitCode === 0
      && !result.timedOut
      && !result.crashed
      && oraclePass(vitestReport, assertions)
      && evidenceComplete,
    ...result,
    assertionIdentitySha256: sha256Text(JSON.stringify(
      assertions.map(({ title, status }) => ({ title, status })),
    )),
    assertions,
    evidence: governedEvidence,
  };
}

async function probeProvider(options, lane, outDir, hostHardware) {
  const runtimeDir = resolve(outDir, 'runtime', `${lane.id}-probe`);
  await mkdir(runtimeDir, { recursive: true });
  const result = await runProcess(process.execPath, [providerProbePath], {
    cwd: packageRoot,
    env: providerEnvironment({
      providerId: lane.providerId,
      baseModule: lane.baseModule,
      providerModule: lane.baseModule,
      evidencePrefix: resolve(outDir, `${lane.id}-probe-evidence`),
      runtimeDir,
    }),
    timeoutMs: options.timeoutMs,
  });
  const marker = result.stdout.split('\n')
    .find((line) => line.startsWith('DOE_WORLD_LAB_PROVIDER_PROBE='));
  const identity = marker ? JSON.parse(marker.slice(marker.indexOf('=') + 1)) : null;
  const softwareRenderer = /llvmpipe|swiftshader|software renderer|software-renderer/u
    .test(JSON.stringify(identity ?? {}).toLowerCase());
  return {
    ...result,
    identity,
    identityMatches: identity?.provider?.id === lane.providerId
      && identity?.provider?.modulePath === lane.baseModule,
    softwareRenderer,
    hardwareEligible: result.exitCode === 0
      && identity?.adapter !== null
      && !softwareRenderer
      && hostHardware.physicalGpuEligible,
  };
}

function summarize(runs) {
  return {
    cleanProcessRuns: runs.length,
    successes: runs.filter((run) => run.success).length,
    failures: runs.filter((run) => !run.success).length,
    crashes: runs.filter((run) => run.crashed).length,
    hangs: runs.filter((run) => run.timedOut).length,
    timeouts: runs.filter((run) => run.timedOut).length,
    peakMemoryBytes: Math.max(0, ...runs.map((run) => run.peakMemoryBytes)),
  };
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const outDir = resolve(
    repoRoot,
    'bench/out/external-projects/world-lab-runtime-webgpu',
    options.runId,
  );
  await mkdir(outDir, { recursive: false });
  const commitResult = await runProcess('git', ['rev-parse', 'HEAD'], {
    cwd: upstreamRoot,
    env: process.env,
    timeoutMs: options.timeoutMs,
  });
  const commit = commitResult.stdout.trim();
  if (commit !== expectedCommit) throw new Error(`unexpected World Labs commit: ${commit}`);

  const dawnModule = resolve(upstreamRoot, 'node_modules/webgpu/index.js');
  const doeModule = resolve(repoRoot, 'packages/doe-gpu/src/index.js');
  await Promise.all([
    dawnModule,
    doeModule,
    evidenceProviderPath,
    planPath,
  ].map((path) => access(path)));
  const lanes = [
    { id: 'I0', providerId: 'dawn-node-webgpu', baseModule: dawnModule, governed: false },
    { id: 'I1', providerId: 'dawn-node-webgpu', baseModule: dawnModule, governed: false },
    { id: 'W0', providerId: 'dawn-node-webgpu', baseModule: dawnModule, governed: true },
    { id: 'D0', providerId: 'doe-gpu', baseModule: doeModule, governed: true },
  ];
  const hostHardware = await inspectHostHardware();
  const results = {};
  for (const lane of lanes) {
    const probe = await probeProvider(options, lane, outDir, hostHardware);
    const runs = [];
    for (let index = 0; index < options.cleanProcessRuns; index += 1) {
      const run = await runLaneProcess(options, lane, outDir, index);
      runs.push(run);
      process.stdout.write(`${lane.id} process ${index + 1}: ${run.success ? 'PASS' : 'FAIL'}\n`);
    }
    results[lane.id] = { lane, probe, summary: summarize(runs), runs };
  }

  const allRunsPass = Object.values(results).every((lane) => (
    lane.probe.identityMatches
    && lane.probe.hardwareEligible
    && lane.summary.failures === 0
  ));
  const laneReproducible = Object.fromEntries(Object.entries(results).map(([id, lane]) => {
    const identities = lane.runs.map((run) => (
      run.evidence?.semanticEvidenceSha256 ?? run.assertionIdentitySha256
    ));
    return [id, new Set(identities).size === 1];
  }));
  const governedShapeMatch = results.W0.runs[0]?.evidence?.shapeIdentitySha256
    === results.D0.runs[0]?.evidence?.shapeIdentitySha256;
  const passed = allRunsPass
    && Object.values(laneReproducible).every(Boolean)
    && governedShapeMatch;
  const artifact = {
    schemaVersion: 1,
    artifactKind: 'world-lab-runtime-ownership-evidence-result',
    status: passed ? 'passed' : 'failed',
    generatedAt: new Date().toISOString(),
    plan: { path: planPath, sha256: await sha256File(planPath) },
    upstream: {
      repositoryUrl: 'https://github.com/saabi/world-lab',
      commit,
      packagePath: 'packages/runtime-webgpu',
    },
    host: {
      platform: process.platform,
      architecture: process.arch,
      node: process.version,
      ...hostHardware,
    },
    implementation: {
      runner: { path: runnerPath, sha256: await sha256File(runnerPath) },
      evidenceProvider: {
        path: evidenceProviderPath,
        sha256: await sha256File(evidenceProviderPath),
      },
      evidenceSetup: {
        path: resolve(harnessDir, 'evidence-webgpu-setup.mjs'),
        sha256: await sha256File(resolve(harnessDir, 'evidence-webgpu-setup.mjs')),
      },
      evidenceConfig: {
        path: governedConfigPath,
        sha256: await sha256File(governedConfigPath),
      },
    },
    frozenWork: {
      testFiles: await Promise.all(testFiles.map(async (path) => ({
        path: `packages/runtime-webgpu/${path}`,
        sha256: await sha256File(resolve(packageRoot, path)),
      }))),
      expectedAssertions,
    },
    lanes: results,
    adjudication: {
      allRunsPass,
      laneReproducible,
      governedShapeMatch,
      boundedPatchLaneAuthorized: false,
      runtimeOwnershipCredit: false,
      runtimeOwnershipDecision: passed
        ? 'rejected-governed-incumbent-closes-frozen-outcome'
        : 'not-adjudicated',
      performanceCredit: false,
      promotionCredit: false,
      releaseCredit: false,
    },
  };
  artifact.sha256 = sha256Text(JSON.stringify(artifact));
  const resultPath = resolve(outDir, 'result.json');
  await writeFile(resultPath, `${JSON.stringify(artifact, null, 2)}\n`);
  process.stdout.write(`${resultPath}\n`);
  if (!passed) process.exitCode = 1;
}

await main();

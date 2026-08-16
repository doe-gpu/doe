#!/usr/bin/env node

import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { access, copyFile, mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const harnessDir = dirname(fileURLToPath(import.meta.url));
const runnerPath = fileURLToPath(import.meta.url);
const repoRoot = resolve(harnessDir, '../../..');
const upstreamRoot = resolve(
  repoRoot,
  'bench/out/external-projects/world-lab-runtime-webgpu/upstream',
);
const packageRoot = resolve(upstreamRoot, 'packages/runtime-webgpu');
const expectedCommit = '4ef19794501d565586a73b991ea569834c54afad';
const workspacePlanPath = resolve(harnessDir, 'package-compilation-observer-qm2.plan.json');
const cleanInstallPlanPath = resolve(
  harnessDir,
  'package-native-identity-clean-install-qm3.plan.json',
);
const renderIdentityPlanPath = resolve(
  harnessDir,
  'package-native-render-identity-clean-install-qm4.plan.json',
);
const renderCompletionIdentityPlanPath = resolve(
  harnessDir,
  'package-native-render-identity-clean-install-qm5.plan.json',
);
const workspaceProviderPath = resolve(harnessDir, 'package-observer-provider.mjs');
const cleanInstallProviderTemplatePath = resolve(
  harnessDir,
  'package-observer-clean-install-provider.mjs',
);
const configPath = resolve(harnessDir, 'vitest-evidence-provider.config.mjs');
const setupPath = resolve(harnessDir, 'evidence-webgpu-setup.mjs');
const workspaceObserverPath = resolve(repoRoot, 'packages/doe-gpu/src/observe.js');
const workspaceObserverSchemaPath = resolve(
  repoRoot,
  'packages/doe-gpu/assets/transparent-webgpu-observation.schema.json',
);
const npm = process.platform === 'win32' ? 'npm.cmd' : 'npm';
const platformPackageName = new Map([
  ['linux-x64', 'doe-gpu-linux-x64'],
  ['darwin-arm64', 'doe-gpu-darwin-arm64'],
]).get(`${process.platform}-${process.arch}`);
let validateTransparentWebGPUObservation;
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
const expectedCounts = {
  workerCount: 3,
  shaderAttemptCount: 13,
  compilationInfoCount: 8,
  dispatchCount: 3,
  drawCount: 2,
  submissionCount: 5,
  readbackCount: 8,
};
const expectedInvalidShaderSourceSha256 =
  'sha256:53672fc645bfd78a8635f16261c9212ad39fc1b12aa95caaf3557221f16632ce';

function parseArgs(argv) {
  const options = {
    runId: null,
    timeoutMs: 120_000,
    cleanInstall: false,
    renderIdentity: false,
    renderCompletionIdentity: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === '--run-id') options.runId = argv[++index];
    else if (value === '--timeout-ms') options.timeoutMs = Number.parseInt(argv[++index], 10);
    else if (value === '--clean-install') options.cleanInstall = true;
    else if (value === '--render-identity') {
      options.cleanInstall = true;
      options.renderIdentity = true;
    }
    else if (value === '--render-completion-identity') {
      options.cleanInstall = true;
      options.renderIdentity = true;
      options.renderCompletionIdentity = true;
    }
    else throw new Error(`unknown argument: ${value}`);
  }
  options.runId ??= options.renderCompletionIdentity
    ? 'world-lab-package-native-render-identity-clean-install-qm5-v1'
    : options.renderIdentity
    ? 'world-lab-package-native-render-identity-clean-install-qm4-v1'
    : options.cleanInstall
      ? 'world-lab-package-native-identity-clean-install-qm3-v1'
      : 'world-lab-package-compilation-observer-qm2-v1';
  if (!/^[A-Za-z0-9._-]+$/u.test(options.runId)) {
    throw new Error('--run-id contains unsupported characters');
  }
  if (!Number.isInteger(options.timeoutMs) || options.timeoutMs < 1) {
    throw new Error('--timeout-ms must be a positive integer');
  }
  return options;
}

function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

async function sha256File(path) {
  return sha256(await readFile(path));
}

async function runProcess(command, args, { cwd, env, timeoutMs }) {
  const started = process.hrtime.bigint();
  const child = spawn(command, args, { cwd, env, stdio: ['ignore', 'pipe', 'pipe'] });
  let stdout = '';
  let stderr = '';
  let timedOut = false;
  let peakProcessTreeMemoryBytes = 0;
  let memoryPollActive = false;
  let memoryPollError = null;
  let memoryPollPromise = Promise.resolve();
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', (chunk) => { stdout += chunk; });
  child.stderr.on('data', (chunk) => { stderr += chunk; });
  const memoryPoll = setInterval(() => {
    if (memoryPollActive) return;
    memoryPollActive = true;
    memoryPollPromise = (async () => {
      const processRows = [];
      const entries = await readdir('/proc', { withFileTypes: true });
      await Promise.all(entries
        .filter((entry) => entry.isDirectory() && /^[0-9]+$/u.test(entry.name))
        .map(async (entry) => {
          try {
            const status = await readFile(`/proc/${entry.name}/status`, 'utf8');
            const parent = /^PPid:\s+(\d+)$/mu.exec(status);
            const rss = /^VmRSS:\s+(\d+)\s+kB$/mu.exec(status);
            processRows.push({
              pid: Number(entry.name),
              parent: Number(parent?.[1] ?? 0),
              rssBytes: Number(rss?.[1] ?? 0) * 1024,
            });
          } catch {
            // Process exit races with /proc reads.
          }
        }));
      const descendants = new Set([child.pid]);
      let changed = true;
      while (changed) {
        changed = false;
        for (const row of processRows) {
          if (descendants.has(row.parent) && !descendants.has(row.pid)) {
            descendants.add(row.pid);
            changed = true;
          }
        }
      }
      const sample = processRows
        .filter((row) => descendants.has(row.pid))
        .reduce((sum, row) => sum + row.rssBytes, 0);
      peakProcessTreeMemoryBytes = Math.max(peakProcessTreeMemoryBytes, sample);
    })().catch((error) => {
      if (error?.code !== 'ENOENT' && error?.code !== 'ESRCH') {
        memoryPollError ??= error;
      }
    }).finally(() => {
      memoryPollActive = false;
    });
  }, 25);
  const timeout = setTimeout(() => {
    timedOut = true;
    child.kill('SIGKILL');
  }, timeoutMs);
  const termination = await new Promise((accept, reject) => {
    child.once('error', reject);
    child.once('exit', (exitCode, signal) => accept({ exitCode, signal }));
  });
  clearTimeout(timeout);
  clearInterval(memoryPoll);
  await memoryPollPromise;
  if (memoryPollError !== null) throw memoryPollError;
  return {
    ...termination,
    timedOut,
    durationMs: Number(process.hrtime.bigint() - started) / 1e6,
    peakProcessTreeMemoryBytes,
    stdout: stdout.slice(-65_536),
    stderr: stderr.slice(-65_536),
  };
}

function assertInside(path, root, label) {
  const absolutePath = resolve(path);
  const absoluteRoot = resolve(root);
  if (absolutePath !== absoluteRoot && !absolutePath.startsWith(`${absoluteRoot}/`)) {
    throw new Error(`${label} escaped clean installation: ${path}`);
  }
}

async function packPackage(packageRootPath, packRoot, label, runScripts, timeoutMs) {
  const result = await runProcess(npm, [
    'pack',
    ...(runScripts ? [] : ['--ignore-scripts']),
    '--pack-destination',
    packRoot,
    '--json',
  ], {
    cwd: packageRootPath,
    env: process.env,
    timeoutMs,
  });
  if (result.exitCode !== 0 || result.signal !== null || result.timedOut) {
    throw new Error(`${label} pack failed:\n${result.stdout}\n${result.stderr}`);
  }
  const records = JSON.parse(result.stdout);
  if (!Array.isArray(records) || records.length !== 1) {
    throw new Error(`${label} pack did not return exactly one package record`);
  }
  const tarball = resolve(packRoot, records[0].filename);
  return {
    id: records[0].id,
    bytes: records[0].size,
    sha256: await sha256File(tarball),
    tarball,
  };
}

async function prepareCleanInstallation(outDir, timeoutMs) {
  if (!platformPackageName) {
    throw new Error(`no clean-install package tuple for ${process.platform}-${process.arch}`);
  }
  const packRoot = resolve(outDir, 'packs');
  const installRoot = resolve(outDir, 'install');
  const applicationRoot = resolve(installRoot, 'application');
  await Promise.all([
    mkdir(packRoot, { recursive: true }),
    mkdir(applicationRoot, { recursive: true }),
  ]);

  const wrapper = await packPackage(
    resolve(repoRoot, 'packages/doe-gpu'),
    packRoot,
    'doe-gpu',
    false,
    timeoutMs,
  );
  const platform = await packPackage(
    resolve(repoRoot, `packages/${platformPackageName}`),
    packRoot,
    platformPackageName,
    true,
    timeoutMs,
  );
  await writeFile(resolve(installRoot, 'package.json'), `${JSON.stringify({
    name: 'world-lab-doe-native-identity-clean-install',
    private: true,
    type: 'module',
  }, null, 2)}\n`);
  const installation = await runProcess(npm, [
    'install',
    '--ignore-scripts',
    '--omit=optional',
    '--package-lock=false',
    '--no-audit',
    '--no-fund',
    wrapper.tarball,
    platform.tarball,
  ], {
    cwd: installRoot,
    env: process.env,
    timeoutMs,
  });
  if (installation.exitCode !== 0 || installation.signal !== null || installation.timedOut) {
    throw new Error(`clean package installation failed:\n${installation.stdout}\n${installation.stderr}`);
  }

  const providerPath = resolve(applicationRoot, 'package-observer-provider.mjs');
  await copyFile(cleanInstallProviderTemplatePath, providerPath);
  const wrapperRoot = resolve(installRoot, 'node_modules/doe-gpu');
  const platformRoot = resolve(installRoot, `node_modules/${platformPackageName}`);
  const observerPath = resolve(wrapperRoot, 'src/observe.js');
  const observerSchemaPath = resolve(
    wrapperRoot,
    'assets/transparent-webgpu-observation.schema.json',
  );
  const doeModule = resolve(wrapperRoot, 'src/index.js');
  const platformLibrary = resolve(
    platformRoot,
    'bin',
    process.platform === 'darwin' ? 'libwebgpu_doe.dylib' : 'libwebgpu_doe.so',
  );
  for (const [label, path] of Object.entries({
    providerPath,
    observerPath,
    observerSchemaPath,
    doeModule,
    platformLibrary,
  })) {
    await access(path);
    assertInside(path, installRoot, label);
  }
  if (await sha256File(providerPath) !== await sha256File(cleanInstallProviderTemplatePath)) {
    throw new Error('clean-install provider template changed during copy');
  }

  return {
    mode: 'local-tarball-clean-install',
    root: installRoot,
    providerPath,
    observerPath,
    observerSchemaPath,
    doeModule,
    platformLibrary,
    packages: { wrapper, platform },
    providerTemplate: {
      path: cleanInstallProviderTemplatePath,
      sha256: await sha256File(cleanInstallProviderTemplatePath),
    },
    installed: {
      provider: { path: providerPath, sha256: await sha256File(providerPath) },
      observer: { path: observerPath, sha256: await sha256File(observerPath) },
      observerSchema: { path: observerSchemaPath, sha256: await sha256File(observerSchemaPath) },
      doeModule: { path: doeModule, sha256: await sha256File(doeModule) },
      platformLibrary: { path: platformLibrary, sha256: await sha256File(platformLibrary) },
    },
  };
}

function normalizeAssertions(report) {
  return (report?.testResults ?? [])
    .flatMap((suite) => suite.assertionResults ?? [])
    .map((assertion) => ({ title: assertion.title, status: assertion.status }))
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

function normalizeObservation(observation) {
  const modules = new Map(observation.shaderModules
    .filter((module) => module.id !== null)
    .map((module) => [module.id, module.sourceSha256]));
  const compute = new Map(observation.computePipelines.map((pipeline) => [pipeline.id, {
    sourceSha256: modules.get(pipeline.moduleId) ?? null,
    entryPoint: pipeline.entryPoint,
  }]));
  const render = new Map(observation.renderPipelines.map((pipeline) => [pipeline.id, {
    vertexSourceSha256: modules.get(pipeline.vertexModuleId) ?? null,
    vertexEntryPoint: pipeline.vertexEntryPoint,
    fragmentSourceSha256: modules.get(pipeline.fragmentModuleId) ?? null,
    fragmentEntryPoint: pipeline.fragmentEntryPoint,
  }]));
  return {
    shaders: observation.shaderModules.map((module) => ({
      label: module.label,
      sourceSha256: module.sourceSha256,
      sourceBytes: module.sourceBytes,
      workgroupSize: module.workgroupSize,
      creation: module.creation,
      errorName: module.errorName ?? null,
    })),
    compilationInfos: (observation.compilationInfos ?? []).map((info) => ({
      shaderSourceSha256: modules.get(info.shaderModuleId) ?? null,
      status: info.status,
      errorName: info.errorName ?? null,
      errorMessage: info.errorMessage ?? null,
      messages: info.messages.map((message) => ({
        type: message.type,
        message: message.message,
        lineNum: message.lineNum,
        linePos: message.linePos,
        offset: message.offset,
        length: message.length,
      })),
    })),
    computePipelines: [...compute.values()],
    renderPipelines: [...render.values()],
    commandKinds: observation.commands.map((command) => command.kind),
    dispatches: observation.dispatches.map((dispatch) => ({
      pipeline: compute.get(dispatch.pipelineId) ?? null,
      kind: dispatch.kind,
      workgroups: dispatch.workgroups ?? null,
      indirectOffset: dispatch.indirectOffset ?? null,
    })),
    draws: observation.draws.map((draw) => ({
      pipeline: render.get(draw.pipelineId) ?? null,
      kind: draw.kind,
      args: draw.args,
    })),
    submissions: observation.submissions.map((submission) => ({
      commandBufferCount: submission.commandBufferIds.length,
    })),
    readbacks: observation.readbacks.map((readback) => ({
      bufferSize: readback.bufferSize,
      offset: readback.offset,
      size: readback.size,
      dataSha256: readback.dataSha256,
    })),
  };
}

async function collectEvidence(processDir, providerId) {
  const names = (await readdir(processDir))
    .filter((name) => name.startsWith('provider-evidence.') && name.endsWith('.json'))
    .sort();
  const observations = [];
  const validationErrors = [];
  for (const name of names) {
    const worker = JSON.parse(await readFile(resolve(processDir, name), 'utf8'));
    if (worker.providerId !== providerId) {
      validationErrors.push(`${name}: providerId mismatch`);
    }
    for (const observation of worker.observations ?? []) {
      const validation = validateTransparentWebGPUObservation(observation);
      if (!validation.valid) {
        validationErrors.push(...validation.errors.map((error) => `${name}: ${error}`));
      }
      observations.push(observation);
    }
  }
  const normalized = observations.map(normalizeObservation)
    .sort((left, right) => JSON.stringify(left).localeCompare(JSON.stringify(right)));
  const counts = {
    workerCount: observations.length,
    shaderAttemptCount: observations.reduce(
      (sum, observation) => sum + observation.summary.shaderModuleCount,
      0,
    ),
    compilationInfoCount: observations.reduce(
      (sum, observation) => sum + (observation.summary.compilationInfoCount ?? 0),
      0,
    ),
    dispatchCount: observations.reduce(
      (sum, observation) => sum + observation.summary.dispatchCount,
      0,
    ),
    drawCount: observations.reduce(
      (sum, observation) => sum + observation.summary.drawCount,
      0,
    ),
    submissionCount: observations.reduce(
      (sum, observation) => sum + observation.summary.submissionCount,
      0,
    ),
    readbackCount: observations.reduce(
      (sum, observation) => sum + observation.summary.readbackCount,
      0,
    ),
  };
  const compilationInfos = normalized.flatMap((observation) => observation.compilationInfos);
  const errorDiagnostics = compilationInfos
    .filter((info) => info.messages.some((message) => message.type === 'error'))
    .sort((left, right) => JSON.stringify(left).localeCompare(JSON.stringify(right)));
  const errorShaderSources = [...new Set(
    errorDiagnostics.map((diagnostic) => diagnostic.shaderSourceSha256),
  )].sort();
  return {
    valid: validationErrors.length === 0 && observations.length > 0,
    validationErrors,
    counts,
    shapeIdentitySha256: sha256(JSON.stringify(normalized.map(({
      compilationInfos: _compilationInfos,
      readbacks,
      ...shape
    }) => shape))),
    outputIdentitySha256: sha256(JSON.stringify(normalized.map(({ readbacks }) => readbacks))),
    diagnosticSourceIdentitySha256: sha256(JSON.stringify(errorShaderSources)),
    errorShaderSources,
    errorCompilationInfoCount: errorDiagnostics.length,
    errorMessageCount: errorDiagnostics.reduce(
      (sum, diagnostic) => sum + diagnostic.messages
        .filter((message) => message.type === 'error').length,
      0,
    ),
    errorDiagnostics,
    providerRuntimeIdentities: observations.map(
      (observation) => observation.metadata?.baseProviderInfo ?? null,
    ),
    observations: normalized,
  };
}

async function collectNativeIdentity(
  processDir,
  tracePath,
  evidence,
  expectedRuntimeRoot = null,
  requireRenderIdentity = false,
  requireRenderCompletionIdentity = false,
) {
  const validationErrors = [];
  let rows = [];
  try {
    rows = (await readFile(tracePath, 'utf8'))
      .split(/\r?\n/u)
      .map((line) => line.trim())
      .filter(Boolean)
      .map((line) => JSON.parse(line));
  } catch (error) {
    validationErrors.push(`native trace unreadable: ${error.message}`);
  }
  const dispatchRows = rows.filter((row) => row.event === 'dispatch_encoded');
  const renderRows = rows.filter((row) => row.event === 'render_draw_executed');
  const submissionRows = rows.filter((row) => row.event === 'submission_succeeded');
  const allowedEvents = new Set([
    'dispatch_encoded',
    'render_draw_executed',
    'submission_succeeded',
  ]);
  for (const row of rows) {
    if (row.schemaVersion !== 1 || row.traceKind !== 'doe_native_program_identity_v1') {
      validationErrors.push('native trace schema identity mismatch');
    }
    if (row.backend !== 'doe_vulkan') validationErrors.push('native trace backend mismatch');
    if (!allowedEvents.has(row.event)) validationErrors.push('native trace event mismatch');
    if (!Number.isInteger(row.processId) || row.processId < 1) {
      validationErrors.push('native trace processId is invalid');
    }
    if (!Number.isInteger(row.sequence) || row.sequence < 1) {
      validationErrors.push('native trace sequence is invalid');
    }
  }
  const observedDispatches = evidence.observations.flatMap((observation) => observation.dispatches)
    .filter((dispatch) => dispatch.kind === 'direct' && dispatch.pipeline !== null)
    .map((dispatch) => ({
      wgslSha256: dispatch.pipeline.sourceSha256?.replace(/^sha256:/u, '') ?? null,
      entryPoint: dispatch.pipeline.entryPoint,
      workgroups: dispatch.workgroups,
    }))
    .sort((left, right) => JSON.stringify(left).localeCompare(JSON.stringify(right)));
  const nativeDispatches = dispatchRows.map((row) => ({
    wgslSha256: row.wgslSha256,
    entryPoint: row.entryPoint,
    workgroups: row.workgroups,
  })).sort((left, right) => JSON.stringify(left).localeCompare(JSON.stringify(right)));
  const dispatchIdentityMatches = JSON.stringify(observedDispatches) === JSON.stringify(nativeDispatches);
  if (!dispatchIdentityMatches) validationErrors.push('observer/native dispatch identity mismatch');
  if (dispatchRows.length !== expectedCounts.dispatchCount) {
    validationErrors.push(`native dispatch count mismatch: ${dispatchRows.length}`);
  }
  const observedRenderDraws = evidence.observations.flatMap((observation) => observation.draws)
    .filter((draw) => draw.kind === 'draw' && draw.pipeline !== null)
    .map((draw) => ({
      vertexWgslSha256: draw.pipeline.vertexSourceSha256?.replace(/^sha256:/u, '') ?? null,
      fragmentWgslSha256: draw.pipeline.fragmentSourceSha256?.replace(/^sha256:/u, '') ?? null,
      vertexEntryPoint: draw.pipeline.vertexEntryPoint,
      fragmentEntryPoint: draw.pipeline.fragmentEntryPoint,
      drawKind: draw.kind,
      args: [
        draw.args[0] ?? 0,
        draw.args[1] ?? 1,
        draw.args[2] ?? 0,
        draw.args[3] ?? 0,
      ],
    }))
    .sort((left, right) => JSON.stringify(left).localeCompare(JSON.stringify(right)));
  const nativeRenderDraws = renderRows.map((row) => ({
    vertexWgslSha256: row.vertexWgslSha256,
    fragmentWgslSha256: row.fragmentWgslSha256,
    vertexEntryPoint: row.vertexEntryPoint,
    fragmentEntryPoint: row.fragmentEntryPoint,
    drawKind: row.drawKind,
    args: row.args,
  })).sort((left, right) => JSON.stringify(left).localeCompare(JSON.stringify(right)));
  const renderIdentityMatches = JSON.stringify(observedRenderDraws)
    === JSON.stringify(nativeRenderDraws);
  if (requireRenderIdentity && !renderIdentityMatches) {
    validationErrors.push('observer/native render identity mismatch');
  }
  if (requireRenderIdentity && renderRows.length !== expectedCounts.drawCount) {
    validationErrors.push(`native render draw count mismatch: ${renderRows.length}`);
  }
  for (const dispatch of dispatchRows) {
    const laterSubmission = submissionRows.some((submission) => (
      submission.processId === dispatch.processId && submission.sequence > dispatch.sequence
    ));
    if (!laterSubmission) {
      validationErrors.push(`dispatch lacks later submission: ${dispatch.processId}/${dispatch.sequence}`);
    }
  }
  for (const draw of renderRows) {
    const laterSubmission = submissionRows.some((submission) => (
      submission.processId === draw.processId && submission.sequence > draw.sequence
    ));
    if (requireRenderCompletionIdentity
      && draw.completion !== 'internal_submit_and_wait_succeeded') {
      validationErrors.push(
        `render draw lacks internal submit-and-wait completion: ${draw.processId}/${draw.sequence}`,
      );
    } else if (requireRenderIdentity && !requireRenderCompletionIdentity && !laterSubmission) {
      validationErrors.push(`render draw lacks later submission: ${draw.processId}/${draw.sequence}`);
    }
  }
  const artifacts = [];
  const artifactBindings = [
    ...dispatchRows.map((row) => ({
      filename: row.backendArtifactFile,
      sha256: row.backendArtifactSha256,
      stage: 'compute',
    })),
    ...renderRows.flatMap((row) => [
      {
        filename: row.vertexBackendArtifactFile,
        sha256: row.vertexBackendArtifactSha256,
        stage: 'vertex',
      },
      {
        filename: row.fragmentBackendArtifactFile,
        sha256: row.fragmentBackendArtifactSha256,
        stage: 'fragment',
      },
    ]),
  ];
  for (const binding of artifactBindings) {
    const filename = binding.filename;
    if (typeof filename !== 'string'
      || !/^doe-native-vulkan-[a-f0-9]{64}\.spv$/u.test(filename)) {
      validationErrors.push('native artifact filename is invalid');
      continue;
    }
    const artifactPath = resolve(processDir, filename);
    const artifactSha256 = await sha256File(artifactPath).catch(() => null);
    const validator = artifactSha256 === null
      ? null
      : await runProcess('/usr/bin/spirv-val', [artifactPath], {
        cwd: repoRoot,
        env: process.env,
        timeoutMs: 30_000,
      });
    const valid = artifactSha256 === binding.sha256
      && filename === `doe-native-vulkan-${artifactSha256}.spv`
      && validator?.exitCode === 0
      && validator?.signal === null
      && validator?.timedOut === false;
    if (!valid) validationErrors.push(`native SPIR-V validation failed: ${filename}`);
    artifacts.push({
      path: artifactPath,
      sha256: artifactSha256,
      stage: binding.stage,
      spirvValPassed: validator?.exitCode === 0,
    });
  }
  const uniqueArtifacts = [...new Map(artifacts.map((artifact) => [artifact.path, artifact])).values()];
  const runtimePaths = [...new Set(evidence.providerRuntimeIdentities
    .map((identity) => identity?.doeLibraryPath)
    .filter((value) => typeof value === 'string' && value.length > 0))];
  const runtime = runtimePaths.length === 1
    ? { path: runtimePaths[0], sha256: await sha256File(runtimePaths[0]).catch(() => null) }
    : null;
  if (runtime === null || runtime.sha256 === null) {
    validationErrors.push('Doe native runtime identity is missing or ambiguous');
  }
  let runtimeInsideExpectedRoot = expectedRuntimeRoot === null;
  if (runtime !== null && expectedRuntimeRoot !== null) {
    try {
      assertInside(runtime.path, expectedRuntimeRoot, 'loaded Doe native runtime');
      runtimeInsideExpectedRoot = true;
    } catch (error) {
      validationErrors.push(error.message);
    }
  }
  return {
    valid: validationErrors.length === 0,
    validationErrors,
    trace: { path: tracePath, sha256: await sha256File(tracePath) },
    runtime,
    runtimeInsideExpectedRoot,
    rowCount: rows.length,
    dispatchCount: dispatchRows.length,
    renderDrawCount: renderRows.length,
    submissionCount: submissionRows.length,
    dispatchIdentityMatches,
    renderIdentityMatches,
    renderCompletionIdentityMatches: renderRows.length === expectedCounts.drawCount
      && renderRows.every(
        (row) => row.completion === 'internal_submit_and_wait_succeeded',
      ),
    artifacts: uniqueArtifacts,
  };
}

async function runLane(options, outDir, lane) {
  const processDir = resolve(outDir, 'processes', lane.id);
  const runtimeDir = resolve(outDir, 'runtime', lane.id);
  await Promise.all([
    mkdir(processDir, { recursive: true }),
    mkdir(runtimeDir, { recursive: true }),
  ]);
  const reportPath = resolve(processDir, 'vitest.json');
  const nativeTracePath = lane.nativeIdentity
    ? resolve(processDir, 'native-program-identity.jsonl')
    : null;
  if (nativeTracePath) await writeFile(nativeTracePath, '', { flag: 'wx' });
  const result = await runProcess(process.execPath, [
    resolve(upstreamRoot, 'node_modules/vitest/vitest.mjs'),
    'run',
    ...testFiles,
    '--config',
    configPath,
    '--reporter=json',
    `--outputFile=${reportPath}`,
  ], {
    cwd: packageRoot,
    env: {
      ...process.env,
      DOE_EXTERNAL_WEBGPU_PROVIDER: lane.providerId,
      DOE_EXTERNAL_PROVIDER_MODULE: lane.providerPath,
      DOE_WORLD_LAB_BASE_PROVIDER_MODULE: lane.baseModule,
      DOE_WORLD_LAB_EVIDENCE_PATH: resolve(processDir, 'provider-evidence'),
      DOE_EXTERNAL_UPSTREAM_ROOT: upstreamRoot,
      REQUIRE_WEBGPU: '1',
      XDG_RUNTIME_DIR: runtimeDir,
      ...(nativeTracePath ? { DOE_PROGRAM_IDENTITY_TRACE_PATH: nativeTracePath } : {}),
    },
    timeoutMs: options.timeoutMs,
  });
  let report = null;
  try {
    report = JSON.parse(await readFile(reportPath, 'utf8'));
  } catch {
    // Process and evidence state preserve the failure when Vitest emits no report.
  }
  const assertions = normalizeAssertions(report);
  const evidence = await collectEvidence(processDir, lane.providerId);
  const nativeIdentity = nativeTracePath
    ? await collectNativeIdentity(
        processDir,
        nativeTracePath,
        evidence,
        lane.expectedRuntimeRoot ?? null,
        lane.renderIdentity ?? false,
        lane.renderCompletionIdentity ?? false,
      )
    : null;
  return {
    laneId: lane.id,
    providerId: lane.providerId,
    baseModule: { path: lane.baseModule, sha256: await sha256File(lane.baseModule) },
    success: result.exitCode === 0
      && !result.timedOut
      && result.signal === null
      && oraclePass(report, assertions)
      && evidence.valid
      && JSON.stringify(evidence.counts) === JSON.stringify(expectedCounts)
      && evidence.errorCompilationInfoCount === 1
      && evidence.errorMessageCount >= 1
      && evidence.errorShaderSources.length === 1
      && evidence.errorShaderSources[0] === expectedInvalidShaderSourceSha256
      && (!lane.nativeIdentity || nativeIdentity?.valid === true),
    process: result,
    assertions,
    assertionIdentitySha256: sha256(JSON.stringify(assertions)),
    evidence,
    nativeIdentity,
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
  const planPath = options.renderCompletionIdentity
    ? renderCompletionIdentityPlanPath
    : options.renderIdentity
      ? renderIdentityPlanPath
    : options.cleanInstall
      ? cleanInstallPlanPath
      : workspacePlanPath;
  const cleanInstallation = options.cleanInstall
    ? await prepareCleanInstallation(outDir, options.timeoutMs)
    : null;
  const providerPath = cleanInstallation?.providerPath ?? workspaceProviderPath;
  const observerPath = cleanInstallation?.observerPath ?? workspaceObserverPath;
  const observerSchemaPath = cleanInstallation?.observerSchemaPath
    ?? workspaceObserverSchemaPath;
  const observerModule = await import(pathToFileURL(observerPath).href);
  if (typeof observerModule.validateTransparentWebGPUObservation !== 'function') {
    throw new Error(`observer validator is missing: ${observerPath}`);
  }
  validateTransparentWebGPUObservation = observerModule.validateTransparentWebGPUObservation;
  const commitResult = await runProcess('git', ['rev-parse', 'HEAD'], {
    cwd: upstreamRoot,
    env: process.env,
    timeoutMs: options.timeoutMs,
  });
  const commit = commitResult.stdout.trim();
  if (commit !== expectedCommit) throw new Error(`unexpected World Labs commit: ${commit}`);

  const lanes = [
    {
      id: 'W0',
      providerId: 'dawn-node-webgpu',
      baseModule: resolve(upstreamRoot, 'node_modules/webgpu/index.js'),
      providerPath,
    },
    {
      id: 'D0',
      providerId: 'doe-gpu',
      baseModule: cleanInstallation?.doeModule ?? resolve(repoRoot, 'packages/doe-gpu/src/index.js'),
      providerPath,
      nativeIdentity: true,
      expectedRuntimeRoot: cleanInstallation?.root ?? null,
      renderIdentity: options.renderIdentity,
      renderCompletionIdentity: options.renderCompletionIdentity,
    },
  ];
  await Promise.all([
    planPath,
    providerPath,
    configPath,
    setupPath,
    observerPath,
    observerSchemaPath,
    ...lanes.map((lane) => lane.baseModule),
  ].map((path) => access(path)));

  const results = {};
  for (const lane of lanes) {
    results[lane.id] = await runLane(options, outDir, lane);
    process.stdout.write(`${lane.id}: ${results[lane.id].success ? 'PASS' : 'FAIL'}\n`);
  }
  const shapeMatch = results.W0.evidence.shapeIdentitySha256
    === results.D0.evidence.shapeIdentitySha256;
  const outputMatch = results.W0.evidence.outputIdentitySha256
    === results.D0.evidence.outputIdentitySha256;
  const diagnosticSourceMatch = results.W0.evidence.diagnosticSourceIdentitySha256
    === results.D0.evidence.diagnosticSourceIdentitySha256;
  const passed = results.W0.success
    && results.D0.success
    && shapeMatch
    && outputMatch
    && diagnosticSourceMatch;
  const artifact = {
    schemaVersion: 1,
    artifactKind: options.renderIdentity
      ? 'world-lab-package-native-render-identity-clean-install-result'
      : options.cleanInstall
        ? 'world-lab-package-native-identity-clean-install-result'
        : 'world-lab-package-compilation-observer-result',
    status: passed ? 'passed' : 'failed',
    generatedAt: new Date().toISOString(),
    plan: { path: planPath, sha256: await sha256File(planPath) },
    upstream: {
      repositoryUrl: 'https://github.com/saabi/world-lab',
      commit,
      packagePath: 'packages/runtime-webgpu',
    },
    implementation: {
      runner: { path: runnerPath, sha256: await sha256File(runnerPath) },
      provider: { path: providerPath, sha256: await sha256File(providerPath) },
      config: { path: configPath, sha256: await sha256File(configPath) },
      setup: { path: setupPath, sha256: await sha256File(setupPath) },
      observer: { path: observerPath, sha256: await sha256File(observerPath) },
      observerSchema: { path: observerSchemaPath, sha256: await sha256File(observerSchemaPath) },
    },
    installation: cleanInstallation === null ? { mode: 'workspace' } : cleanInstallation,
    expectedCounts,
    expectedInvalidShaderSourceSha256,
    lanes: results,
    adjudication: {
      shapeMatch,
      outputMatch,
      diagnosticSourceMatch,
      packageCompilationObserverAdmission: passed,
      cleanInstallPackageIdentity: options.cleanInstall && passed
        && results.D0.nativeIdentity?.runtimeInsideExpectedRoot === true,
      nativeRenderIdentity: options.renderIdentity && passed
        && results.D0.nativeIdentity?.renderIdentityMatches === true,
      nativeRenderCompletionIdentity: options.renderCompletionIdentity && passed
        && results.D0.nativeIdentity?.renderCompletionIdentityMatches === true,
      runtimeOwnershipDecisionReopened: false,
      runtimeOwnershipCredit: false,
      performanceCredit: false,
      promotionCredit: false,
      releaseCredit: false,
    },
  };
  artifact.sha256 = sha256(JSON.stringify(artifact));
  const resultPath = resolve(outDir, 'result.json');
  await writeFile(resultPath, `${JSON.stringify(artifact, null, 2)}\n`);
  process.stdout.write(`${resultPath}\n`);
  if (!passed) process.exitCode = 1;
}

await main();

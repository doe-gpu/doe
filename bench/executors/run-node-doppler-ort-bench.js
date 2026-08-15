#!/usr/bin/env node

import { execFileSync } from 'node:child_process';
import { readFile, stat } from 'node:fs/promises';
import { createServer } from 'node:http';
import { extname, resolve } from 'node:path';

import { loadVendorNodeScenario, parseVendorNodeCliArgs } from './vendor-node/scenario.js';
import {
  fileSha256,
  importFromPath,
  nowMs,
  resolvePrompt,
  resolveRepoPath,
  summarizeDopplerEnvelope,
} from './vendor-node/shared.js';
import {
  writeVendorNodeFailureTrace,
  writeVendorNodeSuccessTrace,
} from './vendor-node/trace-artifact.js';

const USAGE_COMMAND = 'node bench/executors/run-node-doppler-ort-bench.js';
const OCTET_STREAM = 'application/octet-stream';
const CONTENT_TYPE_BY_EXTENSION = Object.freeze({
  '.bin': OCTET_STREAM,
  '.json': 'application/json; charset=utf-8',
  '.model': OCTET_STREAM,
  '.txt': 'text/plain; charset=utf-8',
});

const PROVIDERS = Object.freeze({
  doe: Object.freeze({
    executionBackend: 'doppler_node_webgpu_doe',
    executionLabel: 'Doppler Node benchmark on Doe provider',
    executionProvider: 'doe',
    executionProviderName: 'doe-gpu',
    modulePath: resolveRepoPath('packages/doe-gpu/src/compute.js'),
  }),
  'node-webgpu': Object.freeze({
    executionBackend: 'doppler_node_webgpu_incumbent',
    executionLabel: 'Doppler Node benchmark on node-webgpu provider',
    executionProvider: 'node-webgpu',
    executionProviderName: 'webgpu',
    modulePath: resolveRepoPath('bench/vendor/node-webgpu-package/index.js'),
  }),
});

function resolveProvider(providerId) {
  const provider = PROVIDERS[providerId];
  if (!provider) {
    throw new Error(
      `unsupported Doppler Node provider ${providerId}; expected one of ${Object.keys(PROVIDERS).join(', ')}`,
    );
  }
  return provider;
}

function resolveDopplerSourceIdentity(scenario) {
  const sourceCommit = execFileSync(
    'git',
    ['-C', scenario.dopplerRoot, 'rev-parse', 'HEAD'],
    { encoding: 'utf8' },
  ).trim();
  const sourceStatus = execFileSync(
    'git',
    ['-C', scenario.dopplerRoot, 'status', '--porcelain', '--untracked-files=no'],
    { encoding: 'utf8' },
  ).trim();
  if (scenario.doppler.sourceCommit && sourceCommit !== scenario.doppler.sourceCommit) {
    throw new Error(
      `Doppler source commit mismatch: expected ${scenario.doppler.sourceCommit}, got ${sourceCommit}`,
    );
  }
  if (sourceStatus !== '') {
    throw new Error('Doppler source tree must be clean for provider comparison');
  }
  return {
    dopplerSourceRoot: scenario.dopplerRoot,
    dopplerSourceCommit: sourceCommit,
    dopplerSourceTrackedClean: true,
  };
}

function contentTypeFor(path) {
  return CONTENT_TYPE_BY_EXTENSION[extname(path).toLowerCase()] ?? OCTET_STREAM;
}

async function startStaticModelServer(modelRoot) {
  const normalizedRoot = resolve(modelRoot);
  const server = createServer(async (request, response) => {
    try {
      const requestUrl = new URL(request.url ?? '/', 'http://127.0.0.1');
      const requestedPath = requestUrl.pathname === '/' ? '/manifest.json' : requestUrl.pathname;
      const candidatePath = resolve(normalizedRoot, `.${requestedPath}`);
      if (candidatePath !== normalizedRoot && !candidatePath.startsWith(`${normalizedRoot}/`)) {
        response.writeHead(403, { 'Content-Type': 'text/plain; charset=utf-8' });
        response.end('forbidden');
        return;
      }

      const fileStats = await stat(candidatePath);
      if (!fileStats.isFile()) {
        response.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
        response.end('not found');
        return;
      }
      const payload = await readFile(candidatePath);
      response.writeHead(200, {
        'Content-Type': contentTypeFor(candidatePath),
        'Content-Length': String(payload.byteLength),
        'Cache-Control': 'no-store',
      });
      response.end(payload);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (message.includes('ENOENT')) {
        response.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
        response.end('not found');
        return;
      }
      response.writeHead(500, { 'Content-Type': 'text/plain; charset=utf-8' });
      response.end(message);
    }
  });

  await new Promise((resolveListen, rejectListen) => {
    server.once('error', rejectListen);
    server.listen(0, '127.0.0.1', () => {
      server.off('error', rejectListen);
      resolveListen();
    });
  });

  const address = server.address();
  if (!address || typeof address === 'string') {
    throw new Error('failed to resolve local model server address');
  }

  return {
    baseUrl: `http://127.0.0.1:${address.port}`,
    async close() {
      await new Promise((resolveClose, rejectClose) => {
        server.close((error) => {
          if (error) {
            rejectClose(error);
            return;
          }
          resolveClose();
        });
      });
    },
  };
}

async function resolveDopplerModelSource(scenario) {
  const loadMode = scenario.doppler.loadMode ?? scenario.loadMode;
  if (scenario.doppler.modelPath) {
    if (loadMode === 'memory') {
      return {
        loadMode,
        modelSource: 'local-source-runtime',
        modelUrl: scenario.doppler.modelPath,
        close: null,
      };
    }
    const staticServer = await startStaticModelServer(scenario.doppler.modelPath);
    return {
      loadMode: 'http',
      modelSource: 'local-http-shim',
      modelUrl: staticServer.baseUrl,
      close: staticServer.close,
    };
  }

  const registry = await importFromPath(resolve(scenario.dopplerRoot, 'src/client/doppler-registry.js'));
  const quickstartEntry = await registry.resolveQuickstartModel(scenario.doppler.modelId);
  return {
    loadMode,
    modelSource: 'quickstart-registry',
    modelUrl: registry.buildQuickstartModelBaseUrl(quickstartEntry),
    close: null,
  };
}

function clonePlainObject(value) {
  if (value == null) {
    return {};
  }
  return JSON.parse(JSON.stringify(value));
}

function buildRuntimeConfigForScenario(scenario, promptText) {
  const runtimeConfig = clonePlainObject(scenario.doppler.runtimeConfig);
  const inference = runtimeConfig.inference ?? {};
  const sampling = inference.sampling ?? {};
  const generation = inference.generation ?? {};
  runtimeConfig.inference = {
    ...inference,
    prompt: promptText,
    sampling: {
      ...sampling,
      temperature: scenario.promptWorkload.temperature,
      topK: scenario.promptWorkload.topK,
      topP: scenario.promptWorkload.topP,
    },
    generation: {
      ...generation,
      maxTokens: scenario.promptWorkload.decodeTokens,
    },
  };
  return runtimeConfig;
}

async function buildDopplerRequest(scenario, promptText) {
  const modelSource = await resolveDopplerModelSource(scenario);
  const request = {
    command: 'bench',
    workload: 'inference',
    modelId: scenario.doppler.modelId,
    modelUrl: modelSource.modelUrl,
    cacheMode: scenario.cacheMode,
    loadMode: modelSource.loadMode,
    captureOutput: true,
    inferenceInput: {
      prompt: promptText,
      maxTokens: scenario.promptWorkload.decodeTokens,
    },
  };
  if (scenario.doppler.runtimeProfile) {
    request.runtimeProfile = scenario.doppler.runtimeProfile;
  }
  request.runtimeConfig = buildRuntimeConfigForScenario(scenario, promptText);
  return {
    request,
    modelSource,
  };
}

async function main() {
  const startedMs = nowMs();
  const args = parseVendorNodeCliArgs(USAGE_COMMAND);
  const provider = resolveProvider(args.provider);
  const providerContractPath = resolveRepoPath('packages/doe-gpu/src/node-webgpu.js');
  const providerModuleSha256 = await fileSha256(provider.modulePath);
  const providerContractSha256 = await fileSha256(providerContractPath);
  let scenarioId = args.workloadId;
  let benchmarkLane = 'node-ort-vs-doppler';
  let closeModelSource = null;
  let releaseProvider = null;
  let providerReceipt = null;

  try {
    const scenario = await loadVendorNodeScenario(args.scenarioPath);
    scenarioId = scenario.scenarioId;
    benchmarkLane = scenario.benchmarkLane;
    if (scenario.scenarioId !== args.workloadId) {
      throw new Error(
        `scenario id ${scenario.scenarioId} does not match requested workload ${args.workloadId}`,
      );
    }
    const dopplerSourceIdentity = resolveDopplerSourceIdentity(scenario);
    const modelManifestPath = scenario.doppler.modelPath
      ? resolve(scenario.doppler.modelPath, 'manifest.json')
      : null;
    const modelManifestSha256 = modelManifestPath
      ? await fileSha256(modelManifestPath)
      : null;

    process.env.DOPPLER_NODE_WEBGPU_MODULE = provider.modulePath;
    const providerBridge = await importFromPath(
      resolve(scenario.dopplerRoot, 'src/tooling/node-webgpu.js'),
    );
    const bootstrap = await providerBridge.bootstrapNodeWebGPU({
      providerContractModule: providerContractPath,
    });
    providerReceipt = bootstrap.receipt ?? {
      schema: 'doppler-legacy-provider-bootstrap/v1',
      selectedProviderId: bootstrap.provider ?? null,
      ok: bootstrap.ok === true,
      detail: bootstrap.detail ?? null,
    };
    if (bootstrap.ok !== true) {
      throw new Error(
        `Doppler Node provider bootstrap failed for ${provider.executionProvider}: ${bootstrap.detail ?? 'unknown failure'}`,
      );
    }
    releaseProvider = typeof providerBridge.releaseNodeWebGPU === 'function'
      ? providerBridge.releaseNodeWebGPU
      : null;

    const dopplerRunner = await importFromPath(resolve(scenario.dopplerRoot, 'src/tooling/node-command-runner.js'));
    if (typeof dopplerRunner.runNodeCommand !== 'function') {
      throw new Error('doppler node command runner does not export runNodeCommand');
    }

    const promptStartedMs = nowMs();
    const prompt = await resolvePrompt(scenario);
    const promptResolvedMs = nowMs();

    const requestBundle = await buildDopplerRequest(scenario, prompt.prompt);
    closeModelSource = requestBundle.modelSource.close;
    const runStartedMs = nowMs();
    const envelope = await dopplerRunner.runNodeCommand(requestBundle.request, {});
    const runResolvedMs = nowMs();
    const providerRelease = typeof releaseProvider === 'function'
      ? await releaseProvider()
      : {
          supported: false,
          reason: 'pinned Doppler source predates explicit provider release contract',
        };
    releaseProvider = null;

    const resultSummary = {
      modelId: scenario.doppler.modelId,
      ...summarizeDopplerEnvelope(envelope),
    };
    if (resultSummary.generatedTextLength === 0) {
      throw new Error('Doppler provider comparison produced no captured generated text');
    }
    const promptSummary = {
      promptSource: prompt.promptSource,
      promptLength: prompt.prompt.length,
      prefillTokens: prompt.prefillTokens,
      decodeTokens: scenario.promptWorkload.decodeTokens,
      tokenizerLocator: prompt.tokenizerLocator,
      tokenizerResolutionSource: prompt.tokenizerResolutionSource,
      useChatTemplate: scenario.useChatTemplate,
    };
    const phaseTimingsMs = {
      promptSynthesisMs: promptResolvedMs - promptStartedMs,
      commandRunMs: runResolvedMs - runStartedMs,
    };

    await writeVendorNodeSuccessTrace({
      benchmarkLane,
      executionProvider: provider.executionProvider,
      executionProviderName: provider.executionProviderName,
      traceMetaPath: args.traceMetaPath,
      traceJsonlPath: args.traceJsonlPath,
      workloadId: args.workloadId,
      scenarioId,
      executionBackend: provider.executionBackend,
      executionLabel: provider.executionLabel,
      processWallMs: nowMs() - startedMs,
      adapterInfo: null,
      phaseTimingsMs,
      promptSummary,
      resultSummary,
      extraMeta: {
        vendorStack: 'doppler-node',
        cacheMode: scenario.cacheMode,
        loadMode: requestBundle.modelSource.loadMode,
        modelSource: requestBundle.modelSource.modelSource,
        runtimeProfile: scenario.doppler.runtimeProfile,
        providerModulePath: provider.modulePath,
        providerModuleSha256,
        providerContractPath,
        providerContractSha256,
        providerReceipt,
        providerRelease,
        ...dopplerSourceIdentity,
        modelManifestPath,
        modelManifestSha256,
      },
    });
  } catch (error) {
    let message = error instanceof Error ? error.message : String(error);
    if (typeof releaseProvider === 'function') {
      try {
        await releaseProvider();
      } catch (releaseError) {
        const releaseMessage = releaseError instanceof Error
          ? releaseError.message
          : String(releaseError);
        message = `${message}; provider release failed: ${releaseMessage}`;
      }
      releaseProvider = null;
    }
    await writeVendorNodeFailureTrace({
      benchmarkLane,
      executionProvider: provider.executionProvider,
      executionProviderName: provider.executionProviderName,
      traceMetaPath: args.traceMetaPath,
      traceJsonlPath: args.traceJsonlPath,
      workloadId: args.workloadId,
      scenarioId,
      executionBackend: provider.executionBackend,
      executionLabel: provider.executionLabel,
      processWallMs: nowMs() - startedMs,
      errorMessage: message,
      extraMeta: {
        providerModulePath: provider.modulePath,
        providerModuleSha256,
        providerContractPath,
        providerContractSha256,
        providerReceipt,
      },
    });
    process.stderr.write(`${message}\n`);
    process.exitCode = 1;
  } finally {
    if (typeof closeModelSource === 'function') {
      await closeModelSource();
    }
  }
}

await main();

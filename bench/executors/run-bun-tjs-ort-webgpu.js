#!/usr/bin/env bun

import { loadVendorNodeScenario, parseVendorNodeCliArgs } from './vendor-node/scenario.js';
import {
  createTjsGenerationOptions,
  collectOrtProfileSummary,
  createOrtProfileContext,
  destroyDevice,
  disposeTjsPipeline,
  importTransformersNodeModule,
  installWebGpuExecutionCounters,
  installTjsOrtWebGpuProvider,
  nowMs,
  requestAdapterAndDevice,
  resolvePrompt,
  resolveTjsModelLocator,
  summarizeAdapterInfo,
  summarizeTjsOutput,
  waitForDeviceIdle,
} from './vendor-node/shared.js';
import {
  writeVendorNodeFailureTrace,
  writeVendorNodeSuccessTrace,
} from './vendor-node/trace-artifact.js';

const USAGE_COMMAND = 'bun bench/executors/run-bun-tjs-ort-webgpu.js';
const DOE_PROVIDER = 'doe';
const PROVIDER_LABELS = Object.freeze({
  doe: 'doe-gpu',
  'bun-webgpu': 'bun-webgpu',
});
const BENCHMARK_LANE = 'bun-ort-webgpu-provider-compare';
const RUNTIME_HOST = 'bun';

function requireMatchingWorkloadId(scenarioId, workloadId) {
  if (scenarioId !== workloadId) {
    throw new Error(
      `scenario id ${scenarioId} does not match requested workload ${workloadId}`,
    );
  }
}

async function main() {
  const startedMs = nowMs();
  const args = parseVendorNodeCliArgs(USAGE_COMMAND);
  let scenarioId = args.workloadId;
  let device = null;
  let pipeline = null;
  let executionBackend = 'tjs_ort_bun_webgpu';
  let executionLabel = 'transformers.js ORT Bun WebGPU';
  let executionProvider = DOE_PROVIDER;
  let executionProviderName = PROVIDER_LABELS[DOE_PROVIDER];
  let requestedAdapterName = null;

  try {
    const scenario = await loadVendorNodeScenario(args.scenarioPath);
    scenarioId = scenario.scenarioId;
    requireMatchingWorkloadId(scenario.scenarioId, args.workloadId);

    const providerRuntime = await installTjsOrtWebGpuProvider(args.provider, RUNTIME_HOST);
    executionBackend = providerRuntime.executionBackend;
    executionProvider = providerRuntime.provider;
    executionProviderName = providerRuntime.providerName;
    requestedAdapterName = providerRuntime.requestedAdapterName ?? null;
    executionLabel = `transformers.js ORT Bun WebGPU on ${executionProviderName}`;
    const adapterDevice = await requestAdapterAndDevice(providerRuntime);
    const adapter = adapterDevice.adapter;
    device = adapterDevice.device;
    const webgpuCounters = installWebGpuExecutionCounters(device);
    const adapterInfo = summarizeAdapterInfo(adapter, device);

    const promptStartedMs = nowMs();
    const prompt = await resolvePrompt(scenario);
    const promptResolvedMs = nowMs();

    const transformers = await importTransformersNodeModule(scenario.dopplerRoot);
    if (typeof transformers.pipeline !== 'function') {
      throw new Error('transformers.node bundle does not export pipeline');
    }
    if (!transformers.env?.backends?.onnx?.webgpu) {
      throw new Error('transformers.node bundle does not expose env.backends.onnx.webgpu');
    }
    transformers.env.backends.onnx.webgpu.adapter = adapter;
    transformers.env.backends.onnx.webgpu.device = device;
    if (scenario.tjs.localModelPath) {
      transformers.env.allowLocalModels = true;
      transformers.env.localModelPath = scenario.tjs.localModelPath;
    }

    const modelLocator = resolveTjsModelLocator(scenario);
    const ortProfileContext = await createOrtProfileContext(
      args.traceMetaPath,
      `${executionProvider}-ort`,
    );
    const loadStartedMs = nowMs();
    pipeline = await transformers.pipeline(
      'text-generation',
      modelLocator,
      {
        device: 'webgpu',
        dtype: scenario.tjs.dtype,
        local_files_only: !!scenario.tjs.localModelPath,
        session_options: ortProfileContext.sessionOptions,
      },
    );
    const loadResolvedMs = nowMs();

    const generateStartedMs = nowMs();
    const output = await pipeline(prompt.prompt, createTjsGenerationOptions(scenario));
    await waitForDeviceIdle(device);
    const generateResolvedMs = nowMs();
    const ortProfileSummary = await collectOrtProfileSummary(pipeline, ortProfileContext);

    const processWallMs = nowMs() - startedMs;
    const promptSummary = {
      promptSource: prompt.promptSource,
      promptLength: prompt.prompt.length,
      prefillTokens: prompt.prefillTokens,
      decodeTokens: scenario.promptWorkload.decodeTokens,
      tokenizerLocator: prompt.tokenizerLocator,
      tokenizerResolutionSource: prompt.tokenizerResolutionSource,
      useChatTemplate: scenario.useChatTemplate,
    };
    const resultSummary = {
      modelId: scenario.tjs.modelId,
      modelLocator,
      dtype: scenario.tjs.dtype,
      ...summarizeTjsOutput(output),
    };
    const phaseTimingsMs = {
      promptSynthesisMs: promptResolvedMs - promptStartedMs,
      pipelineLoadMs: loadResolvedMs - loadStartedMs,
      generationMs: generateResolvedMs - generateStartedMs,
    };
    const selectedTimingMs = phaseTimingsMs.generationMs;

    await writeVendorNodeSuccessTrace({
      runtimeHost: RUNTIME_HOST,
      traceMetaPath: args.traceMetaPath,
      traceJsonlPath: args.traceJsonlPath,
      benchmarkLane: BENCHMARK_LANE,
      workloadId: args.workloadId,
      scenarioId,
      executionBackend,
      executionLabel,
      executionProvider,
      executionProviderName,
      processWallMs,
      timingMs: selectedTimingMs,
      timingSource: 'tjs-ort-generation-ms',
      timingClass: 'operation',
      adapterInfo,
      phaseTimingsMs,
      promptSummary,
      resultSummary,
      extraMeta: {
        vendorStack: 'transformers.js+onnxruntime-node',
        cacheMode: scenario.cacheMode,
        loadMode: scenario.loadMode,
        requestedAdapterName,
        ...webgpuCounters.snapshot(),
        ...ortProfileSummary,
      },
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    await writeVendorNodeFailureTrace({
      runtimeHost: RUNTIME_HOST,
      traceMetaPath: args.traceMetaPath,
      traceJsonlPath: args.traceJsonlPath,
      benchmarkLane: BENCHMARK_LANE,
      workloadId: args.workloadId,
      scenarioId,
      executionBackend,
      executionLabel,
      executionProvider,
      executionProviderName,
      processWallMs: nowMs() - startedMs,
      errorMessage: message,
    });
    process.stderr.write(`${message}\n`);
    process.exitCode = 1;
  } finally {
    await disposeTjsPipeline(pipeline);
    destroyDevice(device);
  }
}

await main();

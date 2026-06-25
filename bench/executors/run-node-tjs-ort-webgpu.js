#!/usr/bin/env node

import { loadVendorNodeScenario, parseVendorNodeCliArgs } from './vendor-node/scenario.js';
import {
  createTjsGenerationOptions,
  collectOrtProfileSummary,
  createOrtProfileContext,
  destroyDevice,
  disposeTjsPipeline,
  importTransformersNodeModule,
  installWebGpuExecutionCounters,
  installNodeWebGpuProvider,
  nowMs,
  requestAdapterAndDevice,
  resolvePreferredNodeWebGpuAdapterName,
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

const USAGE_COMMAND = 'node bench/executors/run-node-tjs-ort-webgpu.js';
const DOE_PROVIDER = 'doe';
const PROVIDER_LABELS = Object.freeze({
  doe: 'doe-gpu',
  'node-webgpu': 'node-webgpu',
});
const BENCHMARK_LANE = 'node-ort-webgpu-provider-compare';
const RUNTIME_HOST = typeof Bun !== 'undefined' ? 'bun' : 'node';

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
  let executionBackend = 'tjs_ort_node_webgpu';
  let executionLabel = 'transformers.js ORT node WebGPU';
  let executionProvider = DOE_PROVIDER;
  let executionProviderName = PROVIDER_LABELS[DOE_PROVIDER];
  let requestedAdapterName = null;

  try {
    const scenario = await loadVendorNodeScenario(args.scenarioPath);
    scenarioId = scenario.scenarioId;
    requireMatchingWorkloadId(scenario.scenarioId, args.workloadId);

    if (args.provider === 'node-webgpu' && !process.env.DOE_NODE_WEBGPU_ADAPTER) {
      requestedAdapterName = resolvePreferredNodeWebGpuAdapterName();
      if (requestedAdapterName) {
        process.env.DOE_NODE_WEBGPU_ADAPTER = requestedAdapterName;
      }
    }

    const providerRuntime = await installNodeWebGpuProvider(args.provider);
    executionBackend = providerRuntime.executionBackend;
    executionProvider = providerRuntime.provider;
    executionProviderName = providerRuntime.providerName;
    requestedAdapterName = providerRuntime.requestedAdapterName ?? requestedAdapterName;
    executionLabel = `transformers.js ORT node WebGPU on ${executionProviderName}`;
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

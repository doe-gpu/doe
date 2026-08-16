#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { mkdir, readFile, stat, writeFile } from 'node:fs/promises';
import { extname, resolve } from 'node:path';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import { loadVendorNodeScenario } from './vendor-node/scenario.js';
import { importFromPath, resolvePrompt, resolveRepoPath } from './vendor-node/shared.js';

const scriptPath = fileURLToPath(import.meta.url);
const repoRoot = resolve(dirname(scriptPath), '../..');
const baseScenarioPath = resolve(
  repoRoot,
  'bench/vendor-node/doppler_provider_logit_divergence_gemma270m_commands.json',
);
const EXPECTED_TOKEN_ID = 818;
const EXPECTED_LOGITS_DIGEST =
  'sha256:71a1e8031fc2186659689458869ea1b6d42f83c6c76cc00755c5d2935ffeda4c';

function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

function parseArgs(argv) {
  const options = {
    operatorClasses: null,
    opIds: null,
    layers: null,
    suppressDiagnosticCopies: false,
    suppressDiagnosticAllocations: false,
    diagnosticAllocationBytes: null,
    runId: null,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--operator-classes') {
      options.operatorClasses = (argv[++index] ?? '').split(',').map((value) => value.trim()).filter(Boolean);
    } else if (argument === '--op-ids') {
      options.opIds = (argv[++index] ?? '').split(',').map((value) => value.trim()).filter(Boolean);
    } else if (argument === '--layers') {
      options.layers = (argv[++index] ?? '').split(',').map((value) => Number.parseInt(value, 10));
      if (options.layers.some((value) => !Number.isInteger(value) || value < 0)) {
        throw new Error('--layers must contain non-negative integers');
      }
    } else if (argument === '--suppress-diagnostic-copies') {
      options.suppressDiagnosticCopies = true;
    } else if (argument === '--suppress-diagnostic-allocations') {
      options.suppressDiagnosticCopies = true;
      options.suppressDiagnosticAllocations = true;
    } else if (argument === '--diagnostic-allocation-bytes') {
      options.suppressDiagnosticCopies = true;
      options.diagnosticAllocationBytes = Number.parseInt(argv[++index] ?? '', 10);
      if (!Number.isInteger(options.diagnosticAllocationBytes) || options.diagnosticAllocationBytes < 1) {
        throw new Error('--diagnostic-allocation-bytes must be a positive integer');
      }
    } else if (argument === '--run-id') {
      options.runId = argv[++index] ?? null;
    } else {
      throw new Error(`unknown argument: ${argument}`);
    }
  }
  const selectorCount = [options.operatorClasses, options.opIds, options.layers]
    .filter((value) => Array.isArray(value) && value.length > 0).length;
  if (selectorCount !== 1) {
    throw new Error('exactly one of --operator-classes, --op-ids, or --layers is required');
  }
  if (!options.runId || !/^[A-Za-z0-9._-]+$/u.test(options.runId)) {
    throw new Error('--run-id must contain only letters, digits, dots, underscores, or hyphens');
  }
  return options;
}

function suppressDiagnosticSideEffects(device, suppressAllocations, diagnosticAllocationBytes) {
  const originalCreateCommandEncoder = device.createCommandEncoder.bind(device);
  const originalCreateBuffer = device.createBuffer.bind(device);
  const diagnosticBuffers = new WeakSet();
  if (suppressAllocations || diagnosticAllocationBytes != null) {
    device.createBuffer = (descriptor) => {
      if (!String(descriptor?.label ?? '').endsWith('_diagnostic_capture')) {
        return originalCreateBuffer(descriptor);
      }
      if (diagnosticAllocationBytes != null) {
        const buffer = originalCreateBuffer({ ...descriptor, size: diagnosticAllocationBytes });
        diagnosticBuffers.add(buffer);
        return buffer;
      }
      const bytes = new ArrayBuffer(descriptor.size);
      const buffer = {
        label: descriptor.label,
        size: descriptor.size,
        async mapAsync() {},
        getMappedRange() { return bytes; },
        unmap() {},
        destroy() {},
      };
      diagnosticBuffers.add(buffer);
      return buffer;
    };
  }
  device.createCommandEncoder = (descriptor) => {
    const encoder = originalCreateCommandEncoder(descriptor);
    const originalCopyBufferToBuffer = encoder.copyBufferToBuffer.bind(encoder);
    encoder.copyBufferToBuffer = (source, sourceOffset, destination, destinationOffset, size) => {
      if (diagnosticBuffers.has(destination) ||
          String(destination?.label ?? '').endsWith('_diagnostic_capture')) return;
      return originalCopyBufferToBuffer(source, sourceOffset, destination, destinationOffset, size);
    };
    return encoder;
  };
}

function contentTypeFor(path) {
  const extension = extname(path).toLowerCase();
  if (extension === '.json') return 'application/json; charset=utf-8';
  if (extension === '.txt') return 'text/plain; charset=utf-8';
  return 'application/octet-stream';
}

async function startStaticServer(modelRoot) {
  const normalizedRoot = resolve(modelRoot);
  const server = createServer(async (request, response) => {
    try {
      const requestUrl = new URL(request.url ?? '/', 'http://127.0.0.1');
      const requestedPath = requestUrl.pathname === '/' ? '/manifest.json' : requestUrl.pathname;
      const candidate = resolve(normalizedRoot, `.${requestedPath}`);
      if (candidate !== normalizedRoot && !candidate.startsWith(`${normalizedRoot}/`)) {
        response.writeHead(403).end('forbidden');
        return;
      }
      const fileStat = await stat(candidate);
      if (!fileStat.isFile()) {
        response.writeHead(404).end('not found');
        return;
      }
      const bytes = await readFile(candidate);
      response.writeHead(200, {
        'Content-Type': contentTypeFor(candidate),
        'Content-Length': String(bytes.byteLength),
        'Cache-Control': 'no-store',
      });
      response.end(bytes);
    } catch (error) {
      response.writeHead(error?.code === 'ENOENT' ? 404 : 500).end(error?.message ?? String(error));
    }
  });
  await new Promise((accept, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', accept);
  });
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('model server did not expose a TCP address');
  return {
    url: `http://127.0.0.1:${address.port}`,
    close: () => new Promise((accept, reject) => server.close((error) => error ? reject(error) : accept())),
  };
}

function buildRuntimeConfig(scenario, prompt) {
  const runtimeConfig = JSON.parse(JSON.stringify(scenario.doppler.runtimeConfig ?? {}));
  const inference = (runtimeConfig.inference ??= {});
  inference.prompt = prompt;
  inference.sampling = {
    ...(inference.sampling ?? {}),
    temperature: scenario.promptWorkload.temperature,
    topK: scenario.promptWorkload.topK,
    topP: scenario.promptWorkload.topP,
  };
  inference.generation = {
    ...(inference.generation ?? {}),
    maxTokens: scenario.promptWorkload.decodeTokens,
  };
  return runtimeConfig;
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const outDir = resolve(repoRoot, 'bench/out/external-projects/doppler', options.runId);
  const runtimeDir = resolve(outDir, 'xdg-runtime');
  const nativeTracePath = resolve(outDir, 'native-program-identity.ndjson');
  await mkdir(outDir, { recursive: false });
  await mkdir(runtimeDir, { recursive: true });
  await writeFile(nativeTracePath, '');
  process.env.XDG_RUNTIME_DIR = runtimeDir;
  process.env.DOE_PROGRAM_IDENTITY_TRACE_PATH = nativeTracePath;

  const baseScenarioBytes = await readFile(baseScenarioPath);
  const scenario = await loadVendorNodeScenario(baseScenarioPath);
  const providerModulePath = resolveRepoPath('packages/doe-gpu/src/compute.js');
  const providerContractPath = resolveRepoPath('packages/doe-gpu/src/node-webgpu.js');
  const nativeAddonPath = resolve(repoRoot, 'packages/doe-gpu/build/Release/doe_napi.node');
  const nativeLibraryPath = resolve(repoRoot, 'runtime/zig/zig-out/lib/libwebgpu_doe_full.so');
  process.env.DOPPLER_NODE_WEBGPU_MODULE = providerModulePath;
  process.env.DOE_WEBGPU_LIB = nativeLibraryPath;

  const providerBridge = await importFromPath(resolve(scenario.dopplerRoot, 'src/tooling/node-webgpu.js'));
  const bootstrap = await providerBridge.bootstrapNodeWebGPU({ providerContractModule: providerContractPath });
  if (bootstrap.ok !== true) throw new Error(`Doe provider bootstrap failed: ${bootstrap.detail ?? 'unknown'}`);

  const prompt = await resolvePrompt(scenario);
  const runtimeConfig = buildRuntimeConfig(scenario, prompt.prompt);
  const modelServer = await startStaticServer(scenario.doppler.modelPath);
  let harness = null;
  try {
    const modelHelpers = await importFromPath(
      resolve(scenario.dopplerRoot, 'src/inference/browser-harness-model-helpers.js'),
    );
    const textHelpers = await importFromPath(
      resolve(scenario.dopplerRoot, 'src/inference/browser-harness-text-helpers.js'),
    );
    harness = await modelHelpers.initializeSuiteModel({
      modelId: scenario.doppler.modelId,
      modelUrl: modelServer.url,
      cacheMode: scenario.cacheMode,
      loadMode: 'http',
      runtime: { runtimeConfig },
    });
    if (options.suppressDiagnosticCopies) {
      const deviceModule = await importFromPath(resolve(scenario.dopplerRoot, 'src/gpu/device.js'));
      suppressDiagnosticSideEffects(
        deviceModule.getDevice(),
        options.suppressDiagnosticAllocations,
        options.diagnosticAllocationBytes,
      );
    }
    const captureConfig = {
      enabled: true,
      defaultLevel: 'none',
      targetLevel: 'slice',
      targetOpIds: options.opIds ?? [],
      targetOperatorClasses: options.operatorClasses ?? [],
      targetLayers: options.layers ?? [],
      sampleCount: 8,
      escalation: null,
    };
    // Model loading is intentionally outside the compared inference trajectory.
    // Native tracing opens the file per row, so truncating at this quiescent
    // boundary yields an exact generation-only dispatch stream.
    await writeFile(nativeTracePath, '');
    const generation = await textHelpers.runGeneration(harness.pipeline, runtimeConfig, {
      prompt: prompt.prompt,
      maxTokens: scenario.promptWorkload.decodeTokens,
      sampling: {
        temperature: scenario.promptWorkload.temperature,
        topK: scenario.promptWorkload.topK,
        topP: scenario.promptWorkload.topP,
      },
      diagnostics: { enabled: true, captureConfig },
    });
    const operatorDiagnostics = harness.pipeline.stats?.operatorDiagnostics ?? null;
    const tokenId = generation.tokenIds.length === 1 ? generation.tokenIds[0] : null;
    const logitsDigest = generation.logitsDigests.length === 1
      ? generation.logitsDigests[0]?.digest ?? generation.logitsDigests[0]
      : null;
    const capturedRecords = operatorDiagnostics?.timeline?.filter((record) => record.capture != null) ?? [];
    const nativeTraceBytes = await readFile(nativeTracePath);
    const nativeTraceRows = nativeTraceBytes.toString('utf8').split('\n').filter(Boolean);
    const nativeDispatchCount = nativeTraceRows.reduce((count, row) => {
      try {
        return count + (JSON.parse(row).event === 'dispatch_encoded' ? 1 : 0);
      } catch {
        return count;
      }
    }, 0);
    const result = {
      schema: 'doe.doppler-selective-operator-capture/v1',
      evidenceClass: 'diagnostic-correctness-localization',
      runId: options.runId,
      selector: {
        operatorClasses: options.operatorClasses,
        opIds: options.opIds,
        layers: options.layers,
        suppressDiagnosticCopies: options.suppressDiagnosticCopies,
        suppressDiagnosticAllocations: options.suppressDiagnosticAllocations,
        diagnosticAllocationBytes: options.diagnosticAllocationBytes,
      },
      source: {
        baseScenario: { path: baseScenarioPath, sha256: sha256(baseScenarioBytes) },
        dopplerRoot: scenario.dopplerRoot,
        dopplerSourceCommit: scenario.doppler.sourceCommit,
        providerModule: { path: providerModulePath, sha256: sha256(await readFile(providerModulePath)) },
        nativeAddon: { path: nativeAddonPath, sha256: sha256(await readFile(nativeAddonPath)) },
        nativeLibrary: { path: nativeLibraryPath, sha256: sha256(await readFile(nativeLibraryPath)) },
        nativeProgramIdentityTrace: {
          path: nativeTracePath,
          sha256: sha256(nativeTraceBytes),
          rowCount: nativeTraceRows.length,
          dispatchCount: nativeDispatchCount,
        },
      },
      observation: {
        tokenId,
        logitsDigest,
        output: generation.output,
        expectedTokenId: EXPECTED_TOKEN_ID,
        expectedLogitsDigest: EXPECTED_LOGITS_DIGEST,
        exact: tokenId === EXPECTED_TOKEN_ID && logitsDigest === EXPECTED_LOGITS_DIGEST,
        operatorRecordCount: operatorDiagnostics?.recordCount ?? null,
        capturedRecordCount: capturedRecords.length,
        capturedOpIds: capturedRecords.map((record) => record.opId),
      },
    };
    const resultPath = resolve(outDir, 'result.json');
    await writeFile(resultPath, `${JSON.stringify(result, null, 2)}\n`);
    process.stdout.write(`${JSON.stringify({ resultPath, ...result.observation })}\n`);
  } finally {
    await harness?.pipeline?.unload?.();
    await bootstrap.module?.releaseTrackedDevices?.();
    await providerBridge.releaseNodeWebGPU?.();
    await modelServer.close();
  }
}

await main();

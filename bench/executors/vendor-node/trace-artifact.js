import { mkdir, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';

async function ensureParentDir(path) {
  await mkdir(dirname(path), { recursive: true });
}

async function writeJson(path, payload) {
  await ensureParentDir(path);
  await writeFile(path, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

async function writeNdjson(path, rows) {
  await ensureParentDir(path);
  const body = rows.map((row) => JSON.stringify(row)).join('\n');
  await writeFile(path, body.length > 0 ? `${body}\n` : '', 'utf8');
}

function createBaseTraceMeta({
  runtimeHost = 'node',
  benchmarkLane,
  executionProvider,
  executionProviderName,
  workloadId,
  scenarioId,
  executionBackend,
  executionLabel,
  processWallMs,
  timingMs = processWallMs,
  timingSource = 'wall-time',
  timingClass = null,
  adapterInfo,
  extraMeta,
}) {
  const traceMeta = {
    traceMetaVersion: 1,
    runtimeHost,
    benchmarkLane,
    workloadId,
    scenarioId,
    executionBackend,
    executionLabel,
    executionProvider,
    executionProviderName,
    processWallMs,
    timingMs,
    timingSource,
    adapterInfo,
    ...extraMeta,
  };
  if (timingClass !== null) {
    traceMeta.timingClass = timingClass;
  }
  return traceMeta;
}

export async function writeVendorNodeSuccessTrace({
  runtimeHost = 'node',
  benchmarkLane = 'node-ort-vs-doppler',
  executionProvider = 'doe',
  executionProviderName = 'doe-gpu',
  traceMetaPath,
  traceJsonlPath,
  workloadId,
  scenarioId,
  executionBackend,
  executionLabel,
  processWallMs,
  timingMs = processWallMs,
  timingSource = 'wall-time',
  timingClass = null,
  adapterInfo,
  phaseTimingsMs,
  promptSummary,
  resultSummary,
  extraMeta = {},
}) {
  const traceMeta = createBaseTraceMeta({
    runtimeHost,
    benchmarkLane,
    executionProvider,
    executionProviderName,
    workloadId,
    scenarioId,
    executionBackend,
    executionLabel,
    processWallMs,
    timingMs,
    timingSource,
    timingClass,
    adapterInfo,
    extraMeta: {
      executionRowCount: 1,
      executionSuccessCount: 1,
      executionErrorCount: 0,
      phaseTimingsMs,
      promptSummary,
      resultSummary,
      ...extraMeta,
    },
  });
  const rows = [
    {
      traceFormat: 'vendor-node-benchmark-v1',
      status: 'success',
      executionBackend,
      workloadId,
      scenarioId,
      processWallMs,
      timingMs,
      timingSource,
      ...(timingClass !== null ? { timingClass } : {}),
      phaseTimingsMs,
      promptSummary,
      resultSummary,
    },
  ];
  await writeJson(traceMetaPath, traceMeta);
  await writeNdjson(traceJsonlPath, rows);
}

export async function writeVendorNodeFailureTrace({
  runtimeHost = 'node',
  benchmarkLane = 'node-ort-vs-doppler',
  executionProvider = 'doe',
  executionProviderName = 'doe-gpu',
  traceMetaPath,
  traceJsonlPath,
  workloadId,
  scenarioId,
  executionBackend,
  executionLabel,
  processWallMs,
  errorMessage,
  extraMeta = {},
}) {
  const traceMeta = createBaseTraceMeta({
    runtimeHost,
    benchmarkLane,
    executionProvider,
    executionProviderName,
    workloadId,
    scenarioId,
    executionBackend,
    executionLabel,
    processWallMs,
    adapterInfo: null,
    extraMeta: {
      executionRowCount: 0,
      executionSuccessCount: 0,
      executionErrorCount: 1,
      terminalFailureCaptured: true,
      failureMessage: errorMessage,
      ...extraMeta,
    },
  });
  const rows = [
    {
      traceFormat: 'vendor-node-benchmark-v1',
      status: 'error',
      executionBackend,
      workloadId,
      scenarioId,
      processWallMs,
      errorMessage,
    },
  ];
  await writeJson(traceMetaPath, traceMeta);
  await writeNdjson(traceJsonlPath, rows);
}

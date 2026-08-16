#!/usr/bin/env node

import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptPath = fileURLToPath(import.meta.url);
const repoRoot = resolve(dirname(scriptPath), '../..');
const baseScenarioPath = resolve(
  repoRoot,
  'bench/vendor-node/doppler_provider_logit_divergence_gemma270m_commands.json',
);
const workerPath = resolve(repoRoot, 'bench/executors/run-node-doppler-ort-bench.js');
const EXPECTED_TOKEN_ID = 818;
const KNOWN_WRONG_TOKEN_ID = 34492;
const EXPECTED_LOGITS_DIGEST =
  'sha256:71a1e8031fc2186659689458869ea1b6d42f83c6c76cc00755c5d2935ffeda4c';

function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

function parseLayerSet(value) {
  const layers = new Set();
  for (const part of value.split(',')) {
    const normalized = part.trim();
    if (!normalized) continue;
    const range = normalized.match(/^(\d+)-(\d+)$/u);
    if (range) {
      const first = Number.parseInt(range[1], 10);
      const last = Number.parseInt(range[2], 10);
      if (last < first) throw new Error(`descending layer range is invalid: ${normalized}`);
      for (let layer = first; layer <= last; layer += 1) layers.add(layer);
      continue;
    }
    if (!/^\d+$/u.test(normalized)) throw new Error(`invalid layer selector: ${normalized}`);
    layers.add(Number.parseInt(normalized, 10));
  }
  const sorted = [...layers].sort((left, right) => left - right);
  if (sorted.length === 0) throw new Error('--layers must select at least one layer');
  return sorted;
}

function parseArgs(argv) {
  const options = {
    layers: null,
    disablePooling: false,
    runId: null,
    processTimeoutMs: 180_000,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--layers') options.layers = parseLayerSet(argv[++index] ?? '');
    else if (argument === '--disable-pooling') options.disablePooling = true;
    else if (argument === '--run-id') options.runId = argv[++index] ?? null;
    else if (argument === '--process-timeout-ms') {
      options.processTimeoutMs = Number.parseInt(argv[++index] ?? '', 10);
    } else {
      throw new Error(`unknown argument: ${argument}`);
    }
  }
  if (!options.layers && !options.disablePooling) {
    throw new Error('at least one of --layers or --disable-pooling is required');
  }
  if (!options.runId || !/^[A-Za-z0-9._-]+$/u.test(options.runId)) {
    throw new Error('--run-id must contain only letters, digits, dots, underscores, or hyphens');
  }
  if (!Number.isInteger(options.processTimeoutMs) || options.processTimeoutMs < 1) {
    throw new Error('--process-timeout-ms must be a positive integer');
  }
  return options;
}

async function listFiles(root, relative = '') {
  const directory = resolve(root, relative);
  let entries;
  try {
    entries = await readdir(directory, { withFileTypes: true });
  } catch (error) {
    if (error?.code === 'ENOENT') return [];
    throw error;
  }
  const files = [];
  for (const entry of entries) {
    const child = relative ? `${relative}/${entry.name}` : entry.name;
    if (entry.isDirectory()) files.push(...await listFiles(root, child));
    else if (entry.isFile()) files.push(child);
  }
  return files.sort();
}

async function runProcess(command, args, options) {
  const child = spawn(command, args, {
    cwd: options.cwd,
    env: options.env,
    detached: process.platform !== 'win32',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stdoutTail = '';
  let stderrTail = '';
  let timedOut = false;
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', (chunk) => { stdoutTail = `${stdoutTail}${chunk}`.slice(-131_072); });
  child.stderr.on('data', (chunk) => { stderrTail = `${stderrTail}${chunk}`.slice(-131_072); });
  const timer = setTimeout(() => {
    timedOut = true;
    try {
      if (process.platform === 'win32') child.kill('SIGKILL');
      else process.kill(-child.pid, 'SIGKILL');
    } catch (error) {
      if (error?.code !== 'ESRCH') throw error;
    }
  }, options.timeoutMs);
  const termination = await new Promise((accept, reject) => {
    child.once('error', reject);
    child.once('exit', (exitCode, signal) => accept({ exitCode, signal }));
  });
  clearTimeout(timer);
  return { ...termination, timedOut, stdoutTail, stderrTail };
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const outDir = resolve(repoRoot, 'bench/out/external-projects/doppler', options.runId);
  const runtimeDir = resolve(outDir, 'xdg-runtime');
  const fixtureDir = resolve(outDir, 'tsir-fixture');
  await mkdir(outDir, { recursive: false });
  await mkdir(runtimeDir, { recursive: true });

  const baseScenarioBytes = await readFile(baseScenarioPath);
  const scenario = JSON.parse(baseScenarioBytes.toString('utf8'));
  if (!Array.isArray(scenario) || scenario.length !== 1) {
    throw new Error('base Doppler scenario must contain exactly one command');
  }
  const command = scenario[0];
  const baseScenarioDir = dirname(baseScenarioPath);
  command.dopplerRoot = resolve(baseScenarioDir, command.dopplerRoot);
  if (typeof command.tjs?.localModelPath === 'string') {
    command.tjs.localModelPath = resolve(baseScenarioDir, command.tjs.localModelPath);
  }
  if (typeof command.doppler?.modelPath === 'string') {
    command.doppler.modelPath = resolve(baseScenarioDir, command.doppler.modelPath);
  }
  command.benchmarkLane = 'doppler-node-selective-tsir-capture';
  const shared = (command.doppler.runtimeConfig.shared ??= {});
  const harness = (shared.harness ??= {});
  delete harness.mode;
  if (options.layers) {
    harness.tsirFixture = {
      dir: fixtureDir,
      layerFilter: options.layers,
    };
  } else {
    delete harness.tsirFixture;
  }
  if (options.disablePooling) {
    const bufferPool = (shared.bufferPool ??= {});
    bufferPool.limits = {
      ...(bufferPool.limits ?? {}),
      maxBuffersPerBucket: 0,
      maxTotalPooledBuffers: 0,
    };
  }

  const generatedScenarioBytes = Buffer.from(`${JSON.stringify(scenario, null, 2)}\n`);
  const scenarioPath = resolve(outDir, 'scenario.json');
  const traceMetaPath = resolve(outDir, 'trace.meta.json');
  const traceJsonlPath = resolve(outDir, 'trace.ndjson');
  const nativeTracePath = resolve(outDir, 'native.ndjson');
  await writeFile(scenarioPath, generatedScenarioBytes);
  await writeFile(nativeTracePath, '');

  const processResult = await runProcess(process.execPath, [
    workerPath,
    '--provider', 'doe',
    '--scenario', scenarioPath,
    '--trace-meta', traceMetaPath,
    '--trace-jsonl', traceJsonlPath,
    '--workload', command.scenarioId,
  ], {
    cwd: repoRoot,
    env: {
      ...process.env,
      XDG_RUNTIME_DIR: runtimeDir,
      DOE_PROGRAM_IDENTITY_TRACE_PATH: nativeTracePath,
    },
    timeoutMs: options.processTimeoutMs,
  });

  const trace = processResult.exitCode === 0
    ? JSON.parse(await readFile(traceMetaPath, 'utf8'))
    : null;
  const tokenIds = trace?.resultSummary?.referenceTranscript?.tokens?.ids ?? [];
  const tokenId = tokenIds.length === 1 ? tokenIds[0] : null;
  const logitsDigests = trace?.resultSummary?.referenceTranscript?.logits?.perStepDigests ?? [];
  const logitsDigest = logitsDigests.length === 1 ? logitsDigests[0] : null;
  const fixtureFiles = await listFiles(fixtureDir);
  const result = {
    schema: 'doe.doppler-selective-tsir-capture/v1',
    evidenceClass: 'diagnostic-correctness-localization',
    runId: options.runId,
    selectedLayers: options.layers,
    bufferPoolingDisabled: options.disablePooling,
    source: {
      baseScenario: {
        path: baseScenarioPath,
        sha256: sha256(baseScenarioBytes),
      },
      generatedScenario: {
        path: scenarioPath,
        sha256: sha256(generatedScenarioBytes),
      },
      worker: {
        path: workerPath,
        sha256: sha256(await readFile(workerPath)),
      },
    },
    process: processResult,
    observation: {
      tokenId,
      expectedTokenId: EXPECTED_TOKEN_ID,
      knownWrongTokenId: KNOWN_WRONG_TOKEN_ID,
      logitsDigest,
      expectedLogitsDigest: EXPECTED_LOGITS_DIGEST,
      exactLogitsObserved: logitsDigest === EXPECTED_LOGITS_DIGEST,
      correctionObserved:
        tokenId === EXPECTED_TOKEN_ID && logitsDigest === EXPECTED_LOGITS_DIGEST,
      knownFailureReproduced: tokenId === KNOWN_WRONG_TOKEN_ID,
      generatedTextPreview: trace?.resultSummary?.generatedTextPreview ?? null,
      lifecycleEvidenceState: trace?.lifecycleEvidenceState ?? null,
      fixtureFileCount: fixtureFiles.length,
      fixtureFiles,
    },
  };
  const resultPath = resolve(outDir, 'result.json');
  await writeFile(resultPath, `${JSON.stringify(result, null, 2)}\n`);
  process.stdout.write(`${JSON.stringify({ resultPath, ...result.observation })}\n`);
  if (processResult.exitCode !== 0 || processResult.timedOut) process.exitCode = 1;
}

await main();

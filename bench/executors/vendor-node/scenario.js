import { readFile } from 'node:fs/promises';
import { dirname, isAbsolute, resolve } from 'node:path';
import { parseArgs } from 'node:util';

const SCENARIO_KIND = 'vendor-node-benchmark-scenario';
const SCENARIO_SCHEMA_VERSION = 1;

function asNonEmptyString(value, fieldName) {
  if (typeof value !== 'string' || value.trim() === '') {
    throw new Error(`${fieldName} must be a non-empty string`);
  }
  return value.trim();
}

function asPositiveInteger(value, fieldName) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1) {
    throw new Error(`${fieldName} must be an integer >= 1`);
  }
  return parsed;
}

function asSamplingUnitInterval(value, fieldName) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < 0 || parsed > 1) {
    throw new Error(`${fieldName} must be a finite number between 0 and 1`);
  }
  return parsed;
}

function asSamplingTemperature(value, fieldName) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < 0) {
    throw new Error(`${fieldName} must be a finite number >= 0`);
  }
  return parsed;
}

function asOptionalRuntimeConfig(value, fieldName) {
  if (value == null) {
    return null;
  }
  if (typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${fieldName} must be an object when present`);
  }
  return value;
}

function resolveFromScenarioDir(baseDir, value, fieldName) {
  const normalized = asNonEmptyString(value, fieldName);
  return isAbsolute(normalized) ? normalized : resolve(baseDir, normalized);
}

function resolveOptionalPath(baseDir, value, fieldName) {
  return typeof value === 'string' && value.trim() !== ''
    ? resolveFromScenarioDir(baseDir, value, fieldName)
    : null;
}

function resolveOptionalString(value) {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : null;
}

export function parseVendorNodeCliArgs(usageCommand) {
  const args = parseArgs({
    options: {
      provider: { type: 'string', default: 'doe' },
      scenario: { type: 'string', default: '' },
      'trace-meta': { type: 'string', default: '' },
      'trace-jsonl': { type: 'string', default: '' },
      workload: { type: 'string', default: '' },
    },
    allowPositionals: false,
  }).values;
  if (!args.scenario || !args['trace-meta'] || !args['trace-jsonl'] || !args.workload) {
    throw new Error(
      `usage: ${usageCommand} --scenario <path> --trace-meta <path> --trace-jsonl <path> --workload <id>`,
    );
  }
  return {
    provider: asNonEmptyString(args.provider, 'provider').toLowerCase(),
    scenarioPath: args.scenario,
    traceMetaPath: args['trace-meta'],
    traceJsonlPath: args['trace-jsonl'],
    workloadId: args.workload,
  };
}

export async function loadVendorNodeScenario(scenarioPath) {
  const raw = JSON.parse(await readFile(scenarioPath, 'utf8'));
  if (!Array.isArray(raw) || raw.length !== 1) {
    throw new Error(
      `vendor benchmark scenario ${scenarioPath} must be a JSON array with exactly one entry`,
    );
  }
  const command = raw[0];
  if (!command || typeof command !== 'object' || Array.isArray(command)) {
    throw new Error(`vendor benchmark scenario ${scenarioPath} must contain an object command`);
  }
  if (asNonEmptyString(command.kind, 'scenario.kind') !== SCENARIO_KIND) {
    throw new Error(`scenario.kind must be ${SCENARIO_KIND}`);
  }
  if (asPositiveInteger(command.schemaVersion, 'scenario.schemaVersion') !== SCENARIO_SCHEMA_VERSION) {
    throw new Error(`scenario.schemaVersion must be ${SCENARIO_SCHEMA_VERSION}`);
  }

  const scenarioDir = dirname(resolve(scenarioPath));
  const promptWorkload = command.promptWorkload;
  if (!promptWorkload || typeof promptWorkload !== 'object' || Array.isArray(promptWorkload)) {
    throw new Error('scenario.promptWorkload must be an object');
  }
  const tjs = command.tjs;
  if (!tjs || typeof tjs !== 'object' || Array.isArray(tjs)) {
    throw new Error('scenario.tjs must be an object');
  }
  const doppler = command.doppler;
  if (!doppler || typeof doppler !== 'object' || Array.isArray(doppler)) {
    throw new Error('scenario.doppler must be an object');
  }

  const dopplerRoot = resolveFromScenarioDir(
    scenarioDir,
    command.dopplerRoot,
    'scenario.dopplerRoot',
  );
  const tjsLocalModelPath = resolveOptionalPath(
    scenarioDir,
    tjs.localModelPath,
    'scenario.tjs.localModelPath',
  );
  const dopplerModelPath = resolveOptionalPath(
    scenarioDir,
    doppler.modelPath,
    'scenario.doppler.modelPath',
  );

  return {
    scenarioPath: resolve(scenarioPath),
    scenarioId: asNonEmptyString(command.scenarioId, 'scenario.scenarioId'),
    benchmarkLane: resolveOptionalString(command.benchmarkLane) ?? 'node-ort-vs-doppler',
    dopplerRoot,
    cacheMode: asNonEmptyString(command.cacheMode ?? 'warm', 'scenario.cacheMode'),
    loadMode: asNonEmptyString(command.loadMode ?? 'http', 'scenario.loadMode'),
    useChatTemplate: command.useChatTemplate === true,
    promptWorkload: {
      prefillTokens: asPositiveInteger(
        promptWorkload.prefillTokens,
        'scenario.promptWorkload.prefillTokens',
      ),
      decodeTokens: asPositiveInteger(
        promptWorkload.decodeTokens,
        'scenario.promptWorkload.decodeTokens',
      ),
      temperature: asSamplingTemperature(
        promptWorkload.temperature ?? 0,
        'scenario.promptWorkload.temperature',
      ),
      topK: asPositiveInteger(
        promptWorkload.topK ?? 1,
        'scenario.promptWorkload.topK',
      ),
      topP: asSamplingUnitInterval(
        promptWorkload.topP ?? 1,
        'scenario.promptWorkload.topP',
      ),
    },
    tjs: {
      modelId: asNonEmptyString(tjs.modelId, 'scenario.tjs.modelId'),
      dtype: asNonEmptyString(tjs.dtype ?? 'fp16', 'scenario.tjs.dtype'),
      localModelPath: tjsLocalModelPath,
    },
    doppler: {
      modelId: asNonEmptyString(doppler.modelId, 'scenario.doppler.modelId'),
      sourceCommit: resolveOptionalString(doppler.sourceCommit),
      loadMode: resolveOptionalString(doppler.loadMode),
      modelPath: dopplerModelPath,
      runtimeProfile: resolveOptionalString(doppler.runtimeProfile),
      runtimeConfig: asOptionalRuntimeConfig(
        doppler.runtimeConfig ?? null,
        'scenario.doppler.runtimeConfig',
      ),
    },
  };
}

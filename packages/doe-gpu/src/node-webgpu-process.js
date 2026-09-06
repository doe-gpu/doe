// Provider-neutral DoeProof process execution for unchanged Node WebGPU apps.

import { spawn } from 'node:child_process';
import { terminateProcess } from './node-process-termination.js';
import { createHash } from 'node:crypto';
import { realpathSync } from 'node:fs';
import { isAbsolute, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  NODE_WEBGPU_LOADER_CONTRACT,
  NODE_WEBGPU_LOADER_PROGRAM_OBSERVATION_CONTRACT,
  NODE_WEBGPU_LOADER_PROGRAM_OBSERVATION_REASONS,
} from './node-webgpu-loader.js';
import { validateTransparentWebGPUObservation } from './observe.js';

export const NODE_WEBGPU_GOVERNED_PROCESS_RECEIPT_SCHEMA =
  'doe.governed-node-webgpu-process-receipt/v1';

export const NODE_WEBGPU_GOVERNED_PROCESS_ERROR_CODES = Object.freeze([
  'DOE_GOVERNED_PROCESS_INVALID_CONFIGURATION',
  'DOE_GOVERNED_PROCESS_SPAWN_FAILED',
  'DOE_GOVERNED_PROCESS_ABORTED',
  'DOE_GOVERNED_PROCESS_TIMEOUT',
  'DOE_GOVERNED_PROCESS_OUTPUT_LIMIT',
  'DOE_GOVERNED_PROCESS_EXIT_FAILED',
  'DOE_GOVERNED_PROCESS_EVALUATION_FAILED',
  'DOE_GOVERNED_PROCESS_PROVIDER_IDENTITY_FAILED',
  'DOE_GOVERNED_PROCESS_PROGRAM_EVIDENCE_FAILED',
  'DOE_GOVERNED_PROCESS_ORACLE_FAILED',
  'DOE_GOVERNED_PROCESS_RECEIPT_SINK_FAILED',
]);

const SHA256_PATTERN = /^sha256:[a-f0-9]{64}$/;
const PROVIDER_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const PROVIDER_KEYS = new Set(['id', 'module']);
const WORKLOAD_KEYS = new Set([
  'id',
  'version',
  'implementationSha256',
  'input',
  'expectedOutputSha256',
]);
const PROCESS_KEYS = new Set([
  'executable',
  'nodeArgs',
  'entrypoint',
  'args',
  'cwd',
  'environment',
  'filesystem',
  'timeoutMs',
  'maxOutputBytes',
]);
const ENVIRONMENT_KEYS = new Set(['mode', 'values']);
const FILESYSTEM_KEYS = new Set(['mode', 'readPaths']);
const OBSERVATION_KEYS = new Set(['output', 'providerIdentity', 'evidence']);
const loaderPath = fileURLToPath(new URL('./node-webgpu-loader.js', import.meta.url));
const observerPath = fileURLToPath(new URL('./observe.js', import.meta.url));

function own(object, key) {
  return Object.prototype.hasOwnProperty.call(object, key);
}

function assertPlainObject(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new TypeError(`${label} must be an object.`);
  }
  return value;
}

function assertKnownKeys(value, allowed, label) {
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) throw new TypeError(`${label} contains unsupported field "${key}".`);
  }
}

function assertNonEmptyString(value, label) {
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new TypeError(`${label} must be a non-empty string.`);
  }
  return value;
}

function assertSha256(value, label) {
  if (typeof value !== 'string' || !SHA256_PATTERN.test(value)) {
    throw new TypeError(`${label} must be a lowercase sha256:<64 hex> digest.`);
  }
}

function assertStringArray(value, label) {
  if (!Array.isArray(value) || value.some((item) => typeof item !== 'string')) {
    throw new TypeError(`${label} must be an array of strings.`);
  }
  return [...value];
}

function cloneJsonValue(value, label) {
  function validate(item, path) {
    if (item === null || typeof item === 'string' || typeof item === 'boolean') return;
    if (typeof item === 'number' && Number.isFinite(item)) return;
    if (Array.isArray(item)) {
      item.forEach((entry, index) => validate(entry, `${path}[${index}]`));
      return;
    }
    if (item && typeof item === 'object'
        && (Object.getPrototypeOf(item) === Object.prototype
          || Object.getPrototypeOf(item) === null)) {
      for (const [key, entry] of Object.entries(item)) validate(entry, `${path}.${key}`);
      return;
    }
    throw new TypeError(`${path} must contain only JSON values.`);
  }
  validate(value, label);
  return JSON.parse(JSON.stringify(value));
}

function byteView(value, label) {
  if (typeof value === 'string') return Buffer.from(value, 'utf8');
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  if (ArrayBuffer.isView(value)) {
    return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  }
  throw new TypeError(`${label} must be a string, ArrayBuffer, or ArrayBuffer view.`);
}

function cloneReceiptValue(value) {
  if (value === undefined) return null;
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return value;
  if (typeof value === 'number') return Number.isFinite(value) ? value : String(value);
  if (Array.isArray(value)) return value.map(cloneReceiptValue);
  if (typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, cloneReceiptValue(item)]));
  }
  return String(value);
}

function stableReceiptValue(value) {
  if (Array.isArray(value)) return value.map(stableReceiptValue);
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.keys(value).sort().map((key) => [key, stableReceiptValue(value[key])]),
    );
  }
  return value;
}

function sha256(value) {
  const bytes = typeof value === 'string' ? Buffer.from(value, 'utf8') : value;
  return `sha256:${createHash('sha256').update(bytes).digest('hex')}`;
}

function stableSha256(value) {
  return sha256(JSON.stringify(stableReceiptValue(value)));
}

function processError(code, stage, error) {
  return {
    code,
    stage,
    detail: error instanceof Error ? error.message : String(error),
  };
}

function normalizeProvider(provider) {
  assertPlainObject(provider, 'provider');
  assertKnownKeys(provider, PROVIDER_KEYS, 'provider');
  assertNonEmptyString(provider.id, 'provider.id');
  if (!PROVIDER_ID_PATTERN.test(provider.id)) {
    throw new TypeError('provider.id contains unsupported characters.');
  }
  assertNonEmptyString(provider.module, 'provider.module');
  return { id: provider.id, module: provider.module };
}

function normalizeWorkload(workload) {
  assertPlainObject(workload, 'workload');
  assertKnownKeys(workload, WORKLOAD_KEYS, 'workload');
  assertNonEmptyString(workload.id, 'workload.id');
  assertNonEmptyString(workload.version, 'workload.version');
  assertSha256(workload.implementationSha256, 'workload.implementationSha256');
  assertSha256(workload.expectedOutputSha256, 'workload.expectedOutputSha256');
  const input = byteView(workload.input, 'workload.input');
  return {
    id: workload.id,
    version: workload.version,
    implementationSha256: workload.implementationSha256,
    inputSha256: sha256(input),
    inputBytes: input.byteLength,
    expectedOutputSha256: workload.expectedOutputSha256,
  };
}

function normalizeEnvironment(environment) {
  assertPlainObject(environment, 'process.environment');
  assertKnownKeys(environment, ENVIRONMENT_KEYS, 'process.environment');
  if (!['inherit', 'sealed'].includes(environment.mode)) {
    throw new TypeError('process.environment.mode must be "inherit" or "sealed".');
  }
  const values = environment.values ?? {};
  assertPlainObject(values, 'process.environment.values');
  for (const [key, value] of Object.entries(values)) {
    if (key.length === 0 || (typeof value !== 'string' && value !== null)) {
      throw new TypeError('process.environment.values must map non-empty names to strings or null.');
    }
  }
  const effective = environment.mode === 'inherit' ? { ...process.env } : {};
  for (const [key, value] of Object.entries(values)) {
    if (value === null) delete effective[key];
    else effective[key] = value;
  }
  const normalizedEffective = Object.fromEntries(
    Object.entries(effective)
      .filter(([, value]) => value !== undefined)
      .map(([key, value]) => [key, String(value)]),
  );
  return {
    mode: environment.mode,
    effective: normalizedEffective,
    identity: {
      mode: environment.mode,
      keys: Object.keys(normalizedEffective).sort(),
      sha256: stableSha256(normalizedEffective),
    },
  };
}

function canonicalReadPath(value, label, cwd = null) {
  const path = value.startsWith('file:')
    ? fileURLToPath(value)
    : cwd === null
      ? value
      : resolve(cwd, value);
  try {
    return realpathSync.native(path);
  } catch (error) {
    throw new TypeError(`${label} must resolve to an existing filesystem path: ${error.message}`);
  }
}

function normalizeFilesystem(filesystem, cwd) {
  const value = filesystem ?? { mode: 'ambient' };
  assertPlainObject(value, 'process.filesystem');
  assertKnownKeys(value, FILESYSTEM_KEYS, 'process.filesystem');
  if (!['ambient', 'node-permission-read-only'].includes(value.mode)) {
    throw new TypeError(
      'process.filesystem.mode must be "ambient" or "node-permission-read-only".',
    );
  }
  const readPaths = assertStringArray(value.readPaths ?? [], 'process.filesystem.readPaths');
  if (readPaths.some((path) => path.trim().length === 0)) {
    throw new TypeError('process.filesystem.readPaths must contain non-empty paths.');
  }
  if (value.mode === 'ambient' && readPaths.length !== 0) {
    throw new TypeError('ambient process.filesystem cannot declare readPaths.');
  }
  const effectiveReadPaths = readPaths.flatMap((path, index) => {
    const declaredPath = resolve(cwd, path);
    const physicalPath = canonicalReadPath(
      declaredPath,
      `process.filesystem.readPaths[${index}]`,
    );
    return declaredPath === physicalPath ? [physicalPath] : [declaredPath, physicalPath];
  });
  return {
    mode: value.mode,
    readPaths: [...new Set(effectiveReadPaths)].sort(),
  };
}

function normalizeProcess(processOptions) {
  assertPlainObject(processOptions, 'process');
  assertKnownKeys(processOptions, PROCESS_KEYS, 'process');
  const executable = assertNonEmptyString(
    processOptions.executable ?? process.execPath,
    'process.executable',
  );
  const cwd = canonicalReadPath(
    resolve(assertNonEmptyString(processOptions.cwd ?? process.cwd(), 'process.cwd')),
    'process.cwd',
  );
  const entrypoint = canonicalReadPath(
    resolve(cwd, assertNonEmptyString(processOptions.entrypoint, 'process.entrypoint')),
    'process.entrypoint',
  );
  const nodeArgs = assertStringArray(processOptions.nodeArgs ?? [], 'process.nodeArgs');
  const args = assertStringArray(processOptions.args ?? [], 'process.args');
  if (!Number.isSafeInteger(processOptions.timeoutMs) || processOptions.timeoutMs <= 0) {
    throw new TypeError('process.timeoutMs must be a positive safe integer.');
  }
  if (!Number.isSafeInteger(processOptions.maxOutputBytes) || processOptions.maxOutputBytes <= 0) {
    throw new TypeError('process.maxOutputBytes must be a positive safe integer.');
  }
  const environment = normalizeEnvironment(processOptions.environment);
  const filesystem = normalizeFilesystem(processOptions.filesystem, cwd);
  if (filesystem.mode === 'node-permission-read-only'
      && nodeArgs.some((argument) => /^(--permission|--experimental-permission|--allow-)/.test(argument))) {
    throw new TypeError(
      'node permission flags are owned by process.filesystem and cannot appear in nodeArgs.',
    );
  }
  return {
    executable,
    nodeArgs,
    entrypoint,
    args,
    cwd,
    environment,
    filesystem,
    timeoutMs: processOptions.timeoutMs,
    maxOutputBytes: processOptions.maxOutputBytes,
  };
}

function filesystemPath(value, label) {
  assertNonEmptyString(value, label);
  if (value.startsWith('file:')) return fileURLToPath(value);
  if (!isAbsolute(value)) {
    throw new TypeError(`${label} must be an absolute path or file URL under Node permissions.`);
  }
  return value;
}

function normalizeOptions(options) {
  assertPlainObject(options, 'options');
  for (const key of Object.keys(options)) {
    if (![
      'provider',
      'workload',
      'process',
      'evaluate',
      'checkpoint',
      'signal',
      'observeProgram',
    ].includes(key)) {
      throw new TypeError(`options contains unsupported field "${key}".`);
    }
  }
  if (typeof options.evaluate !== 'function') throw new TypeError('evaluate must be a function.');
  if (options.checkpoint !== undefined && typeof options.checkpoint !== 'function') {
    throw new TypeError('checkpoint must be a function when provided.');
  }
  if (options.signal !== undefined
      && (typeof options.signal !== 'object'
        || typeof options.signal.aborted !== 'boolean'
        || typeof options.signal.addEventListener !== 'function'
        || typeof options.signal.removeEventListener !== 'function')) {
    throw new TypeError('signal must be an AbortSignal when provided.');
  }
  let provider = normalizeProvider(options.provider);
  const processConfiguration = normalizeProcess(options.process);
  if (options.observeProgram !== undefined
      && typeof options.observeProgram !== 'boolean'
      && (!options.observeProgram
        || typeof options.observeProgram !== 'object'
        || Array.isArray(options.observeProgram))) {
    throw new TypeError('observeProgram must be a boolean or an options object.');
  }
  const observationRequested = options.observeProgram === true
    || (options.observeProgram && typeof options.observeProgram === 'object');
  const observationMetadata = options.observeProgram === true
    ? {}
    : options.observeProgram?.metadata ?? {};
  if (observationRequested) {
    assertPlainObject(observationMetadata, 'observeProgram.metadata');
  }
  const programObservation = {
    requested: Boolean(observationRequested),
    metadata: observationRequested
      ? cloneJsonValue(
        observationMetadata,
        'observeProgram.metadata',
      )
      : {},
  };
  if (processConfiguration.filesystem.mode === 'node-permission-read-only') {
    provider = {
      ...provider,
      module: canonicalReadPath(filesystemPath(provider.module, 'provider.module'), 'provider.module'),
    };
  }
  return {
    provider,
    workload: normalizeWorkload(options.workload),
    process: processConfiguration,
    evaluate: options.evaluate,
    checkpoint: options.checkpoint,
    signal: options.signal,
    programObservation,
  };
}


function spawnProcess(configuration, provider, abortSignal, programObservation) {
  return new Promise((resolveProcess) => {
    const effectiveReadPaths = configuration.filesystem.mode === 'node-permission-read-only'
      ? [...new Set([
        canonicalReadPath(loaderPath, 'loader path'),
        ...(programObservation.requested
          ? [canonicalReadPath(observerPath, 'observer path')]
          : []),
        configuration.entrypoint,
        canonicalReadPath(filesystemPath(provider.module, 'provider.module'), 'provider.module'),
        ...configuration.filesystem.readPaths,
      ])].sort()
      : [];
    const permissionArgs = configuration.filesystem.mode === 'node-permission-read-only'
      ? [
        '--permission',
        '--allow-addons',
        '--allow-worker',
        ...effectiveReadPaths.map((path) => `--allow-fs-read=${path}`),
      ]
      : [];
    const argv = [
      ...permissionArgs,
      ...configuration.nodeArgs,
      '--no-warnings',
      '--experimental-loader',
      loaderPath,
      configuration.entrypoint,
      ...configuration.args,
    ];
    const environment = {
      ...configuration.environment.effective,
      DOE_NODE_WEBGPU_PROVIDER_ID: provider.id,
      DOE_NODE_WEBGPU_PROVIDER_MODULE: provider.module,
      ...(programObservation.requested ? {
        DOE_NODE_WEBGPU_OBSERVE_PROGRAM: '1',
        DOE_NODE_WEBGPU_OBSERVE_METADATA: JSON.stringify(programObservation.metadata),
      } : {}),
    };
    if (configuration.filesystem.mode === 'node-permission-read-only') {
      delete environment.NODE_OPTIONS;
    }
    const filesystem = {
      mode: configuration.filesystem.mode,
      readPaths: effectiveReadPaths,
      workerThreads: configuration.filesystem.mode === 'node-permission-read-only'
        ? 'allowed-for-loader'
        : 'ambient',
      nativeAddons: configuration.filesystem.mode === 'node-permission-read-only'
        ? 'allowed-for-provider'
        : 'ambient',
    };
    const terminationScope = process.platform === 'win32' ? 'child-process' : 'process-group';
    if (abortSignal?.aborted) {
      resolveProcess({
        argv,
        environment,
        filesystem,
        spawned: false,
        aborted: true,
        terminationScope,
        spawnError: null,
        exitCode: null,
        signal: null,
        timedOut: false,
        outputLimitExceeded: false,
        stdout: Buffer.alloc(0),
        stderr: Buffer.alloc(0),
        durationMs: 0,
        programObservation: null,
        programObservationContext: null,
        programObservationCount: 0,
        programObservationErrors: [],
      });
      return;
    }
    const started = process.hrtime.bigint();
    let child;
    try {
      child = spawn(configuration.executable, argv, {
        cwd: configuration.cwd,
        env: environment,
        detached: terminationScope === 'process-group',
        stdio: programObservation.requested
          ? ['ignore', 'pipe', 'pipe', 'ipc']
          : ['ignore', 'pipe', 'pipe'],
      });
    } catch (error) {
      resolveProcess({
        spawnError: error,
        argv,
        environment,
        filesystem,
        spawned: false,
        aborted: false,
        terminationScope,
        durationMs: null,
        programObservation: null,
        programObservationContext: null,
        programObservationCount: 0,
        programObservationErrors: [],
      });
      return;
    }

    let stdout = Buffer.alloc(0);
    let stderr = Buffer.alloc(0);
    let timedOut = false;
    let outputLimitExceeded = false;
    let aborted = false;
    let capturedOutputBytes = 0;
    let spawnError = null;
    let settled = false;
    let observedProgram = null;
    let observedProgramContext = null;
    let programObservationCount = 0;
    const programObservationErrors = [];
    const append = (current, chunk) => {
      const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      const remaining = configuration.maxOutputBytes - capturedOutputBytes;
      if (bytes.length > remaining) {
        outputLimitExceeded = true;
        terminateProcess(child, terminationScope);
        if (remaining <= 0) return current;
        capturedOutputBytes += remaining;
        return Buffer.concat([current, bytes.subarray(0, remaining)]);
      }
      capturedOutputBytes += bytes.length;
      return Buffer.concat([current, bytes]);
    };
    child.stdout.on('data', (chunk) => { stdout = append(stdout, chunk); });
    child.stderr.on('data', (chunk) => { stderr = append(stderr, chunk); });
    child.on('error', (error) => { spawnError = error; });
    if (programObservation.requested) {
      child.on('message', (message) => {
        if (!message || typeof message !== 'object'
            || message.contract !== NODE_WEBGPU_LOADER_PROGRAM_OBSERVATION_CONTRACT) {
          return;
        }
        if (!message.context || typeof message.context !== 'object'
            || Array.isArray(message.context)
            || !NODE_WEBGPU_LOADER_PROGRAM_OBSERVATION_REASONS.includes(
              message.context.reason,
            )) {
          programObservationErrors.push('observed checkpoint context is invalid');
          return;
        }
        const validation = validateTransparentWebGPUObservation(message.observation);
        if (!validation.valid) {
          programObservationErrors.push(...validation.errors);
          return;
        }
        if (message.observation.providerId !== provider.id) {
          programObservationErrors.push('observed providerId does not match the declaration');
          return;
        }
        if (stableSha256(message.observation.metadata)
            !== stableSha256(programObservation.metadata)) {
          programObservationErrors.push('observed metadata does not match the declaration');
          return;
        }
        if (observedProgram) {
          for (const field of Object.keys(observedProgram.summary)) {
            if (message.observation.summary[field] < observedProgram.summary[field]) {
              programObservationErrors.push(`observed ${field} regressed between checkpoints`);
              return;
            }
          }
        }
        observedProgram = message.observation;
        observedProgramContext = { reason: message.context.reason };
        programObservationCount += 1;
      });
    }
    const abortListener = () => {
      aborted = true;
      terminateProcess(child, terminationScope);
    };
    abortSignal?.addEventListener('abort', abortListener, { once: true });
    const timer = setTimeout(() => {
      timedOut = true;
      terminateProcess(child, terminationScope);
    }, configuration.timeoutMs);
    child.on('close', (exitCode, signal) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      abortSignal?.removeEventListener('abort', abortListener);
      resolveProcess({
        argv,
        environment,
        filesystem,
        spawnError,
        spawned: true,
        exitCode,
        signal,
        aborted,
        terminationScope,
        timedOut,
        outputLimitExceeded,
        stdout,
        stderr,
        durationMs: Number(process.hrtime.bigint() - started) / 1e6,
        programObservation: observedProgram,
        programObservationContext: observedProgramContext,
        programObservationCount,
        programObservationErrors,
      });
    });
  });
}

function normalizeObservation(value) {
  assertPlainObject(value, 'evaluate result');
  assertKnownKeys(value, OBSERVATION_KEYS, 'evaluate result');
  const output = byteView(value.output, 'evaluate result.output');
  assertPlainObject(value.providerIdentity, 'evaluate result.providerIdentity');
  return {
    output,
    providerIdentity: cloneReceiptValue(value.providerIdentity),
    evidence: cloneReceiptValue(value.evidence),
  };
}

function providerIdentityErrors(provider, identity) {
  const errors = [];
  if (identity.contract !== NODE_WEBGPU_LOADER_CONTRACT) {
    errors.push('effective provider identity has the wrong loader contract');
  }
  if (identity.requestedSpecifier !== 'webgpu') {
    errors.push('effective provider identity did not bind the exact webgpu specifier');
  }
  if (identity.providerId !== provider.id) {
    errors.push('effective provider id does not match the declared provider');
  }
  if (identity.providerModule !== provider.module) {
    errors.push('effective provider module does not match the declared provider');
  }
  if (typeof identity.resolvedProviderUrl !== 'string' || identity.resolvedProviderUrl.length === 0) {
    errors.push('effective provider identity is missing the resolved provider URL');
  }
  return errors;
}

function workloadIdentity(workload) {
  return {
    id: workload.id,
    version: workload.version,
    implementationSha256: workload.implementationSha256,
    inputSha256: workload.inputSha256,
    inputBytes: workload.inputBytes,
    expectedOutputSha256: workload.expectedOutputSha256,
  };
}

function executionIdentity(receipt) {
  return {
    workloadSha256: receipt.replay.workloadSha256,
    provider: receipt.provider,
    declaration: receipt.process.declaration,
    environment: receipt.process.environment,
    exitCode: receipt.process.exitCode,
    signal: receipt.process.signal,
    spawned: receipt.process.spawned,
    aborted: receipt.process.aborted,
    terminationScope: receipt.process.terminationScope,
    timedOut: receipt.process.timedOut,
    outputLimitExceeded: receipt.process.outputLimitExceeded,
    oracle: receipt.oracle,
    programEvidence: receipt.programEvidence === undefined
      ? undefined
      : {
          status: receipt.programEvidence.status,
          checkpointCount: receipt.programEvidence.checkpointCount,
          observationSha256: receipt.programEvidence.observationSha256,
          ...(own(receipt.programEvidence, 'checkpoint')
            ? { checkpoint: receipt.programEvidence.checkpoint }
            : {}),
        },
  };
}

async function emitCheckpoint(checkpoint, receipt, errors) {
  if (typeof checkpoint !== 'function') return;
  try {
    await checkpoint(cloneReceiptValue(receipt));
  } catch (error) {
    errors.push(processError(
      'DOE_GOVERNED_PROCESS_RECEIPT_SINK_FAILED',
      'receipt.sink',
      error,
    ));
  }
}

export async function runGovernedNodeWebGPUProcess(options) {
  let normalized;
  try {
    normalized = normalizeOptions(options);
  } catch (error) {
    return {
      ok: false,
      receipt: null,
      observation: null,
      stdout: Buffer.alloc(0),
      stderr: Buffer.alloc(0),
      errors: [processError(
        'DOE_GOVERNED_PROCESS_INVALID_CONFIGURATION',
        'configuration',
        error,
      )],
    };
  }

  const errors = [];
  const child = await spawnProcess(
    normalized.process,
    normalized.provider,
    normalized.signal,
    normalized.programObservation,
  );
  if (child.spawnError) {
    errors.push(processError('DOE_GOVERNED_PROCESS_SPAWN_FAILED', 'process.spawn', child.spawnError));
  }
  if (child.aborted) {
    errors.push(processError(
      'DOE_GOVERNED_PROCESS_ABORTED',
      'process.abort',
      'process execution was aborted',
    ));
  }
  if (child.timedOut) {
    errors.push(processError('DOE_GOVERNED_PROCESS_TIMEOUT', 'process.timeout', 'process exceeded timeoutMs'));
  }
  if (child.outputLimitExceeded) {
    errors.push(processError(
      'DOE_GOVERNED_PROCESS_OUTPUT_LIMIT',
      'process.output',
      'process exceeded maxOutputBytes',
    ));
  }
  if (child.spawned && !child.spawnError && (child.exitCode !== 0 || child.signal !== null)) {
    errors.push(processError(
      'DOE_GOVERNED_PROCESS_EXIT_FAILED',
      'process.exit',
      `process exited with code ${child.exitCode} and signal ${child.signal}`,
    ));
  }
  for (const detail of child.programObservationErrors ?? []) {
    errors.push(processError(
      'DOE_GOVERNED_PROCESS_PROGRAM_EVIDENCE_FAILED',
      'program-evidence.validate',
      detail,
    ));
  }
  if (normalized.programObservation.requested
      && child.spawned
      && !child.spawnError
      && !child.aborted
      && !child.timedOut
      && !child.outputLimitExceeded
      && child.exitCode === 0
      && child.signal === null
      && !child.programObservation) {
    errors.push(processError(
      'DOE_GOVERNED_PROCESS_PROGRAM_EVIDENCE_FAILED',
      'program-evidence.missing',
      'observed execution completed without a program observation',
    ));
  }

  let observation = null;
  if (errors.length === 0) {
    try {
      observation = normalizeObservation(await normalized.evaluate({
        stdout: child.stdout,
        stderr: child.stderr,
        exitCode: child.exitCode,
        signal: child.signal,
      }));
    } catch (error) {
      errors.push(processError(
        'DOE_GOVERNED_PROCESS_EVALUATION_FAILED',
        'process.evaluate',
        error,
      ));
    }
  }

  if (observation) {
    for (const detail of providerIdentityErrors(normalized.provider, observation.providerIdentity)) {
      errors.push(processError(
        'DOE_GOVERNED_PROCESS_PROVIDER_IDENTITY_FAILED',
        'provider.identity',
        detail,
      ));
    }
    if (sha256(observation.output) !== normalized.workload.expectedOutputSha256) {
      errors.push(processError(
        'DOE_GOVERNED_PROCESS_ORACLE_FAILED',
        'oracle.output',
        'actual output digest does not match expectedOutputSha256',
      ));
    }
  }

  const workload = workloadIdentity(normalized.workload);
  const receipt = {
    schema: NODE_WEBGPU_GOVERNED_PROCESS_RECEIPT_SCHEMA,
    status: errors.length === 0 ? 'pass' : 'failed',
    checkpoint: 'process-complete',
    workload,
    provider: {
      requested: cloneReceiptValue(normalized.provider),
      effective: observation?.providerIdentity ?? null,
    },
    process: {
      declaration: {
        executable: normalized.process.executable,
        nodeArgs: normalized.process.nodeArgs,
        loaderContract: NODE_WEBGPU_LOADER_CONTRACT,
        entrypoint: normalized.process.entrypoint,
        args: normalized.process.args,
        cwd: normalized.process.cwd,
        filesystem: child.filesystem ?? normalized.process.filesystem,
        timeoutMs: normalized.process.timeoutMs,
        maxOutputBytes: normalized.process.maxOutputBytes,
      },
      environment: {
        mode: normalized.process.environment.mode,
        keys: Object.keys(child.environment ?? {}).sort(),
        sha256: stableSha256(child.environment ?? {}),
      },
      exitCode: child.exitCode ?? null,
      signal: child.signal ?? null,
      spawned: child.spawned ?? false,
      aborted: child.aborted ?? false,
      terminationScope: child.terminationScope,
      timedOut: child.timedOut ?? false,
      outputLimitExceeded: child.outputLimitExceeded ?? false,
      stdoutSha256: child.stdout ? sha256(child.stdout) : null,
      stdoutBytes: child.stdout?.byteLength ?? 0,
      stderrSha256: child.stderr ? sha256(child.stderr) : null,
      stderrBytes: child.stderr?.byteLength ?? 0,
      durationMs: child.durationMs ?? null,
    },
    oracle: {
      status: observation && sha256(observation.output) === normalized.workload.expectedOutputSha256
        ? 'pass'
        : 'fail',
      expectedOutputSha256: normalized.workload.expectedOutputSha256,
      actualOutputSha256: observation ? sha256(observation.output) : null,
      outputBytes: observation?.output.byteLength ?? null,
    },
    applicationEvidence: observation?.evidence ?? null,
    applicationEvidenceSha256: observation ? stableSha256(observation.evidence) : null,
    programEvidence: !normalized.programObservation.requested
      ? {
          status: 'not-requested',
          checkpointCount: 0,
          observationSha256: null,
          observation: null,
          checkpoint: null,
        }
      : child.programObservation
        ? {
            status: 'observed',
            checkpointCount: child.programObservationCount,
            observationSha256: child.programObservation.observationSha256,
            observation: child.programObservation,
            checkpoint: child.programObservationContext,
          }
        : {
            status: 'missing',
            checkpointCount: 0,
            observationSha256: null,
            observation: null,
            checkpoint: null,
          },
    replay: {
      workloadSha256: stableSha256(workload),
      executionSha256: null,
    },
    errors,
  };
  receipt.replay.executionSha256 = stableSha256(executionIdentity(receipt));
  await emitCheckpoint(normalized.checkpoint, receipt, errors);
  receipt.status = errors.length === 0 ? 'pass' : 'failed';
  receipt.errors = errors;
  receipt.replay.executionSha256 = stableSha256(executionIdentity(receipt));

  return {
    ok: errors.length === 0,
    receipt,
    observation,
    programObservation: child.programObservation ?? null,
    stdout: child.stdout ?? Buffer.alloc(0),
    stderr: child.stderr ?? Buffer.alloc(0),
    errors,
  };
}

export function validateGovernedNodeWebGPUProcessReceipt(receipt) {
  const errors = [];
  if (!receipt || typeof receipt !== 'object' || Array.isArray(receipt)) {
    return { valid: false, errors: ['receipt must be an object'] };
  }
  if (receipt.schema !== NODE_WEBGPU_GOVERNED_PROCESS_RECEIPT_SCHEMA) {
    errors.push('schema is not recognized');
  }
  if (receipt.checkpoint !== 'process-complete') errors.push('checkpoint is not process-complete');
  if (!['pass', 'failed'].includes(receipt.status)) errors.push('status is not recognized');
  if (!Array.isArray(receipt.errors)) errors.push('errors must be an array');
  if (!receipt.workload || typeof receipt.workload !== 'object') {
    errors.push('workload is missing');
  } else {
    for (const field of ['implementationSha256', 'inputSha256', 'expectedOutputSha256']) {
      if (!SHA256_PATTERN.test(receipt.workload[field] ?? '')) errors.push(`workload.${field} is invalid`);
    }
  }
  const effective = receipt.provider?.effective;
  const requested = receipt.provider?.requested;
  const receiptErrorCodes = new Set((receipt.errors ?? []).map((error) => error?.code));
  if (!requested || typeof requested !== 'object') errors.push('requested provider is missing');
  if (effective !== null && typeof effective !== 'object') {
    errors.push('effective provider must be an object or null');
  }
  if (requested && effective) {
    const identityProblems = providerIdentityErrors(requested, effective);
    const reportsIdentityFailure = receiptErrorCodes.has(
      'DOE_GOVERNED_PROCESS_PROVIDER_IDENTITY_FAILED',
    );
    if (identityProblems.length > 0 && !reportsIdentityFailure) {
      errors.push(...identityProblems);
    }
    if (identityProblems.length === 0 && reportsIdentityFailure) {
      errors.push('receipt reports a provider identity failure without an identity mismatch');
    }
  }
  const reportsTimeout = receiptErrorCodes.has('DOE_GOVERNED_PROCESS_TIMEOUT');
  if (Boolean(receipt.process?.timedOut) !== reportsTimeout) {
    errors.push('timeout state and error code disagree');
  }
  const reportsAborted = receiptErrorCodes.has('DOE_GOVERNED_PROCESS_ABORTED');
  const hasExtendedLifecycle = receipt.process
    && (own(receipt.process, 'spawned')
      || own(receipt.process, 'aborted')
      || own(receipt.process, 'terminationScope'));
  if (hasExtendedLifecycle) {
    if (typeof receipt.process.spawned !== 'boolean') {
      errors.push('process spawned state is invalid');
    }
    if (typeof receipt.process.aborted !== 'boolean') {
      errors.push('process aborted state is invalid');
    }
    if (Boolean(receipt.process.aborted) !== reportsAborted) {
      errors.push('abort state and error code disagree');
    }
    if (!['process-group', 'child-process'].includes(receipt.process.terminationScope)) {
      errors.push('process termination scope is invalid');
    }
  } else if (reportsAborted) {
    errors.push('legacy process receipt cannot report an unrepresented abort state');
  }
  const reportsOutputLimit = receiptErrorCodes.has('DOE_GOVERNED_PROCESS_OUTPUT_LIMIT');
  if (Boolean(receipt.process?.outputLimitExceeded) !== reportsOutputLimit) {
    errors.push('output-limit state and error code disagree');
  }
  const exitedUncleanly = receipt.process?.exitCode !== 0 || receipt.process?.signal !== null;
  const reportsExitFailure = receiptErrorCodes.has('DOE_GOVERNED_PROCESS_EXIT_FAILED');
  const reportsSpawnFailure = receiptErrorCodes.has('DOE_GOVERNED_PROCESS_SPAWN_FAILED');
  const processWasSpawned = hasExtendedLifecycle ? receipt.process.spawned : true;
  if (processWasSpawned && !reportsSpawnFailure
      && exitedUncleanly !== reportsExitFailure) {
    errors.push('process exit state and error code disagree');
  }
  if (!processWasSpawned && reportsExitFailure) {
    errors.push('unspawned process reports an exit failure');
  }
  const filesystem = receipt.process?.declaration?.filesystem;
  if (filesystem !== undefined) {
    if (!filesystem || typeof filesystem !== 'object' || Array.isArray(filesystem)) {
      errors.push('process filesystem declaration is invalid');
    } else if (!['ambient', 'node-permission-read-only'].includes(filesystem.mode)) {
      errors.push('process filesystem mode is invalid');
    } else if (!Array.isArray(filesystem.readPaths)
        || filesystem.readPaths.some((path) => typeof path !== 'string' || path.length === 0)) {
      errors.push('process filesystem read paths are invalid');
    } else if (new Set(filesystem.readPaths).size !== filesystem.readPaths.length
        || [...filesystem.readPaths].sort().some(
          (path, index) => path !== filesystem.readPaths[index],
        )) {
      errors.push('process filesystem read paths are not canonical');
    } else if (filesystem.mode === 'ambient' && filesystem.readPaths.length !== 0) {
      errors.push('ambient process filesystem declares read paths');
    } else if (filesystem.mode === 'node-permission-read-only') {
      if (filesystem.workerThreads !== 'allowed-for-loader') {
        errors.push('node permission filesystem worker scope is invalid');
      }
      if (filesystem.nativeAddons !== 'allowed-for-provider') {
        errors.push('node permission filesystem addon scope is invalid');
      }
      if (receipt.process?.environment?.keys?.includes('NODE_OPTIONS')) {
        errors.push('node permission filesystem retained NODE_OPTIONS');
      }
      if ((receipt.process?.declaration?.nodeArgs ?? []).some(
        (argument) => /^(--permission|--experimental-permission|--allow-)/.test(argument),
      )) {
        errors.push('node permission filesystem exposes caller-owned permission flags');
      }
    } else if (filesystem.workerThreads !== undefined
        && filesystem.workerThreads !== 'ambient') {
      errors.push('ambient process filesystem worker scope is invalid');
    } else if (filesystem.nativeAddons !== undefined
        && filesystem.nativeAddons !== 'ambient') {
      errors.push('ambient process filesystem addon scope is invalid');
    }
  }
  if (receipt.oracle?.status === 'pass') {
    if (receipt.oracle.actualOutputSha256 !== receipt.oracle.expectedOutputSha256) {
      errors.push('passing oracle has unequal expected and actual output digests');
    }
  } else if (receipt.oracle?.status !== 'fail') {
    errors.push('oracle status is not recognized');
  }
  const hasObservedOracleMismatch = receipt.oracle?.actualOutputSha256 !== null
    && receipt.oracle?.actualOutputSha256 !== receipt.oracle?.expectedOutputSha256;
  const reportsOracleFailure = receiptErrorCodes.has('DOE_GOVERNED_PROCESS_ORACLE_FAILED');
  if (hasObservedOracleMismatch !== reportsOracleFailure) {
    errors.push('oracle mismatch state and error code disagree');
  }
  if (receipt.applicationEvidenceSha256 !== null
      && receipt.applicationEvidenceSha256 !== stableSha256(receipt.applicationEvidence)) {
    errors.push('applicationEvidenceSha256 does not match applicationEvidence');
  }
  if (receipt.programEvidence !== undefined) {
    const programEvidence = receipt.programEvidence;
    if (!programEvidence || typeof programEvidence !== 'object'
        || Array.isArray(programEvidence)) {
      errors.push('programEvidence must be an object');
    } else if (!['not-requested', 'observed', 'missing'].includes(programEvidence.status)) {
      errors.push('programEvidence.status is invalid');
    } else if (!Number.isSafeInteger(programEvidence.checkpointCount)
        || programEvidence.checkpointCount < 0) {
      errors.push('programEvidence.checkpointCount is invalid');
    } else if (programEvidence.status === 'observed') {
      const validation = validateTransparentWebGPUObservation(programEvidence.observation);
      if (!validation.valid) {
        errors.push(...validation.errors.map((error) => `programEvidence: ${error}`));
      }
      if (programEvidence.checkpointCount < 1) {
        errors.push('observed programEvidence has no checkpoints');
      }
      if (programEvidence.observationSha256
          !== programEvidence.observation?.observationSha256) {
        errors.push('programEvidence.observationSha256 does not match the observation');
      }
      if (programEvidence.observation?.providerId !== requested?.id) {
        errors.push('programEvidence providerId does not match the requested provider');
      }
      if (programEvidence.checkpoint !== undefined
          && (!programEvidence.checkpoint
            || typeof programEvidence.checkpoint !== 'object'
            || Array.isArray(programEvidence.checkpoint)
            || Object.keys(programEvidence.checkpoint).length !== 1
            || !NODE_WEBGPU_LOADER_PROGRAM_OBSERVATION_REASONS.includes(
              programEvidence.checkpoint.reason,
            ))) {
        errors.push('programEvidence checkpoint is invalid');
      }
    } else {
      if (programEvidence.checkpointCount !== 0
          || programEvidence.observation !== null
          || programEvidence.observationSha256 !== null) {
        errors.push(`${programEvidence.status} programEvidence contains observation state`);
      }
      if (own(programEvidence, 'checkpoint') && programEvidence.checkpoint !== null) {
        errors.push(`${programEvidence.status} programEvidence contains a checkpoint`);
      }
      const reportsProgramFailure = receiptErrorCodes.has(
        'DOE_GOVERNED_PROCESS_PROGRAM_EVIDENCE_FAILED',
      );
      if (programEvidence.status === 'missing'
          && receipt.status === 'pass'
          && !reportsProgramFailure) {
        errors.push('passing receipt has missing programEvidence without a failure code');
      }
      if (programEvidence.status === 'not-requested' && reportsProgramFailure) {
        errors.push('not-requested programEvidence reports a failure');
      }
    }
  }
  const expectedWorkloadSha256 = stableSha256(receipt.workload);
  if (receipt.replay?.workloadSha256 !== expectedWorkloadSha256) {
    errors.push('replay.workloadSha256 does not match the workload contract');
  }
  const expectedExecutionSha256 = stableSha256(executionIdentity(receipt));
  if (receipt.replay?.executionSha256 !== expectedExecutionSha256) {
    errors.push('replay.executionSha256 does not match the execution contract');
  }
  if (receipt.status === 'pass') {
    if (receipt.errors?.length !== 0) errors.push('passing receipt contains errors');
    if (receipt.process?.exitCode !== 0 || receipt.process?.signal !== null) {
      errors.push('passing receipt did not exit cleanly');
    }
    if (receipt.process?.timedOut
        || receipt.process?.outputLimitExceeded
        || receipt.process?.aborted) {
      errors.push('passing receipt violated a process bound');
    }
    if (receipt.oracle?.status !== 'pass') errors.push('passing receipt has no passing oracle');
    if (!effective) errors.push('passing receipt has no effective provider identity');
  } else if (Array.isArray(receipt.errors) && receipt.errors.length === 0) {
    errors.push('failed receipt contains no errors');
  }
  for (const error of receipt.errors ?? []) {
    if (!NODE_WEBGPU_GOVERNED_PROCESS_ERROR_CODES.includes(error?.code)) {
      errors.push('receipt contains an unrecognized error code');
    }
  }
  return { valid: errors.length === 0, errors };
}

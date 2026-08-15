// Provider-neutral DoeProof process execution for unchanged Node WebGPU apps.

import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { NODE_WEBGPU_LOADER_CONTRACT } from './node-webgpu-loader.js';

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
  'timeoutMs',
  'maxOutputBytes',
]);
const ENVIRONMENT_KEYS = new Set(['mode', 'values']);
const OBSERVATION_KEYS = new Set(['output', 'providerIdentity', 'evidence']);
const loaderPath = fileURLToPath(new URL('./node-webgpu-loader.js', import.meta.url));

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

function normalizeProcess(processOptions) {
  assertPlainObject(processOptions, 'process');
  assertKnownKeys(processOptions, PROCESS_KEYS, 'process');
  const executable = assertNonEmptyString(
    processOptions.executable ?? process.execPath,
    'process.executable',
  );
  const cwd = resolve(assertNonEmptyString(processOptions.cwd ?? process.cwd(), 'process.cwd'));
  const entrypoint = resolve(cwd, assertNonEmptyString(processOptions.entrypoint, 'process.entrypoint'));
  const nodeArgs = assertStringArray(processOptions.nodeArgs ?? [], 'process.nodeArgs');
  const args = assertStringArray(processOptions.args ?? [], 'process.args');
  if (!Number.isSafeInteger(processOptions.timeoutMs) || processOptions.timeoutMs <= 0) {
    throw new TypeError('process.timeoutMs must be a positive safe integer.');
  }
  if (!Number.isSafeInteger(processOptions.maxOutputBytes) || processOptions.maxOutputBytes <= 0) {
    throw new TypeError('process.maxOutputBytes must be a positive safe integer.');
  }
  const environment = normalizeEnvironment(processOptions.environment);
  return {
    executable,
    nodeArgs,
    entrypoint,
    args,
    cwd,
    environment,
    timeoutMs: processOptions.timeoutMs,
    maxOutputBytes: processOptions.maxOutputBytes,
  };
}

function normalizeOptions(options) {
  assertPlainObject(options, 'options');
  for (const key of Object.keys(options)) {
    if (!['provider', 'workload', 'process', 'evaluate', 'checkpoint', 'signal'].includes(key)) {
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
  return {
    provider: normalizeProvider(options.provider),
    workload: normalizeWorkload(options.workload),
    process: normalizeProcess(options.process),
    evaluate: options.evaluate,
    checkpoint: options.checkpoint,
    signal: options.signal,
  };
}

function terminateProcess(child, terminationScope) {
  if (!child?.pid) return;
  if (terminationScope === 'process-group') {
    try {
      process.kill(-child.pid, 'SIGKILL');
      return;
    } catch {
      // Fall through to the direct child when the group is already gone.
    }
  }
  try {
    child.kill('SIGKILL');
  } catch {
    // The child already terminated.
  }
}

function spawnProcess(configuration, provider, abortSignal) {
  return new Promise((resolveProcess) => {
    const argv = [
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
    };
    const terminationScope = process.platform === 'win32' ? 'child-process' : 'process-group';
    if (abortSignal?.aborted) {
      resolveProcess({
        argv,
        environment,
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
        stdio: ['ignore', 'pipe', 'pipe'],
      });
    } catch (error) {
      resolveProcess({
        spawnError: error,
        argv,
        environment,
        spawned: false,
        aborted: false,
        terminationScope,
        durationMs: null,
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
  const child = await spawnProcess(normalized.process, normalized.provider, normalized.signal);
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

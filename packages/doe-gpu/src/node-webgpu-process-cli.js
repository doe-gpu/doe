// Public DoeProof CLI/CI contract over the governed unchanged-process API.

import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { dirname, isAbsolute, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import {
  runGovernedNodeWebGPUProcess,
  validateGovernedNodeWebGPUProcessReceipt,
} from './node-webgpu-process.js';

export const DOE_PROOF_PROCESS_CONTRACT_SCHEMA =
  'doe.governed-node-webgpu-process-contract/v1';
export const DOE_PROOF_PROCESS_ARTIFACT_SCHEMA =
  'doe.governed-node-webgpu-process-cli-artifact/v1';

const SHA256_PATTERN = /^sha256:[a-f0-9]{64}$/;
const CONTRACT_KEYS = new Set([
  'schema',
  'provider',
  'workload',
  'process',
  'evaluator',
  'runtimeFiles',
]);
const PROVIDER_KEYS = new Set(['id', 'module', 'sha256']);
const WORKLOAD_KEYS = new Set([
  'id',
  'version',
  'implementationSha256',
  'input',
  'expectedOutputSha256',
]);
const INPUT_KEYS = new Set(['path', 'sha256']);
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
const ENTRYPOINT_KEYS = new Set(['path', 'sha256']);
const ENVIRONMENT_KEYS = new Set(['mode', 'values']);
const FILESYSTEM_KEYS = new Set(['mode']);
const EVALUATOR_KEYS = new Set(['module', 'sha256', 'export']);
const RUNTIME_FILE_KEYS = new Set(['id', 'path', 'sha256']);

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
  return value;
}

function assertStringArray(value, label) {
  if (!Array.isArray(value) || value.some((item) => typeof item !== 'string')) {
    throw new TypeError(`${label} must be an array of strings.`);
  }
  return [...value];
}

function stableValue(value) {
  if (Array.isArray(value)) return value.map(stableValue);
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.keys(value).sort().map((key) => [key, stableValue(value[key])]),
    );
  }
  return value;
}

function sha256(value) {
  const bytes = typeof value === 'string' ? Buffer.from(value, 'utf8') : value;
  return `sha256:${createHash('sha256').update(bytes).digest('hex')}`;
}

function stableSha256(value) {
  return sha256(JSON.stringify(stableValue(value)));
}

async function sha256File(path) {
  return sha256(await readFile(path));
}

function localPath(base, value, label) {
  assertNonEmptyString(value, label);
  if (value.startsWith('file:')) return fileURLToPath(value);
  return isAbsolute(value) ? value : resolve(base, value);
}

function modulePath(contractPath, value, label) {
  assertNonEmptyString(value, label);
  if (value.startsWith('file:')) return fileURLToPath(value);
  if (isAbsolute(value) || value.startsWith('./') || value.startsWith('../')) {
    return localPath(dirname(contractPath), value, label);
  }
  return createRequire(pathToFileURL(contractPath)).resolve(value);
}

async function verifiedFile(path, expectedSha256, label) {
  assertSha256(expectedSha256, `${label}.sha256`);
  const actualSha256 = await sha256File(path);
  if (actualSha256 !== expectedSha256) {
    throw new Error(`${label} digest mismatch: expected ${expectedSha256}, got ${actualSha256}.`);
  }
  return { path, sha256: actualSha256 };
}

function normalizeEnvironment(value) {
  assertPlainObject(value, 'contract.process.environment');
  assertKnownKeys(value, ENVIRONMENT_KEYS, 'contract.process.environment');
  if (!['inherit', 'sealed'].includes(value.mode)) {
    throw new TypeError('contract.process.environment.mode must be "inherit" or "sealed".');
  }
  const values = value.values ?? {};
  assertPlainObject(values, 'contract.process.environment.values');
  for (const [key, item] of Object.entries(values)) {
    if (!key || (typeof item !== 'string' && item !== null)) {
      throw new TypeError(
        'contract.process.environment.values must map non-empty names to strings or null.',
      );
    }
  }
  return { mode: value.mode, values: { ...values } };
}

function normalizeFilesystem(value) {
  const filesystem = value ?? { mode: 'ambient' };
  assertPlainObject(filesystem, 'contract.process.filesystem');
  assertKnownKeys(filesystem, FILESYSTEM_KEYS, 'contract.process.filesystem');
  if (!['ambient', 'node-permission-read-only'].includes(filesystem.mode)) {
    throw new TypeError(
      'contract.process.filesystem.mode must be "ambient" or "node-permission-read-only".',
    );
  }
  return { mode: filesystem.mode };
}

function normalizeContractDocument(document) {
  assertPlainObject(document, 'contract');
  assertKnownKeys(document, CONTRACT_KEYS, 'contract');
  if (document.schema !== DOE_PROOF_PROCESS_CONTRACT_SCHEMA) {
    throw new TypeError(`contract.schema must be ${DOE_PROOF_PROCESS_CONTRACT_SCHEMA}.`);
  }

  const provider = assertPlainObject(document.provider, 'contract.provider');
  assertKnownKeys(provider, PROVIDER_KEYS, 'contract.provider');
  assertNonEmptyString(provider.id, 'contract.provider.id');
  assertNonEmptyString(provider.module, 'contract.provider.module');
  assertSha256(provider.sha256, 'contract.provider.sha256');

  const workload = assertPlainObject(document.workload, 'contract.workload');
  assertKnownKeys(workload, WORKLOAD_KEYS, 'contract.workload');
  assertNonEmptyString(workload.id, 'contract.workload.id');
  assertNonEmptyString(workload.version, 'contract.workload.version');
  assertSha256(workload.implementationSha256, 'contract.workload.implementationSha256');
  assertSha256(workload.expectedOutputSha256, 'contract.workload.expectedOutputSha256');
  const input = assertPlainObject(workload.input, 'contract.workload.input');
  assertKnownKeys(input, INPUT_KEYS, 'contract.workload.input');
  assertNonEmptyString(input.path, 'contract.workload.input.path');
  assertSha256(input.sha256, 'contract.workload.input.sha256');

  const processDocument = assertPlainObject(document.process, 'contract.process');
  assertKnownKeys(processDocument, PROCESS_KEYS, 'contract.process');
  const entrypoint = assertPlainObject(
    processDocument.entrypoint,
    'contract.process.entrypoint',
  );
  assertKnownKeys(entrypoint, ENTRYPOINT_KEYS, 'contract.process.entrypoint');
  assertNonEmptyString(entrypoint.path, 'contract.process.entrypoint.path');
  assertSha256(entrypoint.sha256, 'contract.process.entrypoint.sha256');
  if (processDocument.executable !== undefined) {
    assertNonEmptyString(processDocument.executable, 'contract.process.executable');
  }
  const nodeArgs = assertStringArray(processDocument.nodeArgs ?? [], 'contract.process.nodeArgs');
  const args = assertStringArray(processDocument.args ?? [], 'contract.process.args');
  if (!Number.isSafeInteger(processDocument.timeoutMs) || processDocument.timeoutMs <= 0) {
    throw new TypeError('contract.process.timeoutMs must be a positive safe integer.');
  }
  if (!Number.isSafeInteger(processDocument.maxOutputBytes)
      || processDocument.maxOutputBytes <= 0) {
    throw new TypeError('contract.process.maxOutputBytes must be a positive safe integer.');
  }

  const evaluator = assertPlainObject(document.evaluator, 'contract.evaluator');
  assertKnownKeys(evaluator, EVALUATOR_KEYS, 'contract.evaluator');
  assertNonEmptyString(evaluator.module, 'contract.evaluator.module');
  assertSha256(evaluator.sha256, 'contract.evaluator.sha256');
  const evaluatorExport = evaluator.export ?? 'evaluate';
  assertNonEmptyString(evaluatorExport, 'contract.evaluator.export');

  const runtimeFiles = document.runtimeFiles ?? [];
  if (!Array.isArray(runtimeFiles)) {
    throw new TypeError('contract.runtimeFiles must be an array.');
  }
  const runtimeFileIds = new Set();
  const normalizedRuntimeFiles = runtimeFiles.map((runtimeFile, index) => {
    const label = `contract.runtimeFiles[${index}]`;
    assertPlainObject(runtimeFile, label);
    assertKnownKeys(runtimeFile, RUNTIME_FILE_KEYS, label);
    assertNonEmptyString(runtimeFile.id, `${label}.id`);
    assertNonEmptyString(runtimeFile.path, `${label}.path`);
    assertSha256(runtimeFile.sha256, `${label}.sha256`);
    if (runtimeFileIds.has(runtimeFile.id)) {
      throw new TypeError(`contract.runtimeFiles contains duplicate id "${runtimeFile.id}".`);
    }
    runtimeFileIds.add(runtimeFile.id);
    return { ...runtimeFile };
  });

  return {
    provider: { ...provider },
    workload: {
      id: workload.id,
      version: workload.version,
      implementationSha256: workload.implementationSha256,
      input: { ...input },
      expectedOutputSha256: workload.expectedOutputSha256,
    },
    process: {
      executable: processDocument.executable,
      nodeArgs,
      entrypoint: { ...entrypoint },
      args,
      cwd: processDocument.cwd ?? '.',
      environment: normalizeEnvironment(processDocument.environment),
      filesystem: normalizeFilesystem(processDocument.filesystem),
      timeoutMs: processDocument.timeoutMs,
      maxOutputBytes: processDocument.maxOutputBytes,
    },
    evaluator: {
      module: evaluator.module,
      sha256: evaluator.sha256,
      export: evaluatorExport,
    },
    runtimeFiles: normalizedRuntimeFiles,
  };
}

export async function loadDoeProofProcessContract(contractFile, options = {}) {
  const contractPath = resolve(assertNonEmptyString(contractFile, 'contract path'));
  const contractBytes = await readFile(contractPath);
  const document = normalizeContractDocument(JSON.parse(contractBytes.toString('utf8')));
  const contractDir = dirname(contractPath);
  const providerPath = modulePath(
    contractPath,
    document.provider.module,
    'contract.provider.module',
  );
  const inputPath = localPath(
    contractDir,
    document.workload.input.path,
    'contract.workload.input.path',
  );
  const entrypointPath = localPath(
    contractDir,
    document.process.entrypoint.path,
    'contract.process.entrypoint.path',
  );
  const evaluatorPath = modulePath(
    contractPath,
    document.evaluator.module,
    'contract.evaluator.module',
  );
  const runtimeFiles = await Promise.all(document.runtimeFiles.map(async (runtimeFile) => ({
    id: runtimeFile.id,
    ...await verifiedFile(
      localPath(contractDir, runtimeFile.path, `contract.runtimeFiles.${runtimeFile.id}.path`),
      runtimeFile.sha256,
      `runtime file "${runtimeFile.id}"`,
    ),
  })));
  const dependencies = {
    provider: await verifiedFile(providerPath, document.provider.sha256, 'provider entrypoint'),
    input: await verifiedFile(inputPath, document.workload.input.sha256, 'workload input'),
    entrypoint: await verifiedFile(
      entrypointPath,
      document.process.entrypoint.sha256,
      'process entrypoint',
    ),
    evaluator: await verifiedFile(
      evaluatorPath,
      document.evaluator.sha256,
      'evaluator module',
    ),
    runtimeFiles,
  };
  let evaluator = null;
  if (options.importEvaluator !== false) {
    const evaluatorNamespace = await import(
      `${pathToFileURL(evaluatorPath).href}?doeProofSha256=${document.evaluator.sha256.slice(7)}`
    );
    evaluator = evaluatorNamespace[document.evaluator.export];
    if (typeof evaluator !== 'function') {
      throw new TypeError(
        `evaluator module does not export function "${document.evaluator.export}".`,
      );
    }
  }
  return {
    contractPath,
    contractSha256: sha256(contractBytes),
    document,
    dependencies,
    input: await readFile(inputPath),
    evaluator,
    processOptions: {
      ...(document.process.executable === undefined
        ? {}
        : { executable: document.process.executable }),
      nodeArgs: document.process.nodeArgs,
      entrypoint: entrypointPath,
      args: document.process.args,
      cwd: localPath(contractDir, document.process.cwd, 'contract.process.cwd'),
      environment: document.process.environment,
      filesystem: {
        mode: document.process.filesystem.mode,
        readPaths: document.process.filesystem.mode === 'node-permission-read-only'
          ? [inputPath, ...runtimeFiles.map((runtimeFile) => runtimeFile.path)]
          : [],
      },
      timeoutMs: document.process.timeoutMs,
      maxOutputBytes: document.process.maxOutputBytes,
    },
    provider: { id: document.provider.id, module: providerPath },
  };
}

function artifactSummary(artifact, validation = null) {
  return {
    schema: artifact?.schema ?? null,
    status: artifact?.status ?? null,
    valid: validation?.valid ?? null,
    validationErrors: validation?.errors ?? [],
    contractSha256: artifact?.contract?.sha256 ?? null,
    dependencies: artifact?.dependencies ?? null,
    workload: artifact?.receipt?.workload ?? null,
    provider: artifact?.receipt?.provider ?? null,
    oracle: artifact?.receipt?.oracle ?? null,
    replay: artifact?.receipt?.replay ?? null,
    process: artifact?.receipt?.process ?? null,
  };
}

export async function runDoeProofProcessContract(contractFile, options = {}) {
  const loaded = await loadDoeProofProcessContract(contractFile);
  const result = await runGovernedNodeWebGPUProcess({
    provider: loaded.provider,
    workload: {
      id: loaded.document.workload.id,
      version: loaded.document.workload.version,
      implementationSha256: loaded.document.workload.implementationSha256,
      input: loaded.input,
      expectedOutputSha256: loaded.document.workload.expectedOutputSha256,
    },
    process: loaded.processOptions,
    signal: options.signal,
    evaluate: (processResult) => loaded.evaluator(processResult, {
      contract: loaded.document,
      contractPath: loaded.contractPath,
    }),
  });
  const artifact = {
    schema: DOE_PROOF_PROCESS_ARTIFACT_SCHEMA,
    status: result.ok ? 'pass' : 'failed',
    command: options.command ?? 'run',
    contract: {
      sourcePath: loaded.contractPath,
      sha256: loaded.contractSha256,
    },
    dependencies: loaded.dependencies,
    receipt: result.receipt,
  };
  if (options.replayOf) artifact.replayOf = options.replayOf;
  return { artifact, result, loaded };
}

async function readArtifact(artifactFile) {
  const artifactPath = resolve(assertNonEmptyString(artifactFile, 'artifact path'));
  const bytes = await readFile(artifactPath);
  return {
    artifactPath,
    artifactSha256: sha256(bytes),
    artifact: JSON.parse(bytes.toString('utf8')),
  };
}

export async function validateDoeProofProcessArtifact(artifact, options = {}) {
  const errors = [];
  if (!artifact || typeof artifact !== 'object' || Array.isArray(artifact)) {
    return { valid: false, errors: ['artifact must be an object'] };
  }
  if (artifact.schema !== DOE_PROOF_PROCESS_ARTIFACT_SCHEMA) {
    errors.push('artifact schema is not recognized');
  }
  if (!['pass', 'failed'].includes(artifact.status)) errors.push('artifact status is invalid');
  const receiptValidation = validateGovernedNodeWebGPUProcessReceipt(artifact.receipt);
  errors.push(...receiptValidation.errors.map((error) => `receipt: ${error}`));
  const expectedStatus = artifact.receipt?.status === 'pass' ? 'pass' : 'failed';
  if (artifact.status !== expectedStatus) errors.push('artifact and receipt status disagree');

  let loaded = null;
  try {
    const contractPath = options.contractPath
      ? resolve(options.contractPath)
      : artifact.contract?.sourcePath;
    loaded = await loadDoeProofProcessContract(contractPath, { importEvaluator: false });
    if (artifact.contract?.sha256 !== loaded.contractSha256) {
      errors.push('contract digest does not match the bound contract');
    }
    if (stableSha256(artifact.dependencies) !== stableSha256(loaded.dependencies)) {
      errors.push('dependency identities do not match the bound contract');
    }
    const expectedWorkload = {
      id: loaded.document.workload.id,
      version: loaded.document.workload.version,
      implementationSha256: loaded.document.workload.implementationSha256,
      inputSha256: loaded.dependencies.input.sha256,
      inputBytes: loaded.input.byteLength,
      expectedOutputSha256: loaded.document.workload.expectedOutputSha256,
    };
    if (stableSha256(artifact.receipt?.workload) !== stableSha256(expectedWorkload)) {
      errors.push('receipt workload does not match the bound contract');
    }
    if (artifact.receipt?.provider?.requested?.id !== loaded.provider.id
        || artifact.receipt?.provider?.requested?.module !== loaded.provider.module) {
      errors.push('receipt provider does not match the bound contract');
    }
  } catch (error) {
    errors.push(`contract verification failed: ${error instanceof Error ? error.message : String(error)}`);
  }
  return { valid: errors.length === 0, errors, loaded };
}

export async function validateDoeProofProcessArtifactFile(artifactFile, options = {}) {
  const read = await readArtifact(artifactFile);
  const validation = await validateDoeProofProcessArtifact(read.artifact, options);
  return { ...read, ...validation };
}

export async function compareDoeProofProcessArtifacts(leftFile, rightFile, options = {}) {
  const left = await validateDoeProofProcessArtifactFile(leftFile, {
    contractPath: options.leftContractPath,
  });
  const right = await validateDoeProofProcessArtifactFile(rightFile, {
    contractPath: options.rightContractPath,
  });
  const sameWorkload = left.artifact?.receipt?.replay?.workloadSha256
    === right.artifact?.receipt?.replay?.workloadSha256;
  const sameOutput = left.artifact?.receipt?.oracle?.actualOutputSha256
    === right.artifact?.receipt?.oracle?.actualOutputSha256;
  const bothPass = left.valid && right.valid
    && left.artifact?.status === 'pass'
    && right.artifact?.status === 'pass';
  return {
    schema: 'doe.governed-node-webgpu-process-comparison/v1',
    comparable: bothPass && sameWorkload && sameOutput,
    bothPass,
    sameWorkload,
    sameOutput,
    performanceInterpretable: false,
    runtimeOwnershipCredit: false,
    left: {
      path: left.artifactPath,
      sha256: left.artifactSha256,
      valid: left.valid,
      errors: left.errors,
      provider: left.artifact?.receipt?.provider ?? null,
      replay: left.artifact?.receipt?.replay ?? null,
    },
    right: {
      path: right.artifactPath,
      sha256: right.artifactSha256,
      valid: right.valid,
      errors: right.errors,
      provider: right.artifact?.receipt?.provider ?? null,
      replay: right.artifact?.receipt?.replay ?? null,
    },
  };
}

export async function replayDoeProofProcessArtifact(artifactFile, options = {}) {
  const original = await validateDoeProofProcessArtifactFile(artifactFile, {
    contractPath: options.contractPath,
  });
  if (!original.valid) {
    throw new Error(`original artifact is invalid: ${original.errors.join('; ')}`);
  }
  const contractPath = options.contractPath ?? original.artifact.contract.sourcePath;
  const run = await runDoeProofProcessContract(contractPath, {
    command: 'replay',
    signal: options.signal,
    replayOf: {
      sourcePath: original.artifactPath,
      sha256: original.artifactSha256,
      workloadSha256: original.artifact.receipt.replay.workloadSha256,
      executionSha256: original.artifact.receipt.replay.executionSha256,
    },
  });
  const workloadMatches = run.artifact.receipt?.replay?.workloadSha256
    === original.artifact.receipt?.replay?.workloadSha256;
  const executionMatches = run.artifact.receipt?.replay?.executionSha256
    === original.artifact.receipt?.replay?.executionSha256;
  run.artifact.replay = {
    status: run.result.ok && workloadMatches && executionMatches ? 'pass' : 'failed',
    workloadMatches,
    executionMatches,
  };
  return run;
}

export async function writeDoeProofProcessArtifact(outputFile, artifact) {
  const outputPath = resolve(assertNonEmptyString(outputFile, 'output path'));
  await writeFile(outputPath, `${JSON.stringify(artifact, null, 2)}\n`, {
    encoding: 'utf8',
    flag: 'wx',
  });
  return outputPath;
}

function parseFlags(values, allowed) {
  const positional = [];
  const flags = {};
  for (let index = 0; index < values.length; index += 1) {
    const value = values[index];
    if (!value.startsWith('--')) {
      positional.push(value);
      continue;
    }
    if (!allowed.has(value)) throw new Error(`unknown option ${value}`);
    const next = values[index + 1];
    if (!next || next.startsWith('--')) throw new Error(`${value} requires a value`);
    flags[value.slice(2)] = next;
    index += 1;
  }
  return { positional, flags };
}

function usage() {
  return [
    'Usage:',
    '  doe-proof-node run CONTRACT --out ARTIFACT',
    '  doe-proof-node verify ARTIFACT [--contract CONTRACT]',
    '  doe-proof-node inspect ARTIFACT [--contract CONTRACT]',
    '  doe-proof-node compare LEFT RIGHT [--left-contract CONTRACT] [--right-contract CONTRACT]',
    '  doe-proof-node replay ARTIFACT [--contract CONTRACT] --out ARTIFACT',
  ].join('\n');
}

export async function runDoeProofProcessCli(argv, streams = {}) {
  const stdout = streams.stdout ?? process.stdout;
  const stderr = streams.stderr ?? process.stderr;
  const [command, ...values] = argv;
  try {
    if (!command || command === '--help' || command === '-h') {
      stdout.write(`${usage()}\n`);
      return 0;
    }
    if (command === 'run') {
      const parsed = parseFlags(values, new Set(['--out']));
      if (parsed.positional.length !== 1 || !parsed.flags.out) throw new Error(usage());
      const run = await runDoeProofProcessContract(parsed.positional[0], {
        signal: streams.signal,
      });
      const outputPath = await writeDoeProofProcessArtifact(parsed.flags.out, run.artifact);
      stdout.write(`${JSON.stringify({ outputPath, ...artifactSummary(run.artifact) }, null, 2)}\n`);
      return run.result.ok ? 0 : 1;
    }
    if (command === 'verify' || command === 'inspect') {
      const parsed = parseFlags(values, new Set(['--contract']));
      if (parsed.positional.length !== 1) throw new Error(usage());
      const validation = await validateDoeProofProcessArtifactFile(parsed.positional[0], {
        contractPath: parsed.flags.contract,
      });
      stdout.write(`${JSON.stringify({
        artifactPath: validation.artifactPath,
        artifactSha256: validation.artifactSha256,
        ...artifactSummary(validation.artifact, validation),
      }, null, 2)}\n`);
      return validation.valid ? 0 : 1;
    }
    if (command === 'compare') {
      const parsed = parseFlags(values, new Set(['--left-contract', '--right-contract']));
      if (parsed.positional.length !== 2) throw new Error(usage());
      const comparison = await compareDoeProofProcessArtifacts(
        parsed.positional[0],
        parsed.positional[1],
        {
          leftContractPath: parsed.flags['left-contract'],
          rightContractPath: parsed.flags['right-contract'],
        },
      );
      stdout.write(`${JSON.stringify(comparison, null, 2)}\n`);
      return comparison.comparable ? 0 : 1;
    }
    if (command === 'replay') {
      const parsed = parseFlags(values, new Set(['--contract', '--out']));
      if (parsed.positional.length !== 1 || !parsed.flags.out) throw new Error(usage());
      const replay = await replayDoeProofProcessArtifact(parsed.positional[0], {
        contractPath: parsed.flags.contract,
        signal: streams.signal,
      });
      const outputPath = await writeDoeProofProcessArtifact(parsed.flags.out, replay.artifact);
      stdout.write(`${JSON.stringify({ outputPath, ...artifactSummary(replay.artifact) }, null, 2)}\n`);
      return replay.artifact.replay.status === 'pass' ? 0 : 1;
    }
    throw new Error(`unknown command "${command}"\n${usage()}`);
  } catch (error) {
    stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    return 1;
  }
}

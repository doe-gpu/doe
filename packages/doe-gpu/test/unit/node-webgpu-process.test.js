import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { dirname, resolve } from 'node:path';
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import {
  runGovernedNodeWebGPUProcess,
  validateGovernedNodeWebGPUProcessReceipt,
} from '../../src/node-webgpu-process.js';

const here = dirname(fileURLToPath(import.meta.url));
const entrypoint = fileURLToPath(new URL('../fixtures/governed-process-app.mjs', import.meta.url));
const providerModule = new URL('../fixtures/provider-v1.js', import.meta.url).href;
const observedProviderModule = new URL('../fixtures/provider-observed.js', import.meta.url).href;
const output = new Uint8Array([2, 4, 6, 8]);
const digest = (value) => `sha256:${createHash('sha256').update(value).digest('hex')}`;

async function waitForFile(path) {
  for (let attempt = 0; attempt < 100 && !existsSync(path); attempt += 1) {
    await new Promise((resolveWait) => setTimeout(resolveWait, 10));
  }
  assert.equal(existsSync(path), true, `fixture did not create ${path}`);
}

async function assertProcessStopped(pid, message) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    try {
      process.kill(pid, 0);
      await new Promise((resolveWait) => setTimeout(resolveWait, 10));
    } catch (error) {
      if (error?.code === 'ESRCH') return;
      throw error;
    }
  }
  assert.fail(message);
}

function configuration(overrides = {}) {
  return {
    provider: { id: 'fixture-provider', module: providerModule },
    workload: {
      id: 'governed-process-fixture',
      version: '1',
      implementationSha256: digest('governed process fixture v1'),
      input: new Uint8Array([1, 2, 3, 4]),
      expectedOutputSha256: digest(output),
    },
    process: {
      entrypoint,
      cwd: here,
      environment: {
        mode: 'sealed',
        values: {
          DOE_TEST_PROCESS_OUTPUT: JSON.stringify([...output]),
          DOE_TEST_ENVIRONMENT_MARKER: 'sealed-value',
        },
      },
      timeoutMs: 5_000,
      maxOutputBytes: 16_384,
    },
    evaluate({ stdout }) {
      const result = JSON.parse(Buffer.from(stdout).toString('utf8'));
      return {
        output: new Uint8Array(result.output),
        providerIdentity: result.providerIdentity,
        evidence: result.evidence,
      };
    },
    ...overrides,
  };
}

const checkpoints = [];
const first = await runGovernedNodeWebGPUProcess({
  ...configuration(),
  checkpoint: (receipt) => checkpoints.push(receipt),
});
assert.equal(first.ok, true, JSON.stringify(first.errors));
assert.equal(first.receipt.status, 'pass');
assert.equal(first.receipt.provider.effective.providerId, 'fixture-provider');
assert.equal(first.receipt.oracle.status, 'pass');
assert.equal(first.receipt.applicationEvidence.environmentMarker, 'sealed-value');
assert.ok(first.receipt.process.environment.keys.includes('DOE_NODE_WEBGPU_PROVIDER_ID'));
assert.ok(first.receipt.process.environment.keys.includes('DOE_NODE_WEBGPU_PROVIDER_MODULE'));
assert.equal(first.receipt.process.environment.values, undefined);
assert.ok(!JSON.stringify(first.receipt.process.environment).includes('sealed-value'));
assert.deepEqual(validateGovernedNodeWebGPUProcessReceipt(first.receipt), {
  valid: true,
  errors: [],
});
assert.equal(checkpoints.length, 1);
assert.equal(checkpoints[0].checkpoint, 'process-complete');

const second = await runGovernedNodeWebGPUProcess(configuration());
assert.equal(second.ok, true);
assert.equal(second.receipt.replay.workloadSha256, first.receipt.replay.workloadSha256);
assert.equal(second.receipt.replay.executionSha256, first.receipt.replay.executionSha256);

const observedConfiguration = configuration({
  provider: { id: 'observed-fixture-provider', module: observedProviderModule },
  observeProgram: { metadata: { application: 'governed-process-unit' } },
  process: {
    ...configuration().process,
    environment: {
      mode: 'sealed',
      values: { DOE_TEST_PROCESS_MODE: 'observed-compute' },
    },
  },
});
const observedFirst = await runGovernedNodeWebGPUProcess(observedConfiguration);
assert.equal(observedFirst.ok, true, JSON.stringify(observedFirst.errors));
assert.equal(observedFirst.receipt.programEvidence.status, 'observed');
assert.ok(observedFirst.receipt.programEvidence.checkpointCount >= 1);
assert.equal(observedFirst.receipt.programEvidence.checkpoint.reason, 'process-before-exit');
assert.equal(
  observedFirst.receipt.programEvidence.observation.summary.shaderModuleCount,
  1,
);
assert.equal(observedFirst.receipt.programEvidence.observation.summary.dispatchCount, 1);
assert.equal(observedFirst.receipt.programEvidence.observation.summary.submissionCount, 1);
assert.equal(observedFirst.receipt.programEvidence.observation.summary.readbackCount, 1);
assert.equal(observedFirst.programObservation.observationSha256,
  observedFirst.receipt.programEvidence.observationSha256);
assert.ok(observedFirst.receipt.process.environment.keys.includes(
  'DOE_NODE_WEBGPU_OBSERVE_PROGRAM',
));
assert.equal(validateGovernedNodeWebGPUProcessReceipt(observedFirst.receipt).valid, true);
const observedSecond = await runGovernedNodeWebGPUProcess(observedConfiguration);
assert.equal(observedSecond.ok, true, JSON.stringify(observedSecond.errors));
assert.equal(
  observedSecond.receipt.programEvidence.observationSha256,
  observedFirst.receipt.programEvidence.observationSha256,
);
assert.equal(
  observedSecond.receipt.replay.executionSha256,
  observedFirst.receipt.replay.executionSha256,
);
assert.notEqual(
  observedFirst.receipt.replay.executionSha256,
  first.receipt.replay.executionSha256,
);

const observedFailure = await runGovernedNodeWebGPUProcess(configuration({
  provider: { id: 'observed-fixture-provider', module: observedProviderModule },
  observeProgram: { metadata: { application: 'governed-process-failure-unit' } },
  process: {
    ...configuration().process,
    environment: {
      mode: 'sealed',
      values: { DOE_TEST_PROCESS_MODE: 'observed-failure' },
    },
  },
}));
assert.equal(observedFailure.ok, false);
assert.ok(observedFailure.errors.some(
  (error) => error.code === 'DOE_GOVERNED_PROCESS_EXIT_FAILED',
));
assert.equal(observedFailure.receipt.programEvidence.status, 'observed');
assert.equal(
  observedFailure.receipt.programEvidence.checkpoint.reason,
  'process-uncaught-exception',
);
assert.equal(
  observedFailure.receipt.programEvidence.observation.summary.compilationInfoCount,
  1,
);
assert.equal(
  observedFailure.receipt.programEvidence.observation.compilationInfos[0].messages[0].message,
  'observed fixture warning',
);
assert.equal(validateGovernedNodeWebGPUProcessReceipt(observedFailure.receipt).valid, true);

const tamperedProgramEvidence = structuredClone(observedFirst.receipt);
tamperedProgramEvidence.programEvidence.observation.summary.dispatchCount += 1;
assert.equal(validateGovernedNodeWebGPUProcessReceipt(tamperedProgramEvidence).valid, false);
const tamperedCheckpoint = structuredClone(observedFirst.receipt);
tamperedCheckpoint.programEvidence.checkpoint.reason = 'invented-reason';
assert.equal(validateGovernedNodeWebGPUProcessReceipt(tamperedCheckpoint).valid, false);

const permissionScratch = mkdtempSync(resolve(tmpdir(), 'doe-proof-permission-'));
try {
  const runtimeFilePath = resolve(permissionScratch, 'runtime-data.txt');
  const packageManifestPath = resolve(here, '../../package.json');
  writeFileSync(runtimeFilePath, 'declared-runtime-data');
  const permissionProcess = {
    ...configuration().process,
    environment: {
      mode: 'sealed',
      values: {
        DOE_TEST_PROCESS_MODE: 'read-file',
        DOE_TEST_PROCESS_OUTPUT: JSON.stringify([...output]),
        DOE_TEST_RUNTIME_FILE: runtimeFilePath,
        NODE_OPTIONS: '--allow-fs-read=*',
      },
    },
    filesystem: {
      mode: 'node-permission-read-only',
      readPaths: [packageManifestPath, runtimeFilePath],
    },
  };
  const permissionPass = await runGovernedNodeWebGPUProcess(configuration({
    process: permissionProcess,
  }));
  assert.equal(permissionPass.ok, true, JSON.stringify(permissionPass.errors));
  assert.equal(permissionPass.receipt.applicationEvidence.runtimeFile, 'declared-runtime-data');
  assert.equal(
    permissionPass.receipt.process.declaration.filesystem.mode,
    'node-permission-read-only',
  );
  assert.ok(permissionPass.receipt.process.declaration.filesystem.readPaths.includes(
    runtimeFilePath,
  ));
  const physicalRuntimeFilePath = realpathSync.native(runtimeFilePath);
  assert.ok(permissionPass.receipt.process.declaration.filesystem.readPaths.includes(
    physicalRuntimeFilePath,
  ));
  assert.equal(permissionPass.receipt.process.environment.keys.includes('NODE_OPTIONS'), false);
  assert.equal(validateGovernedNodeWebGPUProcessReceipt(permissionPass.receipt).valid, true);

  const permissionDenied = await runGovernedNodeWebGPUProcess(configuration({
    process: {
      ...permissionProcess,
      filesystem: {
        mode: 'node-permission-read-only',
        readPaths: [packageManifestPath],
      },
    },
  }));
  assert.equal(permissionDenied.ok, false);
  assert.ok(permissionDenied.errors.some(
    (error) => error.code === 'DOE_GOVERNED_PROCESS_EXIT_FAILED',
  ));
  assert.match(Buffer.from(permissionDenied.stderr).toString('utf8'), /permission|access/i);
  assert.equal(validateGovernedNodeWebGPUProcessReceipt(permissionDenied.receipt).valid, true);

  const permissionOverride = await runGovernedNodeWebGPUProcess(configuration({
    process: {
      ...permissionProcess,
      nodeArgs: ['--allow-fs-read=*'],
    },
  }));
  assert.equal(permissionOverride.ok, false);
  assert.equal(permissionOverride.receipt, null);
  assert.equal(
    permissionOverride.errors[0].code,
    'DOE_GOVERNED_PROCESS_INVALID_CONFIGURATION',
  );

  const relativePermissionProvider = await runGovernedNodeWebGPUProcess(configuration({
    provider: { id: 'fixture-provider', module: 'provider-v1' },
    process: permissionProcess,
  }));
  assert.equal(relativePermissionProvider.ok, false);
  assert.equal(relativePermissionProvider.receipt, null);
  assert.equal(
    relativePermissionProvider.errors[0].code,
    'DOE_GOVERNED_PROCESS_INVALID_CONFIGURATION',
  );
} finally {
  rmSync(permissionScratch, { recursive: true, force: true });
}

const evidenceVariant = await runGovernedNodeWebGPUProcess(configuration({
  evaluate({ stdout }) {
    const result = JSON.parse(Buffer.from(stdout).toString('utf8'));
    return {
      output: new Uint8Array(result.output),
      providerIdentity: result.providerIdentity,
      evidence: { ...result.evidence, diagnosticSample: 17 },
    };
  },
}));
assert.equal(evidenceVariant.ok, true);
assert.equal(
  evidenceVariant.receipt.replay.executionSha256,
  first.receipt.replay.executionSha256,
  'semantic replay identity must exclude diagnostic evidence',
);
assert.notEqual(
  evidenceVariant.receipt.applicationEvidenceSha256,
  first.receipt.applicationEvidenceSha256,
);

const alternate = await runGovernedNodeWebGPUProcess(configuration({
  provider: { id: 'alternate-provider', module: providerModule },
}));
assert.equal(alternate.ok, true);
assert.equal(alternate.receipt.replay.workloadSha256, first.receipt.replay.workloadSha256);
assert.notEqual(alternate.receipt.replay.executionSha256, first.receipt.replay.executionSha256);

const oracleFailure = await runGovernedNodeWebGPUProcess(configuration({
  workload: {
    ...configuration().workload,
    expectedOutputSha256: digest(new Uint8Array([9])),
  },
}));
assert.equal(oracleFailure.ok, false);
assert.equal(oracleFailure.errors[0].code, 'DOE_GOVERNED_PROCESS_ORACLE_FAILED');
assert.equal(validateGovernedNodeWebGPUProcessReceipt(oracleFailure.receipt).valid, true);

const identityFailure = await runGovernedNodeWebGPUProcess(configuration({
  evaluate({ stdout }) {
    const result = JSON.parse(Buffer.from(stdout).toString('utf8'));
    return {
      output: new Uint8Array(result.output),
      providerIdentity: { ...result.providerIdentity, providerId: 'undeclared-provider' },
      evidence: result.evidence,
    };
  },
}));
assert.equal(identityFailure.ok, false);
assert.equal(identityFailure.errors[0].code, 'DOE_GOVERNED_PROCESS_PROVIDER_IDENTITY_FAILED');
assert.equal(validateGovernedNodeWebGPUProcessReceipt(identityFailure.receipt).valid, true);

const timeout = await runGovernedNodeWebGPUProcess(configuration({
  process: {
    ...configuration().process,
    environment: { mode: 'sealed', values: { DOE_TEST_PROCESS_MODE: 'hang' } },
    timeoutMs: 100,
  },
}));
assert.equal(timeout.ok, false);
assert.ok(timeout.errors.some((error) => error.code === 'DOE_GOVERNED_PROCESS_TIMEOUT'));
assert.equal(validateGovernedNodeWebGPUProcessReceipt(timeout.receipt).valid, true);

const preAbortedController = new AbortController();
preAbortedController.abort();
const preAborted = await runGovernedNodeWebGPUProcess(configuration({
  signal: preAbortedController.signal,
}));
assert.equal(preAborted.ok, false);
assert.equal(preAborted.receipt.process.spawned, false);
assert.equal(preAborted.receipt.process.aborted, true);
assert.ok(preAborted.errors.some((error) => error.code === 'DOE_GOVERNED_PROCESS_ABORTED'));
assert.equal(validateGovernedNodeWebGPUProcessReceipt(preAborted.receipt).valid, true);

const observedPreAbortedController = new AbortController();
observedPreAbortedController.abort();
const observedPreAborted = await runGovernedNodeWebGPUProcess(configuration({
  observeProgram: true,
  signal: observedPreAbortedController.signal,
}));
assert.equal(observedPreAborted.ok, false);
assert.equal(observedPreAborted.receipt.programEvidence.status, 'missing');
assert.equal(observedPreAborted.receipt.programEvidence.checkpointCount, 0);
assert.equal(validateGovernedNodeWebGPUProcessReceipt(observedPreAborted.receipt).valid, true);

const activeAbortController = new AbortController();
const activeAbortPromise = runGovernedNodeWebGPUProcess(configuration({
  signal: activeAbortController.signal,
  process: {
    ...configuration().process,
    environment: { mode: 'sealed', values: { DOE_TEST_PROCESS_MODE: 'hang' } },
  },
}));
setTimeout(() => activeAbortController.abort(), 100);
const activeAbort = await activeAbortPromise;
assert.equal(activeAbort.ok, false);
assert.equal(activeAbort.receipt.process.spawned, true);
assert.equal(activeAbort.receipt.process.aborted, true);
assert.ok(activeAbort.errors.some((error) => error.code === 'DOE_GOVERNED_PROCESS_ABORTED'));
assert.equal(validateGovernedNodeWebGPUProcessReceipt(activeAbort.receipt).valid, true);

if (process.platform !== 'win32') {
  const processTreeScratch = mkdtempSync(resolve(tmpdir(), 'doe-proof-tree-'));
  const childPidPath = resolve(processTreeScratch, 'child.pid');
  const processTreeController = new AbortController();
  try {
    const processTreePromise = runGovernedNodeWebGPUProcess(configuration({
      signal: processTreeController.signal,
      process: {
        ...configuration().process,
        environment: {
          mode: 'sealed',
          values: {
            DOE_TEST_PROCESS_MODE: 'spawn-child',
            DOE_TEST_CHILD_PID_PATH: childPidPath,
          },
        },
      },
    }));
    await waitForFile(childPidPath);
    const descendantPid = Number(readFileSync(childPidPath, 'utf8'));
    processTreeController.abort();
    const processTreeAbort = await processTreePromise;
    assert.equal(processTreeAbort.receipt.process.terminationScope, 'process-group');
    await assertProcessStopped(descendantPid, 'process-group cancellation left a descendant alive');
  } finally {
    rmSync(processTreeScratch, { recursive: true, force: true });
  }

  for (const failureCase of [
    {
      mode: 'spawn-child',
      timeoutMs: 1_000,
      maxOutputBytes: 16_384,
      receiptField: 'timedOut',
      message: 'timeout left a descendant alive',
    },
    {
      mode: 'spawn-child-loud',
      timeoutMs: 5_000,
      maxOutputBytes: 1_024,
      receiptField: 'outputLimitExceeded',
      message: 'output-limit termination left a descendant alive',
    },
  ]) {
    const scratch = mkdtempSync(resolve(tmpdir(), 'doe-proof-tree-bound-'));
    const descendantPidPath = resolve(scratch, 'child.pid');
    try {
      const boundedProcessPromise = runGovernedNodeWebGPUProcess(configuration({
        process: {
          ...configuration().process,
          environment: {
            mode: 'sealed',
            values: {
              DOE_TEST_PROCESS_MODE: failureCase.mode,
              DOE_TEST_CHILD_PID_PATH: descendantPidPath,
            },
          },
          timeoutMs: failureCase.timeoutMs,
          maxOutputBytes: failureCase.maxOutputBytes,
        },
      }));
      await waitForFile(descendantPidPath);
      const descendantPid = Number(readFileSync(descendantPidPath, 'utf8'));
      const boundedProcess = await boundedProcessPromise;
      assert.equal(boundedProcess.ok, false);
      assert.equal(boundedProcess.receipt.process[failureCase.receiptField], true);
      assert.equal(boundedProcess.receipt.process.terminationScope, 'process-group');
      assert.equal(validateGovernedNodeWebGPUProcessReceipt(boundedProcess.receipt).valid, true);
      await assertProcessStopped(descendantPid, failureCase.message);
    } finally {
      rmSync(scratch, { recursive: true, force: true });
    }
  }
}

const outputLimit = await runGovernedNodeWebGPUProcess(configuration({
  process: {
    ...configuration().process,
    environment: { mode: 'sealed', values: { DOE_TEST_PROCESS_MODE: 'loud' } },
    maxOutputBytes: 1_024,
  },
}));
assert.equal(outputLimit.ok, false);
assert.ok(outputLimit.errors.some((error) => error.code === 'DOE_GOVERNED_PROCESS_OUTPUT_LIMIT'));
assert.equal(validateGovernedNodeWebGPUProcessReceipt(outputLimit.receipt).valid, true);

const invalid = await runGovernedNodeWebGPUProcess(configuration({
  provider: { id: '', module: providerModule },
}));
assert.equal(invalid.ok, false);
assert.equal(invalid.receipt, null);
assert.equal(invalid.errors[0].code, 'DOE_GOVERNED_PROCESS_INVALID_CONFIGURATION');

const invalidObservationMetadata = await runGovernedNodeWebGPUProcess(configuration({
  observeProgram: { metadata: [] },
}));
assert.equal(invalidObservationMetadata.ok, false);
assert.equal(invalidObservationMetadata.receipt, null);
assert.equal(
  invalidObservationMetadata.errors[0].code,
  'DOE_GOVERNED_PROCESS_INVALID_CONFIGURATION',
);

const tampered = structuredClone(first.receipt);
tampered.provider.effective.providerId = 'tampered';
const tamperedValidation = validateGovernedNodeWebGPUProcessReceipt(tampered);
assert.equal(tamperedValidation.valid, false);
assert.ok(tamperedValidation.errors.includes(
  'effective provider id does not match the declared provider',
));

const noncanonicalFilesystem = structuredClone(first.receipt);
noncanonicalFilesystem.process.declaration.filesystem = {
  mode: 'node-permission-read-only',
  readPaths: ['/z', '/a'],
  workerThreads: 'allowed-for-loader',
  nativeAddons: 'allowed-for-provider',
};
assert.equal(
  validateGovernedNodeWebGPUProcessReceipt(noncanonicalFilesystem).valid,
  false,
);

console.log('node-webgpu governed process contracts: ok');

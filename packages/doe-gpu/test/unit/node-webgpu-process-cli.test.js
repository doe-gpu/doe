import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, resolve } from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {
  DOE_PROOF_PROCESS_ARTIFACT_SCHEMA,
  DOE_PROOF_PROCESS_CONTRACT_SCHEMA,
  validateDoeProofProcessArtifactFile,
} from '../../src/node-webgpu-process-cli.js';

const here = dirname(fileURLToPath(import.meta.url));
const packageRoot = resolve(here, '../..');
const bin = resolve(packageRoot, 'bin/doe-proof-node.js');
const provider = resolve(here, '../fixtures/provider-v1.js');
const entrypoint = resolve(here, '../fixtures/governed-process-app.mjs');
const digest = (value) => `sha256:${createHash('sha256').update(value).digest('hex')}`;
const fileDigest = (path) => digest(readFileSync(path));
const scratch = mkdtempSync(resolve(tmpdir(), 'doe-proof-cli-'));

function run(...args) {
  return spawnSync(process.execPath, [bin, ...args], {
    cwd: scratch,
    encoding: 'utf8',
  });
}

function runAsync(args, signalDelayMs) {
  return new Promise((resolveRun) => {
    const child = spawn(process.execPath, [bin, ...args], {
      cwd: scratch,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    setTimeout(() => child.kill('SIGTERM'), signalDelayMs);
    child.on('close', (status, signal) => resolveRun({ status, signal, stdout, stderr }));
  });
}

try {
  const inputPath = resolve(scratch, 'input.bin');
  const contractPath = resolve(scratch, 'contract.json');
  const artifactPath = resolve(scratch, 'artifact.json');
  const replayPath = resolve(scratch, 'replay.json');
  const evaluator = resolve(scratch, 'evaluator.mjs');
  const evaluatorMarker = resolve(scratch, 'evaluator-executed');
  const runtimeDataPath = resolve(scratch, 'runtime-data.bin');
  const output = new Uint8Array([2, 4, 6, 8]);
  writeFileSync(inputPath, new Uint8Array([1, 2, 3, 4]));
  writeFileSync(runtimeDataPath, new Uint8Array([5, 6, 7, 8]));
  writeFileSync(evaluator, `
    import { writeFileSync } from 'node:fs';
    writeFileSync(${JSON.stringify(evaluatorMarker)}, 'executed');
    export function evaluate({ stdout }) {
      const result = JSON.parse(Buffer.from(stdout).toString('utf8'));
      return {
        output: new Uint8Array(result.output),
        providerIdentity: result.providerIdentity,
        evidence: result.evidence,
      };
    }
  `);
  const contract = {
    schema: DOE_PROOF_PROCESS_CONTRACT_SCHEMA,
    provider: {
      id: 'fixture-provider',
      module: provider,
      sha256: fileDigest(provider),
    },
    workload: {
      id: 'governed-cli-fixture',
      version: '1',
      implementationSha256: digest('governed CLI fixture v1'),
      input: { path: inputPath, sha256: fileDigest(inputPath) },
      expectedOutputSha256: digest(output),
    },
    process: {
      entrypoint: { path: entrypoint, sha256: fileDigest(entrypoint) },
      args: [],
      cwd: scratch,
      environment: {
        mode: 'sealed',
        values: { DOE_TEST_PROCESS_OUTPUT: JSON.stringify([...output]) },
      },
      timeoutMs: 5_000,
      maxOutputBytes: 16_384,
    },
    evaluator: {
      module: evaluator,
      sha256: fileDigest(evaluator),
      export: 'evaluate',
    },
    runtimeFiles: [{
      id: 'fixture-runtime-data',
      path: runtimeDataPath,
      sha256: fileDigest(runtimeDataPath),
    }],
  };
  writeFileSync(contractPath, `${JSON.stringify(contract, null, 2)}\n`);

  const executed = run('run', contractPath, '--out', artifactPath);
  assert.equal(executed.status, 0, executed.stderr);
  const artifact = JSON.parse(readFileSync(artifactPath, 'utf8'));
  assert.equal(artifact.schema, DOE_PROOF_PROCESS_ARTIFACT_SCHEMA);
  assert.equal(artifact.status, 'pass');
  assert.equal(artifact.receipt.oracle.status, 'pass');
  assert.equal(artifact.receipt.provider.effective.providerId, 'fixture-provider');
  assert.deepEqual(artifact.dependencies.runtimeFiles, [{
    id: 'fixture-runtime-data',
    path: runtimeDataPath,
    sha256: fileDigest(runtimeDataPath),
  }]);
  assert.equal((await validateDoeProofProcessArtifactFile(artifactPath)).valid, true);
  assert.equal(existsSync(evaluatorMarker), true);
  unlinkSync(evaluatorMarker);

  const verified = run('verify', artifactPath);
  assert.equal(verified.status, 0, verified.stderr);
  assert.equal(JSON.parse(verified.stdout).valid, true);
  assert.equal(existsSync(evaluatorMarker), false, 'verification must not execute the evaluator');

  writeFileSync(runtimeDataPath, new Uint8Array([9]));
  const changedRuntimeFile = run('verify', artifactPath);
  assert.notEqual(changedRuntimeFile.status, 0);
  assert.match(changedRuntimeFile.stdout, /runtime file.*digest mismatch/);
  writeFileSync(runtimeDataPath, new Uint8Array([5, 6, 7, 8]));

  const inspected = run('inspect', artifactPath);
  assert.equal(inspected.status, 0, inspected.stderr);
  assert.equal(JSON.parse(inspected.stdout).oracle.status, 'pass');

  const replayed = run('replay', artifactPath, '--out', replayPath);
  assert.equal(replayed.status, 0, replayed.stderr);
  const replay = JSON.parse(readFileSync(replayPath, 'utf8'));
  assert.equal(replay.replay.status, 'pass');
  assert.equal(replay.replay.workloadMatches, true);
  assert.equal(replay.replay.executionMatches, true);

  const compared = run('compare', artifactPath, replayPath);
  assert.equal(compared.status, 0, compared.stderr);
  const comparison = JSON.parse(compared.stdout);
  assert.equal(comparison.comparable, true);
  assert.equal(comparison.performanceInterpretable, false);
  assert.equal(comparison.runtimeOwnershipCredit, false);

  const overwrite = run('run', contractPath, '--out', artifactPath);
  assert.notEqual(overwrite.status, 0);
  assert.match(overwrite.stderr, /EEXIST/);

  const tamperedPath = resolve(scratch, 'tampered.json');
  artifact.receipt.workload.id = 'tampered';
  writeFileSync(tamperedPath, `${JSON.stringify(artifact, null, 2)}\n`);
  const tampered = run('verify', tamperedPath);
  assert.notEqual(tampered.status, 0);
  assert.equal(JSON.parse(tampered.stdout).valid, false);

  const wrongContractPath = resolve(scratch, 'wrong-contract.json');
  const wrongArtifactPath = resolve(scratch, 'wrong-artifact.json');
  contract.provider.sha256 = digest('wrong provider');
  writeFileSync(wrongContractPath, `${JSON.stringify(contract, null, 2)}\n`);
  const wrong = run('run', wrongContractPath, '--out', wrongArtifactPath);
  assert.notEqual(wrong.status, 0);
  assert.match(wrong.stderr, /provider entrypoint digest mismatch/);
  assert.equal(existsSync(wrongArtifactPath), false);

  const abortContractPath = resolve(scratch, 'abort-contract.json');
  const abortArtifactPath = resolve(scratch, 'abort-artifact.json');
  const abortContract = structuredClone(contract);
  abortContract.provider.sha256 = fileDigest(provider);
  abortContract.process.environment.values = { DOE_TEST_PROCESS_MODE: 'hang' };
  writeFileSync(abortContractPath, `${JSON.stringify(abortContract, null, 2)}\n`);
  const aborted = await runAsync(
    ['run', abortContractPath, '--out', abortArtifactPath],
    100,
  );
  assert.equal(aborted.status, 1, aborted.stderr);
  assert.equal(existsSync(abortArtifactPath), true);
  const abortArtifact = JSON.parse(readFileSync(abortArtifactPath, 'utf8'));
  assert.equal(abortArtifact.status, 'failed');
  assert.equal(abortArtifact.receipt.process.aborted, true);
  assert.ok(abortArtifact.receipt.errors.some(
    (error) => error.code === 'DOE_GOVERNED_PROCESS_ABORTED',
  ));
  assert.equal((await validateDoeProofProcessArtifactFile(abortArtifactPath)).valid, true);
  const verifiedAbort = run('verify', abortArtifactPath);
  assert.equal(verifiedAbort.status, 0, verifiedAbort.stderr);

  const help = run('--help');
  assert.equal(help.status, 0);
  assert.match(help.stdout, /doe-proof-node replay/);
} finally {
  rmSync(scratch, { recursive: true, force: true });
}

console.log('node-webgpu governed process CLI contracts: ok');

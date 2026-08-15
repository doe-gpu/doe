import { createHash } from 'node:crypto';
import {
  mkdtemp,
  readFile,
  readdir,
  rm,
  writeFile,
} from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const packageRoot = resolve(here, '../..');
const scratch = await mkdtemp(join(tmpdir(), 'doe-proof-clean-install-'));
const npm = process.platform === 'win32' ? 'npm.cmd' : 'npm';
const digest = (value) => `sha256:${createHash('sha256').update(value).digest('hex')}`;
const fileDigest = async (path) => digest(await readFile(path));

function execute(command, args, cwd = scratch) {
  return spawnSync(command, args, {
    cwd,
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
  });
}

function requireSuccess(result, label) {
  if (result.status !== 0) {
    throw new Error(`${label} failed:\n${result.stdout}\n${result.stderr}`);
  }
}

try {
  const packed = execute(npm, ['pack', '--pack-destination', scratch, '--json'], packageRoot);
  requireSuccess(packed, 'npm pack');
  const packResult = JSON.parse(packed.stdout)[0];
  const tarball = resolve(scratch, packResult.filename);
  await writeFile(resolve(scratch, 'package.json'), `${JSON.stringify({
    name: 'doe-proof-clean-install-fixture',
    private: true,
    type: 'module',
  }, null, 2)}\n`);
  const installed = execute(npm, [
    'install',
    '--ignore-scripts',
    '--omit=optional',
    '--no-audit',
    '--no-fund',
    tarball,
  ]);
  requireSuccess(installed, 'clean npm install');

  const bin = process.platform === 'win32'
    ? resolve(scratch, 'node_modules/.bin/doe-proof-node.cmd')
    : resolve(scratch, 'node_modules/.bin/doe-proof-node');
  const help = execute(bin, ['--help']);
  requireSuccess(help, 'installed CLI help');
  if (!help.stdout.includes('doe-proof-node replay')) {
    throw new Error('installed CLI help is incomplete');
  }

  const providerPath = resolve(scratch, 'provider.mjs');
  const applicationPath = resolve(scratch, 'application.mjs');
  const evaluatorPath = resolve(scratch, 'evaluator.mjs');
  const inputPath = resolve(scratch, 'input.bin');
  const runtimeDataPath = resolve(scratch, 'runtime-data.bin');
  const contractPath = resolve(scratch, 'contract.json');
  const artifactPath = resolve(scratch, 'artifact.json');
  await writeFile(providerPath, `
    export const globals = {
      GPUBufferUsage: { STORAGE: 128 },
      GPUShaderStage: { COMPUTE: 4 },
      GPUMapMode: { READ: 1 },
      GPUTextureUsage: { STORAGE_BINDING: 8 },
    };
    export function create() {
      return { requestAdapter: async () => ({ label: 'clean-install-adapter' }) };
    }
  `);
  await writeFile(applicationPath, `
    import { __doeProofProviderIdentity, create } from 'webgpu';
    const adapter = await create().requestAdapter();
    process.stdout.write(JSON.stringify({
      providerIdentity: __doeProofProviderIdentity,
      output: [2, 4, 6, 8],
      evidence: { adapterLabel: adapter.label },
    }) + '\\n');
  `);
  await writeFile(evaluatorPath, `
    export function evaluate({ stdout }) {
      const value = JSON.parse(Buffer.from(stdout).toString('utf8'));
      return {
        output: new Uint8Array(value.output),
        providerIdentity: value.providerIdentity,
        evidence: value.evidence,
      };
    }
  `);
  await writeFile(inputPath, new Uint8Array([1, 2, 3, 4]));
  await writeFile(runtimeDataPath, new Uint8Array([5, 6, 7, 8]));
  const expected = new Uint8Array([2, 4, 6, 8]);
  const contract = {
    schema: 'doe.governed-node-webgpu-process-contract/v1',
    provider: {
      id: 'clean-install-provider',
      module: providerPath,
      sha256: await fileDigest(providerPath),
    },
    workload: {
      id: 'clean-install-exact-output',
      version: '1',
      implementationSha256: digest('clean install application v1'),
      input: { path: inputPath, sha256: await fileDigest(inputPath) },
      expectedOutputSha256: digest(expected),
    },
    process: {
      entrypoint: {
        path: applicationPath,
        sha256: await fileDigest(applicationPath),
      },
      cwd: scratch,
      environment: { mode: 'sealed', values: {} },
      filesystem: { mode: 'node-permission-read-only' },
      timeoutMs: 5000,
      maxOutputBytes: 16384,
    },
    evaluator: {
      module: evaluatorPath,
      sha256: await fileDigest(evaluatorPath),
      export: 'evaluate',
    },
    runtimeFiles: [{
      id: 'clean-install-runtime-data',
      path: runtimeDataPath,
      sha256: await fileDigest(runtimeDataPath),
    }, {
      id: 'clean-install-project-manifest',
      path: resolve(scratch, 'package.json'),
      sha256: await fileDigest(resolve(scratch, 'package.json')),
    }, {
      id: 'installed-doe-gpu-manifest',
      path: resolve(scratch, 'node_modules/doe-gpu/package.json'),
      sha256: await fileDigest(resolve(scratch, 'node_modules/doe-gpu/package.json')),
    }],
  };
  await writeFile(contractPath, `${JSON.stringify(contract, null, 2)}\n`);

  const run = execute(bin, ['run', contractPath, '--out', artifactPath]);
  requireSuccess(run, 'installed CLI run');
  const verify = execute(bin, ['verify', artifactPath]);
  requireSuccess(verify, 'installed CLI verify');
  const verified = JSON.parse(verify.stdout);
  if (verified.valid !== true || verified.oracle?.status !== 'pass') {
    throw new Error(`installed CLI receipt failed: ${verify.stdout}`);
  }
  const artifact = JSON.parse(await readFile(artifactPath, 'utf8'));
  if (artifact.receipt?.applicationEvidence?.adapterLabel !== 'clean-install-adapter') {
    throw new Error('installed CLI did not execute the declared provider');
  }
  if (artifact.dependencies?.runtimeFiles?.[0]?.id !== 'clean-install-runtime-data') {
    throw new Error('installed CLI did not bind the declared runtime file');
  }
  if (artifact.receipt?.process?.declaration?.filesystem?.mode
      !== 'node-permission-read-only') {
    throw new Error('installed CLI did not enforce the declared filesystem policy');
  }

  const installedFiles = await readdir(resolve(scratch, 'node_modules/doe-gpu/bin'));
  if (!installedFiles.includes('doe-proof-node.js')) {
    throw new Error('installed package is missing doe-proof-node.js');
  }
  const requireFromFixture = createRequire(resolve(scratch, 'package.json'));
  for (const schemaName of [
    'governed-node-webgpu-process-contract.schema.json',
    'governed-node-webgpu-process-receipt.schema.json',
    'governed-node-webgpu-process-artifact.schema.json',
  ]) {
    const schema = JSON.parse(await readFile(
      requireFromFixture.resolve(`doe-gpu/${schemaName}`),
      'utf8',
    ));
    if (schema.$schema !== 'https://json-schema.org/draft/2020-12/schema') {
      throw new Error(`installed package has an invalid ${schemaName}`);
    }
  }
  console.log('DoeProof CLI clean-install integration: ok');
} finally {
  await rm(scratch, { recursive: true, force: true });
}

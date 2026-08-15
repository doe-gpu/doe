#!/usr/bin/env node

import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  access,
  mkdir,
  mkdtemp,
  readFile,
  rename,
  stat,
  writeFile,
} from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const harnessDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(harnessDir, '../../..');
const packageSpec = 'webgpu@0.3.10';
const expectedIntegrity = 'sha512-5QKDzvwlPaYshQAmhG0WImX5cvWsY5XRiukUwtKaoMEk0csi4tRSH/cwsoNn9S7JJFHnkSDA/NzfuHmcavNBmw==';
const expectedTarballUrl = 'https://registry.npmjs.org/webgpu/-/webgpu-0.3.10.tgz';

function parseArgs(argv) {
  const options = {
    output: resolve(
      repoRoot,
      'bench/out/external-projects/wgsl-fns/p0-webgpu-0.3.10',
    ),
  };
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === '--output') options.output = resolve(argv[++index]);
    else throw new Error(`unknown argument: ${argv[index]}`);
  }
  if (!options.output.startsWith(`${repoRoot}/bench/out/external-projects/wgsl-fns/`)) {
    throw new Error('P0 output must remain under bench/out/external-projects/wgsl-fns');
  }
  return options;
}

async function digest(path, algorithm, encoding = 'hex') {
  const hash = createHash(algorithm);
  hash.update(await readFile(path));
  return hash.digest(encoding);
}

function relativeToRepo(path) {
  if (!path.startsWith(`${repoRoot}/`)) throw new Error(`path escapes repository: ${path}`);
  return path.slice(repoRoot.length + 1);
}

async function run(command, args, cwd) {
  const child = spawn(command, args, {
    cwd,
    env: process.env,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stdout = '';
  let stderr = '';
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', (chunk) => { stdout += chunk; });
  child.stderr.on('data', (chunk) => { stderr += chunk; });
  const result = await new Promise((resolveResult, reject) => {
    child.once('error', reject);
    child.once('exit', (exitCode, signal) => resolveResult({ exitCode, signal }));
  });
  if (result.exitCode !== 0 || result.signal !== null) {
    throw new Error(`${command} failed (${result.exitCode ?? result.signal}): ${stderr}`);
  }
  return stdout;
}

async function validateExisting(receiptPath) {
  const receipt = JSON.parse(await readFile(receiptPath, 'utf8'));
  if (receipt.artifactKind !== 'wgsl-fns-p0-package-receipt'
    || receipt.package?.spec !== packageSpec
    || receipt.package?.integrity !== expectedIntegrity) {
    throw new Error('existing P0 receipt does not match the frozen package contract');
  }
  for (const artifact of Object.values(receipt.artifacts ?? {})) {
    const path = resolve(repoRoot, artifact.path);
    if (await digest(path, 'sha256') !== artifact.sha256) {
      throw new Error(`existing P0 artifact hash mismatch: ${artifact.path}`);
    }
  }
  return receipt;
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const receiptPath = resolve(options.output, 'receipt.json');
  try {
    await access(receiptPath);
    const receipt = await validateExisting(receiptPath);
    console.log(JSON.stringify({ status: 'reused', receiptPath: relativeToRepo(receiptPath), receipt }));
    return;
  } catch (error) {
    if (error?.code !== 'ENOENT') throw error;
  }

  await mkdir(dirname(options.output), { recursive: true });
  const stagingRoot = await mkdtemp(resolve(dirname(options.output), '.p0-stage-'));
  const npmOutput = JSON.parse(await run(
    'npm',
    ['pack', packageSpec, '--pack-destination', stagingRoot, '--json'],
    repoRoot,
  ));
  if (!Array.isArray(npmOutput) || npmOutput.length !== 1) {
    throw new Error('npm pack did not return exactly one package record');
  }
  const tarballPath = resolve(stagingRoot, npmOutput[0].filename);
  const actualIntegrity = `sha512-${await digest(tarballPath, 'sha512', 'base64')}`;
  if (actualIntegrity !== expectedIntegrity || npmOutput[0].integrity !== expectedIntegrity) {
    throw new Error(`P0 tarball integrity mismatch: ${actualIntegrity}`);
  }
  await run('tar', ['-xzf', tarballPath, '-C', stagingRoot], repoRoot);

  const packageRoot = resolve(stagingRoot, 'package');
  const packageJsonPath = resolve(packageRoot, 'package.json');
  const packageJson = JSON.parse(await readFile(packageJsonPath, 'utf8'));
  if (packageJson.name !== 'webgpu' || packageJson.version !== '0.3.10') {
    throw new Error('extracted P0 package identity mismatch');
  }
  const modulePath = resolve(packageRoot, 'index.js');
  const nativePath = resolve(packageRoot, 'dist/linux-x64.dawn.node');
  const licensePath = resolve(packageRoot, 'LICENSE.md');
  for (const path of [modulePath, nativePath, licensePath]) await access(path);

  const finalTarballPath = resolve(options.output, npmOutput[0].filename);
  const finalPackageRoot = resolve(options.output, 'package');
  const artifacts = {
    tarball: {
      path: relativeToRepo(finalTarballPath),
      sha256: await digest(tarballPath, 'sha256'),
      bytes: (await stat(tarballPath)).size,
    },
    module: {
      path: relativeToRepo(resolve(finalPackageRoot, 'index.js')),
      sha256: await digest(modulePath, 'sha256'),
      bytes: (await stat(modulePath)).size,
    },
    native: {
      path: relativeToRepo(resolve(finalPackageRoot, 'dist/linux-x64.dawn.node')),
      sha256: await digest(nativePath, 'sha256'),
      bytes: (await stat(nativePath)).size,
    },
    license: {
      path: relativeToRepo(resolve(finalPackageRoot, 'LICENSE.md')),
      sha256: await digest(licensePath, 'sha256'),
      bytes: (await stat(licensePath)).size,
    },
  };
  const receipt = {
    schemaVersion: 1,
    artifactKind: 'wgsl-fns-p0-package-receipt',
    generatedAt: new Date().toISOString(),
    package: {
      spec: packageSpec,
      name: 'webgpu',
      version: '0.3.10',
      registry: 'https://registry.npmjs.org',
      tarballUrl: expectedTarballUrl,
      integrity: expectedIntegrity,
      npmShasum: npmOutput[0].shasum,
    },
    platform: { os: process.platform, architecture: process.arch },
    artifacts,
  };
  await writeFile(resolve(stagingRoot, 'receipt.json'), `${JSON.stringify(receipt, null, 2)}\n`);
  await rename(stagingRoot, options.output);
  console.log(JSON.stringify({ status: 'prepared', receiptPath: relativeToRepo(receiptPath), receipt }));
}

main().catch((error) => {
  console.error(error?.stack ?? String(error));
  process.exitCode = 1;
});

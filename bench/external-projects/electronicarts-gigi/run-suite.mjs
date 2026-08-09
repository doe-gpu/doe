#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { access, readFile, readdir, mkdir, writeFile } from 'node:fs/promises';
import { constants as fsConstants } from 'node:fs';
import { spawn } from 'node:child_process';
import { dirname, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const harnessDir = dirname(fileURLToPath(import.meta.url));
const defaultUpstream = resolve(
  repoRoot,
  'bench/out/external-projects/electronicarts-gigi/upstream',
);

function parseArgs(argv) {
  const options = {
    upstream: defaultUpstream,
    providers: ['dawn-node-webgpu', 'doe-gpu'],
    runId: new Date().toISOString().replaceAll(':', '').replaceAll('.', ''),
    pattern: '',
    limit: 0,
    timeoutMs: 120_000,
    requireAllPass: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === '--upstream') options.upstream = resolve(argv[++index]);
    else if (value === '--providers') options.providers = argv[++index].split(',');
    else if (value === '--run-id') options.runId = argv[++index];
    else if (value === '--pattern') options.pattern = argv[++index];
    else if (value === '--limit') options.limit = Number.parseInt(argv[++index], 10);
    else if (value === '--timeout-ms') options.timeoutMs = Number.parseInt(argv[++index], 10);
    else if (value === '--require-all-pass') options.requireAllPass = true;
    else throw new Error(`unknown argument: ${value}`);
  }
  return options;
}

async function findCases(root) {
  const cases = [];
  async function walk(directory) {
    const entries = await readdir(directory, { withFileTypes: true });
    if (entries.some((entry) => entry.isFile() && entry.name === 'index.js')) {
      cases.push(directory);
      return;
    }
    await Promise.all(
      entries
        .filter((entry) => entry.isDirectory())
        .map((entry) => walk(resolve(directory, entry.name))),
    );
  }
  await walk(root);
  return cases.sort();
}

async function sha256(path) {
  return createHash('sha256').update(await readFile(path)).digest('hex');
}

function providerEnvironment(options, suiteRoot, provider) {
  return {
    ...process.env,
    DOE_EXTERNAL_WEBGPU_PROVIDER: provider,
    DOE_EXTERNAL_DAWN_MODULE: resolve(suiteRoot, 'node_modules/webgpu/index.js'),
    DOE_EXTERNAL_DOE_MODULE: resolve(
      repoRoot,
      'packages/doe-gpu/src/vendor/webgpu/index.js',
    ),
  };
}

async function runProcess(command, args, { cwd, env, timeoutMs }) {
  const started = process.hrtime.bigint();
  const child = spawn(command, args, { cwd, env, stdio: ['ignore', 'pipe', 'pipe'] });
  let stdout = '';
  let stderr = '';
  let peakMemoryBytes = 0;
  let timedOut = false;
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', (chunk) => { stdout += chunk; });
  child.stderr.on('data', (chunk) => { stderr += chunk; });
  const memoryPoll = setInterval(async () => {
    try {
      const status = await readFile(`/proc/${child.pid}/status`, 'utf8');
      const match = /^VmHWM:\s+(\d+)\s+kB$/m.exec(status);
      if (match) peakMemoryBytes = Math.max(peakMemoryBytes, Number(match[1]) * 1024);
    } catch {
      // Process exit races with /proc reads; the final observed peak remains valid.
    }
  }, 10);
  const timeout = setTimeout(() => {
    timedOut = true;
    child.kill('SIGKILL');
  }, timeoutMs);
  const result = await new Promise((resolveResult, reject) => {
    child.once('error', reject);
    child.once('exit', (code, signal) => resolveResult({ code, signal }));
  });
  clearTimeout(timeout);
  clearInterval(memoryPoll);
  return {
    exitCode: result.code,
    signal: result.signal,
    timedOut,
    crashed: !timedOut && result.signal !== null,
    durationMs: Number(process.hrtime.bigint() - started) / 1e6,
    peakMemoryBytes,
    stdout: stdout.slice(-16_384),
    stderr: stderr.slice(-16_384),
  };
}

async function inspectHostHardware() {
  let renderNodes = [];
  try {
    renderNodes = (await readdir('/dev/dri'))
      .filter((name) => name.startsWith('renderD'))
      .map((name) => `/dev/dri/${name}`);
  } catch {
    return { renderNodes, accessibleRenderNodes: [], physicalGpuEligible: false };
  }
  const accessibleRenderNodes = [];
  for (const path of renderNodes) {
    try {
      await access(path, fsConstants.R_OK | fsConstants.W_OK);
      accessibleRenderNodes.push(path);
    } catch {
      // A listed but inaccessible render node cannot support hardware evidence.
    }
  }
  return {
    renderNodes,
    accessibleRenderNodes,
    physicalGpuEligible: accessibleRenderNodes.length > 0,
  };
}

async function probeProvider(options, suiteRoot, provider, hostHardware) {
  const result = await runProcess(
    process.execPath,
    ['--loader', resolve(harnessDir, 'provider-loader.mjs'), resolve(harnessDir, 'probe-provider.mjs')],
    {
      cwd: suiteRoot,
      env: providerEnvironment(options, suiteRoot, provider),
      timeoutMs: options.timeoutMs,
    },
  );
  const marker = result.stdout
    .split('\n')
    .find((line) => line.startsWith('DOE_GIGI_PROVIDER_PROBE='));
  const identity = marker ? JSON.parse(marker.slice(marker.indexOf('=') + 1)) : null;
  const identityText = JSON.stringify(identity ?? {}).toLowerCase();
  const softwareRenderer = /llvmpipe|swiftshader|software renderer/.test(identityText);
  return {
    ...result,
    identity,
    softwareRenderer,
    hardwareEligible: result.exitCode === 0
      && identity !== null
      && !softwareRenderer
      && hostHardware.physicalGpuEligible,
  };
}

async function runCase(options, suiteRoot, caseDirectory, provider) {
  const result = await runProcess(
    process.execPath,
    ['--loader', resolve(harnessDir, 'provider-loader.mjs'), '.'],
    {
      cwd: caseDirectory,
      env: providerEnvironment(options, suiteRoot, provider),
      timeoutMs: options.timeoutMs,
    },
  );
  return {
    caseId: relative(resolve(suiteRoot, 'UnitTests'), caseDirectory),
    indexSha256: await sha256(resolve(caseDirectory, 'index.js')),
    success: result.exitCode === 0 && !result.timedOut && !result.crashed,
    ...result,
  };
}

function summarize(results) {
  const durations = results.map((result) => result.durationMs).sort((a, b) => a - b);
  const percentile = (value) => durations.length === 0
    ? 0
    : durations[Math.min(durations.length - 1, Math.ceil(value * durations.length) - 1)];
  return {
    cleanProcessRuns: results.length,
    successes: results.filter((result) => result.success).length,
    failures: results.filter((result) => !result.success).length,
    crashes: results.filter((result) => result.crashed).length,
    timeouts: results.filter((result) => result.timedOut).length,
    peakMemoryBytes: Math.max(0, ...results.map((result) => result.peakMemoryBytes)),
    latencyMs: {
      p50: percentile(0.50),
      p95: percentile(0.95),
      p99: percentile(0.99),
    },
  };
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const suiteRoot = resolve(options.upstream, '_GeneratedCode/UnitTests/WebGPU');
  const commit = (await runProcess('git', ['rev-parse', 'HEAD'], {
    cwd: options.upstream,
    env: process.env,
    timeoutMs: options.timeoutMs,
  })).stdout.trim();
  if (commit !== '401386cfd7c6e39e549d939e44d99bd5b49cd14d') {
    throw new Error(`unexpected Gigi commit: ${commit}`);
  }
  let cases = await findCases(resolve(suiteRoot, 'UnitTests'));
  if (options.pattern) cases = cases.filter((path) => relative(suiteRoot, path).includes(options.pattern));
  if (options.limit > 0) cases = cases.slice(0, options.limit);

  const hostHardware = await inspectHostHardware();
  const providers = {};
  for (const provider of options.providers) {
    const probe = await probeProvider(options, suiteRoot, provider, hostHardware);
    if (probe.exitCode !== 0 || probe.identity?.provider?.id !== provider) {
      throw new Error(`provider identity probe failed for ${provider}: ${probe.stderr}`);
    }
    const results = [];
    for (const caseDirectory of cases) {
      const result = await runCase(options, suiteRoot, caseDirectory, provider);
      results.push(result);
      console.log(`[${provider}] ${result.success ? 'PASS' : 'FAIL'} ${result.caseId}`);
    }
    providers[provider] = { probe, summary: summarize(results), results };
  }

  const payload = {
    schemaVersion: 1,
    artifactKind: 'gigi-generated-webgpu-suite-run',
    generatedAt: new Date().toISOString(),
    actorId: 'electronicarts-gigi',
    harnessId: 'generated-webgpu-suite',
    upstream: {
      repositoryUrl: 'https://github.com/electronicarts/gigi',
      commit,
      licenseIdentifier: 'LicenseRef-EA-BSD-3-Clause-With-Marks',
    },
    sameWork: {
      caseCount: cases.length,
      caseIds: cases.map((path) => relative(resolve(suiteRoot, 'UnitTests'), path)),
      applicationSourceUnchanged: true,
      shaderSourceUnchanged: true,
    },
    hostHardware,
    providers,
  };
  const outDir = resolve(
    repoRoot,
    'bench/out/external-projects/electronicarts-gigi',
    options.runId,
  );
  await mkdir(outDir, { recursive: true });
  const outPath = resolve(outDir, 'raw-suite.json');
  await writeFile(outPath, `${JSON.stringify(payload, null, 2)}\n`);
  console.log(`WROTE ${outPath}`);
  if (options.requireAllPass && Object.values(providers).some(({ summary }) => summary.failures > 0)) {
    process.exitCode = 1;
  }
}

await main();

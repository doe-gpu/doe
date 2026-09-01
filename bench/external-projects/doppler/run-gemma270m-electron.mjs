import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync } from 'node:fs';
import {
  mkdir,
  readFile,
  realpath,
  stat,
  writeFile,
} from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { evaluateQualification } from './oracle.mjs';

const harnessDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(harnessDir, '../../..');
const harnessPath = resolve(harnessDir, 'gemma270m-electron.harness.json');
const exportTool = resolve(repoRoot, 'bench/tools/export_doppler_int4ple_reference.mjs');
const timeoutMs = 7_200_000;
const maxOutputBytes = 16 * 1024 * 1024;

function parseArgs(argv) {
  const values = {
    runId: '',
    upstreamRoot: '',
    preparationReceipt: '',
    out: '',
  };
  for (let index = 2; index < argv.length; index += 1) {
    const argument = argv[index];
    const key = {
      '--run-id': 'runId',
      '--upstream-root': 'upstreamRoot',
      '--preparation-receipt': 'preparationReceipt',
      '--out': 'out',
    }[argument];
    if (!key) throw new Error(`unsupported argument: ${argument}`);
    const value = argv[index + 1];
    if (!value) throw new Error(`${argument} requires a value`);
    values[key] = value;
    index += 1;
  }
  for (const [key, value] of Object.entries(values)) {
    if (!value) throw new Error(`${key} is required`);
  }
  return values;
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

function stableJson(value) {
  return `${JSON.stringify(stableValue(value), null, 2)}\n`;
}

function sha256Bytes(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

async function sha256File(path) {
  return sha256Bytes(await readFile(path));
}

function sha256Json(value) {
  return sha256Bytes(Buffer.from(JSON.stringify(stableValue(value)), 'utf8'));
}

async function loadJson(path) {
  return JSON.parse(await readFile(path, 'utf8'));
}

async function writeJson(path, value) {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, stableJson(value), 'utf8');
}

async function requireHash(path, expected, label) {
  if (!existsSync(path)) throw new Error(`${label} is missing: ${path}`);
  const actual = await sha256File(path);
  if (actual !== expected) {
    throw new Error(`${label} hash mismatch: expected ${expected}, received ${actual}`);
  }
  return actual;
}

function requireSuccess(result, label) {
  if (result.status !== 0) {
    throw new Error(
      `${label} failed: ${result.error?.message ?? `exit=${result.status}`}\n`
      + `${result.stdout ?? ''}\n${result.stderr ?? ''}`,
    );
  }
}

function git(upstreamRoot, ...gitArguments) {
  const result = spawnSync('git', ['-C', upstreamRoot, ...gitArguments], {
    encoding: 'utf8',
    maxBuffer: maxOutputBytes,
  });
  requireSuccess(result, `git ${gitArguments.join(' ')}`);
  return result.stdout.trim();
}

async function validateContract(contract, upstreamRoot, preparationReceiptPath) {
  const preparation = await loadJson(preparationReceiptPath);
  if (
    preparation.status !== 'passed'
    || preparation.actorId !== 'doppler'
    || preparation.harnessId !== 'gemma270m-electron'
  ) {
    throw new Error('preparation receipt does not authorize the Doppler Gemma 270M harness');
  }
  if (preparation.source?.actualCommit !== contract.upstreamCommit) {
    throw new Error('preparation receipt source commit does not match the model contract');
  }
  const head = git(upstreamRoot, 'rev-parse', 'HEAD');
  if (head !== contract.upstreamCommit) {
    throw new Error(`Doppler commit mismatch: expected ${contract.upstreamCommit}, received ${head}`);
  }
  if (git(upstreamRoot, 'status', '--porcelain', '--untracked-files=no') !== '') {
    throw new Error('Doppler source tree has tracked changes');
  }

  const upstreamManifestPath = resolve(upstreamRoot, contract.manifest.path);
  const upstreamTokenizerPath = resolve(upstreamRoot, contract.tokenizer.path);
  await requireHash(upstreamManifestPath, contract.manifest.sha256, 'upstream model manifest');
  await requireHash(upstreamTokenizerPath, contract.tokenizer.sha256, 'upstream tokenizer');

  const workspaceRoot = resolve(repoRoot, '..');
  const artifactProjectRoot = resolve(workspaceRoot, contract.artifactSource.project);
  const artifactRoot = await realpath(resolve(
    artifactProjectRoot,
    contract.artifactSource.path,
  ));
  const artifactPrefix = `${await realpath(artifactProjectRoot)}/`;
  if (!`${artifactRoot}/`.startsWith(artifactPrefix)) {
    throw new Error('model artifact source escapes its declared workspace project');
  }
  const manifestPath = resolve(artifactRoot, 'manifest.json');
  const tokenizerPath = resolve(artifactRoot, 'tokenizer.json');
  const originPath = resolve(artifactRoot, contract.artifactSource.origin.path);
  await requireHash(manifestPath, contract.manifest.sha256, 'model artifact manifest');
  await requireHash(tokenizerPath, contract.tokenizer.sha256, 'model artifact tokenizer');
  await requireHash(originPath, contract.artifactSource.origin.sha256, 'model artifact origin');
  const manifest = await loadJson(manifestPath);
  if (manifest.modelId !== contract.modelId) {
    throw new Error(`model ID mismatch: expected ${contract.modelId}, received ${manifest.modelId}`);
  }
  const shaderIdentity = sha256Json(manifest?.inference?.execution?.kernels);
  if (shaderIdentity !== contract.shaderIdentity.sha256) {
    throw new Error(
      `shader identity mismatch: expected ${contract.shaderIdentity.sha256}, received ${shaderIdentity}`,
    );
  }
  for (const shard of manifest.shards ?? []) {
    const shardPath = resolve(artifactRoot, shard.filename);
    const shardStats = await stat(shardPath);
    if (shardStats.size !== shard.size) {
      throw new Error(`model shard size mismatch: ${shard.filename}`);
    }
    await requireHash(shardPath, shard.hash, `model shard ${shard.filename}`);
  }

  const repoLinks = [
    ['application package', contract.application.package],
    ['application entrypoint', contract.application.entrypoint],
    ['prompt', contract.prompt],
    ['Node WebGPU provider contract', contract.providerContract],
    ['W0 provider wrapper', contract.providers.W0.wrapper],
    ['D0 provider wrapper', contract.providers.D0.wrapper],
  ];
  for (const [label, link] of repoLinks) {
    await requireHash(resolve(repoRoot, link.path), link.sha256, label);
  }
  for (const [lane, provider] of Object.entries(contract.providers)) {
    const targetRoot = provider.targetRoot === 'repo' ? repoRoot : upstreamRoot;
    await requireHash(
      resolve(targetRoot, provider.target.path),
      provider.target.sha256,
      `${lane} provider target`,
    );
  }
  return { manifest, manifestPath };
}

function runElectron({ executable, appDir, lane, provider, contract, upstreamRoot, outDir }) {
  return new Promise((resolveRun, rejectRun) => {
    const targetRoot = provider.targetRoot === 'repo' ? repoRoot : upstreamRoot;
    const wrapperPath = resolve(repoRoot, provider.wrapper.path);
    const targetPath = resolve(targetRoot, provider.target.path);
    const providerContractPath = resolve(repoRoot, contract.providerContract.path);
    const prompt = contract.promptText;
    const sampling = contract.execution.sampling;
    const command = [
      '--headless',
      '--no-sandbox',
      '--disable-gpu',
      appDir,
      '--doppler-root',
      upstreamRoot,
      '--model-dir',
      dirname(contract.manifestAbsolutePath),
      '--model-id',
      contract.modelId,
      '--prompt',
      prompt,
      '--runtime-profile',
      contract.execution.runtimeProfile,
      '--out-dir',
      outDir,
      '--decode-steps',
      String(contract.execution.decodeSteps),
      '--temperature',
      String(sampling.temperature),
      '--top-k',
      String(sampling.topK),
      '--top-p',
      String(sampling.topP),
      '--repetition-penalty',
      String(sampling.repetitionPenalty),
      '--seed',
      String(sampling.seed),
      '--kernel-path-policy-mode',
      contract.execution.kernelPathPolicy.mode,
      '--kernel-path-policy-on-incompatible',
      contract.execution.kernelPathPolicy.onIncompatible,
      '--kernel-path-policy-source-scope',
      contract.execution.kernelPathPolicy.sourceScope.join(','),
    ];
    if (!contract.execution.useChatTemplate) command.push('--no-chat-template');
    const startedNs = process.hrtime.bigint();
    const child = spawn(executable, command, {
      cwd: upstreamRoot,
      env: {
        ...process.env,
        DOPPLER_NODE_WEBGPU_MODULE: wrapperPath,
        DOE_DOPPLER_QUALIFICATION_EXPORT_TOOL: exportTool,
        DOE_DOPPLER_QUALIFICATION_PROVIDER_CONTRACT: providerContractPath,
        DOE_DOPPLER_QUALIFICATION_PROVIDER_TARGET: targetPath,
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const stdout = [];
    const stderr = [];
    let outputBytes = 0;
    let timedOut = false;
    let outputLimitExceeded = false;
    const collect = (target) => (chunk) => {
      outputBytes += chunk.byteLength;
      target.push(chunk);
      if (outputBytes > maxOutputBytes) {
        outputLimitExceeded = true;
        child.kill('SIGKILL');
      }
    };
    child.stdout.on('data', collect(stdout));
    child.stderr.on('data', collect(stderr));
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill('SIGKILL');
    }, timeoutMs);
    child.once('error', (error) => {
      clearTimeout(timer);
      rejectRun(error);
    });
    child.once('close', async (exitCode, signal) => {
      clearTimeout(timer);
      const stdoutText = Buffer.concat(stdout).toString('utf8');
      const stderrText = Buffer.concat(stderr).toString('utf8');
      const stdoutPath = resolve(outDir, 'electron.stdout.log');
      const stderrPath = resolve(outDir, 'electron.stderr.log');
      await Promise.all([
        writeFile(stdoutPath, stdoutText, 'utf8'),
        writeFile(stderrPath, stderrText, 'utf8'),
      ]);
      resolveRun({
        lane,
        providerId: provider.id,
        wrapperPath,
        wrapperSha256: provider.wrapper.sha256,
        targetPath,
        targetSha256: provider.target.sha256,
        command,
        exitCode,
        signal,
        timedOut,
        outputLimitExceeded,
        elapsedNs: Number(process.hrtime.bigint() - startedNs),
        stdoutPath,
        stdoutSha256: sha256Bytes(Buffer.from(stdoutText, 'utf8')),
        stderrPath,
        stderrSha256: sha256Bytes(Buffer.from(stderrText, 'utf8')),
      });
    });
  });
}

async function main() {
  const args = parseArgs(process.argv);
  const outputPath = resolve(args.out);
  const runRoot = dirname(outputPath);
  const oraclePath = resolve(runRoot, 'oracle.json');
  const harness = await loadJson(harnessPath);
  const contract = {
    ...harness.workload.modelContract,
    upstreamCommit: harness.upstream.commit,
  };
  const upstreamRoot = await realpath(resolve(args.upstreamRoot));
  const { manifestPath } = await validateContract(
    contract,
    upstreamRoot,
    resolve(args.preparationReceipt),
  );
  contract.manifestAbsolutePath = manifestPath;
  contract.promptText = await readFile(resolve(repoRoot, contract.prompt.path), 'utf8');

  const electronPath = resolve(upstreamRoot, 'node_modules/electron/dist/electron');
  const electronExecutable = await realpath(electronPath);
  const versionProbe = spawnSync(electronExecutable, ['--no-sandbox', '--version'], {
    cwd: upstreamRoot,
    encoding: 'utf8',
    maxBuffer: maxOutputBytes,
  });
  requireSuccess(versionProbe, 'Electron version probe');
  const electronVersion = versionProbe.stdout.trim().replace(/^v/u, '');
  if (electronVersion !== contract.application.version) {
    throw new Error(
      `Electron version mismatch: expected ${contract.application.version}, received ${electronVersion}`,
    );
  }

  const laneRoots = {
    W0: resolve(runRoot, 'lanes/W0'),
    D0: resolve(runRoot, 'lanes/D0'),
  };
  await Promise.all(Object.values(laneRoots).map((path) => mkdir(path, { recursive: true })));
  const runs = {};
  const receipts = {};
  for (const lane of ['W0', 'D0']) {
    runs[lane] = await runElectron({
      executable: electronExecutable,
      appDir: dirname(resolve(repoRoot, contract.application.entrypoint.path)),
      lane,
      provider: contract.providers[lane],
      contract,
      upstreamRoot,
      outDir: laneRoots[lane],
    });
    const receiptPath = resolve(laneRoots[lane], 'doppler_int4ple_reference_export.json');
    if (
      runs[lane].exitCode !== 0
      || runs[lane].signal !== null
      || runs[lane].timedOut
      || runs[lane].outputLimitExceeded
      || !existsSync(receiptPath)
    ) {
      await writeJson(outputPath, {
        schemaVersion: 1,
        artifactKind: 'doe-gemma270m-electron-qualification-result',
        status: 'failed',
        runId: args.runId,
        source: {
          repositoryUrl: harness.upstream.repositoryUrl,
          commit: contract.upstreamCommit,
          clean: true,
        },
        model: {
          modelId: contract.modelId,
          manifest: contract.manifest,
          tokenizer: contract.tokenizer,
          shaderIdentity: contract.shaderIdentity,
        },
        application: {
          ...contract.application,
          executable: electronExecutable,
        },
        supportTarget: harness.supportTargets[0],
        providers: contract.providers,
        runs,
        failure: {
          stage: `${lane}.electron`,
          message: `${lane} Electron execution did not produce a qualification transcript`,
        },
        pass: false,
      });
      throw new Error(`${lane} Electron execution failed; inspect ${laneRoots[lane]}`);
    }
    receipts[lane] = await loadJson(receiptPath);
    runs[lane].receiptPath = receiptPath;
    runs[lane].receiptSha256 = await sha256File(receiptPath);
  }

  const oracle = await evaluateQualification({ contract, laneRoots, receipts });
  await writeJson(oraclePath, oracle);
  const result = {
    schemaVersion: 1,
    artifactKind: 'doe-gemma270m-electron-qualification-result',
    status: oracle.pass ? 'passed' : 'failed',
    runId: args.runId,
    source: {
      repositoryUrl: harness.upstream.repositoryUrl,
      commit: contract.upstreamCommit,
      clean: true,
    },
    model: {
      modelId: contract.modelId,
      manifest: contract.manifest,
      tokenizer: contract.tokenizer,
      shaderIdentity: contract.shaderIdentity,
    },
    application: {
      ...contract.application,
      executable: electronExecutable,
    },
    supportTarget: harness.supportTargets[0],
    providers: contract.providers,
    runs,
    oracle: {
      path: oraclePath,
      sha256: await sha256File(oraclePath),
      status: oracle.status,
    },
    pass: oracle.pass,
  };
  await writeJson(outputPath, result);
  return oracle.pass ? 0 : 1;
}

main()
  .then((code) => {
    process.exitCode = code;
  })
  .catch(async (error) => {
    process.stderr.write(`${error?.stack ?? error}\n`);
    process.exitCode = 1;
  });

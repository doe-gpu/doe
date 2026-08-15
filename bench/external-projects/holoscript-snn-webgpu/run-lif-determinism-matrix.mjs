import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const harnessDir = dirname(fileURLToPath(import.meta.url));
const runnerPath = fileURLToPath(import.meta.url);
const doeRoot = resolve(harnessDir, '../../..');
const upstreamRoot = resolve(
  doeRoot,
  'bench/out/external-projects/holoscript-snn-webgpu/upstream',
);
const upstreamPackageDir = resolve(upstreamRoot, 'packages/snn-webgpu');
const inputPath = resolve(harnessDir, 'lif-determinism.inputs.json');
const harnessPath = resolve(harnessDir, 'lif-determinism.harness.json');
const workloadPath = resolve(harnessDir, 'run-lif-determinism-workload.mjs');
const loaderPath = resolve(harnessDir, 'provider-loader.mjs');
const outputPath = resolve(process.argv[2] ?? resolve(
  doeRoot,
  'bench/out/external-projects/holoscript-snn-webgpu/lif-determinism/result.json',
));
const timeoutMs = 120_000;
const maxOutputBytes = 8 * 1024 * 1024;
const inputs = JSON.parse(await readFile(inputPath, 'utf8'));
const harness = JSON.parse(await readFile(harnessPath, 'utf8'));
const requireFromUpstream = createRequire(
  pathToFileURL(resolve(upstreamPackageDir, 'package.json')),
);
const ambientDawnModule = requireFromUpstream.resolve('webgpu');
const dawnModule = resolve(dirname(ambientDawnModule), 'index.js');
const dawnPackage = JSON.parse(
  await readFile(resolve(dirname(dawnModule), 'package.json'), 'utf8'),
);
const doeModule = resolve(doeRoot, 'packages/doe-gpu/src/index.js');

if (dawnPackage.name !== 'webgpu' || dawnPackage.version !== '0.3.10') {
  throw new Error(
    `pinned incumbent mismatch: expected webgpu@0.3.10, received `
    + `${dawnPackage.name}@${dawnPackage.version}`,
  );
}

function sha256Text(value) {
  return createHash('sha256').update(value).digest('hex');
}

async function sha256File(path) {
  return createHash('sha256').update(await readFile(path)).digest('hex');
}

function terminate(child) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  if (process.platform !== 'win32' && child.pid) {
    try {
      process.kill(-child.pid, 'SIGKILL');
      return;
    } catch {
      // Fall through to direct-child termination.
    }
  }
  child.kill('SIGKILL');
}

function runCleanProcess(laneId, provider, receiptMode, modulePath) {
  return new Promise((resolveRun, rejectRun) => {
    const startedAt = performance.now();
    const child = spawn(process.execPath, [
      '--no-warnings',
      '--experimental-loader',
      loaderPath,
      workloadPath,
    ], {
      cwd: upstreamPackageDir,
      env: {
        ...process.env,
        DOE_EXTERNAL_WEBGPU_PROVIDER: provider,
        DOE_EXTERNAL_DAWN_MODULE: modulePath,
        DOE_EXTERNAL_DOE_MODULE: doeModule,
        DOE_EXTERNAL_UPSTREAM_PACKAGE_DIR: upstreamPackageDir,
        DOE_EXTERNAL_INPUT_PATH: inputPath,
        DOE_EXTERNAL_RECEIPT_MODE: receiptMode,
      },
      detached: process.platform !== 'win32',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const stdout = [];
    const stderr = [];
    let outputBytes = 0;
    let timedOut = false;
    let outputLimitExceeded = false;
    const timer = setTimeout(() => {
      timedOut = true;
      terminate(child);
    }, timeoutMs);
    const collect = (target) => (chunk) => {
      outputBytes += chunk.length;
      target.push(chunk);
      if (outputBytes > maxOutputBytes) {
        outputLimitExceeded = true;
        terminate(child);
      }
    };
    child.stdout.on('data', collect(stdout));
    child.stderr.on('data', collect(stderr));
    child.once('error', (error) => {
      clearTimeout(timer);
      rejectRun(error);
    });
    child.once('close', (exitCode, signal) => {
      clearTimeout(timer);
      const stdoutText = Buffer.concat(stdout).toString('utf8').trim();
      const stderrText = Buffer.concat(stderr).toString('utf8').trim();
      let result = null;
      let parseError = '';
      if (stdoutText) {
        try {
          result = JSON.parse(stdoutText);
        } catch (error) {
          parseError = String(error?.message ?? error);
        }
      }
      resolveRun({
        laneId,
        provider,
        receiptMode,
        modulePath,
        elapsedMs: performance.now() - startedAt,
        exitCode,
        signal,
        timedOut,
        outputLimitExceeded,
        parseError,
        stderr: stderrText,
        result,
      });
    });
  });
}

function semanticEvidence(run) {
  if (!run.result) {
    return {
      laneId: run.laneId,
      provider: run.provider,
      exitCode: run.exitCode,
      signal: run.signal,
      timedOut: run.timedOut,
      outputLimitExceeded: run.outputLimitExceeded,
      parseError: run.parseError,
    };
  }
  return {
    laneId: run.laneId,
    provider: run.provider,
    effectiveProvider: run.result.provider?.id,
    adapter: run.result.adapter,
    hardwareEligible: run.result.hardwareEligible,
    shader: run.result.shader,
    dispatch: run.result.dispatch,
    synchronization: run.result.synchronization,
    readback: run.result.readback,
    oracle: run.result.oracle,
    cases: run.result.cases.map((testCase) => ({
      id: testCase.id,
      delta: testCase.delta,
      oraclePass: testCase.oraclePass,
      cpuMembraneSha256: testCase.cpuMembraneSha256,
      gpuMembraneSha256: testCase.gpuMembraneSha256,
      cpuSpikesSha256: testCase.cpuSpikesSha256,
      gpuSpikesSha256: testCase.gpuSpikesSha256,
    })),
    sameBackendDeterminism: run.result.sameBackendDeterminism,
    passed: run.result.passed,
  };
}

function runPasses(run, expectedProvider) {
  return run.exitCode === 0
    && run.signal === null
    && !run.timedOut
    && !run.outputLimitExceeded
    && !run.parseError
    && run.result?.provider?.id === expectedProvider
    && run.result?.hardwareEligible === true
    && run.result?.passed === true
    && run.result?.cases?.length === inputs.cases.length
    && run.result.cases.every((testCase) => testCase.oraclePass)
    && run.result.sameBackendDeterminism?.uniqueHashCount === 1
    && run.result.sameBackendDeterminism?.nondegenerate === true;
}

function summarizeLane(runs, laneId, expectedProvider) {
  const selected = runs.filter((run) => run.laneId === laneId);
  return {
    runCount: selected.length,
    passingRuns: selected.filter((run) => runPasses(run, expectedProvider)).length,
    peakMemoryBytes: Math.max(0, ...selected.map((run) => run.result?.peakMemoryBytes ?? 0)),
    evidence: selected.map(semanticEvidence),
  };
}

function providerOutputIdentity(run) {
  return {
    cases: run.result.cases.map((testCase) => ({
      id: testCase.id,
      gpuMembraneSha256: testCase.gpuMembraneSha256,
      gpuSpikesSha256: testCase.gpuSpikesSha256,
    })),
    canonicalRepeatSha256: run.result.sameBackendDeterminism.repeatHashes[0],
  };
}

if (process.platform !== 'linux' || process.arch !== 'x64') {
  throw new Error('HoloScript LIF determinism diagnostic is frozen to linux-x64');
}

const immutablePaths = [
  harnessPath,
  inputPath,
  resolve(harnessDir, 'lif-determinism.oracle.md'),
  loaderPath,
  runnerPath,
  workloadPath,
  resolve(harnessDir, 'hardware-identity.mjs'),
  resolve(upstreamPackageDir, 'dist/index.js'),
  resolve(upstreamPackageDir, 'src/paper/LIFDeterminismProbe.ts'),
  resolve(upstreamPackageDir, 'src/paper/__tests__/LIFTwinTest.test.ts'),
  resolve(upstreamPackageDir, 'src/poc/cpu-reference.ts'),
  resolve(upstreamPackageDir, 'src/shaders/lif-neuron.wgsl'),
  dawnModule,
  resolve(dirname(dawnModule), 'dist/linux-x64.dawn.node'),
  doeModule,
  resolve(doeRoot, 'runtime/zig/zig-out/lib/libwebgpu_doe.so'),
];
const immutableInputs = await Promise.all(immutablePaths.map(async (path) => ({
  path: path.startsWith(`${doeRoot}/`) ? path.slice(doeRoot.length + 1) : path,
  sha256: await sha256File(path),
})));

const laneSpecs = [
  ['I0', 'dawn-node-webgpu', 'untraced', ambientDawnModule],
  ['I1', 'dawn-node-webgpu', 'untraced', dawnModule],
  ['W0', 'dawn-node-webgpu', 'enabled', dawnModule],
  ['D0', 'doe-gpu', 'enabled', dawnModule],
];
const runs = [];
for (const [laneId, provider, receiptMode, modulePath] of laneSpecs) {
  for (let index = 0; index < inputs.cleanProcessRuns; index += 1) {
    runs.push(await runCleanProcess(laneId, provider, receiptMode, modulePath));
  }
}

const w0 = runs.find((run) => run.laneId === 'W0');
const d0 = runs.find((run) => run.laneId === 'D0');
const w0Replay = await runCleanProcess('W0', 'dawn-node-webgpu', 'enabled', dawnModule);
const d0Replay = await runCleanProcess('D0', 'doe-gpu', 'enabled', dawnModule);
const w0Expected = sha256Text(JSON.stringify(semanticEvidence(w0)));
const w0Actual = sha256Text(JSON.stringify(semanticEvidence(w0Replay)));
const d0Expected = sha256Text(JSON.stringify(semanticEvidence(d0)));
const d0Actual = sha256Text(JSON.stringify(semanticEvidence(d0Replay)));
const crossProviderIdentity = providerOutputIdentity(w0);
const crossProviderExact = sha256Text(JSON.stringify(crossProviderIdentity))
  === sha256Text(JSON.stringify(providerOutputIdentity(d0)));
const lanePasses = laneSpecs.every(([laneId, provider]) => (
  runs.filter((run) => run.laneId === laneId).length === inputs.cleanProcessRuns
  && runs.filter((run) => run.laneId === laneId)
    .every((run) => runPasses(run, provider))
));
const replayPasses = runPasses(w0Replay, 'dawn-node-webgpu')
  && runPasses(d0Replay, 'doe-gpu')
  && w0Expected === w0Actual
  && d0Expected === d0Actual;

const artifact = {
  schemaVersion: 1,
  artifactKind: 'holoscript-lif-determinism-matrix',
  generatedAt: new Date().toISOString(),
  status: lanePasses && replayPasses && crossProviderExact ? 'passed' : 'failed',
  upstream: {
    repositoryUrl: harness.upstream.repositoryUrl,
    commit: harness.upstream.commit,
    licenseIdentifier: harness.upstream.license.identifier,
  },
  host: {
    platform: process.platform,
    architecture: process.arch,
    node: process.version,
  },
  providers: {
    ambient: { id: 'dawn-node-webgpu', modulePath: ambientDawnModule },
    baseline: { id: 'dawn-node-webgpu', modulePath: dawnModule },
    comparison: { id: 'doe-gpu', modulePath: doeModule },
  },
  immutableInputs,
  contract: {
    cleanProcessRuns: inputs.cleanProcessRuns,
    timeoutMs,
    maxOutputBytes,
    independentCpuMembraneOracle: true,
    exactSpikeMaskOracle: true,
    sameBackendRepeatCount: 3,
    hardwareRequired: true,
  },
  lanes: {
    I0: summarizeLane(runs, 'I0', 'dawn-node-webgpu'),
    I1: summarizeLane(runs, 'I1', 'dawn-node-webgpu'),
    W0: summarizeLane(runs, 'W0', 'dawn-node-webgpu'),
    D0: summarizeLane(runs, 'D0', 'doe-gpu'),
    P0: {
      status: 'not-required',
      reason: 'W0 passes every frozen oracle and determinism obligation.',
    },
  },
  replay: {
    W0: {
      status: w0Expected === w0Actual ? 'passed' : 'failed',
      expectedEvidenceSha256: w0Expected,
      actualEvidenceSha256: w0Actual,
    },
    D0: {
      status: d0Expected === d0Actual ? 'passed' : 'failed',
      expectedEvidenceSha256: d0Expected,
      actualEvidenceSha256: d0Actual,
    },
  },
  crossProvider: {
    exactGpuOutputIdentity: crossProviderExact,
    identity: crossProviderIdentity,
  },
  runtimeOwnershipAssessment: {
    claimedProperty: harness.runtimeOwnershipPlan.claimedProperty,
    uniqueRuntimeOutcome: false,
    decision: 'retain-diagnostic',
    reason: 'W0 and D0 satisfy the same CPU, spike-mask, repeatability, and replay outcomes.',
    runtimeOwnershipCredit: false,
  },
  decision: {
    compatibilityEvidence: lanePasses,
    determinismEvidence: lanePasses && replayPasses,
    runtimeOwnershipCredit: false,
    applicationPromotionCredit: false,
    performanceCredit: false,
    releaseCredit: false,
    nextGate: 'retain-lif-determinism-regression-and-close-runtime-ownership-hypothesis',
  },
  limitations: [
    'This is one AMD Vulkan adapter and does not establish cross-vendor byte identity.',
    'The original upstream cross-vendor runner has a broken relative dist import; this harness calls the exported production implementation directly.',
    'Three clean processes per lane remain below the promotion reliability floor.',
    'No selected-operation performance comparison was run.',
    'A repository-owned diagnostic does not prove external adoption.',
  ],
};

await mkdir(dirname(outputPath), { recursive: true });
await writeFile(outputPath, `${JSON.stringify(artifact, null, 2)}\n`, { flag: 'wx' });
process.stdout.write(`${outputPath}\n`);
if (artifact.status !== 'passed') process.exitCode = 1;

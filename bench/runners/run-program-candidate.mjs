// Parent-owned numerical acceptance; child WGSL cannot replace the job's oracle.
import { readFileSync, writeFileSync, mkdirSync, copyFileSync } from 'node:fs';
import { resolve, basename } from 'node:path';
import { createHash } from 'node:crypto';
import { createRequestProcess } from '../../packages/doe-gpu/src/node-process-requests.js';
import { stats } from '../shared/lib/stats.js';
import { compareNumerical } from '../oracles/compute-programs.mjs';

const [outputPath, packagePath, backend, execution] = process.argv.slice(2);
if (!outputPath || !packagePath || !['vulkan', 'metal'].includes(backend)
    || !['gpu-recorded', 'native-recorded', 'webgpu'].includes(execution)) {
  throw new Error('Expected output-directory package-root vulkan|metal execution');
}
const output = resolve(outputPath);
const job = JSON.parse(readFileSync(resolve(output, 'job.json')));
const descriptor = JSON.parse(readFileSync(resolve(output, 'program.json')));
const qualification = JSON.parse(readFileSync(resolve(output, 'package-inputs/summary.json')));
const hash = (data) => createHash('sha256').update(data).digest('hex');
const save = (name, data) => writeFileSync(resolve(output, name), `${JSON.stringify(data, null, 2)}\n`);
const workers = new Map();
const report = { schemaVersion: 1, kind: 'program_candidate', claimStatus: 'diagnostic',
  status: 'running', error: null, jobHash: hash(readFileSync(resolve(output, 'job.json'))),
  candidateHash: hash(readFileSync(resolve(output, 'candidate.wgsl'))), backend, execution,
  preparation: {}, teardown: {}, environment: null, cases: [],
  timingScope: 'worker-input-clone-through-float32-result-including-gpu-readback',
  limits: [
    'Trusted reference module and declared dependencies are hash-bound; this is not an OS sandbox or a complete dependency closure',
    'Heap limit covers JavaScript; declared buffers and sampled process RSS are not peak GPU memory',
    'CPU reference comparison is not a Dawn/wgpu comparison or production promotion',
    'Process deadlines cannot preempt GPU kernels or prove recovery from a hung driver',
    'Initialization, preparation, first invocation per case, and teardown are separate; the prepared program survives between cases',
    'Native identity journaling remains enabled during candidate timing and contributes to its measured cost',
  ],
};
let deadlineError;
function abort(error) {
  deadlineError = error;
  for (const worker of workers.values()) worker.abort(error);
}
const deadline = setTimeout(() => abort(new Error('Candidate job deadline exceeded')), job.limits.jobTimeoutMs);
const signalHandlers = new Map(['SIGINT', 'SIGTERM'].map((signal) => {
  const handler = () => abort(new Error(`Candidate controller received ${signal}`));
  process.on(signal, handler);
  return [signal, handler];
}));

function child(mode) {
  const worker = createRequestProcess({ entrypoint: new URL('./program-candidate-worker.mjs', import.meta.url),
    requestTimeoutMs: job.limits.requestTimeoutMs, maximumHeapMiB: job.limits.maximumHeapMiB,
    maximumProcessOutputBytes: job.limits.maximumProcessOutputBytes });
  workers.set(mode, worker);
  return worker;
}

async function sample(worker, mode, caseId, phase, index, inputs, expected) {
  if (deadlineError) throw deadlineError;
  const rpcStart = performance.now();
  const result = await worker.call('run', { inputs });
  const rpcMs = performance.now() - rpcStart;
  const bytes = new Uint8Array(result.data);
  if (bytes.byteLength !== expected.length * Float32Array.BYTES_PER_ELEMENT) {
    throw new Error(`${caseId}/${mode} output extent differs from the frozen oracle`);
  }
  const numerical = compareNumerical(new Float32Array(bytes.buffer), expected,
    job.oracle.absoluteTolerance, job.oracle.relativeTolerance);
  const path = `outputs/${caseId}-${mode}-${phase}-${index}.f32`;
  writeFileSync(resolve(output, path), bytes);
  return { mode, phase, index, elapsedMs: result.elapsedMs, cpuMs: result.cpuMs,
    rpcMs, processRssBytes: result.processRssBytes, receipt: result.receipt,
    output: { path, hash: hash(bytes) }, numerical };
}

try {
  mkdirSync(resolve(output, 'outputs'));
  const referenceStart = performance.now();
  const reference = child('reference');
  report.preparation.reference = await reference.call('initialize', { mode: 'reference',
    referencePath: resolve(output, 'inputs', job.reference.path), packageRoot: packagePath });
  report.preparation.reference.processPreparationMs = performance.now() - referenceStart;
  const candidateStart = performance.now();
  const candidate = child('candidate');
  writeFileSync(resolve(output, 'native.jsonl'), '');
  report.preparation.candidate = await candidate.call('initialize', { mode: 'candidate',
    descriptor, packageRoot: packagePath, backend, execution, tracePath: resolve(output, 'native.jsonl') });
  report.preparation.candidate.processPreparationMs = performance.now() - candidateStart;
  report.environment = await candidate.call('environment');
  const libraryHashes = new Set(qualification.hosts.map((host) => host.libraryHash));
  if (libraryHashes.size !== 1 || !report.environment.loadedObjects.some((entry) => libraryHashes.has(entry.hash))) {
    throw new Error('Loaded native library differs from the exact qualified archives');
  }
  mkdirSync(resolve(output, 'provider-binaries'));
  for (const entry of report.environment.loadedObjects) {
    if (libraryHashes.has(entry.hash) || entry.path.endsWith('/doe_napi.node')) {
      const target = resolve(output, 'provider-binaries', `${entry.hash}-${basename(entry.path)}`);
      copyFileSync(entry.path, target);
      if (hash(readFileSync(target)) !== entry.hash) throw new Error('Native object changed during retention');
    }
  }
  for (const fixture of job.cases) {
    const inputs = Object.fromEntries(Object.entries(fixture.inputs)
      .map(([key, value]) => [key, readFileSync(resolve(output, 'inputs', value.path))]));
    const expectedBytes = readFileSync(resolve(output, 'inputs', fixture.expected.path));
    const expected = new Float64Array(Uint8Array.from(expectedBytes).buffer);
    const row = { id: fixture.id, samples: [], referenceStatsMs: null, candidateStatsMs: null,
      ratios: null, preparationRecoveryRuns: null, accepted: false };
    report.cases.push(row);
    const phases = [['first', 1], ['warmup', job.sampling.warmupRuns], ['timed', job.sampling.timedRuns]];
    for (const [phase, count] of phases) {
      for (let index = 0; index < count; index += 1) {
        // Alternate execution order without overlapping competing measurements.
        const modes = index % 2 ? ['candidate', 'reference'] : ['reference', 'candidate'];
        for (const mode of modes) {
          const measured = await sample(workers.get(mode), mode, fixture.id, phase, index, inputs, expected);
          row.samples.push(measured);
          if (!measured.numerical.passed) throw new Error(`${fixture.id}/${mode}/${phase}/${index} failed frozen numerical acceptance`);
        }
      }
    }
    for (const mode of ['reference', 'candidate']) {
      row[`${mode}StatsMs`] = stats(row.samples.filter((value) => value.mode === mode && value.phase === 'timed')
        .map((value) => value.elapsedMs));
    }
    row.ratios = { p50: row.referenceStatsMs.median / row.candidateStatsMs.median,
      p95: row.referenceStatsMs.p95 / row.candidateStatsMs.p95 };
    const savings = row.referenceStatsMs.median - row.candidateStatsMs.median;
    const overhead = Math.max(0, report.preparation.candidate.processPreparationMs
      - report.preparation.reference.processPreparationMs
      + row.samples.find((value) => value.mode === 'candidate' && value.phase === 'first').elapsedMs
      - row.samples.find((value) => value.mode === 'reference' && value.phase === 'first').elapsedMs);
    row.preparationRecoveryRuns = savings > 0 ? Math.ceil(overhead / savings) : null;
    row.accepted = row.ratios.p50 >= job.performance.minimumP50Ratio
      && row.ratios.p95 >= job.performance.minimumP95Ratio
      && row.preparationRecoveryRuns !== null
      && row.preparationRecoveryRuns <= job.performance.maximumPreparationRecoveryRuns;
  }
  report.environment = await candidate.call('environment');
  report.status = report.cases.every((row) => row.accepted) ? 'accepted' : 'rejected';
} catch (error) {
  report.status = 'rejected';
  report.error = { code: error.code ?? 'DOE_CANDIDATE_REJECTED', message: error.message };
} finally {
  for (const [mode, worker] of workers) {
    try {
      if (!deadlineError) report.teardown[mode] = await worker.call('close');
    } catch (error) {
      report.status = 'rejected';
      report.error ??= { code: 'DOE_CANDIDATE_CLEANUP', message: error.message };
    } finally { worker.abort(); }
  }
  clearTimeout(deadline);
  for (const [signal, handler] of signalHandlers) process.off(signal, handler);
  save('execution.json', report);
}
process.exitCode = report.status === 'accepted' ? 0 : 1;

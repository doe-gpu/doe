// Freeze the upstream neuron program and oracle before any provider executes.
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { hashBytes, validateComputeProgram } from '../../../packages/doe-gpu/src/compute-program-contract.js';

if (process.argv.includes('--help')) {
  console.log('Prepare a pinned LIF program before evaluation. Required: --upstream=<prepared HoloScript checkout> --output=<new directory> --case=<lif-determinism.inputs.json case ID>. Optional: --sequence-runs=<oracle states for initialize-once resident execution>');
  process.exit(0);
}
const args = Object.fromEntries(process.argv.slice(2).map((arg) => {
  const split = arg.indexOf('=');
  if (!arg.startsWith('--') || split < 0) throw new Error('Expected --upstream= --output= --case=');
  return [arg.slice(2, split), arg.slice(split + 1)];
}));
if (Object.keys(args).some((key) => !['upstream', 'output', 'case', 'sequence-runs'].includes(key))
    || !args.upstream || !args.output || !args.case) {
  throw new Error('Required: --upstream=<pinned checkout> --output=<new directory> --case=<frozen LIF case>');
}
const sequenceRuns = args['sequence-runs'] === undefined ? null : Number(args['sequence-runs']);
if (sequenceRuns !== null && (!Number.isSafeInteger(sequenceRuns) || sequenceRuns < 1)) {
  throw new Error('--sequence-runs must be a positive safe integer');
}
const here = dirname(fileURLToPath(import.meta.url));
const harness = JSON.parse(readFileSync(resolve(here, 'lif-determinism.harness.json')));
const cases = JSON.parse(readFileSync(resolve(here, 'lif-determinism.inputs.json')));
const testCase = cases.cases.find((item) => item.id === args.case);
if (!testCase) throw new Error(`Unknown frozen case ${args.case}`);
const sourceRoot = resolve(args.upstream);
const output = resolve(args.output);
mkdirSync(output, { recursive: false });
function retain(name, bytes) {
  const path = resolve(output, name);
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, bytes, { flag: 'wx' });
  return { path: name, hash: hashBytes(bytes) };
}
const sources = [];
function pinnedSource(path) {
  // Read the Git object, so a dirty checkout cannot silently alter the fixture.
  const bytes = execFileSync('git', ['-C', sourceRoot, 'show', `${harness.upstream.commit}:${path}`]);
  sources.push(retain(`upstream/${path}`, bytes));
  return bytes.toString('utf8');
}
const prefix = 'packages/snn-webgpu/src';
const shader = pinnedSource(`${prefix}/shaders/lif-neuron.wgsl`);
const types = pinnedSource(`${prefix}/types.ts`);
const cpuSource = pinnedSource(`${prefix}/poc/cpu-reference.ts`);
pinnedSource('LICENSE');
const packagePath = 'packages/snn-webgpu/package.json';
const packageContract = JSON.parse(pinnedSource(packagePath));
const require = createRequire(resolve(sourceRoot, packagePath));
const typescript = require('typescript');
if (typescript.version !== packageContract.devDependencies.typescript.replace(/^~/, '')) {
  throw new Error(`Expected pinned TypeScript ${packageContract.devDependencies.typescript}; received ${typescript.version}`);
}
sources.push(retain('toolchain/typescript.cjs', readFileSync(require.resolve('typescript'))));
sources.push(retain('toolchain/typescript.LICENSE.txt', readFileSync(resolve(dirname(require.resolve('typescript')), '../LICENSE.txt'))));
for (const name of ['lif-determinism.harness.json', 'lif-determinism.inputs.json', 'lif-determinism.oracle.md']) {
  sources.push(retain(`contract/${name}`, readFileSync(resolve(here, name))));
}
sources.push(retain('generator.mjs', readFileSync(new URL(import.meta.url))));
for (const [name, source] of [['types', types], ['poc/cpu-reference', cpuSource]]) {
  const compiled = typescript.transpileModule(source, {
    compilerOptions: { target: typescript.ScriptTarget.ES2022, module: typescript.ModuleKind.ES2022 },
    reportDiagnostics: true,
  });
  if (compiled.diagnostics.some((item) => item.category === typescript.DiagnosticCategory.Error)) {
    throw new Error(`Upstream oracle transpilation failed for ${name}`);
  }
  sources.push(retain(`oracle/${name}.js`, compiled.outputText));
}
sources.push(retain('oracle/package.json', '{"type":"module"}\n'));
const { CPUReferenceSimulator, generateSynapticInput } = await import(pathToFileURL(resolve(output, 'oracle/poc/cpu-reference.js')));
const { DEFAULT_LIF_PARAMS } = await import(pathToFileURL(resolve(output, 'oracle/types.js')));
const params = { ...DEFAULT_LIF_PARAMS, ...testCase.params };
const count = testCase.neuronCount;
const stimulus = generateSynapticInput(count, testCase.stimulusSeed, testCase.stimulusMin, testCase.stimulusMax);
const cpu = new CPUReferenceSimulator(count, testCase.params);
cpu.stepN(testCase.tickCount, stimulus);
const expected = new Float64Array(count * 2);
expected.set(cpu.getMembraneV());
expected.set(cpu.getSpikes(), count);
const expectedReference = retain('expected.f64', new Uint8Array(expected.buffer));
const expectedSequence = [expectedReference];
for (let run = 1; run < (sequenceRuns ?? 1); run += 1) {
  cpu.stepN(testCase.tickCount, stimulus);
  expected.set(cpu.getMembraneV());
  expected.set(cpu.getSpikes(), count);
  expectedSequence.push(retain(`sequence/run-${run + 1}.expected.f64`, new Uint8Array(expected.buffer)));
}
const uniform = new ArrayBuffer(32);
new Float32Array(uniform).set([params.tau, params.vThreshold, params.vReset, params.vRest, params.dt]);
new Uint32Array(uniform)[5] = count;
const values = {
  params: new Uint8Array(uniform),
  membrane: new Float32Array(count).fill(params.vRest),
  stimulus,
};
const inputs = Object.fromEntries(Object.entries(values).map(([id, value]) => [id,
  retain(`inputs/${id}.bin`, new Uint8Array(value.buffer, value.byteOffset, value.byteLength)),
]));
const step = { shader: 'lif', bindings: [
  { binding: 0, buffer: 'params' }, { binding: 1, buffer: 'membrane' },
  { binding: 2, buffer: 'stimulus' }, { binding: 3, buffer: 'spikes' },
  { binding: 4, buffer: 'refractory' },
], workgroups: [Math.ceil(count / 256), 1, 1] };
const descriptor = {
  schemaVersion: 1, id: 'holoscript_lif',
  buffers: [
    { id: 'params', size: uniform.byteLength, type: 'uniform', role: 'input' },
    ...['membrane', 'stimulus'].map((id) => ({ id, size: count * 4, type: 'storage', role: 'input' })),
    ...['spikes', 'refractory'].map((id) => ({ id, size: count * 4, type: 'storage', role: 'scratch' })),
    { id: 'output', size: count * 8, type: 'storage', role: 'output' },
  ],
  shaders: [
    { id: 'lif', entryPoint: 'lif_step', code: shader },
    { id: 'pack', entryPoint: 'main', code: `
      @group(0) @binding(0) var<storage, read> membrane: array<f32>;
      @group(0) @binding(1) var<storage, read> spikes: array<f32>;
      @group(0) @binding(2) var<storage, read_write> output: array<f32>;
      @compute @workgroup_size(256) fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
        let n = arrayLength(&membrane);
        if (gid.x < n) { output[gid.x] = membrane[gid.x]; output[n + gid.x] = spikes[gid.x]; }
      }` },
  ],
  steps: [...Array.from({ length: testCase.tickCount }, () => step), {
    shader: 'pack', bindings: [{ binding: 0, buffer: 'membrane' }, { binding: 1, buffer: 'spikes' },
      { binding: 2, buffer: 'output' }], workgroups: step.workgroups,
  }], output: 'output',
};
if (sequenceRuns !== null) {
  descriptor.schemaVersion = 2;
  descriptor.id = 'holoscript_lif_resident';
  for (const buffer of descriptor.buffers) buffer.lifetime = 'program';
}
validateComputeProgram(descriptor);
const fixture = {
  schemaVersion: sequenceRuns === null ? 1 : 2, kind: 'compute_program_fixture', application: descriptor.id,
  sourceRepo: harness.upstream.repositoryUrl, sourceCommit: harness.upstream.commit,
  caseId: testCase.id, generatorRuntime: `${process.version}; TypeScript ${typescript.version}`,
  adaptation: 'Unchanged lif_step WGSL and upstream CPU twin; declared ticks are batched, with an added packing pass preserving both membrane and spike readbacks on every provider.',
  program: retain('program.json', `${JSON.stringify(descriptor, null, 2)}\n`), inputs,
  expected: expectedReference, sources,
  checks: [
    { offset: 0, count, mode: 'both', absoluteTolerance: cases.absoluteTolerance,
      relativeTolerance: cases.relativeTolerance, relativeEpsilon: 1e-6 },
    { offset: count, count, mode: 'exact', absoluteTolerance: 0, relativeTolerance: 0, relativeEpsilon: 0 },
  ],
};
if (sequenceRuns !== null) {
  fixture.sequence = { inputs: 'initialize-once', expected: expectedSequence };
  fixture.adaptation += ' All buffers persist across invocations; inputs are uploaded only at initialization. The upstream CPU twin advances continuously and freezes every invocation oracle before GPU execution.';
}
const reference = retain('fixture.json', `${JSON.stringify(fixture, null, 2)}\n`);
console.log(JSON.stringify({ path: resolve(output, reference.path), hash: reference.hash }));

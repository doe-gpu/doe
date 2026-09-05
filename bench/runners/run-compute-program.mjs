// One physical provider/process run; comparison and promotion are separate.
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { createHash } from 'node:crypto';
import { performance } from 'node:perf_hooks';
import process from 'node:process';
import { prepareComputeProgram } from '../../packages/doe-gpu/src/compute-program.js';
import { registerTimestampSource } from '../../packages/doe-gpu/src/compute-program-timing.js';
import { imageEdgesProgram, heatDiffusionProgram } from '../../packages/doe-gpu/examples/compute-programs.js';
import { imageEdgesOracle, heatDiffusionOracle, compareNumerical } from '../oracles/compute-programs.mjs';
import { stats } from '../shared/lib/stats.js';

const args = Object.fromEntries(process.argv.slice(2).map((arg) => {
  const split = arg.indexOf('=');
  if (!arg.startsWith('--') || split === -1) throw new Error(`Expected --name=value: ${arg}`);
  return [arg.slice(2, split), arg.slice(split + 1)];
}));
const allowed = new Set(['provider', 'application', 'policy', 'output', 'phase', 'backend']);
if (Object.keys(args).some((key) => !allowed.has(key) && key !== 'hardware') || [...allowed].some((key) => !(key in args))) {
  throw new Error('Required: --provider= --application= --policy= --output= --phase=audit|measure --backend=vulkan|metal');
}
const policyBytes = readFileSync(args.policy);
const policy = JSON.parse(policyBytes);
const gpuTiming = policy.gpuTiming ?? 'off';
const deviceDescriptor = { requiredFeatures: gpuTiming === 'timestamp-query' ? ['timestamp-query'] : [] };
if (policy.percentileMethod !== 'nearest-rank') throw new Error('This runner requires the nearest-rank percentile policy');
if (!policy.providers.includes(args.provider) || !policy.applications.includes(args.application)
    || !['audit', 'measure'].includes(args.phase) || !['vulkan', 'metal'].includes(args.backend)) {
  throw new Error('Unknown provider, application, phase, or backend');
}
const hash = (bytes) => createHash('sha256').update(bytes).digest('hex');
mkdirSync(dirname(args.output), { recursive: true });
const { width, height, heatIterations } = policy;
let descriptor = args.application === 'image_edges'
  ? imageEdgesProgram(width, height) : heatDiffusionProgram(width, height, heatIterations);
const input = Float32Array.from({ length: width * height }, (_, i) => {
  const x = i % width;
  const y = Math.floor(i / width);
  return args.application === 'image_edges'
    ? ((x * 17 + y * 31) % 256) / 255
    : Math.exp(-((x - width * 0.5) ** 2 + (y - height * 0.5) ** 2) / (width * height * 0.01));
});
let expected = args.application === 'image_edges'
  ? imageEdgesOracle(input, width, height) : heatDiffusionOracle(input, width, height, heatIterations);
let inputs = { input };
let checks = [];
let expectedSequence = null;
const fixtureReference = policy.fixtures?.[args.application];
if (fixtureReference) {
  const fixtureBytes = readFileSync(fixtureReference.path);
  if (hash(fixtureBytes) !== fixtureReference.hash) throw new Error('Frozen fixture identity changed');
  const fixture = JSON.parse(fixtureBytes);
  if (fixture.application !== args.application) throw new Error('Fixture application mismatch');
  const bytes = (reference) => {
    const value = readFileSync(resolve(dirname(fixtureReference.path), reference.path));
    if (hash(value) !== reference.hash) throw new Error(`Fixture bytes changed: ${reference.path}`);
    return value;
  };
  descriptor = JSON.parse(bytes(fixture.program));
  inputs = Object.fromEntries(Object.entries(fixture.inputs).map(([id, reference]) => [id, bytes(reference)]));
  const expectedBytes = bytes(fixture.expected);
  expected = new Float64Array(expectedBytes.buffer.slice(expectedBytes.byteOffset, expectedBytes.byteOffset + expectedBytes.byteLength));
  checks = fixture.checks;
  if (fixture.sequence) {
    if (fixture.schemaVersion !== 2 || fixture.sequence.inputs !== 'initialize-once'
        || descriptor.buffers.some((buffer) => buffer.lifetime !== 'program')) {
      throw new Error('Resident sequence requires initialize-once inputs and program-lifetime buffers');
    }
    expectedSequence = fixture.sequence.expected.map((reference) => {
      const value = bytes(reference);
      return new Float64Array(value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength));
    });
    const requiredRuns = args.phase === 'audit' ? 3 : 1 + policy.warmupRuns + policy.timedRuns;
    if (expectedSequence.length < requiredRuns) throw new Error('Frozen sequence is shorter than the declared execution');
  }
} else if (!['image_edges', 'heat_diffusion'].includes(args.application)) {
  throw new Error(`Application requires a frozen fixture: ${args.application}`);
}
writeFileSync(`${args.output}.program.json`, `${JSON.stringify(descriptor, null, 2)}\n`);
const inputPaths = Object.fromEntries(Object.entries(inputs).map(([id, value]) => {
  const path = `${args.output}.${id}.input.bin`;
  writeFileSync(path, value);
  return [id, path];
}));
writeFileSync(`${args.output}.expected.f64`, new Uint8Array(Float64Array.from(expected).buffer));
const report = {
  schemaVersion: 4, kind: 'compute_program_evaluation', claimStatus: 'diagnostic',
  provider: args.provider, application: args.application, phase: args.phase, backend: args.backend,
  policyHash: hash(policyBytes), programPath: `${args.output}.program.json`, inputPaths,
  fixturePath: fixtureReference?.path ?? null,
  runtime: typeof Deno === 'undefined' ? { name: process.versions.bun ? 'bun' : 'node', version: process.versions.bun ?? process.version }
    : { name: 'deno', version: Deno.version.deno },
  status: 'running', error: null, samples: [], warmups: [], lifecycleRuns: [], cold: null, failedRun: null,
  preparationMs: null, deviceStartupMs: null,
  adapter: null, providerArtifact: null, allocatedBufferBytes: null, peakProcessRssBytes: null,
  providerAddonArtifact: null,
  timestampCalibrationArtifact: null,
  lifecycle: null, observed: { dispatchesEncoded: 0, submissions: 0, maps: 0 },
  latencyStatsMs: null, cpuStatsMs: null, programHash: null, teardownMs: null,
  gpuStatsNs: null,
  expectedPath: `${args.output}.expected.f64`, preparation: null,
  measurementLimits: [gpuTiming === 'off' ? 'GPU timestamps disabled by policy' : 'GPU timestamps bracket compute only; useful-operation wall includes all runtime and readback work',
    'Peak device memory unavailable; requested buffers and process RSS reported',
    'Forced device loss is not an observed driver-loss recovery', 'Dawn and wgpu adapter APIs do not expose a numeric driver version'],
};
let program;
let device;
let providerOwner;
try {
  const startup = performance.now();
  if (args.provider.startsWith('doe-')) {
    const native = await import('../../packages/doe-gpu/src/native.js');
    const adapter = await native.requestAdapter({ backend: args.backend });
    device = await adapter.requestDevice(deviceDescriptor);
    const provider = native.providerInfo();
    report.providerArtifact = { path: provider.doeLibraryPath, hash: hash(readFileSync(provider.doeLibraryPath)) };
    const addonPath = process.report?.getReport().sharedObjects.find((path) => path.endsWith('/doe_napi.node'));
    if (!addonPath) throw new Error('Loaded Doe addon identity is unavailable from this host');
    const addonHash = hash(readFileSync(addonPath));
    const retainedAddon = resolve(dirname(args.output), `doe.${addonHash}.addon.node`);
    if (!existsSync(retainedAddon)) writeFileSync(retainedAddon, readFileSync(addonPath), { flag: 'wx' });
    if (hash(readFileSync(retainedAddon)) !== addonHash) throw new Error('Retained addon bytes changed');
    report.providerAddonArtifact = { path: retainedAddon, hash: addonHash };
  } else if (args.provider === 'dawn') {
    const dawn = await import('webgpu');
    const features = policy.dawnTimestampQuantization === 'disabled'
      ? ['disable-dawn-features=timestamp_quantization'] : [];
    providerOwner = dawn.create([`backend=${args.backend}`, ...features]);
    const adapter = await providerOwner.requestAdapter({ powerPreference: 'high-performance' });
    device = await adapter.requestDevice(deviceDescriptor);
    report.adapter = adapter.info;
    const filename = process.platform === 'darwin' ? 'darwin-universal' : `${process.platform}-${process.arch}`;
    const artifactPath = resolve(`bench/node_modules/webgpu/dist/${filename}.dawn.node`);
    report.providerArtifact = { path: artifactPath, hash: hash(readFileSync(artifactPath)) };
  } else {
    if (typeof Deno === 'undefined' || Deno.version.deno !== policy.denoVersion) {
      throw new Error(`wgpu control requires Deno ${policy.denoVersion}`);
    }
    const adapter = await navigator.gpu.requestAdapter({ powerPreference: 'high-performance' });
    if (!adapter) throw new Error('wgpu physical adapter unavailable');
    device = await adapter.requestDevice(deviceDescriptor);
    report.adapter = adapter.info;
    report.providerArtifact = { path: Deno.execPath(), hash: hash(readFileSync(Deno.execPath())) };
  }
  report.deviceStartupMs = performance.now() - startup;
  const retainedProviderPath = resolve(dirname(args.output), `${args.provider}.${report.providerArtifact.hash}.provider.bin`);
  if (!existsSync(retainedProviderPath)) {
    writeFileSync(retainedProviderPath, readFileSync(report.providerArtifact.path), { flag: 'wx' });
  }
  if (hash(readFileSync(retainedProviderPath)) !== report.providerArtifact.hash) throw new Error('Retained provider bytes changed');
  report.providerArtifact.path = retainedProviderPath;
  const info = report.adapter ?? device._adapterInfo ?? device.adapterInfo;
  report.adapter = Object.fromEntries(['vendor', 'architecture', 'device', 'description',
    'isFallbackAdapter', 'vendorID', 'deviceID', 'driverVersion'].map((key) => [key, info?.[key] ?? null]));
  const name = `${report.adapter.description} ${report.adapter.device}`;
  if (report.adapter.isFallbackAdapter === true || /llvmpipe|swiftshader|software/i.test(name)
      || !(args.backend === 'vulkan' ? /AMD|Radeon/i : /Apple/i).test(`${report.adapter.vendor} ${name}`)) {
    throw new Error(`Required physical ${args.backend} adapter; received ${JSON.stringify(report.adapter)}`);
  }
  if (gpuTiming !== 'off' && args.backend === 'vulkan') {
    if (!args.hardware) throw new Error('Timed Vulkan evaluation requires a retained vulkaninfo JSON profile');
    const profileBytes = readFileSync(args.hardware);
    report.timestampCalibrationArtifact = { path: resolve(args.hardware), hash: hash(profileBytes) };
    const physical = JSON.parse(profileBytes).capabilities.device;
    const properties = physical.properties.VkPhysicalDeviceProperties;
    if (args.provider === 'wgpu' && policy.wgpuTimestampUnits === 'vulkan-ticks') {
      if (Number(report.adapter.vendor) !== properties.vendorID || Number(report.adapter.device) !== properties.deviceID) {
        throw new Error('wgpu timestamp calibration belongs to a different physical adapter');
      }
      const bits = new Set(physical.queueFamiliesProperties.map((family) => family.VkQueueFamilyProperties)
        .filter((family) => family.queueFlags.includes('VK_QUEUE_COMPUTE_BIT')).map((family) => family.timestampValidBits));
      if (bits.size !== 1 || bits.has(0)) throw new Error('wgpu timestamp counter width requires an unambiguous compute queue contract');
      registerTimestampSource(device, { periodNs: properties.limits.timestampPeriod,
        validBits: [...bits][0], source: 'wgpu-vulkan-query-ticks' });
    }
  }
  if (args.phase === 'audit') {
    const createEncoder = device.createCommandEncoder.bind(device);
    device.createCommandEncoder = (...values) => {
      const encoder = createEncoder(...values);
      const begin = encoder.beginComputePass.bind(encoder);
      encoder.beginComputePass = (...descs) => {
        const pass = begin(...descs);
        const dispatch = pass.dispatchWorkgroups.bind(pass);
        pass.dispatchWorkgroups = (...counts) => { report.observed.dispatchesEncoded += 1; return dispatch(...counts); };
        return pass;
      };
      return encoder;
    };
    const submit = device.queue.submit.bind(device.queue);
    device.queue.submit = (...values) => { report.observed.submissions += 1; return submit(...values); };
    const createBuffer = device.createBuffer.bind(device);
    device.createBuffer = (...values) => {
      const buffer = createBuffer(...values);
      const map = buffer.mapAsync.bind(buffer);
      buffer.mapAsync = (...mapArgs) => { report.observed.maps += 1; return map(...mapArgs); };
      return buffer;
    };
  }
  const execution = args.provider === 'doe-recorded' ? policy.preparedExecution : 'webgpu';
  program = await prepareComputeProgram(device, descriptor, { execution, gpuTiming });
  report.programHash = program.programHash;
  report.preparationMs = program.preparationMs;
  report.preparation = program.preparation;
  report.allocatedBufferBytes = program.allocatedBufferBytes;
  let completedRuns = 0;
  async function runOne() {
    const expectedForRun = expectedSequence ? expectedSequence[completedRuns] : expected;
    if (!expectedForRun) throw new Error('Frozen sequence has no oracle for the next invocation');
    const start = performance.now();
    const cpuStart = process.cpuUsage();
    const result = await program.run(expectedSequence && completedRuns > 0 ? {} : inputs);
    const cpu = process.cpuUsage(cpuStart);
    const wallMs = performance.now() - start;
    const oracle = compareNumerical(new Float32Array(result.output.buffer), expectedForRun,
      policy.absoluteTolerance, policy.relativeTolerance, checks);
    const outputPath = `${args.output}.run-${result.receipt.run}.output.f32`;
    writeFileSync(outputPath, result.output);
    const sample = { wallMs, cpuMs: (cpu.user + cpu.system) / 1000, oracle, receipt: result.receipt, outputPath };
    if (!oracle.passed) {
      report.failedRun = sample;
      throw new Error(`Numerical oracle failed: ${JSON.stringify(oracle)}`);
    }
    completedRuns += 1;
    return sample;
  }
  report.cold = await runOne();
  const warmups = args.phase === 'audit' ? 0 : policy.warmupRuns;
  for (let i = 0; i < warmups; i += 1) report.warmups.push(await runOne());
  const sampleCount = args.phase === 'audit' ? 1 : policy.timedRuns;
  for (let i = 0; i < sampleCount; i += 1) report.samples.push(await runOne());
  report.latencyStatsMs = stats(report.samples.map((sample) => sample.wallMs));
  report.cpuStatsMs = stats(report.samples.map((sample) => sample.cpuMs));
  if (gpuTiming !== 'off') report.gpuStatsNs = stats(report.samples.map((sample) => sample.receipt.gpuTiming.elapsedNs));
  // Audits include cancellation with a subsequent successful reuse, kept out of timing samples.
  if (args.phase === 'audit') {
    const cancel = new AbortController();
    cancel.abort();
    let cancelled = false;
    try { await program.run(expectedSequence ? {} : inputs, { signal: cancel.signal }); }
    catch (error) { if (error.code !== 'DOE_PROGRAM_CANCELLED') throw error; cancelled = true; }
    report.lifecycleRuns.push(await runOne());
    report.lifecycle = { cancellationRejected: cancelled, reuseAfterCancellation: true };
  }
  report.peakProcessRssBytes = process.resourceUsage().maxRSS * 1024;
  report.status = 'passed';
} catch (error) {
  report.status = 'failed';
  report.error = String(error?.stack ?? error);
  process.exitCode = 1;
} finally {
  const teardown = performance.now();
  try {
    await program?.close();
    device?.destroy();
  } catch (error) {
    report.status = 'failed';
    report.error = `${report.error ?? ''}\nTeardown: ${error?.stack ?? error}`;
    process.exitCode = 1;
  }
  report.teardownMs = performance.now() - teardown;
  writeFileSync(args.output, `${JSON.stringify(report, null, 2)}\n`);
}
console.log(JSON.stringify({ output: args.output, status: report.status, error: report.error,
  latency: report.latencyStatsMs, cpu: report.cpuStatsMs }));

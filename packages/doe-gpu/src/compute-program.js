// Fixed-shape programs retain resources and explicitly choose their execution path.
import { performance } from 'node:perf_hooks';
import { randomUUID } from 'node:crypto';
import { setImmediate } from 'node:timers/promises';
import { globals } from './vendor/webgpu/webgpu-constants.js';
import { awaitProgramCompletion } from './compute-program-completion.js';
import { nativeProgramProvider } from './compute-program-native.js';
import { hashBytes, programError, validateComputeProgram, validateProgramOptions } from './compute-program-contract.js';
import { lifetime, outputReference, releaseEntry, inputBatch } from './compute-program-residency.js';
import { QUERY_COUNT, QUERY_BYTES, timestampInfo, timestampResult } from './compute-program-timing.js';

const { GPUBufferUsage } = globals;
const DEVICE_OPERATIONS = new WeakSet();
const DEVICE_LOSS = new WeakMap();

function deviceLoss(device) {
  let monitor = DEVICE_LOSS.get(device);
  if (!monitor) {
    monitor = { info: null };
    DEVICE_LOSS.set(device, monitor);
    device.lost.then((info) => { monitor.info = info; });
  }
  return monitor;
}

async function captureGpuErrors(device, action) {
  if (DEVICE_OPERATIONS.has(device)) {
    throw programError('DOE_PROGRAM_BUSY', 'device', 'exclusive program operation', 'device in use');
  }
  DEVICE_OPERATIONS.add(device);
  const filters = ['internal', 'out-of-memory', 'validation'];
  let pushed = 0;
  let result;
  let failure;
  try {
    for (const filter of filters) { device.pushErrorScope(filter); pushed += 1; }
    result = await action();
  } catch (error) { failure = error; }
  for (let i = 0; i < pushed; i += 1) {
    try {
      const error = await device.popErrorScope();
      if (error && !failure) {
        failure = programError('DOE_PROGRAM_GPU', 'program.execution', 'successful GPU work', error.message);
      }
    } catch (error) { failure ??= error; }
  }
  DEVICE_OPERATIONS.delete(device);
  if (failure) throw failure;
  return result;
}

/** Prepare an immutable program on an explicitly supplied device and execution path. */
async function buildComputeProgram(device, descriptor, options, previous = null) {
  const started = performance.now();
  const identity = validateComputeProgram(descriptor);
  const plan = identity.descriptor;
  const { execution, gpuTiming, readback: readbackMode } = validateProgramOptions(options);
  const native = nativeProgramProvider(device);
  if (execution !== 'webgpu' && !native) {
    throw programError('DOE_PROGRAM_UNSUPPORTED', 'device', 'Doe native recorded program provider', 'unregistered device');
  }
  if (execution === 'gpu-recorded' && !native?.gpuRecorded) {
    throw programError('DOE_PROGRAM_UNSUPPORTED', 'device.gpuRecording',
      'Vulkan GPU recording with a current addon and library', 'unavailable');
  }
  if (native && native.contractVersion < plan.schemaVersion) {
    throw programError('DOE_PROGRAM_UNSUPPORTED', 'device.runtimeContract',
      `native compute program contract ${plan.schemaVersion}; rebuild the addon and native library`, native.contractVersion);
  }
  const clock = timestampInfo(device, native, gpuTiming);
  const buffers = new Map();
  const bufferEntries = new Map();
  const programInstance = randomUUID();
  const shaders = new Map();
  const pipelines = new Map();
  const steps = [];
  const resources = new Map();
  const preparation = { reusedResources: 0, createdResources: 0 };
  function acquire(key, create) {
    if (resources.has(key)) return resources.get(key).value;
    const retained = previous?.get(key);
    const entry = retained ?? { value: create(), refs: 0, generation: 0, origin: Object.freeze({ kind: 'zero' }) };
    entry.refs += 1;
    resources.set(key, entry);
    if (retained) preparation.reusedResources += 1;
    else preparation.createdResources += 1;
    return entry.value;
  }
  let readback;
  let recording;
  let queries;
  let queryResolve;
  let state = 'preparing';
  let reason = null;
  let runs = 0;
  let active = null;
  let closed = false;
  const loss = deviceLoss(device);
  const outputSize = plan.buffers.find((buffer) => buffer.id === plan.output).size;
  const outputReadbackSize = readbackMode === 'output' ? outputSize : 0;
  const timestampOffset = Math.ceil(outputReadbackSize / BigUint64Array.BYTES_PER_ELEMENT) * BigUint64Array.BYTES_PER_ELEMENT;
  const readbackSize = clock ? timestampOffset + QUERY_BYTES : outputReadbackSize;
  const inputs = plan.buffers.filter((buffer) => buffer.role === 'input');
  const cleared = plan.buffers.filter((buffer) => buffer.role !== 'input' && lifetime(buffer) === 'invocation');
  const resident = plan.buffers.filter((buffer) => lifetime(buffer) === 'program');
  let outputReady = false;
  const owner = { device, outputSize, readers: 0, assertReadable() {
    assertReady();
    if (active || !outputReady) {
      throw programError('DOE_PROGRAM_INPUT', 'program.output', 'completed idle producer', 'unavailable output');
    }
  } };
  const allocatedBytes = plan.buffers.reduce((sum, buffer) => sum + buffer.size,
    readbackSize + (clock ? QUERY_BYTES : 0));

  function assertReady() {
    if (closed || state !== 'ready' || loss.info || native?.isLost()) {
      throw programError('DOE_PROGRAM_INVALIDATED', 'program.state', 'ready live device', reason ?? state);
    }
  }

  function encode() {
    const encoder = device.createCommandEncoder({ label: plan.id });
    if (execution !== 'webgpu') native.materializeEncoder(encoder);
    for (const buffer of cleared) encoder.clearBuffer(buffers.get(buffer.id));
    const pass = encoder.beginComputePass(clock ? { timestampWrites: {
      querySet: queries, beginningOfPassWriteIndex: 0, endOfPassWriteIndex: 1,
    } } : undefined);
    for (const step of steps) {
      pass.setPipeline(step.pipeline);
      pass.setBindGroup(0, step.bindGroup);
      pass.dispatchWorkgroups(...step.workgroups);
    }
    pass.end();
    if (clock) {
      encoder.resolveQuerySet(queries, 0, QUERY_COUNT, queryResolve, 0);
      encoder.copyBufferToBuffer(queryResolve, 0, readback, timestampOffset, QUERY_BYTES);
    }
    if (outputReadbackSize) encoder.copyBufferToBuffer(buffers.get(plan.output), 0, readback, 0, outputReadbackSize);
    return encoder.finish();
  }

  function release() {
    recording?.destroy();
    recording = null;
    for (const entry of [...resources.values()].reverse()) {
      releaseEntry(entry);
    }
    resources.clear();
    buffers.clear();
    bufferEntries.clear();
    pipelines.clear();
    shaders.clear();
    steps.length = 0;
  }

  try {
    await captureGpuErrors(device, async () => {
      for (const declaration of plan.buffers) {
        if (declaration.size > device.limits.maxBufferSize) {
          throw programError('DOE_PROGRAM_LIMIT', `buffers.${declaration.id}`, 'size within device limits', declaration.size);
        }
        const bindingUsage = declaration.type === 'uniform' ? GPUBufferUsage.UNIFORM : GPUBufferUsage.STORAGE;
        const key = `buffer:${JSON.stringify(declaration)}`;
        buffers.set(declaration.id, acquire(key, () => device.createBuffer({
          label: declaration.id, size: declaration.size,
          usage: bindingUsage | GPUBufferUsage.COPY_SRC | GPUBufferUsage.COPY_DST,
        })));
        bufferEntries.set(declaration.id, resources.get(key));
      }
      if (readbackSize) readback = acquire(`readback:${readbackSize}`, () => device.createBuffer({
        label: `${plan.id}:readback`, size: readbackSize,
        usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
      }));
      if (clock) {
        queries = acquire('timestamp:queries', () => device.createQuerySet({ type: 'timestamp', count: QUERY_COUNT }));
        queryResolve = acquire('timestamp:resolve', () => device.createBuffer({
          size: QUERY_BYTES, usage: GPUBufferUsage.QUERY_RESOLVE | GPUBufferUsage.COPY_SRC,
        }));
      }
      for (const declaration of plan.shaders) {
        const shaderKey = `shader:${declaration.id}:${hashBytes(declaration.code)}`;
        const shader = acquire(shaderKey, () => device.createShaderModule({
          label: declaration.id, code: declaration.code,
        }));
        shaders.set(declaration.id, shader);
        const info = await shader.getCompilationInfo();
        const errors = info.messages.filter((message) => message.type === 'error');
        if (errors.length) {
          throw programError('DOE_PROGRAM_SHADER', `shaders.${declaration.id}`, 'valid WGSL', errors.map((error) => error.message).join('; '));
        }
        pipelines.set(declaration.id, acquire(`pipeline:${shaderKey}:${declaration.entryPoint}`, () => device.createComputePipeline({
          label: declaration.id, layout: 'auto',
          compute: { module: shader, entryPoint: declaration.entryPoint },
        })));
      }
      for (const step of plan.steps) {
        if (step.workgroups.some((count) => count > device.limits.maxComputeWorkgroupsPerDimension)) {
          throw programError('DOE_PROGRAM_LIMIT', 'step.workgroups', 'dispatch within device limits', step.workgroups);
        }
        const pipeline = pipelines.get(step.shader);
        const shaderDeclaration = plan.shaders.find((shader) => shader.id === step.shader);
        const bindingKey = JSON.stringify([shaderDeclaration, step.bindings,
          step.bindings.map((binding) => plan.buffers.find((buffer) => buffer.id === binding.buffer))]);
        const layout = acquire(`layout:${hashBytes(JSON.stringify(shaderDeclaration))}`, () => pipeline.getBindGroupLayout(0));
        const bindGroup = acquire(`bindings:${hashBytes(bindingKey)}`, () => device.createBindGroup({
          layout,
          entries: step.bindings.map((binding) => ({
            binding: binding.binding, resource: { buffer: buffers.get(binding.buffer) },
          })),
        }));
        steps.push({ pipeline, bindGroup, workgroups: step.workgroups });
      }
      if (execution !== 'webgpu') recording = native.prepare(encode(), execution);
      const initialized = resident.filter((buffer) => buffer.role !== 'input'
        && !previous?.has(`buffer:${JSON.stringify(buffer)}`));
      if (initialized.length) {
        const encoder = device.createCommandEncoder({ label: `${plan.id}:initialize` });
        for (const buffer of initialized) encoder.clearBuffer(buffers.get(buffer.id));
        device.queue.submit([encoder.finish()]);
        await device.queue.onSubmittedWorkDone();
      }
    });
    if (loss.info || native?.isLost()) {
      throw programError('DOE_PROGRAM_INVALIDATED', 'device', 'live device', 'lost during preparation');
    }
    state = 'ready';
  } catch (error) {
    release();
    throw error;
  }
  const preparationMs = performance.now() - started;

  function assertExecutionActive(signal) {
    if (signal?.aborted || closed || loss.info || native?.isLost()) {
      throw programError(signal?.aborted ? 'DOE_PROGRAM_CANCELLED' : 'DOE_PROGRAM_INVALIDATED',
        'program.execution', 'active live program', 'cancelled or invalidated after submission');
    }
  }

  async function execute(batch, signal) {
    const start = performance.now();
    let submitted = false;
    let mapped = false;
    try {
      return await captureGpuErrors(device, async () => {
        if (signal?.aborted) throw programError('DOE_PROGRAM_CANCELLED', 'signal', 'active run', 'aborted before upload');
        outputReady = false;
        const residentStateBefore = Object.fromEntries(resident.filter((buffer) => buffer.role !== 'input')
          .map((buffer) => [buffer.id, bufferEntries.get(buffer.id).origin]));
        for (const entry of bufferEntries.values()) {
          if (!Number.isSafeInteger(entry.generation + 1)) {
            throw programError('DOE_PROGRAM_INVALIDATED', 'program.generation', 'safe integer', 'exhausted');
          }
          entry.generation += 1;
        }
        const uploadStart = performance.now();
        for (const update of batch.updates) {
          if (update.bytes) device.queue.writeBuffer(update.entry.value, 0, update.bytes);
          update.entry.inputOrigin = update.origin;
          update.entry.inputHash = update.hash;
        }
        const uploadMs = performance.now() - uploadStart;
        const encodeStart = performance.now();
        const copies = batch.updates.filter((update) => update.source);
        let copyCommands;
        if (copies.length) {
          const encoder = device.createCommandEncoder({ label: `${plan.id}:inputs` });
          for (const copy of copies) encoder.copyBufferToBuffer(copy.source, 0, copy.entry.value, 0, copy.size);
          copyCommands = encoder.finish();
        }
        const commands = execution === 'webgpu' ? encode() : null;
        const encodeMs = performance.now() - encodeStart;
        const submitStart = performance.now();
        submitted = true;
        if (recording) {
          if (copyCommands) device.queue.submit([copyCommands]);
          recording.submit();
        } else device.queue.submit(copyCommands ? [copyCommands, commands] : [commands]);
        for (const declaration of plan.buffers) {
          const entry = bufferEntries.get(declaration.id);
          entry.origin = Object.freeze({ kind: 'program-state', programHash: identity.programHash,
            programInstance, buffer: declaration.id, generation: entry.generation });
          // A role describes data flow, not WGSL write access. Storage contents
          // after execution carry provenance until actual bytes are observed.
          if (declaration.role === 'input' && declaration.type === 'storage') {
            entry.inputHash = null;
            entry.inputOrigin = entry.origin;
          }
        }
        await awaitProgramCompletion(device.queue, readback);
        mapped = Boolean(readback);
        const submitWaitMs = performance.now() - submitStart;
        if (signal) await setImmediate();
        assertExecutionActive(signal);
        const readStart = performance.now();
        let output = null;
        let gpuTime = null;
        if (readback) {
          try {
            const bytes = readback.getMappedRange();
            if (outputReadbackSize) output = new Uint8Array(bytes, 0, outputReadbackSize).slice();
            if (clock) gpuTime = timestampResult(bytes, timestampOffset, clock);
          } finally { readback.unmap(); mapped = false; }
        }
        assertExecutionActive(signal);
        const readbackMs = readback ? performance.now() - readStart : 0;
        runs += 1;
        const outputGeneration = bufferEntries.get(plan.output).generation;
        return {
          output,
          receipt: {
            schemaVersion: 5, programHash: identity.programHash, programInstance, execution, run: runs,
            inputHashes: batch.hashes, inputOrigins: batch.origins, residentStateBefore,
            outputHash: output ? hashBytes(output) : null, outputGeneration,
            dispatchCount: plan.steps.length,
            clearedBytes: cleared.reduce((sum, buffer) => sum + buffer.size, 0),
            uploadedBytes: batch.updates.reduce((sum, update) => sum + (update.bytes ? update.size : 0), 0),
            copiedInputBytes: copies.reduce((sum, copy) => sum + copy.size, 0),
            submissionCount: recording && copyCommands ? 2 : 1,
            readbackBytes: outputReadbackSize + (clock ? QUERY_BYTES : 0),
            readbackPath: readback ? 'mapAsync-copy-unmap' : 'none',
            completionMode: readback ? 'queue-and-map' : 'queue-only',
            allocatedBufferBytes: allocatedBytes,
            gpuTiming: gpuTime,
            timingMs: { upload: uploadMs, encode: encodeMs, submitWait: submitWaitMs,
              readback: readbackMs, total: performance.now() - start },
          },
        };
      }).then((result) => { outputReady = true; return result; });
    } catch (error) {
      if (submitted) {
        try { await device.queue.onSubmittedWorkDone(); }
        catch { state = 'invalid'; reason = 'completion failed'; }
      }
      if ((submitted && resident.length) || (error.code !== 'DOE_PROGRAM_CANCELLED' && error.code !== 'DOE_PROGRAM_BUSY')) {
        state = 'invalid';
        reason = error.message;
      }
      throw error;
    } finally {
      try { if (mapped) readback.unmap(); }
      finally { batch.release(); }
    }
  }

  const api = Object.freeze({
    descriptor: plan,
    programHash: identity.programHash,
    preparationMs,
    allocatedBufferBytes: allocatedBytes,
    preparation: Object.freeze(preparation),
    get state() { return closed ? 'closed' : loss.info || native?.isLost() ? 'invalid' : state; },
    output() {
      owner.assertReadable();
      const entry = bufferEntries.get(plan.output);
      return outputReference(owner, entry, { programHash: identity.programHash,
        programInstance, buffer: plan.output, generation: entry.generation });
    },
    run(values = {}, { signal } = {}) {
      assertReady();
      if (active || owner.readers) throw programError('DOE_PROGRAM_BUSY', 'program.run', 'idle unleased program', 'operation in progress');
      const batch = inputBatch(owner, inputs, bufferEntries, values);
      active = execute(batch, signal).finally(() => { active = null; });
      return active;
    },
    update(nextDescriptor) {
      assertReady();
      if (active || owner.readers) throw programError('DOE_PROGRAM_BUSY', 'program.update', 'idle program', 'operation in progress');
      const next = validateComputeProgram(nextDescriptor);
      if (next.programHash === identity.programHash) return Promise.resolve(api);
      state = 'updating';
      active = buildComputeProgram(device, next.descriptor, { execution, gpuTiming, readback: readbackMode }, resources).then(async (replacement) => {
        if (closed) {
          await replacement.close();
          throw programError('DOE_PROGRAM_INVALIDATED', 'program.update', 'open program', 'closed during update');
        }
        closed = true;
        release();
        return replacement;
      }).catch((error) => {
        if (!closed) state = 'ready';
        throw error;
      }).finally(() => { active = null; });
      return active;
    },
    async close() {
      closed = true;
      if (active) { try { await active; } catch { /* Run owns its failure. */ } }
      release();
    },
  });
  return api;
}

async function prepareComputeProgram(device, descriptor, options) {
  return buildComputeProgram(device, descriptor, options);
}

export { prepareComputeProgram, validateComputeProgram };

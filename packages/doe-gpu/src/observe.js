// doe-gpu/observe - transparent, provider-neutral WebGPU execution evidence.

import { createHash } from 'node:crypto';

export const DOE_TRANSPARENT_WEBGPU_OBSERVATION_SCHEMA =
  'doe.transparent-webgpu-observation/v1';
export const DOE_TRANSPARENT_WEBGPU_OBSERVATION_ARTIFACT_KIND =
  'doe-transparent-webgpu-observation';

function isPlainObject(value) {
  if (value === null || typeof value !== 'object') return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function stableValue(value) {
  if (Array.isArray(value)) return value.map(stableValue);
  if (isPlainObject(value)) {
    return Object.fromEntries(
      Object.keys(value)
        .filter((key) => value[key] !== undefined)
        .sort()
        .map((key) => [key, stableValue(value[key])]),
    );
  }
  return value;
}

function sha256(value) {
  const bytes = typeof value === 'string' ? Buffer.from(value, 'utf8') : value;
  return `sha256:${createHash('sha256').update(bytes).digest('hex')}`;
}

function stableSha256(value) {
  return sha256(JSON.stringify(stableValue(value)));
}

function hashBytes(value) {
  if (ArrayBuffer.isView(value)) {
    return sha256(new Uint8Array(value.buffer, value.byteOffset, value.byteLength));
  }
  if (value instanceof ArrayBuffer) return sha256(new Uint8Array(value));
  return null;
}

function workgroupSize(code) {
  const match = /@workgroup_size\s*\(\s*(\d+)(?:\s*,\s*(\d+))?(?:\s*,\s*(\d+))?\s*\)/u
    .exec(code);
  return match ? [Number(match[1]), Number(match[2] ?? 1), Number(match[3] ?? 1)] : null;
}

function cloneJson(value) {
  return JSON.parse(JSON.stringify(value));
}

/**
 * Wrap an already selected GPU and adapter without changing the provider's
 * execution semantics. The observer records the public WebGPU command surface;
 * it does not claim native-driver or operating-system tracing.
 */
export function createTransparentWebGPUObserver(options) {
  if (!options || typeof options !== 'object' || Array.isArray(options)) {
    throw new TypeError('transparent observer options must be an object');
  }
  if (!options.gpu || typeof options.gpu.requestAdapter !== 'function') {
    throw new TypeError('transparent observer requires a GPU with requestAdapter()');
  }
  if (options.adapter !== undefined
      && options.adapter !== null
      && typeof options.adapter.requestDevice !== 'function') {
    throw new TypeError('transparent observer adapter must expose requestDevice()');
  }
  if (options.metadata !== undefined && !isPlainObject(options.metadata)) {
    throw new TypeError('transparent observer metadata must be a plain object');
  }
  if (options.checkpoint !== undefined && typeof options.checkpoint !== 'function') {
    throw new TypeError('transparent observer checkpoint must be a function');
  }

  const providerId = String(options.providerId ?? 'unknown-provider');
  if (providerId.length === 0) {
    throw new TypeError('transparent observer providerId must not be empty');
  }
  const globals = options.globals ?? {};
  const evidence = {
    schema: DOE_TRANSPARENT_WEBGPU_OBSERVATION_SCHEMA,
    artifactKind: DOE_TRANSPARENT_WEBGPU_OBSERVATION_ARTIFACT_KIND,
    providerId,
    metadata: stableValue(options.metadata ?? {}),
    shaderModules: [],
    compilationInfos: [],
    computePipelines: [],
    renderPipelines: [],
    resources: [],
    bufferWrites: [],
    textureWrites: [],
    commands: [],
    dispatches: [],
    draws: [],
    submissions: [],
    synchronizations: [],
    readbacks: [],
  };
  let nextId = 1;
  const proxyToRaw = new WeakMap();
  const rawToProxy = new WeakMap();
  const objectIds = new WeakMap();
  const objectKinds = new WeakMap();
  const bufferState = new WeakMap();
  const encoderState = new WeakMap();
  const passState = new WeakMap();

  function objectId(raw, kind = 'object') {
    if (!objectIds.has(raw)) {
      objectIds.set(raw, nextId);
      nextId += 1;
      objectKinds.set(raw, kind);
    }
    return objectIds.get(raw);
  }

  function unwrap(value, seen = new WeakMap()) {
    if (value === null || typeof value !== 'object') return value;
    const raw = proxyToRaw.get(value);
    if (raw) return raw;
    if (ArrayBuffer.isView(value) || value instanceof ArrayBuffer) return value;
    if (seen.has(value)) return seen.get(value);
    if (Array.isArray(value)) {
      const result = [];
      seen.set(value, result);
      for (const item of value) result.push(unwrap(item, seen));
      return result;
    }
    if (!isPlainObject(value)) return value;
    const result = Object.create(Object.getPrototypeOf(value));
    seen.set(value, result);
    for (const [key, item] of Object.entries(value)) result[key] = unwrap(item, seen);
    return result;
  }

  function descriptorValue(value, state = { seen: new WeakMap(), nextRef: 1 }) {
    if (value === null || typeof value !== 'object') return value;
    const raw = proxyToRaw.get(value) ?? value;
    if (objectIds.has(raw)) {
      return { ref: objectId(raw), kind: objectKinds.get(raw) ?? 'object' };
    }
    if (ArrayBuffer.isView(value)) {
      return { type: value.constructor?.name ?? 'ArrayBufferView', byteLength: value.byteLength };
    }
    if (value instanceof ArrayBuffer) return { type: 'ArrayBuffer', byteLength: value.byteLength };
    if (state.seen.has(value)) return { localRef: state.seen.get(value) };
    state.seen.set(value, state.nextRef);
    state.nextRef += 1;
    if (Array.isArray(value)) return value.map((item) => descriptorValue(item, state));
    if (!isPlainObject(value)) return { type: value.constructor?.name ?? 'object' };
    return Object.fromEntries(
      Object.entries(value)
        .filter(([, item]) => typeof item !== 'function')
        .map(([key, item]) => [key, descriptorValue(item, state)]),
    );
  }

  function invoke(raw, member, args) {
    const seen = new WeakMap();
    return Reflect.apply(member, raw, args.map((value) => unwrap(value, seen)));
  }

  function recordResource(raw, kind, descriptor) {
    const id = objectId(raw, kind);
    evidence.resources.push({ id, kind, descriptor: descriptorValue(descriptor ?? {}) });
    return id;
  }

  function recordPipeline(raw, kind, descriptor) {
    const id = objectId(raw, kind);
    const target = kind === 'computePipeline'
      ? evidence.computePipelines
      : evidence.renderPipelines;
    const record = { id, descriptor: descriptorValue(descriptor ?? {}) };
    if (kind === 'computePipeline') {
      record.moduleId = descriptor?.compute?.module
        ? objectId(unwrap(descriptor.compute.module), 'shaderModule')
        : null;
      record.entryPoint = descriptor?.compute?.entryPoint ?? 'main';
    } else {
      record.vertexModuleId = descriptor?.vertex?.module
        ? objectId(unwrap(descriptor.vertex.module), 'shaderModule')
        : null;
      record.vertexEntryPoint = descriptor?.vertex?.entryPoint ?? 'main';
      record.fragmentModuleId = descriptor?.fragment?.module
        ? objectId(unwrap(descriptor.fragment.module), 'shaderModule')
        : null;
      record.fragmentEntryPoint = descriptor?.fragment?.entryPoint ?? null;
    }
    target.push(record);
    return id;
  }

  function commandEncoderRecord(raw) {
    let state = encoderState.get(raw);
    if (!state) {
      state = { encoderId: objectId(raw, 'commandEncoder'), commandIndex: 0 };
      encoderState.set(raw, state);
    }
    return state;
  }

  function recordEncoderCommand(raw, kind, detail = {}) {
    const state = commandEncoderRecord(raw);
    const record = {
      encoderId: state.encoderId,
      commandIndex: state.commandIndex,
      kind,
      ...detail,
    };
    state.commandIndex += 1;
    evidence.commands.push(record);
    return record;
  }

  function wrap(raw, kind) {
    if (raw === null || (typeof raw !== 'object' && typeof raw !== 'function')) return raw;
    const existing = rawToProxy.get(raw);
    if (existing) return existing;
    objectId(raw, kind);
    const proxy = new Proxy(raw, {
      get(target, property) {
        if (kind === 'device' && property === 'queue') return wrap(target.queue, 'queue');
        const member = Reflect.get(target, property, target);
        if (typeof member !== 'function') return member;

        if (kind === 'gpu' && property === 'requestAdapter') {
          return async (...args) => wrap(await invoke(target, member, args), 'adapter');
        }
        if (kind === 'adapter' && property === 'requestDevice') {
          return async (...args) => wrap(await invoke(target, member, args), 'device');
        }
        if (kind === 'device' && property === 'createShaderModule') {
          return (...args) => {
            const descriptor = args[0] ?? {};
            const code = String(descriptor.code ?? '');
            const record = {
              id: null,
              label: descriptor.label ?? '',
              sourceSha256: sha256(code),
              sourceBytes: Buffer.byteLength(code),
              workgroupSize: workgroupSize(code),
              creation: 'attempted',
            };
            evidence.shaderModules.push(record);
            try {
              const module = invoke(target, member, args);
              record.id = objectId(module, 'shaderModule');
              record.creation = 'returned';
              return wrap(module, 'shaderModule');
            } catch (error) {
              record.creation = 'threw';
              record.errorName = error instanceof Error ? error.name : 'Error';
              throw error;
            }
          };
        }
        if (kind === 'shaderModule' && property === 'getCompilationInfo') {
          return async (...args) => {
            const record = {
              shaderModuleId: objectId(target, 'shaderModule'),
              status: 'pending',
              messages: [],
            };
            evidence.compilationInfos.push(record);
            try {
              const info = await invoke(target, member, args);
              record.status = 'returned';
              record.messages = Array.from(info?.messages ?? []).map((message) => ({
                type: String(message?.type ?? 'unknown'),
                message: String(message?.message ?? ''),
                lineNum: Number.isFinite(message?.lineNum) ? Number(message.lineNum) : null,
                linePos: Number.isFinite(message?.linePos) ? Number(message.linePos) : null,
                offset: Number.isFinite(message?.offset) ? Number(message.offset) : null,
                length: Number.isFinite(message?.length) ? Number(message.length) : null,
              }));
              if (options.checkpoint) {
                options.checkpoint(snapshot(), { reason: 'compilation-info' });
              }
              return info;
            } catch (error) {
              record.status = 'threw';
              record.errorName = error instanceof Error ? error.name : 'Error';
              record.errorMessage = error instanceof Error ? error.message : String(error);
              if (options.checkpoint) {
                options.checkpoint(snapshot(), { reason: 'compilation-info' });
              }
              throw error;
            }
          };
        }
        if (kind === 'device'
            && ['createComputePipeline', 'createRenderPipeline'].includes(property)) {
          return (...args) => {
            const descriptor = args[0] ?? {};
            const pipeline = invoke(target, member, args);
            const pipelineKind = property === 'createComputePipeline'
              ? 'computePipeline'
              : 'renderPipeline';
            recordPipeline(pipeline, pipelineKind, descriptor);
            return wrap(pipeline, pipelineKind);
          };
        }
        if (kind === 'device'
            && ['createComputePipelineAsync', 'createRenderPipelineAsync'].includes(property)) {
          return async (...args) => {
            const descriptor = args[0] ?? {};
            const pipeline = await invoke(target, member, args);
            const pipelineKind = property === 'createComputePipelineAsync'
              ? 'computePipeline'
              : 'renderPipeline';
            recordPipeline(pipeline, pipelineKind, descriptor);
            return wrap(pipeline, pipelineKind);
          };
        }
        if (kind === 'device' && property === 'createBuffer') {
          return (...args) => {
            const descriptor = args[0] ?? {};
            const buffer = invoke(target, member, args);
            const id = recordResource(buffer, 'buffer', descriptor);
            bufferState.set(buffer, {
              id,
              size: Number(descriptor.size ?? 0),
              usage: Number(descriptor.usage ?? 0),
              mapMode: descriptor.mappedAtCreation ? Number(globals.GPUMapMode?.WRITE ?? 2) : 0,
            });
            return wrap(buffer, 'buffer');
          };
        }
        const deviceResourceMethods = {
          createTexture: 'texture',
          createSampler: 'sampler',
          createBindGroup: 'bindGroup',
          createBindGroupLayout: 'bindGroupLayout',
          createPipelineLayout: 'pipelineLayout',
          createQuerySet: 'querySet',
        };
        if (kind === 'device' && deviceResourceMethods[property]) {
          return (...args) => {
            const descriptor = args[0] ?? {};
            const resource = invoke(target, member, args);
            const resourceKind = deviceResourceMethods[property];
            recordResource(resource, resourceKind, descriptor);
            return wrap(resource, resourceKind);
          };
        }
        if (kind === 'texture' && property === 'createView') {
          return (...args) => {
            const descriptor = args[0] ?? {};
            const view = invoke(target, member, args);
            recordResource(view, 'textureView', descriptor);
            return wrap(view, 'textureView');
          };
        }
        if (['computePipeline', 'renderPipeline'].includes(kind)
            && property === 'getBindGroupLayout') {
          return (index) => {
            const layout = invoke(target, member, [index]);
            recordResource(layout, 'bindGroupLayout', {
              derivedFromPipeline: objectId(target, kind),
              index,
            });
            return wrap(layout, 'bindGroupLayout');
          };
        }
        if (kind === 'device' && property === 'createCommandEncoder') {
          return (...args) => {
            const descriptor = args[0] ?? {};
            const encoder = invoke(target, member, args);
            recordResource(encoder, 'commandEncoder', descriptor);
            commandEncoderRecord(encoder);
            return wrap(encoder, 'commandEncoder');
          };
        }
        if (kind === 'commandEncoder'
            && ['beginComputePass', 'beginRenderPass'].includes(property)) {
          return (...args) => {
            const descriptor = args[0] ?? {};
            const passKind = property === 'beginComputePass' ? 'computePass' : 'renderPass';
            const pass = invoke(target, member, args);
            const command = recordEncoderCommand(target, property, {
              descriptor: descriptorValue(descriptor),
            });
            passState.set(pass, {
              passId: objectId(pass, passKind),
              encoderId: command.encoderId,
              pipelineId: null,
              bindGroups: new Map(),
            });
            return wrap(pass, passKind);
          };
        }
        const copyCommands = new Set([
          'copyBufferToBuffer',
          'copyBufferToTexture',
          'copyTextureToBuffer',
          'copyTextureToTexture',
          'clearBuffer',
          'resolveQuerySet',
        ]);
        if (kind === 'commandEncoder' && copyCommands.has(property)) {
          return (...args) => {
            recordEncoderCommand(target, property, { args: descriptorValue(args) });
            return invoke(target, member, args);
          };
        }
        if (kind === 'commandEncoder' && property === 'finish') {
          return (...args) => {
            const descriptor = args[0] ?? {};
            const commandBuffer = invoke(target, member, args);
            recordResource(commandBuffer, 'commandBuffer', {
              encoderId: objectId(target, 'commandEncoder'),
              descriptor,
            });
            recordEncoderCommand(target, 'finish', {
              commandBufferId: objectId(commandBuffer, 'commandBuffer'),
            });
            return wrap(commandBuffer, 'commandBuffer');
          };
        }
        if (['computePass', 'renderPass'].includes(kind) && property === 'setPipeline') {
          return (pipeline) => {
            const rawPipeline = unwrap(pipeline);
            const state = passState.get(target);
            if (state) state.pipelineId = objectId(rawPipeline, `${kind}Pipeline`);
            return invoke(target, member, [pipeline]);
          };
        }
        if (['computePass', 'renderPass'].includes(kind) && property === 'setBindGroup') {
          return (...args) => {
            const [index, bindGroup] = args;
            const state = passState.get(target);
            if (state) {
              state.bindGroups.set(Number(index), objectId(unwrap(bindGroup), 'bindGroup'));
            }
            return invoke(target, member, args);
          };
        }
        if (kind === 'computePass' && property === 'dispatchWorkgroups') {
          return (...args) => {
            const [x, y = 1, z = 1] = args;
            const state = passState.get(target);
            evidence.dispatches.push({
              passId: state?.passId ?? null,
              encoderId: state?.encoderId ?? null,
              pipelineId: state?.pipelineId ?? null,
              bindGroups: state
                ? [...state.bindGroups.entries()].sort(([left], [right]) => left - right)
                  .map(([index, id]) => ({ index, id }))
                : [],
              kind: 'direct',
              workgroups: [Number(x), Number(y), Number(z)],
            });
            return invoke(target, member, args);
          };
        }
        if (kind === 'computePass' && property === 'dispatchWorkgroupsIndirect') {
          return (...args) => {
            const [buffer, offset = 0] = args;
            const state = passState.get(target);
            evidence.dispatches.push({
              passId: state?.passId ?? null,
              encoderId: state?.encoderId ?? null,
              pipelineId: state?.pipelineId ?? null,
              bindGroups: state
                ? [...state.bindGroups.entries()].sort(([left], [right]) => left - right)
                  .map(([index, id]) => ({ index, id }))
                : [],
              kind: 'indirect',
              indirectBufferId: objectId(unwrap(buffer), 'buffer'),
              indirectOffset: Number(offset),
            });
            return invoke(target, member, args);
          };
        }
        const drawMethods = new Set(['draw', 'drawIndexed', 'drawIndirect', 'drawIndexedIndirect']);
        if (kind === 'renderPass' && drawMethods.has(property)) {
          return (...args) => {
            const state = passState.get(target);
            evidence.draws.push({
              passId: state?.passId ?? null,
              encoderId: state?.encoderId ?? null,
              pipelineId: state?.pipelineId ?? null,
              kind: property,
              args: descriptorValue(args),
            });
            return invoke(target, member, args);
          };
        }
        if (['computePass', 'renderPass'].includes(kind) && property === 'end') {
          return () => {
            const state = passState.get(target);
            evidence.commands.push({
              encoderId: state?.encoderId ?? null,
              kind: `${kind}.end`,
              passId: state?.passId ?? null,
            });
            return invoke(target, member, []);
          };
        }
        if (kind === 'queue' && property === 'writeBuffer') {
          return (...args) => {
            const [buffer, bufferOffset, data, dataOffset = 0, size = undefined] = args;
            const byteView = ArrayBuffer.isView(data)
              ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
              : new Uint8Array(data);
            const start = Number(dataOffset ?? 0);
            const length = size === undefined ? byteView.byteLength - start : Number(size);
            const bytes = byteView.subarray(start, start + length);
            evidence.bufferWrites.push({
              bufferId: objectId(unwrap(buffer), 'buffer'),
              bufferOffset: Number(bufferOffset),
              byteLength: bytes.byteLength,
              dataSha256: sha256(bytes),
            });
            return invoke(target, member, args);
          };
        }
        if (kind === 'queue' && property === 'writeTexture') {
          return (...args) => {
            evidence.textureWrites.push({
              destination: descriptorValue(args[0]),
              dataSha256: hashBytes(args[1]),
              dataLayout: descriptorValue(args[2]),
              size: descriptorValue(args[3]),
            });
            return invoke(target, member, args);
          };
        }
        if (kind === 'queue' && property === 'submit') {
          return (commandBuffers) => {
            evidence.submissions.push({
              commandBufferIds: commandBuffers.map(
                (commandBuffer) => objectId(unwrap(commandBuffer), 'commandBuffer'),
              ),
            });
            return invoke(target, member, [commandBuffers]);
          };
        }
        if (kind === 'queue' && property === 'onSubmittedWorkDone') {
          return async (...args) => {
            const value = await invoke(target, member, args);
            evidence.synchronizations.push({ kind: 'queue.onSubmittedWorkDone' });
            return value;
          };
        }
        if (kind === 'buffer' && property === 'mapAsync') {
          return async (mode, ...args) => {
            const state = bufferState.get(target);
            if (state) state.mapMode = Number(mode);
            const value = await invoke(target, member, [mode, ...args]);
            evidence.synchronizations.push({
              kind: 'buffer.mapAsync',
              bufferId: state?.id ?? objectId(target, 'buffer'),
              mode: Number(mode),
              offset: Number(args[0] ?? 0),
              size: args[1] === undefined ? null : Number(args[1]),
            });
            return value;
          };
        }
        if (kind === 'buffer' && property === 'getMappedRange') {
          return (...args) => {
            const range = invoke(target, member, args);
            const state = bufferState.get(target);
            const readMode = Number(globals.GPUMapMode?.READ ?? 1);
            if (state && (state.mapMode & readMode) !== 0) {
              evidence.readbacks.push({
                bufferId: state.id,
                bufferSize: state.size,
                offset: Number(args[0] ?? 0),
                size: Number(args[1] ?? range.byteLength),
                dataSha256: hashBytes(range),
              });
              if (options.checkpoint) {
                options.checkpoint(snapshot(), { reason: 'mapped-readback' });
              }
            }
            return range;
          };
        }
        return (...args) => {
          const result = invoke(target, member, args);
          return result;
        };
      },
      set(target, property, value) {
        return Reflect.set(target, property, unwrap(value), target);
      },
    });
    proxyToRaw.set(proxy, raw);
    rawToProxy.set(raw, proxy);
    return proxy;
  }

  function snapshot() {
    const payload = {
      ...cloneJson(evidence),
      summary: {
        shaderModuleCount: evidence.shaderModules.length,
        compilationInfoCount: evidence.compilationInfos.length,
        computePipelineCount: evidence.computePipelines.length,
        renderPipelineCount: evidence.renderPipelines.length,
        resourceCount: evidence.resources.length,
        bufferWriteCount: evidence.bufferWrites.length,
        textureWriteCount: evidence.textureWrites.length,
        commandCount: evidence.commands.length,
        dispatchCount: evidence.dispatches.length,
        drawCount: evidence.draws.length,
        submissionCount: evidence.submissions.length,
        synchronizationCount: evidence.synchronizations.length,
        readbackCount: evidence.readbacks.length,
      },
    };
    return Object.freeze({
      ...payload,
      observationSha256: stableSha256(payload),
    });
  }

  return Object.freeze({
    gpu: wrap(options.gpu, 'gpu'),
    adapter: options.adapter == null ? null : wrap(options.adapter, 'adapter'),
    snapshot,
  });
}

export function validateTransparentWebGPUObservation(value) {
  const errors = [];
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return { valid: false, errors: ['observation must be an object'] };
  }
  if (value.schema !== DOE_TRANSPARENT_WEBGPU_OBSERVATION_SCHEMA) {
    errors.push('observation schema is invalid');
  }
  if (value.artifactKind !== DOE_TRANSPARENT_WEBGPU_OBSERVATION_ARTIFACT_KIND) {
    errors.push('observation artifactKind is invalid');
  }
  if (typeof value.providerId !== 'string' || value.providerId.length === 0) {
    errors.push('providerId must be a non-empty string');
  }
  if (!isPlainObject(value.metadata)) errors.push('metadata must be a plain object');
  for (const field of [
    'shaderModules',
    'computePipelines',
    'renderPipelines',
    'resources',
    'bufferWrites',
    'textureWrites',
    'commands',
    'dispatches',
    'draws',
    'submissions',
    'synchronizations',
    'readbacks',
  ]) {
    if (!Array.isArray(value[field])) errors.push(`${field} must be an array`);
  }
  if (value.compilationInfos !== undefined && !Array.isArray(value.compilationInfos)) {
    errors.push('compilationInfos must be an array when present');
  }
  if (!value.summary || typeof value.summary !== 'object') {
    errors.push('summary must be an object');
  } else {
    const summaryFields = {
      shaderModuleCount: 'shaderModules',
      compilationInfoCount: 'compilationInfos',
      computePipelineCount: 'computePipelines',
      renderPipelineCount: 'renderPipelines',
      resourceCount: 'resources',
      bufferWriteCount: 'bufferWrites',
      textureWriteCount: 'textureWrites',
      commandCount: 'commands',
      dispatchCount: 'dispatches',
      drawCount: 'draws',
      submissionCount: 'submissions',
      synchronizationCount: 'synchronizations',
      readbackCount: 'readbacks',
    };
    for (const [summaryField, evidenceField] of Object.entries(summaryFields)) {
      if (evidenceField === 'compilationInfos'
          && value.compilationInfos === undefined
          && value.summary[summaryField] === undefined) {
        continue;
      }
      if (value.summary[summaryField] !== value[evidenceField]?.length) {
        errors.push(`${summaryField} does not match ${evidenceField}.length`);
      }
    }
  }
  const { observationSha256, ...payload } = value;
  if (!/^sha256:[0-9a-f]{64}$/u.test(observationSha256 ?? '')) {
    errors.push('observationSha256 must be a lowercase SHA-256 identity');
  }
  if (observationSha256 !== stableSha256(payload)) {
    errors.push('observationSha256 does not match the observation payload');
  }
  return { valid: errors.length === 0, errors };
}

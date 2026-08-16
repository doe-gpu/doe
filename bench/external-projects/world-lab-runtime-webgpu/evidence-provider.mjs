import { createHash } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import * as base from 'doe-world-base-provider';

const baseModulePath = process.env.DOE_WORLD_LAB_BASE_PROVIDER_MODULE;
const evidencePath = process.env.DOE_WORLD_LAB_EVIDENCE_PATH;
const providerId = process.env.DOE_EXTERNAL_WEBGPU_PROVIDER;
if (!baseModulePath) throw new Error('DOE_WORLD_LAB_BASE_PROVIDER_MODULE is required.');
if (!evidencePath) throw new Error('DOE_WORLD_LAB_EVIDENCE_PATH is required.');
if (!providerId) throw new Error('DOE_EXTERNAL_WEBGPU_PROVIDER is required.');
const evidenceOutputPath = `${evidencePath}.${process.pid}.json`;

if (typeof base.create !== 'function' || !base.globals) {
  throw new Error(`${baseModulePath} does not expose create() and globals.`);
}

export const globals = base.globals;

const evidence = {
  schemaVersion: 1,
  artifactKind: 'world-lab-transparent-webgpu-evidence',
  providerId,
  shaderModules: [],
  computePipelines: [],
  renderPipelines: [],
  dispatches: [],
  draws: [],
  submissions: [],
  readbacks: [],
};
let nextId = 1;
const proxyToRaw = new WeakMap();
const rawToProxy = new WeakMap();
const objectIds = new WeakMap();
const bufferState = new WeakMap();
const computePassState = new WeakMap();
const renderPassState = new WeakMap();

function allocateId(raw) {
  if (!objectIds.has(raw)) objectIds.set(raw, nextId++);
  return objectIds.get(raw);
}

function hash(value) {
  return createHash('sha256').update(value).digest('hex');
}

function hashBytes(value) {
  if (ArrayBuffer.isView(value)) {
    return hash(new Uint8Array(value.buffer, value.byteOffset, value.byteLength));
  }
  if (value instanceof ArrayBuffer) return hash(new Uint8Array(value));
  return null;
}

function parseWorkgroupSize(code) {
  const match = /@workgroup_size\s*\(\s*(\d+)(?:\s*,\s*(\d+))?(?:\s*,\s*(\d+))?\s*\)/u.exec(code);
  return match ? [Number(match[1]), Number(match[2] ?? 1), Number(match[3] ?? 1)] : null;
}

function unwrap(value) {
  if (value === null || typeof value !== 'object') return value;
  const raw = proxyToRaw.get(value);
  if (raw) return raw;
  if (ArrayBuffer.isView(value) || value instanceof ArrayBuffer) return value;
  if (Array.isArray(value)) return value.map(unwrap);
  if (Object.getPrototypeOf(value) !== Object.prototype) return value;
  return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, unwrap(item)]));
}

function flushEvidence() {
  writeFileSync(evidenceOutputPath, `${JSON.stringify(evidence, null, 2)}\n`);
}

process.once('beforeExit', flushEvidence);
process.once('exit', flushEvidence);

function invoke(raw, method, args) {
  return Reflect.apply(raw[method], raw, args.map(unwrap));
}

function wrap(raw, kind) {
  if (raw === null || (typeof raw !== 'object' && typeof raw !== 'function')) return raw;
  const existing = rawToProxy.get(raw);
  if (existing) return existing;
  allocateId(raw);
  const proxy = new Proxy(raw, {
    get(target, property) {
      if (kind === 'device' && property === 'queue') return wrap(target.queue, 'queue');
      const member = Reflect.get(target, property, target);
      if (typeof member !== 'function') return member;

      if (kind === 'gpu' && property === 'requestAdapter') {
        return async (...args) => wrap(await invoke(target, property, args), 'adapter');
      }
      if (kind === 'adapter' && property === 'requestDevice') {
        return async (...args) => wrap(await invoke(target, property, args), 'device');
      }
      if (kind === 'device' && property === 'createShaderModule') {
        return (descriptor) => {
          const code = String(descriptor?.code ?? '');
          const record = {
            id: null,
            label: descriptor?.label ?? '',
            sourceSha256: hash(code),
            sourceBytes: Buffer.byteLength(code),
            workgroupSize: parseWorkgroupSize(code),
            creation: 'attempted',
          };
          evidence.shaderModules.push(record);
          try {
            const module = invoke(target, property, [descriptor]);
            record.id = allocateId(module);
            record.creation = 'returned';
            return wrap(module, 'shaderModule');
          } catch (error) {
            record.creation = 'threw';
            record.errorName = error?.name ?? 'Error';
            throw error;
          }
        };
      }
      if (kind === 'device' && property === 'createComputePipeline') {
        return (...args) => {
          const descriptor = args[0] ?? {};
          const pipeline = invoke(target, property, args);
          evidence.computePipelines.push({
            id: allocateId(pipeline),
            moduleId: descriptor.compute?.module
              ? allocateId(unwrap(descriptor.compute.module))
              : null,
            entryPoint: descriptor.compute?.entryPoint ?? null,
          });
          return wrap(pipeline, 'computePipeline');
        };
      }
      if (kind === 'device' && property === 'createComputePipelineAsync') {
        return async (...args) => {
          const descriptor = args[0] ?? {};
          const pipeline = await invoke(target, property, args);
          evidence.computePipelines.push({
            id: allocateId(pipeline),
            moduleId: descriptor.compute?.module
              ? allocateId(unwrap(descriptor.compute.module))
              : null,
            entryPoint: descriptor.compute?.entryPoint ?? null,
          });
          return wrap(pipeline, 'computePipeline');
        };
      }
      if (kind === 'device' && property === 'createRenderPipeline') {
        return (...args) => {
          const descriptor = args[0] ?? {};
          const pipeline = invoke(target, property, args);
          evidence.renderPipelines.push({
            id: allocateId(pipeline),
            vertexModuleId: descriptor.vertex?.module
              ? allocateId(unwrap(descriptor.vertex.module))
              : null,
            vertexEntryPoint: descriptor.vertex?.entryPoint ?? null,
            fragmentModuleId: descriptor.fragment?.module
              ? allocateId(unwrap(descriptor.fragment.module))
              : null,
            fragmentEntryPoint: descriptor.fragment?.entryPoint ?? null,
          });
          return wrap(pipeline, 'renderPipeline');
        };
      }
      if (kind === 'device' && property === 'createRenderPipelineAsync') {
        return async (...args) => {
          const descriptor = args[0] ?? {};
          const pipeline = await invoke(target, property, args);
          evidence.renderPipelines.push({
            id: allocateId(pipeline),
            vertexModuleId: descriptor.vertex?.module
              ? allocateId(unwrap(descriptor.vertex.module))
              : null,
            vertexEntryPoint: descriptor.vertex?.entryPoint ?? null,
            fragmentModuleId: descriptor.fragment?.module
              ? allocateId(unwrap(descriptor.fragment.module))
              : null,
            fragmentEntryPoint: descriptor.fragment?.entryPoint ?? null,
          });
          return wrap(pipeline, 'renderPipeline');
        };
      }
      if (kind === 'device' && property === 'createBuffer') {
        return (descriptor) => {
          const buffer = invoke(target, property, [descriptor]);
          bufferState.set(buffer, {
            id: allocateId(buffer),
            size: Number(descriptor?.size ?? 0),
            usage: Number(descriptor?.usage ?? 0),
            mapMode: null,
          });
          return wrap(buffer, 'buffer');
        };
      }
      if (kind === 'device' && property === 'createCommandEncoder') {
        return (...args) => wrap(invoke(target, property, args), 'commandEncoder');
      }
      if (kind === 'commandEncoder' && property === 'beginComputePass') {
        return (...args) => wrap(invoke(target, property, args), 'computePass');
      }
      if (kind === 'commandEncoder' && property === 'beginRenderPass') {
        return (...args) => wrap(invoke(target, property, args), 'renderPass');
      }
      if (kind === 'commandEncoder' && property === 'finish') {
        return (...args) => wrap(invoke(target, property, args), 'commandBuffer');
      }
      if (kind === 'computePass' && property === 'setPipeline') {
        return (pipeline) => {
          computePassState.set(target, allocateId(unwrap(pipeline)));
          return invoke(target, property, [pipeline]);
        };
      }
      if (kind === 'computePass' && property === 'dispatchWorkgroups') {
        return (x, y = 1, z = 1) => {
          evidence.dispatches.push({
            pipelineId: computePassState.get(target) ?? null,
            workgroups: [Number(x), Number(y), Number(z)],
          });
          return invoke(target, property, [x, y, z]);
        };
      }
      if (kind === 'renderPass' && property === 'setPipeline') {
        return (pipeline) => {
          renderPassState.set(target, allocateId(unwrap(pipeline)));
          return invoke(target, property, [pipeline]);
        };
      }
      if (kind === 'renderPass' && property === 'draw') {
        return (vertexCount, instanceCount = 1, firstVertex = 0, firstInstance = 0) => {
          evidence.draws.push({
            pipelineId: renderPassState.get(target) ?? null,
            vertexCount: Number(vertexCount),
            instanceCount: Number(instanceCount),
            firstVertex: Number(firstVertex),
            firstInstance: Number(firstInstance),
          });
          return invoke(target, property, [vertexCount, instanceCount, firstVertex, firstInstance]);
        };
      }
      if (kind === 'queue' && property === 'submit') {
        return (commandBuffers) => {
          evidence.submissions.push({ commandBufferCount: commandBuffers.length });
          return invoke(target, property, [commandBuffers]);
        };
      }
      if (kind === 'buffer' && property === 'mapAsync') {
        return async (mode, ...args) => {
          const state = bufferState.get(target);
          if (state) state.mapMode = Number(mode);
          return invoke(target, property, [mode, ...args]);
        };
      }
      if (kind === 'buffer' && property === 'getMappedRange') {
        return (...args) => {
          const range = invoke(target, property, args);
          const state = bufferState.get(target);
          if (state && (state.mapMode & Number(globals.GPUMapMode?.READ ?? 1)) !== 0) {
            evidence.readbacks.push({
              bufferId: state.id,
              bufferSize: state.size,
              offset: Number(args[0] ?? 0),
              size: Number(args[1] ?? range.byteLength),
              sha256: hashBytes(range),
            });
            flushEvidence();
          }
          return range;
        };
      }
      return (...args) => invoke(target, property, args);
    },
    set(target, property, value) {
      return Reflect.set(target, property, unwrap(value), target);
    },
  });
  proxyToRaw.set(proxy, raw);
  rawToProxy.set(raw, proxy);
  return proxy;
}

export function create(args = []) {
  return wrap(base.create(args), 'gpu');
}

export function providerInfo() {
  return {
    evidenceProvider: 'world-lab-transparent-webgpu-evidence/v1',
    providerId,
    baseModulePath,
    baseProviderInfo: typeof base.providerInfo === 'function' ? base.providerInfo() : null,
  };
}

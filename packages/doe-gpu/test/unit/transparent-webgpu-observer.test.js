import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import {
  createTransparentWebGPUObserver,
  validateTransparentWebGPUObservation,
} from '../../src/observe.js';

function stableValue(value) {
  if (Array.isArray(value)) return value.map(stableValue);
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.keys(value).filter((key) => value[key] !== undefined).sort()
        .map((key) => [key, stableValue(value[key])]),
    );
  }
  return value;
}

function observationSha256(value) {
  return `sha256:${createHash('sha256').update(JSON.stringify(stableValue(value))).digest('hex')}`;
}

function createFixture() {
  const calls = [];
  let mappedBytes = new Uint8Array([4, 3, 2, 1]).buffer;
  const queue = {
    writeBuffer(buffer, offset, data) {
      calls.push(['writeBuffer', buffer.kind, offset, data.byteLength, arguments.length]);
    },
    writeTexture(destination, data, layout, size) {
      calls.push(['writeTexture', destination.texture.kind, data.byteLength, layout, size]);
    },
    submit(commandBuffers) {
      calls.push(['submit', commandBuffers.map((buffer) => buffer.kind)]);
    },
    async onSubmittedWorkDone() {
      calls.push(['synchronized']);
    },
  };
  const device = {
    queue,
    createShaderModule(descriptor) {
      if (descriptor.code.includes('INVALID')) throw new TypeError('invalid shader');
      const compilationInfoThrows = descriptor.code.includes('INFO_THROWS');
      return {
        kind: 'shaderModule',
        async getCompilationInfo() {
          if (compilationInfoThrows) throw new RangeError('compilation info unavailable');
          return {
            messages: [{
              type: 'warning',
              message: 'fixture warning',
              lineNum: 2,
              linePos: 3,
              offset: 4,
              length: 5,
            }],
          };
        },
      };
    },
    createComputePipeline(descriptor) {
      assert.equal(descriptor.compute.module.kind, 'shaderModule');
      return {
        kind: 'computePipeline',
        getBindGroupLayout(index) {
          return { kind: `bindGroupLayout:${index}` };
        },
      };
    },
    createRenderPipeline(descriptor) {
      assert.equal(descriptor.vertex.module.kind, 'shaderModule');
      return { kind: 'renderPipeline' };
    },
    createBuffer(descriptor) {
      return {
        kind: 'buffer',
        size: descriptor.size,
        async mapAsync() {},
        getMappedRange() { return mappedBytes; },
        unmap() {},
        destroy() {},
      };
    },
    createTexture() {
      return {
        kind: 'texture',
        createView() { return { kind: 'textureView' }; },
      };
    },
    createBindGroupLayout() { return { kind: 'bindGroupLayout' }; },
    createPipelineLayout() { return { kind: 'pipelineLayout' }; },
    createBindGroup(descriptor) {
      assert.equal(descriptor.entries[0].resource.buffer.kind, 'buffer');
      assert.equal(descriptor.self, descriptor);
      return { kind: 'bindGroup' };
    },
    createCommandEncoder() {
      calls.push(['createCommandEncoder', arguments.length]);
      return {
        kind: 'commandEncoder',
        beginComputePass() {
          calls.push(['beginComputePass', arguments.length]);
          return {
            kind: 'computePass',
            setPipeline(pipeline) { assert.equal(pipeline.kind, 'computePipeline'); },
            setBindGroup(_index, group) { assert.equal(group.kind, 'bindGroup'); },
            dispatchWorkgroups() {},
            end() {},
          };
        },
        beginRenderPass() {
          return {
            kind: 'renderPass',
            setPipeline(pipeline) { assert.equal(pipeline.kind, 'renderPipeline'); },
            draw() {},
            end() {},
          };
        },
        copyBufferToBuffer(source, _sourceOffset, target) {
          assert.equal(source.kind, 'buffer');
          assert.equal(target.kind, 'buffer');
        },
        finish() { return { kind: 'commandBuffer' }; },
      };
    },
  };
  const adapter = {
    async requestDevice() { return device; },
  };
  const gpu = {
    async requestAdapter() { return adapter; },
  };
  return {
    gpu,
    adapter,
    calls,
    setMappedBytes(value) { mappedBytes = value; },
  };
}

async function exercise() {
  const fixture = createFixture();
  const checkpoints = [];
  const observer = createTransparentWebGPUObserver({
    gpu: fixture.gpu,
    adapter: fixture.adapter,
    globals: { GPUMapMode: { READ: 1, WRITE: 2 } },
    providerId: 'fixture-provider',
    metadata: { workload: 'observer-contract' },
    checkpoint(observation, context) {
      checkpoints.push({ observation, context });
    },
  });
  const adapter = observer.adapter;
  const device = await adapter.requestDevice();
  const createBindGroupLayout = device.createBindGroupLayout.bind(device);
  device.createBindGroupLayout = (descriptor) => createBindGroupLayout(descriptor);
  const patchedLayout = device.createBindGroupLayout({
    entries: [{ binding: 0, visibility: 1, buffer: { type: 'storage' } }],
  });
  assert.equal(patchedLayout.kind, 'bindGroupLayout');
  const module = device.createShaderModule({
    code: '@compute @workgroup_size(8, 2) fn main() {}',
  });
  const compilationInfo = await module.getCompilationInfo();
  assert.equal(compilationInfo.messages[0].message, 'fixture warning');
  const infoThrowsModule = device.createShaderModule({ code: 'INFO_THROWS' });
  await assert.rejects(
    () => infoThrowsModule.getCompilationInfo(),
    /compilation info unavailable/,
  );
  assert.throws(
    () => device.createShaderModule({ code: 'INVALID' }),
    /invalid shader/,
  );
  const compute = device.createComputePipeline({
    layout: 'auto',
    compute: { module, entryPoint: 'main' },
  });
  const render = device.createRenderPipeline({
    layout: 'auto',
    vertex: { module, entryPoint: 'main' },
  });
  const input = device.createBuffer({ size: 4, usage: 1 });
  const output = device.createBuffer({ size: 4, usage: 3 });
  const texture = device.createTexture({ size: [1, 1, 1], format: 'rgba8unorm', usage: 1 });
  const view = texture.createView();
  const layout = compute.getBindGroupLayout(0);
  const bindGroupDescriptor = {
    layout,
    entries: [{ binding: 0, resource: { buffer: input } }],
  };
  bindGroupDescriptor.self = bindGroupDescriptor;
  const bindGroup = device.createBindGroup(bindGroupDescriptor);
  device.queue.writeBuffer(input, 0, new Uint8Array([1, 2, 3, 4]));
  device.queue.writeTexture(
    { texture },
    new Uint8Array([9, 8, 7, 6]),
    { bytesPerRow: 4 },
    { width: 1, height: 1, depthOrArrayLayers: 1 },
  );
  const encoder = device.createCommandEncoder();
  const computePass = encoder.beginComputePass();
  computePass.setPipeline(compute);
  computePass.setBindGroup(0, bindGroup);
  computePass.dispatchWorkgroups(2, 3, 4);
  computePass.end();
  const renderPass = encoder.beginRenderPass({
    colorAttachments: [{ view, loadOp: 'clear', storeOp: 'store' }],
  });
  renderPass.setPipeline(render);
  renderPass.draw(3, 2, 1, 0);
  renderPass.end();
  encoder.copyBufferToBuffer(input, 0, output, 0, 4);
  const commandBuffer = encoder.finish();
  device.queue.submit([commandBuffer]);
  await device.queue.onSubmittedWorkDone();
  await output.mapAsync(1, 0, 4);
  assert.deepEqual([...new Uint8Array(output.getMappedRange())], [4, 3, 2, 1]);

  const snapshot = observer.snapshot();
  assert.deepEqual(validateTransparentWebGPUObservation(snapshot), {
    valid: true,
    errors: [],
  });
  assert.equal(snapshot.providerId, 'fixture-provider');
  assert.equal(snapshot.shaderModules.length, 3);
  assert.equal(snapshot.compilationInfos.length, 2);
  assert.deepEqual(snapshot.compilationInfos[0], {
    shaderModuleId: snapshot.shaderModules[0].id,
    status: 'returned',
    messages: [{
      type: 'warning',
      message: 'fixture warning',
      lineNum: 2,
      linePos: 3,
      offset: 4,
      length: 5,
    }],
  });
  assert.deepEqual(snapshot.compilationInfos[1], {
    shaderModuleId: snapshot.shaderModules[1].id,
    status: 'threw',
    messages: [],
    errorName: 'RangeError',
    errorMessage: 'compilation info unavailable',
  });
  assert.equal(snapshot.shaderModules[0].creation, 'returned');
  assert.equal(snapshot.shaderModules[1].creation, 'returned');
  assert.equal(snapshot.shaderModules[2].creation, 'threw');
  assert.deepEqual(snapshot.shaderModules[0].workgroupSize, [8, 2, 1]);
  assert.equal(snapshot.computePipelines.length, 1);
  assert.equal(snapshot.renderPipelines.length, 1);
  assert.equal(snapshot.dispatches.length, 1);
  assert.deepEqual(snapshot.dispatches[0].workgroups, [2, 3, 4]);
  assert.equal(snapshot.draws.length, 1);
  assert.equal(snapshot.submissions.length, 1);
  assert.equal(snapshot.synchronizations.length, 2);
  assert.deepEqual(
    snapshot.synchronizations.map(({ kind }) => kind),
    ['queue.onSubmittedWorkDone', 'buffer.mapAsync'],
  );
  assert.equal(snapshot.readbacks.length, 1);
  const recordedBindGroup = snapshot.resources.find(({ kind }) => kind === 'bindGroup');
  assert.deepEqual(recordedBindGroup.descriptor.self, { localRef: 1 });
  assert.equal(checkpoints.length, 3);
  assert.equal(checkpoints[0].context.reason, 'compilation-info');
  assert.equal(checkpoints[0].observation.summary.compilationInfoCount, 1);
  assert.equal(checkpoints[1].context.reason, 'compilation-info');
  assert.equal(checkpoints[1].observation.summary.compilationInfoCount, 2);
  assert.equal(checkpoints[2].context.reason, 'mapped-readback');
  assert.equal(checkpoints[2].observation.summary.readbackCount, 1);
  assert.match(snapshot.readbacks[0].dataSha256, /^sha256:[a-f0-9]{64}$/);
  assert.ok(fixture.calls.some(([name]) => name === 'submit'));
  assert.ok(fixture.calls.some(([name, length]) => name === 'createCommandEncoder' && length === 0));
  assert.ok(fixture.calls.some(([name, length]) => name === 'beginComputePass' && length === 0));
  assert.ok(fixture.calls.some(
    ([name, _kind, _offset, _byteLength, length]) => name === 'writeBuffer' && length === 3,
  ));
  return snapshot;
}

const first = await exercise();
const second = await exercise();
assert.equal(
  first.observationSha256,
  second.observationSha256,
  'identical public command sequences must produce a stable observation identity',
);
const legacy = structuredClone(first);
delete legacy.compilationInfos;
delete legacy.summary.compilationInfoCount;
delete legacy.observationSha256;
legacy.observationSha256 = observationSha256(legacy);
assert.deepEqual(
  validateTransparentWebGPUObservation(legacy),
  { valid: true, errors: [] },
  'additive compilation diagnostics must not invalidate earlier v1 observations',
);
const tampered = structuredClone(first);
tampered.summary.dispatchCount += 1;
assert.equal(validateTransparentWebGPUObservation(tampered).valid, false);
assert.equal(validateTransparentWebGPUObservation(null).valid, false);
assert.throws(
  () => createTransparentWebGPUObserver({ gpu: createFixture().gpu, metadata: [] }),
  /metadata must be a plain object/,
);

const schema = JSON.parse(await readFile(
  new URL('../../assets/transparent-webgpu-observation.schema.json', import.meta.url),
  'utf8',
));
assert.equal(schema.$schema, 'https://json-schema.org/draft/2020-12/schema');
assert.equal(schema.properties.schema.const, first.schema);

console.log('transparent WebGPU observer contracts: ok');

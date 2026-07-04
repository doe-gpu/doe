import { globals } from './webgpu-constants.js';
import {
  setupGlobalsOnTarget,
  buildProviderInfo,
} from './shared/public-surface.js';
import { createEncoderClasses } from './shared/encoder-surface.js';
import {
  createFullSurfaceClasses,
  GPUValidationError,
  GPUOutOfMemoryError,
  GPUInternalError,
  GPUDeviceLostInfo,
  GPUUncapturedErrorEvent,
} from './shared/full-surface.js';
import {
  CANVAS_ALPHA_MODES,
  CANVAS_TONE_MAPPING_MODES,
  CANVAS_COLOR_SPACES,
  normalizeOrigin2D,
  normalizeCanvasConfiguration,
  createBrowserSurfaceClasses,
} from './shared/browser-surface.js';
import { createNativeBrowserCanvasBackend } from './shared/browser-native-canvas-backend.js';
import { failValidation } from './shared/resource-lifecycle.js';

const EMPTY_ADAPTER_INFO = Object.freeze({
  vendor: '',
  architecture: '',
  device: '',
  description: '',
  subgroupMinSize: 0,
  subgroupMaxSize: 0,
});
const WEBGPU_GLOBALS = Object.freeze({
  ...globals,
  GPUValidationError,
  GPUOutOfMemoryError,
  GPUInternalError,
  GPUDeviceLostInfo,
  GPUUncapturedErrorEvent,
});

function unwrap_native(value) {
  return value && typeof value === 'object' && '_native' in value ? value._native : value;
}

function normalize_origin3d(origin) {
  if (origin === undefined || origin === null) {
    return { x: 0, y: 0, z: 0 };
  }
  if (Array.isArray(origin)) {
    return { x: origin[0] ?? 0, y: origin[1] ?? 0, z: origin[2] ?? 0 };
  }
  return {
    x: origin.x ?? 0,
    y: origin.y ?? 0,
    z: origin.z ?? 0,
  };
}

function assert_browser_object(value, path, label, method) {
  if (!value || typeof value !== 'object' || (method && typeof value[method] !== 'function')) {
    failValidation(path, `${label} must be a native browser WebGPU object`);
  }
  return value;
}

function resolve_native_gpu(options, path, { required = true } = {}) {
  const native_gpu = options?.gpu ?? globalThis.navigator?.gpu ?? null;
  if (!native_gpu && required) {
    failValidation(
      path,
      'native browser navigator.gpu is unavailable; pass { gpu } explicitly or run inside a WebGPU-capable browser context',
    );
  }
  if (native_gpu && typeof native_gpu.requestAdapter !== 'function') {
    failValidation(path, 'gpu must expose requestAdapter(...)');
  }
  return native_gpu;
}

function resolve_canvas_backend(options) {
  return options?.canvasBackend ?? createNativeBrowserCanvasBackend({
    contextFactory: options?.contextFactory,
  });
}

function normalize_bind_group_entry(entry) {
  let resource;
  if (entry.buffer) {
    resource = {
      buffer: unwrap_native(entry.buffer),
      offset: entry.offset ?? 0,
      ...(entry.size === undefined ? {} : { size: entry.size }),
    };
  } else if (entry.sampler) {
    resource = unwrap_native(entry.sampler);
  } else if (entry.textureView) {
    resource = unwrap_native(entry.textureView);
  } else if (entry.externalTexture) {
    resource = unwrap_native(entry.externalTexture);
  }
  return {
    binding: entry.binding,
    resource,
  };
}

function normalize_render_pass_descriptor(descriptor) {
  return {
    ...descriptor,
    colorAttachments: (descriptor.colorAttachments ?? []).map((attachment) => {
      if (!attachment) {
        return attachment;
      }
      return {
        ...attachment,
        view: unwrap_native(attachment.view),
        resolveTarget: unwrap_native(attachment.resolveTarget),
      };
    }),
    depthStencilAttachment: descriptor.depthStencilAttachment
      ? {
        ...descriptor.depthStencilAttachment,
        view: unwrap_native(descriptor.depthStencilAttachment.view),
      }
      : undefined,
  };
}

function assert_open_encoder(target, path, label) {
  if (!target._open || !target._native) {
    failValidation(path, `${label} is closed`);
  }
}

function init_encoder_state(target, native) {
  target._native = native;
  target._open = true;
}

function create_browser_backend({ native_gpu, canvasBackend }) {
  return {
    preflightShaderSource() {
      return { ok: true, stage: '', kind: '', message: '', reasons: [] };
    },

    gpuRequestAdapter: async (gpu, options, classes) => {
      if (!native_gpu) {
        failValidation('GPU.requestAdapter', 'native browser GPU object is unavailable');
      }
      const request_options = options == null ? undefined : { ...options };
      const native_adapter = await native_gpu.requestAdapter(request_options);
      if (native_adapter == null) {
        return null;
      }
      return new classes.DoeGPUAdapter(native_adapter, gpu._instance);
    },

    adapterDestroy(native) {
      native.destroy?.();
    },

    adapterFeatures(native) {
      return native.features;
    },

    adapterGetInfo(_adapter, native) {
      return native.info ?? EMPTY_ADAPTER_INFO;
    },

    adapterLimits(native) {
      return native.limits;
    },

    adapterRequestDevice: async (adapter, descriptor, classes) => {
      const native_adapter = assert_browser_object(adapter._native, 'GPUAdapter.requestDevice', 'GPUAdapter', 'requestDevice');
      const native_device = await native_adapter.requestDevice(descriptor);
      return new classes.DoeGPUDevice(native_device, adapter._instance, adapter.limits, adapter.features);
    },

    initBufferState() {},

    bufferAssertMappedPrefixF32(_buffer, native, expected, count) {
      const actual = new Float32Array(native.getMappedRange(0, count * Float32Array.BYTES_PER_ELEMENT));
      for (let index = 0; index < count; index += 1) {
        if (actual[index] !== expected) {
          failValidation(
            'GPUBuffer.assertMappedPrefixF32',
            `expected readback[${index}] === ${expected}, got ${actual[index]}`,
          );
        }
      }
    },

    bufferDestroy(native) {
      native.destroy();
    },

    bufferGetMappedRange(_buffer, native, offset, size) {
      return native.getMappedRange(offset, size);
    },

    bufferMapAsync(_buffer, native, mode, offset, size) {
      return native.mapAsync(mode, offset, size);
    },

    bufferMarkMappedAtCreation() {},

    bufferReadCopy(_buffer, native, offset, size) {
      return native.getMappedRange(offset, size).slice(0);
    },

    bufferUnmap(native) {
      native.unmap();
    },

    computePipelineGetBindGroupLayout(pipeline, index, classes) {
      return new classes.DoeGPUBindGroupLayout(pipeline._native.getBindGroupLayout(index), pipeline._device);
    },

    deviceCreateBindGroup(device, layout_native, entries, label) {
      return device._native.createBindGroup({
        layout: layout_native,
        entries: entries.map(normalize_bind_group_entry),
        ...(label === undefined ? {} : { label }),
      });
    },

    deviceCreateBindGroupLayout(device, entries, label) {
      return device._native.createBindGroupLayout({
        entries,
        ...(label === undefined ? {} : { label }),
      });
    },

    deviceCreateBuffer(device, descriptor) {
      return device._native.createBuffer(descriptor);
    },

    deviceCreateCommandEncoder(device, descriptor, classes) {
      return new classes.DoeGPUCommandEncoder(device._native.createCommandEncoder(descriptor), device);
    },

    deviceCreateComputePipeline(device, shader_native, entryPoint, layout_native, constants, label) {
      return device._native.createComputePipeline({
        layout: layout_native ?? 'auto',
        compute: {
          module: shader_native,
          entryPoint,
          ...(constants ? { constants } : {}),
        },
        ...(label === undefined ? {} : { label }),
      });
    },

    async deviceCreateComputePipelineAsync(device, shader_native, entryPoint, layout_native, constants, label) {
      if (typeof device._native.createComputePipelineAsync !== 'function') {
        return this.deviceCreateComputePipeline(device, shader_native, entryPoint, layout_native, constants, label);
      }
      return device._native.createComputePipelineAsync({
        layout: layout_native ?? 'auto',
        compute: {
          module: shader_native,
          entryPoint,
          ...(constants ? { constants } : {}),
        },
        ...(label === undefined ? {} : { label }),
      });
    },

    deviceCreatePipelineLayout(device, layouts, label) {
      return device._native.createPipelineLayout({
        bindGroupLayouts: layouts.map(unwrap_native),
        ...(label === undefined ? {} : { label }),
      });
    },

    deviceCreateQuerySet(device, descriptor) {
      return device._native.createQuerySet?.(descriptor) ?? null;
    },

    deviceCreateRenderBundleEncoder(device, descriptor, classes) {
      return new classes.DoeGPURenderBundleEncoder(device._native.createRenderBundleEncoder(descriptor), device);
    },

    deviceCreateRenderPipeline(device, descriptor) {
      return device._native.createRenderPipeline({
        layout: descriptor.layout ?? 'auto',
        vertex: {
          module: descriptor.vertexModule,
          entryPoint: descriptor.vertexEntryPoint,
          buffers: descriptor.vertexBuffers,
        },
        fragment: {
          module: descriptor.fragmentModule,
          entryPoint: descriptor.fragmentEntryPoint,
          targets: [{ format: descriptor.fragmentTarget?.format ?? descriptor.colorFormat }],
        },
        ...(descriptor.primitive ? { primitive: descriptor.primitive } : {}),
        ...(descriptor.depthStencil ? { depthStencil: descriptor.depthStencil } : {}),
        ...(descriptor.multisample ? { multisample: descriptor.multisample } : {}),
      });
    },

    async deviceCreateRenderPipelineAsync(device, descriptor) {
      if (typeof device._native.createRenderPipelineAsync !== 'function') {
        return this.deviceCreateRenderPipeline(device, descriptor);
      }
      return device._native.createRenderPipelineAsync({
        layout: descriptor.layout ?? 'auto',
        vertex: {
          module: descriptor.vertexModule,
          entryPoint: descriptor.vertexEntryPoint,
          buffers: descriptor.vertexBuffers,
        },
        fragment: {
          module: descriptor.fragmentModule,
          entryPoint: descriptor.fragmentEntryPoint,
          targets: [{ format: descriptor.fragmentTarget?.format ?? descriptor.colorFormat }],
        },
        ...(descriptor.primitive ? { primitive: descriptor.primitive } : {}),
        ...(descriptor.depthStencil ? { depthStencil: descriptor.depthStencil } : {}),
        ...(descriptor.multisample ? { multisample: descriptor.multisample } : {}),
      });
    },

    deviceCreateSampler(device, descriptor) {
      return device._native.createSampler(descriptor);
    },

    deviceCreateShaderModule(device, code, hints) {
      return device._native.createShaderModule({
        code,
        ...(hints ? { compilationHints: hints } : {}),
      });
    },

    deviceCreateTexture(device, descriptor) {
      return device._native.createTexture(descriptor);
    },

    deviceDestroy(native) {
      native.destroy();
    },

    deviceFeatures(native) {
      return native.features;
    },

    deviceGetAdapterInfo(_device, native) {
      return native.adapterInfo ?? EMPTY_ADAPTER_INFO;
    },

    deviceGetLost(device, native) {
      return native.lost ?? device._lost;
    },

    deviceGetOnUncapturedError(_device, native) {
      return native.onuncapturederror ?? null;
    },

    deviceGetQueue(native) {
      return native.queue;
    },

    deviceImportExternalTexture(device, native, descriptor, classes) {
      return canvasBackend.deviceImportExternalTexture(device, native, descriptor, classes);
    },

    deviceLimits(native) {
      return native.limits;
    },

    devicePopErrorScope(_device, native) {
      if (typeof native.popErrorScope !== 'function') {
        return Promise.resolve(null);
      }
      return native.popErrorScope();
    },

    devicePushErrorScope(_device, native, filter) {
      native.pushErrorScope?.(filter);
    },

    deviceSetOnUncapturedError(_device, native, handler) {
      native.onuncapturederror = handler;
    },

    initDeviceState() {},

    initQueueState(queue) {
      queue._pendingSubmissions = 0;
    },

    querySetDestroy(native) {
      native.destroy?.();
    },

    queueCopyExternalImageToTexture(queue, native, source, destination, copySize) {
      return canvasBackend.queueCopyExternalImageToTexture(
        queue,
        native,
        {
          ...source,
          origin: normalizeOrigin2D(source.origin, 'GPUQueue.copyExternalImageToTexture(source.origin)'),
        },
        {
          ...destination,
          origin: normalize_origin3d(destination.origin),
        },
        copySize,
      );
    },

    queueHasPendingSubmissions(queue) {
      return queue._pendingSubmissions > 0;
    },

    queueMarkSubmittedWorkDone(queue) {
      queue._pendingSubmissions = 0;
    },

    queueOnSubmittedWorkDone(_queue, native) {
      return native.onSubmittedWorkDone();
    },

    queueSubmit(queue, native, commandBuffers) {
      queue._pendingSubmissions += 1;
      const submitted = native.submit(commandBuffers.map((commandBuffer, index) => {
        if (commandBuffer?._submitted) {
          failValidation('GPUQueue.submit', `commandBuffers[${index}] was already submitted`);
        }
        return unwrap_native(commandBuffer);
      }));
      for (const commandBuffer of commandBuffers) {
        if (commandBuffer && typeof commandBuffer === 'object') {
          commandBuffer._submitted = true;
          commandBuffer.destroy?.();
        }
      }
      return submitted;
    },

    queueWriteBuffer(_queue, native, buffer_native, bufferOffset, view) {
      return native.writeBuffer(buffer_native, bufferOffset, view);
    },

    queueWriteTexture(_queue, native, destination, view, layout, size) {
      return native.writeTexture(destination, view, layout, size);
    },

    renderPipelineGetBindGroupLayout(pipeline, index, classes) {
      return new classes.DoeGPUBindGroupLayout(pipeline._native.getBindGroupLayout(index), pipeline._resourceOwner);
    },

    renderBundleEncoderAssertOpen(encoder, path) {
      assert_open_encoder(encoder, path, 'GPURenderBundleEncoder');
    },

    renderBundleEncoderDraw(encoder, vertexCount, instanceCount, firstVertex, firstInstance) {
      encoder._native.draw(vertexCount, instanceCount, firstVertex, firstInstance);
    },

    renderBundleEncoderDrawIndexed(encoder, indexCount, instanceCount, firstIndex, baseVertex, firstInstance) {
      encoder._native.drawIndexed(indexCount, instanceCount, firstIndex, baseVertex, firstInstance);
    },

    renderBundleEncoderDrawIndexedIndirect(encoder, indirectBuffer, indirectOffset) {
      encoder._native.drawIndexedIndirect(indirectBuffer, indirectOffset);
    },

    renderBundleEncoderDrawIndirect(encoder, indirectBuffer, indirectOffset) {
      encoder._native.drawIndirect(indirectBuffer, indirectOffset);
    },

    renderBundleEncoderPushDebugGroup(encoder, label) {
      encoder._native.pushDebugGroup(label);
    },

    renderBundleEncoderPopDebugGroup(encoder) {
      encoder._native.popDebugGroup();
    },

    renderBundleEncoderInsertDebugMarker(encoder, label) {
      encoder._native.insertDebugMarker(label);
    },

    renderBundleEncoderFinish(encoder, descriptor, classes) {
      const native_bundle = encoder._native.finish(descriptor);
      encoder._open = false;
      return new classes.DoeGPURenderBundle(native_bundle, encoder._device);
    },

    renderBundleEncoderInit(encoder, native) {
      init_encoder_state(encoder, native);
    },

    renderBundleEncoderSetBindGroup(encoder, index, bindGroup) {
      encoder._native.setBindGroup(index, bindGroup);
    },

    renderBundleEncoderSetIndexBuffer(encoder, buffer, format, offset, size) {
      encoder._native.setIndexBuffer(buffer, format, offset, size);
    },

    renderBundleEncoderSetPipeline(encoder, pipeline) {
      encoder._native.setPipeline(pipeline);
    },

    renderBundleEncoderSetVertexBuffer(encoder, slot, buffer, offset, size) {
      encoder._native.setVertexBuffer(slot, buffer, offset, size);
    },

    renderPassAssertOpen(pass, path) {
      assert_open_encoder(pass, path, 'GPURenderPassEncoder');
    },

    renderPassBeginOcclusionQuery(pass, queryIndex) {
      pass._native.beginOcclusionQuery(queryIndex);
    },

    renderPassDraw(pass, vertexCount, instanceCount, firstVertex, firstInstance) {
      pass._native.draw(vertexCount, instanceCount, firstVertex, firstInstance);
    },

    renderPassDrawIndexed(pass, indexCount, instanceCount, firstIndex, baseVertex, firstInstance) {
      pass._native.drawIndexed(indexCount, instanceCount, firstIndex, baseVertex, firstInstance);
    },

    renderPassDrawIndexedIndirect(pass, indirectBuffer, indirectOffset) {
      pass._native.drawIndexedIndirect(indirectBuffer, indirectOffset);
    },

    renderPassDrawIndirect(pass, indirectBuffer, indirectOffset) {
      pass._native.drawIndirect(indirectBuffer, indirectOffset);
    },

    renderPassEnd(pass) {
      pass._native.end();
      pass._open = false;
    },

    renderPassEndOcclusionQuery(pass) {
      pass._native.endOcclusionQuery();
    },

    renderPassExecuteBundles(pass, bundles) {
      pass._native.executeBundles(bundles.map(unwrap_native));
    },

    renderPassInit(pass, native) {
      init_encoder_state(pass, native);
    },

    renderPassSetBindGroup(pass, index, bindGroup) {
      pass._native.setBindGroup(index, bindGroup);
    },

    renderPassSetBlendConstant(pass, color) {
      pass._native.setBlendConstant(color);
    },

    renderPassSetIndexBuffer(pass, buffer, format, offset, size) {
      pass._native.setIndexBuffer(buffer, format, offset, size);
    },

    renderPassSetPipeline(pass, pipeline) {
      pass._native.setPipeline(pipeline);
    },

    renderPassSetScissorRect(pass, x, y, width, height) {
      pass._native.setScissorRect(x, y, width, height);
    },

    renderPassSetStencilReference(pass, reference) {
      pass._native.setStencilReference(reference);
    },

    renderPassSetVertexBuffer(pass, slot, buffer, offset, size) {
      pass._native.setVertexBuffer(slot, buffer, offset, size);
    },

    renderPassSetViewport(pass, x, y, width, height, minDepth, maxDepth) {
      pass._native.setViewport(x, y, width, height, minDepth, maxDepth);
    },

    computePassPushDebugGroup(pass, label) {
      pass._native.pushDebugGroup(label);
    },

    computePassPopDebugGroup(pass) {
      pass._native.popDebugGroup();
    },

    computePassInsertDebugMarker(pass, label) {
      pass._native.insertDebugMarker(label);
    },

    requireAutoLayoutEntriesFromNative() {
      return null;
    },

    shaderModuleDestroy(native) {
      native.destroy?.();
    },

    shaderModuleGetCompilationInfo(_module, native) {
      if (typeof native.getCompilationInfo !== 'function') {
        return Promise.resolve({ messages: [] });
      }
      return native.getCompilationInfo();
    },

    textureCreateView(_texture, native, descriptor) {
      return native.createView(descriptor);
    },

    textureDestroy(native, texture) {
      if (texture?._externallyOwned) {
        return;
      }
      native.destroy?.();
    },

    commandEncoderAssertOpen(encoder, path) {
      assert_open_encoder(encoder, path, 'GPUCommandEncoder');
    },

    commandEncoderBeginComputePass(encoder, descriptor, classes) {
      return new classes.DoeGPUComputePassEncoder(encoder._native.beginComputePass(descriptor), encoder);
    },

    commandEncoderBeginRenderPass(encoder, descriptor, classes) {
      return new classes.DoeGPURenderPassEncoder(
        encoder._native.beginRenderPass(normalize_render_pass_descriptor(descriptor)),
        encoder,
      );
    },

    commandEncoderClearBuffer(encoder, buffer, offset, size) {
      encoder._native.clearBuffer(buffer, offset, size);
    },

    commandEncoderPushDebugGroup(encoder, label) {
      encoder._native.pushDebugGroup(label);
    },

    commandEncoderPopDebugGroup(encoder) {
      encoder._native.popDebugGroup();
    },

    commandEncoderInsertDebugMarker(encoder, label) {
      encoder._native.insertDebugMarker(label);
    },

    commandEncoderCopyBufferToBuffer(encoder, source, sourceOffset, destination, destinationOffset, size) {
      encoder._native.copyBufferToBuffer(source, sourceOffset, destination, destinationOffset, size);
    },

    commandEncoderCopyBufferToTexture(encoder, source, destination, copySize) {
      encoder._native.copyBufferToTexture(source, destination, copySize);
    },

    commandEncoderCopyTextureToBuffer(encoder, source, destination, copySize) {
      encoder._native.copyTextureToBuffer(source, destination, copySize);
    },

    commandEncoderCopyTextureToTexture(encoder, source, destination, copySize) {
      encoder._native.copyTextureToTexture(source, destination, copySize);
    },

    commandEncoderFinish(encoder) {
      const command_buffer = encoder._native.finish();
      encoder._open = false;
      return { _native: command_buffer, _batched: false };
    },

    commandEncoderInit(encoder, native) {
      init_encoder_state(encoder, native);
    },

    commandEncoderResolveQuerySet(encoder, querySet, firstQuery, queryCount, destination, destinationOffset) {
      encoder._native.resolveQuerySet(querySet, firstQuery, queryCount, destination, destinationOffset);
    },

    commandEncoderWriteTimestamp(encoder, querySet, queryIndex) {
      encoder._native.writeTimestamp(querySet, queryIndex);
    },

    computePassAssertOpen(pass, path) {
      assert_open_encoder(pass, path, 'GPUComputePassEncoder');
    },

    computePassDispatchWorkgroups(pass, x, y, z) {
      pass._native.dispatchWorkgroups(x, y, z);
    },

    computePassDispatchWorkgroupsIndirect(pass, indirectBuffer, indirectOffset) {
      pass._native.dispatchWorkgroupsIndirect(indirectBuffer, indirectOffset);
    },

    computePassEnd(pass) {
      pass._native.end();
      pass._open = false;
    },

    computePassInit(pass, native) {
      init_encoder_state(pass, native);
    },

    computePassSetBindGroup(pass, index, bindGroup) {
      pass._native.setBindGroup(index, bindGroup);
    },

    computePassSetPipeline(pass, pipeline) {
      pass._native.setPipeline(pipeline);
    },
  };
}

function create_browser_runtime_internal(options = {}) {
  const native_gpu = resolve_native_gpu(options, 'createBrowserRuntime', { required: false });
  const canvasBackend = resolve_canvas_backend(options);
  const backend = create_browser_backend({ native_gpu, canvasBackend });
  const encoderClasses = createEncoderClasses(backend);
  const fullClasses = createFullSurfaceClasses({ globals, backend, encoderClasses });
  Object.assign(fullClasses, encoderClasses);
  const classes = createBrowserSurfaceClasses({ canvasBackend, fullClasses });
  const wrapped_gpu = native_gpu ? new classes.DoeGPU(native_gpu) : null;
  if (wrapped_gpu && native_gpu) {
    wrapped_gpu._native = native_gpu;
    wrapped_gpu.getPreferredCanvasFormat = function getPreferredCanvasFormat() {
      return native_gpu.getPreferredCanvasFormat?.() ?? 'bgra8unorm';
    };
    setupGlobalsOnTarget(globalThis, wrapped_gpu, WEBGPU_GLOBALS);
  }
  return {
    nativeGpu: native_gpu,
    canvasBackend,
    classes,
    gpu: wrapped_gpu,
    createCanvasContext(canvas) {
      return new classes.DoeGPUCanvasContext(canvas);
    },
    bindAdapter(adapter) {
      const native_adapter = assert_browser_object(adapter, 'bindAdapter', 'adapter', 'requestDevice');
      return new classes.DoeGPUAdapter(native_adapter, wrapped_gpu?._instance ?? native_gpu ?? null);
    },
    bindDevice(device) {
      const native_device = assert_browser_object(device, 'bindDevice', 'device', 'createBuffer');
      return new classes.DoeGPUDevice(native_device, wrapped_gpu?._instance ?? native_gpu ?? null);
    },
  };
}

export function createBrowserRuntime(options = {}) {
  const runtime = create_browser_runtime_internal(options);
  if (!runtime.gpu) {
    failValidation(
      'createBrowserRuntime',
      'native browser navigator.gpu is unavailable; pass { gpu } explicitly or run inside a WebGPU-capable browser context',
    );
  }
  return runtime;
}

export function create(options = {}) {
  return createBrowserRuntime(options).gpu;
}

export function createInstance(options = {}) {
  return create(options);
}

export function setupGlobals(target = globalThis, options = {}) {
  return setupGlobalsOnTarget(target, create(options), WEBGPU_GLOBALS);
}

export async function requestAdapter(adapterOptions = undefined, options = {}) {
  return create(options).requestAdapter(adapterOptions);
}

export async function requestDevice(options = {}) {
  const adapter = await requestAdapter(options?.adapterOptions, options);
  if (!adapter) {
    throw new Error('requestDevice: native browser GPUAdapter request returned null');
  }
  return adapter.requestDevice(options?.deviceDescriptor);
}

export function bindAdapter(adapter, options = {}) {
  return create_browser_runtime_internal(options).bindAdapter(adapter);
}

export function bindDevice(device, options = {}) {
  return create_browser_runtime_internal(options).bindDevice(device);
}

export function createCanvasContext(canvas, options = {}) {
  return create_browser_runtime_internal(options).createCanvasContext(canvas);
}

export function providerInfo() {
  const native_gpu = globalThis.navigator?.gpu ?? null;
  return buildProviderInfo({
    moduleName: 'doe-gpu/browser',
    loaded: Boolean(native_gpu),
    loadError: native_gpu ? '' : 'native browser navigator.gpu is unavailable',
    defaultCreateArgs: [],
    doeNative: false,
    libraryFlavor: 'browser-native',
    doeLibraryPath: '',
    buildMetadataSource: 'not-applicable',
    buildMetadataPath: '',
    leanVerifiedBuild: false,
    proofArtifactSha256: null,
  });
}

export {
  globals,
  CANVAS_ALPHA_MODES,
  CANVAS_TONE_MAPPING_MODES,
  CANVAS_COLOR_SPACES,
  normalizeOrigin2D,
  normalizeCanvasConfiguration,
  createBrowserSurfaceClasses,
  createNativeBrowserCanvasBackend,
};

export default {
  createBrowserRuntime,
  create,
  createInstance,
  setupGlobals,
  requestAdapter,
  requestDevice,
  bindAdapter,
  bindDevice,
  createCanvasContext,
  providerInfo,
  globals,
  CANVAS_ALPHA_MODES,
  CANVAS_TONE_MAPPING_MODES,
  CANVAS_COLOR_SPACES,
  normalizeOrigin2D,
  normalizeCanvasConfiguration,
  createBrowserSurfaceClasses,
  createNativeBrowserCanvasBackend,
};

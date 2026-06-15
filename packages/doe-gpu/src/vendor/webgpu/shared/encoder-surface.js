import {
  UINT32_MAX,
  failValidation,
  initResource,
  assertObject,
  assertArray,
  assertIntegerInRange,
  assertLiveResource,
  destroyResource,
} from './resource-lifecycle.js';

const UINT32_RANGE = Object.freeze({ min: 0, max: UINT32_MAX });
const NON_NEGATIVE_RANGE = Object.freeze({ min: 0 });
const POSITIVE_RANGE = Object.freeze({ min: 1 });
const POSITIVE_UINT32_RANGE = Object.freeze({ min: 1, max: UINT32_MAX });

function normalizeImmediateDataInput(data, dataOffset = 0, size, path) {
  const isSharedArrayBuffer = typeof SharedArrayBuffer !== 'undefined' && data instanceof SharedArrayBuffer;
  if (!ArrayBuffer.isView(data) && !(data instanceof ArrayBuffer) && !isSharedArrayBuffer) {
    failValidation(path, 'data must be an ArrayBuffer, SharedArrayBuffer, TypedArray, or DataView');
  }
  assertIntegerInRange(dataOffset, path, 'dataOffset', { min: 0 });
  if (size !== undefined) {
    assertIntegerInRange(size, path, 'size', { min: 0 });
  }
  const bytes = ArrayBuffer.isView(data)
    ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
    : new Uint8Array(data);
  const end = size === undefined ? bytes.byteLength : dataOffset + size;
  if (end > bytes.byteLength) {
    failValidation(path, `data range ${dataOffset}+${size ?? (bytes.byteLength - dataOffset)} exceeds source byteLength ${bytes.byteLength}`);
  }
  return bytes.subarray(dataOffset, end);
}

function createEncoderClasses(backend) {
  let classes = null;

  const _hasComputePassAssertOpen = typeof backend.computePassAssertOpen === 'function';
  const commandBufferFinalizer = typeof FinalizationRegistry === 'function' && typeof backend.commandBufferDestroy === 'function'
    ? new FinalizationRegistry((native) => {
      backend.commandBufferDestroy(native);
    })
    : null;

  function releaseCommandBuffer(commandBuffer) {
    if (commandBuffer._destroyed) {
      return;
    }
    if (commandBuffer._finalizerToken && commandBufferFinalizer) {
      commandBufferFinalizer.unregister(commandBuffer._finalizerToken);
      commandBuffer._finalizerToken = null;
    }
    commandBuffer._commands = [];
    const native = commandBuffer._native;
    commandBuffer._native = null;
    commandBuffer._destroyed = true;
    if (native != null && typeof backend.commandBufferDestroy === 'function') {
      backend.commandBufferDestroy(native);
    }
  }

  class DoeGPUComputePassEncoder {
    constructor(state, encoder) {
      this._encoder = encoder;
      this.label = '';
      initResource(this, 'GPUComputePassEncoder', encoder);
      backend.computePassInit(this, state);
    }

    _assertOpen(path) {
      if (_hasComputePassAssertOpen) {
        backend.computePassAssertOpen(this, path);
      }
    }

    setPipeline(pipeline) {
      this._assertOpen('GPUComputePassEncoder.setPipeline');
      backend.computePassSetPipeline(
        this,
        assertLiveResource(pipeline, 'GPUComputePassEncoder.setPipeline', 'GPUComputePipeline'),
      );
    }

    setBindGroup(index, bindGroup) {
      this._assertOpen('GPUComputePassEncoder.setBindGroup');
      assertIntegerInRange(index, 'GPUComputePassEncoder.setBindGroup', 'index', UINT32_RANGE);
      backend.computePassSetBindGroup(
        this,
        index,
        assertLiveResource(bindGroup, 'GPUComputePassEncoder.setBindGroup', 'GPUBindGroup'),
      );
    }

    setImmediates(index, data, dataOffset = 0, size) {
      this._assertOpen('GPUComputePassEncoder.setImmediates');
      assertIntegerInRange(index, 'GPUComputePassEncoder.setImmediates', 'index', UINT32_RANGE);
      backend.computePassSetImmediates(
        this,
        index,
        normalizeImmediateDataInput(data, dataOffset, size, 'GPUComputePassEncoder.setImmediates'),
      );
    }

    dispatchWorkgroups(x, y = 1, z = 1) {
      this._assertOpen('GPUComputePassEncoder.dispatchWorkgroups');
      assertIntegerInRange(x, 'GPUComputePassEncoder.dispatchWorkgroups', 'x', UINT32_RANGE);
      assertIntegerInRange(y, 'GPUComputePassEncoder.dispatchWorkgroups', 'y', UINT32_RANGE);
      assertIntegerInRange(z, 'GPUComputePassEncoder.dispatchWorkgroups', 'z', UINT32_RANGE);
      backend.computePassDispatchWorkgroups(this, x, y, z);
    }

    _dispatchBound(pipeline, bindGroup, x, y = 1, z = 1) {
      this._assertOpen('GPUComputePassEncoder._dispatchBound');
      assertIntegerInRange(x, 'GPUComputePassEncoder._dispatchBound', 'x', UINT32_RANGE);
      assertIntegerInRange(y, 'GPUComputePassEncoder._dispatchBound', 'y', UINT32_RANGE);
      assertIntegerInRange(z, 'GPUComputePassEncoder._dispatchBound', 'z', UINT32_RANGE);
      backend.computePassDispatchBound(
        this,
        assertLiveResource(pipeline, 'GPUComputePassEncoder._dispatchBound', 'GPUComputePipeline'),
        bindGroup == null
          ? null
          : assertLiveResource(bindGroup, 'GPUComputePassEncoder._dispatchBound', 'GPUBindGroup'),
        x,
        y,
        z,
      );
    }

    dispatchWorkgroupsIndirect(indirectBuffer, indirectOffset = 0) {
      this._assertOpen('GPUComputePassEncoder.dispatchWorkgroupsIndirect');
      assertIntegerInRange(indirectOffset, 'GPUComputePassEncoder.dispatchWorkgroupsIndirect', 'indirectOffset', NON_NEGATIVE_RANGE);
      backend.computePassDispatchWorkgroupsIndirect(
        this,
        assertLiveResource(indirectBuffer, 'GPUComputePassEncoder.dispatchWorkgroupsIndirect', 'GPUBuffer'),
        indirectOffset,
      );
    }

    pushDebugGroup(groupLabel) {
      this._assertOpen('GPUComputePassEncoder.pushDebugGroup');
      backend.computePassPushDebugGroup(this, groupLabel);
    }
    popDebugGroup() {
      this._assertOpen('GPUComputePassEncoder.popDebugGroup');
      backend.computePassPopDebugGroup(this);
    }
    insertDebugMarker(markerLabel) {
      this._assertOpen('GPUComputePassEncoder.insertDebugMarker');
      backend.computePassInsertDebugMarker(
        this,
        assertDOMString(markerLabel, 'GPUComputePassEncoder.insertDebugMarker', 'markerLabel'),
      );
    }

    end() {
      this._assertOpen('GPUComputePassEncoder.end');
      backend.computePassEnd(this);
    }
  }

  class DoeGPURenderPassEncoder {
    constructor(state, encoder) {
      this._encoder = encoder;
      this.label = '';
      initResource(this, 'GPURenderPassEncoder', encoder);
      backend.renderPassInit(this, state);
    }

    _assertOpen(path) {
      if (typeof backend.renderPassAssertOpen === 'function') {
        backend.renderPassAssertOpen(this, path);
      }
    }

    setPipeline(pipeline) {
      this._assertOpen('GPURenderPassEncoder.setPipeline');
      backend.renderPassSetPipeline(
        this,
        assertLiveResource(pipeline, 'GPURenderPassEncoder.setPipeline', 'GPURenderPipeline'),
      );
    }

    setBindGroup(index, bindGroup) {
      this._assertOpen('GPURenderPassEncoder.setBindGroup');
      assertIntegerInRange(index, 'GPURenderPassEncoder.setBindGroup', 'index', UINT32_RANGE);
      backend.renderPassSetBindGroup(
        this,
        index,
        assertLiveResource(bindGroup, 'GPURenderPassEncoder.setBindGroup', 'GPUBindGroup'),
      );
    }

    setImmediates(index, data, dataOffset = 0, size) {
      this._assertOpen('GPURenderPassEncoder.setImmediates');
      assertIntegerInRange(index, 'GPURenderPassEncoder.setImmediates', 'index', UINT32_RANGE);
      backend.renderPassSetImmediates(
        this,
        index,
        normalizeImmediateDataInput(data, dataOffset, size, 'GPURenderPassEncoder.setImmediates'),
      );
    }

    setVertexBuffer(slot, buffer, offset = 0, size) {
      this._assertOpen('GPURenderPassEncoder.setVertexBuffer');
      assertIntegerInRange(slot, 'GPURenderPassEncoder.setVertexBuffer', 'slot', UINT32_RANGE);
      assertIntegerInRange(offset, 'GPURenderPassEncoder.setVertexBuffer', 'offset', NON_NEGATIVE_RANGE);
      if (size !== undefined) {
        assertIntegerInRange(size, 'GPURenderPassEncoder.setVertexBuffer', 'size', NON_NEGATIVE_RANGE);
      }
      backend.renderPassSetVertexBuffer(
        this,
        slot,
        assertLiveResource(buffer, 'GPURenderPassEncoder.setVertexBuffer', 'GPUBuffer'),
        offset,
        size,
      );
    }

    setIndexBuffer(buffer, format, offset = 0, size) {
      this._assertOpen('GPURenderPassEncoder.setIndexBuffer');
      assertIntegerInRange(offset, 'GPURenderPassEncoder.setIndexBuffer', 'offset', NON_NEGATIVE_RANGE);
      if (size !== undefined) {
        assertIntegerInRange(size, 'GPURenderPassEncoder.setIndexBuffer', 'size', NON_NEGATIVE_RANGE);
      }
      backend.renderPassSetIndexBuffer(
        this,
        assertLiveResource(buffer, 'GPURenderPassEncoder.setIndexBuffer', 'GPUBuffer'),
        format,
        offset,
        size,
      );
    }

    draw(vertexCount, instanceCount = 1, firstVertex = 0, firstInstance = 0) {
      this._assertOpen('GPURenderPassEncoder.draw');
      assertIntegerInRange(vertexCount, 'GPURenderPassEncoder.draw', 'vertexCount', UINT32_RANGE);
      assertIntegerInRange(instanceCount, 'GPURenderPassEncoder.draw', 'instanceCount', UINT32_RANGE);
      assertIntegerInRange(firstVertex, 'GPURenderPassEncoder.draw', 'firstVertex', UINT32_RANGE);
      assertIntegerInRange(firstInstance, 'GPURenderPassEncoder.draw', 'firstInstance', UINT32_RANGE);
      backend.renderPassDraw(this, vertexCount, instanceCount, firstVertex, firstInstance);
    }

    drawIndexed(indexCount, instanceCount = 1, firstIndex = 0, baseVertex = 0, firstInstance = 0) {
      this._assertOpen('GPURenderPassEncoder.drawIndexed');
      assertIntegerInRange(indexCount, 'GPURenderPassEncoder.drawIndexed', 'indexCount', UINT32_RANGE);
      assertIntegerInRange(instanceCount, 'GPURenderPassEncoder.drawIndexed', 'instanceCount', UINT32_RANGE);
      assertIntegerInRange(firstIndex, 'GPURenderPassEncoder.drawIndexed', 'firstIndex', UINT32_RANGE);
      assertIntegerInRange(firstInstance, 'GPURenderPassEncoder.drawIndexed', 'firstInstance', UINT32_RANGE);
      backend.renderPassDrawIndexed(this, indexCount, instanceCount, firstIndex, baseVertex, firstInstance);
    }

    drawIndirect(indirectBuffer, indirectOffset = 0) {
      this._assertOpen('GPURenderPassEncoder.drawIndirect');
      assertIntegerInRange(indirectOffset, 'GPURenderPassEncoder.drawIndirect', 'indirectOffset', NON_NEGATIVE_RANGE);
      backend.renderPassDrawIndirect(
        this,
        assertLiveResource(indirectBuffer, 'GPURenderPassEncoder.drawIndirect', 'GPUBuffer'),
        indirectOffset,
      );
    }

    drawIndexedIndirect(indirectBuffer, indirectOffset = 0) {
      this._assertOpen('GPURenderPassEncoder.drawIndexedIndirect');
      assertIntegerInRange(indirectOffset, 'GPURenderPassEncoder.drawIndexedIndirect', 'indirectOffset', NON_NEGATIVE_RANGE);
      backend.renderPassDrawIndexedIndirect(
        this,
        assertLiveResource(indirectBuffer, 'GPURenderPassEncoder.drawIndexedIndirect', 'GPUBuffer'),
        indirectOffset,
      );
    }

    setViewport(x, y, width, height, minDepth, maxDepth) {
      this._assertOpen('GPURenderPassEncoder.setViewport');
      backend.renderPassSetViewport(this, x, y, width, height, minDepth, maxDepth);
    }

    setScissorRect(x, y, width, height) {
      this._assertOpen('GPURenderPassEncoder.setScissorRect');
      assertIntegerInRange(x, 'GPURenderPassEncoder.setScissorRect', 'x', UINT32_RANGE);
      assertIntegerInRange(y, 'GPURenderPassEncoder.setScissorRect', 'y', UINT32_RANGE);
      assertIntegerInRange(width, 'GPURenderPassEncoder.setScissorRect', 'width', UINT32_RANGE);
      assertIntegerInRange(height, 'GPURenderPassEncoder.setScissorRect', 'height', UINT32_RANGE);
      backend.renderPassSetScissorRect(this, x, y, width, height);
    }

    setBlendConstant(color) {
      this._assertOpen('GPURenderPassEncoder.setBlendConstant');
      backend.renderPassSetBlendConstant(
        this,
        assertObject(color, 'GPURenderPassEncoder.setBlendConstant', 'color'),
      );
    }

    setStencilReference(reference) {
      this._assertOpen('GPURenderPassEncoder.setStencilReference');
      assertIntegerInRange(reference, 'GPURenderPassEncoder.setStencilReference', 'reference', UINT32_RANGE);
      backend.renderPassSetStencilReference(this, reference);
    }

    beginOcclusionQuery(queryIndex) {
      this._assertOpen('GPURenderPassEncoder.beginOcclusionQuery');
      assertIntegerInRange(queryIndex, 'GPURenderPassEncoder.beginOcclusionQuery', 'queryIndex', UINT32_RANGE);
      backend.renderPassBeginOcclusionQuery(this, queryIndex);
    }

    endOcclusionQuery() {
      this._assertOpen('GPURenderPassEncoder.endOcclusionQuery');
      backend.renderPassEndOcclusionQuery(this);
    }

    pushDebugGroup(groupLabel) {
      backend.renderPassPushDebugGroup(this, groupLabel);
    }
    popDebugGroup() {
      backend.renderPassPopDebugGroup(this);
    }
    insertDebugMarker(markerLabel) {
      backend.renderPassInsertDebugMarker(this, markerLabel);
    }

    executeBundles(bundles) {
      this._assertOpen('GPURenderPassEncoder.executeBundles');
      backend.renderPassExecuteBundles(
        this,
        assertArray(bundles, 'GPURenderPassEncoder.executeBundles', 'bundles'),
      );
    }

    end() {
      this._assertOpen('GPURenderPassEncoder.end');
      backend.renderPassEnd(this);
    }
  }

  class DoeGPURenderBundle {
    constructor(native, owner) {
      this._native = native;
      this.label = '';
      initResource(this, 'GPURenderBundle', owner);
    }

    destroy() {
      if (typeof backend.renderBundleDestroy !== 'function') {
        return;
      }
      destroyResource(this, (native) => backend.renderBundleDestroy(native));
    }
  }

  class DoeGPURenderBundleEncoder {
    constructor(state, device) {
      this._device = device;
      this.label = '';
      initResource(this, 'GPURenderBundleEncoder', device);
      backend.renderBundleEncoderInit(this, state);
    }

    _assertOpen(path) {
      assertLiveResource(this._device, path, 'GPUDevice');
      if (typeof backend.renderBundleEncoderAssertOpen === 'function') {
        backend.renderBundleEncoderAssertOpen(this, path);
      }
    }

    setPipeline(pipeline) {
      this._assertOpen('GPURenderBundleEncoder.setPipeline');
      backend.renderBundleEncoderSetPipeline(
        this,
        assertLiveResource(pipeline, 'GPURenderBundleEncoder.setPipeline', 'GPURenderPipeline'),
      );
    }

    setBindGroup(index, bindGroup) {
      this._assertOpen('GPURenderBundleEncoder.setBindGroup');
      assertIntegerInRange(index, 'GPURenderBundleEncoder.setBindGroup', 'index', UINT32_RANGE);
      backend.renderBundleEncoderSetBindGroup(
        this,
        index,
        assertLiveResource(bindGroup, 'GPURenderBundleEncoder.setBindGroup', 'GPUBindGroup'),
      );
    }

    setImmediates(index, data, dataOffset = 0, size) {
      this._assertOpen('GPURenderBundleEncoder.setImmediates');
      assertIntegerInRange(index, 'GPURenderBundleEncoder.setImmediates', 'index', UINT32_RANGE);
      backend.renderBundleEncoderSetImmediates(
        this,
        index,
        normalizeImmediateDataInput(data, dataOffset, size, 'GPURenderBundleEncoder.setImmediates'),
      );
    }

    setVertexBuffer(slot, buffer, offset = 0, size) {
      this._assertOpen('GPURenderBundleEncoder.setVertexBuffer');
      assertIntegerInRange(slot, 'GPURenderBundleEncoder.setVertexBuffer', 'slot', UINT32_RANGE);
      assertIntegerInRange(offset, 'GPURenderBundleEncoder.setVertexBuffer', 'offset', NON_NEGATIVE_RANGE);
      if (size !== undefined) {
        assertIntegerInRange(size, 'GPURenderBundleEncoder.setVertexBuffer', 'size', NON_NEGATIVE_RANGE);
      }
      backend.renderBundleEncoderSetVertexBuffer(
        this,
        slot,
        assertLiveResource(buffer, 'GPURenderBundleEncoder.setVertexBuffer', 'GPUBuffer'),
        offset,
        size,
      );
    }

    setIndexBuffer(buffer, format, offset = 0, size) {
      this._assertOpen('GPURenderBundleEncoder.setIndexBuffer');
      assertIntegerInRange(offset, 'GPURenderBundleEncoder.setIndexBuffer', 'offset', NON_NEGATIVE_RANGE);
      if (size !== undefined) {
        assertIntegerInRange(size, 'GPURenderBundleEncoder.setIndexBuffer', 'size', NON_NEGATIVE_RANGE);
      }
      backend.renderBundleEncoderSetIndexBuffer(
        this,
        assertLiveResource(buffer, 'GPURenderBundleEncoder.setIndexBuffer', 'GPUBuffer'),
        format,
        offset,
        size,
      );
    }

    draw(vertexCount, instanceCount = 1, firstVertex = 0, firstInstance = 0) {
      this._assertOpen('GPURenderBundleEncoder.draw');
      assertIntegerInRange(vertexCount, 'GPURenderBundleEncoder.draw', 'vertexCount', UINT32_RANGE);
      assertIntegerInRange(instanceCount, 'GPURenderBundleEncoder.draw', 'instanceCount', UINT32_RANGE);
      assertIntegerInRange(firstVertex, 'GPURenderBundleEncoder.draw', 'firstVertex', UINT32_RANGE);
      assertIntegerInRange(firstInstance, 'GPURenderBundleEncoder.draw', 'firstInstance', UINT32_RANGE);
      backend.renderBundleEncoderDraw(this, vertexCount, instanceCount, firstVertex, firstInstance);
    }

    drawIndexed(indexCount, instanceCount = 1, firstIndex = 0, baseVertex = 0, firstInstance = 0) {
      this._assertOpen('GPURenderBundleEncoder.drawIndexed');
      assertIntegerInRange(indexCount, 'GPURenderBundleEncoder.drawIndexed', 'indexCount', UINT32_RANGE);
      assertIntegerInRange(instanceCount, 'GPURenderBundleEncoder.drawIndexed', 'instanceCount', UINT32_RANGE);
      assertIntegerInRange(firstIndex, 'GPURenderBundleEncoder.drawIndexed', 'firstIndex', UINT32_RANGE);
      assertIntegerInRange(firstInstance, 'GPURenderBundleEncoder.drawIndexed', 'firstInstance', UINT32_RANGE);
      backend.renderBundleEncoderDrawIndexed(this, indexCount, instanceCount, firstIndex, baseVertex, firstInstance);
    }

    drawIndirect(indirectBuffer, indirectOffset = 0) {
      this._assertOpen('GPURenderBundleEncoder.drawIndirect');
      assertIntegerInRange(indirectOffset, 'GPURenderBundleEncoder.drawIndirect', 'indirectOffset', NON_NEGATIVE_RANGE);
      backend.renderBundleEncoderDrawIndirect(
        this,
        assertLiveResource(indirectBuffer, 'GPURenderBundleEncoder.drawIndirect', 'GPUBuffer'),
        indirectOffset,
      );
    }

    drawIndexedIndirect(indirectBuffer, indirectOffset = 0) {
      this._assertOpen('GPURenderBundleEncoder.drawIndexedIndirect');
      assertIntegerInRange(indirectOffset, 'GPURenderBundleEncoder.drawIndexedIndirect', 'indirectOffset', NON_NEGATIVE_RANGE);
      backend.renderBundleEncoderDrawIndexedIndirect(
        this,
        assertLiveResource(indirectBuffer, 'GPURenderBundleEncoder.drawIndexedIndirect', 'GPUBuffer'),
        indirectOffset,
      );
    }

    pushDebugGroup(groupLabel) {
      backend.renderBundleEncoderPushDebugGroup(this, groupLabel);
    }
    popDebugGroup() {
      backend.renderBundleEncoderPopDebugGroup(this);
    }
    insertDebugMarker(markerLabel) {
      backend.renderBundleEncoderInsertDebugMarker(this, markerLabel);
    }

    finish(descriptor) {
      this._assertOpen('GPURenderBundleEncoder.finish');
      const bundle = backend.renderBundleEncoderFinish(
        this,
        descriptor === undefined ? undefined : assertObject(descriptor, 'GPURenderBundleEncoder.finish', 'descriptor'),
        classes,
      );
      bundle.label = descriptor?.label ?? '';
      this._finished = true;
      return bundle;
    }
  }

  class DoeGPUCommandBuffer {
    constructor(state, owner) {
      this._batched = state?._batched === true;
      this._commands = this._batched ? (state?._commands ?? []) : [];
      this._native = this._batched ? null : (state?._native ?? null);
      this._submitted = false;
      this._finalizerToken = null;
      this.label = '';
      initResource(this, 'GPUCommandBuffer', owner);
      if (this._native != null && commandBufferFinalizer) {
        this._finalizerToken = {};
        commandBufferFinalizer.register(this, this._native, this._finalizerToken);
      }
    }

    destroy() {
      releaseCommandBuffer(this);
    }
  }

  class DoeGPUCommandEncoder {
    constructor(state, device) {
      this._device = device;
      this.label = '';
      initResource(this, 'GPUCommandEncoder', device);
      backend.commandEncoderInit(this, state);
    }

    _assertOpen(path) {
      assertLiveResource(this._device, path, 'GPUDevice');
      if (typeof backend.commandEncoderAssertOpen === 'function') {
        backend.commandEncoderAssertOpen(this, path);
      }
    }

    beginComputePass(descriptor) {
      this._assertOpen('GPUCommandEncoder.beginComputePass');
      const pass = backend.commandEncoderBeginComputePass(this, descriptor, classes);
      pass.label = descriptor?.label ?? '';
      return pass;
    }

    beginRenderPass(descriptor) {
      this._assertOpen('GPUCommandEncoder.beginRenderPass');
      const passDescriptor = assertObject(descriptor, 'GPUCommandEncoder.beginRenderPass', 'descriptor');
      const pass = backend.commandEncoderBeginRenderPass(this, passDescriptor, classes);
      pass.label = passDescriptor.label ?? '';
      return pass;
    }

    copyBufferToBuffer(src, srcOffset, dst, dstOffset, size) {
      this._assertOpen('GPUCommandEncoder.copyBufferToBuffer');
      assertIntegerInRange(srcOffset, 'GPUCommandEncoder.copyBufferToBuffer', 'srcOffset', NON_NEGATIVE_RANGE);
      assertIntegerInRange(dstOffset, 'GPUCommandEncoder.copyBufferToBuffer', 'dstOffset', NON_NEGATIVE_RANGE);
      assertIntegerInRange(size, 'GPUCommandEncoder.copyBufferToBuffer', 'size', POSITIVE_RANGE);
      backend.commandEncoderCopyBufferToBuffer(
        this,
        assertLiveResource(src, 'GPUCommandEncoder.copyBufferToBuffer', 'GPUBuffer'),
        srcOffset,
        assertLiveResource(dst, 'GPUCommandEncoder.copyBufferToBuffer', 'GPUBuffer'),
        dstOffset,
        size,
      );
    }

    copyBufferToTexture(source, destination, copySize) {
      this._assertOpen('GPUCommandEncoder.copyBufferToTexture');
      const sourceObject = assertObject(source, 'GPUCommandEncoder.copyBufferToTexture', 'source');
      const destinationObject = assertObject(destination, 'GPUCommandEncoder.copyBufferToTexture', 'destination');
      const sizeObject = assertObject(copySize, 'GPUCommandEncoder.copyBufferToTexture', 'copySize');
      assertIntegerInRange(sourceObject.offset ?? 0, 'GPUCommandEncoder.copyBufferToTexture', 'source.offset', NON_NEGATIVE_RANGE);
      assertIntegerInRange(sourceObject.bytesPerRow ?? 0, 'GPUCommandEncoder.copyBufferToTexture', 'source.bytesPerRow', NON_NEGATIVE_RANGE);
      assertIntegerInRange(sourceObject.rowsPerImage ?? 0, 'GPUCommandEncoder.copyBufferToTexture', 'source.rowsPerImage', NON_NEGATIVE_RANGE);
      assertIntegerInRange(sizeObject.width, 'GPUCommandEncoder.copyBufferToTexture', 'copySize.width', POSITIVE_UINT32_RANGE);
      assertIntegerInRange(sizeObject.height, 'GPUCommandEncoder.copyBufferToTexture', 'copySize.height', POSITIVE_UINT32_RANGE);
      if (sizeObject.depthOrArrayLayers !== undefined) {
        assertIntegerInRange(sizeObject.depthOrArrayLayers, 'GPUCommandEncoder.copyBufferToTexture', 'copySize.depthOrArrayLayers', POSITIVE_UINT32_RANGE);
      }
      backend.commandEncoderCopyBufferToTexture(
        this,
        {
          buffer: assertLiveResource(sourceObject.buffer, 'GPUCommandEncoder.copyBufferToTexture', 'GPUBuffer'),
          offset: sourceObject.offset ?? 0,
          bytesPerRow: sourceObject.bytesPerRow ?? 0,
          rowsPerImage: sourceObject.rowsPerImage ?? 0,
        },
        {
          texture: assertLiveResource(destinationObject.texture, 'GPUCommandEncoder.copyBufferToTexture', 'GPUTexture'),
          mipLevel: destinationObject.mipLevel ?? 0,
          origin: {
            x: destinationObject.origin?.x ?? 0,
            y: destinationObject.origin?.y ?? 0,
            z: destinationObject.origin?.z ?? 0,
          },
          aspect: destinationObject.aspect,
        },
        {
          width: sizeObject.width,
          height: sizeObject.height,
          depthOrArrayLayers: sizeObject.depthOrArrayLayers ?? 1,
        },
      );
    }

    copyTextureToBuffer(source, destination, copySize) {
      this._assertOpen('GPUCommandEncoder.copyTextureToBuffer');
      const sourceObject = assertObject(source, 'GPUCommandEncoder.copyTextureToBuffer', 'source');
      const destinationObject = assertObject(destination, 'GPUCommandEncoder.copyTextureToBuffer', 'destination');
      const sizeObject = assertObject(copySize, 'GPUCommandEncoder.copyTextureToBuffer', 'copySize');
      if (sourceObject.origin !== undefined) {
        assertObject(sourceObject.origin, 'GPUCommandEncoder.copyTextureToBuffer', 'source.origin');
      }
      assertIntegerInRange(destinationObject.offset ?? 0, 'GPUCommandEncoder.copyTextureToBuffer', 'destination.offset', NON_NEGATIVE_RANGE);
      assertIntegerInRange(destinationObject.bytesPerRow ?? 0, 'GPUCommandEncoder.copyTextureToBuffer', 'destination.bytesPerRow', NON_NEGATIVE_RANGE);
      assertIntegerInRange(destinationObject.rowsPerImage ?? 0, 'GPUCommandEncoder.copyTextureToBuffer', 'destination.rowsPerImage', NON_NEGATIVE_RANGE);
      assertIntegerInRange(sizeObject.width, 'GPUCommandEncoder.copyTextureToBuffer', 'copySize.width', POSITIVE_UINT32_RANGE);
      assertIntegerInRange(sizeObject.height, 'GPUCommandEncoder.copyTextureToBuffer', 'copySize.height', POSITIVE_UINT32_RANGE);
      if (sizeObject.depthOrArrayLayers !== undefined) {
        assertIntegerInRange(sizeObject.depthOrArrayLayers, 'GPUCommandEncoder.copyTextureToBuffer', 'copySize.depthOrArrayLayers', POSITIVE_UINT32_RANGE);
      }
      backend.commandEncoderCopyTextureToBuffer(
        this,
        {
          texture: assertLiveResource(sourceObject.texture, 'GPUCommandEncoder.copyTextureToBuffer', 'GPUTexture'),
          mipLevel: sourceObject.mipLevel ?? 0,
          origin: {
            x: sourceObject.origin?.x ?? 0,
            y: sourceObject.origin?.y ?? 0,
            z: sourceObject.origin?.z ?? 0,
          },
          aspect: sourceObject.aspect,
        },
        {
          buffer: assertLiveResource(destinationObject.buffer, 'GPUCommandEncoder.copyTextureToBuffer', 'GPUBuffer'),
          offset: destinationObject.offset ?? 0,
          bytesPerRow: destinationObject.bytesPerRow ?? 0,
          rowsPerImage: destinationObject.rowsPerImage ?? 0,
        },
        {
          width: sizeObject.width,
          height: sizeObject.height,
          depthOrArrayLayers: sizeObject.depthOrArrayLayers ?? 1,
        },
      );
    }

    copyTextureToTexture(source, destination, copySize) {
      this._assertOpen('GPUCommandEncoder.copyTextureToTexture');
      const sourceObject = assertObject(source, 'GPUCommandEncoder.copyTextureToTexture', 'source');
      const destinationObject = assertObject(destination, 'GPUCommandEncoder.copyTextureToTexture', 'destination');
      const sizeObject = assertObject(copySize, 'GPUCommandEncoder.copyTextureToTexture', 'copySize');
      backend.commandEncoderCopyTextureToTexture(
        this,
        {
          texture: assertLiveResource(sourceObject.texture, 'GPUCommandEncoder.copyTextureToTexture', 'GPUTexture'),
          mipLevel: sourceObject.mipLevel ?? 0,
          origin: {
            x: sourceObject.origin?.x ?? 0,
            y: sourceObject.origin?.y ?? 0,
            z: sourceObject.origin?.z ?? 0,
          },
          aspect: sourceObject.aspect,
        },
        {
          texture: assertLiveResource(destinationObject.texture, 'GPUCommandEncoder.copyTextureToTexture', 'GPUTexture'),
          mipLevel: destinationObject.mipLevel ?? 0,
          origin: {
            x: destinationObject.origin?.x ?? 0,
            y: destinationObject.origin?.y ?? 0,
            z: destinationObject.origin?.z ?? 0,
          },
          aspect: destinationObject.aspect,
        },
        {
          width: sizeObject.width,
          height: sizeObject.height,
          depthOrArrayLayers: sizeObject.depthOrArrayLayers ?? 1,
        },
      );
    }

    clearBuffer(buffer, offset = 0, size) {
      this._assertOpen('GPUCommandEncoder.clearBuffer');
      assertIntegerInRange(offset, 'GPUCommandEncoder.clearBuffer', 'offset', NON_NEGATIVE_RANGE);
      if (size !== undefined) {
        assertIntegerInRange(size, 'GPUCommandEncoder.clearBuffer', 'size', NON_NEGATIVE_RANGE);
      }
      backend.commandEncoderClearBuffer(
        this,
        assertLiveResource(buffer, 'GPUCommandEncoder.clearBuffer', 'GPUBuffer'),
        offset,
        size,
      );
    }

    writeTimestamp(querySet, queryIndex) {
      this._assertOpen('GPUCommandEncoder.writeTimestamp');
      const querySetNative = assertLiveResource(querySet, 'GPUCommandEncoder.writeTimestamp', 'GPUQuerySet');
      assertIntegerInRange(queryIndex, 'GPUCommandEncoder.writeTimestamp', 'queryIndex', UINT32_RANGE);
      if (queryIndex >= querySet.count) {
        failValidation('GPUCommandEncoder.writeTimestamp', `queryIndex ${queryIndex} exceeds querySet count ${querySet.count}`);
      }
      backend.commandEncoderWriteTimestamp(this, querySetNative, queryIndex);
    }

    resolveQuerySet(querySet, firstQuery, queryCount, destination, destinationOffset) {
      this._assertOpen('GPUCommandEncoder.resolveQuerySet');
      const querySetNative = assertLiveResource(querySet, 'GPUCommandEncoder.resolveQuerySet', 'GPUQuerySet');
      assertIntegerInRange(firstQuery, 'GPUCommandEncoder.resolveQuerySet', 'firstQuery', UINT32_RANGE);
      assertIntegerInRange(queryCount, 'GPUCommandEncoder.resolveQuerySet', 'queryCount', POSITIVE_UINT32_RANGE);
      if (firstQuery + queryCount > querySet.count) {
        failValidation('GPUCommandEncoder.resolveQuerySet', `firstQuery ${firstQuery} + queryCount ${queryCount} exceeds querySet count ${querySet.count}`);
      }
      const destinationNative = assertLiveResource(destination, 'GPUCommandEncoder.resolveQuerySet', 'GPUBuffer');
      assertIntegerInRange(destinationOffset, 'GPUCommandEncoder.resolveQuerySet', 'destinationOffset', NON_NEGATIVE_RANGE);
      backend.commandEncoderResolveQuerySet(this, querySetNative, firstQuery, queryCount, destinationNative, destinationOffset);
    }

    pushDebugGroup(groupLabel) {
      backend.commandEncoderPushDebugGroup(this, groupLabel);
    }
    popDebugGroup() {
      backend.commandEncoderPopDebugGroup(this);
    }
    insertDebugMarker(markerLabel) {
      backend.commandEncoderInsertDebugMarker(this, markerLabel);
    }

    finish(descriptor) {
      this._assertOpen('GPUCommandEncoder.finish');
      const cmdBuf = new classes.DoeGPUCommandBuffer(
        backend.commandEncoderFinish(this),
        this._device,
      );
      cmdBuf.label = descriptor?.label ?? '';
      return cmdBuf;
    }
  }

  classes = {
    DoeGPUComputePassEncoder,
    DoeGPURenderPassEncoder,
    DoeGPURenderBundle,
    DoeGPURenderBundleEncoder,
    DoeGPUCommandBuffer,
    DoeGPUCommandEncoder,
  };
  return classes;
}

export {
  createEncoderClasses,
};

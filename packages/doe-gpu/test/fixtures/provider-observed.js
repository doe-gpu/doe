export const globals = Object.freeze({
  GPUBufferUsage: Object.freeze({ STORAGE: 1, COPY_SRC: 2, MAP_READ: 4 }),
  GPUShaderStage: Object.freeze({ COMPUTE: 1 }),
  GPUMapMode: Object.freeze({ READ: 1 }),
  GPUTextureUsage: Object.freeze({ STORAGE_BINDING: 1 }),
});

function createBuffer(descriptor) {
  const bytes = new Uint8Array(Number(descriptor.size ?? 0));
  return {
    kind: 'buffer',
    size: bytes.byteLength,
    bytes,
    async mapAsync() {},
    getMappedRange(offset = 0, size = bytes.byteLength - offset) {
      return bytes.slice(offset, offset + size).buffer;
    },
    unmap() {},
    destroy() {},
  };
}

function createDevice() {
  const queue = {
    writeBuffer(buffer, offset, data) {
      const source = ArrayBuffer.isView(data)
        ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
        : new Uint8Array(data);
      buffer.bytes.set(source, offset);
    },
    submit() {},
    async onSubmittedWorkDone() {},
  };
  return {
    queue,
    createShaderModule({ code }) {
      if (!code.includes('@compute')) throw new Error('fixture requires a compute shader');
      return {
        kind: 'shaderModule',
        async getCompilationInfo() {
          return {
            messages: [{
              type: 'warning',
              message: 'observed fixture warning',
              lineNum: 1,
              linePos: 1,
              offset: 0,
              length: 1,
            }],
          };
        },
      };
    },
    createComputePipeline({ compute }) {
      if (compute.module.kind !== 'shaderModule') throw new Error('raw module not received');
      return { kind: 'computePipeline' };
    },
    createBuffer,
    createCommandEncoder() {
      return {
        beginComputePass() {
          return {
            setPipeline(pipeline) {
              if (pipeline.kind !== 'computePipeline') throw new Error('raw pipeline not received');
            },
            dispatchWorkgroups() {},
            end() {},
          };
        },
        finish() { return { kind: 'commandBuffer' }; },
      };
    },
    destroy() {},
  };
}

export function createObservedGPU() {
  return {
    async requestAdapter() {
      return {
        info: {
          vendor: 'Observed Fixture Vendor',
          architecture: 'fixture',
          device: 'Observed Fixture Device',
          description: 'Transparent observer fixture',
          vendorID: 11,
          deviceID: 12,
          driverVersion: 13,
        },
        async requestDevice() { return createDevice(); },
      };
    },
  };
}

export const create = createObservedGPU;

export function providerInfo() {
  return { provider: 'observed-fixture-provider' };
}

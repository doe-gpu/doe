let lastFactoryArgs = null;
let lastAdapterOptions = null;
let compiledEntries = [];
let destroyedDevice = false;

export const globals = Object.freeze({
  GPUBufferUsage: Object.freeze({ STORAGE: 1 }),
  GPUShaderStage: Object.freeze({ COMPUTE: 2 }),
  GPUMapMode: Object.freeze({ READ: 4 }),
  GPUTextureUsage: Object.freeze({ STORAGE_BINDING: 8 }),
});

export function failFactory() {
  throw new Error('declared test provider failure');
}

export function createFakeGPU(...args) {
  lastFactoryArgs = args;
  return {
    async requestAdapter(options) {
      lastAdapterOptions = options ?? null;
      return Object.freeze({
        label: 'provider-v1-test-adapter',
        getInfo() {
          return {
            vendor: 'Fixture Vendor',
            architecture: 'fixture',
            device: 'Fixture Device',
            description: 'Provider v1 test adapter',
            vendorID: 1,
            deviceID: 2,
            driverVersion: 3,
          };
        },
        async requestDevice() {
          return {
            createShaderModule({ code }) {
              if (typeof code !== 'string' || !code.includes('@compute')) {
                throw new Error('test shader source was not packaged WGSL');
              }
              return {
                async getCompilationInfo() {
                  return { messages: [] };
                },
              };
            },
            createComputePipeline({ compute }) {
              compiledEntries.push(compute.entryPoint);
              return Object.freeze({ label: `test-pipeline:${compute.entryPoint}` });
            },
            destroy() {
              destroyedDevice = true;
            },
          };
        },
      });
    },
  };
}

export const create = createFakeGPU;

export function getProviderObservations() {
  return {
    lastFactoryArgs,
    lastAdapterOptions,
    compiledEntries: [...compiledEntries],
    destroyedDevice,
  };
}

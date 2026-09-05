export interface ComputeProgramDescriptor {
  schemaVersion: 1;
  id: string;
  buffers: Array<{
    id: string;
    size: number;
    role: 'input' | 'scratch' | 'output';
    type: 'storage' | 'uniform';
  }>;
  shaders: Array<{ id: string; code: string; entryPoint: string }>;
  steps: Array<{
    shader: string;
    bindings: Array<{ binding: number; buffer: string }>;
    workgroups: [number, number, number];
  }>;
  output: string;
}

export type ComputeProgramExecution = 'gpu-recorded' | 'native-recorded' | 'webgpu';

export interface ComputeProgramReceipt {
  schemaVersion: 3;
  programHash: string;
  execution: ComputeProgramExecution;
  run: number;
  inputHashes: Record<string, string>;
  outputHash: string;
  dispatchCount: number;
  clearedBytes: number;
  uploadedBytes: number;
  readbackBytes: number;
  readbackPath: 'mapAsync-copy-unmap';
  allocatedBufferBytes: number;
  gpuTiming: null | {
    source: 'vulkan-query-ticks' | 'webgpu-nanoseconds' | 'wgpu-vulkan-query-ticks';
    scope: 'compute-pass';
    beginTicks: string; endTicks: string;
    periodNs: number; validBits: number; elapsedNs: number;
  };
  timingMs: {
    upload: number; encode: number; submitWait: number; readback: number; total: number;
  };
}

export interface ComputeProgram {
  readonly descriptor: Readonly<ComputeProgramDescriptor>;
  readonly programHash: string;
  readonly preparationMs: number;
  readonly allocatedBufferBytes: number;
  readonly preparation: Readonly<{ reusedResources: number; createdResources: number }>;
  readonly state: 'preparing' | 'ready' | 'updating' | 'invalid' | 'closed';
  run(inputs: Record<string, ArrayBuffer | ArrayBufferView>, options?: { signal?: AbortSignal }):
    Promise<{ output: Uint8Array; receipt: ComputeProgramReceipt }>;
  close(): Promise<void>;
  /** Atomically replace this program; unchanged resources are retained. */
  update(descriptor: ComputeProgramDescriptor): Promise<ComputeProgram>;
}

/** Device must support standard WebGPU compute, mapping, and error scopes. */
export function prepareComputeProgram(
  device: any,
  descriptor: ComputeProgramDescriptor,
  options: { execution: ComputeProgramExecution; gpuTiming?: 'off' | 'timestamp-query' },
): Promise<ComputeProgram>;
export function validateComputeProgram(descriptor: unknown): {
  descriptor: Readonly<ComputeProgramDescriptor>; programHash: string;
};

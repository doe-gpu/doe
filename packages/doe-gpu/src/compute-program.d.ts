export interface ComputeProgramDescriptor {
  schemaVersion: 1 | 2;
  id: string;
  buffers: Array<{
    id: string;
    size: number;
    role: 'input' | 'scratch' | 'output';
    type: 'storage' | 'uniform';
    /** Requires descriptor version 2; omitted means invocation. */
    lifetime?: 'invocation' | 'program';
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

export type ComputeProgramOrigin = { kind: 'host'; hash: string } | { kind: 'zero' } | {
  kind: 'program-output' | 'program-state'; programHash: string; programInstance: string;
  buffer: string; generation: number;
};

/** Opaque output reference, valid until its producer runs, updates, closes, or loses its device. */
export interface ComputeProgramOutput {
  readonly programHash: string;
  readonly programInstance: string;
  readonly buffer: string;
  readonly generation: number;
  readonly size: number;
}

export interface ComputeProgramReceipt {
  schemaVersion: 4;
  programInstance: string;
  programHash: string;
  execution: ComputeProgramExecution;
  run: number;
  inputHashes: Record<string, string | null>;
  inputOrigins: Record<string, ComputeProgramOrigin>;
  residentStateBefore: Record<string, ComputeProgramOrigin>;
  outputHash: string | null;
  outputGeneration: number;
  copiedInputBytes: number;
  submissionCount: number;
  dispatchCount: number;
  clearedBytes: number;
  uploadedBytes: number;
  readbackBytes: number;
  readbackPath: 'mapAsync-copy-unmap' | 'none';
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
  output(): ComputeProgramOutput;
  run(inputs?: Record<string, ArrayBuffer | ArrayBufferView | ComputeProgramOutput>, options?: { signal?: AbortSignal }):
    Promise<{ output: Uint8Array | null; receipt: ComputeProgramReceipt }>;
  close(): Promise<void>;
  /** Atomically replace this program; unchanged resources are retained. */
  update(descriptor: ComputeProgramDescriptor): Promise<ComputeProgram>;
}

/** Device must support standard WebGPU compute, mapping, and error scopes. */
export function prepareComputeProgram(
  device: any,
  descriptor: ComputeProgramDescriptor,
  options: { execution: ComputeProgramExecution; gpuTiming?: 'off' | 'timestamp-query'; readback?: 'output' | 'none' },
): Promise<ComputeProgram>;
export function validateComputeProgram(descriptor: unknown): {
  descriptor: Readonly<ComputeProgramDescriptor>; programHash: string;
};

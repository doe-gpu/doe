export interface ComputeProgramDescriptor {
  schemaVersion: 1 | 2 | 3;
  id: string;
  buffers: Array<{
    id: string;
    size: number;
    role: 'input' | 'scratch' | 'output';
    type: 'storage' | 'uniform';
    /** Requires descriptor version 2 or later; omitted means invocation. */
    lifetime?: 'invocation' | 'program';
    /** Required for version 3 program buffers; application-owned meaning of stored bytes. */
    stateFormat?: string;
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

type ComputeProgramBuffer = Readonly<ComputeProgramDescriptor['buffers'][number]>;

/** Instance-bound assessment. Copying or serializing it does not copy its authority. */
export interface ComputeProgramUpdateAssessment {
  readonly schemaVersion: 1;
  readonly previousProgramHash: string;
  readonly nextProgramHash: string;
  readonly revision: number;
  readonly retained: readonly ComputeProgramBuffer[];
  readonly replaced: readonly Readonly<{ before: ComputeProgramBuffer; after: ComputeProgramBuffer }>[];
  readonly discarded: readonly ComputeProgramBuffer[];
  readonly created: readonly ComputeProgramBuffer[];
  readonly requiresReset: boolean;
}

export interface ComputeProgramUpdateOptions {
  assessment?: ComputeProgramUpdateAssessment;
  reset?: 'preserve' | 'approve';
}

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
  schemaVersion: 5;
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
  completionMode: 'queue-and-map' | 'queue-only';
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
  /** Assess an edit while idle. The next run expires this assessment. */
  assessUpdate(descriptor: ComputeProgramDescriptor): ComputeProgramUpdateAssessment;
  /** Atomically replace this program. Version 3 state resets require a matching approved assessment. */
  update(descriptor: ComputeProgramDescriptor, options?: ComputeProgramUpdateOptions): Promise<ComputeProgram>;
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

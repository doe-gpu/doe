export const NODE_WEBGPU_GOVERNED_PROCESS_RECEIPT_SCHEMA:
  'doe.governed-node-webgpu-process-receipt/v1';
export const NODE_WEBGPU_GOVERNED_PROCESS_ERROR_CODES: readonly string[];

export type NodeWebGPUProcessByteSource = string | ArrayBuffer | ArrayBufferView;

export interface NodeWebGPUProcessProvider {
  id: string;
  module: string;
}

export interface NodeWebGPUProcessWorkload {
  id: string;
  version: string;
  implementationSha256: `sha256:${string}`;
  input: NodeWebGPUProcessByteSource;
  expectedOutputSha256: `sha256:${string}`;
}

export interface NodeWebGPUProcessDeclaration {
  executable?: string;
  nodeArgs?: string[];
  entrypoint: string;
  args?: string[];
  cwd?: string;
  environment: {
    mode: 'inherit' | 'sealed';
    values?: Record<string, string | null>;
  };
  timeoutMs: number;
  maxOutputBytes: number;
}

export interface NodeWebGPUProcessObservation {
  output: NodeWebGPUProcessByteSource;
  providerIdentity: Record<string, unknown>;
  evidence?: unknown;
}

export interface NodeWebGPUGovernedProcessReceipt {
  schema: 'doe.governed-node-webgpu-process-receipt/v1';
  status: 'pass' | 'failed';
  checkpoint: 'process-complete';
  workload: Record<string, unknown>;
  provider: Record<string, unknown>;
  process: {
    declaration: Record<string, unknown>;
    environment: Record<string, unknown>;
    exitCode: number | null;
    signal: string | null;
    spawned: boolean;
    aborted: boolean;
    terminationScope: 'process-group' | 'child-process';
    timedOut: boolean;
    outputLimitExceeded: boolean;
    stdoutSha256: string;
    stdoutBytes: number;
    stderrSha256: string;
    stderrBytes: number;
    durationMs: number;
  };
  oracle: Record<string, unknown>;
  applicationEvidence: unknown;
  applicationEvidenceSha256: string | null;
  replay: { workloadSha256: string; executionSha256: string };
  errors: Array<{ code: string; stage: string; detail: string }>;
}

export interface NodeWebGPUGovernedProcessOptions {
  provider: NodeWebGPUProcessProvider;
  workload: NodeWebGPUProcessWorkload;
  process: NodeWebGPUProcessDeclaration;
  evaluate(result: {
    stdout: Uint8Array;
    stderr: Uint8Array;
    exitCode: number | null;
    signal: string | null;
  }): Promise<NodeWebGPUProcessObservation> | NodeWebGPUProcessObservation;
  checkpoint?(receipt: NodeWebGPUGovernedProcessReceipt): Promise<void> | void;
  signal?: AbortSignal;
}

export interface NodeWebGPUGovernedProcessResult {
  ok: boolean;
  receipt: NodeWebGPUGovernedProcessReceipt | null;
  observation: NodeWebGPUProcessObservation | null;
  stdout: Uint8Array;
  stderr: Uint8Array;
  errors: Array<{ code: string; stage: string; detail: string }>;
}

export function runGovernedNodeWebGPUProcess(
  options: NodeWebGPUGovernedProcessOptions,
): Promise<NodeWebGPUGovernedProcessResult>;

export function validateGovernedNodeWebGPUProcessReceipt(
  receipt: unknown,
): { valid: boolean; errors: string[] };

export const NODE_WEBGPU_PROVIDER_SCHEMA: 'doe.webgpu-provider/v1';
export const NODE_WEBGPU_PROVIDER_RECEIPT_SCHEMA: 'doe.webgpu-provider-receipt/v1';
export const NODE_WEBGPU_GOVERNED_RECEIPT_SCHEMA: 'doe.governed-node-webgpu-receipt/v1';
export const NODE_WEBGPU_PROVIDER_ERROR_CODES: readonly string[];
export const NODE_WEBGPU_GOVERNED_ERROR_CODES: readonly string[];

export type NodeWebGPUGlobalMode = 'none' | 'install-missing' | 'replace';

export interface NodeWebGPUGlobalProvider {
  id: string;
  kind: 'global';
}

export interface NodeWebGPUModuleProvider {
  id: string;
  kind: 'module';
  module: string;
  gpu: {
    kind: 'export' | 'factory';
    path: string;
    args?: unknown[];
    resultPath?: string | null;
  };
  globals: {
    GPUBufferUsage: string;
    GPUShaderStage: string;
    GPUMapMode: string;
    GPUTextureUsage: string;
  };
}

export type NodeWebGPUProvider = NodeWebGPUGlobalProvider | NodeWebGPUModuleProvider;

export interface NodeWebGPUProviderOptions {
  providers: NodeWebGPUProvider[];
  adapterOptions: GPURequestAdapterOptions | null;
  globals: { mode: NodeWebGPUGlobalMode };
}

export interface NodeWebGPUProviderAttemptReceipt {
  providerId: string;
  kind: 'global' | 'module';
  module: string | null;
  ok: boolean;
  stage: string;
  code: string | null;
  detail: string | null;
}

export interface NodeWebGPUProviderReceipt {
  schema: 'doe.webgpu-provider-receipt/v1';
  contract: 'doe.webgpu-provider/v1';
  providers: NodeWebGPUProvider[];
  providerOrder: string[];
  adapterOptions: unknown;
  globals: {
    mode: NodeWebGPUGlobalMode;
    installed: string[];
    restored: boolean;
  };
  attempts: NodeWebGPUProviderAttemptReceipt[];
  selectedProviderId: string | null;
  ok: boolean;
}

export interface NodeWebGPUProviderSession {
  gpu: GPU;
  adapter: GPUAdapter;
  module: unknown;
  receipt: NodeWebGPUProviderReceipt;
  close(): Promise<void>;
}

export class NodeWebGPUProviderError extends Error {
  readonly code: string;
  readonly stage: string;
  readonly providerId: string | null;
  readonly receipt: NodeWebGPUProviderReceipt | null;
}

export interface NodeWebGPUProbeSuccess {
  ok: true;
  session: NodeWebGPUProviderSession;
  receipt: NodeWebGPUProviderReceipt;
  error: null;
}

export interface NodeWebGPUProbeFailure {
  ok: false;
  session: null;
  receipt: NodeWebGPUProviderReceipt | null;
  error: NodeWebGPUProviderError;
}

export function hasNavigatorGpu(): boolean;
export function hasGpuEnums(): boolean;
export function installNavigatorGpu(gpu: GPU, options?: { force?: boolean }): boolean;
export function openNodeWebGPU(options: NodeWebGPUProviderOptions): Promise<NodeWebGPUProviderSession>;
export function probeNodeWebGPU(options: NodeWebGPUProviderOptions): Promise<NodeWebGPUProbeSuccess | NodeWebGPUProbeFailure>;

export type NodeWebGPUByteSource = string | ArrayBuffer | ArrayBufferView;

export interface NodeWebGPUGovernedWorkload {
  id: string;
  version: string;
  implementationSha256: `sha256:${string}`;
  input: NodeWebGPUByteSource;
  expectedOutputSha256: `sha256:${string}`;
}

export interface NodeWebGPUGovernedCheckpointReceipt {
  schema: 'doe.governed-node-webgpu-receipt/v1';
  status: 'oracle-pass' | 'pass' | 'failed';
  checkpoint: 'inference-complete-release-pending' | 'release-complete';
  workload: Record<string, unknown>;
  provider: Record<string, unknown>;
  adapterInfo: Record<string, unknown>;
  adapterInfoStatus: 'observed' | 'absent' | 'query-failed';
  oracle: Record<string, unknown>;
  execution: { durationMs: number | null };
  lifecycle: Record<string, unknown>;
  replay: { workloadSha256: string; executionSha256: string };
  errors: Array<{ code: string; stage: string; detail: string }>;
}

export interface NodeWebGPUGovernedOptions {
  provider: NodeWebGPUProviderOptions;
  workload: NodeWebGPUGovernedWorkload;
  execute(context: {
    gpu: GPU;
    adapter: GPUAdapter;
    module: unknown;
    input: Uint8Array;
  }): Promise<NodeWebGPUByteSource> | NodeWebGPUByteSource;
  checkpoint?(receipt: NodeWebGPUGovernedCheckpointReceipt): Promise<void> | void;
}

export interface NodeWebGPUGovernedResult {
  ok: boolean;
  output: Uint8Array | null;
  receipt: NodeWebGPUGovernedCheckpointReceipt | null;
  errors: Array<{ code: string; stage: string; detail: string }>;
}

export function validateGovernedNodeWebGPUReceipt(
  receipt: unknown,
): { valid: boolean; errors: string[] };

export function runGovernedNodeWebGPU(
  options: NodeWebGPUGovernedOptions,
): Promise<NodeWebGPUGovernedResult>;

export interface NodeWebGPUCompatibilityBootstrapOptions {
  force?: boolean;
  adapterOptions?: GPURequestAdapterOptions | null;
  provider?: NodeWebGPUProvider;
}

export function bootstrapNodeWebGPU(options?: NodeWebGPUCompatibilityBootstrapOptions): Promise<{
  ok: boolean;
  provider: string | null;
  detail: string | null;
  session?: NodeWebGPUProviderSession;
  receipt: NodeWebGPUProviderReceipt | null;
  error?: NodeWebGPUProviderError;
}>;

export function bootstrapNodeWebGPUProvider(
  providerSpecifier: string,
  options?: NodeWebGPUCompatibilityBootstrapOptions,
): Promise<{
  ok: true;
  provider: string;
  module: unknown;
  session: NodeWebGPUProviderSession;
  receipt: NodeWebGPUProviderReceipt;
}>;

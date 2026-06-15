import type {
  BoundDoeNamespace,
  DoeKernelCreateOptions,
  DoeKernelDispatchOptions,
  DoeMatmulLogitsSliceOptions,
  DoeNamespace,
  DoeNumericStabilityReceipt,
  DoeNumericStabilityRouteDecision,
} from "./vendor/doe-namespace.js";

export type {
  BoundDoeNamespace,
  DoeKernelCreateOptions,
  DoeKernelDispatchOptions,
  DoeMatmulLogitsSliceOptions,
  DoeNamespace,
  DoeNumericStabilityReceipt,
  DoeNumericStabilityRouteDecision,
};

export type {
  DoeBufferUsage,
  DoeWorkgroups,
  DoeBindingAccess,
  DoeCreateBufferOptions,
  DoeReadBufferOptions,
  DoeReadBufferSubrangeOptions,
  DoeStableTokenOptions,
  DoeStableTokenReceipt,
  DoeStableTokenResult,
  DoeStableTokenTieBreakRule,
  DoeStableChoiceOptions,
  DoeStableChoiceReceipt,
  DoeStableChoiceResult,
  DoeNumericStabilityCandidateInput,
  DoeNumericStabilityFirstDivergence,
  DoeNumericStabilityExecutionIdentity,
  DoeNumericStabilityReceiptCandidate,
  DoeOrdinaryExecutionOptions,
  DoeOrdinaryExecutionResult,
  DoeNumericStabilityOrdinaryExecutionOptions,
  DoeNumericStabilityOrdinaryExecutionResult,
  DoeMatmulLogitsSliceResult,
  DoeReviewedChoiceOptions,
  DoeReviewedChoiceReceipt,
  DoeReviewedChoiceResult,
  DoeDeterminismProofLink,
  DoeComputeOptions,
  DoeKernel,
  DoeComputeBatch,
  DoeComputePass,
  DoeCommandEncoder,
} from "./vendor/doe-namespace.js";

export interface FastPathStats {
  dispatchFlush: number;
  flushAndMap: number;
  commandBufferBuild: number;
}

export interface NativeFastPathInfo {
  appleFastPathCompiled: boolean;
  queueFlush: boolean;
  queueFlushBreakdown: boolean;
  queueWriteBufferBatch: boolean;
  queueWriteBufferBatchDataPtrs: boolean;
  computeDispatchFlush: boolean;
  computeDispatchFlushOneBindGroup: boolean;
  computeDispatchFlushBreakdown: boolean;
  computeDispatchBatchFlush: boolean;
  computeDispatchBatchCopyFlush: boolean;
  computeDispatchBatchCopyFlushBreakdown: boolean;
  computePrewarmDispatchBindings: boolean;
  bufferMapReadCopyUnmap: boolean;
}

export interface PreparedDispatchPrewarmCommand {
  t?: number;
  p?: unknown;
  b?: unknown;
  bg?: unknown[];
}

export interface PreparedDispatchPrewarmResult {
  available: boolean;
  requestedCount: number;
  preparedCount: number;
}

export interface NativeQueueSyncInfo {
  backendVulkan: boolean;
  timelineSemaphore: boolean;
  fencePool: boolean;
  deferredSubmissions: boolean;
  queueFamilyPolicy?: 'prefer_graphics_compute' | 'prefer_compute_only' | 'require_compute_only';
  deferredSubmissionSyncPolicy?: 'prefer_timeline_semaphore' | 'require_fence_pool';
  queueFamilyKind?: 'graphics_compute' | 'compute_only';
  queueFamilyIndex?: number;
  queueFamilyQueueCount?: number;
  queueFamilyTimestampValidBits?: number;
  queueFamilySupportsGraphics?: boolean;
}

export interface NativePipelineCacheInfo {
  backend: 'vulkan';
  state: 'enabled' | 'disabled';
  reason: 'default' | 'cli-flag' | 'non-doe-backend' | 'platform-unsupported';
  warmupCount: number;
  warmupNs: number;
}

export interface ProviderInfo {
  module: string;
  loaded: boolean;
  loadError: string;
  defaultCreateArgs: string[];
  doeNative: boolean;
  libraryFlavor: string;
  doeLibraryPath: string;
  buildMetadataSource: string;
  buildMetadataPath: string;
  leanVerifiedBuild: boolean | null;
  proofArtifactSha256: string | null;
  nativeFastPaths: NativeFastPathInfo | null;
}

export interface DoeRuntimeRunResult {
  ok: boolean;
  exitCode: number;
  stdout: string;
  stderr: string;
  signal: string | null;
  command: string[];
}

export interface DoeRuntimeBenchResult extends DoeRuntimeRunResult {
  traceJsonlPath: string | null;
  traceMetaPath: string | null;
  traceMeta: Record<string, unknown> | null;
}

export interface DoeRuntimeBenchOptions {
  commandsPath: string;
  quirksPath?: string;
  kernelRoot?: string;
  numericStabilityPolicyPath?: string;
  executionProfileId?: string;
  numericStabilityExecutionProfileId?: string;
  vendor?: string;
  api?: string;
  family?: string;
  driver?: string;
  backendLane?: string;
  traceJsonlPath?: string;
  traceMetaPath?: string;
  uploadBufferUsage?: string;
  uploadSubmitEvery?: number;
  queueWaitMode?: string;
  queueSyncMode?: string;
  extraArgs?: string[];
  cwd?: string;
}

export interface DoeRuntimeModuleResult extends DoeRuntimeRunResult {
  output: Record<string, unknown> | null;
}

export interface DoeRuntimeNumericStabilityMatmulLogitsSliceResult
  extends DoeRuntimeModuleResult {
  receiptPath: string | null;
  traceMetaPath: string | null;
  traceMeta: Record<string, unknown> | null;
  routeDecision: DoeNumericStabilityRouteDecision;
  token: number | null;
  receipt: DoeNumericStabilityReceipt;
}

export interface DoeRuntimeNumericStabilityOrdinaryExecutionResult
  extends DoeRuntimeBenchResult {
  executionProfileId: string | null;
  receiptPath: string | null;
  receipts: DoeNumericStabilityReceipt[];
  latestReceipt: DoeNumericStabilityReceipt | null;
  routeDecisions: DoeNumericStabilityRouteDecision[];
  latestRouteDecision: DoeNumericStabilityRouteDecision | null;
  latestToken: number | null;
}

export interface DoeRuntimeOrdinaryExecutionResult
  extends DoeRuntimeNumericStabilityOrdinaryExecutionResult {}

export interface DoeRuntime {
  binPath: string;
  libPath: string | null;
  moduleRunnerPath: string | null;
  runRaw(args: string[], spawnOptions?: Record<string, unknown>): DoeRuntimeRunResult;
  runBench(options: DoeRuntimeBenchOptions): DoeRuntimeBenchResult;
  runModule(options: {
    moduleId: string;
    request: Record<string, unknown>;
    policyPath: string;
    cwd?: string;
    moduleRunnerPath?: string;
  }): DoeRuntimeModuleResult;
  runNumericStabilityMatmulLogitsSlice(
    options: DoeMatmulLogitsSliceOptions<unknown>,
  ): DoeRuntimeNumericStabilityMatmulLogitsSliceResult;
  runOrdinaryExecution(
    options: DoeRuntimeBenchOptions,
  ): DoeRuntimeOrdinaryExecutionResult;
  runNumericStabilityOrdinaryExecution(
    options: DoeRuntimeBenchOptions,
  ): DoeRuntimeNumericStabilityOrdinaryExecutionResult;
}

export interface RequestDeviceOptions {
  adapterOptions?: GPURequestAdapterOptions;
  deviceDescriptor?: GPUDeviceDescriptor;
  createArgs?: string[] | null;
}

export interface FullDoeKernelCreateOptions extends DoeKernelCreateOptions<GPUBuffer> {}

export interface FullDoeKernelDispatchOptions extends DoeKernelDispatchOptions<GPUBuffer> {}

export interface FullDoeKernel {
  readonly device: GPUDevice;
  readonly entryPoint: string;
  dispatch(options: FullDoeKernelDispatchOptions): Promise<void>;
}

export interface FullBoundDoeNamespace
  extends BoundDoeNamespace<GPUDevice, GPUBuffer, FullDoeKernel, FullDoeKernelCreateOptions> {}

export interface FullDoeNamespace
  extends DoeNamespace<
    GPUDevice,
    FullBoundDoeNamespace,
    RequestDeviceOptions
  > {}

export interface CanvasLike {
  width: number;
  height: number;
  [key: string]: unknown;
}

export const globals: Record<string, unknown>;
export function create(createArgs?: string[] | null): GPU;
export function createCanvasContext(canvas: CanvasLike): GPUCanvasContext;
export function createInstance(createArgs?: string[] | null): GPU;
export function setupGlobals(target?: object, createArgs?: string[] | null): GPU;
export function requestAdapter(
  adapterOptions?: GPURequestAdapterOptions,
  createArgs?: string[] | null
): Promise<GPUAdapter | null>;
export function requestDevice(options?: RequestDeviceOptions): Promise<GPUDevice>;
export function providerInfo(): ProviderInfo;
export function nativeFastPathInfo(): NativeFastPathInfo | null;
export function prewarmPreparedDispatches(
  queue: GPUQueue,
  dispatchCommands: PreparedDispatchPrewarmCommand[]
): PreparedDispatchPrewarmResult;
export function nativeQueueSyncInfo(queue: GPUQueue): NativeQueueSyncInfo | null;
export function nativePipelineCacheInfo(queue: GPUQueue): NativePipelineCacheInfo | null;
export function packagePipelineCacheFlush(queue?: GPUQueue | null): boolean;
export const fastPathStats: FastPathStats | undefined;
export function createDoeRuntime(options?: {
  binPath?: string;
  libPath?: string;
  moduleRunnerPath?: string;
}): DoeRuntime;
export function runDawnVsDoeCompare(options: Record<string, unknown>): DoeRuntimeRunResult;
export function preflightShaderSource(code: string): {
  ok: boolean;
  stage: string;
  kind: string;
  message: string;
  reasons: string[];
  line?: number;
  column?: number;
};
export function setNativeTimeoutMs(ms: number): void;
export function normalizeOrigin2D(origin: GPUOrigin2D | null | undefined, path: string): { x: number; y: number };
export function normalizeCanvasConfiguration(
  config: GPUCanvasConfiguration,
  path: string
): {
  device: GPUDevice;
  format: GPUTextureFormat;
  usage: number;
  alphaMode: GPUCanvasAlphaMode;
  colorSpace: PredefinedColorSpace;
  toneMapping: { mode: GPUCanvasToneMappingMode };
  viewFormats: GPUTextureFormat[];
};
export const CANVAS_ALPHA_MODES: Readonly<Record<string, GPUCanvasAlphaMode>>;
export const CANVAS_TONE_MAPPING_MODES: Readonly<Record<string, GPUCanvasToneMappingMode>>;
export const CANVAS_COLOR_SPACES: Readonly<Record<string, PredefinedColorSpace>>;

export const gpu: FullDoeNamespace;

export declare function createGpuNamespace<
  TDevice = unknown,
  TBuffer = unknown,
  TBindingSet = unknown,
  TKernel = unknown,
  TBatch = unknown,
  TPass = unknown,
  TEncoder = unknown,
  TBoundDoe = unknown,
  TRequestDeviceOptions = unknown,
>(options?: {
  requestDevice?: (options?: TRequestDeviceOptions) => Promise<TDevice> | TDevice;
}): DoeNamespace<TDevice, TBoundDoe, TRequestDeviceOptions>;

export { createGpuNamespace as createDoeNamespace };

declare const _default: {
  CANVAS_ALPHA_MODES: typeof CANVAS_ALPHA_MODES;
  CANVAS_TONE_MAPPING_MODES: typeof CANVAS_TONE_MAPPING_MODES;
  CANVAS_COLOR_SPACES: typeof CANVAS_COLOR_SPACES;
  create: typeof create;
  createCanvasContext: typeof createCanvasContext;
  createInstance: typeof createInstance;
  globals: typeof globals;
  normalizeCanvasConfiguration: typeof normalizeCanvasConfiguration;
  normalizeOrigin2D: typeof normalizeOrigin2D;
  setupGlobals: typeof setupGlobals;
  requestAdapter: typeof requestAdapter;
  requestDevice: typeof requestDevice;
  providerInfo: typeof providerInfo;
  nativeFastPathInfo: typeof nativeFastPathInfo;
  prewarmPreparedDispatches: typeof prewarmPreparedDispatches;
  nativeQueueSyncInfo: typeof nativeQueueSyncInfo;
  nativePipelineCacheInfo: typeof nativePipelineCacheInfo;
  packagePipelineCacheFlush: typeof packagePipelineCacheFlush;
  fastPathStats: typeof fastPathStats;
  createDoeRuntime: typeof createDoeRuntime;
  runDawnVsDoeCompare: typeof runDawnVsDoeCompare;
  preflightShaderSource: typeof preflightShaderSource;
  setNativeTimeoutMs: typeof setNativeTimeoutMs;
  gpu: FullDoeNamespace;
  createGpuNamespace: typeof createGpuNamespace;
};

export default _default;

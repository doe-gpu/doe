import type { NodeWebGPUProviderOptions, NodeWebGPUProviderReceipt } from './node-webgpu.js';

export const PROGRAM_BUNDLE_RUNNER_VERSION: 'doe.program-bundle-runner/v2';
export const PROGRAM_BUNDLE_SCHEMA_ID: 'doppler.program-bundle/v1';
export const PROGRAM_BUNDLE_JSON_SCHEMA_ID: 'urn:doppler:program-bundle-schema:v1';

export interface ClosedProgramBundle {
  bundlePath: string;
  bundleRoot: string;
  bundle: Record<string, unknown>;
  files: Map<string, {
    role: 'wgsl-source' | 'host-source';
    path: string;
    hash: string;
    sizeBytes: number;
    absolutePath: string;
    bytes: Uint8Array;
  }>;
}

export interface ProgramBundleHostBridge {
  createTextGenerationProgram(
    bundle: Record<string, unknown>,
    options: Record<string, unknown>,
  ): Promise<{ execute(input: unknown): Promise<unknown> }> | { execute(input: unknown): Promise<unknown> };
}

export interface RunProgramBundleOptions {
  programBundlePath: string;
  providerOptions: NodeWebGPUProviderOptions;
  deviceDescriptor?: GPUDeviceDescriptor;
  execution?: {
    hostBridge: ProgramBundleHostBridge;
    options?: Record<string, unknown>;
    input?: unknown;
  } | null;
}

export interface ProgramBundleRunResult {
  schema: 'doe.program-bundle-run/v2';
  runnerVersion: typeof PROGRAM_BUNDLE_RUNNER_VERSION;
  bundleId: string;
  modelId: string;
  schemaValid: true;
  providerAvailable: true;
  executed: boolean;
  transcriptMatched: boolean;
  providerReceipt: NodeWebGPUProviderReceipt;
  compiledModules: Array<{ id: string; compiled: true; entryPoint: string }>;
  executionResult: unknown;
  transcriptComparison: null | {
    matched: boolean;
    expected: Record<string, unknown>;
    observed: Record<string, unknown>;
    mismatches: Array<{ key: string; expected: unknown; observed: unknown }>;
  };
}

export function validateProgramBundle(bundle: unknown): Promise<Record<string, unknown>>;
export function loadClosedProgramBundle(programBundlePath: string): Promise<ClosedProgramBundle>;
export function runProgramBundle(options: RunProgramBundleOptions): Promise<ProgramBundleRunResult>;
export const runProgramBundleInference: typeof runProgramBundle;
export function describeProgramBundleRunner(): Record<string, unknown>;

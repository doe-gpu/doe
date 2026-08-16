export const DOE_TRANSPARENT_WEBGPU_OBSERVATION_SCHEMA:
  'doe.transparent-webgpu-observation/v1';
export const DOE_TRANSPARENT_WEBGPU_OBSERVATION_ARTIFACT_KIND:
  'doe-transparent-webgpu-observation';

export interface TransparentWebGPUObservation {
  schema: 'doe.transparent-webgpu-observation/v1';
  artifactKind: 'doe-transparent-webgpu-observation';
  providerId: string;
  metadata: Record<string, unknown>;
  shaderModules: Array<Record<string, unknown>>;
  compilationInfos?: Array<Record<string, unknown>>;
  computePipelines: Array<Record<string, unknown>>;
  renderPipelines: Array<Record<string, unknown>>;
  resources: Array<Record<string, unknown>>;
  bufferWrites: Array<Record<string, unknown>>;
  textureWrites: Array<Record<string, unknown>>;
  commands: Array<Record<string, unknown>>;
  dispatches: Array<Record<string, unknown>>;
  draws: Array<Record<string, unknown>>;
  submissions: Array<Record<string, unknown>>;
  synchronizations: Array<Record<string, unknown>>;
  readbacks: Array<Record<string, unknown>>;
  summary: Record<string, number>;
  observationSha256: `sha256:${string}`;
}

export interface TransparentWebGPUObserver {
  gpu: GPU;
  adapter: GPUAdapter | null;
  snapshot(): TransparentWebGPUObservation;
}

export function createTransparentWebGPUObserver(options: {
  gpu: GPU;
  adapter?: GPUAdapter | null;
  globals?: Record<string, unknown>;
  providerId?: string;
  metadata?: Record<string, unknown>;
  checkpoint?: (
    observation: TransparentWebGPUObservation,
    context: { reason: 'compilation-info' | 'mapped-readback' },
  ) => void;
}): TransparentWebGPUObserver;

export function validateTransparentWebGPUObservation(
  value: unknown,
): { valid: boolean; errors: string[] };

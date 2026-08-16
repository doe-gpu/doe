import { writeFileSync } from 'node:fs';
import * as base from 'doe-world-base-provider';
import { createTransparentWebGPUObserver } from '../../../packages/doe-gpu/src/observe.js';

const baseModulePath = process.env.DOE_WORLD_LAB_BASE_PROVIDER_MODULE;
const evidencePath = process.env.DOE_WORLD_LAB_EVIDENCE_PATH;
const providerId = process.env.DOE_EXTERNAL_WEBGPU_PROVIDER;
if (!baseModulePath) throw new Error('DOE_WORLD_LAB_BASE_PROVIDER_MODULE is required.');
if (!evidencePath) throw new Error('DOE_WORLD_LAB_EVIDENCE_PATH is required.');
if (!providerId) throw new Error('DOE_EXTERNAL_WEBGPU_PROVIDER is required.');
if (typeof base.create !== 'function' || !base.globals) {
  throw new Error(`${baseModulePath} does not expose create() and globals.`);
}

const evidenceOutputPath = `${evidencePath}.${process.pid}.json`;
const observers = [];
const baseProviderInfo = typeof base.providerInfo === 'function' ? base.providerInfo() : null;

export const globals = base.globals;

function flushEvidence() {
  const artifact = {
    schema: 'doe.world-lab-package-observer-worker/v1',
    providerId,
    baseModulePath,
    observations: observers.map((observer) => observer.snapshot()),
  };
  writeFileSync(evidenceOutputPath, `${JSON.stringify(artifact, null, 2)}\n`);
}

process.once('beforeExit', flushEvidence);
process.once('exit', flushEvidence);

export function create(args = []) {
  const observer = createTransparentWebGPUObserver({
    gpu: base.create(args),
    globals: base.globals,
    providerId,
    metadata: {
      application: 'world-lab-runtime-webgpu',
      contract: 'package-compilation-observer-qm2',
      baseProviderInfo,
    },
    checkpoint: flushEvidence,
  });
  observers.push(observer);
  return observer.gpu;
}

export function providerInfo() {
  return {
    observer: 'doe.transparent-webgpu-observation/v1',
    providerId,
    baseModulePath,
    baseProviderInfo,
  };
}

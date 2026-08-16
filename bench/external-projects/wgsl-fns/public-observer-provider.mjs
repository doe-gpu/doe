import { writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

import { createTransparentWebGPUObserver } from '../../../packages/doe-gpu/src/observe.js';

const providerId = process.env.DOE_EXTERNAL_WEBGPU_PROVIDER;
const modulePath = process.env.DOE_EXTERNAL_WEBGPU_MODULE_PATH;
const evidencePath = process.env.DOE_WGSL_FNS_OBSERVER_EVIDENCE_PATH;
if (!providerId) throw new Error('DOE_EXTERNAL_WEBGPU_PROVIDER is required.');
if (!modulePath) throw new Error('DOE_EXTERNAL_WEBGPU_MODULE_PATH is required.');
if (!evidencePath) throw new Error('DOE_WGSL_FNS_OBSERVER_EVIDENCE_PATH is required.');

const base = await import(pathToFileURL(modulePath).href);
if (typeof base.create !== 'function' || !base.globals) {
  throw new Error(`${modulePath} does not expose create() and globals.`);
}

const outputPath = `${evidencePath}.${process.pid}.json`;
const observers = [];

export const globals = base.globals;
export const __doeHarnessProviderIdentity = Object.freeze({ id: providerId, modulePath });

function flushEvidence() {
  const artifact = {
    schema: 'doe.wgsl-fns-public-compilation-observer-worker/v1',
    providerId,
    modulePath,
    observations: observers.map((observer) => observer.snapshot()),
  };
  writeFileSync(outputPath, `${JSON.stringify(artifact, null, 2)}\n`);
}

process.once('beforeExit', flushEvidence);
process.once('exit', flushEvidence);

export function create(args = []) {
  const observer = createTransparentWebGPUObserver({
    gpu: base.create(args),
    globals: base.globals,
    providerId,
    metadata: {
      application: 'wgsl-fns',
      contract: 'public-compilation-observer-qm0',
    },
    checkpoint: flushEvidence,
  });
  observers.push(observer);
  return observer.gpu;
}

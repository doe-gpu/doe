// doe-gpu/node-webgpu-loader - fail-closed provider substitution for unchanged Node apps.

export const NODE_WEBGPU_LOADER_CONTRACT = 'doe.node-webgpu-loader/v1';
export const NODE_WEBGPU_LOADER_PROGRAM_OBSERVATION_CONTRACT =
  'doe.node-webgpu-loader-program-observation/v1';
export const NODE_WEBGPU_LOADER_PROGRAM_OBSERVATION_REASONS = Object.freeze([
  'mapped-readback',
  'compilation-info',
  'process-before-exit',
  'process-uncaught-exception',
]);
const VIRTUAL_PREFIX = 'doe-node-webgpu-provider:';
const PROVIDER_ID = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const OBSERVER_URL = new URL('./observe.js', import.meta.url).href;

function plainObject(value) {
  return value !== null
    && typeof value === 'object'
    && !Array.isArray(value)
    && (Object.getPrototypeOf(value) === Object.prototype
      || Object.getPrototypeOf(value) === null);
}

function requiredConfiguration() {
  const providerId = process.env.DOE_NODE_WEBGPU_PROVIDER_ID?.trim();
  const providerModule = process.env.DOE_NODE_WEBGPU_PROVIDER_MODULE?.trim();
  if (!providerId || !PROVIDER_ID.test(providerId)) {
    throw new Error(
      'DOE_NODE_WEBGPU_PROVIDER_ID must be an explicit provider identifier.',
    );
  }
  if (!providerModule) {
    throw new Error(
      'DOE_NODE_WEBGPU_PROVIDER_MODULE must be an explicit module specifier.',
    );
  }
  const observationValue = process.env.DOE_NODE_WEBGPU_OBSERVE_PROGRAM;
  if (observationValue !== undefined && !['0', '1'].includes(observationValue)) {
    throw new Error('DOE_NODE_WEBGPU_OBSERVE_PROGRAM must be 0 or 1 when declared.');
  }
  const observeProgram = observationValue === '1';
  let observationMetadata = {};
  if (observeProgram && process.env.DOE_NODE_WEBGPU_OBSERVE_METADATA) {
    try {
      observationMetadata = JSON.parse(process.env.DOE_NODE_WEBGPU_OBSERVE_METADATA);
    } catch {
      throw new Error('DOE_NODE_WEBGPU_OBSERVE_METADATA must be valid JSON.');
    }
    if (!plainObject(observationMetadata)) {
      throw new Error('DOE_NODE_WEBGPU_OBSERVE_METADATA must decode to an object.');
    }
  }
  return { providerId, providerModule, observeProgram, observationMetadata };
}

function encodeVirtualIdentity(identity) {
  return Buffer.from(JSON.stringify(identity), 'utf8').toString('base64url');
}

function decodeVirtualIdentity(url) {
  return JSON.parse(
    Buffer.from(url.slice(VIRTUAL_PREFIX.length), 'base64url').toString('utf8'),
  );
}

export async function resolve(specifier, context, nextResolve) {
  if (specifier !== 'webgpu') return nextResolve(specifier, context);
  const configuration = requiredConfiguration();
  const provider = await nextResolve(configuration.providerModule, context);
  const identity = {
    contract: NODE_WEBGPU_LOADER_CONTRACT,
    requestedSpecifier: 'webgpu',
    providerId: configuration.providerId,
    providerModule: configuration.providerModule,
    resolvedProviderUrl: provider.url,
    ...(configuration.observeProgram ? {
      programObservation: {
        contract: NODE_WEBGPU_LOADER_PROGRAM_OBSERVATION_CONTRACT,
        metadata: configuration.observationMetadata,
      },
    } : {}),
  };
  return {
    url: `${VIRTUAL_PREFIX}${encodeVirtualIdentity(identity)}`,
    shortCircuit: true,
  };
}

export async function load(url, context, nextLoad) {
  if (!url.startsWith(VIRTUAL_PREFIX)) return nextLoad(url, context);
  const identity = decodeVirtualIdentity(url);
  const providerUrl = JSON.stringify(identity.resolvedProviderUrl);
  const serializedIdentity = JSON.stringify(identity);
  const observation = identity.programObservation;
  const observerImport = observation
    ? `import { createTransparentWebGPUObserver } from ${JSON.stringify(OBSERVER_URL)};`
    : '';
  const createExport = observation
    ? `
      if (typeof process.send !== 'function') {
        throw new Error(
          'Program observation requires the governed process IPC contract.',
        );
      }
      const activeObservers = [];
      const sendObservation = (observation, context) => {
        try {
          process.send({
            contract: ${JSON.stringify(NODE_WEBGPU_LOADER_PROGRAM_OBSERVATION_CONTRACT)},
            observation,
            context,
          }, () => {});
        } catch {
          // The parent enforces missing evidence; observation cannot alter app behavior.
        }
      };
      const sendAllObservations = (reason) => {
        for (const observer of activeObservers) {
          sendObservation(observer.snapshot(), { reason });
        }
      };
      process.once('beforeExit', () => {
        sendAllObservations('process-before-exit');
      });
      process.once('uncaughtExceptionMonitor', () => {
        sendAllObservations('process-uncaught-exception');
      });
      export function create(...args) {
        const observer = createTransparentWebGPUObserver({
          gpu: provider.create(...args),
          globals: provider.globals,
          providerId: ${JSON.stringify(identity.providerId)},
          metadata: ${JSON.stringify(observation.metadata)},
          checkpoint: sendObservation,
        });
        activeObservers.push(observer);
        return observer.gpu;
      }
    `
    : 'export const create = provider.create;';
  return {
    format: 'module',
    shortCircuit: true,
    source: `
      import * as provider from ${providerUrl};
      ${observerImport}
      if (typeof provider.create !== 'function' || !provider.globals) {
        throw new Error(
          'Declared Node WebGPU provider must export create() and globals.',
        );
      }
      const runtimeInfo = typeof provider.providerInfo === 'function'
        ? provider.providerInfo()
        : null;
      export * from ${providerUrl};
      ${createExport}
      export const globals = provider.globals;
      export const __doeProofProviderIdentity = Object.freeze(${serializedIdentity});
      export const __doeProofProviderRuntimeInfo = runtimeInfo;
      export default provider.default;
    `,
  };
}

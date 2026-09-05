import { createHash } from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

import { openNodeWebGPU } from './node-webgpu.js';
import { sortedJsonValue } from './json-canonical.js';

export const PROGRAM_BUNDLE_RUNNER_VERSION = 'doe.program-bundle-runner/v2';
export const PROGRAM_BUNDLE_SCHEMA_ID = 'doppler.program-bundle/v1';
export const PROGRAM_BUNDLE_JSON_SCHEMA_ID = 'urn:doppler:program-bundle-schema:v1';

const SCHEMA_URL = new URL('../assets/program-bundle.schema.json', import.meta.url);

function digestBytes(bytes) {
  return `sha256:${createHash('sha256').update(bytes).digest('hex')}`;
}

function isObject(value) {
  return !!value && typeof value === 'object' && !Array.isArray(value);
}

function valueTypeMatches(value, expected) {
  if (expected === 'null') return value === null;
  if (expected === 'array') return Array.isArray(value);
  if (expected === 'object') return isObject(value);
  if (expected === 'integer') return Number.isInteger(value);
  if (expected === 'number') return typeof value === 'number' && Number.isFinite(value);
  return typeof value === expected;
}

function deepEqual(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function resolveSchemaRef(rootSchema, reference) {
  if (typeof reference !== 'string' || !reference.startsWith('#/')) {
    throw new Error(`program bundle schema: unsupported $ref "${reference}".`);
  }
  let current = rootSchema;
  for (const rawSegment of reference.slice(2).split('/')) {
    const segment = rawSegment.replace(/~1/g, '/').replace(/~0/g, '~');
    current = current?.[segment];
  }
  if (!current) throw new Error(`program bundle schema: unresolved $ref "${reference}".`);
  return current;
}

function validateSchemaNode(value, schema, rootSchema, location, failures) {
  if (schema.$ref) {
    validateSchemaNode(value, resolveSchemaRef(rootSchema, schema.$ref), rootSchema, location, failures);
    return;
  }
  if (Array.isArray(schema.anyOf)) {
    const branches = schema.anyOf.map((branch) => {
      const branchFailures = [];
      validateSchemaNode(value, branch, rootSchema, location, branchFailures);
      return branchFailures;
    });
    if (!branches.some((branch) => branch.length === 0)) {
      failures.push(`${location} does not match any allowed schema branch.`);
    }
    return;
  }
  if (schema.const !== undefined && !deepEqual(value, schema.const)) {
    failures.push(`${location} must equal ${JSON.stringify(schema.const)}.`);
    return;
  }
  if (Array.isArray(schema.enum) && !schema.enum.some((item) => deepEqual(value, item))) {
    failures.push(`${location} must be one of ${schema.enum.map((item) => JSON.stringify(item)).join(', ')}.`);
    return;
  }
  if (schema.type !== undefined) {
    const expectedTypes = Array.isArray(schema.type) ? schema.type : [schema.type];
    if (!expectedTypes.some((expected) => valueTypeMatches(value, expected))) {
      failures.push(`${location} must have type ${expectedTypes.join(' or ')}.`);
      return;
    }
  }
  if (typeof value === 'string') {
    if (schema.minLength !== undefined && value.length < schema.minLength) {
      failures.push(`${location} must contain at least ${schema.minLength} character(s).`);
    }
    if (schema.pattern && !(new RegExp(schema.pattern, 'u')).test(value)) {
      failures.push(`${location} does not match ${schema.pattern}.`);
    }
  }
  if (typeof value === 'number' && schema.minimum !== undefined && value < schema.minimum) {
    failures.push(`${location} must be >= ${schema.minimum}.`);
  }
  if (Array.isArray(value)) {
    if (schema.minItems !== undefined && value.length < schema.minItems) {
      failures.push(`${location} must contain at least ${schema.minItems} item(s).`);
    }
    if (schema.items) {
      value.forEach((item, index) => {
        validateSchemaNode(item, schema.items, rootSchema, `${location}[${index}]`, failures);
      });
    }
  }
  if (isObject(value)) {
    for (const key of schema.required ?? []) {
      if (!Object.prototype.hasOwnProperty.call(value, key)) {
        failures.push(`${location}.${key} is required.`);
      }
    }
    if (schema.properties) {
      for (const [key, childSchema] of Object.entries(schema.properties)) {
        if (Object.prototype.hasOwnProperty.call(value, key)) {
          validateSchemaNode(value[key], childSchema, rootSchema, `${location}.${key}`, failures);
        }
      }
    }
    if (schema.additionalProperties === false) {
      const allowed = new Set(Object.keys(schema.properties ?? {}));
      for (const key of Object.keys(value)) {
        if (!allowed.has(key)) failures.push(`${location}.${key} is not allowed.`);
      }
    }
  }
}

async function readCanonicalSchema() {
  const schema = JSON.parse(await fs.readFile(SCHEMA_URL, 'utf8'));
  if (schema.$id !== PROGRAM_BUNDLE_JSON_SCHEMA_ID) {
    throw new Error(`Doe packaged Program Bundle schema must have $id "${PROGRAM_BUNDLE_JSON_SCHEMA_ID}".`);
  }
  return schema;
}

export async function validateProgramBundle(bundle) {
  const schema = await readCanonicalSchema();
  const failures = [];
  validateSchemaNode(bundle, schema, schema, '$', failures);
  if (failures.length > 0) {
    const error = new Error(`Program Bundle schema validation failed: ${failures.slice(0, 8).join(' ')}`);
    error.code = 'DOE_PROGRAM_BUNDLE_SCHEMA_INVALID';
    error.failures = failures;
    throw error;
  }

  const packageFiles = new Map(bundle.package.files.map((file) => [file.path, file]));
  const expectedFileSetHash = digestBytes(JSON.stringify(sortedJsonValue(bundle.package.files)));
  if (bundle.package.fileSetHash !== expectedFileSetHash) {
    throw new Error('Program Bundle package.fileSetHash does not match package.files.');
  }
  for (const entrypoint of bundle.host.entrypoints) {
    const file = packageFiles.get(entrypoint.module);
    if (!file || file.role !== 'host-source' || file.hash !== entrypoint.sourceHash) {
      throw new Error(`Program Bundle host entrypoint "${entrypoint.id}" is not bound to packaged source bytes.`);
    }
  }
  for (const module of bundle.wgslModules) {
    const file = packageFiles.get(module.sourcePath);
    if (!file || file.role !== 'wgsl-source' || file.hash !== module.sourceHash) {
      throw new Error(`Program Bundle WGSL module "${module.id}" is not bound to packaged source bytes.`);
    }
  }
  return bundle;
}

function resolveClosedPath(bundleRoot, relativePath) {
  const resolved = path.resolve(bundleRoot, relativePath);
  const relative = path.relative(bundleRoot, resolved);
  if (relative.startsWith('..') || path.isAbsolute(relative)) {
    throw new Error(`Program Bundle path escapes its bundle root: ${relativePath}.`);
  }
  return resolved;
}

export async function loadClosedProgramBundle(programBundlePath) {
  if (typeof programBundlePath !== 'string' || programBundlePath.trim().length === 0) {
    throw new Error('loadClosedProgramBundle: programBundlePath is required.');
  }
  const bundlePath = path.resolve(programBundlePath);
  const bundle = await validateProgramBundle(JSON.parse(await fs.readFile(bundlePath, 'utf8')));
  const bundleRoot = path.dirname(bundlePath);
  const files = new Map();
  for (const file of bundle.package.files) {
    const absolutePath = resolveClosedPath(bundleRoot, file.path);
    let bytes;
    try {
      bytes = await fs.readFile(absolutePath);
    } catch (error) {
      throw new Error(`Program Bundle packaged file is unavailable: ${file.path}: ${error.message}`);
    }
    const observedHash = digestBytes(bytes);
    if (observedHash !== file.hash || bytes.byteLength !== file.sizeBytes) {
      throw new Error(`Program Bundle packaged file hash/size mismatch: ${file.path}.`);
    }
    files.set(file.path, { ...file, absolutePath, bytes });
  }
  return { bundlePath, bundleRoot, bundle, files };
}

function compareTranscript(bundle, transcript) {
  const expected = {
    executionGraphHash: bundle.sources.executionGraph.hash,
    tokenHash: bundle.referenceTranscript.tokens.generatedTokenIdsHash,
    textHash: bundle.referenceTranscript.output.textHash,
    tokensGenerated: bundle.referenceTranscript.output.tokensGenerated,
    stopReason: bundle.referenceTranscript.output.stopReason,
    kvCacheStateHash: bundle.referenceTranscript.kvCache.stateHash,
  };
  const observed = {
    executionGraphHash: transcript?.executionGraphHash ?? null,
    tokenHash: transcript?.tokens?.generatedTokenIdsHash ?? null,
    textHash: transcript?.output?.textHash ?? null,
    tokensGenerated: transcript?.output?.tokensGenerated ?? null,
    stopReason: transcript?.output?.stopReason ?? null,
    kvCacheStateHash: transcript?.kvCache?.stateHash ?? null,
  };
  const mismatches = Object.keys(expected)
    .filter((key) => expected[key] !== observed[key])
    .map((key) => ({ key, expected: expected[key], observed: observed[key] }));
  return { matched: mismatches.length === 0, expected, observed, mismatches };
}

async function compileWgslModules(device, loaded) {
  const results = [];
  for (const declaration of loaded.bundle.wgslModules) {
    const source = loaded.files.get(declaration.sourcePath).bytes.toString('utf8');
    const shaderModule = device.createShaderModule({
      label: `program-bundle:${declaration.id}`,
      code: source,
    });
    if (typeof shaderModule.getCompilationInfo === 'function') {
      const info = await shaderModule.getCompilationInfo();
      const errors = Array.from(info?.messages ?? []).filter((message) => message.type === 'error');
      if (errors.length > 0) {
        throw new Error(`Program Bundle WGSL compile failed for "${declaration.id}": ${errors.map((error) => error.message).join('; ')}`);
      }
    }
    device.createComputePipeline({
      layout: 'auto',
      compute: { module: shaderModule, entryPoint: declaration.entry },
    });
    results.push({ id: declaration.id, compiled: true, entryPoint: declaration.entry });
  }
  return results;
}

async function executeHost(loaded, execution) {
  if (!execution || typeof execution !== 'object') {
    return { executed: false, result: null, transcript: null };
  }
  if (!execution.hostBridge || typeof execution.hostBridge.createTextGenerationProgram !== 'function') {
    throw new Error('runProgramBundle: execution.hostBridge.createTextGenerationProgram is required.');
  }
  const entrypoint = loaded.bundle.host.entrypoints[0];
  const source = loaded.files.get(entrypoint.module);
  const moduleNamespace = await import(`${pathToFileURL(source.absolutePath).href}?sha256=${source.hash.slice(7)}`);
  const factory = moduleNamespace[entrypoint.export];
  if (typeof factory !== 'function') {
    throw new Error(`Program Bundle host module does not export "${entrypoint.export}".`);
  }
  const program = await factory(execution.hostBridge, loaded.bundle, execution.options ?? {});
  if (!program || typeof program.execute !== 'function') {
    throw new Error('Program Bundle host bridge must return a program with execute(input).');
  }
  const result = await program.execute(execution.input);
  return {
    executed: true,
    result,
    transcript: result?.referenceTranscript ?? null,
  };
}

export async function runProgramBundle(options = {}) {
  const loaded = await loadClosedProgramBundle(options.programBundlePath);
  if (!options.providerOptions) {
    throw new Error('runProgramBundle: providerOptions is required; Doe does not select a provider implicitly.');
  }

  let providerSession = null;
  let device = null;
  try {
    providerSession = await openNodeWebGPU(options.providerOptions);
    device = options.deviceDescriptor === undefined
      ? await providerSession.adapter.requestDevice()
      : await providerSession.adapter.requestDevice(options.deviceDescriptor);
    if (!device) throw new Error('runProgramBundle: selected adapter returned no device.');
    const compiledModules = await compileWgslModules(device, loaded);
    const execution = await executeHost(loaded, options.execution ?? null);
    const comparison = execution.executed
      ? compareTranscript(loaded.bundle, execution.transcript)
      : null;
    return {
      schema: 'doe.program-bundle-run/v2',
      runnerVersion: PROGRAM_BUNDLE_RUNNER_VERSION,
      bundleId: loaded.bundle.bundleId,
      modelId: loaded.bundle.modelId,
      schemaValid: true,
      providerAvailable: true,
      executed: execution.executed,
      transcriptMatched: comparison?.matched ?? false,
      providerReceipt: providerSession.receipt,
      compiledModules,
      executionResult: execution.result,
      transcriptComparison: comparison,
    };
  } finally {
    try {
      device?.destroy?.();
    } finally {
      await providerSession?.close?.();
    }
  }
}

export const runProgramBundleInference = runProgramBundle;

export function describeProgramBundleRunner() {
  return {
    runnerVersion: PROGRAM_BUNDLE_RUNNER_VERSION,
    schema: 'doe.program-bundle-run/v2',
    capabilities: {
      canonicalSchemaValidation: true,
      closedSourceVerification: true,
      exactWgslEntryCompilation: true,
      explicitProviderV1: true,
      constrainedHostExecution: true,
      transcriptComparison: true,
    },
  };
}

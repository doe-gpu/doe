// Schema validation and immutable identity for fixed-shape compute programs.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';

const PROGRAM_SCHEMA = JSON.parse(readFileSync(
  new URL('../assets/compute-program.schema.json', import.meta.url), 'utf8',
));
const BUFFER_ALIGNMENT = Uint32Array.BYTES_PER_ELEMENT;

function validateProgramOptions(options) {
  validateNode(options, PROGRAM_SCHEMA.$defs.options, 'options');
  return { gpuTiming: PROGRAM_SCHEMA.$defs.options.properties.gpuTiming.default,
    readback: PROGRAM_SCHEMA.$defs.options.properties.readback.default, ...options };
}

function programError(code, path, expected, received) {
  return Object.assign(new Error(`${path}: expected ${expected}; received ${String(received)}`), {
    code, path, expected, received,
  });
}

function validateNode(value, schema, path) {
  if (schema.$ref) {
    return validateNode(value, PROGRAM_SCHEMA.$defs[schema.$ref.split('/').at(-1)], path);
  }
  const fail = (expected) => { throw programError('DOE_PROGRAM_INVALID', path, expected, value); };
  const kind = Array.isArray(value) ? 'array' : value === null ? 'null' : typeof value;
  if (schema.type === 'integer') {
    if (!Number.isSafeInteger(value)) fail('safe integer');
  } else if (schema.type && kind !== schema.type) fail(schema.type);
  if (schema.const !== undefined && value !== schema.const) fail(schema.const);
  if (schema.enum && !schema.enum.includes(value)) fail(schema.enum.join(' | '));
  if (typeof value === 'number') {
    if (schema.minimum !== undefined && value < schema.minimum) fail(`>= ${schema.minimum}`);
    if (schema.maximum !== undefined && value > schema.maximum) fail(`<= ${schema.maximum}`);
    if (schema.multipleOf && value % schema.multipleOf !== 0) fail(`multiple of ${schema.multipleOf}`);
  }
  if (typeof value === 'string') {
    if (schema.minLength && value.length < schema.minLength) fail('nonempty string');
    if (schema.pattern && !new RegExp(schema.pattern).test(value)) fail(schema.pattern);
  }
  if (kind === 'array') {
    if (schema.minItems && value.length < schema.minItems) fail(`at least ${schema.minItems} items`);
    if (schema.maxItems && value.length > schema.maxItems) fail(`at most ${schema.maxItems} items`);
    value.forEach((item, index) => validateNode(item, schema.items, `${path}[${index}]`));
  }
  if (kind === 'object') {
    for (const key of schema.required ?? []) {
      if (!Object.hasOwn(value, key)) fail(`required field ${key}`);
    }
    for (const [key, item] of Object.entries(value)) {
      if (!Object.hasOwn(schema.properties ?? {}, key)) fail(`declared field, got ${key}`);
      validateNode(item, schema.properties[key], `${path}.${key}`);
    }
  }
}

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonical(value[key])]));
  }
  return value;
}

function hashBytes(value) {
  return createHash('sha256').update(value).digest('hex');
}

function freezeTree(value) {
  if (value !== null && typeof value === 'object') {
    Object.values(value).forEach(freezeTree);
    Object.freeze(value);
  }
  return value;
}

function validateComputeProgram(descriptor) {
  validateNode(descriptor, PROGRAM_SCHEMA, 'program');
  if (descriptor.schemaVersion === 1 && descriptor.buffers.some((buffer) => buffer.lifetime !== undefined)) {
    throw programError('DOE_PROGRAM_INVALID', 'program.schemaVersion', 'version 2 for declared lifetimes', 1);
  }
  const unique = (values, path) => {
    if (new Set(values).size !== values.length) {
      throw programError('DOE_PROGRAM_INVALID', path, 'unique identifiers', values.join(', '));
    }
  };
  unique(descriptor.buffers.map((buffer) => buffer.id), 'program.buffers');
  unique(descriptor.shaders.map((shader) => shader.id), 'program.shaders');
  const buffers = new Map(descriptor.buffers.map((buffer) => [buffer.id, buffer]));
  const shaders = new Set(descriptor.shaders.map((shader) => shader.id));
  const usedBuffers = new Set();
  const usedShaders = new Set();
  for (const [index, step] of descriptor.steps.entries()) {
    if (!shaders.has(step.shader)) {
      throw programError('DOE_PROGRAM_INVALID', `program.steps[${index}].shader`, 'declared shader', step.shader);
    }
    usedShaders.add(step.shader);
    unique(step.bindings.map((binding) => binding.binding), `program.steps[${index}].bindings`);
    for (const binding of step.bindings) {
      const buffer = buffers.get(binding.buffer);
      if (!buffer) {
        throw programError('DOE_PROGRAM_INVALID', `program.steps[${index}].bindings`, 'declared buffer', binding.buffer);
      }
      if (buffer.type === 'uniform' && buffer.role !== 'input') {
        throw programError('DOE_PROGRAM_INVALID', 'program.buffers', 'uniform input', buffer.id);
      }
      usedBuffers.add(binding.buffer);
    }
  }
  if (usedBuffers.size !== buffers.size || usedShaders.size !== shaders.size) {
    throw programError('DOE_PROGRAM_INVALID', 'program', 'no unused resources or shaders', 'unused declaration');
  }
  if (buffers.get(descriptor.output)?.role !== 'output'
      || descriptor.buffers.filter((buffer) => buffer.role === 'output').length !== 1) {
    throw programError('DOE_PROGRAM_INVALID', 'program.output', 'the sole output buffer', descriptor.output);
  }
  const snapshot = freezeTree(canonical(descriptor));
  return { descriptor: snapshot, programHash: hashBytes(JSON.stringify(snapshot)) };
}

export { validateProgramOptions, BUFFER_ALIGNMENT, PROGRAM_SCHEMA, programError, hashBytes, validateComputeProgram };

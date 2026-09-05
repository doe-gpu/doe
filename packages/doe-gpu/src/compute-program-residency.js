// Private GPU output leases and immutable input provenance for prepared programs.
import { hashBytes, programError, PROGRAM_SCHEMA } from './compute-program-contract.js';

const OUTPUTS = new WeakMap();
const DEFAULT_LIFETIME = PROGRAM_SCHEMA.$defs.buffer.properties.lifetime.default;

function lifetime(buffer) { return buffer.lifetime ?? DEFAULT_LIFETIME; }

function snapshot(value, path, size) {
  if (!ArrayBuffer.isView(value) && !(value instanceof ArrayBuffer)) {
    throw programError('DOE_PROGRAM_INPUT', path, 'ArrayBuffer, view, or live program output', typeof value);
  }
  const bytes = ArrayBuffer.isView(value)
    ? new Uint8Array(value.buffer, value.byteOffset, value.byteLength) : new Uint8Array(value);
  if (bytes.byteLength !== size) throw programError('DOE_PROGRAM_INPUT', path, `${size} bytes`, bytes.byteLength);
  if (typeof SharedArrayBuffer !== 'undefined' && bytes.buffer instanceof SharedArrayBuffer) {
    throw programError('DOE_PROGRAM_INPUT', path, 'non-shared input snapshot', 'SharedArrayBuffer');
  }
  return bytes.slice();
}

function outputReference(owner, entry, origin) {
  const reference = Object.freeze({ ...origin, size: owner.outputSize });
  OUTPUTS.set(reference, { owner, entry, generation: entry.generation });
  return reference;
}

function releaseEntry(entry) {
  entry.refs -= 1;
  if (entry.refs === 0) entry.value.destroy?.();
}

function inputBatch(owner, declarations, entries, values) {
  if (!values || typeof values !== 'object' || Array.isArray(values)
      || Object.keys(values).some((id) => !declarations.some((buffer) => buffer.id === id))) {
    throw programError('DOE_PROGRAM_INPUT', 'inputs', 'declared input identifiers', 'invalid or extra inputs');
  }
  const updates = [];
  const origins = {};
  const hashes = {};
  const leases = [];
  const release = () => { for (const { source, entry } of leases.splice(0)) {
    source.readers -= 1;
    releaseEntry(entry);
  } };
  try {
    for (const input of declarations) {
      const entry = entries.get(input.id);
      if (!Object.hasOwn(values, input.id)) {
        if (lifetime(input) !== 'program' || !entry.inputOrigin) {
          throw programError('DOE_PROGRAM_INPUT', `inputs.${input.id}`, 'initial value or initialized resident input', 'missing');
        }
        origins[input.id] = entry.inputOrigin;
        hashes[input.id] = entry.inputHash;
        continue;
      }
      const value = values[input.id];
      const gpu = value && typeof value === 'object' ? OUTPUTS.get(value) : null;
      if (gpu) {
        gpu.owner.assertReadable();
        if (gpu.owner.device !== owner.device || gpu.owner === owner
            || gpu.entry.generation !== gpu.generation || value.size !== input.size) {
          throw programError('DOE_PROGRAM_INPUT', `inputs.${input.id}`, 'current same-device output of matching size', 'stale, foreign, or mismatched output');
        }
        gpu.entry.refs += 1;
        gpu.owner.readers += 1;
        leases.push({ source: gpu.owner, entry: gpu.entry });
        const origin = Object.freeze({ kind: 'program-output', programHash: value.programHash,
          programInstance: value.programInstance, buffer: value.buffer, generation: value.generation });
        updates.push({ id: input.id, entry, source: gpu.entry.value, size: input.size, origin, hash: null });
        origins[input.id] = origin;
        hashes[input.id] = null;
      } else {
        const bytes = snapshot(value, `inputs.${input.id}`, input.size);
        const hash = hashBytes(bytes);
        const origin = Object.freeze({ kind: 'host', hash });
        updates.push({ id: input.id, entry, bytes, size: input.size, origin, hash });
        origins[input.id] = origin;
        hashes[input.id] = hash;
      }
    }
    return { updates, origins, hashes, release };
  } catch (error) { release(); throw error; }
}

export { lifetime, outputReference, releaseEntry, inputBatch };

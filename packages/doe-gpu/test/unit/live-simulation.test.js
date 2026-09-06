import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { POLICY, DEFAULT_SHADER, descriptor, parameters } from '../../examples/live-simulation/program.js';
import { initialState, advanceReference, compareState } from '../../examples/live-simulation/reference.js';
import { validateComputeProgram } from '../../src/compute-program.js';

for (const name of ['live-simulation.json', 'live-simulation.schema.json']) {
  assert.equal(readFileSync(new URL(`../../assets/${name}`, import.meta.url), 'utf8'),
    readFileSync(new URL(`../../../../config/${name}`, import.meta.url), 'utf8'));
}
assert(Object.isFrozen(POLICY.candidateInputs));
assert(Object.isFrozen(POLICY.candidateRates));
assert.throws(() => parameters(POLICY.maximumRate + 1), /rate/);
assert.throws(() => parameters(Number.NaN), /rate/);
assert.throws(() => descriptor('x'.repeat(POLICY.maximumShaderBytes + 1)), /shader/);
assert.equal(validateComputeProgram(descriptor(DEFAULT_SHADER)).descriptor.schemaVersion, 3);

const constant = Float64Array.from(initialState('zero'), () => -0.5);
assert.deepEqual(advanceReference(constant, POLICY.maximumRate), constant);
const hotspot = initialState();
const advanced = advanceReference(hotspot, POLICY.rate);
assert.equal(advanced.reduce((sum, value) => sum + value, 0), 1);

// IPC byte views need not preserve typed-array alignment.
const bytes = new Uint8Array(1 + hotspot.byteLength);
bytes.set(new Uint8Array(hotspot.buffer), 1);
assert.equal(compareState(bytes.subarray(1), hotspot), 0);
const invalid = bytes.subarray(1);
new DataView(invalid.buffer, invalid.byteOffset).setFloat32(0, Number.NaN, true);
assert.throws(() => compareState(invalid, hotspot), /reference failed/);
assert.throws(() => compareState(new Uint8Array(0), hotspot), /extent/);
console.log('ok: frozen live-simulation policy, independent stencil, and byte-view acceptance');

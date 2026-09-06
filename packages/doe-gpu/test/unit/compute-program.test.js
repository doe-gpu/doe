import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { prepareComputeProgram, validateComputeProgram } from '../../src/compute-program.js';
import { registerNativeProgramProvider } from '../../src/compute-program-native.js';
import { timestampInfo, timestampResult } from '../../src/compute-program-timing.js';
import { inputBatch, outputReference } from '../../src/compute-program-residency.js';
import { sortedJsonValue } from '../../src/json-canonical.js';
import { awaitProgramCompletion } from '../../src/compute-program-completion.js';

for (const first of ['queue', 'map']) {
  for (const failed of [null, 'queue', 'map']) {
    const queue = Promise.withResolvers();
    const map = Promise.withResolvers();
    const failure = new Error(`${failed} failed`);
    let mapRequested = false;
    let unmapped = false;
    let settled = false;
    const completion = awaitProgramCompletion({ onSubmittedWorkDone: () => queue.promise }, {
      mapAsync() { mapRequested = true; return map.promise; },
      unmap() { unmapped = true; },
    });
    completion.then(() => { settled = true; }, () => { settled = true; });
    await Promise.resolve();
    assert(mapRequested);
    const parts = { queue, map };
    parts[first][failed === first ? 'reject' : 'resolve'](failure);
    await Promise.resolve();
    await Promise.resolve();
    assert.equal(settled, false, 'completion must retain ownership until both operations settle');
    assert.equal(unmapped, false);
    const second = first === 'queue' ? 'map' : 'queue';
    parts[second][failed === second ? 'reject' : 'resolve'](failure);
    if (failed) await assert.rejects(completion, (error) => error === failure);
    else await completion;
    assert.equal(unmapped, failed === 'queue', 'only a successful map needs failure cleanup');
  }
}
const queueOnly = Promise.withResolvers();
const completion = awaitProgramCompletion({ onSubmittedWorkDone: () => queueOnly.promise });
queueOnly.resolve();
await completion;
const syncMapFailure = new Error('mapping rejected synchronously');
await assert.rejects(awaitProgramCompletion({ onSubmittedWorkDone: () => Promise.resolve() }, {
  mapAsync() { throw syncMapFailure; },
  unmap() { assert.fail('failed mapping must not be unmapped'); },
}), (error) => error === syncMapFailure);
console.log('ok: concurrent completion retains ownership through either callback order and failures');

const hashInput = JSON.parse('{"z":[{"é":null,"a":2}],"2":2,"10":10,"__proto__":{"b":1,"a":0},"a":true}');
const originalHashInput = JSON.stringify(hashInput);
assert.equal(JSON.stringify(sortedJsonValue(hashInput)),
  '{"2":2,"10":10,"__proto__":{"a":0,"b":1},"a":true,"z":[{"a":2,"é":null}]}');
assert.equal(JSON.stringify(hashInput), originalHashInput);

const descriptor = {
  schemaVersion: 1, id: 'copy',
  buffers: [{ id: 'result', size: 4, type: 'storage', role: 'output' }],
  shaders: [{ id: 'copy', entryPoint: 'main', code: 'source' }],
  steps: [{ shader: 'copy', bindings: [{ binding: 0, buffer: 'result' }], workgroups: [1, 1, 1] }],
  output: 'result',
};
const validated = validateComputeProgram(descriptor);
assert.equal(validated.programHash, '320b12ba1aedf2dd30575d5fed05ed2b69d79dc0ef156d9d26f493a11b675f78');
assert(Object.isFrozen(validated.descriptor.steps[0].bindings[0]));
assert.equal(validated.programHash, validateComputeProgram({ ...descriptor }).programHash);
for (const change of [
  (d) => { d.steps[0].workgroups[0] = 2; },
  (d) => { d.shaders[0].code = 'changed'; },
  (d) => { d.buffers[0].size = 8; },
]) {
  const changed = structuredClone(descriptor);
  change(changed);
  assert.notEqual(validated.programHash, validateComputeProgram(changed).programHash);
}
for (const change of [
  (d) => { d.schemaVersion = 3; },
  (d) => { d.extra = true; },
  (d) => { d.steps[0].workgroups[0] = 0; },
  (d) => { d.steps[0].workgroups.push(1); },
  (d) => { d.buffers[0].size = 5; },
  (d) => { d.steps[0].bindings[0].buffer = 'absent'; },
  (d) => { d.steps[0].bindings.push(d.steps[0].bindings[0]); },
  (d) => { d.buffers.push(d.buffers[0]); },
  (d) => { d.shaders.push({ id: 'unused', entryPoint: 'main', code: 'unused' }); },
]) {
  const changed = structuredClone(descriptor);
  change(changed);
  assert.throws(() => validateComputeProgram(changed), { code: 'DOE_PROGRAM_INVALID' });
}
const canonical = readFileSync(new URL('../../../../config/compute-program.schema.json', import.meta.url), 'utf8');
const shipped = readFileSync(new URL('../../assets/compute-program.schema.json', import.meta.url), 'utf8');
assert.equal(canonical, shipped);
const incompatibleDevice = {};
registerNativeProgramProvider(incompatibleDevice, { contractVersion: 0 });
for (const execution of ['native-recorded', 'webgpu']) {
  await assert.rejects(prepareComputeProgram(incompatibleDevice, descriptor, { execution }), {
    code: 'DOE_PROGRAM_UNSUPPORTED', path: 'device.runtimeContract',
  });
}
console.log('ok: compute program identity, invalidation keys, strict schema, shipped schema parity');

const tickBytes = new BigUint64Array([(1n << 48n) - 4n, 12n]);
assert.equal(timestampResult(tickBytes.buffer, 0, { periodNs: 2.5, validBits: 48 }).elapsedNs, 40);
const largeEpoch = new BigUint64Array([(1n << 60n), (1n << 60n) + 7n]);
assert.equal(timestampResult(largeEpoch.buffer, 0, { periodNs: 0.5, validBits: 64 }).elapsedNs, 3.5);
assert.throws(() => timestampResult(new BigUint64Array([0n, 1n << 54n]).buffer, 0,
  { periodNs: 1, validBits: 64 }), { code: 'DOE_PROGRAM_GPU' });
assert.equal(timestampInfo({}, {}, 'off'), null);
assert.deepEqual(timestampInfo({ features: new Set(['timestamp-query']) }, {
  timestampInfo: () => ({ periodNs: 1, validBits: 64, source: 'webgpu-nanoseconds' }),
}, 'timestamp-query'), { periodNs: 1, validBits: 64, source: 'webgpu-nanoseconds' });
assert.throws(() => timestampInfo({ features: new Set(['timestamp-query']) }, {}, 'timestamp-query'),
  { code: 'DOE_PROGRAM_UNSUPPORTED' });
console.log('ok: timestamp calibration preserves large epochs, fractional periods, wraparound and explicit support');

const residentDescriptor = structuredClone(descriptor);
residentDescriptor.buffers[0].lifetime = 'program';
assert.throws(() => validateComputeProgram(residentDescriptor), { code: 'DOE_PROGRAM_INVALID' });
residentDescriptor.schemaVersion = 2;
assert.equal(validateComputeProgram(residentDescriptor).descriptor.buffers[0].lifetime, 'program');

const deviceIdentity = {};
const source = { device: deviceIdentity, readers: 0, outputSize: 4, assertReadable() {} };
const target = { device: deviceIdentity };
const retained = { refs: 1, generation: 1, value: { destroy() { throw new Error('premature release'); } } };
const reference = outputReference(source, retained, {
  programHash: validated.programHash, programInstance: 'test-instance', buffer: 'result', generation: 1,
});
const inputDeclarations = [{ id: 'a', size: 4, lifetime: 'program' }, { id: 'b', size: 4 }];
const entries = new Map([['a', {}], ['b', {}]]);
assert.throws(() => inputBatch(target, inputDeclarations, entries,
  { a: reference, b: new Uint32Array(2) }), { code: 'DOE_PROGRAM_INPUT' });
assert.equal(source.readers, 0);
assert.equal(retained.refs, 1);
const batch = inputBatch(target, inputDeclarations, entries, { a: reference, b: new Uint32Array([7]) });
assert.equal(source.readers, 1);
assert.equal(retained.refs, 2);
batch.release();
batch.release();
assert.equal(retained.refs, 1);
assert.equal(source.readers, 0);
assert.throws(() => inputBatch({ device: {} }, inputDeclarations, entries,
  { a: reference, b: new Uint32Array([7]) }), { code: 'DOE_PROGRAM_INPUT' });
retained.generation += 1;
assert.throws(() => inputBatch(target, inputDeclarations, entries,
  { a: reference, b: new Uint32Array([7]) }), { code: 'DOE_PROGRAM_INPUT' });
console.log('ok: resident schema migration, partial-input lease rollback, foreign device and stale generation');

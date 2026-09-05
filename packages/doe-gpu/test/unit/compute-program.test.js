import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { prepareComputeProgram, validateComputeProgram } from '../../src/compute-program.js';
import { registerNativeProgramProvider } from '../../src/compute-program-native.js';

const descriptor = {
  schemaVersion: 1, id: 'copy',
  buffers: [{ id: 'result', size: 4, type: 'storage', role: 'output' }],
  shaders: [{ id: 'copy', entryPoint: 'main', code: 'source' }],
  steps: [{ shader: 'copy', bindings: [{ binding: 0, buffer: 'result' }], workgroups: [1, 1, 1] }],
  output: 'result',
};
const validated = validateComputeProgram(descriptor);
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
  (d) => { d.schemaVersion = 2; },
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

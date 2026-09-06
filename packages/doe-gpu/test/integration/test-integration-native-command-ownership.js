// Exercise consumed native-direct commands while JavaScript wrappers stay reachable.
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { createNativeDirect, globals } from '../../src/native.js';

function drmClients() {
  if (process.platform !== 'linux') return [];
  const clients = new Set();
  for (const fd of readdirSync('/proc/self/fdinfo')) {
    let text;
    try { text = readFileSync(`/proc/self/fdinfo/${fd}`, 'utf8'); }
    catch (error) { if (error.code === 'ENOENT') continue; throw error; }
    const id = text.match(/^drm-client-id:\s*(\d+)/m)?.[1];
    if (id) clients.add(`${text.match(/^drm-pdev:\s*(.+)$/m)?.[1]}:${id}`);
  }
  return [...clients].sort();
}

const before = drmClients();
const gpu = createNativeDirect();
const adapter = await gpu.requestAdapter();
const device = await adapter.requestDevice();
const usage = globals.GPUBufferUsage;
const input = new Uint32Array([17, 29, 43, 71]);
const source = device.createBuffer({
  size: input.byteLength, usage: usage.MAP_WRITE | usage.COPY_SRC, mappedAtCreation: true,
});
const output = device.createBuffer({ size: input.byteLength, usage: usage.MAP_READ | usage.COPY_DST });
const commands = [];
try {
  const creationRange = source.getMappedRange();
  new Uint32Array(creationRange).set(input);
  source.unmap();
  assert.equal(creationRange.byteLength, 0);
  for (let index = 0; index < 3; index += 1) {
    const encoder = device.createCommandEncoder();
    encoder.copyBufferToBuffer(source, 0, output, 0, input.byteLength);
    commands.push(encoder.finish());
    assert.throws(() => encoder.finish(), /Invalid encoder/);
  }
  assert.throws(() => device.queue.submit([commands[0], commands[0]]), /same command buffer twice/);
  device.queue.submit([commands[0]]);
  assert.throws(() => device.queue.submit([commands[0]]), /unsubmitted command buffer/);
  assert.throws(() => device.queue.submit([commands[1], commands[0]]), /unsubmitted command buffer/);
  device.queue.submit(commands.slice(1));
  await device.queue.onSubmittedWorkDone();
  await output.mapAsync(globals.GPUMapMode.READ);
  const readRange = output.getMappedRange();
  assert.deepEqual(new Uint32Array(readRange).slice(), input);
  new Uint32Array(readRange).fill(0);
  output.unmap();
  assert.equal(readRange.byteLength, 0);
  await output.mapAsync(globals.GPUMapMode.READ);
  assert.deepEqual(new Uint32Array(output.getMappedRange()).slice(), input,
    'read mapping changes must not write back to the GPU buffer');
  output.unmap();
  await source.mapAsync(globals.GPUMapMode.WRITE);
  const writeRange = source.getMappedRange();
  const updated = Uint32Array.from(input, value => value + 1);
  new Uint32Array(writeRange).set(updated);
  source.unmap();
  assert.equal(writeRange.byteLength, 0);
  const encoder = device.createCommandEncoder();
  encoder.copyBufferToBuffer(source, 0, output, 0, input.byteLength);
  device.queue.submit([encoder.finish()]);
  await output.mapAsync(globals.GPUMapMode.READ);
  assert.deepEqual(new Uint32Array(output.getMappedRange()).slice(), updated);
  output.unmap();
} finally {
  source.destroy();
  output.destroy();
  device.destroy();
  adapter.destroy();
}
assert.deepEqual(drmClients(), before, 'consumed commands must not retain a device client');
assert.equal(commands.length, 3);
console.log('ok: consumed commands, rejected resubmission, mapping write-back and detachment, device cleanup');

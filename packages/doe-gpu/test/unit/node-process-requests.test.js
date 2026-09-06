import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { fork } from 'node:child_process';
import { once } from 'node:events';
import { createRequestProcess } from '../../src/node-process-requests.js';

const root = mkdtempSync(join(tmpdir(), 'doe-request-process-'));
const entrypoint = join(root, 'worker.mjs');
const moduleUrl = new URL('../../src/node-process-requests.js', import.meta.url).href;
writeFileSync(entrypoint, `import { serveRequests } from ${JSON.stringify(moduleUrl)};
serveRequests(async (type, input) => {
  if (type === 'hang') return new Promise(() => {});
  if (type === 'output') { process.stdout.write('x'.repeat(8192)); return new Promise(() => {}); }
  if (type === 'error') throw Object.assign(new Error('distinct cause'), { code: 'TEST_CAUSE' });
  return { type, input, pid: process.pid };
});\n`);
const policy = { entrypoint: pathToFileURL(entrypoint), requestTimeoutMs: 1000,
  maximumHeapMiB: 32, maximumProcessOutputBytes: 4096 };
const created = [];
function worker(options = {}) {
  const value = createRequestProcess({ ...policy, ...options });
  created.push(value);
  return value;
}
try {
  for (const field of ['requestTimeoutMs', 'maximumHeapMiB', 'maximumProcessOutputBytes']) {
    assert.throws(() => worker({ [field]: 0 }), /positive safe integer/);
  }
  const valid = worker();
  const replies = await Promise.all([valid.call('first', { value: 1 }), valid.call('second', { value: 2 })]);
  assert.equal(replies[0].input.value, 1);
  assert.equal(replies[1].input.value, 2);
  await assert.rejects(valid.call('error'), (error) => error.code === 'TEST_CAUSE' && error.message === 'distinct cause');
  assert.equal((await valid.call('valid')).type, 'valid');
  await valid.close();
  await assert.rejects(valid.call('late'), /closed/);
  await valid.close();
  await assert.rejects(worker().call('hang'), /deadline/);
  await assert.rejects(worker().call('output'), /output limit/);
  const cancelled = worker();
  const pending = cancelled.call('hang');
  cancelled.abort(new Error('obsolete edit'));
  await assert.rejects(pending, /obsolete edit/);
  const orphan = fork(entrypoint, [], { stdio: ['ignore', 'ignore', 'ignore', 'ipc'] });
  const replied = once(orphan, 'message');
  orphan.send({ id: 1, type: 'ready', input: {} });
  await replied;
  const exited = once(orphan, 'exit');
  orphan.disconnect();
  assert.equal((await exited)[0], 1);
  console.log('ok: bounded request processes preserve errors, cancel work, and exit after parent disconnect');
} finally {
  for (const value of created) value.abort();
  rmSync(root, { recursive: true, force: true });
}

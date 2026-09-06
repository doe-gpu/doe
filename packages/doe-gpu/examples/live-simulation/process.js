// Request deadlines protect the controller even when a driver stops responding.
import { fork } from 'node:child_process';
import { terminateProcess } from '../../src/node-process-termination.js';
import { POLICY } from './program.js';

function createWorker() {
  const terminationScope = process.platform === 'win32' ? 'child-process' : 'process-group';
  const child = fork(new URL('./worker.js', import.meta.url), [], {
    execArgv: [`--max-old-space-size=${POLICY.maximumHeapMiB}`],
    detached: terminationScope === 'process-group', serialization: 'advanced',
    stdio: ['ignore', 'pipe', 'pipe', 'ipc'],
  });
  const requests = new Map();
  let nextId = 0;
  let stopped = false;
  let bytes = 0;
  let diagnostics = '';
  function rejectPending(error) {
    for (const { reject, timer } of requests.values()) { clearTimeout(timer); reject(error); }
    requests.clear();
  }
  function abort(error = new Error('worker cancelled')) {
    if (stopped) return;
    stopped = true;
    terminateProcess(child, terminationScope);
    rejectPending(error);
  }
  for (const stream of [child.stdout, child.stderr]) stream.on('data', (chunk) => {
    bytes += chunk.length;
    if (bytes > POLICY.maximumProcessOutputBytes) abort(new Error('worker output limit exceeded'));
    else diagnostics += chunk.toString();
  });
  child.on('error', abort);
  child.on('exit', (code, signal) => {
    stopped = true;
    rejectPending(new Error(`worker exited (${code ?? signal}): ${diagnostics}`));
  });
  child.on('message', (message) => {
    const request = requests.get(message.id);
    if (!request) return;
    clearTimeout(request.timer);
    requests.delete(message.id);
    if (message.error) request.reject(Object.assign(new Error(message.error.message), { code: message.error.code }));
    else request.resolve(message.result);
  });
  function call(type, input = {}) {
    if (stopped) return Promise.reject(new Error('worker is closed'));
    const id = ++nextId;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => abort(new Error(`worker ${type} exceeded ${POLICY.requestTimeoutMs}ms deadline`)), POLICY.requestTimeoutMs);
      requests.set(id, { resolve, reject, timer });
      child.send({ id, type, input }, (error) => { if (error) abort(error); });
    });
  }
  return {
    call, abort, terminationScope,
    async close() {
      if (stopped) return;
      try { await call('close'); } finally { abort(); }
    },
  };
}

export { createWorker };

// The live application supplies its policy to the shared bounded request process.
import { createRequestProcess } from '../../src/node-process-requests.js';
import { POLICY } from './program.js';

function createWorker() {
  return createRequestProcess({ entrypoint: new URL('./worker.js', import.meta.url),
    requestTimeoutMs: POLICY.requestTimeoutMs, maximumHeapMiB: POLICY.maximumHeapMiB,
    maximumProcessOutputBytes: POLICY.maximumProcessOutputBytes });
}

export { createWorker };

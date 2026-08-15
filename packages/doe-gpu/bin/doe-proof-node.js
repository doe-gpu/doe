#!/usr/bin/env node

import { runDoeProofProcessCli } from '../src/node-webgpu-process-cli.js';

const controller = new AbortController();
const abort = () => controller.abort();
process.once('SIGINT', abort);
process.once('SIGTERM', abort);
try {
  process.exitCode = await runDoeProofProcessCli(process.argv.slice(2), {
    signal: controller.signal,
  });
} finally {
  process.removeListener('SIGINT', abort);
  process.removeListener('SIGTERM', abort);
}

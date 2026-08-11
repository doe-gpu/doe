#!/usr/bin/env -S deno run --unstable-webgpu --allow-all

import { fileURLToPath } from 'node:url';

import { runPackageWebGpuPlanCli } from './package-webgpu/runner-core.js';

const CLI_PATH = fileURLToPath(import.meta.url);
const CHILD_ENV = 'DOE_DENO_WEBGPU_CHILD';

process.env[CHILD_ENV] = '1';

runPackageWebGpuPlanCli({
  runtimeHost: 'deno',
  defaultProvider: 'deno-webgpu',
  cliPath: CLI_PATH,
  childEnv: CHILD_ENV,
  label: 'deno-webgpu',
  providerUsage: 'doe|deno-webgpu',
  usageCommand: 'deno run --unstable-webgpu --allow-all bench/executors/run-deno-webgpu-plan.js',
}).catch((error) => {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
  process.exit(1);
});

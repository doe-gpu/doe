#!/usr/bin/env node

import { existsSync, mkdirSync, readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { checkNativeAbiLayouts } from './native-abi-layout.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PACKAGE_ROOT = resolve(__dirname, '..');
const WORKSPACE_ROOT = resolve(PACKAGE_ROOT, '..', '..');
const BRIDGE_ROOT = resolve(WORKSPACE_ROOT, 'runtime', 'bridge', 'webgpu-addon');
const OUTPUT_DIR = resolve(PACKAGE_ROOT, 'build', 'Release');
const OUTPUT_PATH = resolve(OUTPUT_DIR, 'doe_napi.node');
const NAPI_VERSION = '8';

const addonTarget = JSON.parse(readFileSync(resolve(PACKAGE_ROOT, 'binding.gyp'), 'utf8'))
  .targets.find((target) => target.target_name === 'doe_napi');
const sourceFiles = addonTarget.sources.map((name) => resolve(PACKAGE_ROOT, name));

function resolveNodeIncludeDir() {
  const candidates = [
    process.env.NODE_INCLUDE_DIR,
    process.env.npm_config_nodedir ? resolve(process.env.npm_config_nodedir, 'include', 'node') : null,
    process.config.variables.nodedir ? resolve(process.config.variables.nodedir, 'include', 'node') : null,
    resolve(dirname(dirname(process.execPath)), 'include', 'node'),
  ];
  for (const candidate of candidates) {
    if (candidate && existsSync(resolve(candidate, 'node_api.h'))) {
      return candidate;
    }
  }
  throw new Error(
    'Unable to locate Node headers. Set NODE_INCLUDE_DIR or npm_config_nodedir, or use a Node install with include/node.',
  );
}

function compilerCommand(includeDir) {
  const compiler = process.env.CC || 'cc';
  const baseArgs = [
    `-DNAPI_VERSION=${NAPI_VERSION}`,
    `-I${includeDir}`,
    '-std=c11',
  ];
  switch (process.platform) {
    case 'darwin':
      return {
        compiler,
        args: [
          '-bundle',
          '-undefined',
          'dynamic_lookup',
          ...baseArgs,
          ...sourceFiles,
          '-o',
          OUTPUT_PATH,
        ],
      };
    case 'linux':
      return {
        compiler,
        args: [
          '-shared',
          '-fPIC',
          ...baseArgs,
          ...sourceFiles,
          '-o',
          OUTPUT_PATH,
        ],
      };
    default:
      throw new Error(
        `build:addon is not implemented for ${process.platform}; use node-gyp rebuild with packages/doe-gpu/binding.gyp if available.`,
      );
  }
}

function main() {
  const includeDir = resolveNodeIncludeDir();
  const { compiler, args } = compilerCommand(includeDir);
  checkNativeAbiLayouts({
    compiler, includeDir,
    bridgeHeader: resolve(BRIDGE_ROOT, 'doe_napi_internal.h'),
    upstreamHeader: resolve(WORKSPACE_ROOT, 'runtime/zig/vendor/webgpu-headers/webgpu.h'),
  });
  mkdirSync(OUTPUT_DIR, { recursive: true });
  execFileSync(compiler, args, {
    cwd: PACKAGE_ROOT,
    stdio: 'inherit',
  });
  console.log(`doe-gpu: built native addon at ${OUTPUT_PATH}`);
}

main();

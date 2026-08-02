#!/usr/bin/env node

import fs from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

import {
  loadClosedProgramBundle,
  runProgramBundle,
} from '../../packages/doe-gpu/src/program-bundle-runner.js';

function usage() {
  return [
    'Usage:',
    '  node bench/tools/run_doe_webgpu_program_bundle_inference.mjs \\',
    '    --program-bundle <bundle.json> \\',
    '    --mode <validate|compile|execute> \\',
    '    [--provider-config <provider-v1.json>] \\',
    '    [--host-bridge-module <bridge.mjs>] \\',
    '    [--execution-input <input.json>] \\',
    '    [--out-json <receipt.json>]',
    '',
    'validate verifies the canonical schema and every packaged source byte.',
    'compile also requires --provider-config and compiles every exact WGSL entrypoint.',
    'execute additionally requires --host-bridge-module and compares the transcript.',
  ].join('\n');
}

function takeValue(argv, index, flag) {
  const value = argv[index + 1];
  if (!value || value.startsWith('--')) throw new Error(`${flag} requires a value.`);
  return value;
}

function parseArgs(argv) {
  const options = {
    programBundlePath: null,
    mode: null,
    providerConfigPath: null,
    hostBridgeModulePath: null,
    executionInputPath: null,
    outputPath: null,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    if (flag === '--help') return { help: true };
    if (flag === '--program-bundle') {
      options.programBundlePath = takeValue(argv, index, flag);
      index += 1;
    } else if (flag === '--mode') {
      options.mode = takeValue(argv, index, flag);
      index += 1;
    } else if (flag === '--provider-config') {
      options.providerConfigPath = takeValue(argv, index, flag);
      index += 1;
    } else if (flag === '--host-bridge-module') {
      options.hostBridgeModulePath = takeValue(argv, index, flag);
      index += 1;
    } else if (flag === '--execution-input') {
      options.executionInputPath = takeValue(argv, index, flag);
      index += 1;
    } else if (flag === '--out-json') {
      options.outputPath = takeValue(argv, index, flag);
      index += 1;
    } else {
      throw new Error(`unknown argument: ${flag}`);
    }
  }
  if (!options.programBundlePath) throw new Error('--program-bundle is required.');
  if (!['validate', 'compile', 'execute'].includes(options.mode)) {
    throw new Error('--mode must be explicitly set to validate, compile, or execute.');
  }
  if (options.mode !== 'validate' && !options.providerConfigPath) {
    throw new Error(`${options.mode} mode requires --provider-config.`);
  }
  if (options.mode === 'execute' && !options.hostBridgeModulePath) {
    throw new Error('execute mode requires --host-bridge-module.');
  }
  if (options.mode !== 'execute' && (options.hostBridgeModulePath || options.executionInputPath)) {
    throw new Error('--host-bridge-module and --execution-input are valid only in execute mode.');
  }
  return options;
}

async function readJson(filePath, label) {
  const absolutePath = path.resolve(filePath);
  try {
    return JSON.parse(await fs.readFile(absolutePath, 'utf8'));
  } catch (error) {
    throw new Error(`${label} could not be read from ${absolutePath}: ${error.message}`);
  }
}

async function readProviderOptions(filePath) {
  const config = await readJson(filePath, 'provider-v1 config');
  if (config.schema !== 'doe.webgpu-provider/v1') {
    throw new Error('provider config must declare schema "doe.webgpu-provider/v1".');
  }
  const { schema: _schema, ...providerOptions } = config;
  return providerOptions;
}

async function readHostBridge(filePath) {
  const absolutePath = path.resolve(filePath);
  const moduleNamespace = await import(pathToFileURL(absolutePath).href);
  if (typeof moduleNamespace.createTextGenerationProgram !== 'function') {
    throw new Error(
      `host bridge ${absolutePath} must export createTextGenerationProgram(bundle, options).`,
    );
  }
  return moduleNamespace;
}

async function execute(options) {
  const programBundlePath = path.resolve(options.programBundlePath);
  if (options.mode === 'validate') {
    const loaded = await loadClosedProgramBundle(programBundlePath);
    return {
      schema: 'doe.program-bundle-cli-receipt/v2',
      mode: options.mode,
      bundleId: loaded.bundle.bundleId,
      modelId: loaded.bundle.modelId,
      packagedFileCount: loaded.files.size,
      schemaValid: true,
      providerAvailable: null,
      executed: false,
      transcriptMatched: false,
    };
  }

  const providerOptions = await readProviderOptions(options.providerConfigPath);
  let execution;
  if (options.mode === 'execute') {
    execution = {
      hostBridge: await readHostBridge(options.hostBridgeModulePath),
      ...(options.executionInputPath
        ? { input: await readJson(options.executionInputPath, 'execution input') }
        : {}),
    };
  }
  const result = await runProgramBundle({
    programBundlePath,
    providerOptions,
    ...(execution ? { execution } : {}),
  });
  return {
    ...result,
    schema: 'doe.program-bundle-cli-receipt/v2',
    mode: options.mode,
  };
}

try {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    process.stdout.write(`${usage()}\n`);
  } else {
    const receipt = await execute(options);
    const serialized = `${JSON.stringify(receipt, null, 2)}\n`;
    if (options.outputPath) {
      const outputPath = path.resolve(options.outputPath);
      await fs.mkdir(path.dirname(outputPath), { recursive: true });
      await fs.writeFile(outputPath, serialized, 'utf8');
    }
    process.stdout.write(serialized);
    if (options.mode === 'execute' && !receipt.transcriptMatched) process.exitCode = 1;
  }
} catch (error) {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n${usage()}\n`);
  process.exitCode = 1;
}

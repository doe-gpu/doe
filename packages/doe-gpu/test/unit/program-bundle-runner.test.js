import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {
  loadClosedProgramBundle,
  runProgramBundle,
} from '../../src/program-bundle-runner.js';

function digest(bytes) {
  return `sha256:${createHash('sha256').update(bytes).digest('hex')}`;
}

const tmpRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'doe-program-bundle-'));
const bundlePath = path.join(tmpRoot, 'bundle.json');
const wgslPath = 'program/wgsl/kernel.wgsl';
const hostPath = 'program/host/entrypoint.mjs';
const wgsl = '@compute @workgroup_size(1) fn exact_entry() {}\n';
const host = [
  'export function createTextGenerationProgram(hostBridge, bundle, options) {',
  '  return hostBridge.createTextGenerationProgram(bundle, options);',
  '}',
  '',
].join('\n');
const wgslHash = digest(wgsl);
const hostHash = digest(host);
const hash = `sha256:${'0'.repeat(64)}`;
const graphHash = `sha256:${'1'.repeat(64)}`;
const transcript = {
  executionGraphHash: graphHash,
  tokens: { generatedTokenIdsHash: `sha256:${'2'.repeat(64)}` },
  output: {
    textHash: `sha256:${'3'.repeat(64)}`,
    tokensGenerated: 1,
    stopReason: 'max_tokens',
  },
  kvCache: { stateHash: `sha256:${'4'.repeat(64)}` },
};
const packageFiles = [
  { role: 'host-source', path: hostPath, hash: hostHash, sizeBytes: Buffer.byteLength(host) },
  { role: 'wgsl-source', path: wgslPath, hash: wgslHash, sizeBytes: Buffer.byteLength(wgsl) },
];
const fileSetHash = digest(JSON.stringify(packageFiles.map((file) => ({
  hash: file.hash,
  path: file.path,
  role: file.role,
  sizeBytes: file.sizeBytes,
}))));
const bundle = {
  schema: 'doppler.program-bundle/v1',
  schemaVersion: 1,
  bundleId: 'doe-closed-bundle-test',
  modelId: 'unit-model',
  createdAtUtc: '2026-08-02T00:00:00.000Z',
  package: {
    schema: 'doppler.program-bundle-package/v1',
    root: '.',
    files: packageFiles,
    fileSetHash,
  },
  sources: {
    manifest: { path: 'manifest.json', hash },
    conversionConfig: null,
    executionGraph: { schema: 'doppler.execution/v1', hash: graphHash, expandedStepHash: hash },
    weightSetHash: hash,
    artifactSetHash: hash,
  },
  host: {
    schema: 'doppler.host-js/v1',
    jsSubset: 'doppler-webgpu-host/v1',
    entrypoints: [{
      id: 'text-generation',
      module: hostPath,
      export: 'createTextGenerationProgram',
      role: 'model-orchestration',
      sourceHash: hostHash,
      validation: {
        dynamicImport: 'none-detected',
        staticImport: 'none-detected',
        dom: 'none-detected',
        runtimeGlobals: 'none-detected',
        network: 'none-detected',
        dynamicCode: 'none-detected',
      },
    }],
    constraints: {
      dynamicImport: 'disallowed',
      staticImport: 'disallowed',
      dom: 'disallowed-in-model-path',
      runtimeGlobals: 'disallowed',
      dynamicCode: 'disallowed',
      filesystem: 'declared-artifacts-only',
      network: 'declared-artifacts-only',
    },
  },
  wgslModules: [{
    id: 'kernel',
    file: 'kernel.wgsl',
    entry: 'exact_entry',
    digest: hash,
    sourcePath: wgslPath,
    sourceHash: wgslHash,
    reachable: true,
    metadata: {
      entry: 'exact_entry',
      sourceMetadataHash: hash,
      bindings: [],
      overrides: [],
      workgroupSize: ['1'],
      requiresSubgroups: false,
    },
  }],
  execution: {
    graphHash,
    stepMetadataHash: hash,
    kernelClosure: {},
    steps: [{}],
  },
  captureProfile: {
    schema: 'doppler.capture-profile/v1',
    deterministic: true,
    phases: ['decode'],
    surfaces: ['node-doe-gpu'],
    adapter: {},
    hashPolicy: {},
    captureHash: hash,
  },
  artifacts: packageFiles.map((file) => ({ ...file })),
  referenceTranscript: {
    schema: 'doppler.reference-transcript/v1',
    source: {},
    executionGraphHash: graphHash,
    surface: 'node-doe-gpu',
    prompt: {},
    output: transcript.output,
    tokens: transcript.tokens,
    phase: {},
    kvCache: transcript.kvCache,
    logits: {},
    tolerance: {},
  },
};

try {
  await fs.mkdir(path.dirname(path.join(tmpRoot, wgslPath)), { recursive: true });
  await fs.mkdir(path.dirname(path.join(tmpRoot, hostPath)), { recursive: true });
  await fs.writeFile(path.join(tmpRoot, wgslPath), wgsl, 'utf8');
  await fs.writeFile(path.join(tmpRoot, hostPath), host, 'utf8');
  await fs.writeFile(bundlePath, `${JSON.stringify(bundle, null, 2)}\n`, 'utf8');

  const loaded = await loadClosedProgramBundle(bundlePath);
  assert.equal(loaded.files.size, 2);

  const providerModule = new URL('../fixtures/provider-v1.js', import.meta.url).href;
  const result = await runProgramBundle({
    programBundlePath: bundlePath,
    providerOptions: {
      providers: [{
        id: 'test-provider',
        kind: 'module',
        module: providerModule,
        gpu: { kind: 'factory', path: 'createFakeGPU', args: ['closed-bundle'] },
        globals: {
          GPUBufferUsage: 'globals.GPUBufferUsage',
          GPUShaderStage: 'globals.GPUShaderStage',
          GPUMapMode: 'globals.GPUMapMode',
          GPUTextureUsage: 'globals.GPUTextureUsage',
        },
      }],
      adapterOptions: null,
      globals: { mode: 'none' },
    },
    execution: {
      hostBridge: {
        createTextGenerationProgram() {
          return {
            async execute() {
              return { referenceTranscript: transcript };
            },
          };
        },
      },
    },
  });
  assert.equal(result.schemaValid, true);
  assert.equal(result.providerAvailable, true);
  assert.equal(result.executed, true);
  assert.equal(result.transcriptMatched, true);
  assert.deepEqual(result.compiledModules, [{ id: 'kernel', compiled: true, entryPoint: 'exact_entry' }]);

  await fs.writeFile(path.join(tmpRoot, wgslPath), `${wgsl}// tampered\n`, 'utf8');
  await assert.rejects(
    () => loadClosedProgramBundle(bundlePath),
    /hash\/size mismatch/,
  );
} finally {
  await fs.rm(tmpRoot, { recursive: true, force: true });
}

console.log('program-bundle runner contracts: ok');

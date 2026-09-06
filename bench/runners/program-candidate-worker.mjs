// GPU and trusted reference execution each have a separately bounded process.
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve, relative, isAbsolute } from 'node:path';
import { pathToFileURL } from 'node:url';
import { release, platform, arch, endianness } from 'node:os';
import { serveRequests } from '../../packages/doe-gpu/src/node-process-requests.js';

const hash = (data) => createHash('sha256').update(data).digest('hex');
let adapter;
let device;
let program;
let reference;
let mode;
let root;
let native;
let preparation;

async function command(type, input) {
  switch (type) {
    case 'initialize': {
      if (mode) throw new Error('Worker already initialized');
      if (endianness() !== 'LE') throw new Error('Candidate jobs require a little-endian host');
      mode = input.mode;
      root = resolve(input.packageRoot);
      const start = performance.now();
      if (mode === 'reference') {
        reference = (await import(pathToFileURL(input.referencePath).href)).compute;
        if (typeof reference !== 'function') throw new Error('Reference must export compute(inputs)');
        preparation = { initializationMs: performance.now() - start, preparationMs: 0 };
      } else if (mode === 'candidate') {
        process.env.DOE_PROGRAM_IDENTITY_TRACE_PATH = input.tracePath;
        native = await import(pathToFileURL(resolve(root, 'src/native.js')).href);
        const { prepareComputeProgram } = await import(pathToFileURL(resolve(root, 'src/compute-program.js')).href);
        adapter = await native.requestAdapter({ backend: input.backend });
        device = await adapter.requestDevice();
        const initializationMs = performance.now() - start;
        program = await prepareComputeProgram(device, input.descriptor, { execution: input.execution });
        preparation = { initializationMs, preparationMs: program.preparationMs };
      } else throw new Error(`Unsupported worker mode: ${mode}`);
      return preparation;
    }
    case 'run': {
      const cpu = process.cpuUsage();
      const start = performance.now();
      const inputs = Object.fromEntries(Object.entries(input.inputs)
        .map(([key, value]) => [key, new Uint8Array(value)]));
      let data;
      let receipt = null;
      if (mode === 'reference') {
        const output = await reference(inputs);
        if (!(output instanceof Float32Array) && !(output instanceof Float64Array)) {
          throw new Error('Reference compute must return a Float32Array or Float64Array');
        }
        data = new Uint8Array(Float32Array.from(output).buffer);
      } else {
        const result = await program.run(inputs);
        data = result.output;
        receipt = result.receipt;
      }
      const elapsedMs = performance.now() - start;
      const usage = process.cpuUsage(cpu);
      return { data, receipt, elapsedMs, cpuMs: (usage.user + usage.system) / 1000,
        processRssBytes: process.memoryUsage().rss };
    }
    case 'environment': {
      const reportedObjects = process.report.getReport().sharedObjects;
      const kernelObjects = reportedObjects.filter((path) => path === 'linux-vdso.so.1' || path === 'linux-gate.so.1');
      const loadedObjects = reportedObjects.filter((path) => !kernelObjects.includes(path))
        .map((path) => ({ path, hash: hash(readFileSync(path)) }))
        .sort((a, b) => a.path.localeCompare(b.path));
      const info = device?._adapterInfo ?? device?.adapterInfo ?? adapter?.info;
      const identity = info ? Object.fromEntries(['vendor', 'architecture', 'device', 'description',
        'isFallbackAdapter', 'vendorID', 'deviceID', 'driverVersion']
        .map((key) => [key, info[key] ?? null])) : null;
      if (mode === 'candidate') {
        const providerPath = native.providerInfo().doeLibraryPath;
        const provider = loadedObjects.find((entry) => entry.path === providerPath);
        const addon = loadedObjects.find((entry) => entry.path.endsWith('/doe_napi.node'));
        for (const entry of [provider, addon]) {
          if (!entry) throw new Error('Loaded package native identity unavailable');
          const path = relative(resolve(root, '..'), entry.path);
          if (path.startsWith('..') || isAbsolute(path)) throw new Error('Native object escaped retained installation');
        }
        if (identity?.isFallbackAdapter !== false || /llvmpipe|swiftshader|software/i.test(JSON.stringify(identity))) {
          throw new Error('Physical adapter identity with explicit false fallback state is required');
        }
      }
      return { os: { platform: platform(), arch: arch(), release: release() },
        node: { version: process.version, hash: hash(readFileSync(process.execPath)) }, adapter: identity,
        loadedObjects, kernelObjects };
    }
    case 'close': {
      const start = performance.now();
      await program?.close();
      device?.destroy();
      adapter?.destroy();
      return { teardownMs: performance.now() - start };
    }
    default: throw new Error(`Unknown candidate worker operation: ${type}`);
  }
}

serveRequests(command);

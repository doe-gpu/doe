#!/usr/bin/env node

import { readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { mkdir } from 'node:fs/promises';

import { evaluateQualification } from '../external-projects/doppler/oracle.mjs';

function parseArgs(argv) {
  const values = { contract: '', w0: '', d0: '', out: '' };
  for (let index = 2; index < argv.length; index += 2) {
    const key = {
      '--contract': 'contract',
      '--w0': 'w0',
      '--d0': 'd0',
      '--out': 'out',
    }[argv[index]];
    if (!key || !argv[index + 1]) {
      throw new Error(`unsupported or incomplete argument: ${argv[index] ?? '<missing>'}`);
    }
    values[key] = argv[index + 1];
  }
  for (const [key, value] of Object.entries(values)) {
    if (!value) throw new Error(`${key} is required`);
  }
  return values;
}

async function loadJson(path) {
  return JSON.parse(await readFile(path, 'utf8'));
}

async function main() {
  const args = parseArgs(process.argv);
  const harness = await loadJson(resolve(args.contract));
  const contract = harness?.workload?.modelContract;
  if (!contract) throw new Error('harness workload.modelContract is missing');
  const laneRoots = { W0: resolve(args.w0), D0: resolve(args.d0) };
  const receipts = {
    W0: await loadJson(resolve(laneRoots.W0, 'doppler_int4ple_reference_export.json')),
    D0: await loadJson(resolve(laneRoots.D0, 'doppler_int4ple_reference_export.json')),
  };
  const result = await evaluateQualification({ contract, laneRoots, receipts });
  const out = resolve(args.out);
  await mkdir(dirname(out), { recursive: true });
  await writeFile(out, `${JSON.stringify(result, null, 2)}\n`, 'utf8');
  process.stdout.write(`${JSON.stringify({ out, status: result.status, pass: result.pass }, null, 2)}\n`);
  return result.pass ? 0 : 1;
}

main()
  .then((code) => { process.exitCode = code; })
  .catch((error) => {
    process.stderr.write(`${error?.stack ?? error}\n`);
    process.exitCode = 2;
  });

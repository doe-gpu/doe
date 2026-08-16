import { readFile } from 'node:fs/promises';
import { register } from 'node:module';

const inputPath = process.env.DOE_CPP_ML_INPUT_PATH;
if (!inputPath) throw new Error('DOE_CPP_ML_INPUT_PATH is required.');
const input = JSON.parse(await readFile(inputPath, 'utf8'));
if (input.schemaVersion !== 1
    || input.upstreamCommit !== 'c46a47b4fcee5ec48dbda7321210b1287b262b06'
    || JSON.stringify(input.expectedDigits) !== JSON.stringify([0, 1, 2, 3, 4, 5, 6, 7, 8, 9])) {
  throw new Error('DoeProof cpp-ml input contract mismatch.');
}

register('./doeproof-pngjs-loader.mjs', import.meta.url);
await import('./mnist-oracle.mjs');

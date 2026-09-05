#!/usr/bin/env node
// Run an image or scientific program from ordinary portable files.
import { readFileSync, writeFileSync } from 'node:fs';
import { requestDevice } from '../src/native.js';
import { prepareComputeProgram } from '../src/compute-program.js';
import { imageEdgesProgram, heatDiffusionProgram } from './compute-programs.js';

const [application, inputPath, outputPath, backend, iterationsText] = process.argv.slice(2);
if (!['image', 'heat'].includes(application) || !inputPath || !outputPath
    || !['vulkan', 'metal'].includes(backend)) {
  throw new Error('Usage: node examples/compute-program.js image|heat input.pgm output.pgm vulkan|metal [heat-iterations]');
}
const words = readFileSync(inputPath, 'utf8').replace(/#[^\r\n]*/g, '').trim().split(/\s+/);
if (words[0] !== 'P2') throw new Error('Expected an ASCII PGM (P2) grayscale image');
const [width, height, maximum] = words.slice(1, 4).map(Number);
if (!Number.isInteger(maximum) || maximum < 1 || maximum > 65535) throw new Error('Invalid PGM maximum');
const pixels = words.slice(4).map(Number);
if (pixels.length !== width * height || pixels.some((value) => !Number.isInteger(value) || value < 0 || value > maximum)) {
  throw new Error('PGM pixels must match dimensions and declared range');
}
const descriptor = application === 'image' ? imageEdgesProgram(width, height)
  : heatDiffusionProgram(width, height, Number(iterationsText));
const input = Float32Array.from(pixels, (pixel) => pixel / maximum);
const device = await requestDevice({ backend });
let program;
try {
  program = await prepareComputeProgram(device, descriptor, { execution: 'native-recorded' });
  const result = await program.run({ input });
  const values = new Float32Array(result.output.buffer);
  const output = [...values].map((value) => Math.round(Math.max(0, Math.min(1, value)) * maximum));
  writeFileSync(outputPath, `P2\n${width} ${height}\n${maximum}\n${output.join(' ')}\n`);
  console.log(`Wrote ${outputPath}`);
} finally {
  await program?.close();
  device.destroy();
}

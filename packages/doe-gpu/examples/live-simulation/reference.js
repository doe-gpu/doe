// Independent double-precision stencil; candidate WGSL never supplies acceptance.
import { POLICY } from './program.js';

function initialState(kind = 'hotspot') {
  const { width, height } = POLICY;
  return Float32Array.from({ length: width * height }, (_, index) => {
    const x = index % width;
    const y = Math.floor(index / width);
    switch (kind) {
      case 'zero': return 0;
      case 'hotspot': return x === Math.floor(width / 2) && y === Math.floor(height / 2) ? 1 : 0;
      case 'ramp': return (x - y) / Math.max(width, height);
      case 'checkerboard': return (x + y) % 2 === 0 ? -1 : 1;
      default: throw new Error(`unknown independent input ${kind}`);
    }
  });
}

function advanceReference(previous, rate) {
  const { width, height } = POLICY;
  const next = new Float64Array(previous.length);
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const index = y * width + x;
      const center = previous[index];
      let change = 0;
      for (const [xx, yy] of [[x - 1, y], [x + 1, y], [x, y - 1], [x, y + 1]]) {
        const row = Math.max(0, Math.min(height - 1, yy));
        const column = Math.max(0, Math.min(width - 1, xx));
        change += previous[row * width + column] - center;
      }
      next[index] = center + Math.fround(rate) * change;
    }
  }
  return next;
}

function compareState(output, expected) {
  if (output.byteLength !== expected.length * Float32Array.BYTES_PER_ELEMENT) throw new Error('output extent differs from frozen reference');
  const view = new DataView(output.buffer, output.byteOffset, output.byteLength);
  let maximumError = 0;
  for (let index = 0; index < expected.length; index += 1) {
    const observed = view.getFloat32(index * Float32Array.BYTES_PER_ELEMENT, true);
    const error = Math.abs(observed - expected[index]);
    const tolerance = POLICY.absoluteTolerance + POLICY.relativeTolerance * Math.abs(expected[index]);
    if (!Number.isFinite(observed) || error > tolerance) {
      throw new Error(`independent heat reference failed at ${index}: expected ${expected[index]}, received ${observed}`);
    }
    maximumError = Math.max(maximumError, error);
  }
  return maximumError;
}

export { initialState, advanceReference, compareState };

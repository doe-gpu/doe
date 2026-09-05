// Independent host calculations use double arithmetic and explicit image loops.
function imageEdgesOracle(input, width, height) {
  const sample = (image, x, y) => image[
    Math.max(0, Math.min(height - 1, y)) * width + Math.max(0, Math.min(width - 1, x))
  ];
  const horizontal = new Float64Array(input.length);
  const vertical = new Float64Array(input.length);
  const output = new Float64Array(input.length);
  const weights = [0.25, 0.5, 0.25];
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      for (let tap = 0; tap < weights.length; tap += 1) {
        horizontal[y * width + x] += weights[tap] * sample(input, x + tap - 1, y);
      }
    }
  }
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      for (let tap = 0; tap < weights.length; tap += 1) {
        vertical[y * width + x] += weights[tap] * sample(horizontal, x, y + tap - 1);
      }
    }
  }
  const sobelX = [[-1, 0, 1], [-2, 0, 2], [-1, 0, 1]];
  const sobelY = [[-1, -2, -1], [0, 0, 0], [1, 2, 1]];
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      let gx = 0;
      let gy = 0;
      for (let yy = 0; yy < 3; yy += 1) {
        for (let xx = 0; xx < 3; xx += 1) {
          const value = sample(vertical, x + xx - 1, y + yy - 1);
          gx += sobelX[yy][xx] * value;
          gy += sobelY[yy][xx] * value;
        }
      }
      output[y * width + x] = Math.hypot(gx, gy);
    }
  }
  return output;
}

function heatDiffusionOracle(input, width, height, iterations) {
  let current = Float64Array.from(input);
  for (let iteration = 0; iteration < iterations; iteration += 1) {
    const next = new Float64Array(input.length);
    for (let row = 0; row < height; row += 1) {
      for (let col = 0; col < width; col += 1) {
        const index = row * width + col;
        const neighbors = [
          row * width + Math.max(col - 1, 0), row * width + Math.min(col + 1, width - 1),
          Math.max(row - 1, 0) * width + col, Math.min(row + 1, height - 1) * width + col,
        ];
        next[index] = current[index] * 0.5;
        for (const neighbor of neighbors) next[index] += current[neighbor] * 0.125;
      }
    }
    current = next;
  }
  return current;
}

function compareNumerical(actual, expected, absoluteTolerance, relativeTolerance, checks = []) {
  if (actual.length !== expected.length) throw new Error('Oracle length mismatch');
  let maxAbsoluteError = 0;
  let firstFailure = null;
  for (let i = 0; i < actual.length; i += 1) {
    const error = Math.abs(actual[i] - expected[i]);
    maxAbsoluteError = Math.max(maxAbsoluteError, error);
    if ((!Number.isFinite(actual[i]) || !Number.isFinite(expected[i])
        || error > absoluteTolerance + relativeTolerance * Math.abs(expected[i])) && firstFailure === null) {
      firstFailure = i;
    }
  }
  for (const check of checks) {
    for (let i = check.offset; i < check.offset + check.count; i += 1) {
      const error = Math.abs(actual[i] - expected[i]);
      const accepted = check.mode === 'exact' ? actual[i] === expected[i]
        : error < check.absoluteTolerance
          && error / (Math.abs(expected[i]) + check.relativeEpsilon) < check.relativeTolerance;
      if (!accepted && firstFailure === null) firstFailure = i;
    }
  }
  return { passed: firstFailure === null, maxAbsoluteError, firstFailure };
}

export { imageEdgesOracle, heatDiffusionOracle, compareNumerical };

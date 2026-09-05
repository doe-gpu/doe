// Application declarations: grayscale denoising/edges and explicit heat diffusion.
const WORKGROUP_WIDTH = 64;
const FLOAT_BYTES = Float32Array.BYTES_PER_ELEMENT;

function buffer(id, size, role) { return { id, size, role, type: 'storage' }; }

function step(shader, input, output, width, height) {
  return {
    shader, bindings: [{ binding: 0, buffer: input }, { binding: 1, buffer: output }],
    workgroups: [Math.ceil(width * height / WORKGROUP_WIDTH), 1, 1],
  };
}

function dimensions(width, height) {
  if (!Number.isSafeInteger(width) || width < 2 || !Number.isSafeInteger(height) || height < 2) {
    throw new Error('width and height must be integers >= 2');
  }
}

function shaderBody(width, height, operation) {
  return `
@group(0) @binding(0) var<storage, read> input: array<f32>;
@group(0) @binding(1) var<storage, read_write> output: array<f32>;
const width: u32 = ${width}u;
const height: u32 = ${height}u;
fn sample(x: i32, y: i32) -> f32 {
  let xx = u32(clamp(x, 0, i32(width) - 1));
  let yy = u32(clamp(y, 0, i32(height) - 1));
  return input[yy * width + xx];
}
@compute @workgroup_size(${WORKGROUP_WIDTH})
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  let index = gid.x;
  if (index >= width * height) { return; }
  let x = i32(index % width);
  let y = i32(index / width);
  ${operation}
}`;
}

/** Denoise a grayscale image with a separable binomial filter, then find edges. */
function imageEdgesProgram(width, height) {
  dimensions(width, height);
  const size = width * height * FLOAT_BYTES;
  const operations = {
    horizontal: 'output[index] = (sample(x - 1, y) + 2.0 * sample(x, y) + sample(x + 1, y)) * 0.25;',
    vertical: 'output[index] = (sample(x, y - 1) + 2.0 * sample(x, y) + sample(x, y + 1)) * 0.25;',
    edges: `let gx = sample(x + 1, y - 1) + 2.0 * sample(x + 1, y) + sample(x + 1, y + 1)
      - sample(x - 1, y - 1) - 2.0 * sample(x - 1, y) - sample(x - 1, y + 1);
    let gy = sample(x - 1, y + 1) + 2.0 * sample(x, y + 1) + sample(x + 1, y + 1)
      - sample(x - 1, y - 1) - 2.0 * sample(x, y - 1) - sample(x + 1, y - 1);
    output[index] = sqrt(gx * gx + gy * gy);`,
  };
  return {
    schemaVersion: 1, id: 'image_edges',
    buffers: [buffer('input', size, 'input'), buffer('horizontal', size, 'scratch'),
      buffer('vertical', size, 'scratch'), buffer('output', size, 'output')],
    shaders: Object.entries(operations).map(([id, operation]) => ({
      id, entryPoint: 'main', code: shaderBody(width, height, operation),
    })),
    steps: [step('horizontal', 'input', 'horizontal', width, height),
      step('vertical', 'horizontal', 'vertical', width, height),
      step('edges', 'vertical', 'output', width, height)],
    output: 'output',
  };
}

/** Integrate a heat field with clamped boundaries and a stable explicit stencil. */
function heatDiffusionProgram(width, height, iterations) {
  dimensions(width, height);
  if (!Number.isSafeInteger(iterations) || iterations < 3) {
    throw new Error('iterations must be an integer >= 3');
  }
  const size = width * height * FLOAT_BYTES;
  const steps = [];
  let source = 'input';
  for (let i = 0; i < iterations; i += 1) {
    const target = i === iterations - 1 ? 'output' : i % 2 === 0 ? 'ping' : 'pong';
    steps.push(step('diffuse', source, target, width, height));
    source = target;
  }
  return {
    schemaVersion: 1, id: 'heat_diffusion',
    buffers: [buffer('input', size, 'input'), buffer('ping', size, 'scratch'),
      buffer('pong', size, 'scratch'), buffer('output', size, 'output')],
    shaders: [{ id: 'diffuse', entryPoint: 'main', code: shaderBody(width, height,
      `let center = sample(x, y);
      let neighbors = sample(x - 1, y) + sample(x + 1, y) + sample(x, y - 1) + sample(x, y + 1);
      output[index] = center + 0.125 * (neighbors - 4.0 * center);`) }],
    steps, output: 'output',
  };
}

export { imageEdgesProgram, heatDiffusionProgram };

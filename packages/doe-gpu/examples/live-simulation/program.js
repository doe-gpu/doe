// The editable stage advances heat; the fixed commit stage retains the next state.
import { readFileSync } from 'node:fs';
import { freezeTree } from '../../src/compute-program-contract.js';

const POLICY_BYTES = readFileSync(new URL('../../assets/live-simulation.json', import.meta.url));
const POLICY = freezeTree(JSON.parse(POLICY_BYTES));
const WORKGROUP_WIDTH = 64;
const PARAMETER_BYTES = 16;
const DEFAULT_SHADER = `
struct Parameters { width: u32, height: u32, rate: f32, padding: f32 }
@group(0) @binding(0) var<storage, read> state: array<f32>;
@group(0) @binding(1) var<storage, read_write> next: array<f32>;
@group(0) @binding(2) var<uniform> parameters: Parameters;
@compute @workgroup_size(${WORKGROUP_WIDTH})
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  let i = gid.x;
  let width = parameters.width;
  let height = parameters.height;
  if (i >= width * height) { return; }
  let x = i % width;
  let y = i / width;
  let left = y * width + u32(max(i32(x) - 1, 0));
  let right = y * width + min(x + 1u, width - 1u);
  let above = u32(max(i32(y) - 1, 0)) * width + x;
  let below = min(y + 1u, height - 1u) * width + x;
  next[i] = state[i] + parameters.rate *
    (state[left] + state[right] + state[above] + state[below] - 4.0 * state[i]);
}`;
const COMMIT_SHADER = `
@group(0) @binding(0) var<storage, read> next: array<f32>;
@group(0) @binding(1) var<storage, read_write> state: array<f32>;
@compute @workgroup_size(${WORKGROUP_WIDTH})
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  if (gid.x < arrayLength(&state)) { state[gid.x] = next[gid.x]; }
}`;
const STATE_FORMAT = `heat-field/f32/${POLICY.width}x${POLICY.height}/v1`;

function descriptor(code, stateFormat = STATE_FORMAT) {
  if (typeof code !== 'string' || Buffer.byteLength(code) > POLICY.maximumShaderBytes) {
    throw new Error(`shader must contain at most ${POLICY.maximumShaderBytes} bytes`);
  }
  const bytes = POLICY.width * POLICY.height * Float32Array.BYTES_PER_ELEMENT;
  const workgroups = [Math.ceil(POLICY.width * POLICY.height / WORKGROUP_WIDTH), 1, 1];
  return {
    schemaVersion: 3, id: 'live_heat',
    buffers: [
      { id: 'state', size: bytes, role: 'input', type: 'storage', lifetime: 'program', stateFormat },
      { id: 'next', size: bytes, role: 'output', type: 'storage' },
      { id: 'parameters', size: PARAMETER_BYTES, role: 'input', type: 'uniform' },
    ],
    shaders: [{ id: 'diffuse', code, entryPoint: 'main' },
      { id: 'commit', code: COMMIT_SHADER, entryPoint: 'main' }],
    steps: [
      { shader: 'diffuse', workgroups, bindings: [
        { binding: 0, buffer: 'state' }, { binding: 1, buffer: 'next' }, { binding: 2, buffer: 'parameters' },
      ] },
      { shader: 'commit', workgroups, bindings: [{ binding: 0, buffer: 'next' }, { binding: 1, buffer: 'state' }] },
    ], output: 'next',
  };
}

function parameters(rate) {
  if (!Number.isFinite(rate) || rate < POLICY.minimumRate || rate > POLICY.maximumRate) {
    throw new Error(`rate must be within [${POLICY.minimumRate}, ${POLICY.maximumRate}]`);
  }
  const bytes = new ArrayBuffer(PARAMETER_BYTES);
  const view = new DataView(bytes);
  view.setUint32(0, POLICY.width, true);
  view.setUint32(4, POLICY.height, true);
  view.setFloat32(8, rate, true);
  return new Uint8Array(bytes);
}

export { POLICY, POLICY_BYTES, DEFAULT_SHADER, STATE_FORMAT, descriptor, parameters };

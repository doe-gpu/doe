struct Parameters { rows: u32, dimensions: u32, pad0: u32, pad1: u32 }
@group(0) @binding(0) var<storage, read> database: array<f32>;
@group(0) @binding(1) var<storage, read> query: array<f32>;
@group(0) @binding(2) var<uniform> parameters: Parameters;
@group(0) @binding(3) var<storage, read_write> output: array<f32>;
var<workgroup> partial: array<f32, 64>;

@compute @workgroup_size(64)
fn main(@builtin(workgroup_id) group: vec3<u32>, @builtin(local_invocation_id) local: vec3<u32>) {
  let row = group.x;
  let lane = local.x;
  var distance = 0.0;
  for (var column = lane; column < parameters.dimensions; column += 64u) {
    let difference = database[row * parameters.dimensions + column] - query[column];
    distance += difference * difference;
  }
  partial[lane] = distance;
  workgroupBarrier();
  for (var stride = 32u; stride > 0u; stride /= 2u) {
    if (lane < stride) { partial[lane] += partial[lane + stride]; }
    workgroupBarrier();
  }
  if (lane == 0u) { output[row] = partial[0]; }
}

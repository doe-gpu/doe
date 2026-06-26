const kWorkgroupSize : u32 = 256u;
const kWorkgroupMask : u32 = kWorkgroupSize - 1u;

@group(0) @binding(0) var<storage, read_write> outVal : array<u32>;
var<workgroup> wg: array<atomic<u32>, kWorkgroupSize>;

@compute @workgroup_size(kWorkgroupSize, 1, 1)
fn main(
  @builtin(local_invocation_id) local_id : vec3u,
  @builtin(global_invocation_id) global_id : vec3u
) {
  var accum : u32 = outVal[global_id.x];
  atomicStore(&wg[local_id.x], accum + global_id.x);
  workgroupBarrier();

  for (var i : u32 = 0u; i < kWorkgroupSize; i = i + 1u) {
    accum = atomicLoad(&wg[(i + accum) & kWorkgroupMask]);
  }

  workgroupBarrier();
  outVal[global_id.x] = accum;
}

const kWorkgroupSize : u32 = 256u;
const kWorkgroupMask : u32 = kWorkgroupSize - 1u;
const kInnerIters : u32 = 100u;

@group(0) @binding(0) var<storage, read_write> outVal : array<u32>;
var<workgroup> wg: array<u32, kWorkgroupSize>;

@compute @workgroup_size(kWorkgroupSize, 1, 1)
fn main(
  @builtin(local_invocation_id) local_id : vec3u,
  @builtin(global_invocation_id) global_id : vec3u
) {
  var accum : u32 = outVal[global_id.x];
  var iter : u32 = 0u;
  loop {
    if (iter >= kInnerIters) {
      break;
    }

    wg[local_id.x] = accum + global_id.x + iter;
    workgroupBarrier();

    var i : u32 = 0u;
    loop {
      if (i >= kWorkgroupSize) {
        break;
      }
      accum = wg[(i + accum) & kWorkgroupMask];
      i = i + 1u;
    }

    workgroupBarrier();
    iter = iter + 1u;
  }

  outVal[global_id.x] = accum;
}

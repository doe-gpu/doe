const kBufferSize : u32 = 1024u;
const kBufferMask : u32 = kBufferSize - 1u;

@group(0) @binding(0) var<storage, read_write> inout_data : array<u32, kBufferSize>;
var<workgroup> wg_data : array<u32, kBufferSize>;

@compute @workgroup_size(1, 1, 1)
fn main() {
  var accum : u32 = inout_data[0];

  for (var i : u32 = 0u; i < kBufferSize; i = i + 1u) {
    wg_data[i] = inout_data[i];
  }

  for (var i : u32 = 0u; i < 1000000u; i = i + 1u) {
    let idx = (i + accum) & kBufferMask;
    accum = (accum ^ wg_data[idx]) + 123u;
  }

  inout_data[0] = accum;
}

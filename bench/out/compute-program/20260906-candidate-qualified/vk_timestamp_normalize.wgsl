// Exact f32-period multiplication using base-2^16 limbs; no shaderInt64 required.
@group(0) @binding(0) var<storage, read_write> timestamps: array<vec2<u32>>;

fn limb_at(product: array<u32, 6>, start: i32) -> u32 {
  if (start <= -16 || start >= 96) { return 0u; }
  if (start < 0) { return (product[0] << u32(-start)) & 65535u; }
  let index = u32(start) >> 4u;
  let shift = u32(start) & 15u;
  var value = product[index] >> shift;
  if (shift != 0u && index < 5u) {
    value = value | (product[index + 1u] << (16u - shift));
  }
  return value & 65535u;
}

@compute @workgroup_size(WORKGROUP_SIZE)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
  if (id.x >= arrayLength(&timestamps)) { return; }
  let ticks = timestamps[id.x] & vec2<u32>(MASK_LOW, MASK_HIGH);
  let digits = array<u32, 4>(ticks.x & 65535u, ticks.x >> 16u,
    ticks.y & 65535u, ticks.y >> 16u);
  let multiplier = array<u32, 2>(MANTISSA & 65535u, MANTISSA >> 16u);
  var product: array<u32, 6>;
  for (var i = 0u; i < 4u; i++) {
    var carry = 0u;
    for (var j = 0u; j < 2u; j++) {
      let value = digits[i] * multiplier[j] + product[i + j] + carry;
      product[i + j] = value & 65535u;
      carry = value >> 16u;
    }
    product[i + 2u] = carry;
  }
  timestamps[id.x] = vec2<u32>(
    limb_at(product, -PERIOD_SHIFT) | (limb_at(product, 16 - PERIOD_SHIFT) << 16u),
    limb_at(product, 32 - PERIOD_SHIFT) | (limb_at(product, 48 - PERIOD_SHIFT) << 16u));
}

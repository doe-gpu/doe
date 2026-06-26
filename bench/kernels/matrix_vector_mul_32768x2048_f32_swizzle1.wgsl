const kRows : u32 = 32768u;
const kPackedCols : u32 = 512u;

@group(0) @binding(0) var<storage, read> matrixData : array<vec4<f32>>;
@group(0) @binding(1) var<storage, read> vectorData : array<vec4<f32>>;
@group(0) @binding(2) var<storage, read_write> outData : array<vec4<f32>>;

@compute @workgroup_size(64, 1, 1)
fn main(@builtin(global_invocation_id) gid : vec3u) {
  let rowBy4 = gid.x;
  if (rowBy4 >= (kRows / 4u)) {
    return;
  }

  var sum : vec4<f32> = vec4<f32>(0.0);
  var col : u32 = 0u;
  loop {
    if (col >= kPackedCols) {
      break;
    }

    let base = 4u * (rowBy4 * kPackedCols + col);
    let v0 = vectorData[col + 0u];
    let v1 = vectorData[col + 1u];
    let v2 = vectorData[col + 2u];
    let v3 = vectorData[col + 3u];
    let v4 = vectorData[col + 4u];
    let v5 = vectorData[col + 5u];
    let v6 = vectorData[col + 6u];
    let v7 = vectorData[col + 7u];
    let v8 = vectorData[col + 8u];
    let v9 = vectorData[col + 9u];
    let v10 = vectorData[col + 10u];
    let v11 = vectorData[col + 11u];
    let v12 = vectorData[col + 12u];
    let v13 = vectorData[col + 13u];
    let v14 = vectorData[col + 14u];
    let v15 = vectorData[col + 15u];
    sum = sum + vec4<f32>(
      dot(matrixData[base + 0u], v0),
      dot(matrixData[base + 1u], v0),
      dot(matrixData[base + 2u], v0),
      dot(matrixData[base + 3u], v0)
    ) + vec4<f32>(
      dot(matrixData[base + 4u], v1),
      dot(matrixData[base + 5u], v1),
      dot(matrixData[base + 6u], v1),
      dot(matrixData[base + 7u], v1)
    ) + vec4<f32>(
      dot(matrixData[base + 8u], v2),
      dot(matrixData[base + 9u], v2),
      dot(matrixData[base + 10u], v2),
      dot(matrixData[base + 11u], v2)
    ) + vec4<f32>(
      dot(matrixData[base + 12u], v3),
      dot(matrixData[base + 13u], v3),
      dot(matrixData[base + 14u], v3),
      dot(matrixData[base + 15u], v3)
    ) + vec4<f32>(
      dot(matrixData[base + 16u], v4),
      dot(matrixData[base + 17u], v4),
      dot(matrixData[base + 18u], v4),
      dot(matrixData[base + 19u], v4)
    ) + vec4<f32>(
      dot(matrixData[base + 20u], v5),
      dot(matrixData[base + 21u], v5),
      dot(matrixData[base + 22u], v5),
      dot(matrixData[base + 23u], v5)
    ) + vec4<f32>(
      dot(matrixData[base + 24u], v6),
      dot(matrixData[base + 25u], v6),
      dot(matrixData[base + 26u], v6),
      dot(matrixData[base + 27u], v6)
    ) + vec4<f32>(
      dot(matrixData[base + 28u], v7),
      dot(matrixData[base + 29u], v7),
      dot(matrixData[base + 30u], v7),
      dot(matrixData[base + 31u], v7)
    ) + vec4<f32>(
      dot(matrixData[base + 32u], v8),
      dot(matrixData[base + 33u], v8),
      dot(matrixData[base + 34u], v8),
      dot(matrixData[base + 35u], v8)
    ) + vec4<f32>(
      dot(matrixData[base + 36u], v9),
      dot(matrixData[base + 37u], v9),
      dot(matrixData[base + 38u], v9),
      dot(matrixData[base + 39u], v9)
    ) + vec4<f32>(
      dot(matrixData[base + 40u], v10),
      dot(matrixData[base + 41u], v10),
      dot(matrixData[base + 42u], v10),
      dot(matrixData[base + 43u], v10)
    ) + vec4<f32>(
      dot(matrixData[base + 44u], v11),
      dot(matrixData[base + 45u], v11),
      dot(matrixData[base + 46u], v11),
      dot(matrixData[base + 47u], v11)
    ) + vec4<f32>(
      dot(matrixData[base + 48u], v12),
      dot(matrixData[base + 49u], v12),
      dot(matrixData[base + 50u], v12),
      dot(matrixData[base + 51u], v12)
    ) + vec4<f32>(
      dot(matrixData[base + 52u], v13),
      dot(matrixData[base + 53u], v13),
      dot(matrixData[base + 54u], v13),
      dot(matrixData[base + 55u], v13)
    ) + vec4<f32>(
      dot(matrixData[base + 56u], v14),
      dot(matrixData[base + 57u], v14),
      dot(matrixData[base + 58u], v14),
      dot(matrixData[base + 59u], v14)
    ) + vec4<f32>(
      dot(matrixData[base + 60u], v15),
      dot(matrixData[base + 61u], v15),
      dot(matrixData[base + 62u], v15),
      dot(matrixData[base + 63u], v15)
    );
    col = col + 16u;
  }

  outData[rowBy4] = sum;
}

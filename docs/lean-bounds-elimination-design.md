# Lean-verified bounds check elimination

## Status

Design approved. Layer 1 (unconditional clamping) is implemented in
`ir_transform_robustness.zig`. Layer 2 (Lean-verified elimination) has
theorem proofs in `pipeline/lean/Doe/Shader/ComputeBounds.lean` and
now covers both storage-buffer gid indexing and textureLoad/textureStore
gid-coordinate guards, plus dispatch-fit texture extent proofs for 1D/2D/3D
gid coordinates. The proof-backed pattern recognizers and IR metadata are
implemented. Storage-buffer elimination is now active on native compute
runtime translation with dispatch-time precondition enforcement, including
the existing `flat_index_2d_inbounds` theorem for `gid.y * dispatch_width +
gid.x`, the 3D flattened `gid.z * (dispatch_height * dispatch_width) +
gid.y * dispatch_width + gid.x` family, the broader affine `gid + constant`,
`gid * constant + offset`, canonical counted-loop `gid + i + constant`,
`flat_index_2d + constant`, and 1D tiled
`(gid / tile_width) * tile_stride + (gid % tile_width) + offset`
families. Dispatch-fit texture
precondition enforcement is now active on native compute runtime
translation as well for direct gid, affine gid-derived, and tiled gid-derived
texture coordinates, including constant non-zero mip accesses; `_doe_sizes` is
only retained when a real runtime `arrayLength` query survives proof-backed
clamp elimination.
Default/public WGSL translation still stays conservative for the
dispatch-fit texture path; the remaining activation blocker is whether
non-runtime/public consumers should opt into host-validated proof
contracts at all.

## Problem

The WebGPU specification requires that all shader buffer/texture accesses
are bounds-checked. `ir_transform_robustness.zig` injects `min(index,
length-1)` for every indexing operation unconditionally. This is correct
but costs one `min` instruction per array access — measurable in
tight compute kernels.

Tint (Dawn's shader compiler) added heuristic integer range analysis
(2024) to skip bounds checks when it can statically prove an access is
safe. This is sound but not formally verified — the analysis could have
bugs that silently remove necessary checks.

Doe's design property: Lean proofs that formally verify the conditions under
which an index is guaranteed in-bounds, with the proofs consumed at compile
time to elide clamps. Provably correct bounds elimination, not heuristic.

## Architecture

### Two-layer robustness

```
Layer 1: Unconditional clamp (always present)
  ir_transform_robustness.zig → min(index, length-1) for every index

Layer 2: Lean-verified elimination (opt-in, explicit transform config)
  ComputeBounds.lean proves conditions → proven-conditions.json artifact
  → ir_transform_robustness.zig pattern-matches and skips clamp when
  proof conditions are met AND host-side dispatch enforces preconditions
```

Layer 1 is the safety net — it is always correct. Layer 2 is a
performance optimization that removes the clamp only when a formal proof
guarantees the clamp is a no-op.

### Core theorem

The fundamental insight:

```
global_invocation_id.x = workgroup_id.x * workgroup_size.x + local_invocation_id.x
```

GPU hardware guarantees:
- `workgroup_id.x < num_workgroups.x`
- `local_invocation_id.x < workgroup_size.x`

Therefore: `global_invocation_id.x < workgroup_size.x * num_workgroups.x`

If the host ensures `workgroup_size.x * num_workgroups.x ≤ array_length`
at dispatch time, then `global_invocation_id.x < array_length` and the
`min()` clamp is a no-op.

This is formalized as `gid_inbounds_when_dispatch_fits` in
`Doe/Shader/ComputeBounds.lean`.

### Proof artifact integration

The proof artifact (`proven-conditions.json`) schema version 1 includes a
`boundsEliminations` array:

```json
{
  "schemaVersion": 1,
  "boundsEliminations": [
    {
      "theorem": "gid_inbounds_when_dispatch_fits",
      "pattern": "global_invocation_id.{component} indexes storage buffer",
      "precondition": "workgroup_size.{component} * num_workgroups.{component} <= buffer_element_count",
      "eliminates": "min(gid.{component}, arrayLength(&buf) - 1) → gid.{component}",
      "runtimePath": "runtime/zig/src/compiler/wgsl/ir/ir_transform_robustness.zig:clamp_runtime_sized"
    },
    {
      "theorem": "flat_index_2d_inbounds",
      "pattern": "gid.y * width + gid.x indexes storage buffer",
      "precondition": "ws.x * nwg.x <= width AND ws.y * nwg.y <= height AND width * height <= buffer_element_count",
      "eliminates": "min(flat_index, arrayLength(&buf) - 1) → flat_index",
      "runtimePath": "runtime/zig/src/compiler/wgsl/ir/ir_transform_robustness.zig:clamp_runtime_sized"
    },
    {
      "theorem": "guarded_gid_texture_coords_2d_inbounds",
      "pattern": "global_invocation_id.xy texture coords guarded by root early-return against textureDimensions(tex[,level]).xy",
      "precondition": "if gid.x >= textureDimensions(...).x || gid.y >= textureDimensions(...).y { return; }",
      "eliminates": "clamp(coords, vec(0), textureDimensions(tex[,level]) - 1) → coords",
      "runtimePath": "runtime/zig/src/compiler/wgsl/ir/ir_transform_robustness.zig:clamp_texture_coords"
    }
  ]
}
```

### Pipeline flow

```
1. Lean typecheck
   pipeline/lean/Doe/Shader/ComputeBounds.lean is compiled.
   All theorems are verified by the Lean kernel.

2. Artifact extraction
   pipeline/lean/extract.sh runs Doe/Extract.lean.
   Emits proven-conditions.json with boundsEliminations section.

3. Zig build
   build.zig reads proven-conditions.json when -Dlean-verified=true.
   lean_proof.zig validates the artifact at comptime.
   Sets lean_proof.bounds_elimination_available = true.

4. IR transform (compile time per shader)
   ir_transform_robustness.zig checks lean_proof.bounds_elimination_available.
   For each index expression:
   a. Pattern-match: is this gid.{x,y,z} indexing a storage buffer?
   b. If matched AND the shader declares @workgroup_size, record the
      binding + component + workgroup_size for host-side enforcement.
   c. Skip the min() clamp for this expression.
   d. Tag the shader module with a dispatch precondition table.

5. Host dispatch (runtime per dispatch call)
   doeNativeComputeDispatchFlush checks precondition table:
   - For each entry: workgroup_size.{component} * num_workgroups.{component}
     <= buffer_element_count
   - If ANY precondition fails, the dispatch still executes (safety is
     guaranteed by the proof — the condition failing means the shader
     would access out-of-bounds, which is a user error regardless).
   - Optional: emit a validation warning when precondition fails.

Texture guard elimination follows a separate proof-backed path with no
host-side table:
- pattern-match root early-return guard against `textureDimensions(tex[,level])`
- prove that surviving executions have componentwise in-bounds gid coords
- skip the later `clamp(coords, 0, textureDimensions - 1)` insertion entirely

Texture dispatch-fit elimination uses the same theorem style as storage
bounds elimination:
- pattern-match `textureLoad` / `textureStore` coords built directly from
  `global_invocation_id`
- record a texture binding + gid-axis precondition table on the IR module
- elide the later `clamp(coords, 0, textureDimensions - 1)` insertion when
  `workgroup_size * num_workgroups <= textureDimensions(tex, 0)` is assumed
```

### Pattern recognizer (Zig-side, future implementation)

The pattern recognizer in `ir_transform_robustness.zig` will match:

1. **Direct gid access**: `buf[global_invocation_id.x]`
   - Index expression is a member access `.x`/`.y`/`.z` on a builtin
     `global_invocation_id` variable
   - Base is a `global_ref` to a storage buffer

2. **Flat 2D access**: `buf[gid.y * width + gid.x]`
   - Index expression is `binary(add, binary(mul, member(gid, y), const), member(gid, x))`
   - Both gid components have independent proofs; width is a pipeline constant

3. **Affine 1D strided access**: `buf[gid.x * stride + offset]`
   - `stride` and `offset` must be positive/known compile-time constants
   - Host-side precondition validates `ws.x * nwg.x * stride + offset <= buf.length`

4. **Affine flat 2D access**: `buf[gid.y * width + gid.x + offset]`
   - Same width matching as flat 2D access
   - Host-side precondition validates `width * height + offset <= buf.length`

5. **Loop-carried access**: `buf[gid.x + i]` where `i < stride`
   - Requires compound precondition: `ws.x * nwg.x + stride <= buf.length`
   - Future extension, not in the current implementation

### Comparison with Tint

| Property | Tint | Doe |
|---|---|---|
| Method | Heuristic integer range analysis | Formal proof |
| Verifiability | Test suite | Lean kernel |
| False positives | Possible (analysis bug removes needed check) | Impossible (proof must be valid) |
| Coverage | Broader patterns (arbitrary integer flow) | Focused patterns (gid-based access) |
| Cost | C++ analysis pass at compile time | Zero runtime cost; one-time Lean build |
| Extensibility | Modify C++ analyzer | Add new Lean theorem |
| Auditability | Read 150K LOC C++ | Read 100-line Lean file |

Doe's approach is narrower but provably correct. The common case (compute
shader accessing `buf[gid.x]`) is covered by the core theorem. Tint's
range analysis covers more exotic patterns but cannot guarantee
correctness of the analysis itself.

## Theorems

### Verified (ComputeBounds.lean)

| Theorem | Category | What it proves |
|---|---|---|
| `gid_component_lt_total` | `lean_verified` | Single-dimension gid < array_length when dispatch fits |
| `gid_inbounds_when_dispatch_fits` | `lean_verified` | 1D dispatch: gid.x < buf.length when ws.x * nwg.x ≤ buf.length |
| `gid_plus_offset_inbounds_when_dispatch_fits` | `lean_verified` | 1D affine dispatch: gid.x + offset < buf.length when ws.x * nwg.x + offset ≤ buf.length |
| `gid_times_stride_plus_offset_inbounds_when_dispatch_fits` | `lean_verified` | 1D strided affine dispatch: gid.x * stride + offset < buf.length when ws.x * nwg.x * stride + offset ≤ buf.length |
| `gid_plus_bounded_loop_index_inbounds_when_dispatch_fits` | `lean_verified` | Constant-bounded counted loops (`for`, `while`, and guarded `loop`, ascending or descending) give `gid.x + i + offset < buf.length` when ws.x * nwg.x + limit + offset fits |
| `gid_affine_plus_scaled_loop_index_inbounds_when_dispatch_fits` | `lean_verified` | Constant-bounded counted loops (including descending forms) give `gid.x * gid_stride + i * loop_stride + offset < buf.length` when the scaled dispatch and loop limits fit |
| `gid_tiled_index_plus_offset_inbounds_when_dispatch_fits` | `lean_verified` | `(gid.x / tile_width) * tile_stride + (gid.x % tile_width) + offset < buf.length` when host-validated tiled groups fit |
| `clamp_noop_when_inbounds` | `lean_verified` | min(gid, len-1) = gid when gid < len (connects proof to transform) |
| `gid_2d_inbounds` | `lean_verified` | Both components bounded independently for 2D dispatch |
| `flat_index_2d_inbounds` | `lean_verified` | gid.y * width + gid.x < width * height when components bounded |
| `flat_index_2d_plus_offset_inbounds` | `lean_verified` | gid.y * width + gid.x + offset < buf.length when width * height + offset fits |
| `flat_index_3d_inbounds` | `lean_verified` | gid.z * (width * height) + gid.y * width + gid.x < width * height * depth when components bounded |
| `flat_index_3d_plus_offset_inbounds` | `lean_verified` | 3D flat index plus constant offset stays in bounds when width * height * depth + offset fits |
| `gid_texture_coord_1d_inbounds_when_dispatch_fits` | `lean_verified` | Dispatch-fit precondition implies a 1D gid texture coord is in bounds |
| `gid_texture_coords_2d_inbounds_when_dispatch_fits` | `lean_verified` | Dispatch-fit precondition implies in-bounds 2D gid texture coords |
| `gid_texture_coord_1d_affine_inbounds_when_dispatch_fits` | `lean_verified` | 1D affine gid-derived texture coord stays in bounds when the validated extent fits |
| `gid_texture_coords_2d_affine_inbounds_when_dispatch_fits` | `lean_verified` | 2D affine gid-derived texture coords stay in bounds when per-axis validated extents fit |
| `gid_texture_coords_3d_affine_inbounds_when_dispatch_fits` | `lean_verified` | 3D affine gid-derived texture coords stay in bounds when per-axis validated extents fit |
| `gid_texture_coord_1d_tiled_inbounds_when_dispatch_fits` | `lean_verified` | 1D tiled gid-derived texture coord stays in bounds when tiled groups fit the validated extent |
| `gid_texture_coords_2d_tiled_inbounds_when_dispatch_fits` | `lean_verified` | 2D tiled gid-derived texture coords stay in bounds when per-axis tiled groups fit |
| `gid_texture_coords_3d_tiled_inbounds_when_dispatch_fits` | `lean_verified` | 3D tiled gid-derived texture coords stay in bounds when per-axis tiled groups fit |
| `guarded_gid_texture_coords_2d_inbounds` | `lean_verified` | Root early-return guard against `textureDimensions(...).xy` implies in-bounds 2D gid coords |
| `gid_texture_coords_3d_inbounds_when_dispatch_fits` | `lean_verified` | Dispatch-fit precondition implies in-bounds 3D gid texture coords |
| `guarded_gid_texture_coords_3d_inbounds` | `lean_verified` | Root early-return guard against `textureDimensions(...).xyz` implies in-bounds 3D gid coords |

### Why `lean_verified`

All theorems quantify over arbitrary `Nat` values (workgroup sizes,
dispatch dimensions, array lengths). Zig `comptime` cannot enumerate
these — the domains are unbounded. This is where Lean earns its keep,
exactly matching the criterion established in `pipeline/lean/README.md`.

## Implementation sequence

1. **Done**: `ir_transform_robustness.zig` — unconditional clamping (Layer 1)
2. **Done**: `Doe/Shader/ComputeBounds.lean` — formal proofs
3. **Done**: `Extract.lean` updated to import Shader module and emit `boundsEliminations`
4. **Done**: Pattern recognizer in `ir_transform_robustness.zig` — matches gid storage-buffer access patterns, guarded gid texture coordinate patterns, direct/affine/tiled dispatch-fit texture coordinate patterns, and constant mip-level texture accesses
5. **Done**: `lean_proof.zig` — validates shader theorem/artifact coverage and exposes the comptime availability flags
6. **Done/Partial**: explicit proof-aware analysis path now powers native compute runtime translation; default/public translation remains conservative
7. **Done**: `_doe_sizes` requirement now derives from surviving IR `arrayLength` use, and proof-covered robustness clamps no longer keep `_doe_sizes` alive on Metal
8. **Done**: host-side storage-buffer and texture dispatch precondition checks in native compute dispatch paths (`doeNativeComputeDispatchFlush`, `doe_compute_ext_native.zig`, `doe_vulkan_compute_native.zig`)
9. **Future**: broader guarded texture patterns, a policy decision for public/non-runtime proof consumption, mixed affine+tiled texture coord families, and deeper non-counted/data-dependent loop range analysis beyond the current counted-loop proof contract

## File map

| File | Role |
|---|---|
| `pipeline/lean/Doe/Shader/ComputeBounds.lean` | Formal proofs of compute bounds safety |
| `runtime/zig/src/compiler/wgsl/ir/ir_transform_robustness.zig` | Layer 1 clamping + future Layer 2 pattern recognizer |
| `runtime/zig/src/verification/lean_proof.zig` | Comptime proof artifact validator |
| `pipeline/lean/Doe/Extract.lean` | Proof artifact extraction (emits proven-conditions.json) |
| `config/proof-artifact.schema.json` | Schema for proven-conditions.json |
| `docs/lean-bounds-elimination-design.md` | This document |

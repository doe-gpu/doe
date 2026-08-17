-- Shader compute bounds safety theorems.
-- Mirrors: runtime/zig/src/compiler/wgsl/ir/ir_transform_robustness.zig
--
-- Proves that global_invocation_id components are strictly less than
-- array_length when the dispatch dimensions fit. This lets the robustness
-- pass skip the min() clamp for index patterns that match proven conditions.
--
-- Layer 1 (Zig): clamp ALL indices unconditionally (ir_transform_robustness.zig).
-- Layer 2 (Lean → Zig): this module proves conditions under which the clamp is
-- provably unnecessary, allowing the Zig runtime to elide it.
--
-- Integration: build.zig reads proven-conditions.json (-Dlean-verified=true),
-- lean_proof.zig validates at comptime, ir_transform_robustness.zig consults
-- the proof status to skip clamping for matched patterns.

import Doe.Shader.Tactics

/-- Global invocation ID for a single dimension.
    Mirrors WGSL: global_invocation_id.x = workgroup_id.x * workgroup_size.x + local_invocation_id.x -/
def globalInvocationId (workgroup_id local_id workgroup_size : Nat) : Nat :=
  workgroup_id * workgroup_size + local_id

/-- Core single-dimension bound: if the dispatch grid fits in the array,
    every global invocation ID is strictly less than the array length.

    Preconditions (enforced at dispatch time by host-side check):
    - workgroup_id < num_workgroups  (GPU hardware guarantee)
    - local_id < workgroup_size      (GPU hardware guarantee)
    - workgroup_size * num_workgroups ≤ array_length  (host-side precondition)

    This is `lean_verified`: it quantifies over arbitrary Nat values and
    cannot be replicated by comptime enumeration. -/
theorem gid_component_lt_total
    (workgroup_id local_id workgroup_size num_workgroups array_length : Nat)
    (h_wid : workgroup_id < num_workgroups)
    (h_lid : local_id < workgroup_size)
    (h_fit : workgroup_size * num_workgroups ≤ array_length) :
    globalInvocationId workgroup_id local_id workgroup_size < array_length := by
  unfold globalInvocationId
  have h_local :
      workgroup_id * workgroup_size + local_id <
      workgroup_id * workgroup_size + workgroup_size := by
    exact Nat.add_lt_add_left h_lid (workgroup_id * workgroup_size)
  have h_step :
      workgroup_id * workgroup_size + workgroup_size =
      (workgroup_id + 1) * workgroup_size := by
    simpa using (Nat.succ_mul workgroup_id workgroup_size).symm
  have h_wid_mul :
      (workgroup_id + 1) * workgroup_size ≤
      num_workgroups * workgroup_size := by
    exact Nat.mul_le_mul_right workgroup_size (Nat.succ_le_of_lt h_wid)
  have h_fit_comm :
      num_workgroups * workgroup_size ≤ array_length := by
    simpa [Nat.mul_comm] using h_fit
  calc
    workgroup_id * workgroup_size + local_id <
        workgroup_id * workgroup_size + workgroup_size := h_local
    _ = (workgroup_id + 1) * workgroup_size := h_step
    _ ≤ num_workgroups * workgroup_size := h_wid_mul
    _ ≤ array_length := h_fit_comm

/-- 1D dispatch convenience wrapper. When a compute shader accesses
    buf[global_invocation_id.x] and the host ensures
    workgroup_size.x * num_workgroups.x ≤ buf.length,
    the access is proven in-bounds and the min() clamp can be elided.

    This is the theorem that ir_transform_robustness.zig pattern-matches
    against. The pattern recognizer checks:
    1. Index expression uses global_invocation_id.x
    2. Base is a storage buffer with known binding
    3. Dispatch precondition is registered for that binding -/
theorem gid_inbounds_when_dispatch_fits
    (workgroup_id_x local_id_x workgroup_size_x num_workgroups_x array_length : Nat)
    (h_wid : workgroup_id_x < num_workgroups_x)
    (h_lid : local_id_x < workgroup_size_x)
    (h_fit : workgroup_size_x * num_workgroups_x ≤ array_length) :
    globalInvocationId workgroup_id_x local_id_x workgroup_size_x < array_length :=
  gid_component_lt_total workgroup_id_x local_id_x workgroup_size_x num_workgroups_x array_length
    h_wid h_lid h_fit

/-- Affine 1D extension. If the shader indexes `buf[gid.x + offset]`, the
    access is still in bounds when the dispatch extent plus that constant
    offset fits the runtime-sized array length. -/
theorem gid_plus_offset_inbounds_when_dispatch_fits
    (workgroup_id_x local_id_x workgroup_size_x num_workgroups_x array_length offset : Nat)
    (h_wid : workgroup_id_x < num_workgroups_x)
    (h_lid : local_id_x < workgroup_size_x)
    (h_fit : workgroup_size_x * num_workgroups_x + offset ≤ array_length) :
    globalInvocationId workgroup_id_x local_id_x workgroup_size_x + offset < array_length := by
  have h_gid : globalInvocationId workgroup_id_x local_id_x workgroup_size_x < workgroup_size_x * num_workgroups_x :=
    gid_component_lt_total workgroup_id_x local_id_x workgroup_size_x num_workgroups_x _ h_wid h_lid (Nat.le_refl _)
  omega

/-- Strided affine 1D extension. If the shader indexes
    `buf[gid.x * stride + offset]`, the access is in bounds when the dispatch
    extent scaled by that positive constant stride still fits the array. -/
theorem gid_times_stride_plus_offset_inbounds_when_dispatch_fits
    (workgroup_id_x local_id_x workgroup_size_x num_workgroups_x array_length stride offset : Nat)
    (h_stride : 0 < stride)
    (h_wid : workgroup_id_x < num_workgroups_x)
    (h_lid : local_id_x < workgroup_size_x)
    (h_fit : (workgroup_size_x * num_workgroups_x) * stride + offset ≤ array_length) :
    globalInvocationId workgroup_id_x local_id_x workgroup_size_x * stride + offset < array_length := by
  have h_gid : globalInvocationId workgroup_id_x local_id_x workgroup_size_x < workgroup_size_x * num_workgroups_x :=
    gid_component_lt_total workgroup_id_x local_id_x workgroup_size_x num_workgroups_x _ h_wid h_lid (Nat.le_refl _)
  have h_mul : globalInvocationId workgroup_id_x local_id_x workgroup_size_x * stride < (workgroup_size_x * num_workgroups_x) * stride :=
    Nat.mul_lt_mul_of_pos_right h_gid h_stride
  omega

/-- Canonical loop-carried 1D extension. If a shader executes a loop-local
    index `gid.x + i + offset`, and the loop body only runs while `i < limit`,
    then the access is in bounds when the dispatch extent plus that exclusive
    loop limit and constant offset fits the runtime-sized array length. This
    uses a conservative host-side precondition `... + limit + offset ≤ len`
    because the runtime validates only the loop's exclusive upper bound, not
    the exact `limit - 1` maximum iteration value. -/
theorem gid_plus_bounded_loop_index_inbounds_when_dispatch_fits
    (workgroup_id_x local_id_x workgroup_size_x num_workgroups_x array_length limit i offset : Nat)
    (h_i : i < limit)
    (h_wid : workgroup_id_x < num_workgroups_x)
    (h_lid : local_id_x < workgroup_size_x)
    (h_fit : workgroup_size_x * num_workgroups_x + limit + offset ≤ array_length) :
    globalInvocationId workgroup_id_x local_id_x workgroup_size_x + i + offset < array_length := by
  have h_gid : globalInvocationId workgroup_id_x local_id_x workgroup_size_x < workgroup_size_x * num_workgroups_x :=
    gid_component_lt_total workgroup_id_x local_id_x workgroup_size_x num_workgroups_x _ h_wid h_lid (Nat.le_refl _)
  omega

/-- Affine counted-loop extension. If a shader indexes
    `buf[gid.x * gid_stride + i * loop_stride + offset]`, and the loop body
    executes only while `i < limit`, then the access is in bounds when the
    dispatched gid range and the exclusive loop limit both fit after scaling. -/
theorem gid_affine_plus_scaled_loop_index_inbounds_when_dispatch_fits
    (workgroup_id_x local_id_x workgroup_size_x num_workgroups_x array_length : Nat)
    (gid_stride limit i loop_stride offset : Nat)
    (h_gid_stride : 0 < gid_stride)
    (h_loop_stride : 0 < loop_stride)
    (h_i : i < limit)
    (h_wid : workgroup_id_x < num_workgroups_x)
    (h_lid : local_id_x < workgroup_size_x)
    (h_fit : workgroup_size_x * num_workgroups_x * gid_stride + limit * loop_stride + offset ≤ array_length) :
    globalInvocationId workgroup_id_x local_id_x workgroup_size_x * gid_stride + i * loop_stride + offset < array_length := by
  have h_gid : globalInvocationId workgroup_id_x local_id_x workgroup_size_x < workgroup_size_x * num_workgroups_x :=
    gid_component_lt_total workgroup_id_x local_id_x workgroup_size_x num_workgroups_x _ h_wid h_lid (Nat.le_refl _)
  have h_gid_scaled : globalInvocationId workgroup_id_x local_id_x workgroup_size_x * gid_stride < (workgroup_size_x * num_workgroups_x) * gid_stride :=
    Nat.mul_lt_mul_of_pos_right h_gid h_gid_stride
  have h_loop_scaled : i * loop_stride < limit * loop_stride :=
    Nat.mul_lt_mul_of_pos_right h_i h_loop_stride
  omega

/-- Tight-precondition variant of the affine counted-loop extension.
    The original theorem over-approximates the precondition by
    `gid_stride + loop_stride - 1` (substituting `total` for `gid ≤ total - 1`
    and `limit` for `i ≤ limit - 1`). For large-stride dispatches, that slack
    can push the precondition past the buffer size even when the actual
    maximum accessed index is strictly in bounds — e.g. a 256 MB matvec
    buffer packed to exactly `total * gid_stride` elements fails the over-
    approximate fit but is provably in-range.

    This variant encodes the precondition tightly as the strict upper bound
    on the maximum accessed index plus one, corresponding to the runtime
    formula
      `(total_invocations - 1) * gid_stride
         + (limit - 1) * loop_stride
         + offset + 1
       ≤ array_length`
    that `required_buffer_bytes` now uses for `.gid_component` kinds. -/
theorem gid_affine_plus_scaled_loop_index_inbounds_when_dispatch_fits_tight
    (workgroup_id_x local_id_x workgroup_size_x num_workgroups_x array_length : Nat)
    (gid_stride limit i loop_stride offset : Nat)
    (h_i : i < limit)
    (h_wid : workgroup_id_x < num_workgroups_x)
    (h_lid : local_id_x < workgroup_size_x)
    (h_fit :
      (workgroup_size_x * num_workgroups_x - 1) * gid_stride +
        (limit - 1) * loop_stride + offset + 1 ≤ array_length) :
    globalInvocationId workgroup_id_x local_id_x workgroup_size_x * gid_stride + i * loop_stride + offset < array_length := by
  let gid := globalInvocationId workgroup_id_x local_id_x workgroup_size_x
  let total := workgroup_size_x * num_workgroups_x
  have h_gid_lt_total : gid < total := by
    dsimp [gid, total]
    exact gid_component_lt_total
      workgroup_id_x local_id_x workgroup_size_x num_workgroups_x
      (workgroup_size_x * num_workgroups_x)
      h_wid h_lid (Nat.le_refl _)
  have h_total_pos : 0 < total := Nat.lt_of_le_of_lt (Nat.zero_le _) h_gid_lt_total
  have h_gid_le_total_minus_one : gid ≤ total - 1 :=
    Nat.le_sub_of_add_le (by omega)
  have h_gid_scaled_le :
      gid * gid_stride ≤ (total - 1) * gid_stride :=
    Nat.mul_le_mul_right gid_stride h_gid_le_total_minus_one
  have h_limit_pos : 0 < limit := Nat.lt_of_le_of_lt (Nat.zero_le _) h_i
  have h_i_le_limit_minus_one : i ≤ limit - 1 :=
    Nat.le_sub_of_add_le (by omega)
  have h_loop_scaled_le :
      i * loop_stride ≤ (limit - 1) * loop_stride :=
    Nat.mul_le_mul_right loop_stride h_i_le_limit_minus_one
  have h_sum_le :
      gid * gid_stride + i * loop_stride ≤
      (total - 1) * gid_stride + (limit - 1) * loop_stride :=
    Nat.add_le_add h_gid_scaled_le h_loop_scaled_le
  have h_plus_offset_le :
      gid * gid_stride + i * loop_stride + offset ≤
      (total - 1) * gid_stride + (limit - 1) * loop_stride + offset :=
    Nat.add_le_add_right h_sum_le offset
  calc
    gid * gid_stride + i * loop_stride + offset
        ≤ (total - 1) * gid_stride + (limit - 1) * loop_stride + offset := h_plus_offset_le
    _ < (total - 1) * gid_stride + (limit - 1) * loop_stride + offset + 1 := Nat.lt_succ_self _
    _ ≤ array_length := h_fit

/-- Pure loop-only affine bound: if a shader indexes
    `buf[i * loop_stride + offset]` where `i` is the induction variable of a
    counted loop with `i < limit`, and the buffer is packed so that the tight
    upper bound on the indexed range plus one fits, then the access is in
    bounds for every iteration. No gid term is required — this is the
    companion to `gid_affine_plus_scaled_loop_index_inbounds_when_dispatch_fits_tight`
    for access patterns that are purely loop-induction (e.g. the matvec
    `vectorData[col]` inner-loop load where `col` is the unrolled loop
    index with no per-thread offset). -/
theorem loop_index_affine_inbounds_when_loop_fits_tight
    (array_length limit i loop_stride offset : Nat)
    (h_i : i < limit)
    (h_fit : (limit - 1) * loop_stride + offset + 1 ≤ array_length) :
    i * loop_stride + offset < array_length := by
  have h_limit_pos : 0 < limit := Nat.lt_of_le_of_lt (Nat.zero_le _) h_i
  have h_i_le_limit_minus_one : i ≤ limit - 1 :=
    Nat.le_sub_of_add_le (by omega)
  have h_loop_scaled_le :
      i * loop_stride ≤ (limit - 1) * loop_stride :=
    Nat.mul_le_mul_right loop_stride h_i_le_limit_minus_one
  have h_plus_offset_le :
      i * loop_stride + offset ≤ (limit - 1) * loop_stride + offset :=
    Nat.add_le_add_right h_loop_scaled_le offset
  calc
    i * loop_stride + offset
        ≤ (limit - 1) * loop_stride + offset := h_plus_offset_le
    _ < (limit - 1) * loop_stride + offset + 1 := Nat.lt_succ_self _
    _ ≤ array_length := h_fit

/-- 1D tiled index from a global invocation ID. Common pattern:
    `(gid / tile_width) * tile_stride + (gid % tile_width)`. -/
def tiledIndex1D (gid tile_width tile_stride : Nat) : Nat :=
  (gid / tile_width) * tile_stride + (gid % tile_width)

/-- Tiled 1D extension. If the shader indexes
    `buf[(gid.x / tile_width) * tile_stride + (gid.x % tile_width) + offset]`,
    the access is in bounds when each tile-wide group lands within a stride-wide
    segment and the host validates enough tiled groups for the dispatched extent. -/
theorem gid_tiled_index_plus_offset_inbounds_when_dispatch_fits
    (workgroup_id_x local_id_x workgroup_size_x num_workgroups_x array_length tile_width tile_stride offset : Nat)
    (h_tile_pos : 0 < tile_width)
    (h_tile_stride : tile_width ≤ tile_stride)
    (h_wid : workgroup_id_x < num_workgroups_x)
    (h_lid : local_id_x < workgroup_size_x)
    (h_fit : (((workgroup_size_x * num_workgroups_x - 1) / tile_width) + 1) * tile_stride + offset ≤ array_length) :
    tiledIndex1D (globalInvocationId workgroup_id_x local_id_x workgroup_size_x) tile_width tile_stride + offset < array_length := by
  let gid := globalInvocationId workgroup_id_x local_id_x workgroup_size_x
  let total := workgroup_size_x * num_workgroups_x
  have h_gid_lt_total : gid < total := by
    dsimp [gid, total]
    exact gid_component_lt_total
      workgroup_id_x local_id_x workgroup_size_x num_workgroups_x
      (workgroup_size_x * num_workgroups_x)
      h_wid h_lid (Nat.le_refl _)
  have h_gid_le_pred : gid ≤ total - 1 := by
    exact Nat.le_pred_of_lt h_gid_lt_total
  have h_total_pred_bound :
      total - 1 ≤ ((total - 1) / tile_width) * tile_width + tile_width - 1 := by
    exact (Nat.div_le_iff_le_mul h_tile_pos).1 (Nat.le_refl _)
  have h_div_le : gid / tile_width ≤ (total - 1) / tile_width := by
    exact (Nat.div_le_iff_le_mul h_tile_pos).2 (Nat.le_trans h_gid_le_pred h_total_pred_bound)
  have h_mod_lt_tile : gid % tile_width < tile_width := by
    exact Nat.mod_lt gid h_tile_pos
  have h_mod_lt_stride : gid % tile_width < tile_stride := by
    exact Nat.lt_of_lt_of_le h_mod_lt_tile h_tile_stride
  have h_body_lt :
      tiledIndex1D gid tile_width tile_stride <
      ((gid / tile_width) + 1) * tile_stride := by
    unfold tiledIndex1D
    have h_row :
        (gid / tile_width) * tile_stride + gid % tile_width <
        (gid / tile_width) * tile_stride + tile_stride := by
      exact Nat.add_lt_add_left h_mod_lt_stride ((gid / tile_width) * tile_stride)
    have h_step :
        (gid / tile_width) * tile_stride + tile_stride =
        ((gid / tile_width) + 1) * tile_stride := by
      simpa using (Nat.succ_mul (gid / tile_width) tile_stride).symm
    calc
      (gid / tile_width) * tile_stride + gid % tile_width <
          (gid / tile_width) * tile_stride + tile_stride := h_row
      _ = ((gid / tile_width) + 1) * tile_stride := h_step
  have h_div_succ_le :
      (gid / tile_width + 1) ≤ ((total - 1) / tile_width + 1) := by
    exact Nat.succ_le_succ h_div_le
  have h_scaled_le :
      ((gid / tile_width) + 1) * tile_stride ≤
      (((total - 1) / tile_width) + 1) * tile_stride := by
    exact Nat.mul_le_mul_right tile_stride h_div_succ_le
  have h_base_lt :
      tiledIndex1D gid tile_width tile_stride <
      (((total - 1) / tile_width) + 1) * tile_stride := by
    exact Nat.lt_of_lt_of_le h_body_lt h_scaled_le
  have h_offset_lt :
      tiledIndex1D gid tile_width tile_stride + offset <
      (((total - 1) / tile_width) + 1) * tile_stride + offset := by
    exact Nat.add_lt_add_right h_base_lt offset
  calc
    tiledIndex1D gid tile_width tile_stride + offset <
        (((total - 1) / tile_width) + 1) * tile_stride + offset := h_offset_lt
    _ ≤ array_length := h_fit

/-- The clamp min(gid, len-1) is a no-op when gid < len.
    This connects the proof to the transform: if the condition holds,
    min(gid, len-1) = gid, so the injected code has no runtime effect
    and can be elided entirely. -/
theorem clamp_noop_when_inbounds
    (gid len : Nat)
    (h_pos : 0 < len)
    (h_bound : gid < len) :
    min gid (len - 1) = gid := by
  omega

/-- Two-dimensional extension. For 2D compute dispatches accessing
    a 2D array flattened as buf[gid.y * width + gid.x], both components
    must be independently bounded. -/
theorem gid_2d_inbounds
    (wid_x lid_x ws_x nwg_x width : Nat)
    (wid_y lid_y ws_y nwg_y height : Nat)
    (h_wid_x : wid_x < nwg_x) (h_lid_x : lid_x < ws_x)
    (h_wid_y : wid_y < nwg_y) (h_lid_y : lid_y < ws_y)
    (h_fit_x : ws_x * nwg_x ≤ width)
    (h_fit_y : ws_y * nwg_y ≤ height) :
    globalInvocationId wid_x lid_x ws_x < width ∧
    globalInvocationId wid_y lid_y ws_y < height :=
  ⟨gid_component_lt_total wid_x lid_x ws_x nwg_x width h_wid_x h_lid_x h_fit_x,
   gid_component_lt_total wid_y lid_y ws_y nwg_y height h_wid_y h_lid_y h_fit_y⟩

/-- Texture coordinate analogue of `gid_2d_inbounds`. When the dispatched 2D
    grid fits the texture extents, `global_invocation_id.xy` is already
    componentwise in bounds and texture coordinate clamping is redundant. -/
theorem gid_texture_coords_2d_inbounds_when_dispatch_fits
    (wid_x lid_x ws_x nwg_x width : Nat)
    (wid_y lid_y ws_y nwg_y height : Nat)
    (h_wid_x : wid_x < nwg_x) (h_lid_x : lid_x < ws_x)
    (h_wid_y : wid_y < nwg_y) (h_lid_y : lid_y < ws_y)
    (h_fit_x : ws_x * nwg_x ≤ width)
    (h_fit_y : ws_y * nwg_y ≤ height) :
    globalInvocationId wid_x lid_x ws_x < width ∧
    globalInvocationId wid_y lid_y ws_y < height :=
  gid_2d_inbounds wid_x lid_x ws_x nwg_x width wid_y lid_y ws_y nwg_y height
    h_wid_x h_lid_x h_wid_y h_lid_y h_fit_x h_fit_y

/-- Flat index from 2D global invocation ID. Common pattern:
    buf[gid.y * width + gid.x] where buf has width * height elements. -/
def flatIndex2D (gid_x gid_y width : Nat) : Nat :=
  gid_y * width + gid_x

/-- Flat 2D index is in bounds when both components are bounded and
    the total size is width * height. -/
theorem flat_index_2d_inbounds
    (gid_x gid_y width height : Nat)
    (h_x : gid_x < width)
    (h_y : gid_y < height) :
    flatIndex2D gid_x gid_y width < width * height := by
  unfold flatIndex2D
  have h_row :
      gid_y * width + gid_x < gid_y * width + width := by
    exact Nat.add_lt_add_left h_x (gid_y * width)
  have h_step :
      gid_y * width + width = (gid_y + 1) * width := by
    simpa using (Nat.succ_mul gid_y width).symm
  have h_height :
      (gid_y + 1) * width ≤ height * width := by
    exact Nat.mul_le_mul_right width (Nat.succ_le_of_lt h_y)
  calc
    gid_y * width + gid_x < gid_y * width + width := h_row
    _ = (gid_y + 1) * width := h_step
    _ ≤ height * width := h_height
    _ = width * height := by simp [Nat.mul_comm]

/-- Flat 2D index with an additional constant offset. This captures row-major
    kernels that reserve a prefix region before the dispatch-visible window. -/
theorem flat_index_2d_plus_offset_inbounds
    (gid_x gid_y width height offset array_length : Nat)
    (h_x : gid_x < width)
    (h_y : gid_y < height)
    (h_fit : width * height + offset ≤ array_length) :
    flatIndex2D gid_x gid_y width + offset < array_length := by
  have h_flat_lt : flatIndex2D gid_x gid_y width < width * height := by
    exact flat_index_2d_inbounds gid_x gid_y width height h_x h_y
  have h_offset_lt :
      flatIndex2D gid_x gid_y width + offset < width * height + offset := by
    exact Nat.add_lt_add_right h_flat_lt offset
  calc
    flatIndex2D gid_x gid_y width + offset < width * height + offset := h_offset_lt
    _ ≤ array_length := h_fit

/-- Flat index from 3D global invocation ID. Common pattern:
    buf[(gid.z * height + gid.y) * width + gid.x]. -/
def flatIndex3D (gid_x gid_y gid_z width height : Nat) : Nat :=
  gid_z * (width * height) + flatIndex2D gid_x gid_y width

/-- Flat 3D index is in bounds when all three gid components are independently
    bounded by the dispatched 3D extent. -/
theorem flat_index_3d_inbounds
    (gid_x gid_y gid_z width height depth : Nat)
    (h_x : gid_x < width)
    (h_y : gid_y < height)
    (h_z : gid_z < depth) :
    flatIndex3D gid_x gid_y gid_z width height < width * height * depth := by
  have h_plane_lt : flatIndex2D gid_x gid_y width < width * height := by
    exact flat_index_2d_inbounds gid_x gid_y width height h_x h_y
  unfold flatIndex3D
  have h_row :
      gid_z * (width * height) + flatIndex2D gid_x gid_y width <
      gid_z * (width * height) + (width * height) := by
    exact Nat.add_lt_add_left h_plane_lt (gid_z * (width * height))
  have h_step :
      gid_z * (width * height) + (width * height) = (gid_z + 1) * (width * height) := by
    simpa using (Nat.succ_mul gid_z (width * height)).symm
  have h_depth :
      (gid_z + 1) * (width * height) ≤ depth * (width * height) := by
    exact Nat.mul_le_mul_right (width * height) (Nat.succ_le_of_lt h_z)
  calc
    gid_z * (width * height) + flatIndex2D gid_x gid_y width <
        gid_z * (width * height) + (width * height) := h_row
    _ = (gid_z + 1) * (width * height) := h_step
    _ ≤ depth * (width * height) := h_depth
    _ = width * height * depth := by
      simp [Nat.mul_assoc, Nat.mul_comm, Nat.mul_left_comm]

/-- Flat 3D index with an additional constant offset. This captures volume
    kernels that reserve a prefix region before the dispatch-visible window. -/
theorem flat_index_3d_plus_offset_inbounds
    (gid_x gid_y gid_z width height depth offset array_length : Nat)
    (h_x : gid_x < width)
    (h_y : gid_y < height)
    (h_z : gid_z < depth)
    (h_fit : width * height * depth + offset ≤ array_length) :
    flatIndex3D gid_x gid_y gid_z width height + offset < array_length := by
  have h_flat_lt : flatIndex3D gid_x gid_y gid_z width height < width * height * depth := by
    exact flat_index_3d_inbounds gid_x gid_y gid_z width height depth h_x h_y h_z
  have h_offset_lt :
      flatIndex3D gid_x gid_y gid_z width height + offset < width * height * depth + offset := by
    exact Nat.add_lt_add_right h_flat_lt offset
  calc
    flatIndex3D gid_x gid_y gid_z width height + offset < width * height * depth + offset := h_offset_lt
    _ ≤ array_length := h_fit

/-- Early-return texture guard for 2D gid coordinates. If the shader exits when
    either coordinate is out of range, any surviving execution has both
    coordinates strictly below the texture dimensions. This is the proof-backed
    bridge for eliding texture coordinate clamp insertion. -/
theorem guarded_gid_texture_coords_2d_inbounds
    (gid_x gid_y width height : Nat)
    (h_guard : ¬ (gid_x ≥ width ∨ gid_y ≥ height)) :
    gid_x < width ∧ gid_y < height := by
  omega

/-- 3D extension of the early-return texture guard theorem. -/
theorem guarded_gid_texture_coords_3d_inbounds
    (gid_x gid_y gid_z width height depth : Nat)
    (h_guard : ¬ (gid_x ≥ width ∨ gid_y ≥ height ∨ gid_z ≥ depth)) :
    gid_x < width ∧ gid_y < height ∧ gid_z < depth := by
  omega

/-- 3D dispatch-fit version of the texture coordinate proof. -/
theorem gid_texture_coords_3d_inbounds_when_dispatch_fits
    (wid_x lid_x ws_x nwg_x width : Nat)
    (wid_y lid_y ws_y nwg_y height : Nat)
    (wid_z lid_z ws_z nwg_z depth : Nat)
    (h_wid_x : wid_x < nwg_x) (h_lid_x : lid_x < ws_x)
    (h_wid_y : wid_y < nwg_y) (h_lid_y : lid_y < ws_y)
    (h_wid_z : wid_z < nwg_z) (h_lid_z : lid_z < ws_z)
    (h_fit_x : ws_x * nwg_x ≤ width)
    (h_fit_y : ws_y * nwg_y ≤ height)
    (h_fit_z : ws_z * nwg_z ≤ depth) :
    globalInvocationId wid_x lid_x ws_x < width ∧
    globalInvocationId wid_y lid_y ws_y < height ∧
    globalInvocationId wid_z lid_z ws_z < depth := by
  refine ⟨?_, ?_, ?_⟩
  exact gid_component_lt_total wid_x lid_x ws_x nwg_x width h_wid_x h_lid_x h_fit_x
  exact gid_component_lt_total wid_y lid_y ws_y nwg_y height h_wid_y h_lid_y h_fit_y
  exact gid_component_lt_total wid_z lid_z ws_z nwg_z depth h_wid_z h_lid_z h_fit_z

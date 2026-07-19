-- Texture sample-level integer coordinate bounds elimination theorems.
-- Mirrors: runtime/zig/src/compiler/wgsl/ir/ir_transform_robustness.zig
--
-- Proves that integer texture coordinates derived from global_invocation_id
-- are within texture dimensions when the dispatch grid fits, so the
-- robustness transform's coordinate clamp can be eliminated.
--
-- While textureSampleLevel itself uses float coordinates, a common compute
-- shader pattern converts integer global_invocation_id components to texture
-- coordinates for textureLoad/textureStore. This module proves that integer
-- coordinates from gid are strictly bounded by texture dimensions under
-- dispatch-fit preconditions, enabling the min()/clamp() injection to be
-- skipped entirely.
--
-- Layer 1 (Zig): clamp ALL integer texture coordinates unconditionally.
-- Layer 2 (Lean -> Zig): this module proves conditions under which the clamp
-- is provably unnecessary for texture coordinate patterns.
--
-- Integration: build.zig reads proven-conditions.json (-Dlean-verified=true),
-- lean_proof.zig validates at comptime, ir_transform_robustness.zig consults
-- the proof status to skip clamping for matched patterns.

import Doe.Shader.ComputeBounds

/-- Integer texture coordinate for a single axis, derived from global_invocation_id.
    This is the identity case: the coordinate is exactly the gid component. -/
def texCoordFromGid (workgroup_id local_id workgroup_size : Nat) : Nat :=
  globalInvocationId workgroup_id local_id workgroup_size

/-- Core single-axis theorem: an integer texture coordinate derived from
    global_invocation_id is strictly less than the texture dimension when the
    dispatch grid fits the texture extent.

    Preconditions (enforced at dispatch time by host-side check):
    - workgroup_id < num_workgroups   (GPU hardware guarantee)
    - local_id < workgroup_size       (GPU hardware guarantee)
    - workgroup_size * num_workgroups <= texture_dim  (host-side precondition)

    This is `lean_required`: it quantifies over arbitrary Nat values and
    cannot be replicated by comptime enumeration. -/
theorem tex_coord_lt_dim_when_dispatch_fits
    (workgroup_id local_id workgroup_size num_workgroups texture_dim : Nat)
    (h_wid : workgroup_id < num_workgroups)
    (h_lid : local_id < workgroup_size)
    (h_fit : workgroup_size * num_workgroups ≤ texture_dim) :
    texCoordFromGid workgroup_id local_id workgroup_size < texture_dim := by
  unfold texCoordFromGid
  exact gid_component_lt_total workgroup_id local_id workgroup_size num_workgroups texture_dim
    h_wid h_lid h_fit

/-- Dispatch-fit theorem for 1D gid-derived texture coordinates.
    This is the scalar texture analogue of the 2D/3D gid-coordinate theorems
    extracted from ComputeBounds.lean. -/
theorem gid_texture_coord_1d_inbounds_when_dispatch_fits
    (workgroup_id local_id workgroup_size num_workgroups texture_dim : Nat)
    (h_wid : workgroup_id < num_workgroups)
    (h_lid : local_id < workgroup_size)
    (h_fit : workgroup_size * num_workgroups ≤ texture_dim) :
    texCoordFromGid workgroup_id local_id workgroup_size < texture_dim := by
  exact tex_coord_lt_dim_when_dispatch_fits
    workgroup_id local_id workgroup_size num_workgroups texture_dim
    h_wid h_lid h_fit

/-- The clamp min(coord, dim-1) is a no-op when coord < dim.
    This connects the proof to the robustness transform: if the condition holds,
    min(coord, dim-1) = coord, so the injected clamp has no runtime effect
    and can be elided entirely. -/
theorem tex_clamp_noop_when_inbounds
    (coord dim : Nat)
    (h_pos : 0 < dim)
    (h_bound : coord < dim) :
    min coord (dim - 1) = coord := by
  omega

/-- Combined single-axis elimination: if the dispatch grid fits the texture
    dimension, then the coordinate clamp min(gid, dim-1) = gid. This is the
    composition that ir_transform_robustness.zig pattern-matches against. -/
theorem tex_sample_coord_clamp_elim_1d
    (workgroup_id local_id workgroup_size num_workgroups texture_dim : Nat)
    (h_wid : workgroup_id < num_workgroups)
    (h_lid : local_id < workgroup_size)
    (h_fit : workgroup_size * num_workgroups ≤ texture_dim)
    (h_pos : 0 < texture_dim) :
    min (texCoordFromGid workgroup_id local_id workgroup_size) (texture_dim - 1) =
    texCoordFromGid workgroup_id local_id workgroup_size := by
  have h_lt := tex_coord_lt_dim_when_dispatch_fits
    workgroup_id local_id workgroup_size num_workgroups texture_dim
    h_wid h_lid h_fit
  exact tex_clamp_noop_when_inbounds
    (texCoordFromGid workgroup_id local_id workgroup_size) texture_dim h_pos h_lt

/-- 2D texture coordinate bounds. For textureSampleLevel with integer
    coordinates derived from global_invocation_id.xy on a 2D texture,
    both components are strictly less than the texture dimensions when the
    dispatch grid fits. -/
theorem tex_sample_coords_2d_inbounds_when_dispatch_fits
    (wid_x lid_x ws_x nwg_x width : Nat)
    (wid_y lid_y ws_y nwg_y height : Nat)
    (h_wid_x : wid_x < nwg_x) (h_lid_x : lid_x < ws_x)
    (h_wid_y : wid_y < nwg_y) (h_lid_y : lid_y < ws_y)
    (h_fit_x : ws_x * nwg_x ≤ width)
    (h_fit_y : ws_y * nwg_y ≤ height) :
    texCoordFromGid wid_x lid_x ws_x < width ∧
    texCoordFromGid wid_y lid_y ws_y < height := by
  unfold texCoordFromGid
  exact gid_2d_inbounds wid_x lid_x ws_x nwg_x width wid_y lid_y ws_y nwg_y height
    h_wid_x h_lid_x h_wid_y h_lid_y h_fit_x h_fit_y

/-- 2D clamp elimination. Both coordinate clamps are no-ops when the
    dispatch grid fits the texture dimensions. -/
theorem tex_sample_coord_clamp_elim_2d
    (wid_x lid_x ws_x nwg_x width : Nat)
    (wid_y lid_y ws_y nwg_y height : Nat)
    (h_wid_x : wid_x < nwg_x) (h_lid_x : lid_x < ws_x)
    (h_wid_y : wid_y < nwg_y) (h_lid_y : lid_y < ws_y)
    (h_fit_x : ws_x * nwg_x ≤ width)
    (h_fit_y : ws_y * nwg_y ≤ height)
    (h_pos_w : 0 < width)
    (h_pos_h : 0 < height) :
    min (texCoordFromGid wid_x lid_x ws_x) (width - 1) =
      texCoordFromGid wid_x lid_x ws_x ∧
    min (texCoordFromGid wid_y lid_y ws_y) (height - 1) =
      texCoordFromGid wid_y lid_y ws_y := by
  have ⟨h_x_lt, h_y_lt⟩ := tex_sample_coords_2d_inbounds_when_dispatch_fits
    wid_x lid_x ws_x nwg_x width wid_y lid_y ws_y nwg_y height
    h_wid_x h_lid_x h_wid_y h_lid_y h_fit_x h_fit_y
  exact ⟨tex_clamp_noop_when_inbounds _ _ h_pos_w h_x_lt,
         tex_clamp_noop_when_inbounds _ _ h_pos_h h_y_lt⟩

/-- 3D texture coordinate bounds for textureSampleLevel with integer
    coordinates derived from global_invocation_id.xyz. -/
theorem tex_sample_coords_3d_inbounds_when_dispatch_fits
    (wid_x lid_x ws_x nwg_x width : Nat)
    (wid_y lid_y ws_y nwg_y height : Nat)
    (wid_z lid_z ws_z nwg_z depth : Nat)
    (h_wid_x : wid_x < nwg_x) (h_lid_x : lid_x < ws_x)
    (h_wid_y : wid_y < nwg_y) (h_lid_y : lid_y < ws_y)
    (h_wid_z : wid_z < nwg_z) (h_lid_z : lid_z < ws_z)
    (h_fit_x : ws_x * nwg_x ≤ width)
    (h_fit_y : ws_y * nwg_y ≤ height)
    (h_fit_z : ws_z * nwg_z ≤ depth) :
    texCoordFromGid wid_x lid_x ws_x < width ∧
    texCoordFromGid wid_y lid_y ws_y < height ∧
    texCoordFromGid wid_z lid_z ws_z < depth := by
  unfold texCoordFromGid
  refine ⟨?_, ?_, ?_⟩
  exact gid_component_lt_total wid_x lid_x ws_x nwg_x width h_wid_x h_lid_x h_fit_x
  exact gid_component_lt_total wid_y lid_y ws_y nwg_y height h_wid_y h_lid_y h_fit_y
  exact gid_component_lt_total wid_z lid_z ws_z nwg_z depth h_wid_z h_lid_z h_fit_z

/-- 3D clamp elimination. All three coordinate clamps are no-ops when the
    dispatch grid fits the texture dimensions. -/
theorem tex_sample_coord_clamp_elim_3d
    (wid_x lid_x ws_x nwg_x width : Nat)
    (wid_y lid_y ws_y nwg_y height : Nat)
    (wid_z lid_z ws_z nwg_z depth : Nat)
    (h_wid_x : wid_x < nwg_x) (h_lid_x : lid_x < ws_x)
    (h_wid_y : wid_y < nwg_y) (h_lid_y : lid_y < ws_y)
    (h_wid_z : wid_z < nwg_z) (h_lid_z : lid_z < ws_z)
    (h_fit_x : ws_x * nwg_x ≤ width)
    (h_fit_y : ws_y * nwg_y ≤ height)
    (h_fit_z : ws_z * nwg_z ≤ depth)
    (h_pos_w : 0 < width)
    (h_pos_h : 0 < height)
    (h_pos_d : 0 < depth) :
    min (texCoordFromGid wid_x lid_x ws_x) (width - 1) =
      texCoordFromGid wid_x lid_x ws_x ∧
    min (texCoordFromGid wid_y lid_y ws_y) (height - 1) =
      texCoordFromGid wid_y lid_y ws_y ∧
    min (texCoordFromGid wid_z lid_z ws_z) (depth - 1) =
      texCoordFromGid wid_z lid_z ws_z := by
  have ⟨h_x_lt, h_y_lt, h_z_lt⟩ := tex_sample_coords_3d_inbounds_when_dispatch_fits
    wid_x lid_x ws_x nwg_x width wid_y lid_y ws_y nwg_y height wid_z lid_z ws_z nwg_z depth
    h_wid_x h_lid_x h_wid_y h_lid_y h_wid_z h_lid_z h_fit_x h_fit_y h_fit_z
  exact ⟨tex_clamp_noop_when_inbounds _ _ h_pos_w h_x_lt,
         tex_clamp_noop_when_inbounds _ _ h_pos_h h_y_lt,
         tex_clamp_noop_when_inbounds _ _ h_pos_d h_z_lt⟩

/-- Affine texture coordinate: gid * stride + offset. For a tiled or strided
    texture access pattern where coordinates are scaled from gid. -/
theorem tex_sample_affine_coord_inbounds_when_dispatch_fits
    (workgroup_id local_id workgroup_size num_workgroups texture_dim stride offset : Nat)
    (h_stride : 0 < stride)
    (h_wid : workgroup_id < num_workgroups)
    (h_lid : local_id < workgroup_size)
    (h_fit : (workgroup_size * num_workgroups) * stride + offset ≤ texture_dim) :
    texCoordFromGid workgroup_id local_id workgroup_size * stride + offset < texture_dim := by
  unfold texCoordFromGid
  exact gid_times_stride_plus_offset_inbounds_when_dispatch_fits
    workgroup_id local_id workgroup_size num_workgroups texture_dim stride offset
    h_stride h_wid h_lid h_fit

/-- 1D affine gid-derived texture coordinates remain in bounds when the
    dispatch grid fits the validated extent. -/
theorem gid_texture_coord_1d_affine_inbounds_when_dispatch_fits
    (workgroup_id local_id workgroup_size num_workgroups texture_dim stride offset : Nat)
    (h_stride : 0 < stride)
    (h_wid : workgroup_id < num_workgroups)
    (h_lid : local_id < workgroup_size)
    (h_fit : (workgroup_size * num_workgroups) * stride + offset ≤ texture_dim) :
    texCoordFromGid workgroup_id local_id workgroup_size * stride + offset < texture_dim := by
  exact tex_sample_affine_coord_inbounds_when_dispatch_fits
    workgroup_id local_id workgroup_size num_workgroups texture_dim stride offset
    h_stride h_wid h_lid h_fit

/-- 2D affine gid-derived texture coordinates remain componentwise in bounds
    when each dispatched axis fits the validated texture extent. -/
theorem gid_texture_coords_2d_affine_inbounds_when_dispatch_fits
    (wid_x lid_x ws_x nwg_x width stride_x offset_x : Nat)
    (wid_y lid_y ws_y nwg_y height stride_y offset_y : Nat)
    (h_stride_x : 0 < stride_x)
    (h_stride_y : 0 < stride_y)
    (h_wid_x : wid_x < nwg_x) (h_lid_x : lid_x < ws_x)
    (h_wid_y : wid_y < nwg_y) (h_lid_y : lid_y < ws_y)
    (h_fit_x : (ws_x * nwg_x) * stride_x + offset_x ≤ width)
    (h_fit_y : (ws_y * nwg_y) * stride_y + offset_y ≤ height) :
    texCoordFromGid wid_x lid_x ws_x * stride_x + offset_x < width ∧
    texCoordFromGid wid_y lid_y ws_y * stride_y + offset_y < height := by
  exact ⟨gid_texture_coord_1d_affine_inbounds_when_dispatch_fits
            wid_x lid_x ws_x nwg_x width stride_x offset_x
            h_stride_x h_wid_x h_lid_x h_fit_x,
         gid_texture_coord_1d_affine_inbounds_when_dispatch_fits
            wid_y lid_y ws_y nwg_y height stride_y offset_y
            h_stride_y h_wid_y h_lid_y h_fit_y⟩

/-- 3D affine gid-derived texture coordinates remain componentwise in bounds
    when each dispatched axis fits the validated texture extent. -/
theorem gid_texture_coords_3d_affine_inbounds_when_dispatch_fits
    (wid_x lid_x ws_x nwg_x width stride_x offset_x : Nat)
    (wid_y lid_y ws_y nwg_y height stride_y offset_y : Nat)
    (wid_z lid_z ws_z nwg_z depth stride_z offset_z : Nat)
    (h_stride_x : 0 < stride_x)
    (h_stride_y : 0 < stride_y)
    (h_stride_z : 0 < stride_z)
    (h_wid_x : wid_x < nwg_x) (h_lid_x : lid_x < ws_x)
    (h_wid_y : wid_y < nwg_y) (h_lid_y : lid_y < ws_y)
    (h_wid_z : wid_z < nwg_z) (h_lid_z : lid_z < ws_z)
    (h_fit_x : (ws_x * nwg_x) * stride_x + offset_x ≤ width)
    (h_fit_y : (ws_y * nwg_y) * stride_y + offset_y ≤ height)
    (h_fit_z : (ws_z * nwg_z) * stride_z + offset_z ≤ depth) :
    texCoordFromGid wid_x lid_x ws_x * stride_x + offset_x < width ∧
    texCoordFromGid wid_y lid_y ws_y * stride_y + offset_y < height ∧
    texCoordFromGid wid_z lid_z ws_z * stride_z + offset_z < depth := by
  exact ⟨gid_texture_coord_1d_affine_inbounds_when_dispatch_fits
            wid_x lid_x ws_x nwg_x width stride_x offset_x
            h_stride_x h_wid_x h_lid_x h_fit_x,
         gid_texture_coord_1d_affine_inbounds_when_dispatch_fits
            wid_y lid_y ws_y nwg_y height stride_y offset_y
            h_stride_y h_wid_y h_lid_y h_fit_y,
         gid_texture_coord_1d_affine_inbounds_when_dispatch_fits
            wid_z lid_z ws_z nwg_z depth stride_z offset_z
            h_stride_z h_wid_z h_lid_z h_fit_z⟩

/-- 1D tiled gid-derived texture coordinates remain in bounds when the host
    validates the tiled groups against the texture extent. -/
theorem gid_texture_coord_1d_tiled_inbounds_when_dispatch_fits
    (workgroup_id local_id workgroup_size num_workgroups texture_dim tile_width tile_stride offset : Nat)
    (h_tile_width : 0 < tile_width)
    (h_tile_fit : tile_width ≤ tile_stride)
    (h_wid : workgroup_id < num_workgroups)
    (h_lid : local_id < workgroup_size)
    (h_fit : (((workgroup_size * num_workgroups - 1) / tile_width) + 1) * tile_stride + offset ≤ texture_dim) :
    (texCoordFromGid workgroup_id local_id workgroup_size / tile_width) * tile_stride +
      (texCoordFromGid workgroup_id local_id workgroup_size % tile_width) + offset < texture_dim := by
  unfold texCoordFromGid
  exact gid_tiled_index_plus_offset_inbounds_when_dispatch_fits
    workgroup_id local_id workgroup_size num_workgroups texture_dim tile_width tile_stride offset
    h_tile_width h_tile_fit h_wid h_lid h_fit

/-- 2D tiled gid-derived texture coordinates remain componentwise in bounds
    when each tiled axis fits the validated texture extent. -/
theorem gid_texture_coords_2d_tiled_inbounds_when_dispatch_fits
    (wid_x lid_x ws_x nwg_x width tile_width_x tile_stride_x offset_x : Nat)
    (wid_y lid_y ws_y nwg_y height tile_width_y tile_stride_y offset_y : Nat)
    (h_tile_width_x : 0 < tile_width_x)
    (h_tile_width_y : 0 < tile_width_y)
    (h_tile_fit_x : tile_width_x ≤ tile_stride_x)
    (h_tile_fit_y : tile_width_y ≤ tile_stride_y)
    (h_wid_x : wid_x < nwg_x) (h_lid_x : lid_x < ws_x)
    (h_wid_y : wid_y < nwg_y) (h_lid_y : lid_y < ws_y)
    (h_fit_x : (((ws_x * nwg_x - 1) / tile_width_x) + 1) * tile_stride_x + offset_x ≤ width)
    (h_fit_y : (((ws_y * nwg_y - 1) / tile_width_y) + 1) * tile_stride_y + offset_y ≤ height) :
    (texCoordFromGid wid_x lid_x ws_x / tile_width_x) * tile_stride_x +
      (texCoordFromGid wid_x lid_x ws_x % tile_width_x) + offset_x < width ∧
    (texCoordFromGid wid_y lid_y ws_y / tile_width_y) * tile_stride_y +
      (texCoordFromGid wid_y lid_y ws_y % tile_width_y) + offset_y < height := by
  exact ⟨gid_texture_coord_1d_tiled_inbounds_when_dispatch_fits
            wid_x lid_x ws_x nwg_x width tile_width_x tile_stride_x offset_x
            h_tile_width_x h_tile_fit_x h_wid_x h_lid_x h_fit_x,
         gid_texture_coord_1d_tiled_inbounds_when_dispatch_fits
            wid_y lid_y ws_y nwg_y height tile_width_y tile_stride_y offset_y
            h_tile_width_y h_tile_fit_y h_wid_y h_lid_y h_fit_y⟩

/-- 3D tiled gid-derived texture coordinates remain componentwise in bounds
    when each tiled axis fits the validated texture extent. -/
theorem gid_texture_coords_3d_tiled_inbounds_when_dispatch_fits
    (wid_x lid_x ws_x nwg_x width tile_width_x tile_stride_x offset_x : Nat)
    (wid_y lid_y ws_y nwg_y height tile_width_y tile_stride_y offset_y : Nat)
    (wid_z lid_z ws_z nwg_z depth tile_width_z tile_stride_z offset_z : Nat)
    (h_tile_width_x : 0 < tile_width_x)
    (h_tile_width_y : 0 < tile_width_y)
    (h_tile_width_z : 0 < tile_width_z)
    (h_tile_fit_x : tile_width_x ≤ tile_stride_x)
    (h_tile_fit_y : tile_width_y ≤ tile_stride_y)
    (h_tile_fit_z : tile_width_z ≤ tile_stride_z)
    (h_wid_x : wid_x < nwg_x) (h_lid_x : lid_x < ws_x)
    (h_wid_y : wid_y < nwg_y) (h_lid_y : lid_y < ws_y)
    (h_wid_z : wid_z < nwg_z) (h_lid_z : lid_z < ws_z)
    (h_fit_x : (((ws_x * nwg_x - 1) / tile_width_x) + 1) * tile_stride_x + offset_x ≤ width)
    (h_fit_y : (((ws_y * nwg_y - 1) / tile_width_y) + 1) * tile_stride_y + offset_y ≤ height)
    (h_fit_z : (((ws_z * nwg_z - 1) / tile_width_z) + 1) * tile_stride_z + offset_z ≤ depth) :
    (texCoordFromGid wid_x lid_x ws_x / tile_width_x) * tile_stride_x +
      (texCoordFromGid wid_x lid_x ws_x % tile_width_x) + offset_x < width ∧
    (texCoordFromGid wid_y lid_y ws_y / tile_width_y) * tile_stride_y +
      (texCoordFromGid wid_y lid_y ws_y % tile_width_y) + offset_y < height ∧
    (texCoordFromGid wid_z lid_z ws_z / tile_width_z) * tile_stride_z +
      (texCoordFromGid wid_z lid_z ws_z % tile_width_z) + offset_z < depth := by
  exact ⟨gid_texture_coord_1d_tiled_inbounds_when_dispatch_fits
            wid_x lid_x ws_x nwg_x width tile_width_x tile_stride_x offset_x
            h_tile_width_x h_tile_fit_x h_wid_x h_lid_x h_fit_x,
         gid_texture_coord_1d_tiled_inbounds_when_dispatch_fits
            wid_y lid_y ws_y nwg_y height tile_width_y tile_stride_y offset_y
            h_tile_width_y h_tile_fit_y h_wid_y h_lid_y h_fit_y,
         gid_texture_coord_1d_tiled_inbounds_when_dispatch_fits
            wid_z lid_z ws_z nwg_z depth tile_width_z tile_stride_z offset_z
            h_tile_width_z h_tile_fit_z h_wid_z h_lid_z h_fit_z⟩

/-- Early-return guard theorem for 2D texture sample coordinates. When the shader
    has `if gid.x >= width || gid.y >= height { return; }`, surviving invocations
    have both coordinates strictly in bounds. -/
theorem guarded_tex_sample_coords_2d_inbounds
    (coord_x coord_y width height : Nat)
    (h_guard : ¬ (coord_x ≥ width ∨ coord_y ≥ height)) :
    coord_x < width ∧ coord_y < height := by
  omega

/-- Mip-level texture dimension reduction. If the base-level dimension is `d`,
    mip level `n` has dimension `max(d / 2^n, 1)`. When the dispatch grid fits
    the mip-level dimension, integer coordinates from gid are in bounds. -/
theorem tex_sample_mip_coord_inbounds
    (workgroup_id local_id workgroup_size num_workgroups base_dim mip_level : Nat)
    (h_wid : workgroup_id < num_workgroups)
    (h_lid : local_id < workgroup_size)
    (h_mip_pos : 0 < max (base_dim / 2 ^ mip_level) 1)
    (h_fit : workgroup_size * num_workgroups ≤ max (base_dim / 2 ^ mip_level) 1) :
    texCoordFromGid workgroup_id local_id workgroup_size <
      max (base_dim / 2 ^ mip_level) 1 := by
  unfold texCoordFromGid
  exact gid_component_lt_total workgroup_id local_id workgroup_size num_workgroups
    (max (base_dim / 2 ^ mip_level) 1) h_wid h_lid h_fit

/-- Mip-level clamp elimination. The coordinate clamp at a given mip level
    is a no-op when dispatch fits the mip-level dimension. -/
theorem tex_sample_mip_clamp_elim
    (workgroup_id local_id workgroup_size num_workgroups base_dim mip_level : Nat)
    (h_wid : workgroup_id < num_workgroups)
    (h_lid : local_id < workgroup_size)
    (h_mip_pos : 0 < max (base_dim / 2 ^ mip_level) 1)
    (h_fit : workgroup_size * num_workgroups ≤ max (base_dim / 2 ^ mip_level) 1) :
    min (texCoordFromGid workgroup_id local_id workgroup_size)
        (max (base_dim / 2 ^ mip_level) 1 - 1) =
    texCoordFromGid workgroup_id local_id workgroup_size := by
  have h_lt := tex_sample_mip_coord_inbounds
    workgroup_id local_id workgroup_size num_workgroups base_dim mip_level
    h_wid h_lid h_mip_pos h_fit
  exact tex_clamp_noop_when_inbounds _ _ h_mip_pos h_lt

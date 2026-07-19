-- Doe/Shader/BoundsElisionMatcher.lean
--
-- Matcher-facing proof contract for proof-backed bounds elision.
-- Mirrors: runtime/zig/src/compiler/wgsl/proof/dispatch_proof_match.zig
-- Classification: lean_required.

import Doe.Shader.ComputeBounds
import Doe.Shader.TextureSampleBounds

/-- Axis tag for the small matcher-side expression contract. -/
inductive BoundsMatcherAxis where
  | x
  | y
  | z

/-- Dispatch values for one axis. The GPU provides the workgroup/local bounds;
    the host validates dispatch extent fit against the target resource. -/
structure BoundsMatcherAxisDispatch where
  workgroupId : Nat
  localId : Nat
  workgroupSize : Nat
  numWorkgroups : Nat

def BoundsMatcherAxisDispatch.gid (dispatch : BoundsMatcherAxisDispatch) : Nat :=
  globalInvocationId dispatch.workgroupId dispatch.localId dispatch.workgroupSize

/-- Per-axis dispatch environment for evaluating matcher expressions. -/
structure BoundsMatcherEnv where
  x : BoundsMatcherAxisDispatch
  y : BoundsMatcherAxisDispatch
  z : BoundsMatcherAxisDispatch

def BoundsMatcherEnv.axisDispatch
    (env : BoundsMatcherEnv) : BoundsMatcherAxis → BoundsMatcherAxisDispatch
  | .x => env.x
  | .y => env.y
  | .z => env.z

/-- Minimal expression grammar covered by the stride+offset matcher:
    gid component, integer literals, commutative addition, and
    commutative multiplication by a literal. -/
inductive BoundsMatcherExpr where
  | gid (axis : BoundsMatcherAxis)
  | loopIndex
  | lit (value : Nat)
  | add (lhs rhs : BoundsMatcherExpr)
  | mul (lhs rhs : BoundsMatcherExpr)
  | div (lhs rhs : BoundsMatcherExpr)
  | rem (lhs rhs : BoundsMatcherExpr)

def evalBoundsMatcherExpr (env : BoundsMatcherEnv) (loopIndex : Nat) : BoundsMatcherExpr → Nat
  | .gid axis => (env.axisDispatch axis).gid
  | .loopIndex => loopIndex
  | .lit value => value
  | .add lhs rhs => evalBoundsMatcherExpr env loopIndex lhs + evalBoundsMatcherExpr env loopIndex rhs
  | .mul lhs rhs => evalBoundsMatcherExpr env loopIndex lhs * evalBoundsMatcherExpr env loopIndex rhs
  | .div lhs rhs => evalBoundsMatcherExpr env loopIndex lhs / evalBoundsMatcherExpr env loopIndex rhs
  | .rem lhs rhs => evalBoundsMatcherExpr env loopIndex lhs % evalBoundsMatcherExpr env loopIndex rhs

/-- Contract for `match_gid_component_times_stride_plus_offset`.
    It accepts `gid * stride` or `stride * gid`, optionally plus one literal
    offset on either side. The stride is positive because the Zig matcher
    rejects zero multipliers. -/
inductive MatchesGidStrideOffset :
    BoundsMatcherExpr → BoundsMatcherAxis → Nat → Nat → Prop where
  | mul_gid_lit
      (axis : BoundsMatcherAxis)
      (stride : Nat)
      (h_stride : 0 < stride) :
      MatchesGidStrideOffset
        (.mul (.gid axis) (.lit stride)) axis stride 0
  | mul_lit_gid
      (axis : BoundsMatcherAxis)
      (stride : Nat)
      (h_stride : 0 < stride) :
      MatchesGidStrideOffset
        (.mul (.lit stride) (.gid axis)) axis stride 0
  | add_offset_rhs
      {base : BoundsMatcherExpr}
      {axis : BoundsMatcherAxis}
      {stride offset : Nat}
      (h_base : MatchesGidStrideOffset base axis stride 0) :
      MatchesGidStrideOffset (.add base (.lit offset)) axis stride offset
  | add_offset_lhs
      {base : BoundsMatcherExpr}
      {axis : BoundsMatcherAxis}
      {stride offset : Nat}
      (h_base : MatchesGidStrideOffset base axis stride 0) :
      MatchesGidStrideOffset (.add (.lit offset) base) axis stride offset

theorem matches_gid_stride_offset_eval
    (env : BoundsMatcherEnv)
    {expr : BoundsMatcherExpr}
    {axis : BoundsMatcherAxis}
    {stride offset : Nat}
    (h_match : MatchesGidStrideOffset expr axis stride offset) :
    evalBoundsMatcherExpr env 0 expr =
      (env.axisDispatch axis).gid * stride + offset := by
  induction h_match with
  | mul_gid_lit axis stride h_stride =>
      simp [evalBoundsMatcherExpr, BoundsMatcherAxisDispatch.gid]
  | mul_lit_gid axis stride h_stride =>
      simp [evalBoundsMatcherExpr, BoundsMatcherAxisDispatch.gid, Nat.mul_comm]
  | add_offset_rhs h_base ih =>
      simp [evalBoundsMatcherExpr, ih, Nat.add_assoc]
  | add_offset_lhs h_base ih =>
      simp [evalBoundsMatcherExpr, ih, Nat.add_comm, Nat.add_left_comm, Nat.add_assoc]

theorem matches_gid_stride_offset_stride_pos
    {expr : BoundsMatcherExpr}
    {axis : BoundsMatcherAxis}
    {stride offset : Nat}
    (h_match : MatchesGidStrideOffset expr axis stride offset) :
    0 < stride := by
  induction h_match with
  | mul_gid_lit axis stride h_stride => exact h_stride
  | mul_lit_gid axis stride h_stride => exact h_stride
  | add_offset_rhs h_base ih => exact ih
  | add_offset_lhs h_base ih => exact ih

/-- Matcher contract soundness for the existing storage-buffer pattern
    `gid_1d_storage_buffer_stride`.

    If the matcher accepts an expression as `gid.{axis} * stride + offset`,
    the GPU-provided invocation bounds and the host-side dispatch-fit
    precondition are enough to prove the evaluated index is in bounds. -/
theorem gid_stride_offset_matcher_contract_sound
    (env : BoundsMatcherEnv)
    (expr : BoundsMatcherExpr)
    (axis : BoundsMatcherAxis)
    (stride offset array_length : Nat)
    (h_match : MatchesGidStrideOffset expr axis stride offset)
    (h_wid :
      (env.axisDispatch axis).workgroupId <
        (env.axisDispatch axis).numWorkgroups)
    (h_lid :
      (env.axisDispatch axis).localId <
        (env.axisDispatch axis).workgroupSize)
    (h_fit :
      ((env.axisDispatch axis).workgroupSize *
          (env.axisDispatch axis).numWorkgroups) *
          stride + offset ≤ array_length) :
    evalBoundsMatcherExpr env 0 expr < array_length := by
  have h_eval := matches_gid_stride_offset_eval env h_match
  have h_stride := matches_gid_stride_offset_stride_pos h_match
  rw [h_eval]
  exact gid_times_stride_plus_offset_inbounds_when_dispatch_fits
    (env.axisDispatch axis).workgroupId
    (env.axisDispatch axis).localId
    (env.axisDispatch axis).workgroupSize
    (env.axisDispatch axis).numWorkgroups
    array_length
    stride
    offset
    h_stride
    h_wid
    h_lid
    h_fit

/-- Contract for `match_gid_component_plus_offset`.
    It accepts `gid` plus one literal offset on either side. -/
inductive MatchesGidOffset :
    BoundsMatcherExpr → BoundsMatcherAxis → Nat → Prop where
  | add_offset_rhs
      (axis : BoundsMatcherAxis)
      (offset : Nat) :
      MatchesGidOffset (.add (.gid axis) (.lit offset)) axis offset
  | add_offset_lhs
      (axis : BoundsMatcherAxis)
      (offset : Nat) :
      MatchesGidOffset (.add (.lit offset) (.gid axis)) axis offset

theorem matches_gid_offset_eval
    (env : BoundsMatcherEnv)
    {expr : BoundsMatcherExpr}
    {axis : BoundsMatcherAxis}
    {offset : Nat}
    (h_match : MatchesGidOffset expr axis offset) :
    evalBoundsMatcherExpr env 0 expr =
      (env.axisDispatch axis).gid + offset := by
  cases h_match <;> simp [evalBoundsMatcherExpr, BoundsMatcherAxisDispatch.gid, Nat.add_comm]

theorem gid_offset_matcher_contract_sound
    (env : BoundsMatcherEnv)
    (expr : BoundsMatcherExpr)
    (axis : BoundsMatcherAxis)
    (offset array_length : Nat)
    (h_match : MatchesGidOffset expr axis offset)
    (h_wid : (env.axisDispatch axis).workgroupId < (env.axisDispatch axis).numWorkgroups)
    (h_lid : (env.axisDispatch axis).localId < (env.axisDispatch axis).workgroupSize)
    (h_fit :
      (env.axisDispatch axis).workgroupSize *
          (env.axisDispatch axis).numWorkgroups + offset ≤ array_length) :
    evalBoundsMatcherExpr env 0 expr < array_length := by
  rw [matches_gid_offset_eval env h_match]
  exact gid_plus_offset_inbounds_when_dispatch_fits
    (env.axisDispatch axis).workgroupId
    (env.axisDispatch axis).localId
    (env.axisDispatch axis).workgroupSize
    (env.axisDispatch axis).numWorkgroups
    array_length
    offset
    h_wid
    h_lid
    h_fit

/-- Contract for the additive counted-loop matcher. The Zig matcher first
    collects one gid term, one loop-index term, optional constant offset, and
    positive multipliers for both dynamic terms. -/
inductive MatchesGidLoopAffine :
    BoundsMatcherExpr → BoundsMatcherAxis → Nat → Nat → Nat → Prop where
  | mk
      (axis : BoundsMatcherAxis)
      (gid_stride loop_stride offset : Nat)
      (h_gid_stride : 0 < gid_stride)
      (h_loop_stride : 0 < loop_stride) :
      MatchesGidLoopAffine
        (.add
          (.add
            (.mul (.gid axis) (.lit gid_stride))
            (.mul .loopIndex (.lit loop_stride)))
          (.lit offset))
        axis gid_stride loop_stride offset

theorem matches_gid_loop_affine_eval
    (env : BoundsMatcherEnv)
    (i : Nat)
    {expr : BoundsMatcherExpr}
    {axis : BoundsMatcherAxis}
    {gid_stride loop_stride offset : Nat}
    (h_match : MatchesGidLoopAffine expr axis gid_stride loop_stride offset) :
    evalBoundsMatcherExpr env i expr =
      (env.axisDispatch axis).gid * gid_stride + i * loop_stride + offset := by
  cases h_match
  simp [evalBoundsMatcherExpr, BoundsMatcherAxisDispatch.gid, Nat.add_assoc]

theorem matches_gid_loop_affine_gid_stride_pos
    {expr : BoundsMatcherExpr}
    {axis : BoundsMatcherAxis}
    {gid_stride loop_stride offset : Nat}
    (h_match : MatchesGidLoopAffine expr axis gid_stride loop_stride offset) :
    0 < gid_stride := by
  cases h_match
  assumption

theorem matches_gid_loop_affine_loop_stride_pos
    {expr : BoundsMatcherExpr}
    {axis : BoundsMatcherAxis}
    {gid_stride loop_stride offset : Nat}
    (h_match : MatchesGidLoopAffine expr axis gid_stride loop_stride offset) :
    0 < loop_stride := by
  cases h_match
  assumption

theorem gid_loop_offset_matcher_contract_sound
    (env : BoundsMatcherEnv)
    (expr : BoundsMatcherExpr)
    (axis : BoundsMatcherAxis)
    (limit i offset array_length : Nat)
    (h_match : MatchesGidLoopAffine expr axis 1 1 offset)
    (h_i : i < limit)
    (h_wid : (env.axisDispatch axis).workgroupId < (env.axisDispatch axis).numWorkgroups)
    (h_lid : (env.axisDispatch axis).localId < (env.axisDispatch axis).workgroupSize)
    (h_fit :
      (env.axisDispatch axis).workgroupSize *
          (env.axisDispatch axis).numWorkgroups + limit + offset ≤ array_length) :
    evalBoundsMatcherExpr env i expr < array_length := by
  rw [matches_gid_loop_affine_eval env i h_match]
  simp
  exact gid_plus_bounded_loop_index_inbounds_when_dispatch_fits
    (env.axisDispatch axis).workgroupId
    (env.axisDispatch axis).localId
    (env.axisDispatch axis).workgroupSize
    (env.axisDispatch axis).numWorkgroups
    array_length
    limit
    i
    offset
    h_i
    h_wid
    h_lid
    h_fit

theorem gid_loop_affine_matcher_contract_sound
    (env : BoundsMatcherEnv)
    (expr : BoundsMatcherExpr)
    (axis : BoundsMatcherAxis)
    (gid_stride limit i loop_stride offset array_length : Nat)
    (h_match : MatchesGidLoopAffine expr axis gid_stride loop_stride offset)
    (h_i : i < limit)
    (h_wid : (env.axisDispatch axis).workgroupId < (env.axisDispatch axis).numWorkgroups)
    (h_lid : (env.axisDispatch axis).localId < (env.axisDispatch axis).workgroupSize)
    (h_fit :
      (env.axisDispatch axis).workgroupSize *
          (env.axisDispatch axis).numWorkgroups * gid_stride +
          limit * loop_stride + offset ≤ array_length) :
    evalBoundsMatcherExpr env i expr < array_length := by
  rw [matches_gid_loop_affine_eval env i h_match]
  exact gid_affine_plus_scaled_loop_index_inbounds_when_dispatch_fits
    (env.axisDispatch axis).workgroupId
    (env.axisDispatch axis).localId
    (env.axisDispatch axis).workgroupSize
    (env.axisDispatch axis).numWorkgroups
    array_length
    gid_stride
    limit
    i
    loop_stride
    offset
    (matches_gid_loop_affine_gid_stride_pos h_match)
    (matches_gid_loop_affine_loop_stride_pos h_match)
    h_i
    h_wid
    h_lid
    h_fit

/-- Tight-precondition variant of `gid_loop_affine_matcher_contract_sound`.
    Uses the tightened Lean theorem so dispatches packed to exactly the
    maximum accessed index + 1 elements (e.g. the AMD Vulkan matvec 256 MB
    buffer) still pass the elision check. -/
theorem gid_loop_affine_matcher_contract_sound_tight
    (env : BoundsMatcherEnv)
    (expr : BoundsMatcherExpr)
    (axis : BoundsMatcherAxis)
    (gid_stride limit i loop_stride offset array_length : Nat)
    (h_match : MatchesGidLoopAffine expr axis gid_stride loop_stride offset)
    (h_i : i < limit)
    (h_wid : (env.axisDispatch axis).workgroupId < (env.axisDispatch axis).numWorkgroups)
    (h_lid : (env.axisDispatch axis).localId < (env.axisDispatch axis).workgroupSize)
    (h_fit :
      ((env.axisDispatch axis).workgroupSize *
            (env.axisDispatch axis).numWorkgroups - 1) * gid_stride +
          (limit - 1) * loop_stride + offset + 1 ≤ array_length) :
    evalBoundsMatcherExpr env i expr < array_length := by
  rw [matches_gid_loop_affine_eval env i h_match]
  exact gid_affine_plus_scaled_loop_index_inbounds_when_dispatch_fits_tight
    (env.axisDispatch axis).workgroupId
    (env.axisDispatch axis).localId
    (env.axisDispatch axis).workgroupSize
    (env.axisDispatch axis).numWorkgroups
    array_length
    gid_stride
    limit
    i
    loop_stride
    offset
    h_i
    h_wid
    h_lid
    h_fit

/-- Contract for the loop-only affine matcher: `i * loop_stride + offset`,
    with no gid term. This is the matvec inner-loop `vectorData[col]` pattern
    where the index is the pure loop induction variable plus a constant. -/
inductive MatchesLoopAffine :
    BoundsMatcherExpr → Nat → Nat → Prop where
  | mk
      (loop_stride offset : Nat)
      (h_loop_stride : 0 < loop_stride) :
      MatchesLoopAffine
        (.add
          (.mul .loopIndex (.lit loop_stride))
          (.lit offset))
        loop_stride offset

theorem matches_loop_affine_eval
    (env : BoundsMatcherEnv)
    (i : Nat)
    {expr : BoundsMatcherExpr}
    {loop_stride offset : Nat}
    (h_match : MatchesLoopAffine expr loop_stride offset) :
    evalBoundsMatcherExpr env i expr =
      i * loop_stride + offset := by
  cases h_match
  simp [evalBoundsMatcherExpr]

theorem matches_loop_affine_loop_stride_pos
    {expr : BoundsMatcherExpr}
    {loop_stride offset : Nat}
    (h_match : MatchesLoopAffine expr loop_stride offset) :
    0 < loop_stride := by
  cases h_match
  assumption

/-- Tight-precondition contract for the loop-only affine matcher.
    The runtime check uses the strict supremum + 1 formula
    `(limit - 1) * loop_stride + offset + 1 ≤ array_length`, matching
    `loop_index_affine_inbounds_when_loop_fits_tight`. -/
theorem loop_affine_matcher_contract_sound_tight
    (env : BoundsMatcherEnv)
    (expr : BoundsMatcherExpr)
    (limit i loop_stride offset array_length : Nat)
    (h_match : MatchesLoopAffine expr loop_stride offset)
    (h_i : i < limit)
    (h_fit :
      (limit - 1) * loop_stride + offset + 1 ≤ array_length) :
    evalBoundsMatcherExpr env i expr < array_length := by
  rw [matches_loop_affine_eval env i h_match]
  exact loop_index_affine_inbounds_when_loop_fits_tight
    array_length limit i loop_stride offset h_i h_fit

/-- Contract for the tiled matcher shape:
    `(gid / tile_width) * tile_stride + (gid % tile_width) + offset`. -/
inductive MatchesGidTiled :
    BoundsMatcherExpr → BoundsMatcherAxis → Nat → Nat → Nat → Prop where
  | mk
      (axis : BoundsMatcherAxis)
      (tile_width tile_stride offset : Nat)
      (h_tile_width : 0 < tile_width)
      (h_tile_stride : tile_width ≤ tile_stride) :
      MatchesGidTiled
        (.add
          (.add
            (.mul (.div (.gid axis) (.lit tile_width)) (.lit tile_stride))
            (.rem (.gid axis) (.lit tile_width)))
          (.lit offset))
        axis tile_width tile_stride offset

theorem matches_gid_tiled_eval
    (env : BoundsMatcherEnv)
    {expr : BoundsMatcherExpr}
    {axis : BoundsMatcherAxis}
    {tile_width tile_stride offset : Nat}
    (h_match : MatchesGidTiled expr axis tile_width tile_stride offset) :
    evalBoundsMatcherExpr env 0 expr =
      tiledIndex1D (env.axisDispatch axis).gid tile_width tile_stride + offset := by
  cases h_match
  simp [evalBoundsMatcherExpr, tiledIndex1D, BoundsMatcherAxisDispatch.gid, Nat.add_assoc]

theorem matches_gid_tiled_width_pos
    {expr : BoundsMatcherExpr}
    {axis : BoundsMatcherAxis}
    {tile_width tile_stride offset : Nat}
    (h_match : MatchesGidTiled expr axis tile_width tile_stride offset) :
    0 < tile_width := by
  cases h_match
  assumption

theorem matches_gid_tiled_stride_fit
    {expr : BoundsMatcherExpr}
    {axis : BoundsMatcherAxis}
    {tile_width tile_stride offset : Nat}
    (h_match : MatchesGidTiled expr axis tile_width tile_stride offset) :
    tile_width ≤ tile_stride := by
  cases h_match
  assumption

theorem gid_tiled_matcher_contract_sound
    (env : BoundsMatcherEnv)
    (expr : BoundsMatcherExpr)
    (axis : BoundsMatcherAxis)
    (tile_width tile_stride offset array_length : Nat)
    (h_match : MatchesGidTiled expr axis tile_width tile_stride offset)
    (h_wid : (env.axisDispatch axis).workgroupId < (env.axisDispatch axis).numWorkgroups)
    (h_lid : (env.axisDispatch axis).localId < (env.axisDispatch axis).workgroupSize)
    (h_fit :
      ((((env.axisDispatch axis).workgroupSize *
          (env.axisDispatch axis).numWorkgroups - 1) / tile_width) + 1) *
          tile_stride + offset ≤ array_length) :
    evalBoundsMatcherExpr env 0 expr < array_length := by
  rw [matches_gid_tiled_eval env h_match]
  exact gid_tiled_index_plus_offset_inbounds_when_dispatch_fits
    (env.axisDispatch axis).workgroupId
    (env.axisDispatch axis).localId
    (env.axisDispatch axis).workgroupSize
    (env.axisDispatch axis).numWorkgroups
    array_length
    tile_width
    tile_stride
    offset
    (matches_gid_tiled_width_pos h_match)
    (matches_gid_tiled_stride_fit h_match)
    h_wid
    h_lid
    h_fit

def flat2DMatcherIndex (env : BoundsMatcherEnv) (width : Nat) : Nat :=
  flatIndex2D env.x.gid env.y.gid width

def flat3DMatcherIndex (env : BoundsMatcherEnv) (width height : Nat) : Nat :=
  flatIndex3D env.x.gid env.y.gid env.z.gid width height

theorem flat_2d_matcher_contract_sound
    (env : BoundsMatcherEnv)
    (width height array_length : Nat)
    (h_wid_x : env.x.workgroupId < env.x.numWorkgroups)
    (h_lid_x : env.x.localId < env.x.workgroupSize)
    (h_wid_y : env.y.workgroupId < env.y.numWorkgroups)
    (h_lid_y : env.y.localId < env.y.workgroupSize)
    (h_fit_x : env.x.workgroupSize * env.x.numWorkgroups ≤ width)
    (h_fit_y : env.y.workgroupSize * env.y.numWorkgroups ≤ height)
    (h_fit_len : width * height ≤ array_length) :
    flat2DMatcherIndex env width < array_length := by
  have h_x := gid_component_lt_total env.x.workgroupId env.x.localId env.x.workgroupSize env.x.numWorkgroups width h_wid_x h_lid_x h_fit_x
  have h_y := gid_component_lt_total env.y.workgroupId env.y.localId env.y.workgroupSize env.y.numWorkgroups height h_wid_y h_lid_y h_fit_y
  unfold flat2DMatcherIndex
  exact Nat.lt_of_lt_of_le (flat_index_2d_inbounds env.x.gid env.y.gid width height h_x h_y) h_fit_len

theorem flat_2d_offset_matcher_contract_sound
    (env : BoundsMatcherEnv)
    (width height offset array_length : Nat)
    (h_wid_x : env.x.workgroupId < env.x.numWorkgroups)
    (h_lid_x : env.x.localId < env.x.workgroupSize)
    (h_wid_y : env.y.workgroupId < env.y.numWorkgroups)
    (h_lid_y : env.y.localId < env.y.workgroupSize)
    (h_fit_x : env.x.workgroupSize * env.x.numWorkgroups ≤ width)
    (h_fit_y : env.y.workgroupSize * env.y.numWorkgroups ≤ height)
    (h_fit_len : width * height + offset ≤ array_length) :
    flat2DMatcherIndex env width + offset < array_length := by
  have h_x := gid_component_lt_total env.x.workgroupId env.x.localId env.x.workgroupSize env.x.numWorkgroups width h_wid_x h_lid_x h_fit_x
  have h_y := gid_component_lt_total env.y.workgroupId env.y.localId env.y.workgroupSize env.y.numWorkgroups height h_wid_y h_lid_y h_fit_y
  unfold flat2DMatcherIndex
  exact flat_index_2d_plus_offset_inbounds env.x.gid env.y.gid width height offset array_length h_x h_y h_fit_len

theorem flat_3d_matcher_contract_sound
    (env : BoundsMatcherEnv)
    (width height depth array_length : Nat)
    (h_wid_x : env.x.workgroupId < env.x.numWorkgroups)
    (h_lid_x : env.x.localId < env.x.workgroupSize)
    (h_wid_y : env.y.workgroupId < env.y.numWorkgroups)
    (h_lid_y : env.y.localId < env.y.workgroupSize)
    (h_wid_z : env.z.workgroupId < env.z.numWorkgroups)
    (h_lid_z : env.z.localId < env.z.workgroupSize)
    (h_fit_x : env.x.workgroupSize * env.x.numWorkgroups ≤ width)
    (h_fit_y : env.y.workgroupSize * env.y.numWorkgroups ≤ height)
    (h_fit_z : env.z.workgroupSize * env.z.numWorkgroups ≤ depth)
    (h_fit_len : width * height * depth ≤ array_length) :
    flat3DMatcherIndex env width height < array_length := by
  have h_x := gid_component_lt_total env.x.workgroupId env.x.localId env.x.workgroupSize env.x.numWorkgroups width h_wid_x h_lid_x h_fit_x
  have h_y := gid_component_lt_total env.y.workgroupId env.y.localId env.y.workgroupSize env.y.numWorkgroups height h_wid_y h_lid_y h_fit_y
  have h_z := gid_component_lt_total env.z.workgroupId env.z.localId env.z.workgroupSize env.z.numWorkgroups depth h_wid_z h_lid_z h_fit_z
  unfold flat3DMatcherIndex
  exact Nat.lt_of_lt_of_le (flat_index_3d_inbounds env.x.gid env.y.gid env.z.gid width height depth h_x h_y h_z) h_fit_len

theorem flat_3d_offset_matcher_contract_sound
    (env : BoundsMatcherEnv)
    (width height depth offset array_length : Nat)
    (h_wid_x : env.x.workgroupId < env.x.numWorkgroups)
    (h_lid_x : env.x.localId < env.x.workgroupSize)
    (h_wid_y : env.y.workgroupId < env.y.numWorkgroups)
    (h_lid_y : env.y.localId < env.y.workgroupSize)
    (h_wid_z : env.z.workgroupId < env.z.numWorkgroups)
    (h_lid_z : env.z.localId < env.z.workgroupSize)
    (h_fit_x : env.x.workgroupSize * env.x.numWorkgroups ≤ width)
    (h_fit_y : env.y.workgroupSize * env.y.numWorkgroups ≤ height)
    (h_fit_z : env.z.workgroupSize * env.z.numWorkgroups ≤ depth)
    (h_fit_len : width * height * depth + offset ≤ array_length) :
    flat3DMatcherIndex env width height + offset < array_length := by
  have h_x := gid_component_lt_total env.x.workgroupId env.x.localId env.x.workgroupSize env.x.numWorkgroups width h_wid_x h_lid_x h_fit_x
  have h_y := gid_component_lt_total env.y.workgroupId env.y.localId env.y.workgroupSize env.y.numWorkgroups height h_wid_y h_lid_y h_fit_y
  have h_z := gid_component_lt_total env.z.workgroupId env.z.localId env.z.workgroupSize env.z.numWorkgroups depth h_wid_z h_lid_z h_fit_z
  unfold flat3DMatcherIndex
  exact flat_index_3d_plus_offset_inbounds env.x.gid env.y.gid env.z.gid width height depth offset array_length h_x h_y h_z h_fit_len

theorem texture_1d_identity_matcher_contract_sound
    (env : BoundsMatcherEnv)
    (width : Nat)
    (h_wid : env.x.workgroupId < env.x.numWorkgroups)
    (h_lid : env.x.localId < env.x.workgroupSize)
    (h_fit : env.x.workgroupSize * env.x.numWorkgroups ≤ width) :
    env.x.gid < width := by
  exact gid_texture_coord_1d_inbounds_when_dispatch_fits env.x.workgroupId env.x.localId env.x.workgroupSize env.x.numWorkgroups width h_wid h_lid h_fit

theorem texture_2d_identity_matcher_contract_sound
    (env : BoundsMatcherEnv)
    (width height : Nat)
    (h_wid_x : env.x.workgroupId < env.x.numWorkgroups)
    (h_lid_x : env.x.localId < env.x.workgroupSize)
    (h_wid_y : env.y.workgroupId < env.y.numWorkgroups)
    (h_lid_y : env.y.localId < env.y.workgroupSize)
    (h_fit_x : env.x.workgroupSize * env.x.numWorkgroups ≤ width)
    (h_fit_y : env.y.workgroupSize * env.y.numWorkgroups ≤ height) :
    env.x.gid < width ∧ env.y.gid < height := by
  exact gid_texture_coords_2d_inbounds_when_dispatch_fits
    env.x.workgroupId env.x.localId env.x.workgroupSize env.x.numWorkgroups width
    env.y.workgroupId env.y.localId env.y.workgroupSize env.y.numWorkgroups height
    h_wid_x h_lid_x h_wid_y h_lid_y h_fit_x h_fit_y

theorem texture_3d_identity_matcher_contract_sound
    (env : BoundsMatcherEnv)
    (width height depth : Nat)
    (h_wid_x : env.x.workgroupId < env.x.numWorkgroups)
    (h_lid_x : env.x.localId < env.x.workgroupSize)
    (h_wid_y : env.y.workgroupId < env.y.numWorkgroups)
    (h_lid_y : env.y.localId < env.y.workgroupSize)
    (h_wid_z : env.z.workgroupId < env.z.numWorkgroups)
    (h_lid_z : env.z.localId < env.z.workgroupSize)
    (h_fit_x : env.x.workgroupSize * env.x.numWorkgroups ≤ width)
    (h_fit_y : env.y.workgroupSize * env.y.numWorkgroups ≤ height)
    (h_fit_z : env.z.workgroupSize * env.z.numWorkgroups ≤ depth) :
    env.x.gid < width ∧ env.y.gid < height ∧ env.z.gid < depth := by
  exact gid_texture_coords_3d_inbounds_when_dispatch_fits
    env.x.workgroupId env.x.localId env.x.workgroupSize env.x.numWorkgroups width
    env.y.workgroupId env.y.localId env.y.workgroupSize env.y.numWorkgroups height
    env.z.workgroupId env.z.localId env.z.workgroupSize env.z.numWorkgroups depth
    h_wid_x h_lid_x h_wid_y h_lid_y h_wid_z h_lid_z h_fit_x h_fit_y h_fit_z

theorem texture_1d_affine_matcher_contract_sound
    (env : BoundsMatcherEnv)
    (width stride offset : Nat)
    (h_stride : 0 < stride)
    (h_wid : env.x.workgroupId < env.x.numWorkgroups)
    (h_lid : env.x.localId < env.x.workgroupSize)
    (h_fit : (env.x.workgroupSize * env.x.numWorkgroups) * stride + offset ≤ width) :
    env.x.gid * stride + offset < width := by
  exact gid_texture_coord_1d_affine_inbounds_when_dispatch_fits
    env.x.workgroupId env.x.localId env.x.workgroupSize env.x.numWorkgroups width stride offset h_stride h_wid h_lid h_fit

theorem texture_2d_affine_matcher_contract_sound
    (env : BoundsMatcherEnv)
    (width stride_x offset_x height stride_y offset_y : Nat)
    (h_stride_x : 0 < stride_x)
    (h_stride_y : 0 < stride_y)
    (h_wid_x : env.x.workgroupId < env.x.numWorkgroups)
    (h_lid_x : env.x.localId < env.x.workgroupSize)
    (h_wid_y : env.y.workgroupId < env.y.numWorkgroups)
    (h_lid_y : env.y.localId < env.y.workgroupSize)
    (h_fit_x : (env.x.workgroupSize * env.x.numWorkgroups) * stride_x + offset_x ≤ width)
    (h_fit_y : (env.y.workgroupSize * env.y.numWorkgroups) * stride_y + offset_y ≤ height) :
    env.x.gid * stride_x + offset_x < width ∧
    env.y.gid * stride_y + offset_y < height := by
  exact gid_texture_coords_2d_affine_inbounds_when_dispatch_fits
    env.x.workgroupId env.x.localId env.x.workgroupSize env.x.numWorkgroups width stride_x offset_x
    env.y.workgroupId env.y.localId env.y.workgroupSize env.y.numWorkgroups height stride_y offset_y
    h_stride_x h_stride_y h_wid_x h_lid_x h_wid_y h_lid_y h_fit_x h_fit_y

theorem texture_3d_affine_matcher_contract_sound
    (env : BoundsMatcherEnv)
    (width stride_x offset_x height stride_y offset_y depth stride_z offset_z : Nat)
    (h_stride_x : 0 < stride_x)
    (h_stride_y : 0 < stride_y)
    (h_stride_z : 0 < stride_z)
    (h_wid_x : env.x.workgroupId < env.x.numWorkgroups)
    (h_lid_x : env.x.localId < env.x.workgroupSize)
    (h_wid_y : env.y.workgroupId < env.y.numWorkgroups)
    (h_lid_y : env.y.localId < env.y.workgroupSize)
    (h_wid_z : env.z.workgroupId < env.z.numWorkgroups)
    (h_lid_z : env.z.localId < env.z.workgroupSize)
    (h_fit_x : (env.x.workgroupSize * env.x.numWorkgroups) * stride_x + offset_x ≤ width)
    (h_fit_y : (env.y.workgroupSize * env.y.numWorkgroups) * stride_y + offset_y ≤ height)
    (h_fit_z : (env.z.workgroupSize * env.z.numWorkgroups) * stride_z + offset_z ≤ depth) :
    env.x.gid * stride_x + offset_x < width ∧
    env.y.gid * stride_y + offset_y < height ∧
    env.z.gid * stride_z + offset_z < depth := by
  exact gid_texture_coords_3d_affine_inbounds_when_dispatch_fits
    env.x.workgroupId env.x.localId env.x.workgroupSize env.x.numWorkgroups width stride_x offset_x
    env.y.workgroupId env.y.localId env.y.workgroupSize env.y.numWorkgroups height stride_y offset_y
    env.z.workgroupId env.z.localId env.z.workgroupSize env.z.numWorkgroups depth stride_z offset_z
    h_stride_x h_stride_y h_stride_z
    h_wid_x h_lid_x h_wid_y h_lid_y h_wid_z h_lid_z
    h_fit_x h_fit_y h_fit_z

theorem texture_1d_tiled_matcher_contract_sound
    (env : BoundsMatcherEnv)
    (width tile_width tile_stride offset : Nat)
    (h_tile_width : 0 < tile_width)
    (h_tile_stride : tile_width ≤ tile_stride)
    (h_wid : env.x.workgroupId < env.x.numWorkgroups)
    (h_lid : env.x.localId < env.x.workgroupSize)
    (h_fit : (((env.x.workgroupSize * env.x.numWorkgroups - 1) / tile_width) + 1) * tile_stride + offset ≤ width) :
    tiledIndex1D env.x.gid tile_width tile_stride + offset < width := by
  exact gid_texture_coord_1d_tiled_inbounds_when_dispatch_fits
    env.x.workgroupId env.x.localId env.x.workgroupSize env.x.numWorkgroups width tile_width tile_stride offset
    h_tile_width h_tile_stride h_wid h_lid h_fit

theorem texture_2d_tiled_matcher_contract_sound
    (env : BoundsMatcherEnv)
    (width tile_width_x tile_stride_x offset_x height tile_width_y tile_stride_y offset_y : Nat)
    (h_tile_width_x : 0 < tile_width_x)
    (h_tile_width_y : 0 < tile_width_y)
    (h_tile_stride_x : tile_width_x ≤ tile_stride_x)
    (h_tile_stride_y : tile_width_y ≤ tile_stride_y)
    (h_wid_x : env.x.workgroupId < env.x.numWorkgroups)
    (h_lid_x : env.x.localId < env.x.workgroupSize)
    (h_wid_y : env.y.workgroupId < env.y.numWorkgroups)
    (h_lid_y : env.y.localId < env.y.workgroupSize)
    (h_fit_x : (((env.x.workgroupSize * env.x.numWorkgroups - 1) / tile_width_x) + 1) * tile_stride_x + offset_x ≤ width)
    (h_fit_y : (((env.y.workgroupSize * env.y.numWorkgroups - 1) / tile_width_y) + 1) * tile_stride_y + offset_y ≤ height) :
    tiledIndex1D env.x.gid tile_width_x tile_stride_x + offset_x < width ∧
    tiledIndex1D env.y.gid tile_width_y tile_stride_y + offset_y < height := by
  exact gid_texture_coords_2d_tiled_inbounds_when_dispatch_fits
    env.x.workgroupId env.x.localId env.x.workgroupSize env.x.numWorkgroups width tile_width_x tile_stride_x offset_x
    env.y.workgroupId env.y.localId env.y.workgroupSize env.y.numWorkgroups height tile_width_y tile_stride_y offset_y
    h_tile_width_x h_tile_width_y h_tile_stride_x h_tile_stride_y
    h_wid_x h_lid_x h_wid_y h_lid_y h_fit_x h_fit_y

theorem texture_3d_tiled_matcher_contract_sound
    (env : BoundsMatcherEnv)
    (width tile_width_x tile_stride_x offset_x height tile_width_y tile_stride_y offset_y depth tile_width_z tile_stride_z offset_z : Nat)
    (h_tile_width_x : 0 < tile_width_x)
    (h_tile_width_y : 0 < tile_width_y)
    (h_tile_width_z : 0 < tile_width_z)
    (h_tile_stride_x : tile_width_x ≤ tile_stride_x)
    (h_tile_stride_y : tile_width_y ≤ tile_stride_y)
    (h_tile_stride_z : tile_width_z ≤ tile_stride_z)
    (h_wid_x : env.x.workgroupId < env.x.numWorkgroups)
    (h_lid_x : env.x.localId < env.x.workgroupSize)
    (h_wid_y : env.y.workgroupId < env.y.numWorkgroups)
    (h_lid_y : env.y.localId < env.y.workgroupSize)
    (h_wid_z : env.z.workgroupId < env.z.numWorkgroups)
    (h_lid_z : env.z.localId < env.z.workgroupSize)
    (h_fit_x : (((env.x.workgroupSize * env.x.numWorkgroups - 1) / tile_width_x) + 1) * tile_stride_x + offset_x ≤ width)
    (h_fit_y : (((env.y.workgroupSize * env.y.numWorkgroups - 1) / tile_width_y) + 1) * tile_stride_y + offset_y ≤ height)
    (h_fit_z : (((env.z.workgroupSize * env.z.numWorkgroups - 1) / tile_width_z) + 1) * tile_stride_z + offset_z ≤ depth) :
    tiledIndex1D env.x.gid tile_width_x tile_stride_x + offset_x < width ∧
    tiledIndex1D env.y.gid tile_width_y tile_stride_y + offset_y < height ∧
    tiledIndex1D env.z.gid tile_width_z tile_stride_z + offset_z < depth := by
  exact gid_texture_coords_3d_tiled_inbounds_when_dispatch_fits
    env.x.workgroupId env.x.localId env.x.workgroupSize env.x.numWorkgroups width tile_width_x tile_stride_x offset_x
    env.y.workgroupId env.y.localId env.y.workgroupSize env.y.numWorkgroups height tile_width_y tile_stride_y offset_y
    env.z.workgroupId env.z.localId env.z.workgroupSize env.z.numWorkgroups depth tile_width_z tile_stride_z offset_z
    h_tile_width_x h_tile_width_y h_tile_width_z h_tile_stride_x h_tile_stride_y h_tile_stride_z
    h_wid_x h_lid_x h_wid_y h_lid_y h_wid_z h_lid_z h_fit_x h_fit_y h_fit_z

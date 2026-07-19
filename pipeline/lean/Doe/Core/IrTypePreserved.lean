-- Doe/Core/IrTypePreserved.lean
--
-- Abstract proof that the WGSL IR robustness transform is type-preserving:
-- it appends new helper expressions but does not mutate the type of any
-- pre-existing expression.
--
-- Mirrors: runtime/zig/src/compiler/wgsl/ir/ir_transform_robustness.zig apply()
--
-- The transform iterates over exprs[0..original_count) and for each index
-- operation appends new min/arrayLength expressions to the end of the array.
-- It does NOT write back to exprs.items[i].ty for i < original_count.
--
-- This file models that append-only contract abstractly and proves:
--   (1) A single transform step is type-preserving for all original entries.
--   (2) A full transform pass (N steps) is type-preserving.
--   (3) M sequential passes (M unbounded) preserve all original types.
--   (4) The injected clamp is safe, and is semantically a no-op for reads whose
--       original index already satisfies the host/GPU bounds preconditions.
--
-- The key abstraction is IsPrefix: after any number of passes, the original
-- type array is a prefix of the result. All original entries are intact.
--
-- Classification: lean_required (induction over unbounded List TransformPass).

-- ---------------------------------------------------------------------------
-- Abstract expression type array
-- ---------------------------------------------------------------------------

/-- An expression type array models the exprs.items[*].ty slice:
    a list of type identifiers indexed by expression id. -/
abbrev ExprTypeArray := List Nat

-- ---------------------------------------------------------------------------
-- Prefix relation
-- ---------------------------------------------------------------------------

/-- arr is a prefix of arr': the original entries are preserved as a
    prefix of the extended array. -/
def IsPrefix (arr arr' : ExprTypeArray) : Prop :=
  ∃ suffix, arr' = arr ++ suffix

theorem IsPrefix_refl (arr : ExprTypeArray) : IsPrefix arr arr :=
  ⟨[], by simp⟩

theorem IsPrefix_append (arr extra : ExprTypeArray) :
    IsPrefix arr (arr ++ extra) :=
  ⟨extra, rfl⟩

theorem IsPrefix_trans (a b c : ExprTypeArray)
    (hab : IsPrefix a b) (hbc : IsPrefix b c) :
    IsPrefix a c := by
  obtain ⟨s1, hs1⟩ := hab
  obtain ⟨s2, hs2⟩ := hbc
  exact ⟨s1 ++ s2, by rw [hs2, hs1, List.append_assoc]⟩

-- ---------------------------------------------------------------------------
-- Transform contract
-- ---------------------------------------------------------------------------

/-- A transform step: appends zero or more new type entries for helper
    expressions (clamping nodes). Never mutates existing entries.
    Models: ir_transform_robustness.zig transform_function() append pattern. -/
structure TransformStep where
  appended : ExprTypeArray

/-- Apply a transform step: append new entries to an existing array. -/
def applyStep (arr : ExprTypeArray) (step : TransformStep) : ExprTypeArray :=
  arr ++ step.appended

/-- A transform pass is a sequence of steps (one per function processed). -/
def TransformPass := List TransformStep

def applyPass (arr : ExprTypeArray) (pass : TransformPass) : ExprTypeArray :=
  pass.foldl applyStep arr

-- ---------------------------------------------------------------------------
-- Type preservation — single step
-- ---------------------------------------------------------------------------

/-- A single transform step extends the array by prefix. -/
theorem step_is_prefix (arr : ExprTypeArray) (step : TransformStep) :
    IsPrefix arr (applyStep arr step) :=
  IsPrefix_append arr step.appended

-- ---------------------------------------------------------------------------
-- Type preservation — a full pass (lean_required helper)
-- ---------------------------------------------------------------------------

/-- lean_required (helper): A full transform pass extends the array by prefix.
    Induction over List TransformStep. -/
theorem applyPass_is_prefix (arr : ExprTypeArray) (pass : TransformPass) :
    IsPrefix arr (applyPass arr pass) := by
  induction pass generalizing arr with
  | nil =>
    show IsPrefix arr arr
    exact IsPrefix_refl arr
  | cons step rest ih =>
    show IsPrefix arr (rest.foldl applyStep (applyStep arr step))
    exact IsPrefix_trans arr (applyStep arr step) _
      (step_is_prefix arr step) (ih (applyStep arr step))

-- ---------------------------------------------------------------------------
-- Type preservation — N sequential passes
-- ---------------------------------------------------------------------------

/-- Apply a list of transform passes sequentially. -/
def applyPasses (arr : ExprTypeArray) (passes : List TransformPass) : ExprTypeArray :=
  passes.foldl applyPass arr

/-- lean_required: N sequential transform passes (N unbounded) preserve all
    original type entries as a prefix of the final array.
    Induction over the list of passes (unbounded length).
    This is the formal guarantee that the emit pass sees the correct type
    for every expression regardless of how many robustness passes ran first. -/
theorem nPasses_preserve_original_types (arr : ExprTypeArray)
    (passes : List TransformPass) :
    IsPrefix arr (applyPasses arr passes) := by
  induction passes generalizing arr with
  | nil =>
    show IsPrefix arr arr
    exact IsPrefix_refl arr
  | cons pass rest ih =>
    show IsPrefix arr (rest.foldl applyPass (applyPass arr pass))
    exact IsPrefix_trans arr (applyPass arr pass) _
      (applyPass_is_prefix arr pass) (ih (applyPass arr pass))

-- ---------------------------------------------------------------------------
-- Abstract clamp/read semantics
-- ---------------------------------------------------------------------------

/-- A buffer payload model for semantic reads. Each Nat is an abstract element
    value; only indexing behavior matters for this proof. -/
abbrev BufferPayload := List Nat

/-- A single IR index read before or after robustness rewriting.
    Models the `.index` expression's base plus index operand. -/
structure IndexRead where
  base : BufferPayload
  index : Nat

/-- Evaluate an index read in the abstract model. Out-of-bounds reads are
    represented by `none`; in-bounds reads return `some value`. -/
def evalIndexRead (read : IndexRead) : Option Nat :=
  read.base.get? read.index

/-- The robustness transform's sized/runtime-sized array index clamp:
    `min(index, length - 1)`.

    Mirrors:
    - `clamp_sized`: `min(index, length - 1)`
    - `clamp_runtime_sized`: `min(index, arrayLength(&base) - 1)` -/
def robustClampIndex (index length : Nat) : Nat :=
  min index (length - 1)

/-- Apply the robustness clamp to an abstract index read.
    Models the Zig rewrite of the original `.index.index` operand while keeping
    the base expression unchanged. -/
def applyRobustClamp (read : IndexRead) : IndexRead :=
  { read with index := robustClampIndex read.index read.base.length }

-- Classification: lean_required (quantified over unbounded Nat domains).
/-- The clamped index is always within a non-empty container. This is the safety
    half of the robustness transform's semantic contract. -/
theorem robustClampIndex_inbounds_when_nonempty
    (index length : Nat)
    (h_pos : 0 < length) :
    robustClampIndex index length < length := by
  unfold robustClampIndex
  omega

-- Classification: lean_required (quantified over unbounded Nat domains).
/-- If the original index is already in bounds, the injected `min` clamp is
    semantically the identity on that index. -/
theorem robustClampIndex_noop_when_inbounds
    (index length : Nat)
    (h_pos : 0 < length)
    (h_bound : index < length) :
    robustClampIndex index length = index := by
  unfold robustClampIndex
  omega

-- Classification: lean_required (semantic read preservation over arbitrary buffers).
/-- When the original read is already in bounds, applying the robustness clamp
    preserves the observable read result. This is the semantic counterpart to
    `nPasses_preserve_original_types`: the transform changes the index operand,
    but under the bounds precondition the read denotes the same value. -/
theorem robustClampRead_noop_under_bounds
    (read : IndexRead)
    (h_bound : read.index < read.base.length) :
    evalIndexRead (applyRobustClamp read) = evalIndexRead read := by
  have h_pos : 0 < read.base.length := by
    exact Nat.lt_of_le_of_lt (Nat.zero_le read.index) h_bound
  unfold applyRobustClamp evalIndexRead
  rw [robustClampIndex_noop_when_inbounds read.index read.base.length h_pos h_bound]

-- Classification: lean_required (semantic safety over arbitrary buffers).
/-- Applying the robustness clamp to a non-empty buffer yields an in-bounds read
    index. The theorem is stated on the transformed IR node, matching the shape
    the emit passes observe after robustness rewriting. -/
theorem applyRobustClamp_index_safe_when_nonempty
    (read : IndexRead)
    (h_pos : 0 < read.base.length) :
    (applyRobustClamp read).index < read.base.length := by
  unfold applyRobustClamp
  exact robustClampIndex_inbounds_when_nonempty read.index read.base.length h_pos

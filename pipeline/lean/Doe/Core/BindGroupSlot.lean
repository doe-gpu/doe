-- Bind group → MSL buffer index mapping safety.
-- Mirrors: runtime/zig/src/compiler/wgsl/emit/msl/emit_msl_ir.zig:msl_binding_slot
--          runtime/zig/src/native/compute/doe_compute_ext_native.zig:flattenBindGroups
-- Constants match Zig: BINDINGS_PER_GROUP=16, MAX_BIND_GROUPS=4, MAX_FLAT_BIND=64.

/-- Bindings per group. Matches BINDINGS_PER_GROUP in emit_msl_ir.zig. -/
def BINDINGS_PER_GROUP : Nat := 16

/-- Maximum bind groups. Matches MAX_BIND_GROUPS in doe_compute_ext_native.zig. -/
def MAX_BIND_GROUPS : Nat := 4

/-- Maximum flat binding slots. Equals MAX_BIND_GROUPS * BINDINGS_PER_GROUP. -/
def MAX_FLAT_BIND : Nat := 64

/-- MSL buffer index from (group, binding). Mirrors emit_msl_ir.zig:msl_binding_slot. -/
def mslBindingSlot (group : Nat) (binding : Nat) : Nat :=
  group * BINDINGS_PER_GROUP + binding

/-- Same group, different bindings produce different slots. -/
theorem mslBindingSlot_injective_within_group
    (group b1 b2 : Nat)
    (h : mslBindingSlot group b1 = mslBindingSlot group b2) :
    b1 = b2 := by
  simp [mslBindingSlot, BINDINGS_PER_GROUP] at h
  omega

/-- Different (group, binding) pairs with valid bindings produce different slots.
    This is the collision-freedom guarantee for the flat buffer array. -/
theorem mslBindingSlot_injective_across_groups
    (g1 g2 b1 b2 : Nat)
    (hb1 : b1 < BINDINGS_PER_GROUP)
    (hb2 : b2 < BINDINGS_PER_GROUP)
    (h : mslBindingSlot g1 b1 = mslBindingSlot g2 b2) :
    g1 = g2 ∧ b1 = b2 := by
  simp [mslBindingSlot, BINDINGS_PER_GROUP] at h hb1 hb2
  omega

/-- Valid group and binding indices produce a slot within the flat array bounds. -/
theorem mslBindingSlot_in_bounds
    (group binding : Nat)
    (hg : group < MAX_BIND_GROUPS)
    (hb : binding < BINDINGS_PER_GROUP) :
    mslBindingSlot group binding < MAX_FLAT_BIND := by
  simp [mslBindingSlot, BINDINGS_PER_GROUP, MAX_BIND_GROUPS, MAX_FLAT_BIND] at *
  omega

/-- Different groups with valid bindings cannot collide.
    Corollary of injective_across_groups. -/
theorem mslBindingSlot_distinct_groups
    (g1 g2 b1 b2 : Nat)
    (hg : g1 ≠ g2)
    (hb1 : b1 < BINDINGS_PER_GROUP)
    (hb2 : b2 < BINDINGS_PER_GROUP) :
    mslBindingSlot g1 b1 ≠ mslBindingSlot g2 b2 := by
  intro h
  have ⟨hge, _⟩ := mslBindingSlot_injective_across_groups g1 g2 b1 b2 hb1 hb2 h
  exact hg hge

/-- Slot zero is uniquely (group=0, binding=0). -/
theorem mslBindingSlot_zero :
    mslBindingSlot 0 0 = 0 := by rfl

/-- Maximum valid slot is 63 = mslBindingSlot(3, 15). -/
theorem mslBindingSlot_max :
    mslBindingSlot 3 15 = 63 := by decide

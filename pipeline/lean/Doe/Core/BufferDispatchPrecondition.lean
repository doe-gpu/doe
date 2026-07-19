import Doe.Core.BufferLifecycle

-- Doe/Core/BufferDispatchPrecondition.lean
--
-- Proves that a buffer which starts live and is only operated on by
-- non-release operations remains dispatch-ready after any finite sequence
-- of such operations.
--
-- Extends: Doe.Core.BufferLifecycle
-- Connects to: runtime/zig/src/native/mod.zig DoeBuffer lifecycle,
--              dispatch precondition checks in doe_compute_preconditions_native.zig.
--
-- Classification: lean_required (induction over unbounded List LiveBufferOp).

-- ---------------------------------------------------------------------------
-- Live operations (subset that cannot kill the buffer)
-- ---------------------------------------------------------------------------

/-- Operations that cannot transition a live buffer to .released. -/
inductive LiveBufferOp where
  | mapAsync  -- doeBufferMapAsync: unmapped/mapped → mapped
  | unmap     -- doeBufferUnmap:    mapped/unmapped → unmapped
  deriving DecidableEq, Repr

def applyLiveOp : BufferState → LiveBufferOp → BufferState
  | s, .mapAsync => doeMapAsync s
  | s, .unmap    => doeUnmap s

def applyLiveOps : BufferState → List LiveBufferOp → BufferState
  | s, []         => s
  | s, op :: rest => applyLiveOps (applyLiveOp s op) rest

-- ---------------------------------------------------------------------------
-- Liveness preservation — single step
-- ---------------------------------------------------------------------------

/-- A single live operation preserves the "not released" invariant. -/
theorem liveOp_preserves_live (s : BufferState) (hs : s ≠ .released)
    (op : LiveBufferOp) :
    applyLiveOp s op ≠ .released := by
  cases op with
  | mapAsync =>
    cases s with
    | released => contradiction
    | unmapped => simp [applyLiveOp, doeMapAsync]
    | mapped   => simp [applyLiveOp, doeMapAsync]
  | unmap =>
    cases s with
    | released => contradiction
    | unmapped => simp [applyLiveOp, doeUnmap]
    | mapped   => simp [applyLiveOp, doeUnmap]

-- ---------------------------------------------------------------------------
-- lean_required: Liveness preservation over unbounded sequences
-- ---------------------------------------------------------------------------

/-- lean_required: Any sequence of live operations (map/unmap, no release)
    preserves the "not released" invariant, regardless of sequence length.
    Induction over unbounded List LiveBufferOp.
    Formal basis for Doe's policy of not rechecking buffer liveness on
    every dispatch when the buffer was live at bind-group creation time. -/
theorem liveOps_preserve_live (s : BufferState) (hs : s ≠ .released)
    (ops : List LiveBufferOp) :
    applyLiveOps s ops ≠ .released := by
  induction ops generalizing s with
  | nil          => exact hs
  | cons op rest ih =>
    simp only [applyLiveOps]
    exact ih _ (liveOp_preserves_live s hs op)

-- ---------------------------------------------------------------------------
-- Dispatch readiness
-- ---------------------------------------------------------------------------

/-- A live buffer (not released) satisfies Doe's dispatch precondition. -/
theorem live_buffer_dispatch_ready (s : BufferState) (hs : s ≠ .released) :
    doeAllowsDispatch s = true := by
  cases s with
  | released => contradiction
  | unmapped => rfl
  | mapped   => rfl

/-- lean_required: A buffer that starts live and undergoes any number of
    map/unmap operations remains dispatch-ready at all times, regardless of
    how many operations occurred between bind-group creation and dispatch.
    Induction over unbounded List LiveBufferOp. -/
theorem liveOps_dispatch_always_ready (s : BufferState) (hs : s ≠ .released)
    (ops : List LiveBufferOp) :
    doeAllowsDispatch (applyLiveOps s ops) = true :=
  live_buffer_dispatch_ready _ (liveOps_preserve_live s hs ops)

-- ---------------------------------------------------------------------------
-- Spec compliance for dispatch on live buffers
-- ---------------------------------------------------------------------------

/-- After live ops ending at .unmapped, the buffer also satisfies the WebGPU
    spec dispatch permission (spec requires unmapped; Doe also allows mapped).
    Uses doe_dispatch_superset from BufferLifecycle.lean. -/
theorem liveOps_unmapped_spec_dispatch_ready (s : BufferState) (hs : s ≠ .released)
    (ops : List LiveBufferOp) (h_final : applyLiveOps s ops = .unmapped) :
    specAllowsDispatch (applyLiveOps s ops) = true := by
  rw [h_final]
  rfl

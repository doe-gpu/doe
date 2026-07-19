-- Doe/Core/RenderPassStateMachine.lean
--
-- Abstract state machine proof for the Doe render pass encoder.
-- Mirrors: runtime/zig/src/native/render/doe_render_native.zig DoeRenderPass + DoeCommandEncoder.
--
-- Doe follows a permissive model: all operations succeed on any live encoder;
-- commands issued after endRenderPass are silently absorbed (no error state).
-- This module formalizes the state machine and proves key reachability
-- properties over unbounded command sequences, which require induction and
-- are not checkable by Zig comptime.
--
-- Classification: lean_required (induction over unbounded List).

-- ---------------------------------------------------------------------------
-- Render pass encoder state
-- ---------------------------------------------------------------------------

/-- State of a single render pass encoder. Doe has no error state:
    the encoder is either recording or ended. -/
inductive RenderPassState where
  | recording -- endRenderPass not yet called; commands are accepted
  | ended     -- endRenderPass has been called; further commands are no-ops
  deriving DecidableEq, Repr

-- ---------------------------------------------------------------------------
-- Render pass operations
-- ---------------------------------------------------------------------------

/-- The set of operations callable on a render pass encoder.
    Mirrors the exported C-ABI entry points in doe_render_native.zig. -/
inductive RenderPassOp where
  | setBindGroup
  | setVertexBuffer
  | setIndexBuffer
  | setPipeline
  | setViewport
  | setScissor
  | draw
  | drawIndexed
  | drawIndirect
  | drawIndexedIndirect
  | endPass   -- doeRenderPassEncoderEnd
  deriving DecidableEq, Repr

-- ---------------------------------------------------------------------------
-- Transition function
-- ---------------------------------------------------------------------------

/-- Apply a single render pass operation.
    Doe's permissive semantics: endPass is the only state-changing op;
    all other operations are no-ops on an ended encoder. -/
def applyRenderOp : RenderPassState → RenderPassOp → RenderPassState
  | _,          .endPass => .ended
  | .ended,     _        => .ended     -- Doe: permissive absorption
  | .recording, _        => .recording

/-- Apply a sequence of render pass operations. -/
def applyRenderOps : RenderPassState → List RenderPassOp → RenderPassState
  | s, []         => s
  | s, op :: rest => applyRenderOps (applyRenderOp s op) rest

-- ---------------------------------------------------------------------------
-- Core state machine theorems
-- ---------------------------------------------------------------------------

/-- endPass is idempotent: calling it twice is the same as calling it once. -/
theorem endPass_idempotent (s : RenderPassState) :
    applyRenderOp (applyRenderOp s .endPass) .endPass = applyRenderOp s .endPass := by
  cases s <;> rfl

/-- The ended state absorbs any single operation. -/
theorem ended_absorbs_op (op : RenderPassOp) :
    applyRenderOp .ended op = .ended := by
  cases op <;> rfl

/-- lean_required: The ended state absorbs any sequence of operations,
    regardless of length. Induction over unbounded List RenderPassOp.
    Formal basis for Doe's contract that a finished render pass encoder
    remains closed regardless of how many trailing calls are made. -/
theorem ended_absorbs_all_ops (ops : List RenderPassOp) :
    applyRenderOps .ended ops = .ended := by
  induction ops with
  | nil          => rfl
  | cons op rest ih =>
    simp only [applyRenderOps, ended_absorbs_op, ih]

/-- The final state after any sequence of operations is either .recording
    or .ended — never anything else. -/
theorem applyRenderOps_dichotomy (s : RenderPassState) (ops : List RenderPassOp) :
    applyRenderOps s ops = .recording ∨ applyRenderOps s ops = .ended := by
  induction ops generalizing s with
  | nil => cases s <;> simp [applyRenderOps]
  | cons op rest ih => simp only [applyRenderOps]; exact ih _

-- ---------------------------------------------------------------------------
-- Command encoder — render pass pairing
-- ---------------------------------------------------------------------------

/-- State of the command encoder with respect to render pass tracking.
    A command encoder has at most one active render pass at a time. -/
inductive CommandEncoderState where
  | idle      -- no active render pass
  | inPass    -- a render pass is currently recording
  | finished  -- finish() has been called on the command encoder
  deriving DecidableEq, Repr

/-- Command encoder operations (simplified). -/
inductive CommandEncoderOp where
  | beginRenderPass
  | endRenderPass
  | finishEncoder
  deriving DecidableEq, Repr

def applyEncoderOp : CommandEncoderState → CommandEncoderOp → CommandEncoderState
  | .idle,     .beginRenderPass => .inPass
  | .inPass,   .endRenderPass   => .idle
  | s,         .finishEncoder   => .finished
  | s,         _                => s   -- permissive: out-of-order ops are no-ops

def applyEncoderOps : CommandEncoderState → List CommandEncoderOp → CommandEncoderState
  | s, []         => s
  | s, op :: rest => applyEncoderOps (applyEncoderOp s op) rest

/-- The finished state absorbs any further encoder operation. -/
theorem finished_absorbs_op (op : CommandEncoderOp) :
    applyEncoderOp .finished op = .finished := by
  cases op <;> rfl

/-- lean_required: The finished command encoder absorbs any sequence of
    further operations, regardless of length.
    Induction over unbounded List CommandEncoderOp.
    Formal basis for Doe's contract that a finished encoder remains closed. -/
theorem finished_absorbs_all_ops (ops : List CommandEncoderOp) :
    applyEncoderOps .finished ops = .finished := by
  induction ops with
  | nil          => rfl
  | cons op rest ih =>
    simp only [applyEncoderOps, finished_absorbs_op, ih]

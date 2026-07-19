-- Doe/Core/Model.lean
--
-- Core data contracts: api/scope/safety/proof enums, command-kind taxonomy,
-- quirk records, and device profile. These mirror the Zig runtime contract
-- modules one-for-one; any Zig-side change must be reflected here in the
-- same change (per CLAUDE.md contract-update discipline).
--
-- Mirrors: runtime/zig/src/contracts/model/model_policy.zig (Api, Scope, SafetyClass,
--          VerificationMode, ProofLevel, ActionKind, ToggleEffect)
--          runtime/zig/src/contracts/model/model_profile.zig (DeviceProfile)
--          runtime/zig/src/contracts/model/model_quirks.zig  (Quirk, MatchSpec)
--          runtime/zig/src/contracts/model/model_commands.zig (CommandKind)
-- Classification: tautological (enum definitions are by construction).

inductive Api where
  | vulkan
  | metal
  | d3d12
  | webgpu
  deriving Repr, DecidableEq

inductive Scope where
  | alignment
  | barrier
  | layout
  | driver_toggle
  | memory
  deriving Repr, DecidableEq

inductive SafetyClass where
  | low
  | moderate
  | high
  | critical
  deriving Repr, DecidableEq

inductive VerificationMode where
  | guard_only
  | lean_preferred
  | lean_required
  deriving Repr, DecidableEq

inductive ProofLevel where
  | proven
  | guarded
  | rejected
  deriving Repr, DecidableEq

inductive CommandKind where
  | upload
  | copyBufferToTexture
  | barrier
  | dispatch
  | dispatchIndirect
  | kernelDispatch
  | renderDraw
  | drawIndirect
  | drawIndexedIndirect
  | renderPass
  | samplerCreate
  | samplerDestroy
  | textureWrite
  | textureQuery
  | textureDestroy
  | surfaceCreate
  | surfaceCapabilities
  | surfaceConfigure
  | surfaceAcquire
  | surfacePresent
  | surfaceUnconfigure
  | surfaceRelease
  | asyncDiagnostics
  | mapAsync
  deriving Repr, DecidableEq

structure SemVer where
  major : Nat
  minor : Nat
  patch : Nat
  deriving Repr, DecidableEq

def parseVersionComponent (text : String) : Option Nat :=
  text.trim.toNat?

def SemVer.parse (text : String) : Option SemVer :=
  let parts := text.trim.splitOn "."
  match parts with
  | [major] =>
    match parseVersionComponent major, parseVersionComponent "0", parseVersionComponent "0" with
    | some m, some _, some _ => some { major := m, minor := 0, patch := 0 }
    | _, _, _ => none
  | [major, minor] =>
    match parseVersionComponent major, parseVersionComponent minor, parseVersionComponent "0" with
    | some m, some n, some _ => some { major := m, minor := n, patch := 0 }
    | _, _, _ => none
  | [major, minor, patch] =>
    match parseVersionComponent major, parseVersionComponent minor, parseVersionComponent patch with
    | some m, some n, some p => some { major := m, minor := n, patch := p }
    | _, _, _ => none
  | _ => none

def SemVer.eq (left : SemVer) (right : SemVer) : Bool :=
  left.major == right.major &&
  left.minor == right.minor &&
  left.patch == right.patch

def SemVer.lt (left : SemVer) (right : SemVer) : Bool :=
  (left.major < right.major) ||
  (left.major == right.major && left.minor < right.minor) ||
  (left.major == right.major && left.minor == right.minor && left.patch < right.patch)

def SemVer.gt (left : SemVer) (right : SemVer) : Bool :=
  (left.major > right.major) ||
  (left.major == right.major && left.minor > right.minor) ||
  (left.major == right.major && left.minor == right.minor && left.patch > right.patch)

def SemVer.ge (left : SemVer) (right : SemVer) : Bool :=
  !SemVer.lt left right

def SafetyClass.rank : SafetyClass → Nat
  | .low => 0
  | .moderate => 1
  | .high => 2
  | .critical => 3

def ProofLevel.rank : ProofLevel → Nat
  | .proven => 3
  | .guarded => 2
  | .rejected => 1

def requiresLean : VerificationMode → Bool
  | .guard_only => False
  | .lean_preferred => False
  | .lean_required => True

def requiredProofClass : SafetyClass → ProofLevel
  | .low => ProofLevel.guarded
  | .moderate => ProofLevel.guarded
  | .high => ProofLevel.proven
  | .critical => ProofLevel.proven

inductive ToggleEffect where
  | behavioral
  | informational
  | unhandled
  deriving Repr, DecidableEq

inductive ActionKind where
  | use_temporary_buffer
  | use_temporary_render_texture
  | toggle (effect : ToggleEffect)
  | no_op
  deriving Repr, DecidableEq

/-- An action is identity when it does not modify the command. -/
def ActionKind.isIdentity : ActionKind → Bool
  | .no_op => true
  | .toggle .informational => true
  | .toggle .unhandled => true
  | _ => false

theorem critical_is_max_rank : SafetyClass.critical.rank = 3 := by
  rfl

theorem requiredProof_forbidden_reject_from_rank :
    ∀ c : SafetyClass, requiredProofClass c = ProofLevel.rejected → False := by
  intro c h
  cases c <;> simp [requiredProofClass] at h

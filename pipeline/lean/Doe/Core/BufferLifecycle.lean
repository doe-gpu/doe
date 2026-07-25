-- DoeBuffer lifecycle state machine.
-- Model context: native buffer operations. Exact runtime mirrors and source
-- hashes are emitted by the theoremMetadata registry during extraction.
-- Doe is intentionally more permissive than the WebGPU spec:
-- no precondition checks on mapAsync/unmap/getMappedRange/dispatch.
-- This module formally documents where Doe diverges from spec.

/-- Buffer states in Doe's lifecycle. -/
inductive BufferState where
  | unmapped   -- alive, not mapped (CPU access still works via UMA)
  | mapped     -- alive, mapped for CPU access
  | released   -- freed by doeBufferRelease, all access is undefined
  deriving Repr, DecidableEq

-- Doe transition functions (match Zig implementation)

/-- doeBufferMapAsync: sets mapped=true. No precondition check in Doe. -/
def doeMapAsync : BufferState → BufferState
  | .released => .released
  | _ => .mapped

/-- doeBufferUnmap: sets mapped=false. No precondition check in Doe. -/
def doeUnmap : BufferState → BufferState
  | .released => .released
  | _ => .unmapped

/-- doeBufferRelease: immediately frees the buffer. Terminal transition. -/
def doeRelease : BufferState → BufferState
  | _ => .released

-- Core lifecycle properties

/-- Release is terminal: any state transitions to released. -/
theorem doeRelease_terminal (s : BufferState) :
    doeRelease s = .released := by
  cases s <;> rfl

/-- Released state absorbs all transitions. -/
theorem released_absorbs_all (s : BufferState) (hs : s = .released) :
    doeMapAsync s = .released ∧ doeUnmap s = .released ∧ doeRelease s = .released := by
  subst hs; exact ⟨rfl, rfl, rfl⟩

-- Idempotency

/-- mapAsync is idempotent. -/
theorem doeMapAsync_idempotent (s : BufferState) :
    doeMapAsync (doeMapAsync s) = doeMapAsync s := by
  cases s <;> rfl

/-- unmap is idempotent. -/
theorem doeUnmap_idempotent (s : BufferState) :
    doeUnmap (doeUnmap s) = doeUnmap s := by
  cases s <;> rfl

/-- map then unmap returns to unmapped (round-trip for live buffers). -/
theorem doeMapUnmap_roundtrip (s : BufferState) (hs : s ≠ .released) :
    doeUnmap (doeMapAsync s) = .unmapped := by
  cases s <;> simp_all [doeMapAsync, doeUnmap]

/-- unmap then map returns to mapped (reverse round-trip for live buffers). -/
theorem doeUnmapMap_roundtrip (s : BufferState) (hs : s ≠ .released) :
    doeMapAsync (doeUnmap s) = .mapped := by
  cases s <;> simp_all [doeMapAsync, doeUnmap]

-- WebGPU spec conformance gap documentation

/-- What Doe allows for getMappedRange (permissive: any live buffer). -/
def doeAllowsGetMappedRange : BufferState → Bool
  | .released => false
  | _ => true

/-- What the WebGPU spec allows for getMappedRange (strict: mapped only). -/
def specAllowsGetMappedRange : BufferState → Bool
  | .mapped => true
  | _ => false

/-- What Doe allows for dispatch (permissive: any live buffer). -/
def doeAllowsDispatch : BufferState → Bool
  | .released => false
  | _ => true

/-- What the WebGPU spec allows for dispatch (strict: unmapped only). -/
def specAllowsDispatch : BufferState → Bool
  | .unmapped => true
  | _ => false

/-- Formal gap: Doe allows getMappedRange on unmapped buffers (spec forbids).
    This is intentional: Apple Silicon UMA makes CPU pointers valid without mapping. -/
theorem doe_getMappedRange_gap :
    doeAllowsGetMappedRange .unmapped = true ∧ specAllowsGetMappedRange .unmapped = false := by
  exact ⟨rfl, rfl⟩

/-- Formal gap: Doe allows dispatch on mapped buffers (spec forbids).
    Doe has no mapped-state precondition check on command encoding. -/
theorem doe_dispatch_gap :
    doeAllowsDispatch .mapped = true ∧ specAllowsDispatch .mapped = false := by
  exact ⟨rfl, rfl⟩

/-- Doe is a superset of spec for getMappedRange:
    anything the spec permits, Doe also permits. -/
theorem doe_getMappedRange_superset :
    ∀ s : BufferState, specAllowsGetMappedRange s = true → doeAllowsGetMappedRange s = true := by
  intro s h
  cases s <;> simp_all [doeAllowsGetMappedRange, specAllowsGetMappedRange]

/-- Doe is a superset of spec for dispatch:
    anything the spec permits, Doe also permits. -/
theorem doe_dispatch_superset :
    ∀ s : BufferState, specAllowsDispatch s = true → doeAllowsDispatch s = true := by
  intro s h
  cases s <;> simp_all [doeAllowsDispatch, specAllowsDispatch]

-- Doe/Core/Runtime.lean
--
-- Runtime dispatch and quirk-matching contract.
-- Models device profile, match specs, and the deterministic matcher/selector
-- that the Zig runtime uses at dispatch time.
--
-- Mirrors: runtime/zig/src/quirk/runtime.zig (matcher, selector, bucketing)
--          runtime/zig/src/contracts/model/model_profile.zig (DeviceProfile construction)
--          runtime/zig/src/quirk/quirk_json.zig (quirk record schema)
-- Classification: lean_verified (quantified over unbounded quirk lists).

import Doe.Core.Model

structure DeviceProfile where
  vendor : String
  api : Api
  deviceFamily : Option String
  driverMajor : Nat
  driverMinor : Nat
  driverPatch : Nat
  deriving Repr

def DeviceProfile.versionKey (p : DeviceProfile) : Nat × Nat × Nat :=
  (p.driverMajor, p.driverMinor, p.driverPatch)

structure MatchSpec where
  vendor : String
  api : Api
  deviceFamily : Option String
  driverRange : Option String
  deriving Repr

structure Quirk where
  id : String
  scope : Scope
  matchSpec : MatchSpec
  priority : Nat
  verificationMode : VerificationMode
  safetyClass : SafetyClass
  proofLevel : ProofLevel
  deriving Repr

structure DispatchResult where
  quirk : Option Quirk
  score : Nat
  matchedCount : Nat
  deriving Repr

structure DispatchDecision where
  quirk : Option Quirk
  score : Nat
  matchedCount : Nat
  requiresLean : Bool
  isBlocking : Bool
  proofLevel : Option ProofLevel
  verificationMode : Option VerificationMode
  matchedScope : Option Scope
  matchedSafetyClass : Option SafetyClass
  deriving Repr

def vendorMatch (profileVendor : String) (quirkVendor : String) : Bool :=
  profileVendor = quirkVendor

def deviceProfileVersion (profile : DeviceProfile) : SemVer :=
  { major := profile.driverMajor, minor := profile.driverMinor, patch := profile.driverPatch }

def parseDriverVersion (raw : String) : Option SemVer :=
  SemVer.parse raw

def matchesDriverToken (actual : SemVer) (raw : String) : Bool :=
  let token := raw.trim
  if token.length == 0 then
    true
  else if token.startsWith ">=" then
    match parseDriverVersion (token.drop 2) with
    | some expected => actual.ge expected
    | none => false
  else if token.startsWith "<=" then
    match parseDriverVersion (token.drop 2) with
    | some expected => !actual.gt expected
    | none => false
  else if token.startsWith ">" then
    match parseDriverVersion (token.drop 1) with
    | some expected => actual.gt expected
    | none => false
  else if token.startsWith "<" then
    match parseDriverVersion (token.drop 1) with
    | some expected => actual.lt expected
    | none => false
  else if token.startsWith "==" then
    match parseDriverVersion (token.drop 2) with
    | some expected => SemVer.eq actual expected
    | none => false
  else
    match parseDriverVersion token with
    | some expected => SemVer.eq actual expected
    | none => false

def matchesDriverRange (actual : SemVer) (expression : String) : Bool :=
  (expression.split (fun ch => ch = ',')).all (fun token => matchesDriverToken actual token)

def proofPriority : ProofLevel → Nat
  | .proven => 3
  | .guarded => 2
  | .rejected => 1

def profileMatches (profile : DeviceProfile) (spec : MatchSpec) : Bool :=
  vendorMatch profile.vendor spec.vendor &&
  profile.api = spec.api &&
  (match spec.deviceFamily with
  | none => True
  | some required => profile.deviceFamily = some required) &&
  (match spec.driverRange with
  | none => True
  | some range => matchesDriverRange (deviceProfileVersion profile) range)

def supportsScope (scope : Scope) (command : CommandKind) : Bool :=
  match scope with
  | .alignment => command = .upload || command = .copyBufferToTexture
  | .layout =>
    command = .dispatch || command = .dispatchIndirect ||
    command = .kernelDispatch || command = .renderDraw ||
    command = .drawIndirect || command = .drawIndexedIndirect ||
    command = .renderPass || command = .copyBufferToTexture ||
    command = .samplerCreate || command = .samplerDestroy ||
    command = .textureWrite || command = .textureQuery ||
    command = .textureDestroy || command = .surfaceCreate ||
    command = .surfaceCapabilities || command = .surfaceConfigure ||
    command = .surfaceAcquire || command = .surfacePresent ||
    command = .surfaceUnconfigure || command = .surfaceRelease ||
    command = .asyncDiagnostics
  | .barrier =>
    command = .barrier || command = .dispatch ||
    command = .dispatchIndirect || command = .kernelDispatch ||
    command = .renderDraw || command = .drawIndirect ||
    command = .drawIndexedIndirect || command = .renderPass ||
    command = .surfacePresent
  | .driver_toggle => True
  | .memory =>
    command = .copyBufferToTexture || command = .upload ||
    command = .textureWrite || command = .textureQuery ||
    command = .textureDestroy

def supportsQuirk (quirk : Quirk) (command : CommandKind) : Bool :=
  supportsScope quirk.scope command

def scopeBias (scope : Scope) (command : CommandKind) : Nat :=
  match scope, command with
  | .alignment, .upload => 5
  | .memory, .copyBufferToTexture => 8
  | _, _ => 0

def scoreQuirk (profile : DeviceProfile) (quirk : Quirk) (command : CommandKind) : Nat :=
  let base := quirk.priority
  let explicitFamilyScore :=
    match quirk.matchSpec.deviceFamily with
    | none => 1
    | some required =>
      match profile.deviceFamily with
      | none => 0
      | some actual => if required == actual then 50 else 0
  let driverRangeScore := if quirk.matchSpec.driverRange.isSome then 10 else 0
  let safetyScore :=
    match quirk.safetyClass with
    | .critical => 15
    | .high => 8
    | _ => 0
  let verificationScore :=
    if quirk.verificationMode == VerificationMode.lean_required then 12 else 0
  let memoryDensityScore :=
    if quirk.scope == .memory && quirk.matchSpec.deviceFamily.isSome && profile.deviceFamily.isSome then 20 else 0
  let commandScore :=
    match command with
    | .upload =>
      if quirk.scope == .alignment then 5 else 0
    | .copyBufferToTexture =>
      if quirk.scope == .memory then 8 else if quirk.scope == .alignment then 4 else 0
    | .dispatch =>
      if quirk.scope == .layout then 4 else if quirk.scope == .barrier then 6 else 0
    | .dispatchIndirect =>
      if quirk.scope == .layout then 4 else if quirk.scope == .barrier then 6 else 0
    | .barrier =>
      if quirk.scope == .barrier then 8 else 0
    | .kernelDispatch =>
      if quirk.scope == .layout then 7 else if quirk.scope == .barrier then 2 else 0
    | .renderDraw | .drawIndirect | .drawIndexedIndirect | .renderPass =>
      if quirk.scope == .layout then 6 else if quirk.scope == .barrier then 3 else 0
    | .samplerCreate | .samplerDestroy =>
      if quirk.scope == .layout then 3 else 0
    | .textureWrite | .textureQuery | .textureDestroy =>
      if quirk.scope == .memory then 6 else if quirk.scope == .layout then 2 else 0
    | .surfaceCreate | .surfaceCapabilities | .surfaceConfigure
    | .surfaceAcquire | .surfacePresent | .surfaceUnconfigure | .surfaceRelease =>
      if quirk.scope == .memory then 5 else 0
    | .asyncDiagnostics =>
      if quirk.scope == .memory then 5 else 0
    | .mapAsync =>
      if quirk.scope == .memory then 6 else 0
  base +
  explicitFamilyScore +
  driverRangeScore +
  safetyScore +
  verificationScore +
  memoryDensityScore +
  commandScore

def betterMatch (lhs : Quirk × Nat) (rhs : Quirk × Nat) : Quirk × Nat :=
  if lhs.2 < rhs.2 then rhs
  else if rhs.2 < lhs.2 then lhs
  else if proofPriority lhs.1.proofLevel != proofPriority rhs.1.proofLevel then
    if proofPriority lhs.1.proofLevel > proofPriority rhs.1.proofLevel then lhs else rhs
  else if lhs.1.priority != rhs.1.priority then
    if lhs.1.priority > rhs.1.priority then lhs else rhs
  else if lhs.1.id < rhs.1.id then lhs else rhs

theorem betterMatch_prefers_higher_score
    (lhs rhs : Quirk × Nat)
    (h : lhs.2 < rhs.2) :
    betterMatch lhs rhs = rhs := by
  simp [betterMatch, h, Nat.not_lt_of_ge (Nat.le_of_lt h)]

def chooseBestFrom (profile : DeviceProfile) (command : CommandKind) (quirks : List Quirk) : DispatchResult :=
  let rec loop
      (items : List Quirk)
      (best : Option (Quirk × Nat))
      (matched : Nat) : Option (Quirk × Nat) × Nat :=
    match items with
    | [] => (best, matched)
    | q :: rest =>
      let nextMatched := if profileMatches profile q.matchSpec && supportsQuirk q command then matched + 1 else matched
      let nextBest :=
        if profileMatches profile q.matchSpec && supportsQuirk q command then
          let candidate := (q, scoreQuirk profile q command)
          match best with
          | none => some candidate
          | some value => some (betterMatch value candidate)
        else
          best
      loop rest nextBest nextMatched

  let ⟨winner, total⟩ := loop quirks none 0
  match winner with
  | none => { quirk := none, score := 0, matchedCount := total }
  | some chosen =>
    { quirk := some chosen.1, score := chosen.2, matchedCount := total }

def selectForProfile (profile : DeviceProfile) (command : CommandKind) (quirks : List Quirk) : DispatchDecision :=
  let result := chooseBestFrom profile command quirks
  match result.quirk with
  | none =>
    { quirk := none
      score := 0
      matchedCount := result.matchedCount
      requiresLean := false
      isBlocking := false
      proofLevel := none
      verificationMode := none
      matchedScope := none
      matchedSafetyClass := none
    }
  | some quirk =>
    { quirk := some quirk
      score := result.score
      matchedCount := result.matchedCount
      requiresLean := requiresLean quirk.verificationMode
      isBlocking := requiresLean quirk.verificationMode && quirk.proofLevel != ProofLevel.proven
      proofLevel := some quirk.proofLevel
      verificationMode := some quirk.verificationMode
      matchedScope := some quirk.scope
      matchedSafetyClass := some quirk.safetyClass
    }

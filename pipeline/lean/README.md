# Doe Lean module

## Verification category classification

Current theorem inventory and category counts live in
`pipeline/lean/artifacts/proven-conditions.json`.

Every extracted theorem is classified into one of five artifact categories
based on whether Lean is actually necessary to verify it:

- **`tautological`** — correct by construction or definitional. There is nothing to verify: the property follows directly from how the code is written. Lean is restating the definition. Examples: a table built from a function trivially matches that function; `rfl` proofs that just unfold a definition; a one-liner that follows from another theorem.
- **`comptime_verified`** — property over a finite domain that requires checking all cases but is independently verifiable by Zig `comptime` exhaustion or unit tests. Lean is redundant — a `comptime` inline-for or exhaustive test does the same thing.
- **`lean_verified`** — property quantified over unbounded domains (arbitrary lists, parametric structures) that `comptime` cannot enumerate. Lean is necessary.
- **`lean_required`** — theorem that requires Lean proof and is used as a blocking proof obligation in the current artifact/gate model.
- **`lean_fixture`** — specific test case verified against a `lean_verified` theorem. Could be an integration test, but exercises the genuine proofs and catches regressions in the obligation model.

The tier is recorded in the `category` field of the proof artifact (`config/proof-artifact.schema.json`).

## Theorem inventory by tier

### `tautological`

See `pipeline/lean/artifacts/proven-conditions.json` for the current count.

Nothing to verify. These restate definitions or are correct by construction.

| Theorem | What it says | Why it's tautological |
|---------|-------------|----------------------|
| `scopeCommandTableComplete` | Comptime table matches `supportsScope` | Table is built from the function — `X == X` |
| `toggleAlwaysSupported` | `driver_toggle` supports all commands | Subsumed by above; `driver_toggle => True` is the definition |
| `noOpActionIdentity` | `no_op.isIdentity = true` | Definitional (`rfl` — just unfolds the definition) |
| `informationalToggleIdentity` | `(toggle .informational).isIdentity = true` | Definitional (`rfl`) |
| `unhandledToggleIdentity` | `(toggle .unhandled).isIdentity = true` | Definitional (`rfl`) |
| `behavioralToggleNotIdentity` | `(toggle .behavioral).isIdentity = false` | Definitional (`rfl`) |
| `betterMatch_prefers_higher_score` | Higher score wins | `if a < b then b` returns `b` — obvious from definition |
| `identityActionPreservesCommand` | Identity actions preserve commands | One-liner: calls `identityActionComplete` |

### `comptime_verified`

See `pipeline/lean/artifacts/proven-conditions.json` for the current count.

Finite-enum properties that require checking all cases. Zig `comptime` inline-for or exhaustive tests would verify the same thing.

| Theorem | What it says | Domain size |
|---------|-------------|-------------|
| `critical_is_max_rank` | Critical has the highest safety rank | 4 enum values |
| `requiredProof_forbidden_reject_from_rank` | No safety class maps to `.rejected` | 3 × 3 enum pairs |
| `strongerSafetyRaisesProofDemand` | Critical safety demands `.proven` proof | 3 enum values |
| `identityActionComplete` | Exactly which actions are identity (iff) | 4 action variants × sub-cases |

### `lean_verified` and `lean_required`

See `pipeline/lean/artifacts/proven-conditions.json` for the current counts.

`lean_verified` theorems are quantified over arbitrary `List Obligation` or arbitrary `Nat` — unbounded domain, cannot enumerate. `lean_required` theorems also require Lean (induction over unbounded structures: lists, IR node counts, ref chains, render-pass state machines) and are classified separately in the proof artifact.

Representative `lean_verified` selection below; full `lean_required` coverage
in the current artifact includes IR builder soundness, IR semantic/validator
contracts, MSL address-space chains, render-pass state machines, buffer
dispatch preconditions, and compute bounds theorems.

| Theorem | What it proves |
|---------|---------------|
| `comparableFromObligations_eq_noFailed` | Comparability equals having no failed obligations |
| `comparableFromFacts_eq_noFailed` | Same, from facts (composed through obligation pipeline) |
| `comparableFromObligations_true_iff_failedBlockingNil` | Comparable ↔ no failed blocking obligations |
| `comparableFromObligations_false_iff_failedBlockingNonEmpty` | Not comparable ↔ at least one failed blocking obligation |
| `comparableFromFacts_true_iff_failedBlockingNil` | Same, from facts |
| `comparableFromFacts_false_iff_failedBlockingNonEmpty` | Same, from facts |
| `structurallyEquivalentGeometry_refl` | Any workload geometry is structurally equivalent to itself |
| `structurallyEquivalentGeometry_forall_components` | Arbitrary Nat-valued buffer/dispatch components remain structurally equivalent when mirrored |
| `equalGeometrySetsExecutionShapeFacts` | Equal Nat-valued geometry forces execution-shape comparability facts true |
| `gid_component_lt_total` | Single-dimension gid < array_length when dispatch fits |
| `gid_inbounds_when_dispatch_fits` | 1D dispatch: gid.x < buf.length when ws.x * nwg.x ≤ buf.length |
| `gid_plus_offset_inbounds_when_dispatch_fits` | 1D affine dispatch: gid.x + offset < buf.length when ws.x * nwg.x + offset ≤ buf.length |
| `gid_times_stride_plus_offset_inbounds_when_dispatch_fits` | 1D strided affine dispatch: gid.x * stride + offset < buf.length when ws.x * nwg.x * stride + offset ≤ buf.length |
| `gid_plus_bounded_loop_index_inbounds_when_dispatch_fits` | Constant-bounded counted-loop dispatch: gid.x + i + offset < buf.length for supported ascending or descending `for`/`while`/guarded-`loop` forms when ws.x * nwg.x + limit + offset ≤ buf.length |
| `gid_affine_plus_scaled_loop_index_inbounds_when_dispatch_fits` | Constant-bounded affine counted-loop dispatch: gid.x * gid_stride + i * loop_stride + offset < buf.length for supported ascending or descending loop forms when the scaled dispatch and loop limits fit |
| `gid_tiled_index_plus_offset_inbounds_when_dispatch_fits` | 1D tiled dispatch: `(gid.x / tile_width) * tile_stride + (gid.x % tile_width) + offset` < buf.length when host-validated tiled groups fit |
| `clamp_noop_when_inbounds` | min(gid, len-1) = gid when gid < len (connects proof to transform) |
| `gid_2d_inbounds` | Both components bounded independently for 2D dispatch |
| `flat_index_2d_inbounds` | gid.y * width + gid.x < width * height when components bounded |
| `flat_index_2d_plus_offset_inbounds` | 2D flat index plus constant offset stays in bounds when width * height + offset fits |
| `gid_texture_coords_2d_inbounds_when_dispatch_fits` | Dispatch-fit precondition implies 2D gid texture coords are in bounds |
| `guarded_gid_texture_coords_2d_inbounds` | Root early-return guard against `textureDimensions(...).xy` implies 2D gid coords are in bounds |
| `gid_texture_coords_3d_inbounds_when_dispatch_fits` | Dispatch-fit precondition implies 3D gid texture coords are in bounds |
| `guarded_gid_texture_coords_3d_inbounds` | Root early-return guard against `textureDimensions(...).xyz` implies 3D gid coords are in bounds |

### `lean_fixture`

See `pipeline/lean/artifacts/proven-conditions.json` for the current count.

Specific obligation sets verified against the `lean_verified` theorems. Four
additional fixture candidates (timing-phase, hardware-path) are defined in Lean
source but not yet extracted to the proof artifact.

| Theorem | Fixture | In artifact |
|---------|---------|-------------|
| `strictHappyPathExpectedBlocking_exact` | Happy-path facts produce expected blocking list | yes |
| `strictHappyPathComparable` | Happy-path facts are comparable | yes |
| `strictMissingLeftSamplesExpectedBlocking_exact` | Missing-left facts produce expected blocking | yes |
| `strictMissingLeftSamplesComparable` | Missing-left facts are comparable | yes |
| `allowLeftNoExecutionDensityFailureExpectedBlocking_exact` | Density-failure facts produce expected blocking | yes |
| `allowLeftNoExecutionDensityFailureComparable` | Density-failure facts are comparable | yes |
| `strictTimingPhaseFailureExpectedBlocking_exact` | Timing-phase failure blocking | no (source only) |
| `strictTimingPhaseFailureComparable` | Timing-phase failure comparability | no (source only) |
| `strictHardwarePathFailureExpectedBlocking_exact` | Hardware-path failure blocking | no (source only) |
| `strictHardwarePathFailureComparable` | Hardware-path failure comparability | no (source only) |

## Policy

- not every quirk requires Lean in v0
- use `verificationMode` in quirk records to decide obligation
- obligation matrix:
  - `guard_only`: no Lean proof required
  - `lean_preferred`: proof is advisory in v0
  - `lean_required`: proof is required (`proofLevel=proven`)
- safetyClass may add stricter requirements only if configured in `config/gates.json`

## Current integration boundary (v0)

- Lean files in `pipeline/lean/Doe` are the formal contract/model source for verification semantics.
- Blocking CI gates are currently schema/correctness/trace (and claim when enabled) through `bench` scripts.
- Zig/Python runtime/gate logic mirrors Lean obligation fields and policy (`verificationMode`, `proofLevel`, blocking/advisory outcomes).
- Manual Lean typecheck/build is available through `./pipeline/lean/check.sh` (uses pinned toolchain version from `config/toolchains.json`).

## Trusted boundary and limits

Lean proves theorem families. It does not, by itself, prove that every Zig caller applies those theorems correctly.

The current trusted matcher/application boundary is:

- `runtime/zig/src/compiler/wgsl/proof/dispatch_proof_match.zig` decides which shader access shapes are theorem-covered.
- `runtime/zig/src/native/compute/doe_compute_preconditions_native.zig` enforces the host-side preconditions that replace per-access shader clamps.
- `runtime/zig/src/verification/lean_proof.zig` validates theorem presence plus artifact provenance at comptime.

So the strongest current Lean story is:

- validator redundancy
- comparability/workload-geometry model correctness
- specific bounds-elision families that are also covered by targeted Zig tests

It is not yet a fully verified runtime, because the Zig matcher/application layer remains trusted code.

## File layout

Core theorem pack (`Doe/Core/`, maps to `runtime/zig/src/core/`):
- `Doe/Core/Model.lean` — foundational enums, precedence lattice, requirement predicates
- `Doe/Core/Runtime.lean` — deterministic matching, scoring, selector, driver-range matching
- `Doe/Core/Dispatch.lean` — dispatch-level theorems (`tautological` and `comptime_verified`)
- `Doe/Core/DeterminismPolicy.lean` — policy-layer determinism contracts for `stable-token`, trigger evaluation, fixed-priority choice, and reviewed-choice decision acceptance
- `Doe/Core/NumericStabilityPolicy.lean` — numeric-instability trigger, route-selection, and route-to-selection contracts for selective stable rerun
- `Doe/Core/Bridge.lean` — obligation gate evaluation from dispatch decisions

Current numeric-stability proof scope is intentionally narrow:
- trigger predicate correctness
- triggered-vs-fallback route selection
- route-to-selection semantics for `accept-fast`, `prefer-stable`, and `abstain`

It still does not attempt to prove floating-point equivalence or discovery
heuristics.

Full theorem pack (`Doe/Full/`, maps to `runtime/zig/src/full/`):
- `Doe/Full/Comparability.lean` — comparability obligation model (`lean_verified`)
- `Doe/Full/ComparabilityFixtures.lean` — parity fixtures (`lean_fixture`)
- `Doe/Full/WorkloadGeometry.lean` — arbitrary-`Nat` workload-geometry theorems feeding execution-shape comparability

Shader theorem pack (`Doe/Shader/`, maps to `runtime/zig/src/compiler/wgsl/`):
- `Doe/Shader/ComputeBounds.lean` — compute dispatch bounds safety, proving global_invocation_id < array_length under dispatch-fit preconditions. Enables bounds-check elimination in `ir_transform_robustness.zig`.

Generated theorem contract:
- `Doe/Generated/ComparabilityContract.lean` — generated from `config/comparability-obligations.json`; provides the canonical obligation IDs, fact record, and `obligationsFromFacts`

Re-export shims (backward compatibility):
- `Doe/Model.lean`, `Doe/Runtime.lean`, `Doe/Dispatch.lean`, `Doe/Bridge.lean`, `Doe/Comparability.lean`, `Doe/ComparabilityFixtures.lean` re-export from `Doe.Core.*` / `Doe.Full.*`.

Extraction:
- `Doe/Extract.lean` — proof artifact extraction program, imports from both Core and Full

## Bridge layer contract

- input: runtime `DispatchResult` stream
- optional override: `SafetyProofOverride` maps safety class to stricter proof level requirements
- output per matched quirk (`QuirkLeanObligation`) with:
  - `quirkId`
  - `requiresLean`
  - `requiredProofLevel` (`none` = no Lean requirement)
  - `actualProofLevel`
  - `isBlocking`
  - `isAdvisory`
- v0 policy:
  - `lean_required` sets blocking requirement to `proven`
  - `lean_preferred` is intentionally advisory only when explicitly driven by override
  - default safety overrides remain empty (`none`)

## Proof artifact extraction

- `./pipeline/lean/generate_comparability_contract.py` regenerates `Doe/Generated/ComparabilityContract.lean` from `config/comparability-obligations.json` before typecheck/extraction.
- `./pipeline/lean/extract.sh` compiles all Lean modules and runs `Doe/Extract.lean` to produce `pipeline/lean/artifacts/proven-conditions.json`.
- The artifact lists all verified theorems with their tier classification, records the active comparability contract hash, evaluates decidable propositions, and maps theorems to Zig runtime elimination targets.
- The artifact also records a provenance block covering:
  - the pinned Lean toolchain ref
  - `pipeline/lean/Doe/Extract.lean`
  - the deterministic Lean source tree hash under `pipeline/lean/Doe`
  - the generated comparability contract
  - the shared proof-pattern spec in `config/lean-proof-patterns.json`
- Artifact schema: `config/proof-artifact.schema.json`.
- CI runs extraction after typecheck and uploads the artifact (see `.github/workflows/lean-check.yml`).
- The artifact is generated (not committed); `pipeline/lean/artifacts/` is gitignored.
- Zig build embeds the artifact at comptime via `-Dlean-verified=true`.

## Shared proof-pattern contract

`config/lean-proof-patterns.json` is the canonical list of runtime proof-application IDs Doe expects to be covered today.

- `boundsPatterns` maps stable runtime pattern IDs to theorems and matcher callsites.
- `validatorElisions` maps validator-removal sites to the theorems that justify them.

This is not proof-carrying code generation, but it reduces drift by giving the artifact, the runtime gate, and the proof-pipeline tests one shared named contract.

## Zig runtime integration

When built with `-Dlean-verified=true`, `lean_proof.zig` validates the proof artifact at comptime and sets `lean_proof.lean_verified = true`. The Zig compiler dead-code-eliminates branches gated on this flag.

`lean_proof.zig` now also rejects artifacts whose provenance does not match the current Lean source tree, generated comparability contract, toolchain ref, or shared proof-pattern spec.

The `tautological` and `comptime_verified` theorems gate init-time and per-command branch elimination in `quirk/runtime.zig`. These properties are independently verifiable by Zig `comptime` — the Lean proof is a redundant second check, not the sole authority.

The `lean_verified` theorems validate the comparability obligation model used by benchmark methodology gates. These cannot be replicated by `comptime` exhaustion because they quantify over arbitrary obligation lists and arbitrary Nat-valued workload geometry. This is where Lean earns its keep.

Build chain: Lean typecheck → `extract.sh` emits `proven-conditions.json` with provenance → `build.zig` recomputes provenance from the current tree → `lean_proof.zig` validates theorem names plus provenance at comptime → runtime gates use theorem availability as compile-time switches.

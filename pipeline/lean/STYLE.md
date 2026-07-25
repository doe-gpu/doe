# Doe Lean style guide

This guide is the Lean style contract for `pipeline/lean/`.

## Core principles

- Theorems exist to eliminate runtime branches. Every theorem must have a
  corresponding runtime callsite or obligation gate.
- Classify every theorem. The classification determines whether it is
  advisory or blocking.
- Build incrementally: prove base lemmas, compose into stronger theorems.
- Keep proof artifacts reproducible via provenance metadata.

## Module structure

```
Doe/
  Core/         -- foundational types, enums, dispatch, matching
  Full/         -- comparability, workload geometry
  Shader/       -- compute bounds, IR safety
  Generated/    -- auto-generated from config (not hand-edited)
  Extract.lean  -- artifact extraction program
```

- This diagram is representative, not exhaustive; it names the main module
  families without listing every file.
- `Core/` holds types and theorems that mirror `runtime/zig/src/` runtime
  logic.
- `Full/` holds higher-level obligation models and fixture tests.
- `Shader/` holds bounds proofs for WGSL/IR transforms.
- `Generated/` holds files produced by
  `pipeline/lean/generate_comparability_contract.py`. The proof artifact
  itself is emitted by `pipeline/lean/extract.sh`. Do not hand-edit either
  output.
- Backward-compatibility re-export shims live at `Doe/Model.lean`,
  `Doe/Runtime.lean`, etc. Keep them thin when practical; some legacy shims are
  longer because they bridge staged migrations.

## File naming

- `PascalCase.lean` for all module files: `Model.lean`, `Runtime.lean`,
  `ComputeBounds.lean`, `IrTypePreserved.lean`.
- Directory structure mirrors the Lean namespace: `Doe/Core/Model.lean`
  defines `Doe.Core.Model`.
- Generated files go in `Doe/Generated/`.

## Naming

- **Types and structures**: `PascalCase` (`DeviceProfile`, `Quirk`,
  `WorkloadGeometry`, `DispatchDecision`)
- **Inductive constructors**: follow the existing constructor style in the
  file. Many single-word constructors use lowercase tags such as `.vulkan` and
  `.metal`; multiword constructors often keep camelCase spelling such as
  `.copyBufferToTexture` and `.dispatchIndirect`.
- **Theorems**: use the established naming family for the file. `camelCase`
  is common in `Core/`; snake_case also appears in shader/bounds theorem
  families (`scopeCommandTableComplete`, `gid_component_lt_total`,
  `identityActionPreservesCommand`)
- **Definitions and functions**: `camelCase` (`vendorMatch`,
  `profileMatches`, `scoreQuirk`, `selectForProfile`)
- **Abbreviations**: `camelCase` (`abbrev ExprTypeArray := List Nat`)
- **Hypothesis names**: short `h_` prefix describing the condition
  (`h_wid`, `h_lid`, `h_fit`, `h_fit_comm`)

## Theorem classification

Theorems that feed runtime gates, extraction artifacts, or review fixtures
should carry a classification comment. The five categories are:

| Category | Meaning | Requires Lean |
|----------|---------|---------------|
| `tautological` | Follows from construction (rfl, by-definition) | No |
| `comptime_verified` | Finite enum exhaustion | No |
| `lean_verified` | Quantified over unbounded domains | Yes |
| `lean_required` | Blocking; must pass for runtime gate | Yes |
| `lean_fixture` | Concrete test case with `native_decide` | Yes |

Place the classification as a comment above or below the theorem:

```lean
-- Classification: lean_verified (quantified over unbounded Nat domains).
theorem gid_component_lt_total
    (workgroup_id local_id workgroup_size num_workgroups array_length : Nat)
    (h_wid : workgroup_id < num_workgroups)
    (h_lid : local_id < workgroup_size)
    (h_fit : workgroup_size * num_workgroups ≤ array_length)
    : globalInvocationId workgroup_id local_id workgroup_size < array_length :=
```

## Proof style

**Tactic mode** is the default. Use `by` blocks:

```lean
theorem toggleAlwaysSupported (q : Quirk) :
    q.scope = .driver_toggle → ∀ cmd : CommandKind, supportsQuirk q cmd := by
  intro h cmd
  simp [supportsQuirk, supportsScope, h]
```

**Term mode / `rfl`** for trivial reflexivity:

```lean
theorem critical_is_max_rank :
    SafetyClass.critical.rank = 3 := by rfl
```

**`native_decide`** for decidable propositions over finite domains:

```lean
-- Classification: lean_fixture.
theorem strictHappyPathComparable :
    comparableFromFacts strictHappyPathFacts = true := by native_decide
```

**`calc` blocks** for chained inequalities in unbounded proofs:

```lean
calc
  workgroup_id * workgroup_size + local_id
      < workgroup_id * workgroup_size + workgroup_size := h_local
  _ = (workgroup_id + 1) * workgroup_size := h_step
  _ ≤ num_workgroups * workgroup_size := h_wid_mul
  _ ≤ array_length := h_fit_comm
```

**Induction** for unbounded list/structure theorems:

```lean
theorem applyPass_is_prefix (arr : ExprTypeArray) (pass : TransformPass) :
    IsPrefix arr (applyPass arr pass) := by
  induction pass generalizing arr with
  | nil => exact IsPrefix_refl arr
  | cons step rest ih =>
    exact IsPrefix_trans arr _ _ (step_is_prefix arr step) (ih _)
```

## Preconditions

- Name preconditions as explicit hypotheses, not embedded in the goal.
- Document which preconditions are GPU hardware guarantees vs host-side
  checks.

```lean
-- Preconditions:
-- h_wid: workgroup_id < num_workgroups  (GPU hardware guarantee)
-- h_lid: local_id < workgroup_size      (GPU hardware guarantee)
-- h_fit: workgroup_size * num_workgroups ≤ array_length  (host-side)
```

## Lemma composition

- Prove base lemmas first, then compose into stronger results.
- Reuse existing theorems via `have h := theorem_name ...`.
- Do not duplicate proof logic across theorems.

## Comments

- File header: `--` comment block identifying the module, what it mirrors
  in the runtime, and its classification.
- `/-- ... --/` doc comments for definitions and public theorems.
- `-- ...` inline comments for proof strategy notes.
- Section separators: `-- ---` lines for major sections.
- Some foundational legacy files still omit file headers; add them when those
  files are edited for substantive work.

```lean
-- Doe/Shader/ComputeBounds.lean
--
-- Bounds safety for global_invocation_id indexing into runtime-sized arrays.
-- Mirrors: runtime/zig/src/compiler/wgsl/ir/ir_transform_robustness.zig
-- Classification: lean_required.
```

## Runtime mirror contract

- Every extracted theorem has one generated `theoremMetadata` row.
- Runtime-elimination metadata binds the Zig source path, mirrored symbol, and
  source SHA-256. Extraction fails when a source or symbol is absent.
- Comments may explain the model, but they are not the runtime mirror
  authority.
- When the Zig source changes, the Lean model must be updated in the same
  change or flagged as stale in the status log (`docs/status.md`, with dated
  entries in the current `docs/status/*.md` shard).

## Extraction and artifacts

- Theorems are extracted to `pipeline/lean/artifacts/proven-conditions.json`
  via `Doe/Extract.lean` and `pipeline/lean/extract.sh`.
- The artifact includes provenance: toolchain ref, source tree hash,
  generated contract hash, and theorem-metadata generator hash.
- The artifact schema is `config/proof-artifact.schema.json`.
- Zig consumes the artifact at compile time via `-Dlean-verified=true`.

## Toolchain

- Lean version is pinned in `config/toolchains.json` and the repo build/check
  scripts.
- Build via `pipeline/lean/check.sh` and `pipeline/lean/extract.sh` with
  explicit `LEAN_PATH`.
- CI workflows run typecheck and extraction; blocking policy is governed by
  `docs/process.md`.

# CATSCAN: Compiler

Parent: [Zig runtime](../../CATSCAN.md)

## Target

Preserve declared program meaning and identity while producing explicit, target-valid lowering artifacts or typed rejection.

## Authority

- Owns shared compiler representations, semantic validation, target selection, lowering provenance, and emitter contracts.
- Does not own runtime scheduling, benchmark conclusions, or backend driver behavior.

## Scope

- Includes files beneath this directory except child-chartered components, which narrow this authority.

## Contracts

Inputs:
- Compiler architecture: [`../../../../docs/shader-compiler-architecture.md`](../../../../docs/shader-compiler-architecture.md).
- Source program and target descriptors supplied by the calling runtime or manifest.

Outputs:
- Typed IR, target artifacts, lowering identities, diagnostics, and rejection causes.

## Invariants

- Source, semantic, realization, and target identity stay linked.
- Target-specific optimization cannot introduce undeclared semantic divergence.
- Unsupported source or target behavior fails closed.

## Acceptance

- Declared backend coverage and source-to-artifact identity pass compiler gates.
- Evidence: [`../../../../bench/gates/wgsl_backend_matrix_gate.py`](../../../../bench/gates/wgsl_backend_matrix_gate.py).

## Non-goals

- Hiding target policy inside emitters or treating compilation success as execution correctness.

## Freedom

Any mechanism is permitted if it preserves these boundaries and passes the acceptance evidence.

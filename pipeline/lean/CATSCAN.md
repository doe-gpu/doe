# CATSCAN: Lean verification

Parent: [Pipeline](../CATSCAN.md)

## Target

Discharge named compiler, runtime, artifact, or comparability obligations and export proof state that removes or gates executable behavior.

## Authority

- Owns Lean models, theorems, extraction, proof artifacts, and proof-level classification.
- Does not own runtime implementation, application correctness, hardware claims, or abstract theorem counts as product value.

## Scope

- Includes files beneath this directory except child-chartered components, which narrow this authority.

## Contracts

Inputs:
- Verification boundary: [`README.md`](README.md).
- Named runtime or artifact obligations selected by configuration.

Outputs:
- Reproducible proof artifacts and extracted conditions consumed by gates or runtime specialization.

## Invariants

- Every promoted proof has a named executable or artifact consumer.
- Lean removes or gates behavior; it does not become a hot-path runtime interpreter.
- Proof evidence and physical execution evidence remain separate.

## Acceptance

- The proof pipeline builds, tests, extracts, and validates its tracked artifacts.
- Evidence: [`test_proof_pipeline.py`](test_proof_pipeline.py).

## Non-goals

- Replacing sandboxing, deployment security, numerical testing, or hardware validation.

## Freedom

Any mechanism is permitted if it preserves these boundaries and passes the acceptance evidence.

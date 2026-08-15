# CATSCAN: TSIR

Parent: [Compiler](../CATSCAN.md)

## Target

Represent semantic kernels and target realizations explicitly enough for deterministic planning, parity, and spatial lowering.

## Authority

- Owns TSIR schemas, semantic nodes, realization choices, target descriptors, planning, reference interpretation, and TSIR emitters.
- Does not own source manifests, model orchestration, hardware claims, or legacy classifier-template semantics.

## Scope

- Includes files beneath this directory except child-chartered components, which narrow this authority.

## Contracts

Inputs:
- Lowering plan: [`../../../../../docs/tsir-lowering-plan.md`](../../../../../docs/tsir-lowering-plan.md).
- Source kernels and hash-bound target descriptors.

Outputs:
- Semantic and realization digests, plans, target artifacts, parity receipts, and typed rejections.

## Invariants

- Semantic identity and target realization identity remain separate and hash-bound.
- Parity compares against the declared oracle, never another backend by assumption.
- Bootstrap, simulator, and hardware evidence never conflate.

## Acceptance

- Bootstrap and real-kernel contracts execute through the TSIR test catalog.
- Evidence: [`../../../tests/tsir`](../../../tests/tsir).

## Non-goals

- Claiming a completed universal IR or broad hardware execution from scaffolded emitters.

## Freedom

Any mechanism is permitted if it preserves these boundaries and passes the acceptance evidence.

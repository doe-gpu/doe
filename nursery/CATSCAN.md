# CATSCAN: Nursery

Parent: [Doe](../CATSCAN.md)

## Target

Retain explicitly referenced incubation and CI compatibility surfaces without implying product maturity from the directory name.

## Authority

- Owns only nursery paths referenced by current workflows or explicit migration contracts.
- Does not own product strategy, promoted APIs, or permanent duplicate implementations.

## Scope

- Includes files beneath this directory except child-chartered components, which narrow this authority.

## Contracts

Inputs:
- Nursery boundary: [`README.md`](README.md).
- Tool classification: [`../config/tool-surfaces.json`](../config/tool-surfaces.json).

Outputs:
- Bounded compatibility or incubation inputs consumed by named repository workflows.

## Invariants

- Every live nursery surface has a named consumer.
- Incubation state cannot support a promoted product claim.
- Duplicate implementations retain an explicit migration or removal condition.

## Acceptance

- Referenced nursery paths remain visible to the repository tooling surface and CI contracts.
- Evidence: [`../bench/gates/tool_surface_gate.py`](../bench/gates/tool_surface_gate.py).

## Non-goals

- A dumping ground for abandoned or unowned code.

## Freedom

Any mechanism is permitted if it preserves these boundaries and passes the acceptance evidence.

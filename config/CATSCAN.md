# CATSCAN: Configuration and schemas

Parent: [Doe](../CATSCAN.md)

## Target

Make Doe policy, schemas, support boundaries, and machine-owned registries explicit and deterministically validatable.

## Authority

- Owns versioned configuration, schema contracts, policy thresholds, and generated configuration state.
- Does not own runtime implementation, narrative status, or generated execution evidence.

## Scope

- Includes files beneath this directory except child-chartered components, which narrow this authority.

## Contracts

Inputs:
- Process law: [`../docs/process.md`](../docs/process.md).
- Schema enforcement: [`../docs/config-schema-enforcement.md`](../docs/config-schema-enforcement.md).

Outputs:
- Registered schemas, policies, manifests, support matrices, and workload catalogs consumed by gates and runtime surfaces.

## Invariants

- Runtime-visible fields have schemas and migrations.
- Defaults and thresholds are explicit; hidden switches are forbidden.
- Generated state names its source and can be reproduced.

## Acceptance

- Every registered schema and sample validates under the canonical schema gate.
- Evidence: [`../bench/gates/schema_gate.py`](../bench/gates/schema_gate.py).

## Non-goals

- Encoding implementation algorithms or mutable benchmark conclusions in configuration.

## Freedom

Any mechanism is permitted if it preserves these boundaries and passes the acceptance evidence.

# CATSCAN: Trace and replay

Parent: [Pipeline](../CATSCAN.md)

## Target

Preserve execution identity and first-failure evidence in deterministic traces that can be compared and replayed.

## Authority

- Owns trace envelopes, receipt helpers, dispatch comparison, and replay tooling.
- Does not own runtime truth, output-oracle truth, benchmark claims, or fallback policy.

## Scope

- Includes files beneath this directory except child-chartered components, which narrow this authority.

## Contracts

Inputs:
- Trace contract: [`README.md`](README.md).
- Runtime and workload artifacts supplied by governed executors.

Outputs:
- Hash-linked traces, replay results, receipt fragments, and dispatch comparisons.

## Invariants

- Trace and replay artifacts bind their source modules, operations, and inputs.
- Replay cannot strengthen the claim class of the original execution.
- Missing or inconsistent trace state fails explicitly.

## Acceptance

- Python and JavaScript trace tooling preserve deterministic receipt and replay behavior.
- Evidence: [`test_trace_tools.py`](test_trace_tools.py).

## Non-goals

- Treating observed traces as independent semantic oracles.

## Freedom

Any mechanism is permitted if it preserves these boundaries and passes the acceptance evidence.

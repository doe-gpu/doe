# CATSCAN: Documentation

Parent: [Doe](../CATSCAN.md)

## Target

Keep human-facing strategy, contracts, navigation, and status boundaries discoverable without replacing machine-owned evidence.

## Authority

- Owns canonical prose, documentation routing, and the distinction between intended behavior and measured state.
- Does not own runtime behavior, mutable verdicts, benchmark values, or artifact identities.

## Scope

- Includes files beneath this directory except child-chartered components, which narrow this authority.

## Contracts

Inputs:
- Repository goals: [`../GOALS.md`](../GOALS.md).
- Documentation law: [`process.md`](process.md).

Outputs:
- Strategy, architecture, contracts, runbooks, generated component index, and status front doors.

## Invariants

- Prose links to evidence instead of copying mutable results.
- Strategy, contracts, status, and historical archives remain distinct.
- Public wording never promotes diagnostic or scaffolded evidence.

## Acceptance

- Current local Markdown links resolve and component routing is generated from charters.
- Evidence: [`../bench/tests/test_doc_link_coverage.py`](../bench/tests/test_doc_link_coverage.py).

## Non-goals

- Becoming a parallel source of benchmark, support, or release state.

## Freedom

Any mechanism is permitted if it preserves these boundaries and passes the acceptance evidence.

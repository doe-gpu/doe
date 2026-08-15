# CATSCAN: Upstream quirk agent

Parent: [Pipeline](../CATSCAN.md)

## Target

Mine upstream changes into normalized, reviewable candidate quirks without silently changing Doe behavior.

## Authority

- Owns upstream change ingestion, classification, watchdog operation, and candidate quirk output.
- Does not own runtime binding, verification, promotion, or product strategy.

## Scope

- Includes files beneath this directory except child-chartered components, which narrow this authority.

## Contracts

Inputs:
- Mining contract: [`README.md`](README.md).
- Pattern and upstream data selected by the pipeline invocation.

Outputs:
- Provenance-bound candidate quirks and typed mining failures for later normalization and verification.

## Invariants

- Upstream source identity and extraction decisions remain reproducible.
- A mined pattern is not a runtime rule or accepted fix.
- Network, parsing, and classification failures remain explicit.

## Acceptance

- Mining tests preserve source attribution, deterministic normalization, and rejection behavior.
- Evidence: [`test_mine_quirks.py`](test_mine_quirks.py).

## Non-goals

- Automatically modifying runtime policy or accepting an upstream workaround as correct.

## Freedom

Any mechanism is permitted if it preserves these boundaries and passes the acceptance evidence.

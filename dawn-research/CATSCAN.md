# CATSCAN: Dawn research

Parent: [Doe](../CATSCAN.md)

## Target

Convert pinned upstream Dawn changes into reviewable patterns and candidates for Doe's governed failure-and-fix loop.

## Authority

- Owns Gerrit change ingestion, research manifests, pattern analysis, trend summaries, and candidate packs.
- Does not own Doe runtime behavior, claim promotion, or automatic workaround adoption.

## Scope

- Includes files beneath this directory except child-chartered components, which narrow this authority.

## Contracts

Inputs:
- Research workflow: [`README.md`](README.md).
- Pinned manifest and patterns: [`data/dawn_research_manifest.json`](data/dawn_research_manifest.json).

Outputs:
- Source-bound review rows, workaround signals, hotspots, trends, and candidate packs.

## Invariants

- Raw upstream data remains distinguishable from derived analysis.
- A research signal is diagnostic until normalized, verified, bound, and tested.
- Candidate generation preserves review and source provenance.

## Acceptance

- Research scripts reproduce outputs from the declared manifest and patterns.
- Evidence: [`scripts/run_dawn_driverradar.sh`](scripts/run_dawn_driverradar.sh).

## Non-goals

- Mirroring Dawn, copying upstream policy blindly, or declaring Doe superiority.

## Freedom

Any mechanism is permitted if it preserves these boundaries and passes the acceptance evidence.

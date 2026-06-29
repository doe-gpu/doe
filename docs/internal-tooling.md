# Internal tooling

This document separates Doe's repo-only tooling from its public package
surface.

The canonical machine-readable contract is [`config/tool-surfaces.json`](../config/tool-surfaces.json).
If prose and tooling metadata disagree, treat the schema-backed manifest as the
source of truth.

## Public package surface

The current public package contract is:

- `doe-gpu`
- its documented subpath exports, including `api`, `native`, `plan`, `capture`,
  `compute`, `browser`, and compatibility `hybrid`
- the package docs in [`packages/doe-gpu/README.md`](../packages/doe-gpu/README.md)

Advanced helper exports such as `createDoeRuntime()` and
`runDawnVsDoeCompare()` are still part of the package surface, but they are
repo-adjacent helpers, not the canonical operator front doors for benchmark or
release work.

The npm package does not ship compare, bench, or release pipeline CLIs.
It also does not ship a public `doe-gpu/csl` subpath until the CSL HostPlan and
receipt contracts are stable enough to treat as semver package surface.

## Claim and reporting boundary

Human-facing performance claims must come from current claim metadata, not from
stale README prose, old SVGs, or local scratch artifacts.

Public README claim rows are indexed in
[`reports/claim-index.json`](../reports/claim-index.json). A public claim row
must state its backend, surface, comparator, metric direction, result, claim
state, and evidence path. Diagnostic rows may stay visible, but they must be
described as diagnostic or status-only rather than claimable speed evidence.

Package-local docs may point to the claim index or a package-local evidence
artifact, but they must not hardcode benchmark percentages without an explicit
claim state and current artifact path.

## Internal operator tooling

These are repo-only contributor/operator surfaces:

- [`bench/cli.py`](../bench/cli.py)
- [`bench/runners/run_release_pipeline.py`](../bench/runners/run_release_pipeline.py)
- [`bench/runners/run_blocking_gates.py`](../bench/runners/run_blocking_gates.py)
- [`bench/tools/generate_backend_workloads.py`](../bench/tools/generate_backend_workloads.py)
- TSIR parity tooling ([`bench/tools/doe_parity.py`](../bench/tools/doe_parity.py),
  [`bench/tools/tsir_manifest_lowering.py`](../bench/tools/tsir_manifest_lowering.py),
  [`bench/gates/nightly_tsir_parity_canary.py`](../bench/gates/nightly_tsir_parity_canary.py));
  full surface + fixtures enumerated in
  [`bench/README.md`](../bench/README.md) §TSIR parity tooling
- [`runtime/zig/README.md`](../runtime/zig/README.md) and `doe-zig-runtime`
- browser benchmark scripts under [`browser/chromium`](../browser/chromium/README.md)

Repo-only directories should not be treated as public product commitments unless
`config/tool-surfaces.json` marks them `audience=public`.

In practice:

- `bench/` (including `bench/cts/`), `browser/chromium/`, `examples/`,
  `pipeline/`, top-level `scripts/`, and `demos/` are internal
- `packages/doe-gpu/` is the public npm surface
- `packages/doe-gpu/src/browser.js` is public API compatibility over incumbent
  browser WebGPU, not the Chromium runtime replacement lane
- overlapping helpers are allowed, but repo workflows are still owned by the
  repo tooling, not by the npm package

## Archive and deprecated areas

These areas exist for migration, reference, or research and should not be read
as active public product surfaces:

- legacy npm names `@simulatte/webgpu` and `@simulatte/webgpu-doe`
- `dawn-research/`
- `nursery/`

Experimental demo applications stay under `demos/`, but they are still
repo-only/internal unless the surface manifest explicitly marks them public.

When a question is about public package behavior, ignore archive and repo-only
tooling unless the user explicitly asks about them.

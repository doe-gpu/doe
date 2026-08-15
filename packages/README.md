# Packages

`packages/` contains Doe's public JavaScript package surface:

- `packages/doe-gpu/`
  - `doe-gpu`, the merged runtime and helper package

Repo-only operator tooling lives outside `packages/` and is documented in
[`docs/internal-tooling.md`](../docs/internal-tooling.md). The public package
contract is the package exports plus
[`packages/doe-gpu/README.md`](./doe-gpu/README.md), not the scripts under
`bench/`, `browser/`, or `pipeline/`.

Within `doe-gpu`, subpaths such as `api`, `native`, `node-webgpu`,
`node-webgpu-loader`, `node-webgpu-process`,
`program-bundle`, `plan`, `capture`, `compute`, `browser`, and `hybrid` are
entrypoints of one package, not separate products. The `csl` runtime surface is
intentionally not exported yet. `packages/doe-gpu/package.json` owns the exact
list.

## Boundary rules

- `doe-gpu` and `doe-gpu/compute` are native-runtime package surfaces.
- `doe-gpu/browser` is an API compatibility wrapper over the browser's existing
  WebGPU runtime. It is not the Chromium replacement lane.
- `doe-gpu/node-webgpu` owns strict provider acquisition plus provider-neutral
  DoeProof exact-output and lifecycle receipts. It does not assign application
  credit to DoeRuntime.
- `doe-gpu/node-webgpu-loader` is the narrow unchanged-application seam. It
  redirects only the exact `webgpu` import to one declared provider and fails
  closed instead of searching for an ambient fallback.
- `doe-gpu/node-webgpu-process` executes that unchanged application under
  bounded process policy, verifies effective loader identity and exact output,
  and emits a provider-neutral, self-validating receipt.
- `doe-proof-node` exposes the governed process contract to CI through
  hash-bound `run`, `verify`, `inspect`, `compare`, and `replay` commands. It
  cannot assign performance or runtime-ownership credit.
- `doe-gpu/plan` and `doe-gpu/capture` expose portable command/capture
  contracts, not arbitrary JavaScript source translation.
- Benchmark, release, claim, and browser-integration operator flows remain
  repo-only unless `config/tool-surfaces.json` marks them public.
- Public performance wording should cite `reports/claim-index.json` or a
  package-local evidence artifact with an explicit claim state.

## Deprecated

- `@simulatte/webgpu` — legacy npm name, now redirected to `doe-gpu`
- `@simulatte/webgpu-doe` — legacy npm name, now redirected to `doe-gpu`

# Packages

`packages/` contains Doe's public JavaScript package surface:

- `packages/doe-gpu/`
  - `doe-gpu`, the merged runtime and helper package

Repo-only operator tooling lives outside `packages/` and is documented in
[`docs/internal-tooling.md`](../docs/internal-tooling.md). The public package
contract is the package exports plus
[`packages/doe-gpu/README.md`](./doe-gpu/README.md), not the scripts under
`bench/`, `browser/`, or `pipeline/`.

Within `doe-gpu`, subpaths such as `api`, `native`, `plan`, `capture`,
`compute`, `browser`, and `hybrid` are subpath entrypoints of one package, not
separate products. The `csl` runtime surface is intentionally not exported yet.

## Boundary rules

- `doe-gpu` and `doe-gpu/compute` are native-runtime package surfaces.
- `doe-gpu/browser` is an API compatibility wrapper over the browser's existing
  WebGPU runtime. It is not the Chromium replacement lane.
- `doe-gpu/plan` and `doe-gpu/capture` expose portable command/capture
  contracts, not arbitrary JavaScript source translation.
- Benchmark, release, claim, and browser-integration operator flows remain
  repo-only unless `config/tool-surfaces.json` marks them public.
- Public performance wording should cite `reports/claim-index.json` or a
  package-local evidence artifact with an explicit claim state.

## Deprecated

- `@simulatte/webgpu` — legacy npm name, now redirected to `doe-gpu`
- `@simulatte/webgpu-doe` — legacy npm name, now redirected to `doe-gpu`

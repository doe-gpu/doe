# Doe

<p align="center">
  <img src="assets/doe-logo.svg" alt="Doe logo" width="96" />
</p>

<p align="center">
  <a href="https://github.com/doerun/doe/actions/workflows/webgpu-package-surface.yml"><img alt="Build" src="https://img.shields.io/github/actions/workflow/status/doerun/doe/webgpu-package-surface.yml?branch=main&amp;label=build" /></a>
  <a href="https://www.npmjs.com/package/doe-gpu"><img alt="npm version" src="https://img.shields.io/npm/v/doe-gpu.svg?label=version" /></a>
  <a href="https://github.com/doerun/doe/blob/main/LICENSE"><img alt="License: Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-blue.svg" /></a>
  <a href="https://github.com/doerun/doe/pulls"><img alt="PRs welcome" src="https://img.shields.io/badge/PRs-welcome-brightgreen.svg" /></a>
</p>

Doe is a source-preserving accelerator runtime and compiler. It keeps WGSL and
model-program bodies visible as it validates, lowers, and runs them. Hash-linked
receipts bind the input program to the selected lowering, backend, and result,
giving parity and benchmark gates an execution path they can replay.

Doppler owns the portable Program Bundle. Doe accepts that closed, versioned
bundle and preserves its declared identity through normalization, execution,
and backend receipts. Normalized execution and HostPlan operate today. The TSIR
compiler surface has landed, but the live CSL lane still uses its
classifier/template path; end-to-end TSIR remains target work in the
[ingest status](docs/doppler-ingest.md).

## Objective

Doe has two targets: replace Dawn and Tint in Chromium-family WebGPU, and
retarget Doppler Program Bundles to Cerebras without losing program identity.
The runtime hoists stable validation and lowering decisions out of execution,
keeps remaining dynamic checks explicit in Zig, and promotes performance claims
only after comparable receipts pass their gates. The
[replacement frontier](config/dawn-replacement-frontier.json) records the
remaining browser, runtime, compiler, and platform blockers.

## Surfaces

| Surface | Current boundary |
| --- | --- |
| [`doe-gpu`](packages/doe-gpu/README.md) | Public npm package for Node, Bun, and Deno. Its `browser` subpath wraps the browser's incumbent WebGPU implementation. |
| Native runtime | `doe-zig-runtime` and `libwebgpu_doe` drive repo development, governed comparisons, and lane-specific drop-in artifacts. They are not a universal runtime release. |
| Fawn/Chromium | Repo-only browser integration and diagnostics. The claim index does not yet contain a public Doe browser release. |
| Compiler and lowering | The WGSL compiler emits backend artifacts for Metal, SPIR-V/Vulkan, and DXIL/HLSL. Doppler bundles currently reach normalized execution and HostPlan/CSL. Unsupported contracts fail explicitly. |

Public performance wording comes from claim-indexed rows in
[`reports/claim-index.json`](reports/claim-index.json) and their receipt
sidecars. The browser-release row remains scaffolded; promotion requires a real
HTTPS archive, provenance, proof surface, launch receipt, and platform-specific
comparisons.

## Execution paths

```text
WGSL source ----------> WGSL IR + emitters -------> Metal | SPIR-V | DXIL

Doppler Program Bundle -> normalized execution -+-> WebGPU executor
                                                +-> HostPlan | CSL

input + lowering + backend + result identities ---> receipts -> gates
                                                              -> claim index
```

## Build

Install the public package:

```bash
npm install doe-gpu
```

Build the native lane from source with Zig 0.15.2 and Node.js 18+:

```bash
git clone https://github.com/doerun/doe.git
cd doe
cd runtime/zig
zig build dropin
cd ../..
node packages/doe-gpu/scripts/build-addon.js
node packages/doe-gpu/test/smoke/test-smoke-load.js
```

The smoke command checks load and export wiring without requiring a GPU.
Legacy package names `@simulatte/webgpu` and `@simulatte/webgpu-doe` redirect to
`doe-gpu`.

## Evidence

The chart names each backend, surface, comparator, metric direction, claim
state, and artifact pointer. Raw timings remain in the indexed receipts.

![Doe backend evidence summary](assets/readme/backend-evidence-summary.svg)

The [support matrix](docs/doe-support-matrix.md) records the broader platform
and surface inventory.

## Start here

| Reader | Entry points |
| --- | --- |
| Package users | [`packages/doe-gpu/README.md`](packages/doe-gpu/README.md), [`docs/package-model.md`](docs/package-model.md) |
| Runtime contributors | [`runtime/zig/README.md`](runtime/zig/README.md), [`docs/architecture.md`](docs/architecture.md), [`docs/status.md`](docs/status.md) |
| Compiler contributors | [`docs/shader-compiler-architecture.md`](docs/shader-compiler-architecture.md), [`docs/doppler-ingest.md`](docs/doppler-ingest.md), [`docs/tsir-lowering-plan.md`](docs/tsir-lowering-plan.md), [`docs/status/tsir.md`](docs/status/tsir.md) |
| Evidence reviewers | [`bench/README.md`](bench/README.md), [`docs/process.md`](docs/process.md), [`docs/claim-discipline.md`](docs/claim-discipline.md), [`reports/claim-index.json`](reports/claim-index.json) |

License details: [`docs/licensing.md`](docs/licensing.md).

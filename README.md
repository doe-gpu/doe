# Doe

<p align="center">
  <img src="assets/doe-logo.svg" alt="Doe logo" width="96" />
</p>

Doe is a source-preserving accelerator runtime and compiler. It keeps shader and
program bodies inspectable, lowers them across execution targets, and writes
receipts for what ran.

Doe has three non-interchangeable surfaces:

- A native/package WebGPU runtime path for Node, Bun, Deno, drop-in, and
  embedded workloads.
- A browser compatibility shim plus a separate governed Chromium integration
  lane. The shim wraps the browser's existing WebGPU runtime; it is not Doe
  running inside the browser.
- A compiler/lowering path for source-visible WGSL and model-program contracts.

The strategy is to beat the Chromium WebGPU incumbent stack by preserving
program identity across lowering, keeping the native WebGPU runtime surface
independent, and making every claim receipt-backed. Chromium is the browser
surface to win, Dawn is the runtime incumbent to beat, and Tint is the compiler
incumbent to beat.

Published npm surface: [`packages/doe-gpu/README.md`](packages/doe-gpu/README.md).

## Current release read

Doe has package and native-runtime evidence that can support lane-specific
release notes, but not broad "Doe beats Dawn everywhere" or public browser
release language. Public wording must stay tied to
[`reports/claim-index.json`](reports/claim-index.json) and the claim sidecars
named there.

The browser lane is still a separate release surface. Local Fawn/Chromium runs
can compare Doe and Dawn in the same binary, but a public Fawn Doe browser
release requires a public HTTPS archive, release-candidate provenance, proof
surface, launch receipt, and platform-specific comparison receipts.

macOS remains a first-class release lane. Linux Vulkan browser diagnostics,
Apple Metal package evidence, and npm package availability are not
interchangeable; macOS arm64 browser and native artifacts need their own
receipts before public wording claims that platform.

## Project map

```text
+-------------------------+
| Source-visible inputs   |
| WGSL | commands | plans |
+-----------+-------------+
            |
            v
+--------------------------------------------------------------+
| Doe compiler/runtime spine                                   |
| preserve identity | lower | execute | reject unsupported      |
+------+---------------+---------------+-----------------------+
       |               |               |
       v               v               v
+--------------+  +--------------+  +--------------+
| Vulkan       |  | Metal        |  | D3D12/DXIL   |
| Linux/Fawn   |  | macOS lane   |  | Windows lane |
+------+-------+  +------+-------+  +------+-------+
       |                |                |
       +----------------+----------------+
                        |
                        v
                 +-------------+          +----------------------+
                 | Receipts    |<-------->| Incumbents           |
                 | hashes/time | compare  | Dawn/Tint/Chromium   |
                 +------+------+ fairly   +----------------------+
                        |
                        v
                 +-------------+     +-------------------+
                 | Gates       |---->| Public claims     |
                 | schema/fair |     | claim-index/docs  |
                 +-------------+     +-------------------+

       +-----------------------+
       | WebGPU package        |
       | doe-gpu Node/Bun/Deno |
       +-----------+-----------+
                  |
                  v
             receipts/gates

       +---------------------+
       | Browser lane        |
       | Fawn/Chromium       |
       +----------+----------+
                  |
                  v
             receipts/gates

       +---------------------+     +---------------------+
       | TSIR / HostPlan     |---->| CSL / WSE3          |
       | spatial lowering    |     | current target lane |
       +----------+----------+     +---------------------+
                  |
                  v
       . . . retargeting candidates, not release claims . . .
       . vLLM/paged KV . TPU/XLA . Groq/LPU . Tenstorrent .
       . hosted inference . custom ASIC lanes              .
       . . . . . . . . . . . . . . . . . . . . . . . . . .
```

## What it is

- `doe-gpu`: JavaScript package entry point for WebGPU-backed workloads.
- `doe-gpu/browser`: browser API compatibility wrapper over the incumbent
  browser WebGPU runtime, not a browser runtime replacement.
- `doe-zig-runtime` and `libwebgpu_doe`: native WebGPU runtime surfaces used by
  strict and release comparison lanes.
- `runtime/zig/src/doe_wgsl`: WGSL lowering and backend emission work.
- `pipeline/trace`, `pipeline/lean`, and `bench`: trace, checking, and benchmark
  receipt surfaces.
- Model-program ingest and lowering: bundle/capture inputs, TSIR/HostPlan
  planning, backend emission, and receipt-bound replay/evidence.

## How it works

1. Workloads enter as source-visible WGSL, IR, or model-plan contracts.
2. Config selects the backend and comparability rules.
3. Doe lowers and executes the workload, or rejects unsupported contracts.
4. Bench and trace tools emit receipts.
5. Public claims point at receipt artifacts instead of prose-only summaries.

## Boundary rules

- Package, native runtime, browser shim, Chromium integration, benchmarks, and
  compiler lowering are separate surfaces.
- `reports/claim-index.json` is the public README claim inventory.
- Diagnostic evidence is useful engineering evidence, but it is not public speed
  claim language.
- Unsupported runtime or lowering behavior must fail explicitly instead of
  switching to hidden fallback behavior.

Boundary docs:

- [`docs/public-claim-boundary.md`](docs/public-claim-boundary.md)
- [`docs/runtime-surface-boundary.md`](docs/runtime-surface-boundary.md)
- [`docs/backend-evidence-matrix.md`](docs/backend-evidence-matrix.md)
- [`docs/config-schema-enforcement.md`](docs/config-schema-enforcement.md)

## Benchmark evidence

The README chart uses one reporting contract across backends: each row states
backend, surface, comparator, metric direction, result source, claim state, and
evidence path. It intentionally defers raw timings and percentages to the
current claim index and sidecar artifacts. Metal rows include claim-indexed
native strict and Bun package evidence. Native release, Node package,
Node+Bun ORT, and browser ORT stay diagnostic when the claim index marks them
diagnostic. Vulkan rows include claim-indexed native/package boundaries where indexed.
Browser rows remain diagnostic or scaffolded unless the claim index and release
gates say otherwise. Platform names matter: macOS arm64, Linux x64/AMD Vulkan,
and Chromium browser rows are separate release surfaces.
The broader Dawn/Tint replacement frontier is tracked by
`config/dawn-replacement-frontier.json` and blocked by
`bench/gates/dawn_replacement_frontier_gate.py`; universal replacement language
is not allowed until every frontier row is claim-allowed.

![Doe backend evidence summary](assets/readme/backend-evidence-summary.svg)

See [`reports/claim-index.json`](reports/claim-index.json) for the public claim
index and [`bench/out`](bench/out) for receipt payloads. Backend support status
and claim boundaries are tracked in
[`docs/doe-support-matrix.md`](docs/doe-support-matrix.md).

## Start here

- Package consumers: [`packages/doe-gpu/README.md`](packages/doe-gpu/README.md)
- Runtime contributors: [`runtime/zig/README.md`](runtime/zig/README.md)
- Benchmarks and evidence: [`bench/README.md`](bench/README.md)
- Current status and claim boundaries: [`docs/status.md`](docs/status.md)
- Public claim boundary: [`docs/public-claim-boundary.md`](docs/public-claim-boundary.md)
- Runtime surface boundary: [`docs/runtime-surface-boundary.md`](docs/runtime-surface-boundary.md)
- Backend evidence matrix: [`docs/backend-evidence-matrix.md`](docs/backend-evidence-matrix.md)
- Chromium WebGPU strategy:
  [`docs/chromium-webgpu-task-list.md`](docs/chromium-webgpu-task-list.md)
- Doppler Program Bundle ingest: [`docs/doppler-ingest.md`](docs/doppler-ingest.md)
- TSIR compiler work:
  [`docs/tsir-lowering-plan.md`](docs/tsir-lowering-plan.md),
  [`docs/loop-protocol.md`](docs/loop-protocol.md), and
  [`docs/status/tsir.md`](docs/status/tsir.md)
- Project rationale and boundaries: [`docs/thesis.md`](docs/thesis.md),
  [`docs/architecture.md`](docs/architecture.md), and
  [`docs/process.md`](docs/process.md)
- Proof and trace pipeline: [`pipeline/lean/README.md`](pipeline/lean/README.md),
  [`pipeline/trace/README.md`](pipeline/trace/README.md), and
  [`pipeline/agent/README.md`](pipeline/agent/README.md)

## Quick start

Requirements:

- Zig 0.15.2
- Node.js 18+

```bash
git clone https://github.com/doerun/doe.git
cd doe
zig build dropin
node packages/doe-gpu/scripts/build-addon.js
node packages/doe-gpu/test/smoke/test-smoke-load.js
```

That smoke path checks load and export wiring without requiring a GPU.

## Legacy package names

These legacy package names are deprecated in favor of `doe-gpu`:

- `@simulatte/webgpu`
- `@simulatte/webgpu-doe`

## License

See [`docs/licensing.md`](docs/licensing.md).

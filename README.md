# Doe

<p align="center">
  <img src="assets/doe-logo.svg" alt="Doe logo" width="96" />
</p>

Doe is a source-preserving WebGPU compute runtime and compiler for applications
that control their GPU provider. The promoted developer wedge is deliberately
narrow: Node and Bun workloads that Doe can run correctly, reliably, and
materially faster than a declared incumbent on a declared support matrix.

Receipts, replay, deterministic artifacts, and runtime policy prove those
properties. They do not substitute for them.

## What Doe is

The long-term product is a receipt-backed local compute plane for AI workloads
and autonomous software. A versioned workload enters under explicit policy;
Doe selects or enforces the provider, executes it, independently validates the
result, and returns a receipt describing what actually ran.

Doe is the strategy driver. Doppler, Dream, Columbo/Valera, Reploid/Poolday,
Cerebras, Chromium/Fawn, and outside projects are collaborators, workload
sources, design partners, proofs, hosts, baselines, or competitors. Doe owns
the runtime, compiler, workload contract, execution policy, evidence, and
release decision. The full Doe-first strategy is in
[`docs/thesis.md`](docs/thesis.md).

Node, Bun, Electron, and controlled CI are the first execution surfaces.
Chromium is a future Doe-led browser substrate: begin beneath the WebGPU/Dawn
seam, then earn adjacent GPU-heavy browser work with separate evidence. Doe
is not an agent SDK, browser automation framework, or general Chromium fork.

The complete product strategy lives in
[`docs/thesis.md`](docs/thesis.md). Other documentation defines contracts,
procedures, support state, or evidence; it does not define a second strategy.

## Install

```bash
npm install doe-gpu
node node_modules/doe-gpu/examples/node-first-kernel.mjs
```

Package usage and supported entrypoints are documented in
[`packages/doe-gpu/README.md`](packages/doe-gpu/README.md).

## Evidence boundary

Measured results belong to [`reports/claim-index.json`](reports/claim-index.json)
and its referenced artifacts. This table names evidence classes, not universal
performance claims.

| Backend | Surface or workload | Comparator | Result | Evidence state | Evidence |
| --- | --- | --- | --- | --- | --- |
| Apple Metal | Native and Node/Bun package lanes | Declared Dawn-backed lanes | Artifact-specific | claim-indexed | `reports/claim-index.json` |
| AMD Vulkan | Native and Node/Bun package lanes | Declared Dawn-backed lanes | Artifact-specific | claim-indexed | `reports/claim-index.json` |
| Intel Tiger Lake Vulkan | Native compute diagnostics | Declared Dawn-backed lane | Host-specific only | diagnostic | `docs/status/runtime-backends-and-bench.md` |
| Windows D3D12 | Native runtime | Dawn D3D12 | Evidence incomplete | scaffolded | `docs/doe-support-matrix.md` |
| Chromium | Forced-Doe browser lane | Chromium/Dawn | Diagnostic only | diagnostic | `browser/chromium/bench/workflows/browser-milestones.json` |

Read the claim index and sidecar before repeating any measured result.

The latest physical backend evidence is cumulative and remains diagnostic:

- Metal: Doe and Dawn separately ran an output-oracled workload on a physical
  Apple M3; see [`bench/out/recomposition/backend-evidence-inputs/metal.json`](bench/out/recomposition/backend-evidence-inputs/metal.json).
- Vulkan: the corresponding AMD host capture is in
  [`reports/ecosystem/electronicarts-cpp-ml-intro/cpp-ml-mnist-webgpu-amd-vulkan-2026-08-09-diagnostic.json`](reports/ecosystem/electronicarts-cpp-ml-intro/cpp-ml-mnist-webgpu-amd-vulkan-2026-08-09-diagnostic.json).
- D3D12: no physical Windows capture yet.

The merged evidence is
[`runtime/zig/reports/recomposition/backend-evidence.json`](runtime/zig/reports/recomposition/backend-evidence.json).
Do not interpret one Metal or Vulkan capture as a general Doe performance
claim.

## Repository map

- `packages/doe-gpu/`: public npm package
- `runtime/zig/`: native runtime, compiler, and backend implementations
- `bench/`: correctness, compatibility, performance, and claim tooling
- `config/`: schemas and machine-owned policy
- `browser/chromium/`: Chromium integration contracts and diagnostics
- `pipeline/`: trace, upstream intelligence, and proof tooling
- `docs/`: architecture, process, support, and concise live status

## Read next

- [Canonical product strategy](docs/thesis.md)
- [Architecture](docs/architecture.md)
- [Process and release law](docs/process.md)
- [Support matrix](docs/doe-support-matrix.md)
- [Current status](docs/status.md)
- [Documentation index](docs/INDEX.md)

## How to iterate

1. Choose one named workload and one correctness or performance question.
2. Change `runtime/zig/` or `packages/doe-gpu/`; keep provider selection
   explicit and do not add fallback just to make a lane pass.
3. Run the smallest relevant correctness test, then the physical backend lane:

   ```bash
   python3 bench/runners/run_recomposition_backend_evidence.py --backend metal
   python3 bench/runners/run_recomposition_backend_evidence.py --backend vulkan
   python3 bench/runners/run_recomposition_backend_evidence.py --backend d3d12
   ```

4. Inspect the raw receipt and merged classification. Correctness and
   equivalent work come before timing.
5. Run the gates for the changed surface and update its live status page.

The governing order is `Mine -> Normalize -> Verify -> Bind -> Gate ->
Benchmark -> Release`, defined in [`docs/process.md`](docs/process.md).

Browser replacement and spatial-compute targets remain expansion lanes. They do
not broaden the current Node/Bun support claim.

# Doe

Doe is a source-preserving WebGPU runtime and compiler for applications that
choose their GPU provider. It runs Node and Bun workloads, keeps shader and
program bodies inspectable, and emits receipts for the work that actually ran.

## Mission, goal, and value

Doe’s mission is to make GPU execution inspectable and controllable at the
runtime boundary.

The current product goal has two independently gated surfaces: a Node/Bun
runtime lane and a Fawn/Chromium browser lane. Each must run a named unchanged
workload correctly against a declared incumbent on a declared support matrix.
The receipt, replay artifact, and runtime policy must identify the workload,
provider, physical hardware, backend, and validation result. Browser evidence
does not inherit package claim status.

Doe serves several audiences:

- Application developers get a package and runtime for explicit GPU execution.
- Runtime and compiler engineers can inspect lowering, backend selection, and
  generated work.
- Benchmark and release reviewers can trace a claim to its receipt and raw
  artifact.

Doe owns the runtime, compiler, workload contract, execution policy, evidence
classification, and release decision. Doppler, Dream, Columbo/Valera,
Reploid/Poolday, Cerebras, Chromium/Fawn, and outside projects may provide
workloads, hosts, baselines, or integration surfaces; they do not define Doe’s
runtime claim.

## How to use Doe

Install the public package and run the Node example:

```bash
npm install doe-gpu
node node_modules/doe-gpu/examples/node-first-kernel.mjs
```

Package entrypoints and public exports are documented in
[`packages/doe-gpu/README.md`](packages/doe-gpu/README.md).

Contributors making a Doe change should choose one workload and one correctness
or performance question. Change [`runtime/zig/`](runtime/zig/) or
[`packages/doe-gpu/`](packages/doe-gpu/), run the smallest relevant correctness
test, then run the physical backend lane that matches the host: Metal on macOS,
Vulkan on Linux, or D3D12 on Windows.

```bash
python3 bench/runners/run_recomposition_backend_evidence.py --backend metal
python3 bench/runners/run_recomposition_backend_evidence.py --backend vulkan
python3 bench/runners/run_recomposition_backend_evidence.py --backend d3d12
```

Inspect the raw receipt and merged classification before updating status.

## Evidence and demonstrated capabilities

Measured results belong to [`reports/claim-index.json`](reports/claim-index.json)
and the artifacts named by its rows. The table records evidence classes; it is
not a universal performance claim.

| Backend | Surface or workload | Comparator | Result | Evidence state | Evidence |
| --- | --- | --- | --- | --- | --- |
| Apple Metal | Native and Node/Bun package lanes | Declared Dawn-backed lanes | Artifact-specific | `claim-indexed` | [`claim index`](reports/claim-index.json) |
| AMD Vulkan | Bun warm application row | Declared Bun WebGPU provider | Artifact-specific | `claim-indexed` | [`claim index`](reports/claim-index.json) |
| AMD Vulkan | Node warm application row | Declared Node WebGPU provider | Artifact-specific | `claim-indexed` | [`claim index`](reports/claim-index.json) |
| AMD Vulkan | Deno warm application row | Deno wgpu | Driver identity incomplete | `diagnostic` | [`claim index`](reports/claim-index.json) |
| AMD Vulkan | Native release rows | Declared Dawn-backed lanes | Artifact-specific | `claim-indexed` | [`claim index`](reports/claim-index.json) |
| AMD Vulkan | Linux drop-in cutover | Dawn rollback lane | Strict cutover rehearsal | `claim-indexed` | [`claim index`](reports/claim-index.json) |
| AMD Vulkan | Pinned vGPU Node/ORT application | Application oracle | Hash-linked reproduction | `diagnostic` | [`reviewed report`](reports/ecosystem/vercel-labs-vgpu/vgpu-node-ort-snapshot-amd-vulkan-2026-08-10-diagnostic.json) |
| AMD Vulkan | Pinned wgsl-fns compilation application | Node/Dawn package | Doe passes; comparator crashes | `diagnostic` | [`reviewed report`](reports/ecosystem/wgsl-fns/wgsl-fns-compilation-suite-amd-vulkan-2026-08-10-diagnostic.json) |
| AMD Vulkan | Vendored WebGPU CTS subset | CTS required-query subset | Identity-bound subset pass | `diagnostic` | [`CTS receipt`](reports/benchmarks/amd-vulkan/20260810T222323Z/webgpu-cts-subset-receipt.json) |
| AMD Vulkan | Physical recomposition diagnostic | Dawn delegate | Output-oracled capture | `diagnostic` | [`backend evidence`](runtime/zig/reports/recomposition/backend-evidence.json) |
| Intel Tiger Lake Vulkan | Native compute diagnostics | Declared Dawn-backed lane | Host-specific only | `diagnostic` | [`backend status`](docs/status/runtime-backends-and-bench.md) |
| Windows D3D12 | Native runtime | Dawn D3D12 | Evidence incomplete | `scaffolded` | [`support matrix`](docs/doe-support-matrix.md) |
| Fawn/Chromium | Forced-Doe browser lane | Chromium/Dawn | Clean-install release gate remains blocked | `diagnostic` | [`clean-install receipt`](browser/chromium/artifacts/20260811T130500Z/fawn-release-clean-install.diagnostic.json) |

The latest physical backend bundle is
[`backend-evidence.json`](runtime/zig/reports/recomposition/backend-evidence.json).
Read the claim index and sidecars before repeating a result.

## Long-term vision

The long-term product is a receipt-backed local compute plane for AI workloads
and autonomous software. A versioned workload enters under an explicit policy;
Doe selects or enforces the provider, executes the workload, validates the
result, and returns a receipt describing the run.

Node, Bun, Electron, and controlled CI are the first runtime surfaces. Fawn is
the first-class browser target: a released Chromium-family archive must run an
unchanged WebGPU application through forced Doe with independently verified
output, physical hardware identity, reliable lifecycle behavior, and a narrow
measured advantage or compatibility benefit. Doe must earn each adjacent
GPU-heavy browser workload separately. It is not an agent SDK, browser
automation framework, or general Chromium fork.

## Limits and current status

Receipts, replay, deterministic artifacts, and runtime policy identify and
reproduce execution. They do not establish a general speed advantage without a
matched workload and timing scope. One Metal or Vulkan capture does not support
a universal Doe performance claim. D3D12 has no physical capture in the current
status table, and Chromium remains diagnostic.

## Repository map

- [`packages/doe-gpu/`](packages/doe-gpu/) — public npm package
- [`runtime/zig/`](runtime/zig/) — native runtime, compiler, and backends
- [`bench/`](bench/) — correctness, compatibility, performance, and claim tools
- [`config/`](config/) — schemas and machine-owned policy
- [`browser/chromium/`](browser/chromium/) — Chromium integration contracts and diagnostics
- [`pipeline/`](pipeline/) — trace, upstream intelligence, and proof tooling
- [`docs/`](docs/) — architecture, process, support, and status documentation

## Read next

- [Product strategy](docs/thesis.md)
- [Architecture](docs/architecture.md)
- [Process and release law](docs/process.md)
- [Support matrix](docs/doe-support-matrix.md)
- [Current status](docs/status.md)
- [Documentation index](docs/INDEX.md)

The governing order is `Mine -> Normalize -> Verify -> Bind -> Gate ->
Benchmark -> Release`, defined in [`docs/process.md`](docs/process.md).

## License

[MIT License](LICENSE)

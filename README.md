# Doe

<p align="center">
  <img src="assets/doe-logo.svg" alt="Doe logo" width="96" />
</p>

Doe is a native WebGPU compute runtime and compiler for applications that
control their GPU provider. The promoted developer wedge is deliberately
narrow: Node and Bun workloads that Doe can run correctly, reliably, and
materially faster than a declared incumbent on a declared support matrix.

Receipts, replay, deterministic artifacts, and runtime policy prove those
properties. They do not substitute for them.

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

Browser replacement and spatial-compute targets remain expansion lanes. They do
not broaden the current Node/Bun support claim.

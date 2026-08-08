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

## Install

```bash
npm install doe-gpu
node node_modules/doe-gpu/examples/node-first-kernel.mjs
```

Package usage and supported entrypoints are documented in
[`packages/doe-gpu/README.md`](packages/doe-gpu/README.md).

## Admission contract

A surface is promoted only when it has:

- independent output oracles for every promoted workload;
- explicit crash, hang, timeout, ordering, concurrency, and memory behavior;
- compatibility with named downstream applications;
- end-to-end latency and memory evidence for user-visible operations;
- clean installation on every declared runtime, operating system, and
  architecture tuple;
- structured runtime identity, fallback decisions, diagnostics, and receipts.

Unsupported systems and operations must fail explicitly. Diagnostic and
scaffolded lanes are not promoted product support.

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

- [Product thesis](docs/thesis.md)
- [Architecture](docs/architecture.md)
- [Process and release law](docs/process.md)
- [Node/Bun developer wedge](docs/node-bun-developer-wedge.md)
- [Support matrix](docs/doe-support-matrix.md)
- [Performance contract](docs/performance-strategy.md)
- [Current status](docs/status.md)
- [Documentation index](docs/INDEX.md)

Browser replacement and spatial-compute targets remain expansion lanes. They do
not broaden the current Node/Bun support claim.

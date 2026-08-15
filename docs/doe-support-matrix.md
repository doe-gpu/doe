# Doe support matrix

## Rule

Support is a declared tuple, not a repository-wide adjective:

`package version × host runtime × operating system × architecture × backend × adapter/driver × workload surface`

A tuple is promoted only when installation, compatibility, correctness,
reliability, performance, and evidence gates all pass. Machine-owned artifacts
carry the changing state.

## Surface classes

| Surface | Contract | Current claim boundary |
| --- | --- | --- |
| `doe-gpu` controlled-JavaScript compute | Public npm package over the native Doe runtime | Narrow Node, Bun, and Electron main-process workload tuples only |
| Native `webgpu.h` runtime | Embeddable or drop-in Doe shared library | Backend- and host-specific evidence only |
| Chromium integration | Doe beneath Chromium WebGPU | Diagnostic until browser release gates pass |
| TSIR/HostPlan/CSL | Spatial-compute lowering and execution | Simulator and hardware evidence remain distinct |

## Evidence classes

| State | Meaning |
| --- | --- |
| `claim-indexed` | A named row has current report and claim sidecars in `reports/claim-index.json` |
| `diagnostic` | Useful engineering evidence that cannot support promoted wording |
| `status-only` | Capability or contract exists without a performance claim |
| `scaffolded` | Code or configuration exists but the required execution evidence does not |
| `unsupported` | The declared tuple or operation must fail explicitly |

## Current platform boundary

| Platform/backend | Package | Native runtime | Browser | Boundary |
| --- | --- | --- | --- | --- |
| macOS arm64 / Apple Metal | Narrow Node/Bun evidence; Electron unproved | Narrow native evidence | Separate diagnostic lane | Read claim index per row |
| Linux x64 / AMD Vulkan | Narrow Node/Bun and Electron main-process evidence | Narrow native evidence | Separate diagnostic lane | Read claim index per row |
| Linux / Intel Tiger Lake Vulkan | Diagnostic host evidence | Diagnostic host evidence | Not promoted | Do not generalize |
| Windows / D3D12 | Not promoted | Scaffolded | Not promoted | Fresh Windows evidence required |
| Other tuples | Unsupported unless explicitly listed | Unsupported unless explicitly listed | Unsupported | Fail with typed cause |

The table intentionally contains no benchmark percentages or mutable pass
counts. Current evidence lives in `reports/claim-index.json` and the status
artifacts it references.

## Controlled JavaScript runtime promotion requirements

- clean npm installation with the correct native binary;
- first-kernel output oracle;
- versioned downstream-project suite;
- crash, hang, concurrency, teardown, and memory checks;
- end-to-end workload wins at declared p50, p95, and p99 thresholds;
- no hidden provider, backend, CPU, or cloud fallback;
- receipt with runtime, binary, adapter, driver, workload, output, and timing
  identity.
- Electron claims remain main-process and Node-side unless a separate renderer
  or browser contract passes.

## Native runtime promotion requirements

- declared `webgpu.h` ABI and behavior surface;
- lifecycle, mapping, queue, error-scope, and device-loss behavior;
- backend-specific correctness and stress coverage;
- published CTS scope when conformance language is used;
- clean shared-library installation and consumer smoke test;
- matched incumbent comparison for every performance claim.

## Browser promotion requirements

- downloadable browser artifact with hash-bound Doe and fallback runtimes;
- forced-Doe execution with hidden fallback disabled;
- browser compatibility, CTS, crash, recovery, presentation, and media-path
  coverage;
- hosted proof surface and launch receipt;
- browser-specific end-to-end comparisons.

Package and native evidence do not satisfy these gates.

## Source of truth

- Public claims: `reports/claim-index.json`
- Tool/public boundary: `config/tool-surfaces.json`
- Platform-package manifests: `packages/doe-gpu/package.json` and platform
  package manifests
- WebGPU API inventory: `config/webgpu-spec-index.jsonl`
- CTS evidence: `config/webgpu-cts-evidence.json`
- Browser milestones: `browser/chromium/bench/workflows/browser-milestones.json`
- Cerebras status: `bench/out/r3-cerebras-status/snapshot.json`

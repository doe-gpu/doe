# Backend evidence matrix

This is a navigation view. It does not own results.

| Backend | Current boundary | Evidence owner |
| --- | --- | --- |
| Apple Metal | Narrow native and package rows | `reports/claim-index.json` |
| AMD Vulkan | Narrow native and package rows | `reports/claim-index.json` |
| Intel Tiger Lake Vulkan | Host-specific diagnostic compute evidence | `docs/status/runtime-backends-and-bench.md` |
| D3D12 | Scaffolded; fresh Windows evidence required | `docs/doe-support-matrix.md` |
| Chromium WebGPU | Diagnostic until browser release gates pass | `browser/chromium/bench/workflows/browser-milestones.json` |

Rules:

- read the claim sidecar before repeating a result;
- do not compare across machines, backends, workloads, or timing scopes;
- do not promote diagnostic or scaffolded rows;
- update machine-owned evidence before changing this navigation view.

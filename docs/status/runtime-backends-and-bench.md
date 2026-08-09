# Doe status: runtime backends and benchmarks

This is the live status front door for native backends, package execution, and
benchmark methodology. Receipts and claim sidecars own measured results; this
file only names the promoted boundary and open admission gates.

## Current boundary

- Public performance rows come only from `reports/claim-index.json` and their
  referenced claim sidecars.
- Apple Metal and AMD Vulkan have narrow native and package evidence. That
  evidence does not establish broad runtime superiority.
- Intel Tiger Lake has local source- and output-bound Vulkan evidence. It is a
  host-specific result, not a cross-device claim.
- D3D12 still lacks a current Windows evidence run.
- Chromium results remain a separate browser lane and do not inherit package or
  native claim status.
- External-project harnesses now have a manifest-driven prepare/reproduce
  entrypoint with exact source pinning and separate hash-bound preparation and
  execution receipts. Promotion remains downstream of reviewed application
  evidence and a claim-eligible physical support target.
- Strict Linux Vulkan profiles declare ordered distro-specific ICD path
  candidates. Preflight selects only the first installed declared candidate;
  it does not scan for or fall back to an undeclared software ICD.
- GPU smoke configs that select claim-eligible catalog workloads use the full
  comparability sample floor. The lower diagnostic smoke floor applies only to
  workloads that are not claim-eligible.
- GPU smoke verification resolves current compare-report receipt references,
  verifies their file hashes and identities, and checks every bound sample for
  successful GPU resource evidence. Legacy inline samples remain readable.
- The AMD Vulkan external-project handoff has returned a reviewed diagnostic
  report with physical-adapter, native-output, and GPU-resource evidence at
  `reports/ecosystem/electronicarts-cpp-ml-intro/cpp-ml-mnist-webgpu-amd-vulkan-2026-08-09-diagnostic.json`.
- Recomposition backend evidence schema version 2 marks Vulkan representative
  output captured only after verifying a comparable report, its receipt hashes
  and identities, successful dispatches, and output-oracle matches. Version 1
  evidence remains an unbound capability snapshot; Metal and D3D12 remain
  separate physical-host obligations.
- The recomposition kernel-dispatch receipt rebuilds the frozen baseline and
  current runtime, runs the same output-oracled kernel on the AMD-only Vulkan
  ICD, and requires exact normalized command, output, error, trace, receipt,
  and shader-artifact identities before classifying the dispatch seam equal.
- After equivalence and no-regression approval, the temporary legacy-dispatch
  mock and benchmark executable were removed. Build-measurement schema version
  2 now captures only source-bound clean/incremental builds and artifacts; the
  retired seam timing remains immutable in the recomposition approval receipt.
- WGSL IR digest encoding version 2 excludes Zig compiler-generated anonymous
  type names and binds schema field names, union tags, and semantic values.
  Frozen and current fixtures use the same observer and remain identical across
  all supported Zig optimization modes; target-output bytes remain unchanged.
- WebGPU ABI source policy version 2 uses the licensed, SHA-pinned header under
  `runtime/zig/vendor/webgpu-headers/`. Runtime builds and ABI generation no
  longer inherit header state from the mutable Dawn benchmark checkout.

## Admission blockers

- Every promoted workload needs an independent output oracle on both products.
- Node and Bun need downstream-project compatibility evidence, not only package
  harness coverage.
- End-to-end application latency, memory, concurrency, crash, hang, and leak
  evidence must become release-blocking for the promoted developer wedge.
- Installation must pass from clean npm environments on every supported
  runtime, operating system, and architecture tuple.
- Performance is still advisory in `config/gates.json`.
- The AMD Vulkan cpp-ml lane remains ineligible because the generated
  Presentation WGSL does not compile in Doe and the strict application oracle
  also rejects one baseline label. Physical-host admission is no longer the
  blocker for that diagnostic lane.

## Ground truth

- Claims: `reports/claim-index.json`
- Support contract: [`../doe-support-matrix.md`](../doe-support-matrix.md)
- Methodology: [`../performance-strategy.md`](../performance-strategy.md)
- Workload law: [`../workload-system.md`](../workload-system.md)
- Historical entries:
  [`archive/2026-05-to-2026-08-runtime-backends-and-bench.md`](archive/2026-05-to-2026-08-runtime-backends-and-bench.md)

Add new prose here only when the promoted boundary or an admission blocker
changes. Put measured facts in artifacts.

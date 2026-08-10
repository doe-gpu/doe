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
- Strict comparison now rejects workload-unit normalization that makes selected
  operation timing exceed its containing workload wall. Trace row and success
  counts are not implicit workload-unit divisors without a declared unit.
- Shader-artifact validation treats the exact backend-initialization manifest
  as structural bootstrap evidence with no executed binary to validate. Any
  manifest produced by actual shader execution still requires its emitted
  backend artifact under strict validation.
- The fresh AMD Vulkan release matrix at
  `bench/out/amd-vulkan/20260810T155306Z/dawn-vs-doe.amd.vulkan.release.json`
  validates source-bound receipts and rejects evidence that is only
  superficially matched. The multistage graphs now execute their full command
  prefixes in one oracle context and produce exact Doe/Dawn output parity.
  During that work, the Dawn delegate's internal `kernel_dispatch` path was
  corrected to use direct dispatch, and its pipeline-cache identity now includes
  layout-visible binding fields. The retained graph hashes are explicitly
  source-bound cross-runtime consensus, so those rows remain diagnostic until
  an independent semantic reference exists.
- The same AMD matrix marks upload rows as hardware-path-asymmetric because Doe
  may write host-visible memory while Dawn stages and copies. Their large timing
  deltas are diagnostic and non-transferable. The remaining strictly comparable
  compute rows preserve the same selected-timing and workload-wall sign through
  the release percentiles, and none crosses the configured suspicious-speedup
  ratio; the report owns the current values.
- The retained AMD Vulkan Bun warm Gemma application row is now claim-indexed
  through `reports/claim-index.json`. Both package providers bind the same
  physical vendor, device, driver, execution shape, shader-source receipts,
  effective readback path, and final captured token. The corresponding Node row
  is retained as diagnostic because its incumbent provider omits adapter and
  driver identity. Positive timings do not override that missing hardware
  evidence.
- Strict Vulkan package comparison now folds physical adapter identity into the
  existing hardware-path obligation. A row cannot remain comparable unless both
  sides expose one matching vendor ID, device ID, and normalized driver version.
  Doe's package bridge obtains those fields from the selected Vulkan physical
  device for both Node and Bun.
- `reports/claim-index.json` continues to scaffold the AMD Vulkan native
  release, browser ORT, and Linux Vulkan drop-in rows instead of borrowing older
  measured status after stricter evidence checks or artifact pruning.
- The fresh Linux Vulkan drop-in gate passes symbol, behavior,
  proc-resolution, and benchmark checks at
  `bench/out/dropin/20260809T221600Z/dropin_report.json`. It remains diagnostic
  until a cutover rehearsal receipt and rollback-side claim evidence are
  retained and indexed.
- `config/dawn-replacement-frontier.json` keeps claimable Apple slices visible
  but marks mixed-platform product rows diagnostic. Its named AMD frontier
  slices remain separate from the claim-indexed Bun application row; the
  generated readiness report passes its coherence gate without treating
  scaffolded entries as claim evidence.
- External-project harness schema version 4 replaces one inferred installation
  command with ordered named steps, each owning its working-directory scope and
  timeout. The pinned vGPU workspace and isolated ORT experiment now prepare
  without modifying upstream source.
- The pinned vGPU Node/ORT workload passes its physical AMD Vulkan diagnostic
  matrix on Dawn and Doe after closing native callback export, TypeScript-loader,
  and post-destroy event-handler lifecycle gaps. Its governed receipts remain
  diagnostic until support-target, replay, reliability, and promotion floors
  are independently satisfied.
- The AMD Vulkan external-project handoff has returned a reviewed diagnostic
  report with physical-adapter, native-output, and GPU-resource evidence at
  `reports/ecosystem/electronicarts-cpp-ml-intro/cpp-ml-mnist-webgpu-amd-vulkan-2026-08-09-diagnostic.json`.
- Recomposition backend evidence schema version 2 marks Vulkan representative
  output captured only after verifying a comparable report, its receipt hashes
  and identities, successful dispatches, and output-oracle matches. Version 1
  evidence remains an unbound capability snapshot; Metal and D3D12 remain
  separate physical-host obligations.
- Recomposition backend evidence schema version 3 supports cumulative
  cross-host capture. Darwin and Windows operators can add receipt-bound Metal
  or D3D12 output without replacing the existing Vulkan evidence; each captured
  backend owns its physical device and host identity.
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

- Every promoted workload needs an independent output oracle on both products;
  exact cross-runtime consensus does not satisfy that obligation.
- Node and Bun need downstream-project compatibility evidence, not only package
  harness coverage. The vGPU Node/ORT lane now supplies one diagnostic Node
  application result; it is not yet a promoted release dependency.
- The incumbent Node WebGPU package still exposes no physical adapter or driver
  identity. Doe now records the selected Vulkan PCI and raw driver identity, but
  a strict Node comparison remains diagnostic until the comparator supplies
  equivalent evidence.
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

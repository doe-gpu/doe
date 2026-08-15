# Doe status: runtime backends and benchmarks

This is the live status front door for native backends, package execution, and
benchmark methodology. Receipts and claim sidecars own measured results; this
file only names the promoted boundary and open admission gates.

## Current boundary

- Fawn M4 is now an explicit in-progress published-browser milestone. Linux x64
  joins macOS arm64 as a governed release-candidate platform through
  `config/browser-release-platform-policy.json`; this expands the admissible
  lane without promoting any browser claim.
- A clean extraction of the retained compact Linux diagnostic archive aborts
  before WebGPU because Chromium runtime support files are absent. The governed
  failure is retained at
  `browser/chromium/artifacts/20260811T130500Z/fawn-release-clean-install.diagnostic.json`.
  Release-candidate preflight now requires the declared ICU, V8 snapshot,
  resource, locale, crash-handler, sandbox, and scale-resource members, and the
  Linux archive packer requires an eligible preflight receipt.
- `bench/tools/check_browser_release_clean_install.py` now turns that boundary
  into an observational gate: it rejects unsafe zip members, verifies the exact
  manifest and platform package set, extracts into a fresh temporary directory,
  runs the packaged browser launch probe, and can run strict Dawn-and-Doe smoke
  with only packaged browser/runtime bytes. Release-candidate launch receipts
  must bind a passing, WebGPU-level result; declared launch facts alone no
  longer satisfy the release contract. The retained compact archive's governed
  failure is at
  `browser/chromium/artifacts/20260811T130500Z/fawn-release-clean-install.diagnostic.json`.
  Migration: launch-receipt schema version 1 remains readable for diagnostic
  evidence, but `release_candidate` and `release` receipts must now include a
  hash-bound `cleanInstallCheck`; older candidate-shaped receipts must be
  regenerated and cannot be promoted by relabeling.
- Browser runtime proof now separates the forced provider from physical adapter
  identity. New smoke and layered reports bind Doe or Dawn through the selector
  and runtime hashes while retaining the real vendor, architecture, device, and
  description returned by `wgpuAdapterGetInfo`. Legacy schema-version-1 browser
  artifacts remain readable but do not define the new identity contract.
- No Fawn release candidate exists on this host: the original Chromium checkout
  and complete build output are unavailable, and substituting public Chromium
  support files fails exact V8 snapshot compatibility. M4 remains in progress
  until a complete build is clean-installed and an unchanged exact-oracle
  application passes lifecycle, fallback, replay, concurrency, memory, and
  timing gates.

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
- External-project source preparation now forces byte-preserving Git checkout
  semantics across host configurations and ignores package-manager executable-
  bit normalization while continuing to reject content changes. The retained
  HoloScript preparation receipt exercises the corrected boundary.
- The reviewed HoloScript physical AMD Vulkan result at
  `reports/ecosystem/holoscript-snn-webgpu/holoscript-tropical-spmv-amd-vulkan-2026-08-11-diagnostic.json`
  binds the real provider and adapter identities, the unchanged upstream CPU
  oracle, exact output hashes, and the validated host tuple. It is a passing
  application compatibility wedge, not a performance or release claim.
- The reviewed UMAP-GPU physical AMD Vulkan result at
  `reports/ecosystem/umap-gpu/umap-sgd-output-correctness-amd-vulkan-2026-08-11-diagnostic.json`
  retains the unchanged structural application oracle under both providers.
  Exact embedding identity and concrete primary dispatch identity remain open,
  and Doe's process timing is a measured disadvantage rather than a speed wedge.
- The reviewed Gigi physical matrix at
  `reports/ecosystem/electronicarts-gigi/gigi-generated-webgpu-suite-amd-vulkan-2026-08-11-diagnostic.json`
  is a gap map: shared fixture failures are separated from the cases that pass
  under Dawn and fail under Doe. It does not support a Gigi product claim.
- Strict Linux Vulkan profiles declare ordered distro-specific ICD path
  candidates. Preflight selects only the first installed declared candidate;
  it does not scan for or fall back to an undeclared software ICD.
- GPU smoke configs that select claim-eligible catalog workloads use the full
  comparability sample floor. The lower diagnostic smoke floor applies only to
  workloads that are not claim-eligible.
- The AMD GPU smoke workflow selects the strict comparable workgroup-atomic
  compute row. It no longer selects the large upload row, whose declared
  hardware-path asymmetry makes it directional rather than a valid strict
  smoke comparison.
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
- The retained AMD Vulkan native release matrix at
  `reports/benchmarks/amd-vulkan/20260810T222323Z/dawn-vs-doe.amd.vulkan.release.compare.json`
  passes strict source binding, output verification, replay, structural
  equivalence, backend selection, shader-artifact validation, Vulkan sync and
  timing policy, release claim, and active-cycle gates. The claim sidecar at
  `reports/benchmarks/amd-vulkan/20260810T222323Z/dawn-vs-doe.amd.vulkan.release.claim.json`
  owns the promoted verdict. The release warmup contract now excludes observed
  pipeline-preparation transients while preserving the configured timed-sample
  floor on both providers.
- Stable fluids now executes its complete multistage command prefix and checks
  the final dye field against a hash-bound independent CPU reference using the
  schema-version-3 float32 tolerance oracle. Monte Carlo now uses a separately
  compiled C reference generator and an exact hash-bound output oracle. The
  retained native report owns both verdicts and their current cohort state.
- The AMD workload contract marks upload rows as hardware-path-asymmetric because Doe
  may write host-visible memory while Dawn stages and copies. Their large timing
  deltas are diagnostic and non-transferable. The governed release rows preserve
  the same selected-timing and workload-wall sign through the required release
  percentiles, and none crosses the configured suspicious-speedup ratio; the
  retained report owns the current row set and values.
- The retained AMD Vulkan Node and Bun warm Gemma application rows are
  claim-indexed through `reports/claim-index.json`. The Node comparator now
  materializes non-enumerable `GPUAdapterInfo` fields before serialization, and
  the strict hardware gate accepts either matching numeric PCI identity or an
  exact normalized runtime-reported vendor, device, and driver triple. Numeric
  conflicts never fall back to text.
- Deno now has a hardware-backed package entrypoint, a config-backed Doe-vs-Deno
  wgpu executor lane, and matched `mapAsync` readback policy. Its retained AMD
  Vulkan comparison at
  `reports/benchmarks/amd-vulkan/20260810T224707Z/gemma64.deno-package.warm.ir.compare.json`
  remains diagnostic for one explicit reason: Deno wgpu exposes matching AMD
  vendor and device IDs but no driver version.
- Strict Vulkan package comparison now folds physical adapter identity into the
  existing hardware-path obligation. A row cannot remain comparable unless both
  sides expose one matching vendor ID, device ID, and normalized driver version.
  Doe's package bridge obtains those fields from the selected Vulkan physical
  device for both Node and Bun.
- `reports/claim-index.json` indexes the AMD Vulkan native release, Node and Bun
  package rows, and Linux Vulkan drop-in cutover. Deno is indexed diagnostically;
  browser ORT and Chromium release surfaces remain scaffolded.
- The Linux Vulkan drop-in rehearsal at
  `reports/benchmarks/amd-vulkan/20260810T221159Z/dropin/dropin-cutover-rehearsal-receipt.json`
  passes ABI, behavior, proc-resolution, benchmark, strict no-fallback cutover,
  and Dawn rollback checks. Its hash-linked claim sidecar owns the indexed
  verdict.
- `config/dawn-replacement-frontier.json` keeps every platform slice explicit.
  Its native, Node, Bun, Deno, CTS, browser, and drop-in AMD entries point to
  their current retained artifacts without allowing diagnostic or scaffolded
  slices to inherit claim status. The frontier coherence gate passes.
- External-project harness schema version 4 replaces one inferred installation
  command with ordered named steps, each owning its working-directory scope and
  timeout. The pinned vGPU workspace and isolated ORT experiment now prepare
  without modifying upstream source.
- The pinned vGPU Node/ORT workload passes a fresh offline physical AMD Vulkan
  reproduction recorded by
  `reports/ecosystem/vercel-labs-vgpu/vgpu-node-ort-snapshot-amd-vulkan-2026-08-10-diagnostic.json`.
  The reviewed report hash-links its manifest, preparation, raw matrix, summary,
  and gate outputs; maturity remains diagnostic until downstream promotion
  policy is satisfied.
- The pinned wgsl-fns compilation application now declares its upstream build
  as a separate installation step. The reviewed diagnostic at
  `reports/ecosystem/wgsl-fns/wgsl-fns-compilation-suite-amd-vulkan-2026-08-10-diagnostic.json`
  binds the retained raw suite and records clean Doe process success across the
  unchanged upstream assertion and generated-shader corpus with physical
  adapter identity and no native compiler diagnostics. The overall reproduction
  remains failed and diagnostic because the pinned Node/Dawn comparator aborts
  during adapter probing and test execution on this host.
- That workload exposed a vector-scalar compound-assignment gap in WGSL
  semantic analysis and IR validation. Compound assignments now validate the
  underlying binary operation before checking assignability, and the minimized
  SPIR-V regression lives in
  `runtime/zig/tests/wgsl/emit_spirv_mixed_binary_test.zig`.
- The actual vendored WebGPU CTS subset runner passes its configured AMD Vulkan
  queries at
  `reports/benchmarks/amd-vulkan/20260810T222323Z/webgpu-cts-subset.json`.
  Its published subset receipt and backend pass ledger live beside the run as
  `webgpu-cts-subset-receipt.json` and
  `webgpu-cts-backend-pass-ledger.json`. This remains diagnostic evidence, not
  a conformance claim, because it does not cover the policy-defined full
  required query scope. CTS run-report schema version 2 adds a required
  same-provider adapter probe, and evidence-ledger schema version 2 hash-binds
  that physical identity and the raw report into the published receipt.
  Version-1 CTS run reports and evidence ledgers remain readable diagnostics but
  are not accepted by the version-2 publication builder.
- Browser smoke report schema version 2 adds an active-runtime proof derived
  from `wgpuAdapterGetInfo`. A stock Chrome run at
  `browser/chromium/artifacts/20260810T223700Z/dawn-vs-doe.browser.playwright-smoke.diagnostic.json`
  correctly fails the forced-Doe lane because Chrome ignores Doe runtime flags
  and continues to report the AMD/RDNA incumbent. No local Fawn-patched Chromium
  binary exists, so Track A advanced through a stronger false-positive gate,
  not through a browser-replacement claim. Version-1 smoke reports are legacy
  diagnostics and must be regenerated to satisfy the current gate.
- Package execution policy and its schema now admit Deno as an explicit runtime
  host. The public claim-index comparison taxonomy likewise admits the
  diagnostic Doe-vs-Deno-wgpu row. These are additive contract migrations;
  Node and Bun policy entries retain their previous meaning.
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

- Node and Bun need downstream-project compatibility evidence, not only package
  harness coverage. The vGPU Node/ORT and wgsl-fns lanes now supply diagnostic
  application results; neither is yet a promoted release dependency, and the
  wgsl-fns incumbent comparator currently crashes before a fair paired verdict.
- Deno wgpu must expose driver-version telemetry before its AMD Vulkan package
  row can satisfy strict physical identity and become claimable.
- The CTS lane needs completion of its policy-defined required query scope
  before it supports public conformance language. The AMD Vulkan raw run,
  physical adapter identity, subset receipt, and backend pass ledger are now
  hash-bound published diagnostic evidence.
- Chromium Track A needs a locally built Fawn-patched browser artifact before a
  forced-Doe run can prove Doe is active. Stock Chrome is only a negative
  runtime-selection control.
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

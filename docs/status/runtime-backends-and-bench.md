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
- External-project promotion policy 1.1.0 now makes runtime ownership a
  blocking attribution contract. A candidate must predeclare the ambient,
  pinned, governed-wrapper, and DoeRuntime lanes; independent-correction claims
  must also predeclare the bounded-patch lane. Existing reviewed reports remain
  diagnostic and explicitly record that this ownership assessment was not run.
- DoeProof now has a public provider-neutral Node execution primitive at
  `doe-gpu/node-webgpu::runGovernedNodeWebGPU`. It binds the declared workload
  implementation, input, selected provider, adapter observation, exact output
  digest, and lifecycle state. A caller-supplied checkpoint receives completed
  inference evidence before provider release and a terminal receipt after
  release; stable workload and execution hashes support W0/D0 replay without
  conflating wrapper evidence with runtime ownership. This is a package
  contract, not application promotion: the caller must still prove an
  independent expected output and pass the external-project release gates.
- The public unchanged-application loader and governed process runner are
  physically bound by
  `reports/benchmarks/amd-vulkan/20260815T193900Z/holoscript-doeproof-loader-diagnostic.json`.
  Pinned Dawn and Doe each load through
  `doe-gpu/node-webgpu-loader`, while `doe-gpu/node-webgpu-process` binds the
  process declaration, hashed effective environment, exact parent-side oracle,
  effective loader identity, and provider-neutral replay identity. Both
  self-validated receipts bind the physical Radeon and reproduce all four
  frozen HoloScript topology hashes with identical shader, dispatch,
  synchronization, readback, oracle, and output identity. This authorizes the
  public DoeProof process seam; it grants no runtime-ownership, performance,
  application-promotion, or release credit and leaves the terminal HoloScript
  decision unchanged.
- The package now exposes the same governed process contract through
  `doe-proof-node run|verify|inspect|compare|replay`. Contracts and every local
  dependency are hash-bound; verification never imports the evaluator; compare
  is exact-output-only and hard-codes no performance or runtime-ownership
  interpretation. The physical HoloScript command-chain diagnostic at
  `reports/benchmarks/amd-vulkan/20260815T200358Z/holoscript-doeproof-cli-diagnostic.json`
  passes all five commands for W0/D0 plus D0 semantic replay. This is an
  adoption and CI surface, not a new evidence tier.
- Governed process cancellation is now explicit and receipt-bound. Pre-aborted
  calls do not spawn; active abort, timeout, and output-limit paths share the
  same termination primitive. POSIX descendants are terminated through the
  owned process group, while Windows reports direct-child scope without
  claiming tree cleanup. CLI `SIGINT` and `SIGTERM` preserve a terminal valid
  failure artifact when an output path was declared.
- CLI contracts can now bind an explicit set of additional runtime files. Each
  ID is unique and each file is rehashed during run, verify, and replay. This
  establishes declared-file identity only; it does not claim transitive
  dependency completeness or filesystem isolation.
- The package now ships Draft 2020-12 schemas for the governed contract,
  process receipt, and CLI artifact. Clean-install coverage checks that all
  three are present. The schemas own portable structure only; the CLI verifier
  remains required for dependency hashes, provider/oracle coherence, and
  replay identity.
- Governed Node processes can now select `node-permission-read-only`. The
  effective entrypoint/provider/loader plus declared-file allowlist is recorded,
  `NODE_OPTIONS` and caller-owned permission flags cannot widen it, and tested
  undeclared reads fail. Node's custom-loader worker exception is explicit.
  Native addon loading is also explicitly allowed for the provider. This is not
  described as dependency sealing because addon syscalls, network access, and
  operating-system isolation remain outside Node's permission boundary.
- The unchanged HoloScript W0/D0 workload now passes that boundary through the
  public CLI with a frozen hash-bound import allowlist, exact output comparison,
  and semantic replay. Its reviewed diagnostic is
  `reports/benchmarks/amd-vulkan/20260815T205128Z/holoscript-doeproof-cli-filesystem-diagnostic.json`.
  The auxiliary `vulkaninfo` subprocess is omitted rather than permitted, so
  the artifact deliberately receives no hardware, performance, ownership,
  promotion, or release credit. Native-addon syscalls and network access remain
  outside the Node permission contract.
- A Linux Bubblewrap successor at
  `reports/benchmarks/amd-vulkan/20260815T212816Z/holoscript-doeproof-cli-linux-bwrap-diagnostic.json`
  runs W0, D0, and D0 replay with only their hash-bound workspace files, a
  private temporary directory and network namespace, read-only declared base
  system roots, GPU device access, an explicitly selected Radeon Vulkan ICD,
  disabled ambient layer activation, and separate writable output directories.
  Its negative visibility probe sees the declared CLI, cannot see undeclared
  `GOALS.md`, and observes only loopback. A diagnostic trace still observes
  installed layer-manifest enumeration and hardware-dependent sysfs paths.
  This grants Linux workspace-sealing evidence, not complete OS dependency
  closure, hardware eligibility, performance, ownership, application
  promotion, release, or cross-platform sandbox support.
- The package integration suite now packs `doe-gpu`, installs the tarball into
  a fresh project with optional native packages and install scripts disabled,
  invokes the installed `.bin/doe-proof-node`, executes a sealed custom
  provider contract, and independently verifies its exact-output receipt. This
  proves the CLI package boundary without claiming a native-runtime clean
  install on any support tuple.
- A separate required native clean-install gate now packs both `doe-gpu` and
  the staged host platform package, installs them with scripts disabled, and
  executes the shipped first kernel. It exposed a stale Linux x64 platform
  payload whose shader-binding metadata no longer matched the JavaScript
  surface; restaging from the current native build restored exact output. The
  gate also rejects workspace-library resolution. Node, Bun, and Electron each
  execute their shipped first-kernel entrypoint and bind the selected host
  executable. Electron is restricted to main-process Node-side compute, uses
  the frozen headless launch arguments, and creates no renderer.
  Source-tree integration may skip when platform payloads are absent, but the
  explicit release commands may not. The bounded physical receipts are
  `reports/benchmarks/amd-vulkan/20260815T220824Z/doe-gpu-node-native-clean-install-diagnostic.json`,
  `reports/benchmarks/amd-vulkan/20260815T220824Z/doe-gpu-bun-native-clean-install-diagnostic.json`,
  and
  `reports/benchmarks/amd-vulkan/20260815T220824Z/doe-gpu-electron-native-clean-install-diagnostic.json`;
  they grant runtime-specific installation evidence for Linux x64 only and no
  performance, ownership, application-promotion, or release credit.
- Bounded clean-install reliability diagnostics now reuse one installed package
  across repeated fresh processes and overlapping runtime instances. The Node,
  Bun, and Electron receipts are
  `reports/benchmarks/amd-vulkan/20260815T220824Z/doe-gpu-node-native-clean-install-reliability-diagnostic.json`,
  `reports/benchmarks/amd-vulkan/20260815T220824Z/doe-gpu-bun-native-clean-install-reliability-diagnostic.json`,
  and
  `reports/benchmarks/amd-vulkan/20260815T220824Z/doe-gpu-electron-native-clean-install-reliability-diagnostic.json`.
  They prove exact output, bounded child execution, clean process exit, and 12
  exact create/compute/destroy cycles in one process for the declared Linux x64
  runtime tuples. After two warm-up cycles, the observed RSS spans are 6,713,344
  bytes for Node, 14,721,024 bytes for Bun, and 6,430,720 bytes for Electron,
  below the frozen 256 MiB diagnostic ceiling. Each cycle also resolves a
  pre-registered `GPUDevice.lost` promise with reason `destroyed` and rejects
  subsequent use of that device. This is not a long-soak leak certificate or
  unexpected hardware-loss recovery test. Full memory-growth promotion,
  performance, application promotion, and release remain unproved. Electron's
  result does not establish renderer, Chromium, or browser lifecycle support.
  The Electron first-kernel gate additionally executes a native compute
  readback through `GPUBuffer.getMappedRange()` and requires a sliceable
  `ArrayBuffer`. This permanently covers the Node-API external-buffer fallback
  exercised by the Electron main-process runtime.
- The named HoloScript Electron main-process diagnostic at
  `reports/ecosystem/holoscript-snn-webgpu/holoscript-electron-main-process-p0-2026-08-15-diagnostic.json`
  now exercises that correction through the unchanged tropical-SpMV
  application. `D0` passes three clean processes plus exact replay across all
  four topology hashes; `I0`, `I1`, and `W0` each fail three times at the
  external-ArrayBuffer boundary. The bounded application upload workaround
  reaches a native `SIGABRT`. The exact `webgpu@0.3.10` source and Dawn
  submodule were then rebuilt with a frozen two-file mapped-buffer ownership
  patch; `P0` passes three clean processes and exact replay across the same
  oracle. The bounded incumbent patch closes the application gap, so
  DoeRuntime ownership is rejected for this tuple. The artifact remains a
  diagnostic regression with no application-promotion, performance, release,
  renderer, Chromium, or browser credit and does not reinterpret the terminal
  Node HoloScript gate.
- `.github/workflows/webgpu-package-surface.yml` now runs the complete package
  contract, smoke, integration, and clean-install suite and the public
  tool-surface gate. Package-bin or manifest drift is therefore blocking CI,
  rather than being left to an operator-only dry-run.
- External-project source preparation now forces byte-preserving Git checkout
  semantics across host configurations and ignores package-manager executable-
  bit normalization while continuing to reject content changes. The retained
  HoloScript preparation receipt exercises the corrected boundary.
- The reviewed HoloScript physical AMD Vulkan result at
  `reports/ecosystem/holoscript-snn-webgpu/holoscript-tropical-spmv-amd-vulkan-2026-08-11-diagnostic.json`
  binds the real provider and adapter identities, the unchanged upstream CPU
  oracle, exact output hashes, and the validated host tuple. It is a passing
  application compatibility wedge, not a performance or release claim.
- The reviewed HoloScript ownership diagnostic at
  `reports/ecosystem/holoscript-snn-webgpu/holoscript-tropical-spmv-runtime-ownership-2026-08-15-diagnostic.json`
  completes the ambient, pinned, governed-incumbent, and DoeRuntime matrix.
  Every lane passes the exact workload, and W0 and D0 pass hash-bound replay.
  Because the unchanged incumbent needs no bounded correction and D0 supplies
  no distinct application outcome, the report rejects runtime ownership and
  retains HoloScript as a diagnostic workload.
- The reviewed HoloScript LIF determinism diagnostic at
  `reports/ecosystem/holoscript-snn-webgpu/holoscript-lif-determinism-2026-08-15-diagnostic.json`
  passes the upstream CPU membrane tolerances and exact final spike oracle in
  all `I0`, `I1`, `W0`, and `D0` processes. Governed Dawn and Doe replay
  exactly and produce identical GPU membrane and spike bytes across all three
  frozen cases on the physical Radeon Vulkan adapter. The result is retained
  as a correctness regression and supplies no runtime-ownership, promotion,
  performance, or release credit.
- The Gemma package-surface attribution receipt at
  `reports/benchmarks/amd-vulkan/20260815T171507Z/gemma64-no-dispatch-prewarm-attribution.json`
  remains a synthetic mechanism antecedent. The governed Doppler application
  diagnostic at
  `reports/benchmarks/amd-vulkan/20260815T182649Z/doppler-provider-runtime-ownership-diagnostic.json`
  rejects transfer of that advantage: Doe completes the unchanged workload and
  cleanly releases its provider, but fails the frozen application-performance
  outcome. Doppler supplies no runtime-ownership or release credit; its
  incumbent teardown abort remains a separate, unpromoted lifecycle finding.
- A versioned bounded successor at
  `reports/benchmarks/amd-vulkan/20260815T190434Z/doppler-provider-capability-publication-diagnostic.json`
  fixes a provider capability-publication defect: native Radeon limits were
  clamped to Doe's fallback table, forcing Doppler onto a CPU-streaming path.
  The corrected path preserves the exact generated text and token hashes and
  reduces bounded prefill from 14,676.65 ms to 175.99 ms, but model loading rises
  from 22,180.23 ms to 41,618.68 ms. This is diagnostic admission evidence for
  a new full W0/D0 comparison, not runtime-ownership or release credit. The full
  result at
  `reports/benchmarks/amd-vulkan/20260815T190434Z/doppler-provider-corrected-runtime-result.json`
  is terminal: output is exact, but Doe is 1.341× W0 on complete-session wall
  and 4.147× W0 on median timed inference. The corrected Doppler performance
  family is retired without tuning. W0's post-release abort remains a distinct
  lifecycle observation.
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
- The reviewed vGPU ownership diagnostic at
  `reports/ecosystem/vercel-labs-vgpu/vgpu-runtime-ownership-2026-08-15-diagnostic.json`
  completes `I0`, `I1`, `W0`, and `D0` on the same application oracle. Both
  governed lanes reproduce a hash-bound application receipt and pass the
  retained post-destroy error-handler regression. DoeRuntime does not exceed
  the governed incumbent on the frozen lifecycle outcome, so the report keeps
  vGPU diagnostic and assigns no runtime-ownership credit.
- The pinned wgsl-fns compilation application now declares its upstream build
  as a separate installation step. The reviewed diagnostic at
  `reports/ecosystem/wgsl-fns/wgsl-fns-compilation-suite-amd-vulkan-2026-08-10-diagnostic.json`
  binds the retained raw suite and records clean Doe process success across the
  unchanged upstream assertion and generated-shader corpus with physical
  adapter identity and no native compiler diagnostics. The overall reproduction
  remains failed and diagnostic because the pinned Node/Dawn comparator aborts
  during adapter probing and test execution on this host.
- The reviewed wgsl-fns ownership diagnostic at
  `reports/ecosystem/wgsl-fns/wgsl-fns-runtime-ownership-2026-08-15-diagnostic.json`
  executes `I0`, `I1`, `W0`, `D0`, and the frozen `webgpu@0.3.10` patch control.
  The pinned incumbent crashes, while Doe and the independently prepared
  `webgpu@0.3.10` plus no-isolation control both pass all 13 assertions, all 110
  generated functions, an exact `smoothStep` compute dispatch and readback,
  physical provider identity, and replay. The bounded wrapper correction
  closes the exercised outcome, so the report assigns no runtime-ownership
  credit and keeps wgsl-fns diagnostic.
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

- No external application has cleared the material-outcome and accepted
  runtime-ownership-cost gates. Completed HoloScript, vGPU, and wgsl-fns
  matrices reject DoeRuntime ownership for their declared tuples, so no
  application is currently a release blocker.
- Node, Bun, and Electron now have bounded package and application diagnostics,
  but none has cleared ownership, performance, reliability, adoption, and
  release promotion together. The wgsl-fns bounded incumbent correction closes
  its exercised outcome and therefore supplies no DoeRuntime ownership credit.
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

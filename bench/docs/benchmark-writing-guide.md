# Doe benchmark writing guide

This guide defines how to add and evolve benchmarks so results stay reproducible, apples-to-apples, and claim-safe.

Terminology note:
- use the benchmark taxonomy from `docs/benchmark-taxonomy.md`:
  - workload
  - surface
  - executor
  - run artifact
  - compare report
- when this guide says `backend` surface, it means Doe or Dawn implementing
  WebGPU semantics on the target backend runtime.
- when this guide says `plan` surface, it means both products executing the
  same normalized plan contract.
- runtime workloads usually mix API/setup work, first-use shader
  compilation/pipeline creation, and GPU execution unless the workload is
  explicitly scoped to isolate one of those layers.

## Scope

Applies to:
- `bench/workloads/specialized/workloads.generic.json`
- `bench/workloads.*.json`
- `bench/ir/*.json`
- `bench/plans/generated/*.plan.json`
- `examples/*_commands.json`
- `bench/native-compare/compare.config.*.json`
- `config/comparability-obligations.json`
- `config/backend-timing-policy.json`
- `config/webgpu-capability-inventory.json`
- `config/dropin_abi.symbols.txt`

## 1) Non-negotiables

- Fairness comes before speed. Do not present a faster number as evidence
  until the benchmark proves both sides performed equivalent work under the
  same timing scope.
- Comparable benchmark surfaces must be apples-to-apples by default.
- Any runtime-visible benchmark contract change must be schema/config-backed.
- Strict comparability must fail fast on mismatch, not silently report timings.
- Directional and claimable evidence must stay explicitly separated.
- Artifacts must be reproducible from config + workload + command files.

## 2) Source-of-truth files and checkpoints

- Workload contracts:
  - `bench/workloads*.json`
  - DOE-vs-Dawn comparable fullsuite contract: `bench/workloads/specialized/workloads.amd.vulkan.superset.comparable.json`
- Compare harness:
  - `bench/cli.py compare`
  - `bench/native_compare_modules/comparability.py`
  - `bench/native_compare_modules/timing_selection.py`
- Comparability obligation contract:
  - `config/comparability-obligations.json`
  - `pipeline/lean/Doe/Comparability.lean`
- Timing policy contract:
  - `config/backend-timing-policy.json`
  - `bench/gates/timing_policy_gate.py --backend vulkan`
- Coverage artifacts:
  - `config/webgpu-capability-inventory.json`
  - `config/dropin_abi.symbols.txt`

Required checkpoints for benchmark contract changes:
- `python3 bench/gates/comparability_obligation_parity_gate.py`
- `python3 bench/gates/schema_gate.py`
- targeted compare run for the modified workload set / surface config
- timing policy gate on that report (`bench/gates/timing_policy_gate.py --backend vulkan` for Vulkan timing-policy-bound benchmark surfaces)

## 3) Workload contract format (`bench/workloads*.json`)

Each workload entry is parsed by `bench/cli.py compare`.

Authoring rule:
- do not hand-edit the generated backend workload files under `bench/workloads*.json`.
- edit `bench/workloads/metadata/backend-workload-catalog.json` instead, then regenerate with:
  `python3 bench/tools/generate_backend_workloads.py`
- the catalog is the canonical backend workload source of truth; the generated files are execution views.

Required fields:
- `id`
- `name`
- `commandsPath`
- `runnerType`
- `quirksPath`
- `vendor`
- `api`
- `family`
- `driver`
- `dawnFilter`
- `domain`

Common comparability fields:
- `comparable`
- `default`
- `comparabilityNotes`
- `timingNormalizationNote`
- `baselineCommandRepeat`
- `comparisonCommandRepeat`
- `baselineIgnoreFirstOps`
- `comparisonIgnoreFirstOps`
- `baselineUploadBufferUsage`
- `comparisonUploadBufferUsage`
- `baselineUploadSubmitEvery`
- `comparisonUploadSubmitEvery`
- `baselineTimingDivisor`
- `comparisonTimingDivisor`
- `allowBaselineNoExecution`
- `extraArgs`

IR-backed workload fields:
- `irPath`
- `irScenario`
- `planPath`

IR-backed authoring rule:
- authored benchmark meaning belongs in `bench/ir/*.json`
- generated backend workload files may still carry `commandsPath`, but for
  IR-backed workloads those command files are compatibility artifacts, not the
  authored source of truth
- IR scenarios may set `matmulGemvVariant: row2_helper_exact` only when every
  `matmul-gemv.wgsl` dispatch in that scenario has even rows, columns
  divisible by four, and source dispatch `[rows,1,1]`; materialization rewrites
  those dispatches to `matmul_gemv_row2_helper_exact.wgsl` with dispatch
  `[rows/2,1,1]` and fails fast if the preconditions are not met.

### 3.2 Synthetic readonly assets for IR-backed inference workloads

When an IR-backed workload needs large synthetic readonly tensors that would be
impractical to inline as `buffer_write` data:

- author the deterministic asset policy in `shared.syntheticReadonlyBufferPolicy`
  inside the IR source
- use a deterministic generator + seed + scale so the payload hash is stable
  across reruns on the same contract
- materialize those payloads into the local asset cache, not Git:
  - `DOE_BENCH_ASSET_CACHE_DIR`
  - default: `~/.cache/doe/bench_synthetic_assets`
- let plan generation inject explicit `buffer_load` commands for readonly-only
  buffers instead of relying on implicit zero-filled buffer creation
- keep asset generation and cache warming outside timed samples
- keep the timed `buffer_load` command itself inside the benchmark when the workload
  is meant to be device-load-inclusive; that command measures:
  - host cache read
  - device-visible upload / staging

If you want an already-resident steady-state inference variant, author it as a
separate workload contract instead of silently changing the timing boundary.

Strict Dawn-vs-Doe operation comparability rule:
- when `comparability=strict` and `requireTimingClass=operation`, comparable workloads must use direct timing:
  `baselineTimingDivisor=1.0` and `comparisonTimingDivisor=1.0`.

### 3.3 Repo-only vendor and external command lanes

Some repo-only directional lanes use `commandsPath` as a JSON-array scenario
payload consumed by an explicit executor instead of a Doe command stream. That
is allowed only when all of these hold:

- the executor is explicit in `executor_registry.py`; do not hide custom runner behavior behind generic product names
- the scenario file is still a JSON array so receipt-first command-boundary tooling can load it consistently
- the workload is `benchmarkClass: directional`, `comparable: false`, and `claimEligible: false` when model artifacts or runtime stacks differ
- compare configs for those lanes must use `requireTimingClass: process-wall` unless both sides expose symmetric operation-scope timing and structural parity
- do not fabricate sibling host/runtime cells when the underlying tooling surface is missing; if a vendor lane is Node-only, document the absent Bun/native/browser cells explicitly instead of implying parity

Parser-level field constraints:
- `id` must be non-empty and unique per file.
- `baseline/comparisonCommandRepeat >= 1`
- `baseline/comparisonIgnoreFirstOps >= 0`
- `baseline/comparisonUploadSubmitEvery >= 1`
- `baseline/comparisonTimingDivisor > 0`
- strict Dawn-vs-Doe operation runs require `baseline/comparisonTimingDivisor == 1.0` for `comparable=true` workloads
- `baseline/comparisonUploadBufferUsage` must be `copy-dst-copy-src` or `copy-dst`
- `comparabilityCandidate.enabled=true` requires `comparabilityCandidate.tier`
- `comparabilityCandidate.enabled=true` cannot be combined with `comparable=true`

### 3.1 Workload ID naming contract (required)

Workload IDs are immutable contract keys. They must be stable across benchmark-class promotion and methodology changes.

Required pattern:
- `domain_subject_shape_variant` (snake case tokens)

Required rules:
- include domain first (for example: `upload`, `compute`, `render`, `pipeline`, `resource`, `surface`, `capability`, `lifecycle`, `texture`)
- encode operation semantics and stable shape descriptors (`1kb`, `200k`, `mip8`, matrix geometry, etc.)
- keep IDs status-free and lifecycle-free; do not encode maturity tier or rollout state
- do not rename an existing ID when it moves between directional/comparable/claim surfaces; change metadata fields instead
- avoid overloaded shorthand prefixes (`par_`, `exp_`, `ctr_`) and status tokens (`contract`, `proxy`, `macro`) in new IDs

Classification and methodology belong in fields, not ID text:
- `comparable`
- `benchmarkClass`
- `comparabilityCandidate`
- `comparabilityNotes`
- timing normalization fields

## 4) Apples-to-apples strict rules for comparable workloads

Comparable workloads (`comparable=true`) in strict mode must satisfy both:

1. Contract symmetry:
- baseline/comparison command repeat match (`left*`/`right*` fields in the contract)
- baseline/comparison ignore-first match
- baseline/comparison upload usage + submit cadence match
- baseline/comparison timing divisor match

2. Measured comparability obligations:
- `baseline_comparison_trace_meta_source_match`
- `baseline_comparison_timing_selection_policy_match`
- `baseline_comparison_queue_sync_mode_match`
- `baseline_comparison_submit_scope_match`
- `baseline_comparison_timing_phase_match`
- `baseline_comparison_execution_shape_match`
- `baseline_comparison_hardware_path_match`
- `baseline_comparison_upload_buffer_usage_match`
- `baseline_comparison_upload_submit_cadence_match`
- `baseline_upload_ignore_first_scope_consistent`
- `comparison_upload_ignore_first_scope_consistent`

Obligation IDs are contract-controlled by `config/comparability-obligations.json`.

## 5) Execution-shape parity (critical — applies to ALL domains)

Normalization symmetry alone is not enough. A workload can still be invalid if runtime execution shape diverges.

Strict comparability for ALL domains (compute, render, upload, resource, pipeline, texture) requires matching sampled execution tuples:
- `executionDispatchCount`
- `executionRowCount`
- `executionSuccessCount`

If these differ between baseline and comparison, strict comparable classification must fail.

This is not optional for non-compute domains. A render workload where the baseline executor dispatches 500 draws and the comparison executor dispatches 0 is not comparable regardless of what `comparable: true` says in the workload contract.

## 5.1) Structural work equivalence (blocking for comparable)

Beyond dispatch count matching, both sides must perform structurally equivalent GPU operations:

1. **Execution completeness**: both sides must execute all commands in the workload. If one side returns `unsupported` or skips execution, the comparison is invalid.

2. **Timing-phase symmetry**: both sides must report non-trivial timing in the same phases (setup_ns, encode_ns, submit_wait_ns). Violations:
   - baseline setup_ns=0 across all workloads AND comparison setup_ns>0 → instrumentation gap, not genuine zero cost.
   - baseline submit_wait_ns=0 across all workloads AND comparison submit_wait_ns>0 → baseline is not measuring GPU submission. The "speed win" is a scope mismatch.
   - comparison encode_ns=0 across all workloads AND baseline encode_ns>0 → different timing phases dominate on each side.

3. **Hardware-path equivalence**: if one side takes a hardware-specific shortcut (e.g. Apple Silicon UMA shared-memory memset that skips staging+copy) that bypasses operations the other side performs, the delta measures architectural path choice, not implementation quality. Such workloads must:
   - set `"pathAsymmetry": true` in the workload contract
   - include a transferability caveat in `comparabilityNotes`
   - fail strict Dawn-vs-Doe comparability/claimability gates until structural equivalence is restored
   - not be presented as general "faster" claims

4. **Zero-phase anomaly detection**: if one side reports an entire timing phase as identically zero across ALL workloads in a run, treat this as a systemic instrumentation gap. Audit the timing instrumentation before accepting any claimable results from that run.

## 5.2) Structural equivalence audit checklist

Before accepting claimable results from any run:

1. For each workload, verify baseline and comparison dispatch counts match.
2. For each workload, verify both sides report non-zero values in the same timing phases.
3. Flag any workload where one side's total is dominated by a phase the other side reports as zero.
4. Flag any workload where the speed delta comes primarily from setup or submit_wait that only one side measures.
5. For upload workloads on UMA hardware, verify both sides use the same transfer path (staging+copy vs shared-memory memset). If paths differ, mark `pathAsymmetry: true` and treat the workload as non-comparable for strict claim surfaces.
   Current strict Doe Metal/Vulkan/D3D12 compare surfaces should prove this from config: `config/backend-runtime-policy.json` must set `uploadPathPolicy: "staged_copy_only"` on `metal_doe_comparable` / `metal_doe_release`, `vulkan_doe_comparable` / `vulkan_doe_release`, and `d3d12_doe_comparable` / `d3d12_doe_release`.
   Once strict compare surfaces are staged-copy-only and timing phases match, remove the stale `pathAsymmetry` flag from the strict comparable workload contract; keep it only on directional/non-strict contracts or workloads with a separate unresolved plausibility issue.
6. Treat unusually large speedups as suspicious until audited. Check whether
   the result is really a runtime improvement or instead comes from
   cache/prepared-session state, skipped work, one-sided setup/upload/submit/
   readback cost, stale artifacts, hidden fallback, mismatched runtime paths,
   or a timing-scope mismatch.
7. Reject any "X/Y claimable" summary that has not passed per-workload structural equivalence checks.

## 6) Timing selection and normalization policy

Runtime timing scope reminder:
- operation timing on runtime workloads does not imply "pure GPU math only".
- unless a workload contract explicitly isolates compilation or pure execution,
  runtime operation timing may still include first-use pipeline/shader setup
  inside the measured workload unit.

For strict Dawn-vs-Doe claim surfaces, required timing class is `operation` by default.

For same-runtime parity surfaces (e.g. Dawn-vs-Dawn), operation timing remains
allowed under their surface contracts.

Current selection priorities in compare harness:
1. Explicit `traceMeta.timingMs`/`timingSource` when present, valid, and compatible with domain timing policy.
2. Upload-domain workload-total execution durations (`doe-execution-workload-total-ns`) when execution evidence exists.
3. Render and p0-render encode totals (`doe-execution-encode-ns`) only when encode is a plausible share of total execution on that side; render-macro, p0-render-macro, and render-bundle workloads use total execution timing.
4. Execution total (`doe-execution-total-ns`) when execution evidence exists.
5. GPU timestamp total (`doe-execution-gpu-timestamp-ns`) as fallback.
6. Dispatch window (`doe-execution-dispatch-window-ns`) when available.
7. Trace window or wall-time fallback only when operation sources are unavailable.

Strict Doe-native comparable workloads must also match canonical selected timing source and timing-selection policy across baseline/comparison. Mixed `encode` vs `total` source selection is a scope mismatch, not apples-to-apples evidence.

Run-receipt reporting rule:
- preserve the per-sample timing metadata needed to reconstruct selected timing
  and workload-unit wall after a receipt roundtrip.
- workload-unit wall must normalize through one explicit workload-unit divisor
  per sample; do not blindly multiply `commandRepeat` and timing-divisor
  metadata when they describe the same repeated workload unit.

Benchmark intent split (required reporting separation):

1. `apples-to-apples`:
   - workload contract marked comparable
   - strict comparability on
   - same timing basis across sides (default: `operation`)
2. `doe-advantage`:
   - directional/optimized workload contract
   - still measured with the same timing basis rule as apples-to-apples
   - cannot be reported as apples-to-apples comparable evidence

Upload-specific rule:
- ignore-first adjustment must stay in workload-total scope.
- do not mix ignore-first adjustments across different timing scopes.

Important:
- Do not force side-specific render timing overrides in strict apples-to-apples compare surfaces.
- Any allowed source deviations must be explicit in `config/backend-timing-policy.json` (including backend-specific allowlists).

## 7) Delta percent convention

Current compare reports use a percent-of-comparison convention:
- `((comparisonMs - baselineMs) / comparisonMs) * 100`
- positive means baseline faster
- negative means baseline slower

Interpretation examples:
- `+50%` means baseline is `2x` faster.
- `+90%` means baseline is `10x` faster.
- `+99%` means baseline is `100x` faster.

Always read the convention from report metadata fields
`deltaPercentConvention` and `deltaPercentFormula`. If an older artifact lacks
those fields, use the raw `baselineStatsMs` and `comparisonStatsMs` values and
state the speed ratio directly.

Fairness rule:
- never accept a speed claim from `deltaPercent` alone.
- any speedup at or above the configured
  `reliability.suspiciousSpeedupRatio` is suspicious until the receipts prove
  same work, same timing scope, equivalent cache/preparation state, no
  fallback, and matching dispatch/readback/output evidence.

## 8) Workload catalog size vs run size

Do not confuse total catalog inventory with one config run subset.

Example:
- active workload catalogs may contain more IDs overall
- a specific strict fullsuite config may intentionally execute a subset

When reporting counts, always state:
- source workload file
- selected workload filter/cohort flags
- final executed workload count in report

## 9) Neutral benchmark IR and command compatibility artifacts

For new end-to-end runtime workloads, the preferred authoring surface is the
neutral benchmark IR under `bench/ir/*.json`.

Normalized plans under `bench/plans/generated/*.plan.json` are the executable
contract that standalone executors consume.

`examples/*_commands.json` still exists, but for IR-backed workloads it is a
generated compatibility artifact for Doe runtime execution, not the authored
benchmark definition.

### 9.1 Command file contract (`examples/*_commands.json`)

Command files must be deterministic JSON arrays of command objects with `kind`.

Supported top-level command kinds:
- `upload`
- `copy_buffer_to_texture`
- `barrier`
- `dispatch`
- `dispatch_indirect`
- `kernel_dispatch`
- `render_draw`
- `draw_indirect`
- `draw_indexed_indirect`
- `render_pass`
- `sampler_create`
- `sampler_destroy`
- `texture_write`
- `texture_query`
- `texture_destroy`
- `surface_create`
- `surface_capabilities`
- `surface_configure`
- `surface_acquire`
- `surface_present`
- `surface_unconfigure`
- `surface_release`
- `async_diagnostics`

Authoring rules:
- stable ordering and stable values
- no random payloads
- explicit handles/IDs
- no implicit behavior assumptions hidden in command JSON

## 10) Coverage workflow (ABI, capability, feature mapping)

For new benchmark capabilities:
- map capability/feature coverage in `config/webgpu-capability-inventory.json`
- keep ABI surface contract in `config/dropin_abi.symbols.txt`
- regenerate feature benchmark table:
  - `python3 bench/tools/generate_feature_benchmark_table.py`

Coverage updates are separate from claimability. A covered feature is not automatically claim-ready.

## 11) Recommended workflow for new or changed benchmarks

1. Add or update neutral benchmark IR, or deterministic command file when IR is not yet appropriate.
2. Regenerate plans / compatibility command artifacts when the workload is IR-backed.
3. Add workload entry in the correct workload catalog.
4. Document normalization and comparability notes.
5. Run targeted compare config in strict mode.
6. Run `comparability_obligation_parity_gate.py` and `schema_gate.py`.
7. Run timing-policy gate for policy-bound lanes.
8. Treat any non-comparable output as diagnostic until obligations are green.

Useful strict run pattern:

```bash
python3 bench/cli.py run-config --config bench/native-compare/compare.config.amd.vulkan.doe-vs-dawn.fullsuite.json --side baseline
python3 bench/cli.py run-config --config bench/native-compare/compare.config.amd.vulkan.doe-vs-dawn.fullsuite.json --side comparison
# then join the emitted .run.json receipts with `python3 bench/cli.py compare ...`
python3 bench/gates/timing_policy_gate.py --backend vulkan --report bench/out/<timestamp>/vulkan.strict.doe_vs_dawn.fullsuite.apples.json
```

## 12) Anti-patterns

- Marking a workload `comparable=true` without proving execution-shape parity.
- Allowing mixed timing scopes between selection and ignore-first adjustment.
- Using directional or proxy workloads as claim evidence.
- Accepting side-specific timing-policy exceptions not codified in config.
- Reporting speed deltas without `deltaPercentConvention` context.
- Reporting subset counts without stating the workload source file/config.
- Claiming speed when one side reports 0 dispatches while the other dispatches (broken comparison, not a speed win).
- Claiming speed from zero-phase asymmetry (baseline submit_wait=0 while comparison submit_wait=40ms means the baseline did not measure GPU submission, not that it was faster).
- Claiming speed from submit-scope asymmetry in package lanes (one side's `submit_wait` is dominated by retained replay/flush work while the peer measures real queue wait).
- Treating universally-zero setup_ns on one side as genuine zero cost when the other side reports material setup. This is an instrumentation gap.
- Presenting hardware-path shortcuts (UMA memset vs staging+copy) as general speed claims without transferability caveats.
- Accepting aggregate "N/N claimable" without per-workload timing-phase audit. The metadata can pass while the actual work performed is structurally different.
- Applying execution-shape parity only to compute domains. Render, upload, resource, and pipeline workloads need the same checks.
- Citing an unusually large speedup before explaining why it is not caused by
  cache state, prepared-session state, stale receipts, skipped work, one-sided
  overhead, hidden fallback, or a timing-scope mismatch.

## 13) Templates

Minimal workload template:

```json
{
  "id": "example_workload_id",
  "name": "example-workload",
  "description": "Brief semantics of the workload.",
  "domain": "compute",
  "comparabilityNotes": "Matched kernel shape and normalization contract.",
  "commandsPath": "examples/example_commands.json",
  "quirksPath": "examples/quirks/amd_radv_noop_list.json",
  "vendor": "amd",
  "api": "vulkan",
  "family": "gfx11",
  "driver": "24.0.0",
  "dawnFilter": "SomePerfSuite.Run/Profile",
  "comparable": true,
  "default": false,
  "baselineCommandRepeat": 1,
  "comparisonCommandRepeat": 1,
  "baselineIgnoreFirstOps": 0,
  "comparisonIgnoreFirstOps": 0,
  "baselineUploadBufferUsage": "copy-dst-copy-src",
  "comparisonUploadBufferUsage": "copy-dst-copy-src",
  "baselineUploadSubmitEvery": 1,
  "comparisonUploadSubmitEvery": 1,
  "baselineTimingDivisor": 1,
  "comparisonTimingDivisor": 1,
  "timingNormalizationNote": "Document unit normalization and divisors.",
  "extraArgs": []
}
```

Minimal command file template:

```json
[
  {
    "kind": "upload",
    "bytes": 1024,
    "alignBytes": 4
  }
]
```

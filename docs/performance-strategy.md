# Doe performance strategy

## Purpose

This document defines how to pursue and communicate Dawn-vs-Doe performance work without creating comparability debt.

Use this for:

- benchmark methodology changes
- upload/copy/dispatch performance optimization
- performance claims against Dawn

## Core Rule

Do not optimize or claim from intuition.  
Optimize only from comparable measurements with explicit workload contracts.

## Claimability Order (Always)

1. Check `comparisonStatus`, `nonComparableCount`, and failure reasons.
2. Verify timing class is `operation` on both sides for per-op claims.
3. Verify workload normalization fields:
- repeat
- timing divisor
- ignore-first count
- upload buffer usage
- submit cadence
4. Inspect per-run traces for first-op spikes/outliers.
5. Interpret deltas only after all invariants hold.

If any invariant fails, label the run diagnostic, not claimable.

When reporting outcomes, include tails and floor, not only median:

- `p10` (fast-end floor view; less noisy than `p5` at low sample counts)
- `p50` (median)
- `p95` and `p99` (tail stability)

Recommended distribution-comparison stack for claim support:

1. ECDF overlays
2. bootstrap CI for delta `p50`/`p95`/`p99`
3. superiority probability `P(baseline<comparison)`
4. KS statistic + p-value
5. Wasserstein distance
6. workload×percentile delta heatmap

## Reliable Faster Contract

Use two labels only:

- `claimable`: can be used for "Doe is faster" statements.
- `diagnostic`: useful for engineering direction, not for claims.

`claimable` faster requires all of the following:

1. comparability passes (`comparisonStatus=comparable`, zero non-comparable workloads), including report-level comparability coherence.
2. sample floor: at least the configured `config/benchmark-methodology-thresholds.json::comparabilityDefaults.minTimedSamples` for comparable claim-eligible rows before compare reports can remain claimable; claim sidecars then apply local/release floors from `claimabilityDefaults`.
3. percentile sign consistency for speed claims:
- local: `delta p50 > 0` and `delta p95 > 0`
- release/CI: `delta p50 > 0`, `delta p95 > 0`, `delta p99 > 0`
4. timing-scope consistency:
- do not treat mixed-source derived timings as claimable (example: `doe-execution-dispatch-window-ns+ignore-first-ops` where base and adjustment measure different scopes)
- for upload claims, use a single operation-scope timing method consistently and document it in workload/report artifacts
- for compute/pipeline operation claims, selected operation timing is authoritative. Do not use `workloadUnitWall` to promote a row after selected operation timing loses.
- host kernel/pipeline prewarm belongs outside selected execution timing unless a workload contract declares a separate timing class. Record prewarm provenance as diagnostic metadata, not as an addition to `doe-execution-total-ns`.
5. operation-vs-wall sanity:
- selected operation timing must not cover an implausibly tiny share of process wall on one side while the peer side shows materially higher operation-to-wall coverage
- treat large baseline/comparison operation-to-wall coverage asymmetry as diagnostic until the timing scope is audited
- if selected operation timing and workload-unit wall disagree on claim sign, classify the row as diagnostic and fix the timing-scope explanation before citing the result.
6. no execution errors and no filter/adapter validity failures.
7. structural work equivalence:
- both sides must execute the same commands with non-zero work output. If one side reports 0 dispatches while the other reports >0, the comparison is invalid regardless of other metadata.
- both sides must report non-trivial timing in the same phases (setup, encode, submit_wait). If one side reports zero across an entire phase while the other reports material cost, the timing scopes do not match and the result is diagnostic.
- if baseline setup_ns=0 for all workloads AND comparison setup_ns>0 for a material fraction: flag as timing-instrumentation asymmetry.
- if baseline submit_wait_ns=0 for all workloads AND comparison submit_wait_ns>0: flag as scope mismatch (baseline is not measuring GPU submission cost).
8. hardware-path equivalence:
- both sides must perform structurally equivalent GPU operations. If one side takes a hardware-specific shortcut (e.g. UMA shared-memory memset) that bypasses operations the other side performs (e.g. staging buffer allocation + GPU blit copy), the delta measures architectural path choice on specific hardware, not implementation quality.
- such workloads must carry `pathAsymmetry: true` and a transferability caveat. In strict Dawn-vs-Doe claim surfaces they are blocking comparability failures until structural equivalence is restored.
- the gap from path asymmetry would vanish or invert on hardware where the shortcut does not apply (e.g. discrete GPUs with separate VRAM).

If any condition fails, classify the run as `diagnostic`.

## Prewarm and wall fallback retrospective

The 2026-06-06 AMD Vulkan audit caught a bad promotion path: a compute/pipeline
row could lose on selected operation timing while `workloadUnitWall` made the
row look claimable. That is not a valid operation-speed claim.

Current rule:

- keep `hostKernelPrewarmTotalNs` and related provenance outside selected
  execution timing.
- keep selected operation timing as the claim metric for compute/pipeline
  operation-speed claims.
- use workload-unit wall for diagnosis of missing work, prewarm behavior, and
  process-level overhead, not for claim promotion when selected timing loses.
- when selected timing and wall disagree on direction, label the row diagnostic
  and audit the methodology before making a speed claim.

The relevant fixed audit artifacts are:

- `bench/out/scratch/current-vulkan-fairness/dawn-vs-doe.amd.vulkan.current-fairness.fixed.json`
- `bench/out/scratch/current-vulkan-fairness/dawn-vs-doe.amd.vulkan.current-fairness.fixed.claim.json`

Harness support:

- `bench/cli.py compare` produces the compare report used for comparability.
- `bench/cli.py claim --mode local|release` evaluates claim policy separately
  and emits `claimStatus` in a sidecar claim report.

## Delta sign convention

Performance delta percent is reported from the compare report's baseline role:

- formula: `((comparisonMs - baselineMs) / comparisonMs) * 100`
- positive: baseline runtime faster
- negative: baseline runtime slower
- zero: parity

For the usual Doe-vs-Dawn compare report (`baseline=doe`, `comparison=dawn`):

- positive: Doe faster than Dawn
- negative: Doe slower than Dawn

## Near-Term Optimization Priorities

1. Align upload timing-source semantics so claim runs are methodologically stable.
2. Eliminate `upload_write_buffer_64kb` bimodality (submit-wait spikes + setup variance).
3. Isolate remaining steady-state hotspots (next focus after 64KB reliability: `upload_write_buffer_1mb`).
4. Remove steady-state allocator churn from upload paths.
5. Keep upload path allocation-light and reuse resources/encoders aggressively.
6. Tune submit cadence by size/profile with explicit config fields.
7. Optimize tails (`p95`/`p99`) in addition to `p50`.

## Investigation Loop (No Shortcut)

1. Reproduce with strict comparability and workload filter.
2. Increase samples (`iterations`) and keep warmup explicit.
3. Split measured cost into setup/encode/submit-wait/dispatch where available.
4. Classify each delta component:
- artifact (cold start / methodology mismatch)
- signal (steady-state per-op overhead)
5. Apply one change at a time and rerun strict comparison.
6. Record methodology and remaining caveats in docs/status.

## 64KB Upload Finding (2026-02-21)

Investigation outcome for AMD Vulkan `upload_write_buffer_64kb`:

1. `baselineCommandRepeat=50`, `baselineUploadSubmitEvery=50`, `baselineIgnoreFirstOps=1` showed strong bimodality and negative tails in repeated runs.
2. Switching `baselineIgnoreFirstOps` changed deltas dramatically, confirming high measurement-policy sensitivity.
3. Increasing `baselineCommandRepeat` to 500 with explicit per-op normalization produced strong positive diagnostics, indicating heavy batching/setup sensitivity.
4. Local follow-up on operation-scope upload submit-wait metric showed `baselineUploadSubmitEvery=100` outperformed `50` for the 64KB contract (`repeat=500`) in `bench/out/upload_64kb_submit_wait_100_vs_50.local.json` (`executionSubmitWaitTotalNs`, `n=30` per side): `p50 +19.52%`, `p95 +14.21%`; AMD Vulkan claim-mode recheck is still required on adapter-backed host.

Interpretation:

- the 64KB issue is primarily a reliability/methodology + submit behavior problem, not a simple one-dimensional throughput limit.
- claim-mode now enforces timing-scope consistency; legacy runs before this enforcement should be treated as diagnostic.
- queue wait implementation strategy can affect host behavior; keep wait-path changes explicit, trace-meta visible, and benchmark-backed before promoting them into claim workloads.

## Architecture Guidance: Zig vs C++

Language alone does not guarantee wins. C++/Dawn can close gaps with enough focused engineering.

Doe's durable advantage should come from:

- explicit hot-path control in Zig
- config-driven methodology with fail-fast comparability
- deterministic trace/replay for rapid root-cause loops
- proof-driven branch elimination (Lean) after Zig behavior is measured

Target advantage is not "Zig magic"; it is lower hot-path complexity plus faster safe iteration.

## Anti-Patterns (Do Not Do)

- accepting startup-only timings as comparable performance
- allowing implicit filter autodiscovery fallback in strict claim runs
- mixing timing classes (`process-wall` vs `operation`) for per-op claims
- hiding methodology knobs in code instead of workload/config
- reporting deltas when execution/adapter/filter validity failed
- claiming speed when one side reports 0 dispatches and the other dispatches >0
- claiming speed from zero-phase asymmetry (e.g. baseline submit_wait=0, comparison submit_wait=40ms — the "win" is that baseline did not measure GPU submission, not that it was faster)
- claiming compute/pipeline operation speed from workload-unit wall after selected operation timing loses
- folding host kernel/pipeline prewarm into selected operation timing without an explicit timing-class contract
- claiming speed from hardware-path shortcuts (e.g. UMA memset vs staging+copy) without transferability caveats
- treating zero setup_ns across all workloads as genuine when the comparison side reports material setup cost — this indicates an instrumentation gap
- marking a workload `comparable: true` when the two sides perform structurally different GPU operations, even if methodology metadata matches
- accepting a "30/30 claimable" summary without auditing per-workload timing-phase breakdown for each side

## Required Artifacts for Performance Claims

For each claimable result, keep:

- comparison report JSON
- per-run trace meta/jsonl artifacts
- workload config showing normalization/methodology knobs
- comparability status and failure-free summary
- date and command/config used

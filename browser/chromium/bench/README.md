# Browser Benchmark Superset (Nursery)

This module implements a layered browser benchmark superset for Chromium Track A (browser).

## Layers

1. `L0 engine`
   - host-specific strict runtime benchmark (`workloads.apple.metal.superset.json`
     on macOS; `workloads.amd.vulkan.superset.json` on other current lanes).
2. `L1 browser-api`
   - Playwright-driven browser WebGPU projections derived from `L0`.
3. `L2 browser-workflow`
   - browser end-to-end workflows that include WebGPU and browser lifecycle overhead.

## No-Maintenance Rule

1. Do not hand-maintain workload lists in nursery.
2. Generate projection manifest from core workloads using:
   - `scripts/generate-browser-projection-manifest.py`
3. Use `bench/projection-rules.json` for classification and scenario-template mapping.

## Files

1. `projection-rules.json`
   - domain -> projection-class/scenario-template mapping plus required-status and claim-scope.
2. `projection-manifest.schema.json`
   - schema for generated projection manifest.
3. `generated/browser_projection_manifest.json`
   - generated `L1/L0` projection rows with contract hashes, repo-relative source/rules paths, and browser workload parameters such as upload byte counts.
   - compute direct and indirect component rows carry source command hashes plus `directDispatchArgs` or `indirectDispatchArgs` so the browser runner can replay command-shaped `dispatchWorkgroups` and `dispatchWorkgroupsIndirect` rows instead of generic placeholders.
   - layered report schema v5 requires compute component dispatch rows plus source-kernel compute rows to emit `dispatchElapsedMs`, `encodeSubmitMs`, and `waitMs` phase telemetry, and every mode to prove the observed active runtime.
   - projection manifest schema v6 added oracle-v2 source-kernel rows with pinned exact output oracles. Every source-kernel report retains the complete timed-output SHA-256 for Dawn/Doe parity checks; oracle-v2 rows also retain the independent oracle result.
   - projection manifest schema v7 requires render rows to carry a full-raster RGBA8 oracle. The browser runner verifies every readback byte and both the manifest-owned and reconstructed SHA-256 identities; manifests without that contract fail closed.
   - macOS uses `generated/browser_projection_manifest.apple.metal.json`.
4. `workflows/browser-workflow-manifest.json`
   - `L2` workflow definitions with required status, claim scope, and promotion approver roles.
5. `workflows/browser-workflow-manifest.schema.json`
   - schema for `L2` workflow manifest.
6. `workflows/browser-promotion-approvals.json`
   - explicit promotion approvals for the roles required by the workflow manifest.
7. `workflows/browser-promotion-approvals.schema.json`
   - schema for promotion approval artifact.
8. `workflows/browser-milestones.json`
   - source-of-truth milestone state for M0-M6.
9. `workflows/browser-milestones.schema.json`
   - schema for milestone tracking.

## Scripts

1. `scripts/generate-browser-projection-manifest.py`
   - emits generated manifest from core workload source.
2. `scripts/webgpu-playwright-layered-bench.mjs`
   - runs `L1` and `L2` browser benchmark layers for dawn/doe.
   - the render projection uses a fullscreen triangle constrained by the declared viewport and scissor, allowing an exact whole-frame oracle instead of sampled-pixel checks. Oracle validation has its own timing phase and is excluded from `renderMs`.
3. `scripts/webgpu-playwright-ort-bench.mjs`
   - runs a repo-only same-stack browser ORT WebGPU Dawn-vs-Doe benchmark
     against the local Chromium-vendored DistilBERT sentiment model.
   - currently supports `--task sentiment`, `--task sentiment_medium`, and
     `--task sentiment_longform`.
4. `../../bench/native-compare/compare.config.browser.ort-webgpu.json`
   - canonical `bench/` compare config for the same browser ORT tasks.
5. `scripts/check-browser-benchmark-superset.py`
   - validates projection completeness/hash sync, optional report coverage, and optional promotion approvals.
6. `scripts/run-browser-benchmark-superset.py`
   - one-command orchestration (generate -> run -> check -> summary + checker artifact).
7. `scripts/score-browser-layered-report.py`
   - emits a diagnostic score sidecar from a layered dawn/doe report:
     row-weighted score, category-balanced score, per-category scores,
     included rows, and excluded rows.
8. `scripts/run-consumer-bench.sh`
   - macOS/local side-by-side wrapper that compares stock Chrome as the Dawn
     baseline against the host Fawn Chromium build with Doe forced on.
9. `scripts/run-fawn-runtime-bench.sh`
   - macOS/local wrapper that keeps the same host Fawn Chromium binary on both
     sides and compares its Dawn runtime path against its forced Doe runtime
     path.
10. `scripts/check-browser-milestones.py`
   - validates milestone state and required local evidence for M0-M6.

## Quick Start

From `` root:

```bash
npm --prefix browser/chromium ci
./browser/chromium/scripts/run-bench.sh
```

The benchmark front door selects the Apple Metal workload and projection
manifest on macOS. Other current hosts retain the AMD Vulkan defaults. Explicit
`--workloads` and `--manifest-out` arguments override host selection.

To run dawn/doe against different browser executables in one benchmark run:

```bash
./browser/chromium/scripts/run-bench.sh \
  --mode both \
  --dawn-chrome /Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
  --doe-chrome /path/to/your/doe-chromium-binary
```

On a macOS host with stock Chrome and a local Fawn source build, run the
consumer-facing diagnostic wrapper:

```bash
./browser/chromium/scripts/run-consumer-bench.sh --headless true --strict-run
```

To isolate the runtime swap inside the same local Fawn binary:

```bash
./browser/chromium/scripts/run-fawn-runtime-bench.sh --headless true
```

The Fawn runtime wrapper defaults to `modeSchedule=paired-balanced` and
`strict-run` so same-binary Dawn-vs-Doe evidence is order-balanced by default.

The wrapper writes the same layered diagnostic artifacts plus:

- `browser/chromium/artifacts/<timestamp>/chrome-vs-fawn.browser-layered.superset.score.json`

The CLI prints separate paired scores for the baseline and comparison modes,
with Doe as the default baseline and Dawn as the default comparison. Positive
`comparisonDeltaPercent` / `baselineLeadPercent` means the baseline mode is
faster, so the default score reads positive when Doe beats Dawn. `overall` is
row-weighted.
`categoryBalancedOverall` uses the geometric mean of per-category geomeans so a
dense category cannot dominate the headline view. The legacy relative index is
still present in JSON as `legacyRatioScore` for compatibility; `score` is the
baseline paired score. `strictComparable` is the fair browser-projection summary
and includes only scorable rows whose projection says
`comparabilityExpectation=strict` and whose `browserWorkload` records
`sourceComparable=true`, `sourceClaimEligible=true`, and
`benchmarkClass=comparable`. Projection manifest schema v6 requires every
non-strict browser projection to use `benchmarkClass=directional`.
`sourceClaimEligible` is source-workload provenance; it is not browser
claimability unless the row is strict-comparable.
`bottlenecks` lists the slowest categories, rows, and measured phases so
regressions do not require manual row sorting. The score is directional
diagnostic evidence, not a release performance claim. The score sidecar carries
source report, workload, mode order, browser executable, runtime, shader
compiler, adapter, and trace-hash identity anchors and is covered by the
browser artifact identity coverage gate.

Every mode also records an `activeRuntimeProof` derived from explicit
`GPUAdapter.info` fields. Requested launch arguments do not establish runtime
identity: forced Doe must report the Doe adapter vendor and platform backend,
while Dawn must report a non-empty, non-Doe vendor. The checker binds Metal to
macOS, Vulkan to Linux, and D3D12 to Windows, independently recomputes the
result, and fails closed on mismatches.

`--mode-order` records which runtime runs first. `--mode-schedule grouped`
preserves the historical behavior of running all rows for one runtime before
the next. `--mode-schedule paired` alternates runtimes per row and records each
schedule unit in `modeRunDetails`. `--mode-schedule paired-balanced` runs both
row orders and averages numeric metrics per runtime, with
`orderBalancedSampleCount` recorded in row metrics. Use order-balanced evidence
when auditing order-sensitive browser results before promotion. Non-grouped
schedules run strict-comparable `L1` rows before component diagnostics so
component probes do not precondition strict browser evidence.

Use `--mode-schedule-repetitions N` with a paired schedule when tuning a noisy
row. The report retains each timing observation in
`orderBalancedMetricSamples` and weights every observation equally. Startup
rows split adapter and device request time; surface and queue rows split
encode/submit from completion wait.

The L2 workflow manifest includes optional `fawn_visual_resource` rows for the
checked-in Fawn HTML pages under `browser/chromium/resources/`. Those rows load
the visible pages through the same local Playwright server and score shared
frame-time telemetry only when both Dawn and forced Doe emit it. Reports and
score rows carry the checked-in HTML resource path and SHA-256 so visual rows
stay tied to the exact page source that ran.

Layered runs request the high-performance WebGPU adapter by default on both
browser modes. Override with `--power-preference default` or
`--power-preference low-power` only when the artifact is meant to describe that
adapter policy; the raw report records the selected adapter request policy.

Texture L1 rows emit `textureMs` in addition to total `elapsedMs`. The score
sidecar prefers `textureMs` so adapter/device startup remains visible evidence
without dominating the texture-path category score. Texture rows also emit
phase-level diagnostic medians and tails, including texture creation,
texture write, view creation, render pipeline creation, submit/readback,
map/read, wait, and destroy where the scenario exercises those phases. Use
`--iters-texture` to set the texture sample count.

Upload L1 rows emit the requested and effective iteration counts, upload bytes,
total uploaded bytes, and `iterationPolicy`. Browser upload rows above the
exact-upload ceiling remain `l0_only` in the generated projection manifest
instead of being silently downscaled.

Render-readback L1 rows emit `renderMs` plus render-path phase timings so
adapter/device setup stays outside the render category score while remaining in
the raw scenario evidence.

For tuning one weak area without running the full diagnostic surface, pass one
or more focused categories:

```bash
./browser/chromium/scripts/run-consumer-bench.sh --headless true --focus-category texture --focus-category render
```

Focused reports remain diagnostic and carry `workloadFilter` counts. The
superset checker validates only rows in the selected categories and rejects
rows that leak in from outside the filter. Score sidecars copy the same
`workloadFilter` so focused scores are self-describing.

To attribute the native Doe Metal command path, run an explicitly instrumented
diagnostic:

```bash
./browser/chromium/scripts/run-fawn-runtime-bench.sh \
  --headless true \
  --focus-category compute \
  --native-metal-trace
```

This mode uses `config/browser-metal-native-trace.json`, hash-binds the emitted
JSONL, and reports command-buffer create, encode, commit, and flush totals. The
instrumented timings are excluded from browser scores.

Default outputs are lane-local diagnostic artifacts under:

- `browser/chromium/artifacts/<timestamp>/dawn-vs-doe.browser-layered.superset.diagnostic.json`
- `browser/chromium/artifacts/<timestamp>/dawn-vs-doe.browser-layered.superset.check.json`
- `browser/chromium/artifacts/<timestamp>/dawn-vs-doe.browser-layered.superset.summary.json`

Repo-only browser ORT WebGPU evidence uses:

```bash
node browser/chromium/scripts/webgpu-playwright-ort-bench.mjs \
  --mode both \
  --task sentiment \
  --headless true \
  --timed-iters 5 \
  --warmup-iters 2
```

The current canonical compare artifact is:

- `bench/out/browser-ort-webgpu-compare/20260420T203851Z/browser.compare.json`

If you intentionally need `bench/out`, pass `--allow-bench-out` explicitly.
Diagnostic outputs under `bench/out` are restricted to `bench/out/scratch`.

## Cadence

1. Daily browser smoke runs.
2. Twice-weekly layered benchmark runs.
3. Weekly promotion review.

## Promotion Gate

Promotion candidates must pass:

1. hash-synchronized projection contract checks,
2. explicit status/statusCode evidence for required `L1/L2` rows,
3. promotion approvals matching the roles declared by the workflow manifest.

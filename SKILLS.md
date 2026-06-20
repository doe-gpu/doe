# Doe performance tuning skill

Use this file for Dawn-vs-Doe performance tuning and benchmark-guided runtime
optimization.

## Goal

Make Doe faster than Dawn without breaking apples-to-apples methodology.

## Read this with

- `docs/performance-strategy.md`
- `bench/README.md`
- `bench/docs/benchmark-writing-guide.md`

## Workflow

1. Start from a strict comparable workload.
   - Prefer governed comparable rows or IR-backed rows.
   - Do not optimize against directional rows unless the output is explicitly
     diagnostic.
   - Decide whether the target is:
     - direct implementation (`doe-plan-executor` vs direct Dawn executor), or
     - package surface (Doe-backed `doe-gpu` vs Dawn-backed WebGPU on the
       same Node/Bun host lane).
   - Do not mix those two when making a claim.

2. Build the real executors you are about to benchmark.
   - Doe direct backend path in optimized mode.
   - Dawn direct executor when the row uses the neutral IR path.

3. Run enough samples to trust the result.
   - Local tuning default: at least `16` iterations and `1` warmup.
   - Use more warmup on noisy Metal rows.

4. Check methodology before reading deltas.
   - `comparisonStatus` must be `comparable` for apples-to-apples work.
   - Verify execution-shape parity, timing-source parity, and phase symmetry.
   - Reject rows with structural work mismatch or timing-scope mismatch.

5. Convert percent deltas back to raw speed before making a claim.
   - Use `baselineStatsMs` and `comparisonStatsMs`; do not infer speed from
     `deltaPercent` alone.
   - For the current compare convention, speed ratio is
     `comparisonStatsMs / baselineStatsMs`.
   - Treat any speedup at or above
     `reliability.suspiciousSpeedupRatio` in
     `config/benchmark-methodology-thresholds.json` as a fairness-audit
     trigger until the artifact proves identical work, timing scope, cache
     state, fallback state, dispatch work, and readback/output work.

6. Read the metrics in this order.
   - `selectedTiming`: core comparable operation scope.
   - `workloadUnitWall`: full timed workload-unit wall.
   - `hostOverheadBreakdown`: coarse explanation of wall minus selected timing.

7. Tune the bottleneck the artifact actually shows.
   - If `selectedTiming` is bad, optimize shader compilation, command encode,
     submit/wait, or GPU work.
   - If `selectedTiming` wins but `workloadUnitWall` loses, target the
     breakdown buckets: input read/parse, workload prepare, executor init,
     prewarm, command orchestration, or artifact finalize.

8. Re-run the same workload after each meaningful change.
   - Keep the workload contract fixed while tuning.
   - Only change methodology deliberately and document it when you do.

## Do not do these

- Do not turn a directional row into a claim.
- Do not change workload semantics just to improve a number.
- Do not trust a single rerun with contention or obvious outliers.
- Do not present a Doe win from mismatched work, mismatched timing scope, or
  hardware-path asymmetry as a general speed claim.

## Useful entrypoints

- `python3 bench/cli.py run-config --config <compare-config.json> --side baseline`
- `python3 bench/cli.py run-config --config <compare-config.json> --side comparison`
- `python3 bench/cli.py compare <baseline.run.json> <comparison.run.json>`
- `python3 bench/runners/run.py`
- `zig build -Doptimize=ReleaseFast`
- `zig build webgpu-plan-executor`

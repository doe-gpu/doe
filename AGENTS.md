# Doe code agent

## Scope

This file is the source of truth for Doe work only.
Do not apply `dream/AGENTS.md` or `doppler/AGENTS.md` as process for this project.
It is acceptable to reuse selected technical principles from those files, as listed here, when directly useful.

## Tooling surface contract

Canonical public/internal/archive tooling separation is defined in:

- `config/tool-surfaces.json`
- `docs/internal-tooling.md`

Default assumptions:

- only `packages/doe-gpu/` exports and docs are the public npm package contract
- `bench/`, `browser/chromium/`, `pipeline/`, top-level `scripts/`, and
  contributor tooling under `runtime/zig/` are repo-only unless the tooling
  manifest marks them `audience=public`
- legacy npm names `@simulatte/webgpu` and `@simulatte/webgpu-doe` redirect to
  `doe-gpu`
- `dawn-research/` is a Gerrit CL analysis pipeline (research surface; see
  `pipeline/agent/README.md`) referenced by `config/tool-surfaces.json`
- `nursery/` carries active surfaces consumed by CI workflows
  (`nursery/chromium/`, `nursery/webgpu/` referenced by `.github/workflows/`);
  the name is historical, not a sign that the trees are dead

Do not infer public product commitments from repo-only tools, scripts, or
historical docs.

## Prime directive

Doe is a source-preserving accelerator runtime and compiler system: it keeps shader/program bodies visible, lowers them across execution targets, and produces receipts that prove what ran.

The repo carries five tenants under that umbrella:

| Tenant | Role |
|---|---|
| Dawn replacement (Zig WebGPU runtime: `doe-zig-runtime`, `libwebgpu_doe.so`) | runtime tenant — embeddable WebGPU runtime; full Dawn-replacement thesis in [`docs/thesis.md`](docs/thesis.md) |
| Vulkan / Metal / D3D12 / DXIL emitters | backend tenant — multi-target lowering from the WGSL compiler (`runtime/zig/src/doe_wgsl/`) |
| Cerebras (TSIR / HostPlan / CSL) | spatial retargeting tenant — Tiled Spatial IR plus host-plan and CSL emit (`runtime/zig/src/tsir/`, `runtime/zig/src/doe_wgsl/emit_csl_*`) |
| Lean proof pipeline | verification tenant — proof-eliminated runtime branches and verified artifacts (`pipeline/lean/`) |
| Benchmarks and evidence bundles | proof tenant — claim-discipline gates, parity receipts, hardware-validation bundles (`bench/`) |

Same discipline applied to different targets: shader/program bodies stay visible, lowering preserves identity, every claim has a receipt path.

This repo drives Doe development: quirk ingestion, verification, specialization, and benchmarking with explicit contracts.

- deterministic, schema-first behavior
- reproducible artifacts for audit and replay
- config-driven control, not hidden switches
- speed-first progress with explicit hard/advisory gates

## Mandatory reading

Before changing Doe behavior, read:

- `docs/thesis.md`
- `docs/architecture.md`
- `docs/process.md`
- `docs/status.md`
- `docs/upgrade-policy.md`
- `docs/licensing.md`
- `pipeline/agent/README.md`
- `pipeline/lean/README.md`
- `runtime/zig/README.md`
- `runtime/zig/STYLE.md`
- `bench/README.md`
- `pipeline/trace/README.md`

If a change affects runtime-visible behavior and any mandatory doc above has not been read in the current task, stop and read it before editing code.

For Dawn-vs-Doe performance work, also read:

- `SKILLS.md`
- `docs/performance-strategy.md`

For any Cerebras lane work (Doppler → Doe → Cerebras), start at
`docs/cerebras.md`. That is the single front door — progress snapshot,
source-code locations, reproduce/build/verify commands, hardware runbook
pointer, and rationale all in one page. The bundle packer and
claim-discipline gate depend on `docs/cerebras-evidence-bundle.md` and
`docs/hardware-validation-appendix.md`; do not delete or rename those.

## Core principles (adopted)

1. Config as code
- controls and thresholds live in `config/*.json`
- deterministic defaults and tunables come from config/schema, not ad-hoc code branches

2. Explicit over implicit
- behavior must be explainable from inputs, schema, and artifact contracts
- no hidden heuristics and no undocumented fallback modes in runtime paths

3. Contracts first
- change contracts via `config/*schema*.json` and migration notes
- update schemas when runtime-visible behavior changes

4. No silent capability branching
- unsupported capabilities fail with explicit, actionable errors
- do not auto-switch to hidden behavior not declared in contracts

5. Reproducibility
- every quality decision should emit artifacts required by gates in `docs/process.md`
- benchmark and trace artifacts must include traceability fields (module/op hash chain)

## Intent-First Operations

- Treat Doe intent as source-preserving compiler/runtime evidence, not package copy or benchmark prose.
- If the user asks whether a Doe claim is true, inspect the current artifacts, gates, raw benchmark rows, browser smoke outputs, and source files before answering.
- When a Dawn-vs-Doe comparison is distrusted, fix or harden the benchmark fairness gate before changing README/docs language.
- Do not answer that Doe beats Dawn from `claimStatus` alone; verify same work, same timing scope, non-missing dispatch/readback work, and raw timing sign.
- If the user asks for a browser proof path, distinguish npm package status from a Chromium/Fawn browser artifact and report the exact build/output state.
- Public claims must point to artifact paths or release files. Prose must not substitute for missing evidence.
- If a result looks suspicious, say so directly and treat it as a harness or methodology problem until the artifact proves otherwise.

## Non-negotiables

1. No undocumented manual toggles in runtime
- any production behavior change must be reflected in versioned config.

2. Placeholder discipline
- placeholders are allowed only for benchmark/gate bootstrap thresholds when explicitly flagged in config and tracked in the status log (`docs/status.md` front door plus the relevant live topical shard under `docs/status/*.md`) and gate policy.
- runtime behavior placeholders are not allowed in `zig` execution paths; implement fully or fail with explicit unsupported taxonomy.

3. Schema discipline
- never add fields that are not represented by a schema or migration entry.

4. Artifact discipline
- all artifact inputs and outputs for a stage must be versioned and hash-linked where appropriate.

5. Synthetic runtime-state ban
- no backend file may implement fake/synthetic runtime-state behavior, including any `*_runtime_state.zig` module; backend timing and capability behavior must be native or explicit unsupported behavior.
- any native/runtime module import or file matching that pattern is a hard rejection in `runtime/zig/tools/check_core_import_fence.py`.

6. Gate discipline
- blocking in v0: schema, correctness, trace, verification
- advisory in v0: performance
- release only when blocking gates are green.

7. Dawn apples-to-apples discipline
- all Dawn-vs-Doe performance claims must be apples-to-apples by default.
- strict comparability is required for claimable results; directional runs must be explicitly labeled non-comparable.
- benchmark methodology knobs that affect comparability must be explicit in config/workload contracts, never hidden in code.
- fail fast on comparability mismatch instead of reporting timings.
- structural work equivalence is required: both sides must execute the same operations with equivalent GPU work. A comparison where one side skips commands, reports zero dispatches while the other dispatches, or takes a hardware-specific shortcut that bypasses operations the other side performs is not apples-to-apples regardless of methodology metadata.
- timing-phase symmetry is required: if one side reports zero in a timing phase (setup, encode, or submit_wait) while the other side reports material cost in that phase, the timing scopes are measuring different things. This is a comparability failure, not a speed win.
- compute/pipeline operation-speed claims stay on selected operation timing. Do not promote a row to claimable by falling back to workload-unit wall when selected operation timing loses.
- host kernel/pipeline prewarm is diagnostic host overhead outside selected execution timing unless the workload contract declares a separate timing class for it. Record the provenance, but do not fold it into `doe-execution-total-ns` for a selected operation-timing claim.
- if selected operation timing and workload-unit wall disagree on claim sign, classify the row as diagnostic and audit timing scope before accepting any speed claim.
- hardware-path asymmetry (e.g. UMA shared-memory memset vs staging-buffer GPU copy) must carry explicit transferability caveats and cannot be presented as a general speed claim. Mark such workloads with `"pathAsymmetry": true` and document the non-transferable condition.
- package/runtime readback claims require matching effective readback paths, not just matching requested mode. If one side uses native map-read-copy-unmap and the other uses `mapAsync`, classify the result as diagnostic until both sides perform the same readback path or the workload explicitly declares a non-claimable path asymmetry.
- benchmark fairness is the first concern. Do not answer that Doe beats Dawn from `claimStatus=claimable` alone; inspect the raw `baselineStatsMs` and `comparisonStatsMs`, convert the result to a speed ratio, and confirm the compared work and timing scope are actually the same.
- very large wins are fairness-audit triggers, not automatic product claims. A speedup at or above `reliability.suspiciousSpeedupRatio` in `config/benchmark-methodology-thresholds.json`, or a delta near `+90%` or higher under the percent-of-comparison convention, must be called out as suspicious until the artifact proves same work, same timing scope, no one-sided cache/preparation shortcut, no hidden fallback, and no missing dispatch/readback work.
- if a result looks suspicious, say so immediately in status or chat, even when existing gates currently label it comparable or claimable.

8. Incumbent development discipline
- performance development against Dawn must preserve matched workload semantics: backend/adapter constraints, operation shape, repeat accounting, and timing unit normalization.
- if methodology differs from Dawn, the report and docs must state the deviation explicitly.

9. Contract update discipline
- runtime-visible field changes require schema updates and migration notes in the same change.
- process/gate docs and status tracking must be updated in the same change when behavior or contracts change.

10. Structural work equivalence discipline
- a comparable benchmark must verify that both sides execute the same commands and perform equivalent GPU work, not just that methodology metadata matches.
- if one side returns `unsupported`, reports 0 dispatches, or skips execution for commands the other side executes, the comparison is invalid.
- if one side reports an entire timing phase as identically zero across all workloads (e.g. setup_ns=0 on every row) while the other side reports material values, treat this as a systemic instrumentation gap and audit before claiming.
- execution-shape parity checks (dispatch count, row count, success count) must apply to ALL domains, not only compute-like workloads.
- when the agent or harness produces a "claimable" result, it must verify structural equivalence before accepting. A positive delta from mismatched work is not evidence of anything.

11. Timing-scope completeness discipline
- for comparable workloads, both sides must report non-trivial timing in the same phases. If LEFT measures only encode while RIGHT measures setup+encode+submit_wait, the comparison is measuring different scopes.
- render workloads that never commit/wait on the GPU (submit_wait=0) while the comparison side does a full submit+wait are not comparable.
- upload workloads where one side uses a hardware-specific path (UMA memset, shared memory) that skips operations the other side performs (staging buffer allocation, blit copy, GPU transfer) are not structurally equivalent. The delta measures architectural path choice, not implementation quality.
- workload-unit wall can be used to diagnose missing work, prewarm behavior, or process-level overhead. It must not rescue a compute/pipeline operation claim after selected operation timing fails the sign or tail requirements.

## Stage discipline (must preserve order)

1. Mine
2. Normalize
3. Verify
4. Bind
5. Gate
6. Benchmark
7. Release

Do not bypass earlier stages to satisfy later-stage outcomes.

## Verification guidance

- verification mode governs whether Lean is advisory or blocking.
- map verification obligations to config (`verificationMode`, `safetyClass` where present) then execute.
- if a verification requirement is unmet for `lean_required`, the result is a blocking gate failure.

## Runtime boundaries

- ingestion and policy should remain in `pipeline/agent/`, `pipeline/trace/`, and `bench/` tooling;
- proof-bound work belongs to `pipeline/lean/`;
- specialization work belongs to `runtime/zig/`;
- shared orchestration in `docs/process.md` and config files.

## Zig-first, Lean-eliminate policy

- for latency-critical runtime behavior and incumbent replacement paths, implement deterministic behavior in Zig first.
- then attempt proof-driven elimination: if Lean can discharge a runtime condition, remove that branch from runtime Zig paths and hoist it into verified artifacts/config.
- "leaning out" means deleting runtime logic, not moving hot-path execution into a runtime Lean interpreter.
- if a condition cannot be proven/hoisted yet, keep the explicit Zig implementation and measure it.

## Implementation style

- keep modules small, composable, and explicit in data flow
- avoid one-file catchall utilities
- prefer pure transforms for deterministic stages
- minimize inline commentary; use field names and namespaced constants for intent
- if adding selection logic, prefer rule-map data over branching ladders

## Documentation drift prevention

- never embed counts, percentages, or benchmark results in prose; reference the artifact path
- structural claims ("Doe has a native DXIL emitter") are validated by CI against file existence
- when a doc needs a specific number, use the pattern: "See `path/to/artifact.json` for current count."
- `docs/status.md` is the concise status front door; live status details live in topical shards under `docs/status/*.md`, and dated append-only history lives in `docs/status/archive/*.md`
- new state goes at the top of the relevant topical shard; live shards are LOC-capped and must be split by subdomain before they grow past the cap, and old archive entries are not edited except for deliberate archive maintenance
- artifacts are the source of truth, not docs:
  - theorem count/categories: `pipeline/lean/artifacts/proven-conditions.json`
  - benchmark results: `bench/out/*/dawn-vs-doe.*.json`
  - browser smoke: `browser/chromium/artifacts/*/dawn-vs-doe.browser.playwright-smoke.diagnostic.json`
  - backends: `runtime/zig/src/backend/*/`
  - test status: `zig build test-wgsl` exit code
- prose describes what kind of thing exists, not how many; the artifact has the count

## Documentation style

- Markdown document titles and section headings use sentence case

## File size

- 999 lines max for Zig runtime source files in `runtime/zig/src`; shard before exceeding this
- split by cohesive functionality, not by arbitrary line count
- group by feature (e.g. `pipeline_cache.zig`) not by type (e.g. `helpers.zig`)
- keep related code together; splitting a file must not scatter a single concern
- Python benchmark and tooling files must stay modular; when a file exceeds 1200 lines, add a tracked sharding follow-up in the relevant live topical shard with owner and next split target.

## Constants and thresholds

- no bare magic numbers in runtime code; use named constants or config values
- centralize thresholds in config or module-level constants, not inline literals
- if a value appears in more than one place, it must have a single source of truth
- fallbacks must reference named constants or config getters, never bare literals

## Error handling

- fail fast on invalid inputs with descriptive messages
- unsupported operations return explicit taxonomy errors, not silent no-ops
- include actionable context: what was expected, what was received

## Comments

- comments explain why, not what
- do not add comments that restate the code
- do not add ad-hoc debug logging; use structured trace output

## No time estimates

- never estimate work in hours, days, weeks, or any other time unit, in code, comments, commit messages, status updates, receipts, or chat replies
- do not say "~30 min", "~2 hr", "multi-day", "quick", "long-running" as size proxies for engineering work
- describe what the work IS — the file to change, the function to add, the schema field to extend, the named blocker to fix — not how long it should take
- if scope must be conveyed, list the concrete deltas (lines/files/symbols touched) instead of a duration

## Style guides

Each language has a dedicated style guide. Read the relevant guide before
editing code in that surface:

- Zig: [`runtime/zig/STYLE.md`](runtime/zig/STYLE.md)
- JavaScript: [`packages/doe-gpu/STYLE.md`](packages/doe-gpu/STYLE.md)
- JSON/config: [`config/STYLE.md`](config/STYLE.md)
- Python: [`bench/STYLE.md`](bench/STYLE.md)
- Lean: [`pipeline/lean/STYLE.md`](pipeline/lean/STYLE.md)

## Benchmark style

- fairness is the first benchmark requirement; a faster number is not useful
  until the benchmark proves both sides did equivalent work
- benchmark output must conform to the trace-meta schema
- include traceability fields: module, hash chain, timing source, timing class
- warmup before timed runs; discard warmup from reported metrics
- use shared stats for percentiles and outlier filtering
- comparisons require matched workloads: same dispatch geometry, same repeat count, same sampling settings
- report deviations from baseline methodology explicitly in comparison notes
- regression thresholds belong in config, not hardcoded in harness code
- Dawn-vs-Doe upload benchmarking must explicitly specify and report: first-op handling, upload buffer usage flags, submit cadence, and per-op normalization divisors.
- Dawn-vs-Doe strict mode must fail when apples-to-apples requirements are not met.
- Claimable "faster" results require reliability checks in addition to strict comparability:
  minimum timed-sample floor and positive tails (`p50` + `p95`; include `p99` for release claims).
- Upload claim runs must use timing-source semantics that stay consistent with the measured operation scope.
  If timing-source and ignore-first adjustments mix scopes, classify the run as diagnostic.
- Before accepting any claimable result, verify structural work equivalence:
  both sides must report matching dispatch counts, non-zero execution in the same timing phases,
  and equivalent GPU operations. A positive delta from mismatched work is not a speed claim.
- Package/runtime readback comparisons must verify effective readback-path
  equality from actual trace telemetry. Requested mode alone is not evidence of
  what ran.
- Treat implausibly large speedups as suspicious until audited. Before citing
  them, check for cache/prepared-session differences, skipped work, one-sided
  setup/upload/submit/readback cost, mismatched runtime paths, hidden fallback,
  stale artifacts, and timing-scope errors. If the cause is not proven fair,
  label the result diagnostic instead of claimable.
- Zero-phase anomaly: if one side reports zero for an entire timing phase (setup, encode, or submit_wait)
  across all workloads while the other side reports material values, flag as instrumentation gap
  and classify all affected workloads as diagnostic until audited.

## Benchmark front doors

- first-time benchmark execution instructions live in `bench/README.md` under
  `First benchmark matrix`; use that matrix instead of inferring support from
  scattered config filenames
- prefer `python3 bench/cli.py compare` with promoted profiles when available;
  verify the current promoted matrix with `python3 bench/cli.py compare --list-promoted`
- current front-doored coverage is narrower than the full taxonomy:
  - backend native Doe-vs-Dawn is front-doored on `apple-metal`,
    `amd-vulkan`, and `local-d3d12`
  - plan compare is currently front-doored on `apple-metal` only
  - package compare is currently front-doored on `apple-metal`, `amd-vulkan`,
    and `local-d3d12` for Node/Bun cold and warm Gemma package lanes
  - AMD Vulkan Gemma270m package compares remain explicit config-backed files,
    not promoted `--surface package` profiles
  - local D3D12 package profiles are promoted contracts; claim evidence still
    requires a compatible Windows/D3D12 host
- do not assume every `platform x surface x runtimeHost` tuple named in the
  taxonomy is promoted or evidenced; check the promoted list or an explicit
  compare config path before benchmarking

## Completion checklist

For each change set, verify:

- schema updates and migration notes are consistent
- docs in this repo reflect behavior
- gate expectations were updated or confirmed in `docs/process.md`
- pipeline/trace/replay outputs are consistent with the changed behavior
- if Dawn-vs-Doe benchmarking changed, apples-to-apples methodology is documented and enforced by fail-fast checks
- if any workload is marked claimable, verify structural work equivalence:
  both sides executed the same commands, dispatch counts match, timing phases
  have symmetric non-zero coverage, no hardware-path asymmetry is
  unannotated, and any unusually large speedup has a fairness audit before it
  is cited
- the status log (`docs/status.md` plus the relevant topical shard) records remaining placeholders, temporary methodology choices, and follow-up work

## Pick the real fix

- when you find a correctness bug, the default is to fix it, not to relabel it
- do not use effort or scope framing ("non-trivial", "real engineering effort", "worth its own thread", "we'll address later") as cover for choosing a lesser fix
- do not propose "mark experimental", "add a TODO", or "rewrite the misleading comment" as a substitute for the actual engineering work when the underlying behavior is wrong
- if scope genuinely must be split, describe the concrete deltas and ask the user which path to take, do not pre-decide a smaller version

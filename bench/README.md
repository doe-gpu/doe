# Doe bench

Audience:

- internal operator tooling and contributor workflows
- not part of the public `doe-gpu` npm package contract

Canonical front doors:

- `bench/cli.py` — canonical benchmark CLI
- `runners/publish_apple_runtime_release.py`
- `run_release_pipeline.py`
- `run_blocking_gates.py`
- `generate_backend_workloads.py`

Canonical compare taxonomy:

- `docs/benchmark-taxonomy.md`
- `config/compare-taxonomy.json`
- `config/generated/compare-taxonomy-expanded.jsonl`

For public package usage, use `packages/doe-gpu/README.md`. For the public vs
repo-only tooling boundary, use `docs/internal-tooling.md`. For the Apple
runtime bundle receipt, use `docs/apple-metal-runtime-release.md`.

Purpose:
- run correctness and performance measurements against specialization outputs
- enforce blocking/advisory gate modes from `config/gates.json`

This module is self-contained and does not depend on external runtime code.

## Directory Ownership

Treat `bench/` as several surfaces, not one body of authored benchmark code:

- Authored benchmark code: `cli.py`, `lib/`, `runners/`, `executors/`,
  `gates/`, `tools/`, `native_compare_modules/`, and focused tests.
- Workload inputs and policy: `workloads/`, `native-compare/`, and relevant
  `config/` files at repo root.
- Kernel inputs: `kernels/` for backend/runtime compare lanes and
  `inference-pipeline/kernels/` for model inference lanes. A small mirrored
  compatibility set is documented in `kernels/README.md`.
- Fixtures: `fixtures/` contains small canonical inputs and pinned evidence
  snapshots. Exact duplicate fixture bytes are not enough reason to delete a
  path when the path has semantic meaning in a manifest.
- Generated material: `plans/generated/`, `ir/`, and most timestamped
  `out/` trees should be regenerated or materialized deliberately instead of
  treated as authored code.
- Durable evidence: curated receipts may stay checked in when they back a
  promoted claim, release, or reproducibility contract.
- Scratch output: local A/B runs, bulky workspaces, harvested corpora, and
  transient reports belong in ignored `bench/out/` locations unless promoted.

Cleanup rule: move generated or scratch material out of tracking only when the
generator, source inputs, or durable evidence reference remains clear. During an
active A/B pass, do not prune the receipts needed to compare the current runs.

## Quick Start

`bench/cli.py` is the only canonical benchmark front door. Use:

- `run` to execute one product and emit immutable run receipts
- `run-config` to expand one side of a compare config into standalone run receipts
- `compare` to join existing run receipts
- `claim` to evaluate claim policy over an existing compare report
- `list` to inspect executors, products, surfaces, or workload catalogs

Python-only benchmark and gate commands do not require checked-in JavaScript
dependencies. Browser ORT and package-lane commands that load
`onnxruntime-web` must restore the bench dependency tree from the lockfile:

```sh
npm --prefix bench ci
```

```sh
python3 bench/cli.py run \
  --product doe \
  --executor-id doe_direct_metal \
  --workloads bench/workloads/workloads.apple.metal.smoke.json

python3 bench/cli.py compare \
  bench/out/runs/<ts>/run-artifacts/doe/<artifact>.run.json \
  bench/out/runs/<ts>/run-artifacts/dawn/<artifact>.run.json

python3 bench/cli.py run-config \
  --config bench/native-compare/compare.config.apple.metal.compare.json \
  --side baseline

python3 bench/cli.py run-config \
  --config bench/native-compare/compare.config.apple.metal.compare.json \
  --side comparison

python3 bench/cli.py claim \
  bench/out/sample.compare.json \
  --mode local \
  --benchmark-policy config/benchmark-methodology-thresholds.json

python3 bench/cli.py compare --list-promoted
python3 bench/cli.py compare --surface backend --backend apple-metal --preset compare --dry-run
python3 bench/cli.py compare --surface plan --backend apple-metal --workload gemma270m-literal --dry-run
python3 bench/cli.py compare --surface package --backend apple-metal --workload gemma64 --runtime-host node --temperature warm --dry-run
python3 bench/runners/publish_apple_runtime_release.py --timestamp <YYYYMMDDTHHMMSSZ>
python3 bench/runners/exercise_runtime_numeric_stability.py
python3 bench/runners/exercise_in_path_numeric_stability.py
```

Generated workload manifests now carry explicit ownership plus advisory
freshness metadata in the run receipt. Freshness no longer rejects `run` or
`compare`; standalone manifests are never checked against the backend catalog.

Apple Metal native compare defaults are fair-cold: `doe_direct_metal` and
`dawn_delegate_metal` pass `--no-pipeline-cache`. Cache-enabled diagnostics must
use explicit cache opt-in executor ids. See `bench/docs/metal-pipeline-cache-policy.md`.
Package and browser ORT WebGPU lane scope is audited in
`bench/docs/package-browser-ort-fairness-audit.md`.

## First benchmark matrix

If you are starting from zero, use this matrix instead of inferring coverage
from scattered configs:

| Goal | Current status | Canonical entrypoint |
|---|---|---|
| Apple Metal native Doe vs Dawn | promoted | `python3 bench/cli.py compare --surface backend --backend apple-metal --preset compare --dry-run` |
| AMD Vulkan native Doe vs Dawn | promoted | `python3 bench/cli.py compare --surface backend --backend amd-vulkan --preset compare --dry-run` |
| Local D3D12 native Doe vs Dawn | promoted contract, Windows host required | `python3 bench/cli.py compare --surface backend --backend local-d3d12 --preset compare --dry-run` |
| Apple Metal plan Doe vs Dawn direct WebGPU | promoted | `python3 bench/cli.py compare --surface plan --backend apple-metal --workload gemma64 --dry-run` |
| Apple Metal package Doe-backed vs Dawn-backed `node-webgpu` | promoted | `python3 bench/cli.py compare --surface package --backend apple-metal --workload gemma64 --runtime-host node --temperature warm --dry-run` |
| Apple Metal package Doe-backed vs Dawn-backed `bun-webgpu` | promoted | `python3 bench/cli.py compare --surface package --backend apple-metal --workload gemma64 --runtime-host bun --temperature warm --dry-run` |
| AMD Vulkan package Doe-backed WebGPU vs Dawn-backed WebGPU on Node/Bun | promoted for Gemma64/Gemma1B cold/warm; older Gemma270m configs remain explicit repo-only artifacts | `python3 bench/cli.py compare --surface package --backend amd-vulkan --workload gemma64 --runtime-host node --temperature warm --dry-run` |
| Node ORT WebGPU Doe-backed vs Dawn-backed `node-webgpu` package | repo-only strict comparable local claim surface | `python3 bench/cli.py run-config --config bench/native-compare/compare.config.node.ort-webgpu-provider.gemma270m.json --side baseline`, then `--side comparison`, then compare the emitted receipts with `--comparability strict --require-timing-class process-wall`, then run `bench/cli.py claim --config ... bench/out/compare-report.json` |
| Bun ORT WebGPU Doe-backed vs Dawn-backed `bun-webgpu` package | repo-only strict comparable local claim surface | `python3 bench/cli.py run-config --config bench/native-compare/compare.config.bun.ort-webgpu-provider.gemma270m.prefill32.decode1.json --side baseline`, then `--side comparison`, then compare the emitted receipts with `--comparability strict --require-timing-class process-wall`, then run `bench/cli.py claim --config ... bench/out/bun-ort-webgpu-provider-compare/gemma270m-prefill32-decode1.compare.json` |
| Bun ORT WebGPU Doe-backed vs Dawn-backed `bun-webgpu` package breadth matrix | repo-only strict comparable exploration surface | `python3 bench/cli.py run-config --config bench/native-compare/compare.config.bun.ort-webgpu-provider.breadth.json --side baseline`, then `--side comparison`, then compare the emitted receipts with `--comparability strict --require-timing-class process-wall` |
| Node ORT WebGPU Doe-backed vs Dawn-backed `node-webgpu` package breadth matrix | repo-only strict comparable exploration surface | `python3 bench/cli.py run-config --config bench/native-compare/compare.config.node.ort-webgpu-provider.breadth.json --side baseline`, then `--side comparison`, then compare the emitted receipts with `--comparability strict --require-timing-class process-wall` |
| Browser ORT WebGPU Doe vs Dawn | repo-only strict comparable browser surface | `python3 bench/cli.py run-config --config bench/native-compare/compare.config.browser.ort-webgpu.json --side baseline`, then `--side comparison`, then compare the emitted receipts with `--comparability strict --require-timing-class process-wall` |
| Doe WGSL compiler vs Tint | repo-only claim-boundary contract | `python3 bench/native-compare/compare_doe_vs_tint_compilation.py --config bench/native-compare/compare_doe_vs_tint.config.json --evidence-out bench/out/tint-compiler-evidence.json`, then `python3 bench/gates/tint_compiler_evidence_gate.py --report bench/out/tint-compiler-evidence.json`; add `--require-claimable` only when the report is intended to support a compiler claim |
| AMD Vulkan browser superset (Chromium Playwright layered) | repo-only diagnostic; `--mode auto` is selector evidence only | `python3 browser/chromium/scripts/generate-browser-projection-manifest.py --workloads bench/workloads/specialized/workloads.amd.vulkan.superset.json` then `python3 browser/chromium/scripts/run-browser-benchmark-superset.py` on a Linux/AMD host with vulkaninfo reachable |
| Apple Metal browser superset (Chromium Playwright layered) | repo-only diagnostic, cross-backend parity with Vulkan (50 IDs) | `python3 browser/chromium/scripts/generate-browser-projection-manifest.py --workloads bench/workloads/specialized/workloads.apple.metal.superset.json --out browser/chromium/bench/generated/browser_projection_manifest.apple.metal.json` then `python3 browser/chromium/scripts/run-browser-benchmark-superset.py --workloads bench/workloads/specialized/workloads.apple.metal.superset.json --manifest-out browser/chromium/bench/generated/browser_projection_manifest.apple.metal.json` on a macOS host |
| Native ORT Doe EP narrow basic-ops slice | repo-only single-runtime bench surface | `python3 bench/single-runtime/run_bench.py --workloads bench/workloads/workloads.native.ort-doe-ep-smoke.json --workload-id inference_ort_doe_ep_matmul_add_relu_float32_rank2_exactshape --executor-id ort_native_doe_ep --iterations 3 --warmup 1 --out-dir bench/out/native-ort-doe-ep/matmul_add_relu --out-report bench/out/native-ort-doe-ep/matmul_add_relu.report.json --out-metadata bench/out/native-ort-doe-ep/matmul_add_relu.metadata.json --no-timestamp-output` |
| Native ORT incumbent WebGPU vs Doe EP basic-ops compare | repo-only strict comparable local claim surface | `python3 bench/cli.py run-config --config bench/native-compare/compare.config.native.ort-webgpu-provider.basic-ops.json --side baseline`, then `--side comparison`, then compare the emitted receipts with `--comparability strict --require-timing-class process-wall`, then run `bench/cli.py claim --config ... bench/out/native-ort-webgpu-provider/20260413T175708Z/basic-ops.compare.json` |
| Node ORT WebGPU vs Doppler on Doe provider | repo-only directional, not claimable | `python3 bench/cli.py run-config --config bench/native-compare/compare.config.node.ort-vs-doppler.gemma270m.json --side baseline`, then `--side comparison`, then compare the emitted receipts |
| Local D3D12 package Doe-backed WebGPU vs Dawn-backed WebGPU on Node/Bun | promoted contract, Windows host required for evidence | `python3 bench/cli.py compare --surface package --backend local-d3d12 --workload gemma64 --runtime-host node --temperature warm --dry-run` |

Two rules for first-time operators:

- Start with `python3 bench/cli.py compare --list-promoted` when you want the
  currently promoted matrix.
- Add `--dry-run` to a promoted compare selection when you want the exact
  explicit per-side `run-config` commands.
- Do not infer that every taxonomy tuple is runnable or promoted. The backend
  matrix is broader than the current plan/package matrix.

Browser runtime identity artifacts can be checked without launching Chromium:

```sh
python3 browser/chromium/scripts/check-browser-runtime-identity.py \
  --identity examples/browser-runtime-identity.sample.json
```

The same checker is available through `run_blocking_gates.py` with
`--with-browser-runtime-identity-gate`.

Browser pipeline cache receipts can also be checked against their source
local-AI workload artifact:

```sh
python3 browser/chromium/scripts/check-browser-pipeline-cache-receipts.py \
  --receipts examples/browser-pipeline-cache-receipts.sample.json \
  --verify-workloads-root . \
  --runtime-identity-root .
```

Derived browser artifacts with `runtimeIdentity.runtimeIdentityPath` accept the
same `--runtime-identity-root` check. The reference may be a
`browser_runtime_identity` artifact or the source browser smoke report, and the
checker rejects selected-runtime or fallback-state drift.

## ONNX Runtime plugin EP lane

Doe now has a repo-only ONNX Runtime plugin EP scaffold under
`runtime/bridge/onnxruntime-ep/`.

What that means today:

- the shared library exports the official plugin-EP factory entrypoints
- the repo now has a repo-only smoke runner for load/factory/unsupported-path
  validation:
  `zig build ort-plugin-ep-smoke-run -- --plugin-path <plugin> --ort-lib-path <ort-shared-lib>`
- the repo now also has a repo-only session smoke runner:
  `zig build ort-plugin-ep-session-smoke-run -- --plugin-path <plugin> --ort-lib-path <ort-shared-lib> --case identity|add|relu|matmul|matmul_add|matmul_add_relu|add_relu|all`
- the plugin now creates real `OrtEpDevice` instances and a narrow native
  `OrtEp` execution slice for `Identity`, `Add`, `Relu`, rank-2 `MatMul`, and
  exact `MatMul -> Add` / `MatMul -> Add -> Relu` / `Add -> Relu` fused
  groups; see
  `runtime/bridge/onnxruntime-ep/artifacts/20260413T172955Z/doe-ort-ep-session-smoke.json`
  for the current proof that Doe claimed, compiled, and executed that slice
- the repo now also has a repo-only single-runtime `bench/` surface for the
  current `Identity`, `Add`, `Relu`, rank-2 `MatMul`, and exact
  `MatMul -> Add` / `MatMul -> Add -> Relu` / `Add -> Relu` slice:
  - workload contract:
    `bench/workloads/workloads.native.ort-doe-ep-smoke.json`
  - executor id:
    `ort_native_doe_ep`
  - current local reports:
    - `bench/out/native-ort-doe-ep/identity.report.json`
    - `bench/out/native-ort-doe-ep/add.report.json`
    - `bench/out/native-ort-doe-ep/relu.report.json`
    - `bench/out/native-ort-doe-ep/matmul.report.json`
    - `bench/out/native-ort-doe-ep/matmul_add.report.json`
    - `bench/out/native-ort-doe-ep/matmul_add_relu.report.json`
    - `bench/out/native-ort-doe-ep/add_relu.report.json`
- the repo now also has a repo-only strict native compare and local-claim
  surface for the current shared `Add`, `Relu`, rank-2 `MatMul`, exact
  `MatMul -> Add`, exact `MatMul -> Add -> Relu`, and exact `Add -> Relu`
  slice:
  - workload contract:
    `bench/workloads/workloads.native.ort-webgpu-provider-compare.basic-ops.json`
  - compare config:
    `bench/native-compare/compare.config.native.ort-webgpu-provider.basic-ops.json`
  - executors:
    `ort_native_doe_ep`
    `ort_native_webgpu_incumbent`
  - current strict compare artifact:
    `bench/out/native-ort-webgpu-provider/20260413T175708Z/basic-ops.compare.json`
  - current local claim artifact:
    `bench/out/native-ort-webgpu-provider/20260413T175708Z/basic-ops.claim.json`

What it does not mean yet:

- there is now a repo-only same-stack Node ORT WebGPU provider-compare lane at
  `bench/native-compare/compare.config.node.ort-webgpu-provider.gemma270m.json`;
  the fresh strict compare and local claim artifacts for the current AMD RADV
  host live at:
  - `bench/out/node-ort-webgpu-provider-compare/20260413T191817Z/gemma270m.compare.json`
  - `bench/out/node-ort-webgpu-provider-compare/20260413T191817Z/gemma270m.claim.json`
  - the current Node provider-compare scenarios now use the same local
    Transformers cache root as the Bun lanes so the package/provider compare
    contract no longer mixes model-id resolution on Node with local-model
    resolution on Bun
- there is now also a repo-only same-stack browser ORT WebGPU Playwright lane
  at `browser/chromium/scripts/webgpu-playwright-ort-bench.mjs`; the current
  strict comparable `bench/` surface lives at
  `bench/native-compare/compare.config.browser.ort-webgpu.json`
  and the current canonical compare artifact on this Linux host lives at:
  - `bench/out/browser-ort-webgpu-compare/20260413T193605Z/browser.compare.json`
  - the browser harness now supports both the short `sentiment` task and the
    longer `sentiment_longform` task on the same vendored DistilBERT ORT model
  - the canonical browser compare surface is strict/comparable but still not a
    local-claim lane
- there is also a broader repo-only package matrix at
  `bench/native-compare/compare.config.node.ort-webgpu-provider.breadth.json`;
  the current breadth artifacts live at:
  - `bench/out/node-ort-webgpu-provider-breadth/20260413T192150Z/breadth.compare.json`
  - `bench/out/node-ort-webgpu-provider-breadth/20260413T192150Z/breadth.workspace/`
  - the current five-shape breadth matrix now has a positive overall mean on
    this AMD RADV host, but it is still mixed workload-by-workload, so it does
    not support a blanket Doe-over-Dawn ORT package claim on this host
- there is now also a repo-only same-stack Bun ORT WebGPU provider-compare
  lane at
  `bench/native-compare/compare.config.bun.ort-webgpu-provider.gemma270m.prefill32.decode1.json`;
  the fresh Bun compare and claim artifacts live at:
  - `bench/out/bun-ort-webgpu-provider-compare/gemma270m-prefill32-decode1.compare.json`
  - `bench/out/bun-ort-webgpu-provider-compare/gemma270m-prefill32-decode1.claim.json`
  - the current local Bun claim artifact records a claimable Doe advantage for
    this exact Bun host / Gemma-3 270M / `prefill 32` + `decode 1` contract
  - the broader two-shape Bun exploration matrix now also lives at
    `bench/native-compare/compare.config.bun.ort-webgpu-provider.breadth.json`
    with the fresh compare artifact at
    `bench/out/bun-ort-webgpu-provider-breadth/20260413T181619Z/breadth.compare.json`
  - that broader Bun matrix is mixed, so it does not support a blanket
    Doe-over-Dawn ORT package claim on this host
- there is now a repo-only Node directional lane at
  `bench/native-compare/compare.config.node.ort-vs-doppler.gemma270m.json`
  comparing Transformers.js plus `onnxruntime-node` WebGPU against Doppler on
  the same Doe provider; it is process-wall only and non-claimable because the
  model/runtime stacks differ
- fresh local reruns on this host now succeed on both sides; see
  `bench/out/node-ort-vs-doppler/20260413T001826Z/gemma270m.workspace/run-artifacts/doppler_node_doe/doppler_node_doe-node_ort_vs_doppler_gemma3_270m_prefill_64tok_decode_64tok-20260413T001826Z.run.json`
  for the current Doppler-side receipt and `bench/out/compare-report.json` for
  the current strict compare report, which still marks the lane non-comparable
  because it is directional/process-wall only
- there is no Bun ORT-vs-Doppler lane today; Doppler exposes a Node command
  runner (`src/tooling/node-command-runner.js`), but no parallel Bun tooling
  surface that Doe can benchmark honestly here
- there is no claimable native `ORT + Dawn` vs `ORT + Doe` graph-execution
  compare surface today
- a broader Doe-backed graph execution bridge beyond the current narrow
  basic-ops proof slice still has to land before that benchmark lane exists
- the browser ORT Playwright harness now exists, but it is still a browser-local
  repo script rather than a `bench/cli.py` executor or claim-gated matrix cell

## Numeric-stability promotion and runtime exercise

Numeric-stability work now has three explicit repo runners:

- `bench/runners/promote_numeric_fragility_signatures.py`
  - lifts the latest corpus export into checked-in promoted signatures and the
    promoted fragility catalog
- `bench/runners/exercise_runtime_numeric_stability.py`
  - replays selected promoted prompt/control cases through the live Zig
    `doe_numeric_stability` service
  - writes runtime receipts plus bounded overhead summaries under
    `bench/out/apple-metal-runtime-numeric-stability/*`
  - updates selected signatures and the promoted catalog from `promoted` to
    `runtime-exercised`
- `bench/runners/exercise_in_path_numeric_stability.py`
  - replays selected promoted prompt/control cases through ordinary
    `doe-zig-runtime` `kernel_dispatch` execution using the runtime
    auto-detect profiles for supported operator families
  - writes native trace artifacts, ordinary-execution receipts, and manifest
    summaries under `bench/out/apple-metal-in-path-numeric-stability/*`
  - is the current source of truth for native `runtime-exercised`
    `matmul.logits` signatures in the promoted catalog

The exercise surface is config-backed by:

- `config/runtime-numeric-stability-exercise.json`
- `config/runtime-numeric-stability-exercise.schema.json`
- `config/in-path-numeric-stability-exercise.json`
- `config/in-path-numeric-stability-exercise.schema.json`

## Proof-backed shader metric front door

Proof-backed shader metric evidence has a named front door under `bench/out/`;
it does not live in a scratch-only path.

- stable mirror:
  - `bench/out/proof-metrics/latest/proof_metrics_summary.json` — structured
    before/after deltas per shader (size, `min(...)` count, `_doe_sizes` /
    `needs_sizes_buf`, dispatch preconditions, compile `p50`, native Vulkan
    `p50/dispatch`, GPU timestamp)
  - `bench/out/proof-metrics/latest/proof_metrics_summary.md` — human summary
    of the same deltas
  - both files are tracked (allowlisted in `.gitignore`) so external writeups
    can link the stable path
- structural reporter entrypoint:
  - `zig build runtime-compile-report` builds `doe-runtime-compile-report`
  - `runtime/zig/src/doe_wgsl/runtime_compile_report.zig` is the single-shader
    structural emitter; one invocation per shader emits MSL size, `min(...)`
    count, `_doe_sizes` presence, `needs_sizes_buf`, dispatch preconditions,
    workgroup size, and parse/sema/lower/emit/total phase timings for the
    current build flavor
- build flavors:
  - `-Dlean-verified=false` reports the baseline structural shape
  - `-Dlean-verified=true` reports the proof-backed structural shape with the
    corresponding `lean_proof.lean_verified` comptime branch elimination
  - both flavors must be run to produce a delta pair per shader
- refresh pattern:
  - the structural half of the summary is reproducible cross-platform with the
    reporter binary alone; build under each flavor, run the reporter on each
    target shader, and collate the pair into the mirror shape
  - the timing half (`compileP50Ns`, `nativeVulkanP50PerDispatchNs`,
    `gpuTimestampNs`) requires Vulkan host execution plus warmup/percentile
    discipline; it is not structural, and the current mirror values are the
    current evidence until a refresh on Vulkan hardware produces a newer pass
- shader scope:
  - the current pass covers `affine_loop_storage`, `tiled_storage`, and
    `flat_2d_storage`; broadening the shader set requires extending the
    reporter invocation list and the mirror schema in lockstep

## TSIR parity tooling

TSIR (Tiled Spatial IR) parity infrastructure lives alongside the benchmark
tooling in this directory but is a separate verification surface from the
Doe-vs-Dawn comparisons above.

- `bench/tools/doe_parity.py` — manual parity CLI; three-way compare scaffold
  (reference interpreter, WebGPU emission, CSL simfabric) with fail-closed
  exactness classes matching the RDRR taxonomy.
- `bench/tools/tsir_manifest_lowering.py` — schema-backed builder for
  `integrityExtensions.lowerings[]` manifest entries.
- `bench/tools/generate_tsir_manifest_fixtures.py` — bootstrap manifest
  fixture generator; invokes the Zig `doe-tsir-bootstrap-manifest-inputs` tool.
- `bench/fixtures/tsir-manifest-entries/` — six pinned manifest fixtures
  (three bootstrap kernels × two target descriptors).
- `bench/gates/nightly_tsir_parity_canary.py` — advisory nightly canary that
  runs the six bootstrap fixtures through the parity CLI and emits a report.
- `bench/tests/test_{doe_parity,tsir_bootstrap_catalog,tsir_manifest_lowering,nightly_tsir_parity_canary,doc_link_coverage}.py` — invariant tests.

For architecture see
[`../docs/tsir-lowering-plan.md`](../docs/tsir-lowering-plan.md); for live
status see [`../docs/status/tsir.md`](../docs/status/tsir.md); for iteration
discipline see [`../docs/loop-protocol.md`](../docs/loop-protocol.md).

## Terminology

Use the benchmark taxonomy from `docs/benchmark-taxonomy.md`:

- `workload`
  - one benchmark definition, such as `render_draw_throughput_200k` or
    `inference_gemma3_270m_prefill_32tok`
- `surface`
  - the execution boundary being tested:
    - `backend`
    - `plan`
    - `package`
- `executor`
  - the concrete runner for one product on one surface
- `run artifact`
  - legacy name for the per-product receipt artifact
- `run receipt`
  - the output of running one product on one workload
  - includes the runner binary identity and, for native delegate lanes such as
    Dawn, the delegated WebGPU library identity when it is discoverable from
    the launch environment
- `compare report`
  - the output of joining isolated run receipts for the same workload and
    surface
- `claim report`
  - the output of evaluating claim policy over a compare report

Useful benchmark-specific clarifications:

- `backend` surface
  - Doe or Dawn implements WebGPU semantics on Metal, Vulkan, or D3D12
- `plan` surface
  - both products execute the same normalized `planPath`
- `package` surface
  - public Node/Bun/Deno-facing providers execute the same normalized plan
- `Runtime workload`
  - a runtime workload usually includes API/setup work, first-use shader
    compilation or pipeline creation, and GPU execution together
  - compilation-only workloads are separate `runnerType: "compilation"`
    workloads
- `Host-overhead breakdown`
  - compare reports expose `timingInterpretation.hostOverheadBreakdown` for
    once-per-sample work outside the selected execution timing

Two practical rules:

- the benchmark primitive is always the isolated run receipt
- compare is post-hoc analysis, never the execution primitive
- claim is a separate post-hoc policy pass over a compare report

## Performance Strategy (Read First)

Before running or interpreting Dawn-vs-Doe performance results, read:

- `docs/performance-strategy.md`
- `docs/benchmark-taxonomy.md`
- `bench/docs/benchmark-writing-guide.md`

If you're adding or changing workloads/commands, treat the benchmark writing guide as the required authoring contract.

That document defines:

- claimability order and comparability invariants
- delta sign convention (`+` faster, `-` slower from the compare report's baseline role)
- optimization priorities and anti-patterns

## Workload layout

- Canonical backend workload files live directly under `bench/workloads/`:
  - `workloads.apple.metal.json`
  - `workloads.apple.metal.smoke.json`
  - `workloads.amd.vulkan.json`
  - `workloads.amd.vulkan.smoke.json`
  - `workloads.local.d3d12.json`
  - `workloads.local.d3d12.smoke.json`
- The source of truth is `bench/workloads/metadata/backend-workload-catalog.json`.
- Generic and special-purpose projections live under `bench/workloads/specialized/`.
  Use those only when a tool or document explicitly calls for them.
- Compilation workloads now live in the same workload contracts as runtime workloads.
  The Doe-vs-Tint compiler harness resolves `runnerType: "compilation"` workloads
  from the workload file instead of scanning an unrelated shader directory, so
  named compilation workloads can point at the real inference-pipeline WGSLs.
- Compilation workloads now publish both:
  - raw Tint process-wall timings
  - a startup-corrected derived view that subtracts the Tint trivial-shader
    baseline `p50` from each raw Tint sample
- Compilation workloads may also publish a real warm/in-process Tint view from
  Dawn's `tint_benchmark` target when the compare config provides
  `comparison.warmBinaryPath`.
- For Doe-owned workload rows, first materialize the WGSL corpus into the local
  Dawn Tint benchmark input set and rebuild the benchmark harness:
  `python3 bench/tools/materialize_tint_warm_corpus.py --workloads bench/workloads/workloads.apple.metal.json --dawn-source-dir bench/vendor/dawn --build-dir bench/vendor/dawn/out/Release --target msl --build --ninja-bin ninja --output-state bench/fixtures/dawn_tint_warm_corpus_state.json`
- Raw Tint timings remain the auditable source metric; the corrected view is a
  presentation aid so process startup does not get mistaken for compile work.
  The warm view is separate again: it is a true in-process Tint measurement,
  not a correction derived from the raw CLI samples.
- The benchmark-corpus config for that warm compiler surface is:
  `bench/native-compare/compare_doe_vs_tint.benchmark-corpus.config.json`
- Apple Metal also carries Doe-owned Gemma-3-270M-shaped backend runtime workloads:
  `inference_gemma3_270m_prefill_32tok` and
  `inference_gemma3_270m_decode_1tok`. These are plain Doe command streams,
  not imported manifest schemas: they seed uniform/token buffers with explicit
  `buffer_write` commands, load deterministic non-zero synthetic readonly
  tensors with explicit `buffer_load` commands, and dispatch the retained
  inference WGSL kernels in the same compute shape as the real
  prefill/decode path.
- Neutral authored benchmark IR now lives under `bench/ir/`.
  - `bench/ir/gemma3_270m.json` is the current Gemma-shaped source of truth.
  - `bench/ir/gemma3_270m_literal.json` is the current Doe-owned
    literal-production-style 270M workload: it stays synthetic, but it tracks the
    production-style kernel family, entry points, gated FFN, and tied LM head
    more closely than the shaped workload.
  - Large synthetic readonly tensors for these workloads are cache-backed, not
    checked in:
    - canonical cache root:
      `DOE_BENCH_ASSET_CACHE_DIR` or `~/.cache/doe/bench_synthetic_assets`
    - explicit plan commands use `buffer_load`, not implicit first-use zeroed
      buffer creation
    - asset generation and cache warming happen outside timed samples
    - file read plus device upload stay inside the timed plan command, so the
      inference workloads are device-load-inclusive rather than already-resident
      hot-path runs
  - Warm assets ahead of time with:
    `python3 bench/tools/materialize_plan_assets.py --plan <generated.plan.json>`
  - Generated normalized plans live under `bench/plans/generated/`.
  - Compatibility command artifacts remain emitted for Doe runtime execution,
    but they are generated artifacts, not the authored benchmark layer.
  - For comparable IR-backed runtime workloads, `planPath` is the strict apples-to-
    apples execution boundary. `commandsPath` compatibility artifacts are
    non-claim debugging surfaces for those workloads.
- The old synthetic JS inference-pipeline benchmark surface was removed.
  For real model inference benchmarking, use Doe-owned runtime command streams
  and runtime example paths under `runtime/zig/examples/`, not a random-weight
  JS proxy.

## IR and executors

- `bench/ir/*.json`
  - neutral authored benchmark IR
- `bench/plans/generated/*.plan.json`
  - normalized executable plans derived from the IR
- `bench/executors/`
  - standalone executors that consume normalized plans
  - current plan-surface executor coverage:
    - Doe plan executor via `runtime/zig/zig-out/bin/doe-plan-executor`
      for plan-backed comparable workloads
    - standalone direct WebGPU plan executor via `runtime/zig/zig-out/bin/webgpu-plan-executor`
      for:
      - Dawn direct Metal (`dawn_direct_metal`)
      - WebKit direct Metal (`webkit_webgpu_native_metal`)
    - standalone Node package executor via `bench/executors/run-node-webgpu-plan.js`
      for:
      - `doe-gpu` (`doe_node_webgpu`)
      - `node-webgpu` package (`node_webgpu_package`)
    - standalone Bun package executor via `bench/executors/run-bun-webgpu-plan.js`
      for:
      - `doe-gpu` (`doe_bun_package`)
      - `bun-webgpu` package (`bun_webgpu_package`)

The compare front door can now resolve executor IDs instead of only raw command
templates. One Gemma-shaped end-to-end config is:

- `bench/native-compare/compare.config.apple.metal.gemma64.ir.json`

That workload compares:

- baseline executor: Doe plan Metal execution through the normalized plan
- comparison executor: standalone direct WebGPU plan execution on Metal

over the same normalized `prefill64 + decode64` Gemma-shaped workload.

Package-surface configs now exist alongside the plan-surface configs across the
three governed native lanes, and they all select from the shared package
inference manifest `bench/workloads/workloads.package.inference.json`.

Representative config paths are:

- `bench/native-compare/compare.config.apple.metal.gemma64.node-package.ir.json`
- `bench/native-compare/compare.config.amd.vulkan.gemma64.node-package.ir.json`
- `bench/native-compare/compare.config.local.d3d12.gemma64.node-package.ir.json`
- matching `gemma1b`, `bun-package`, and `.warm` variants on each lane

The promoted package catalog covers Gemma64 and Gemma1B Node/Bun cold/warm
package profiles on Apple Metal, AMD Vulkan, and local D3D12. Older AMD Vulkan
Gemma270m package compare configs remain explicit config-backed lanes outside
the promoted `--surface package` profile set:

- `bench/native-compare/compare.config.amd.vulkan.gemma270m.node-package.ir.json`
- `bench/native-compare/compare.config.amd.vulkan.gemma270m.bun-package.ir.json`

These compare public package providers over the same normalized plan:

- Node package workloads
  - baseline executor: `doe-gpu`
  - comparison executor: `node-webgpu`
- Bun package workloads
  - baseline executor: `doe-gpu`
  - comparison executor: `bun-webgpu`

They are apples-to-apples for the package surface, but they are not backend
surface implementation claims.

The package surface now has two explicit timing modes:

- cold package surface (`*.node-package.ir.json`, `*.bun-package.ir.json`)
  - keeps package setup inside `selectedTiming`
  - keeps `workloadUnitWall` on the compare harness subprocess wall
  - starts cold-package `traceMeta.processWallMs` before runtime bringup so
    direct trace-meta audits include the same cold setup boundary instead of a
    warm-only execution window
  - represents first-use package cost from a JS caller point of view
- prepared-session package surface (`*.node-package.warm.ir.json`, `*.bun-package.warm.ir.json`)
  - builds the package runtime and cached WebGPU objects before the timed sample
  - keeps `selectedTiming` on the repeated workload steps only
  - switches `workloadUnitWall` to trace-meta `processWallMs` via
    `workloadUnitWallSource=trace-meta-process-wall`
  - records that warm wall boundary before executor artifact emission so the
    wall metric stays on package execution rather than trace file writes
  - represents steady-state package execution without silently redefining the
    cold metric

Package trace meta now emits explicit host and setup buckets for this surface,
including input read/parse, workload prepare, executor init, command
orchestration, artifact finalize, and package setup breakdowns such as shader
module creation and bind-group/pipeline creation.

Config-backed receipt resolvers now sit above those raw configs. The catalog lives in:

- `config/promoted-compare-catalog.json`

That catalog is front-door wiring only. The single taxonomy source of truth is:

- `config/compare-taxonomy.json`

And the front door is:

- `python3 bench/cli.py compare --list-promoted`
- `python3 bench/cli.py compare --surface backend --backend amd-vulkan --preset compare --dry-run`
- `python3 bench/cli.py compare --surface backend --backend apple-metal --preset release --dry-run`
- `python3 bench/cli.py compare --surface backend --backend local-d3d12 --preset smoke --dry-run`
- `python3 bench/cli.py compare --surface plan --backend apple-metal --workload gemma64 --dry-run`
- `python3 bench/cli.py compare --surface plan --backend apple-metal --workload gemma1b --dry-run`
- `python3 bench/cli.py compare --surface plan --backend apple-metal --workload gemma270m-literal --dry-run`
- `python3 bench/cli.py compare --surface package --backend apple-metal --workload gemma64 --runtime-host node --temperature cold --dry-run`
- `python3 bench/cli.py compare --surface package --backend apple-metal --workload gemma64 --runtime-host node --temperature warm --dry-run`
- `python3 bench/cli.py compare --surface package --backend apple-metal --workload gemma64 --runtime-host bun --temperature cold --dry-run`
- `python3 bench/cli.py compare --surface package --backend apple-metal --workload gemma64 --runtime-host bun --temperature warm --dry-run`
- `python3 bench/cli.py compare --surface package --backend amd-vulkan --workload gemma64 --runtime-host node --temperature warm --dry-run`
- `python3 bench/cli.py compare --surface package --backend amd-vulkan --workload gemma64 --runtime-host bun --temperature warm --dry-run`
- `python3 bench/cli.py compare --surface package --backend local-d3d12 --workload gemma64 --runtime-host node --temperature warm --dry-run`
- `python3 bench/cli.py compare --surface package --backend local-d3d12 --workload gemma64 --runtime-host bun --temperature warm --dry-run`
- `python3 bench/cli.py run-config --config bench/native-compare/compare.config.amd.vulkan.gemma270m.node-package.ir.json --side baseline`
- `python3 bench/cli.py run-config --config bench/native-compare/compare.config.amd.vulkan.gemma270m.bun-package.ir.json --side baseline`

The promoted matrix is explicit in config:

- `surface=backend`
  - backend command/delegate preset configs on Metal, Vulkan, and D3D12
- `surface=plan`
  - promoted on Apple Metal only (`gemma64`, `gemma1b`, `gemma270m-literal`)
- `surface=package`
  - promoted on Apple Metal, AMD Vulkan, and local D3D12 for
    `runtimeHost=node` or `runtimeHost=bun`, with `temperature=cold` or
    `temperature=warm`, on the Gemma64 and Gemma1B package workloads
  - AMD Vulkan Gemma270m package compares remain explicit config-backed lanes,
    not promoted surface profiles
  - local D3D12 package profiles are front-door contracts; claim evidence still
    requires a compatible Windows/D3D12 host

The canonical axis vocabulary underneath those front doors is defined in
`config/compare-taxonomy.json`. The generated expansion in
`config/generated/compare-taxonomy-expanded.jsonl` is a derived artifact, and
`config/promoted-compare-catalog.json` is front-door wiring. Do not treat those
as parallel taxonomy sources.

`bench/cli.py compare` is the config-backed and promoted-profile compare front
door. It resolves the selected compare contract and then executes the same
isolated-run plus compare-report flow used by the lower-level artifact tools.

If you pass `--catalog` to `bench/cli.py compare`, relative `configPath`
entries resolve against that catalog file. The default repo catalog still
resolves its entries against repo root.

## Scripts

- `run_bench.py`
  - executes a configured workload command template, captures runtime timing samples, and emits measured metrics
  - computes timing statistics from wall time and trace-window timings when trace artifacts are present
  - emits reproducible run metadata with workload/artifact hashes and toolchain fields
  - compares against incumbent baseline ids from `config/benchmarks.json`
  - enforces host/backend compatibility before execution and fails fast on unsupported OS/backend mixes (for example: Vulkan on macOS, Metal on Linux/Windows, D3D12 on Linux/macOS).
- `check_correctness.py`
  - runs deterministic contract-level correctness checks
- `schema_gate.py`
  - validates schema-backed benchmark/config contracts as blocking release checks (`claim-cycle`, `webgpu-capability-inventory`, command coverage ledgers, Chromium integration overlay, benchmark methodology thresholds, substantiation policy, comparability obligation contracts, and all quirk examples).
- `csl_fixture_mirror_gate.py`
  - validates CSL fixture mirror canonicity from `config/csl-fixture-mirrors.json`, including byte-identical mirrors, declared path-context differences, and runtime-only fixture coverage.
- `csl_operation_graph_gate.py`
  - validates registered CSL operation graphs from `config/csl-operation-graph.schema.json`, including `rpc_launch` and `streaming_memcpy_driven` memcpy patterns, exported-symbol or memcpy-color references, memcpy ROI bounds, SdkLayout stream references, and required `unblock_cmd_stream` checkpoints.
- `run_blocking_gates.py`
  - canonical entrypoint for blocking gate order: schema -> CSL fixture mirrors -> CSL operation graphs -> correctness -> trace -> optional drop-in -> optional claim gate.
  - release-claim readiness evidence requires claim gate enabled (`--with-claim-gate`), and can be enforced with `--require-claim-gate`.
  - can run comparability verification parity fixtures with `--with-comparability-parity-gate`.
  - can run standalone browser/WGSL/native artifact checks with opt-in `--with-*-gate` flags for browser milestone/smoke/flight-replay/policy/probe/promotion/release artifacts, capture-policy-bound media probes, Chromium patch manifests, Chromium source-checkout readiness, WGSL corpus/diagnostic/robustness/lowering evidence, and native upload/cache/reuse/command-graph/no-fallback/coverage receipts.
  - shader-artifact gating now treats SPIR-V validation as routine for SPIR-V-bearing manifests; `spirv-val` is auto-discovered from PATH when available.
- `comparability_obligation_parity_gate.py`
  - validates comparability obligation parity fixtures against Python evaluation and Lean obligation ID set alignment.
  - verifies fixture expectations (`expectedBlockingFailedObligations`, `expectedComparable`) from `bench/fixtures/comparability_obligation_fixtures.json`.
- `run_release_pipeline.py`
  - canonical entrypoint for CI/local release orchestration: preflight -> compare report generation -> compare HTML visualization (default on) -> optional smoke verification -> blocking gates (optional drop-in + optional claim gate).
  - when claim gate is enabled, it also emits claim rehearsal artifacts by default:
    claim gate result, tail-health table, timing-invariant audit, and contract-hash manifest.
  - when claim gate is enabled, cycle-lock/rollback enforcement runs by default via `cycle_gate.py` (disable only for diagnostics with `--no-with-cycle-gate`).
- `run_release_claim_windows.py`
  - runs repeated release pipeline windows and emits a trend summary (`comparisonStatus`, `claimStatus`, non-claimable/non-comparable workload IDs per window); can run `substantiation_gate.py` over that summary in one command.
  - forwards compare HTML generation per window by default; use `--no-compare-html-output` to disable.
  - forwards claim rehearsal artifact generation per window by default; use `--no-with-claim-rehearsal-artifacts` to disable.
  - forwards cycle-lock/rollback gate execution per window by default; use `--no-with-cycle-gate` to disable.
  - can forward optional substantiation status into cycle-gate evaluation via `--cycle-substantiation-report`.
- `build_browser_claim_promotion_receipt.py`
  - turns schema-backed browser claim reports into promotion receipts with forced-Doe, claim-policy, and hidden-fallback checks.
- `build_browser_release_artifact_bundle.py`
  - hash-binds the browser binary, Doe runtime, shader compiler, browser claim reports, promotion receipts, contracts, and policies, including the Chromium patch manifest, browser artifact identity coverage manifest, and browser unsupported reason taxonomy, into the release artifact bundle contract.
- `check_browser_claim_promotion_receipt.py` / `check_browser_release_artifact_bundle.py`
  - validate browser promotion/release artifacts and can verify referenced file hashes with `--verify-files-root`; verified artifact paths must resolve under that root.
- `check_browser_artifact_identity_coverage.py`
  - validates the configured identity anchors for smoke, flight-recorder, derived probe, claim, promotion, and release artifacts.
- `check_browser_unsupported_reason_taxonomy.py`
  - validates browser unsupported/fallback reason-code governance used by developer-visible fallback explanations.
- `check_browser_claim_policy.py`
  - validates browser claim policy semantics for local and release modes, including required modes, strict/headless flags, no data-URL fallback, and release percentile coverage.
- `check_browser_ownership.py`
  - validates promoted browser ownership assignments for runtime integration, compatibility, methodology, and nursery-exit approval.
- `check_browser_responsibility_map.py`
  - validates browser CPU/GPU responsibility entries, repo-relative claim-candidate bindings, boundary references, and stale claim-binding paths.
- `check_chromium_fork_maintenance_policy.py` / `check_chromium_patch_manifest.py`
  - validate Chromium fork isolation policy and the required patch manifest, including allowed/forbidden roots, rollback references, active patch files, and evidence references.
- `check_webgpu_integration_chromium.py`
  - validates the Chromium integration overlay, required browser seam capabilities, external-texture blocked state, wire-protocol notes, and optional repo-relative smoke-artifact linkage.
- `check-browser-runtime-selector-policy.py`
  - validates browser runtime selector modes, fallback taxonomy, fail-closed Doe behavior, and required observability fields.
- `check-browser-promotion-approvals.py`
  - validates browser promotion approval roles, approval timestamps, and exact workflow-required approval coverage.
- `check-browser-workflow-manifest.py`
  - validates browser workflow rows, required/optional status, L2 claim scope, metric uniqueness, and L0 parity claim-language boundaries.
- `check-browser-benchmark-superset.py`
  - validates browser projection hash sync, repo-relative source/rules paths, report coverage, and promotion approvals.
- `build_test_inventory_dashboard.py`
  - scans Dawn-vs-Doe compare reports and emits:
    - canonical tested-profile inventory JSON (`vendor/api/deviceFamily/driver` coverage, matrix status history, report-level status rollups)
    - optional HTML dashboard for matrix status + performance delta vs Dawn when explicit HTML output paths are provided
  - only includes conformant compare reports (`artifactKind=compare-report`, `schemaVersion=1`, canonical comparability-obligation IDs, and valid `workloadManifest.path/sha256` hash match).
  - profile combos are sourced from per-sample `traceMeta.profile` fields; sides without profile metadata are tracked as report status only (not hardware-profile coverage).
  - always writes stable latest JSON at `bench/out/test-inventory.latest.json`; HTML latest output is optional and off by default.
  - excludes `bench/out/scratch/**` from canonical inventory aggregation.
- `build_baseline_dataset.py`
  - builds a canonical baseline trend package from historical comparison artifacts.
  - only includes conformant compare reports (`artifactKind=compare-report`, `schemaVersion=1`, canonical comparability-obligation IDs, and valid `workloadManifest.path/sha256` hash match).
  - emits timestamped JSON trend dataset + markdown summary plus stable latest outputs.
  - groups history by matrix/runtime pair and tracks latest/best/worst p50 delta snapshots.
- `build_benchmark_cube.py`
  - normalizes backend compare reports plus package-surface compare reports into a single benchmark cube contract.
  - emits timestamped JSON cube-entry artifacts plus JSON cube summary under `bench/out/cube/<timestamp>/`.
  - markdown matrix and HTML dashboard outputs are optional and off by default.
  - also writes stable latest JSON outputs under `bench/out/cube/latest/`.
  - `bench/out/cube/latest/` is the stable git-tracked JSON mirror; timestamped cube runs remain disposable evidence artifacts under `bench/out/cube/<timestamp>/`.
  - preserves latest-history by default: it seeds the build with report paths referenced by the current `bench/out/cube/latest/cube.summary.json`, so explicit subset reruns cannot silently downgrade the latest mirror.
  - latest-cell selection now prefers broader evidence before newer evidence:
    canonical source conformance first, then larger cube-entry count, then better status, then newer timestamp.
    This keeps focused or subset reruns from replacing full governed-surface historical evidence in `latest/`.
  - use `--no-preserve-latest` only for intentionally isolated ad-hoc cube snapshots.
  - cube publication is governed-subset-backed: every included cube entry must resolve to governed IDs from `config/governed-lanes.json`.
  - backend cube entries carry the two source runtime governed IDs from report telemetry; package cube entries require explicit top-level `laneId` in the compare report.
  - package-surface evidence now uses the same artifact-first flow as every other surface:
    run one product with a package executor, emit a run artifact, then compare artifacts post-hoc.
  - package execution on Node and Bun now flows only through:
    - `bench/executors/run-node-webgpu-plan.js`
    - `bench/executors/run-bun-webgpu-plan.js`
  - package surfaces can use explicit policy workload-id overrides (`config/benchmark-cube-policy.json`) so directional workloads stay isolated from comparable workload-set cells.
  - backend cube entries preserve both canonical and legacy report history:
    - canonical entries come from fully conformant Dawn-vs-Doe reports.
    - legacy entries are kept when old reports still parse but no longer match the active workload-contract hash or obligation contract; these entries are marked `sourceConformance=legacy_nonconformant` and degrade to diagnostic in cube cells.
  - Node/Bun package cube entries stay explicit about maturity and missing-cell status instead of silently fabricating parity; package reports without governed `laneId` are excluded from canonical cube publication.
  - package workloads now also normalize cross-surface aliases through `bench/workloads/metadata/workload-registry.json`, so package workload IDs like `buffer_upload_1kb` land in cube entries as canonical backend-aligned IDs such as `upload_write_buffer_1kb` while preserving `sourceWorkloadId`.
- `substantiation_gate.py`
  - validates claim substantiation evidence from one or more comparison reports and/or release-window summaries using `config/substantiation-policy.json` (minimum comparable+claimable report count and minimum unique baseline-side profile diversity).
  - `targetUniqueBaselineProfiles` can now be enforced as blocking via `releaseEvidence.enforceTargetUniqueBaselineProfiles` (default in repo policy: `true`).
- `dropin_symbol_gate.py`
  - validates candidate shared-library symbol completeness against `config/dropin_abi.symbols.txt`.
- `dropin_behavior_suite.py`
  - compiles and runs an artifact-linked black-box API behavior harness (instance/device creation, queue ops, error scopes, lifecycle release).
- `dropin_benchmark_suite.py`
  - compiles and runs artifact-linked micro + end-to-end benchmarks for drop-in runtime surfaces.
  - compilation contract is two translation units by default (`--source` harness + `--ops-source` operations), and the suite fails fast if only one distinct source is provided.
- `dropin_gate.py`
  - canonical drop-in compatibility entrypoint; runs symbol + behavior + benchmark suites, emits a consolidated report with per-step runtimes, and generates benchmark HTML with micro and end-to-end sections.
- `visualize_dropin_benchmark.py`
  - reads `dropin_benchmark_suite.py` JSON output and writes an HTML report that includes all benchmark workloads grouped by class (`micro`, `end_to_end`).
- `bench/diagnostics/node/bench-headless-webgpu-comparison.mjs`
  - runs the four-way Node package-surface comparison for compute-heavy matmul:
    Dawn direct, Dawn + Doe helpers, Simulatte direct, and Simulatte + Doe helpers.
  - uses the same generated WGSL, matrix data, and chunk plan across all four runners.
  - the direct Simulatte surface now imports the addon-native `@simulatte/webgpu/native-direct` surface, and both helper surfaces now bind the same standalone `@simulatte/webgpu-doe` helpers onto their respective raw devices. This keeps wrapper-model asymmetry out of the compare contract.
  - the helper surfaces now use the same one-encoder, one-compute-pass, one-copy, one-submit, one-map round shape as the direct surfaces; they no longer time `gpu.buffer.read(...)` as a second copy+submit path inside the measured round.
  - runs each GPU candidate in an isolated subprocess and prepares/tears it down sequentially so one candidate's buffers, pipelines, or provider state do not distort another candidate's measurement or stability.
  - prints per-runner phase means (`encode`, `submit+wait`, `readback`) so direct-vs-helper and Dawn-vs-Simulatte gaps can be attributed instead of treated as one opaque wall-time delta.
- `bench/diagnostics/node/bench-streaming-webgpu-comparison.mjs`
  - runs the four-way Node package-surface comparison for the streaming affine-transform workload.
  - uses the same addon-native `@simulatte/webgpu/native-direct` vs Dawn direct pairing and the same standalone `@simulatte/webgpu-doe` helper implementation on both helper surfaces.
  - the helper surfaces now use the same one-encoder, one-compute-pass, one-copy, one-submit, one-map round shape as the direct surfaces; they no longer time `gpu.buffer.read(...)` as a second copy+submit path inside the measured round.
  - runs each GPU candidate in an isolated subprocess and prepares/tears it down sequentially so the four-way compare stays apples-to-apples without concurrent package/device resource pressure or package-state carryover.
  - run one package-surface streaming compare process at a time on a host. Concurrent ad-hoc scenario runs are diagnostic-only because overlapping package/device processes can materially distort `submit+wait` and readback timings even when each compare keeps its own candidates sequential.
  - prints per-runner phase means (`encode`, `submit+wait`, `readback`, `validation`) plus timed-sample variance (`stddev`, `CV`, `range`) for submission-heavy diagnosis.
  - supports explicit attribution scenarios via `--scenario=`:
    - `default`: 64 dispatches, full-range 16 MiB readback
    - `single-dispatch-full-readback`: 1 dispatch, full-range 16 MiB readback
    - `many-dispatches-tiny-readback`: 64 dispatches, 1 KiB readback
    - `raw-per-pipeline-bindgroups`: 64 dispatches, full-range 16 MiB readback, one direct-path bind group per pipeline
  - use those scenarios to separate dispatch-count cost, readback-byte cost, and bind-group-shape cost without changing the provider pair under test.
- `bench/diagnostics/node/bench-doe-routines-vs-cpu.mjs`
  - compares the Doe one-shot compute helper against the CPU worker baseline for the streaming workload.
- `bench/cli.py compare`
  - executes shared workload files against two explicit command templates (default Doe backend runtime on the baseline side + configurable Dawn/competitor runtime).
  - outputs per-run trace artifacts (`--trace-jsonl` and `--trace-meta` when templates provide these placeholders) plus workload-level and overall quantile summaries.
  - when both sides emit Doe-native semantic operator manifests, the compare report now also includes per-workload `operatorDiff` summaries and a top-level `operatorDiffSummary` that point at the first structural divergence (or structural match) from `.operators.json` artifacts.
  - enforces host/backend compatibility before execution and fails fast on unsupported OS/backend mixes (for example: Vulkan on macOS, Metal on Linux/Windows, D3D12 on Linux/macOS).
  - current repo compare configs default to the command-stream Dawn delegate surface (`dawn_delegate`) for apples-to-apples strict workloads; `dawn_benchmark_adapter.py` remains available for gtest-filter diagnostics.
  - core logic is now split into dedicated helper modules under `bench/native_compare_modules/`:
    `timing_selection.py`, `comparability.py`, `claimability.py`, `reporting.py`.
  - see `bench/docs/operator-diff-demo-runbook.md` for the currently validated
    scratch-harness proof path covering structural match, semantic identity
    mismatch, and capture digest mismatch.
- `run_reduction_order_counterexample.py`
  - runs multiple explicit command-stream variants of the same micro workload
    through Doe and Dawn, then compares the captured output bytes per variant
    instead of only asking whether one fixed command stream is stable.
  - this is the first metal-level counterexample surface:
    same fixed dot product, same inputs, different declared accumulation
    policy, distinct stable output bytes.
  - current bundled fixture:
    - `bench/fixtures/determinism/apple-metal-reduction-order-dot-product.json`
  - example:
    - `python3 bench/runners/run_reduction_order_counterexample.py --fixture bench/fixtures/determinism/apple-metal-reduction-order-dot-product.json --runs 3`
  - use the generated report to answer:
    whether alternate accumulation modes change bytes on the same exact micro
    workload, whether each policy is stable across repeats, and whether Doe and
    Dawn stay aligned for each named policy.
- `run_reduction_order_logit_flip.py`
  - promotes the same idea to a tiny logits operator:
    the runner executes three explicit accumulation policies for the same
    2-row matmul, captures the 2-logit output plus sampled token, and reports
    whether the winning row and sampled token flip when only the accumulation
    contract changes.
  - this is the operator-level bridge from numeric drift to token selection:
    same hidden state, same nominal logits op, different declared accumulation
    policy, different top token.
  - current bundled fixture:
    - `bench/fixtures/determinism/apple-metal-reduction-order-logit-flip.json`
    - `bench/fixtures/determinism/apple-metal-rmsnorm-slice-logit-flip.json`
  - example:
    - `python3 bench/runners/run_reduction_order_logit_flip.py --fixture bench/fixtures/determinism/apple-metal-reduction-order-logit-flip.json --runs 3`
    - `python3 bench/runners/run_reduction_order_logit_flip.py --fixture bench/fixtures/determinism/apple-metal-rmsnorm-slice-logit-flip.json --runs 3`
  - use the generated report to answer:
    whether alternate accumulation modes change logits bytes, whether those
    changed logits flip scalar argmax and sampled token, whether each policy is
    stable across repeats, and whether Doe and Dawn stay aligned for each named
    policy.
  - the `rmsnorm` family fixture is the current real operator-family promotion:
    first divergence is `rmsnorm.output`, the downstream selected token flips,
    and the exact-reference path stays on the tree/fast side.
- `run_real_lm_head_slice_hunt.py`
  - promotes the same numeric-sensitivity search onto a real prompt state:
    the runner harvests a real browser/Doppler prefill embedding plus logits,
    resolves real output rows from the model artifact, evaluates multiple
    accumulation contracts over that exact LM-head slice, and promotes the best
    case into both:
    - a reduction-order logit-flip receipt
    - a selective stable-rerun receipt
  - this is the first real prompt/operator/rerun bridge:
    same natural prompt state, same real LM-head rows, different declared
    accumulation policy, different selected token, then an explicit route
    decision over the real operator family.
  - current bundled fixture:
    - `bench/fixtures/determinism/apple-metal-real-lm-head-slice-hunt.gemma270m.red-go-stop-answer.json`
  - example:
    - `python3 bench/runners/run_real_lm_head_slice_hunt.py --fixture bench/fixtures/determinism/apple-metal-real-lm-head-slice-hunt.gemma270m.red-go-stop-answer.json --runs 3 --top-candidates 4`
  - the current flagship report is the explicit-choice traffic-light prompt:
    the real bounded `{ go, stop }` slice stays on ` go` under the f32
    policies, flips to ` stop` under `f16accum`, and the selective rerun route
    correctly prefers the stable serial policy on both Doe and Dawn.
- `export_numeric_fragility_corpus.py`
  - normalizes the current Apple Metal prompt-flip, policy-boundary, and
    operator-control evidence into one JSONL corpus plus a companion manifest.
  - the exporter keeps a stable row shape and now adds the token-level metrics
    needed to compare numeric fragility against uncertainty:
    - bounded-answer renormalized probability
    - bounded-answer surprisal (`-log p`) for the exact/reference token and the
      `f16accum` token
    - bounded-answer entropy and margin
    - global top-candidate context, including outsider lead versus the bounded
      pair
    - global reference-token surprisal when the source report persisted full
      logits; otherwise the row records why it is unavailable
  - route fields are intentionally split:
    - `routeExpectation`: hunt-derived expectation only, with explicit status
      (`hypothetical-from-hunt` vs `realized-in-promotion`)
    - `routeDecision`: realized route from a promoted rerun or policy artifact
  - promoted prompt workloads now use the promoted hunt report as
    `sourceArtifactPath`; the earlier representative hunt artifact is preserved
    separately as `sourceSearchArtifactPath`
  - the prompt-flip workloads are deduped by full prompt text across
    `prompt-choice` and `answer-set` candidates, while the curated
    `top-prefix-only` workloads remain a separate benchmark subset.
  - example:
    - `python3 bench/runners/export_numeric_fragility_corpus.py`
  - current output root:
    - `bench/out/apple-metal-numeric-fragility-corpus/<timestamp>/`
  - use the manifest as the source of truth for the current corpus size and the
    current mix of:
    - `prompt-lm-head-flip`
    - `prompt-top-prefix-flip`
    - `policy-boundary`
    - `operator-control`
- `promote_numeric_fragility_signatures.py`
  - promotes the current numeric-fragility corpus into checked-in config for
    the contract side of numeric stability.
  - the promotion ladder is governed by:
    - `config/fragility-promotion-policy.json`
  - checked-in outputs are:
    - `config/promoted-fragility-catalog.json`
    - `config/fragility-signatures/promoted/*.json`
  - each signature is validated against:
    - `config/fragility-signature.schema.json`
  - example:
    - `python3 bench/runners/promote_numeric_fragility_signatures.py`
  - interpretation:
    - this freezes promoted bench evidence into a runtime-consumable config
      shape without claiming that the runtime already enforces it
    - native `matmul.logits` novelty is now exercised through the in-path
      runner; broader operator families and package/browser ordinary execution
      still remain future work
- `rank_decode_fragility_states.py`
  - ranks normalized decode-boundary rows for the next numeric-stability
    promotion step.
  - this runner is track-2 tooling:
    it does not invent a decode receipt, it scores the rows emitted by the
    live ordinary-execution decode-boundary surface and keeps promotion
    criteria explicit.
  - the current scoring contract is schema-backed in:
    - `config/numeric-stability-decode-fragility-plan.json`
  - current ranked signals:
    - post-temperature top-1 margin
    - `top-k` cutoff proximity
    - `top-p` cutoff proximity
    - sampled CDF proximity to the draw `u`
    - adjacent-step persistence
    - upstream fast/stable disagreement
    - early decode position
  - promotion remains strict:
    - actual selected-token change
    - meaningful token
    - within-policy stability
    - upstream disagreement
    - short suffix replay divergence
  - example:
    - `python3 bench/runners/rank_decode_fragility_states.py --input <sample-token-receipts.jsonl>`
  - current output root:
    - `bench/out/numeric-stability-decode-fragility/<timestamp>/`
- `search_sampled_decode_prompts.py`
  - runs a bench-side discovery loop for sampled decode fragility:
    it reuses the real-logit scout, pair-agnostic miner, and semantic mutation
    templates to search prompt space in rounds instead of relying on hand-picked
    decode prompts.
  - the default seed bank is no longer only operational/security phrasing:
    it now mixes those controls with bounded ambiguity prompts across
    philosophy, science, law, identity, and art.
  - structured-choice mutation now preserves natural three-way forms such as
    `X, Y, or both: ...` so those prompts can survive into later mutation
    rounds instead of being flattened into malformed binary rewrites.
  - this runner is discovery-only:
    it improves the seed prompt pool for later sampled ordinary-execution
    harvests, but it does not by itself claim a live decode-governance case.
  - config is explicit in:
    - `config/numeric-stability-decode-prompt-search-plan.json`
  - example:
    - `python3 bench/runners/search_sampled_decode_prompts.py`
  - current output root:
    - `bench/out/apple-metal-sampled-decode-prompt-search/<timestamp>/`
- `harvest_sampled_decode_fragility.py`
  - patches ordinary command streams into sampled decode mode, annotates
    `decode.final_logits` / `decode.sample_token` with step-stable semantic
    identities, and harvests real sampled decode receipts on Metal across
    repeated runs.
  - config is explicit in:
    - `config/numeric-stability-decode-harvest-plan.json`
  - current output root:
    - `bench/out/apple-metal-sampled-decode-fragility/<timestamp>/`
  - example:
    - `python3 bench/runners/harvest_sampled_decode_fragility.py`
- `enrich_sampled_decode_rows.py`
  - attaches within-policy stability and short suffix replay evidence to the
    harvested decode receipts, then writes normalized rows and the ranked
    decode-fragility report in one pass.
  - example:
    - `python3 bench/runners/enrich_sampled_decode_rows.py --manifest <harvest-manifest.json>`
- `promote_sampled_decode_fragility.py`
  - writes the checked decode-boundary promotion catalog and per-case promoted
    signatures when the ranked report contains real promotable sampled flips.
  - current checked catalog:
    - `config/numeric-stability-decode-promoted-catalog.json`
  - the catalog may legitimately stay empty when the latest harvest only
    produced controls or meaningless flips.
  - example:
    - `python3 bench/runners/promote_sampled_decode_fragility.py --report <decode-fragility-report.json> --manifest <harvest-manifest.json>`
- `replay_promoted_sampled_decode_vulkan.py`
  - replays the promoted sampled decode set on the configured Vulkan surface so
    cross-backend reproduction becomes an explicit runtime artifact instead of
    a hand-waved follow-up.
  - config is explicit in:
    - `config/numeric-stability-decode-vulkan-replay-plan.json`
  - example:
    - `python3 bench/runners/replay_promoted_sampled_decode_vulkan.py`
- `run_selective_stable_rerun_probe.py`
  - consumes a reduction-order source report and applies a versioned
    numeric-stability route policy instead of only stopping at "the bytes
    changed".
  - records the full governance path:
    first divergence op, fast-vs-stable digests, selected-token consequence,
    trigger checks, and the final route decision.
  - the route policy is now proof-linked:
    the report also records `proofArtifactPath`, `routeTaxonomyVersion`,
    explicit trigger/route proof links, and route-to-selection proof links
    from `config/numeric-stability-policy.json`.
  - current bundled fixture:
    - `bench/fixtures/determinism/apple-metal-selective-stable-rerun-logit-flip.json`
    - `bench/fixtures/determinism/apple-metal-selective-stable-rerun-attention-slice.json`
    - `bench/fixtures/determinism/apple-metal-selective-stable-rerun-rmsnorm-slice.json`
  - example:
    - `python3 bench/runners/run_selective_stable_rerun_probe.py --fixture bench/fixtures/determinism/apple-metal-selective-stable-rerun-logit-flip.json --source-report bench/out/apple-metal-reduction-order-logit-flip/<timestamp>/apple_metal_reduction_order_logit_flip.reduction-order-logit-flip.json`
  - use the generated report to answer:
    where the first sensitive divergence begins, whether the stable rerun
    restores the exact-reference top token, and whether the declared route
    policy should keep the fast or stable result.
  - the attention-slice fixture is the current real-operator-family negative
    control:
    it proves the pipeline can say "no first divergence, keep fast path"
    instead of forcing every named operator family into a false-positive wedge.
  - the `rmsnorm` fixture is the current real-operator-family `accept-fast`
    control:
    the operator is sensitive, the selected token changes, but the strict-
    serial rerun still loses to the exact-reference path, so the route keeps
    the tree/fast result.
- `run_determinism_probe.py`
  - runs explicit determinism stages against Doe and Dawn on the same
    host/backend using the existing semantic-operator artifact path.
  - supported modes are:
    - `receipt`: emit a one-run semantic capture receipt for the sampled-token
      boundary
    - `stable-token`: rerun a greedy sampling boundary and prove token-byte
      stability across runs
    - `stable-decode-step`: rerun a decode step and prove both final-logits and
      sampled-token byte stability across runs
  - the runner can infer semantic capture points directly from ordinary command
    streams, so the bundled fixtures no longer depend on hand-authored capture
    indices for sample-boundary probes.
  - captures are only accepted when semantic execution succeeded:
    if a captured operator reports any `execution.status` other than `ok`, the
    runner fails the surface instead of producing misleading stability receipts.
  - writes an annotated command stream plus per-run trace/meta/operator-manifest
    artifacts and a final report that separates:
    Doe repeated-byte stability, Dawn repeated-byte stability, and cross-surface
    byte equality.
  - for `stable-decode-step` reports, the runner also emits a `tieBreakAudit`
    section that derives the expected greedy token from the captured logits
    buffer (`lowest index among max logits`) and flags whether each surface's
    sampled token matches that sequencing rule.
  - current bundled fixtures are:
    - `bench/fixtures/determinism/apple-metal-greedy-sample-receipt.json`
      for the one-run `receipt` stage on the real `sample.wgsl`
      greedy-argmax kernel
    - `bench/fixtures/determinism/apple-metal-greedy-sample-clear-winner.json`
      for the `stable-token` stage on the real `sample.wgsl`
      greedy-argmax kernel with explicit non-zero logits
    - `bench/fixtures/determinism/apple-metal-gemma3-270m-decode1tok.json`
      for the `stable-decode-step` stage on a Gemma-shaped decode slice on the
      generated compat command stream
  - example:
    - `python3 bench/runners/run_determinism_probe.py --fixture bench/fixtures/determinism/apple-metal-greedy-sample-receipt.json`
    - `python3 bench/runners/run_determinism_probe.py --fixture bench/fixtures/determinism/apple-metal-greedy-sample-clear-winner.json`
    - `python3 bench/runners/run_determinism_probe.py --fixture bench/fixtures/determinism/apple-metal-gemma3-270m-decode1tok.json`
  - use the generated report to make narrow claims only:
    fixed-host, fixed-input byte stability for named probes; not universal LM
    determinism, not cross-platform determinism, and not automatically “more
    deterministic than Dawn”
- `run_real_logit_hunt.py`
  - harvests real final-logits receipts from Doppler's browser advanced API
    (`prefillWithLogits()` / `decodeStepLogits()`) against a real model
    artifact, then ranks prompt/step candidates by exact-max ties, greedy-token
    flips, byte drift, and top-2 margin.
  - uses `bench/executors/harvest-doppler-browser-logits.js` under the hood and
    now supports explicit browser repeat isolation through
    `browser.repeatIsolation`:
    - `reuse-page`: keep one page alive across repeats
    - `new-page`: open a fresh page for each repeat within one browser
    - `new-browser`: relaunch Chromium for each repeat
  - use `new-page` or `new-browser` when hunting real small-margin prompts; the
    older `reuse-page` mode is still useful as a lifecycle-bug detector but is
    not a safe default for determinism claims.
  - current bundled fixture:
    - `bench/fixtures/determinism/apple-metal-real-logit-hunt.gemma270m.json`
    - `bench/fixtures/determinism/apple-metal-real-logit-hunt.gemma270m.natural-stakes.json`
    - `bench/fixtures/determinism/apple-metal-real-logit-hunt.gemma270m.choice-primer.json`
    - `bench/fixtures/determinism/apple-metal-real-logit-hunt.gemma270m.choice-breadth.json`
    - `bench/fixtures/determinism/apple-metal-real-logit-hunt.gemma270m.seatbelt-safe-unsafe.json`
  - example:
    - `python3 bench/runners/run_real_logit_hunt.py --runs 3 --top-candidates 12`
    - `python3 bench/runners/run_real_logit_hunt.py --runs 3 --top-candidates 12 --persist-logits`
  - use the generated report to separate:
    real prompt/step candidates with small greedy margins from browser/model
    lifecycle faults that can otherwise masquerade as nondeterministic logits.
  - the dedicated `red-go-stop-answer` fixture is the current real source surface
    for the promoted LM-head slice above.
- `run_semantic_pair_hunt.py`
  - scans one or more real-logit hunt reports for semantically meaningful token
    pairs such as ` not` vs ` safe` or ` public` vs ` private`, then ranks the
    matches by pairwise logit gap and proximity to the current top token.
  - it now has two explicit input modes:
    - `--source-report`: the original hand-declared pair-fixture path
    - `--mined-report`: promote pair-agnostic mined cases into decode-state
      receipts without a handwritten pair list
  - emits a token-level decode-state recipe for each match:
    `promptTokenIds`, the already-decoded greedy prefix, and the exact
    `currentIds` sequence needed to reconstruct an equivalent decode boundary on
    the same model/runtime path.
  - bundled fixture:
    - `bench/fixtures/determinism/apple-metal-semantic-pair-hunt.gemma270m.json`
    - `bench/fixtures/determinism/apple-metal-semantic-pair-hunt.gemma270m.choice-breadth.json`
  - example:
    - `python3 bench/runners/run_semantic_pair_hunt.py --source-report bench/out/apple-metal-real-logit-hunt/<timestamp>/apple_metal_real_logit_hunt_gemma270m_choice_primer.real-logit-hunt.json --source-report bench/out/apple-metal-real-logit-hunt/<timestamp>/apple_metal_real_logit_hunt_gemma270m_natural_stakes.real-logit-hunt.json`
    - `python3 bench/runners/run_semantic_pair_hunt.py --mined-report bench/out/apple-metal-pair-agnostic-mine/<timestamp>/apple_metal_pair_agnostic_mine_gemma270m.pair-agnostic-mine.json`
  - use the generated report to answer:
    where the model already places meaningful alternatives near the top, and
    which exact decode states are worth carrying forward into sample-only
    stable-token probes.
- `run_pair_agnostic_pair_miner.py`
  - consumes one or more broad scout receipts from `run_real_logit_hunt.py` and
    mines plausible single-token answer pairs directly from each step's `topK`
    surface instead of requiring a predeclared pair library.
  - mining is gated by a tokenizer-aware bounded answer-set registry plus a
    versioned trigger-policy config, so the runner does not promote arbitrary
    numerically-close pairs.
  - the miner keeps explicit provenance on every promoted case:
    `candidateSetSource=mined-topk-v1`, canonical token IDs, source report path,
    source repeat index, prompt/phase/step identity, source logits
    artifact digest/path, `discoveryMode`, `promotionBucket`,
    `triggerPolicyId`, `triggerEvaluation`, and stage-specific stability.
  - the current bundled fixture is conservative by design:
    - `bench/fixtures/determinism/apple-metal-pair-agnostic-mine.gemma270m.json`
  - example:
    - `python3 bench/runners/run_pair_agnostic_pair_miner.py --source-report bench/out/apple-metal-real-logit-hunt/<timestamp>/apple_metal_real_logit_hunt_gemma270m_choice_breadth.real-logit-hunt.json --source-report bench/out/apple-metal-real-logit-hunt/<timestamp>/apple_metal_real_logit_hunt_gemma270m_seatbelt_safe_unsafe.real-logit-hunt.json --source-report bench/out/apple-metal-real-logit-hunt/<timestamp>/apple_metal_real_logit_hunt_gemma270m_high_stakes.real-logit-hunt.json`
  - use the generated report to answer:
    which prompt-bounded pairs are useful enough to promote into decode-state
    receipts without hardcoding the answer pair in advance.
  - zero promotions are a valid result:
    if the registry-gated pairs never survive the usefulness and stability
    filters, the report should stay empty instead of manufacturing a demo.
- `run_semantic_pair_mutation_search.py`
  - takes a promoted semantic-pair report, mutates only the shortlist, reruns a
    cheap real-logit scout over those prompt variants, and writes both:
    - a mutation-search report with promotions and negative controls
    - a companion mined-pair report containing only the improved cases
  - this keeps the later pipeline stages unchanged:
    `run_semantic_pair_hunt.py --mined-report ...` can consume the companion
    mined report directly, and the negative controls remain first-class
    artifacts instead of disappearing.
  - bundled fixture:
    - `bench/fixtures/determinism/apple-metal-semantic-pair-mutation-search.gemma270m.json`
  - example:
    - `python3 bench/runners/run_semantic_pair_mutation_search.py --source-report bench/out/apple-metal-semantic-pair-hunt/<timestamp>/apple_metal_pair_agnostic_mine_gemma270m.semantic-pair-hunt.json --case-count 3 --runs 1`
  - use the generated report to answer:
    whether small prompt edits actually preserve and improve a useful semantic
    pair, or whether they collapse into format/list tokens and should stay as
    negative controls.
  - mutation-derived promotions remain a separate provenance surface:
    they carry `discoveryMode=mutation-derived`,
    `promotionBucket=mutation-assisted`, and source prompt metadata instead of
    being mixed into natural discoveries.
- `run_sample_only_tie_break_probe.py`
  - reuses persisted real-logit hunt artifacts and synthesizes a minimal
    `sample.wgsl` command stream so Doe and Dawn can be compared on the same
    exact input logits bytes.
  - the fixture now also declares an explicit Doe stable-token receipt config
    under `doeStableToken`; the runner invokes
    `bench/executors/run-doe-stable-token.js` so each case carries a Doe
    helper receipt in addition to the raw Doe/Dawn sample receipts.
  - fixtures may also declare an optional `doeStableChoice` section; the
    runner invokes `bench/executors/run-doe-stable-choice.js` so each case can
    carry a bounded-policy ambiguity-resolution receipt alongside the raw and
    stable-token receipts.
  - fixtures may also declare an optional `doeReviewedChoice` section; the
    runner invokes `bench/executors/run-doe-reviewed-choice.js` so each case
    can carry an explicit reviewed-decision receipt alongside the raw,
    stable-token, and stable-choice receipts.
  - stable-choice receipts now include explicit policy provenance:
    `triggerPolicyId`, `candidateSetId`, and `candidateSetSource`.
  - reviewed-choice receipts keep the same trigger and candidate-set
    provenance, but add explicit decision provenance:
    `reviewerId`, optional decision IDs/refs, acceptance, and fallback reason.
  - keeps the same surface methodology as `run_determinism_probe.py`:
    one annotated command stream per case, repeated runs per surface, semantic
    token capture, per-surface stability summary, and cross-surface byte/token
    equality checks.
  - supports controlled mutations on the top-ranked logits before upload:
    - `as-captured`
    - `force-top2-exact-tie`
    - `force-top4-exact-tie`
    - `force-top1-wins-by-1ulp`
    - `force-top2-wins-by-1ulp`
    - `explicit_tokens_exact_tie`
      - ties an explicit semantic token set from the source report, selected by
        token IDs or token texts, at one `f32` ULP above the original global
        max so the chosen tokens control the greedy boundary
  - fixtures can now pin exact source cases with `sourceCases` instead of
    taking the first `N` candidates from the report
  - the runner audits those cases against a scalar `f32` argmax model
    (`cpu_f32_first_max`) so exact-tie stress cases can be separated from
    simple Doe-vs-Dawn parity.
  - the Doe stable-token receipt path uses the public `gpu.determinism.stableToken(...)`
    helper from `doe-gpu`, not an internal Python-only audit branch.
  - the repo-only Doe determinism executors now also emit adjacent zero-row
    `trace_meta` companions (`doe.stable-token.trace-meta.json`,
    `doe.stable-choice.trace-meta.json`, `doe.reviewed-choice.trace-meta.json`)
    whose `determinism` block carries the same policy registry path/version,
    policy IDs, trigger IDs, evaluator IDs, and proof theorem list as the
    public receipts.
  - bundled fixture:
    - `bench/fixtures/determinism/apple-metal-sample-only-tie-break.gemma270m.json`
    - `bench/fixtures/determinism/apple-metal-sample-only-tie-break.brakes-safe-unsafe.gemma270m.json`
    - `bench/fixtures/determinism/apple-metal-sample-only-tie-break.driving-not-good.gemma270m.json`
    - `bench/fixtures/determinism/apple-metal-sample-only-tie-break.patch-public-private.gemma270m.json`
    - `bench/fixtures/determinism/apple-metal-sample-only-tie-break.red-go-stop.gemma270m.json`
    - `bench/fixtures/determinism/apple-metal-sample-only-tie-break.snow-winter-summer.gemma270m.json`
    - `bench/fixtures/determinism/apple-metal-sample-only-tie-break.seatbelt-not-safe.gemma270m.json`
  - example:
    - `python3 bench/runners/run_sample_only_tie_break_probe.py --source-report bench/out/apple-metal-real-logit-hunt/<timestamp>/apple_metal_real_logit_hunt_gemma270m.real-logit-hunt.json`
    - `python3 bench/runners/run_sample_only_tie_break_probe.py --fixture bench/fixtures/determinism/apple-metal-sample-only-tie-break.brakes-safe-unsafe.gemma270m.json --source-report bench/out/apple-metal-real-logit-hunt/<timestamp>/apple_metal_real_logit_hunt_gemma270m_choice_primer.real-logit-hunt.json`
    - `python3 bench/runners/run_sample_only_tie_break_probe.py --fixture bench/fixtures/determinism/apple-metal-sample-only-tie-break.seatbelt-not-safe.gemma270m.json --source-report bench/out/apple-metal-real-logit-hunt/<timestamp>/apple_metal_real_logit_hunt_gemma270m_seatbelt_safe_unsafe.real-logit-hunt.json`
  - use the generated report to answer three different questions:
    - do Doe and Dawn pick the same sampled token on the exact same logits?
    - does the real GPU sample kernel stay aligned with scalar CPU argmax
      semantics under forced exact-tie stress?
    - does Doe `stable-token` recover the scalar expected token on those same
      exact logits when the raw GPU sample kernel does not?
    - can Doe keep the bounded ambiguity detector fixed but switch the
      evaluator from a deterministic program (`stable-choice`) to an explicit
      reviewed decision (`reviewed-choice`) with a separate receipt?
    - can that exact-tie stress be expressed on a real prompt with meaningful
      answer tokens such as ` not` vs ` safe`, not just anonymous `topK`
      positions?
    - which semantic tie families actually differentiate on Apple Metal and
      which ones remain raw Doe/Dawn parity even under a controlled exact tie?
    - can Doe apply a separate bounded-policy `stable-choice` decision on a
      real near-ambiguous prompt without claiming that the underlying model or
      raw sampler became more deterministic?
  - if a refreshed source scout no longer keeps the bounded candidate set in
    `topK`, pin explicit token IDs in the fixture rather than silently
    broadening the source evidence.
- `run_package_determinism_receipt.py`
  - replays one persisted real-logit determinism case through the ordinary
    Node/package executor instead of the helper-only sample probe.
  - preserves semantic capture metadata in the package plan, captures the
    logits/token buffers through the normal readback path, and emits a real
    package `trace_meta` receipt whose `determinism` block matches the public
    `doe-gpu` policy contract.
  - use this runner when a helper/sample-only result needs to be re-proven on
    the actual package surface before it becomes part of a public claim.
  - bundled fixture:
    - `bench/fixtures/determinism/apple-metal-sample-only-tie-break.pool-safe-unsafe.gemma270m.json`
  - example:
    - `python3 bench/runners/run_package_determinism_receipt.py --fixture bench/fixtures/determinism/apple-metal-sample-only-tie-break.pool-safe-unsafe.gemma270m.json --source-report bench/out/apple-metal-real-logit-hunt/<timestamp>/apple_metal_real_logit_hunt_gemma270m_policy_breadth.real-logit-hunt.json --prompt-id pool-safe-unsafe --phase prefill --step-index 0 --mutation-id as-captured --mode stable-choice`
  - fresh natural supporting package receipts:
    - `bench/out/apple-metal-package-determinism/20260328T212103Z/pool-safe-unsafe-prefill-as-captured-stable-token/pool-safe-unsafe-prefill-as-captured-stable-token.package-determinism.json`
    - `bench/out/apple-metal-package-determinism/20260328T212034Z/pool-safe-unsafe-prefill-as-captured-stable-choice/pool-safe-unsafe-prefill-as-captured-stable-choice.package-determinism.json`
    - `bench/out/apple-metal-package-determinism/20260328T212034Z/pool-safe-unsafe-prefill-as-captured-reviewed-choice/pool-safe-unsafe-prefill-as-captured-reviewed-choice.package-determinism.json`
- `cleanup_out.py`
  - prunes legacy untimestamped artifacts from `bench/out` and can optionally prune old timestamped run folders by retention window.
- `organize_out_by_timestamp.py`
  - migrates legacy timestamp-suffixed top-level artifacts into timestamp folders (`bench/out/<timestamp>/...`) for chronological directory listing.
- `backfill_run_manifests.py`
  - writes inferred `run_manifest.json` files for historical timestamp folders that predate manifest emission.
- `list_out_runs.py`
  - prints a concise chronological index of timestamp folders (`timestamp`, `scope`, `runType`, `status`, summary) using `run_manifest.json`.
- `visualize_dawn_vs_doe.py`
  - reads a compare report and writes an ad-hoc local HTML visualization plus optional analysis JSON.
  - this is now a local diagnostic helper, not the default tracked/shareable bench surface.
  - includes ECDF overlays, workload×percentile delta heatmap, KS statistic/p-value, Wasserstein distance, probability of superiority `P(baseline<comparison)`, and bootstrap CIs for delta `p50`/`p95`/`p99`.
- `bench/viewers/bench_out_viewer.html`
  - single static repo-tracked viewer for `bench/out` JSON artifacts.
  - loads compare/claim/cube/inventory/pipeline summary JSON files from local disk via file input and charts the current portable artifact surface without generating new HTML bundles.
- `run_visualization_pipeline.py`
  - builds a timestamped JSON bundle over explicit compare reports:
    pipeline summary JSON plus refreshed cube/inventory JSON surfaces.
  - writes a stable latest summary mirror under `bench/out/visualization/latest/pipeline.summary.json`.
  - the canonical local viewer for these JSON artifacts is `bench/viewers/bench_out_viewer.html`.
- `claim_gate.py`
  - validates a compare report plus claim sidecar against required claim contract fields (`claimPolicy.mode`, `comparisonStatus`, `claimStatus`, per-workload claimability, and comparability-obligation schema/blocking-pass state) for blocking release CI gates.
  - validates comparability obligation IDs against the canonical contract in `config/comparability-obligations.json`.
  - validates compare-report and claim-report linkage via compare-report SHA, workload manifest path/hash, benchmark policy hash, and receipt/trace-meta references.
  - for claimable compare reports, independently enforces positive required tail deltas (`p50`/`p95`/`p99` in release mode) and timed-sample floors per workload.
- `build_claim_rehearsal_artifacts.py`
  - builds machine-readable claim rehearsal artifacts from a compare report:
    claim gate result, tail-health table, timing-invariant audit, contract-hash manifest, and a rehearsal manifest linking all outputs.
- `build_claim_scope_report.py`
  - emits citation-safe claim scope artifacts from a compare report:
    per-workload status (`comparisonStatus`, `claimStatus`, comparability/claimability flags), selected-timing scope vs headline process-wall context, backend/profile metadata, and trace-meta/report paths.
  - fails fast when top-level report status is not explicitly claimable/comparable as required by CLI arguments.
- `cycle_gate.py`
  - validates active cycle contract hash locks (`workloadContract`, benchmark policy, compare config, substantiation policy), methodology invariants, and comparable/directional workload partition.
  - validates claim-report conformance + hash-link invariants, evaluates rollback criteria, and enforces artifact namespace policy (`bench/out/...` canonical vs `bench/out/scratch/...` diagnostics).
- `measure_runtime_footprint.py`
  - measures Doe-vs-Dawn runtime artifact footprint (`rawSizeBytes`, optional stripped size, dependency counts/list) and optional build wall times.
  - emits JSON + markdown reports suitable for embedded/runtime sizing evidence.
- `pipeline-concurrency-bench.py`
  - runs a repeated pipeline/concurrency command under configurable parallelism and emits p50/p95/max timing artifacts.
  - intended as the first evidence harness for async pipeline creation throughput, cold-start contention, and future single-flight/cache wins.
- `run_cts_subset.py`
  - executes a configured WebGPU CTS query subset and emits per-query pass/fail + wall-time artifacts (JSON + markdown).
  - query configs can now carry structured query metadata (`id`, `bucket`, `notes`) plus preflight requirements, so reports include per-bucket pass/fail counts instead of a flat raw-query list.
  - preferred Doe CTS config is `bench/fixtures/cts_subset.fawn-node.json` (literal current compatibility filename), which drives the vendored WebGPU CTS through Doe via `bench/cts/fawn-node-gpu-provider.js`.
  - supports `--dry-run`, `--stop-on-fail`, and bounded query execution via `--max-queries`.
- `run_csl_governed_lane.py`
  - runs the non-hardware CSL smoke surface:
    fresh HostPlan lowering from the Gemma fixture -> simulator-plan materialization -> external simulator-driver invocation -> governed JSON/markdown report.
  - emits explicit compile/run/parity status without fabricating simulator trace output; blocked toolchain/runtime states remain diagnostic instead of silently passing.
  - accepts explicit environment/toolchain wiring when available:
    - `$DOE_CSL_SIM_EXECUTABLE` -> external driver
    - `$DOE_CSLC_EXECUTABLE` -> `cslc`
    - `$DOE_CSL_RUNTIME_EXECUTABLE` -> real simulator/runtime command
- `csl_governed_lane_gate.py`
  - validates governed CSL surface reports against schema and explicit parity/compile/run requirements.
  - intended for `run_blocking_gates.py --with-csl-governed-lane-gate` once the report path is available.
  - use `--require-compile-success` and `--require-run-success` once the SDK surface is available.
- `build_model_capacity_matrix.py`
  - builds a hardware×model capacity matrix artifact from measured AI workload/Doe runs, including status classes (`pass`, `fail`, `oom`, `unsupported`) and per-hardware max passable model size.
  - emits JSON + markdown summaries for explicit model-size ceiling disclosure.
- `run_market_readiness_bundle.py`
  - one-command orchestrator for release evidence packaging:
    release pipeline -> claim scope report -> runtime footprint -> CTS subset -> optional model-capacity matrix.
  - writes a manifest linking all generated artifacts and exits non-zero on any failed step.
- `check_full39_claim_readiness.py`
  - validates the full AMD Vulkan frontier-comparable matrix against strict done criteria (exact comparable workload identity from the canonical main catalog, `comparisonStatus=comparable`, `claimStatus=claimable`, and zero baseline unsupported/error counters).
  - the `full39` name is legacy; the script now derives the active frontier comparable set from `bench/workloads/workloads.amd.vulkan.json`.
  - prints worst p95/p99 tail regressions plus non-claimable workload reasons to accelerate tail-fix loops.
- `run_full39_evidence_bundle.sh`
  - post-run orchestrator for frontier-matrix claim-grade artifacts: readiness check -> blocking gates (pipeline/trace/correctness/schema + drop-in + claim) -> repeated claim windows + substantiation -> inventory and baseline refresh.
  - the `full39` name is legacy; the script now validates against the canonical AMD Vulkan main catalog.
- `generate_feature_benchmark_table.py`
  - builds a markdown table joining `config/webgpu-capability-inventory.json`, workload contracts, and Dawn filter mappings for Dawn-vs-Doe feature/benchmark coverage auditing.
  - emits both overall comparable-coverage and eligible-only comparable-coverage metrics; eligibility is config-driven via `benchmarkClass` (`comparable` vs `directional`) in `config/webgpu-capability-inventory.json`.
  - treats coverage `status=tracked` as spec-inventory-complete (audited/contracted) but not runtime-semantic implementation.
- `verify_smoke_gpu_usage.py`
  - validates AMD Vulkan smoke reports include explicit GPU probe evidence (`gpuMemoryProbeAvailable`, sample counts, and VRAM peak fields) on both sides.

Template placeholders:
`{commands}`, `{quirks}`, `{vendor}`, `{api}`, `{family}`, `{driver}`, `{workload}`, `{dawn_filter}`, `{trace_jsonl}`, `{trace_meta}`, `{extra_args}`.

Benchmark/report-producing scripts now timestamp outputs by default (`YYYYMMDDTHHMMSSZ`) and write artifacts under grouped per-run folders (`bench/out/<group>/<timestamp>/...`) to avoid clobbering, keep related runs together, and preserve chronological history inside each group. Use `--no-timestamp-output` when you intentionally need an exact fixed output path.

Each timestamped run folder now includes `run_manifest.json` with run metadata (`runType`, `config`, `fullRun`, `claimGateRan`, `dropinGateRan`, status fields).
Compare runs that finish but miss claimability now record `status=diagnostic` in the manifest while still exiting non-zero when claimability mode is enabled.
For performance/claim benchmarking, build `runtime/zig/zig-out/bin/doe-zig-runtime` with `zig build -Doptimize=ReleaseFast` before running compare profiles; the optimized build materially reduces the AMD Vulkan `upload_write_buffer_1kb` gap on this host, but the governed release profile still remains performance-bound on that workload.

Ad-hoc/manual artifact names (for example `*layoutcheck*`, `*contractcheck*`, `tmp.*`) are routed to `bench/out/scratch/<timestamp>/...` so canonical runs stay clean.

Generated HTML is no longer the default bench surface. Release compare HTML is optional and off by default, while the portable tracked/shareable surface is JSON plus the single static viewer at `bench/viewers/bench_out_viewer.html`.
Repo tracking keeps the bulky run workspaces ignored by default, but allows the JSON artifact surfaces needed by the current run/compare/claim stack to be committed under `bench/out/` without the NDJSON trace payloads.

Benchmark cube output follows the same discipline:

- timestamped run folder: `bench/out/cube/<timestamp>/`
- stable latest mirror: `bench/out/cube/latest/`
- current artifacts:
  - `cube.rows.json`
  - `cube.summary.json`
  - `cube.matrix.md` only when explicitly requested
  - `cube.dashboard.html` only when explicitly requested

## Artifact cleanup

```bash
# normalize existing legacy top-level timestamp-suffixed artifacts into grouped run folders
python3 bench/organize_out_by_timestamp.py

# backfill historical run manifests where missing
python3 bench/backfill_run_manifests.py

# show what would be removed
python3 bench/tools/cleanup_out.py --dry-run

# remove legacy untimestamped bench/out entries
python3 bench/tools/cleanup_out.py

# scratch namespace holds manual/ad-hoc outputs
ls bench/out/scratch

# show a readable run index across grouped timestamp folders
python3 bench/tools/list_out_runs.py --limit 25

# additionally prune timestamped artifacts older than 14 days
python3 bench/tools/cleanup_out.py --retention-days 14
```

### Retention policy

- `bench/out/scratch/` directories are ephemeral and can be cleaned at any time.
- Timestamped directories under `bench/out/{backend}/` (e.g. `bench/out/amd-vulkan/`, `bench/out/apple-metal/`) are evidence artifacts and should be retained for audit and trend analysis.
- The latest artifact per governed subset is authoritative; older timestamped runs in the same subset are historical evidence and should not be deleted without explicit retention-window pruning via `cleanup_out.py --retention-days`.
- Ad-hoc directories (e.g. `bench/out/node-doe-vs-dawn-*`) follow the same evidence retention rules as backend compare surfaces.
- Do not manually delete benchmark outputs outside of `bench/out/scratch/` without running `cleanup_out.py` to preserve manifest and inventory consistency.

## Workload presets

- `bench/workloads/specialized/workloads.generic.json` defines the generic replay workload view, default profiles, and command seed artifacts.
- workload IDs must follow the immutable naming contract from `bench/docs/benchmark-writing-guide.md`:
  `domain_subject_shape_variant` (status-free, no lifecycle/maturity prefixes).
- each workload includes `comparable` to declare whether mapping quality is apples-to-apples (`true`) or directional (`false`).
- directional workloads may include `directionalReason` to distinguish incumbent limits (`dawn_limit`, `dawn_missing_contract`, `dawn_no_execution`) from transferability or host-only issues (`path_asymmetry`, `host_instability`, `methodology_gap`).
- workloads may set `allowBaselineNoExecution: true` to allow strict comparability for deterministic feature-gated paths when baseline runtime reports unsupported/skipped execution evidence and zero execution errors.
- each workload can include `default: false`; these extended workloads are skipped unless `--include-extended-workloads` or explicit `--workload-filter` is provided.
- workloads are tagged with `domain` and `comparabilityNotes` for report transparency.
- directional workloads that are likely parity-promotion targets can declare `comparabilityCandidate` metadata.
- use `--workload-cohort comparability-candidates` to isolate that candidate set for directional parity work (requires `--include-noncomparable-workloads`).
- use `--workload-cohort doe-advantage` to isolate governed directional Doe-vs-Dawn workloads; this keeps the same strict operation timing basis but reports non-claimable incumbent-limited evidence separately from apples-to-apples compare surfaces.
- canonical cross-surface workload identity now lives in `bench/workloads/metadata/workload-registry.json`.
- backend-native execution contracts still live in `bench/workloads*.json`.
- canonical source of workload intent is `bench/workloads/metadata/backend-workload-catalog.json`.
- generated workload artifacts are `bench/workloads*.json`, `bench/workloads/metadata/workload-overlap-map.json`, and `bench/workloads/metadata/workload-origin-map.json`.
- catalog refresh is [below](#workload-catalog-refresh).

## Workload catalog refresh

Use this exact sequence for any workload intent change:

1. Edit workload intent only in `bench/workloads/metadata/backend-workload-catalog.json`.
2. Regenerate all generated artifacts.
3. Verify generated outputs are canonical and drift-free.
4. Run catalog invariants checks.

```bash
python3 bench/tools/generate_backend_workloads.py
python3 bench/tools/generate_workload_overlap_map.py
python3 bench/tools/generate_backend_workloads.py --emit-workload-origins bench/workloads/metadata/workload-origin-map.json
python3 bench/tools/generate_backend_workloads.py --verify
python3 bench/tools/generate_workload_overlap_map.py --verify
python3 bench/tests/test_backend_workload_catalog.py
```

`test_backend_workload_catalog.py` is an optional invariants check for schema and expected IDs.

Rules:

- do not hand-edit files matching `bench/workloads*.json`; they are generated views.
- keep governed-subset manifests and overlap/origin artifacts in sync with the catalog in the same change.
- do not run release compares or gate-only runs until regenerate + verify steps pass.
- if workload IDs or contract fields change, rerun the workflow before publishing evidence.
- backend-native execution contracts still live in `bench/workloads*.json`.
- Node/Bun package execution stays in normalized plans plus package executors:
  `bench/executors/run-node-webgpu-plan.js` and
  `bench/executors/run-bun-webgpu-plan.js`.
- registry alias normalization still lands in `bench/workloads/metadata/workload-registry.json` and canonicalizes package IDs like `buffer_upload_1kb` to `upload_write_buffer_1kb`.
- D3D12 managed workload files are also generated:
  `bench/workloads/workloads.local.d3d12.json` and `bench/workloads/workloads.local.d3d12.smoke.json`.
- `bench/workloads/workloads.local.d3d12.json` is the canonical D3D12 catalog. Strict D3D12 compare/release surfaces select the governed comparable subset from that file via `selector.cohorts=["governed"]` and `selector.benchmarkClass=["comparable"]`.
- D3D12 preset configs now live in: `bench/native-compare/compare.config.local.d3d12.compare-dev.json`, `bench/native-compare/compare.config.local.d3d12.compare.json`, `bench/native-compare/compare.config.local.d3d12.frontier.json`, `bench/native-compare/compare.config.local.d3d12.explore.json`, `bench/native-compare/compare.config.local.d3d12.release.json`, and `bench/native-compare/compare.config.local.d3d12.smoke.json`.
- Windows D3D12 host workflow remains: `python3 bench/runners/preflight_d3d12_host.py --json`, `python3 bench/runners/run_local_d3d12_lane.py`.
- current comparable default matrix is upload scaling: `buffer_upload_{1kb,64kb,1mb,4mb,16mb}`.
- exploration domains include render/draw, shader/pipeline, texture-raster, and compute suites that are not yet in the governed comparable cohort.

## Dawn-vs-Doe example

Dawn does not publish a dedicated single-purpose `dawn-cli` binary. Use the benchmark
binary built from source (`dawn_perf_tests`) and a filter mapping by workload.

Build Dawn in this repo:

```bash
python3 bench/tools/bootstrap_dawn.py \
  --source-dir bench/vendor/dawn \
  --build-dir bench/vendor/dawn/out/Release \
  --build-system gn \
  --branch main \
  --targets dawn_perf_tests \
  --parallel 8
```

If `bench/vendor/dawn` already exists only as an ignored build-output holder,
preserve it and initialize the source checkout in place:

```bash
python3 bench/tools/bootstrap_dawn.py \
  --source-dir bench/vendor/dawn \
  --build-dir bench/vendor/dawn/out/Release \
  --build-system gn \
  --targets tint tint_benchmark \
  --branch main \
  --gn-args 'is_debug=false' \
  --init-existing-source-dir \
  --sync-deps \
  --gn-bin .tooling/depot_tools/gn \
  --gclient-bin .tooling/depot_tools/gclient \
  --output-state bench/fixtures/dawn_tint_runtime_state.json
```

Use `--fetch-depth 1` on local evidence hosts when you only need the current
branch state for benchmark-tool binaries.

```bash
python3 bench/cli.py compare \
  --baseline-command-template "env LD_LIBRARY_PATH=bench/vendor/dawn/out/Release:$LD_LIBRARY_PATH runtime/zig/zig-out/bin/doe-zig-runtime --commands {commands} --quirks {quirks} --vendor {vendor} --api {api} --family {family} --driver {driver} --backend native --execute --trace --trace-jsonl {trace_jsonl} --trace-meta {trace_meta} {extra_args}" \
  --comparison-command-template "python3 bench/native-compare/dawn_benchmark_adapter.py --dawn-state bench/fixtures/dawn_runtime_state.json --dawn-filter {dawn_filter} --dawn-filter-map bench/dawn_workload_map.json --workload {workload} --dawn-extra-args --backend=vulkan --dawn-extra-args --adapter-vendor-id=0x1002 --trace-jsonl {trace_jsonl} --trace-meta {trace_meta}" \
  --comparability strict \
  --require-timing-class operation \
  --resource-probe rocm-smi \
  --resource-sample-ms 100 \
  --resource-sample-target-count 104 \
  --iterations 3 \
  --warmup 1 \
  --out bench/out/dawn-vs-doe.json
```

Run broader engineering slices:

```bash
python3 bench/cli.py compare \
  --config bench/native-compare/compare.config.amd.vulkan.explore.json \
  --workload-filter compute_workgroup_atomic_1024,compute_workgroup_non_atomic_1024,compute_matvec_32768x2048_f32,compute_matvec_32768x2048_f32_swizzle1,compute_matvec_32768x2048_f32_workgroupshared_swizzle1,pipeline_compile_stress,render_draw_throughput_baseline,texture_sampling_raster_baseline \
  --out bench/out/dawn-vs-doe.amd.vulkan.explore.slice.json
```

With Doe's default binary path:

```bash
python3 bench/cli.py compare \
  --comparison-name "chromium-dawn" \
  --comparison-command-template "/path/to/dawn-wrapper {commands} --trace-jsonl {trace_jsonl} --trace-meta {trace_meta}"
```

## Comparability guardrails

`bench/cli.py compare` marks each workload as comparable/non-comparable and can fail hard:

- `--comparability strict` (default): exit non-zero when timing classes are mixed or mismatched.
- strict mode also exits non-zero when a selected workload contract is explicitly marked non-comparable (`comparable=false`).
- comparability evaluation is emitted as machine-checkable obligations per workload (`comparability.obligations` with `blockingFailedObligations`), and comparability status is derived from blocking-obligation pass/fail (not only free-form reason text).
- `--require-timing-class operation` (default): require operation-level timings on both sides.
- use `--require-timing-class process-wall` only for diagnostic end-to-end overhead studies.
- `--allow-baseline-no-execution`: opt out if baseline trace-meta has no `executionSuccessCount`/`executionRowCount`.
- workload-level `allowBaselineNoExecution: true` provides the same opt-out per workload contract and still requires explicit unsupported/skipped execution evidence when no successful execution samples are present.
- strict mode rejects samples with runtime execution failures (`executionErrorCount > 0`) on either side.
- strict Dawn-vs-Doe package compares now reject submit-scope asymmetry when one side's `submit_wait` phase includes material retained replay/flush work (`packageStepBreakdownNs.submitAddon*`) that the peer side does not measure in the same phase.
- Dawn adapter now fails fast when a gtest filter matches zero tests (`Running 0 tests` / filter no-match warning) so startup-only runs cannot be reported as comparable timings.
- non-comparable workload mappings are excluded by default using `workloads.json` `comparable: false`.
- use `--include-noncomparable-workloads` only for directional investigation runs.
- `--workload-cohort comparability-candidates` filters to workloads with `comparabilityCandidate.enabled=true`; this does not promote those workloads to strict comparable lanes.
- `--workload-cohort doe-advantage` filters to workloads with `benchmarkClass=directional`; these runs are governed Doe-vs-Dawn diagnostics and must not be presented as strict comparable claims.
- non-default workload entries are excluded unless `--include-extended-workloads` is set.
- strict mode now rejects contract-domain workloads as comparable unless explicitly promoted by contract policy.
  for guarded contract domains (`pipeline-async`, `p0-resource`, `p0-compute`, `p0-render`, `p1-capability`,
  `p1-resource-table`, `p1-capability-macro`, `p2-lifecycle`, `p2-lifecycle-macro`, `surface`), promotion
  requires `applesToApplesVetted=true` in workload config.
- strict upload comparability now preflights the executed `doe-zig-runtime` binary:
  it must expose `--upload-buffer-usage` and `--upload-submit-every`, reject invalid values for both flags, and not be older than key upload/runtime Zig sources (`runtime/zig/src/main.zig`, `runtime/zig/src/execution.zig`, `runtime/zig/src/wgpu_commands.zig`, `runtime/zig/src/webgpu_ffi.zig`).
  when a workload contract sets `--queue-wait-mode`, strict preflight also requires runtime support and validation for `--queue-wait-mode process-events|wait-any`.
- strict render comparability now selects encode-only operation timing on the Doe side for workload domains
  `render` and `render-macro` (`timingSource=doe-execution-encode-ns`) when encode is a plausible share of total execution.
  render-bundle workloads use total execution timing because bundle encode timing proved scope-asymmetric on Apple Metal.
- claimability reliability mode is available:
  `--claimability local|release` enforces sample-floor and positive-tail checks for claimable speed reports.
  use `--claim-min-timed-samples N` to override mode defaults loaded from `config/benchmark-methodology-thresholds.json` (`claimabilityDefaults.localMinTimedSamples`, `claimabilityDefaults.releaseMinTimedSamples`).
  claimability failures return non-zero exit status (`3`) and report `claimStatus=diagnostic`.
  workloads whose selected timing scope is `narrow-hot-path` keep `deltaPercent` as an engineering diagnostic, but claimability now evaluates `timingInterpretation.workloadUnitWall.deltaPercent` when that full workload-unit metric is available. `workloadUnitWall` is normalized by one explicit workload-unit divisor preserved in sample timing provenance, so repeated workload units are not double-counted when `commandRepeat` and timing-divisor metadata describe the same unit.
- trace replay gate supports semantic parity lanes:
  `bench/gates/trace_gate.py --semantic-parity-mode auto|required`.
  use `required` only for runtime-to-runtime parity artifacts (for example Doe vs Dawn traces), because Dawn comparison traces are not semantic-envelope compatible.
- optional resource profiling is available via `--resource-probe rocm-smi` and is applied equally to both sides.
- when resource probe is enabled, strict comparability also checks probe quality:
  use fixed `N vs N` probing via `--resource-sample-target-count N`.
  strict mode requires `N > 0`; both sides must match `N` and must not be truncated.

Reliability guardrails for performance claims:

- strict comparability is necessary but not sufficient; claimable "faster" runs also need reliability checks.
- use the claim gate's timed-sample floor per side; `iterations` is the timed sample count, and `warmup` is executed and discarded before those samples.
- speed claims must be positive in tails, not only median:
  require positive `deltaPercent` at least for `p50` and `p95` (and `p99` for release/CI claims).
- if percentile signs are mixed or tails are negative, classify as diagnostic even when comparability is green.
- for upload claims, mixed-scope derived timing sources are not apples-to-apples; strict comparability now marks these runs non-comparable and claimability marks them diagnostic.

Quick reliability recheck pattern:

```bash
python3 bench/cli.py compare \
  --config bench/native-compare/compare.config.amd.vulkan.compare.json \
  --workload-filter upload_write_buffer_64kb \
  --iterations 10 \
  --warmup 1 \
  --out bench/out/dawn-vs-doe.64kb.recheck.json
```

Timing classes:

- `operation`: `doe-execution-dispatch-window-ns`, `doe-execution-encode-ns`, `doe-execution-total-ns`, `doe-execution-workload-total-ns`, `doe-trace-window`, `dawn-perf-wall-time`
- `process-wall`: `wall-time`

Process-wall comparability policy:

- when `--require-timing-class process-wall` is set, `bench/cli.py compare` forces both sides to use outer command wall-time for measurement selection (no trace-meta substitution).
- if trace-meta also reports `timingSource=wall-time`, it is treated as auxiliary metadata and not as the primary timing value.
- process/resource sampling avoids fixed sleep quantization for open-ended runs by waiting on process completion with timeout polling.
- per-workload timing normalization divisors (`baselineTimingDivisor`/`comparisonTimingDivisor`) are only applied in non-process-wall timing modes; process-wall runs use a normalization divisor of `1.0`.
- run receipts now preserve per-sample timing provenance needed to reconstruct selected timing and workload-unit wall after a run-artifact roundtrip.
- strict comparable workloads can also declare `strictNormalizationUnit` when the comparable unit is not raw command-row count:
  - `dispatch`: divisor must match repeated dispatch count
  - `cycle`: divisor must match repeated full-workload cycles
  - default/omitted: divisor must match repeated command-row count
  strict compare fails fast when the configured divisor and trace-derived physical-op count disagree for the declared unit.

Use `process-wall` only for startup/runtime-overhead studies, not per-op claims.

## Resource Bench (1:1)

`bench/cli.py compare` can capture resource metrics for both sides from the same external source:

- `processPeakRssKb`: per-run peak process RSS (`/usr/bin/time` max-RSS when available, with `/proc/<pid>/status` sampling fallback).
- `gpuVramUsed{Before,After,Peak}Bytes` and `gpuVramDeltaPeakFromBeforeBytes`:
  sampled from `rocm-smi --showmeminfo vram --json` when `--resource-probe rocm-smi` is enabled.

Use `--resource-sample-target-count N` to force fixed-count resource probing (`N vs N`) per run.
If a side runs longer than the probe budget, strict comparability fails with a truncation reason.

This is a 1:1 contract because the probe is outside both runtimes and identical for Dawn and Doe.
Interpret VRAM deltas as device-level signals (global GPU usage), not isolated per-process accounting.

## What Is Being Tested

- default comparable Dawn-vs-Doe runs currently test upload throughput scaling with
  `buffer_upload_{1kb,64kb,1mb,4mb,16mb}`.
- each workload is timed at operation-level when available:
  Dawn adapter uses benchmark `*RESULT ... wall_time` samples and takes median;
  Doe timing source is selected by `bench/cli.py compare` policy from trace metadata
  (`executionGpuTimestampTotalNs` -> `executionEncodeTotalNs+executionSubmitWaitTotalNs` -> `executionTotalNs`)
  with fallback to trace-window/wall-time when required fields are unavailable.
  In strict operation mode, webgpu-ffi execution samples must resolve to native execution-span timing
  sources (`doe-execution-*`); fallback timing is treated as non-comparable.
  tiny dispatch-window timings (`<minDispatchWindowNsWithoutEncode` and `<minDispatchWindowCoveragePercentWithoutEncode` of `executionTotalNs`) are rejected as bookkeeping noise whenever `executionTotalNs` is available, and `executionTotalNs` is used instead (`dispatchWindowSelectionRejected` in timing metadata).
  when ignore-first is enabled and applied, source is reported as `doe-execution-workload-total-ns+ignore-first-ops`.
- compare reports now also emit `timingInterpretation` per workload:
  - `selectedTiming` describes what `deltaPercent` actually measures (`operation-total`, `operation-encode`, `process-wall`, etc.).
  - `workloadUnitWall` reports the timed-command process-wall view for the full workload unit, normalized through the explicit per-sample workload-unit divisor carried in timing provenance instead of blindly multiplying `commandRepeat` and timing-divisor metadata.
  - when `selectedTiming.scopeClass=narrow-hot-path`, `deltaPercent` stays a phase-specific diagnostic while claimability uses `workloadUnitWall.deltaPercent` for full workload-unit evaluation when available.
- per-workload timing normalization is config-driven via `baselineTimingDivisor` / `comparisonTimingDivisor`
  in `workloads.json` (matvec uses `baselineTimingDivisor=100` and `comparisonTimingDivisor=1` because Dawn already reports per-dispatch via `iterationsPerStep=100`).
  repeat-asymmetric benchmark runs also normalize counter-derived operation totals and workload-unit wall by `commandRepeat`, so `repeat=100` vs `repeat=1` still compares a single workload unit on both sides.
- non-comparable mappings can be explicitly flagged in workload contracts and excluded by default.

Extended workload domains now include:

- render/draw throughput and state-set variants (`DrawCallPerf` mappings for base, dynamic bind-group, redundant pipeline/bind-group, draw-indexed proxy, and render-bundle dynamic variants).
- shader compile/pipeline stress (`ShaderRobustnessPerf` mapping, comparable, fixed single-test filter + per-step normalization).
- texture/raster and texture API contract workloads (`SubresourceTrackingPerf` mappings) including explicit sampler create/destroy, queue write texture, texture query assertions, and texture destroy lifecycle commands.
- async pipeline diagnostics and most P0/P1/P2 API contracts are directional-only in the AMD extended matrix unless/until a directly matched Dawn contract is available.
- promoted macro contracts now treated as strict comparable include `render_draw_throughput_200k`, `texture_sampler_write_query_destroy_500`, `resource_table_immediates_500`, and `render_pixel_local_storage_barrier_500`.
- hard-gated pilot promotions now treated as strict comparable include `render_multidraw` and `render_multidraw_indexed` (`applesToApplesVetted=true`).
- hard-gated contract promotions now also include `resource_lifecycle` and `compute_indirect_timestamp` (`applesToApplesVetted=true`).
- `surface_presentation` is directional-only (`comparable=false`) because Dawn perf coverage does not expose a matching create/release-surface benchmark contract.
- AMD native Vulkan now executes `surface_presentation` through a Doe-owned
  headless surface lifecycle/present path, and executes `resource_table_immediates`
  / `render_pixel_local_storage_barrier` through explicit native emulation when
  the workload contract opts into `featurePolicy=emulate_when_unavailable`.
- `compute_concurrent_execution_single` is the strict comparable replacement for Dawn `ConcurrentExecutionTest ... RunSingle`.
- compute kernels matched to Dawn compute suites: `WorkgroupAtomicPerf` (atomic/non-atomic) and `MatrixVectorMultiplyPerf` (Rows=32768, Cols=2048, F32/F32 Naive).
  Matvec variants in config:
  `compute_matvec_32768x2048_f32` (Naive Swizzle=0),
  `compute_matvec_32768x2048_f32_swizzle1` (Naive Swizzle=1),
  `compute_matvec_32768x2048_f32_workgroupshared_swizzle1` (WorkgroupShared Swizzle=1).
  Doe matvec command files set `kernel_dispatch.repeat=100` to match Dawn's `kNumDisptaches=100` step structure.

Use report `domain`, `workloadComparable`, and `comparabilityNotes` fields to separate
strict claimable slices from engineering diagnostics.

## Release hard gate (mandatory)

Release CI should treat replay validation as a blocking gate.
After each `bench/cli.py compare` run, fail CI if schema, correctness, or replay
validation fails. For claimable release statements, also fail CI unless
the report is explicitly `claimability.mode=release`, `comparisonStatus=comparable`,
and `claimStatus=claimable`. Then generate an HTML visualization artifact:

```bash
# canonical one-command release pipeline:
python3 bench/runners/run_release_pipeline.py \
  --config bench/native-compare/compare.config.amd.vulkan.release.json \
  --strict-amd-vulkan \
  --trace-semantic-parity-mode auto \
  --with-claim-gate
# emits claim rehearsal artifacts next to the report by default:
# <report>.claim-rehearsal.{claim-gate-result,tail-health,timing-invariant-audit,contract-hash-manifest,manifest}.json

# drop-in compatibility + benchmark suite against a built shared-library artifact:
python3 bench/drop-in/dropin_gate.py \
  --artifact runtime/zig/zig-out/lib/libwebgpu_doe.<so|dylib> \
  --report bench/out/dropin_report.json

# optional standalone drop-in benchmark visualization (micro vs end-to-end sections):
python3 bench/drop-in/visualize_dropin_benchmark.py \
  --report bench/out/dropin_benchmark_report.json \
  --out bench/out/dropin_benchmark_report.html

# run release pipeline and include drop-in gating:
python3 bench/runners/run_release_pipeline.py \
  --config bench/native-compare/compare.config.amd.vulkan.release.json \
  --strict-amd-vulkan \
  --trace-semantic-parity-mode auto \
  --with-dropin-gate \
  --dropin-artifact runtime/zig/zig-out/lib/libwebgpu_doe.<so|dylib> \
  --with-claim-gate

# optional repeated release windows for trend evidence:
python3 bench/runners/run_release_claim_windows.py \
  --config bench/native-compare/compare.config.amd.vulkan.release.json \
  --windows 5 \
  --strict-amd-vulkan \
  --trace-semantic-parity-mode auto \
  --with-dropin-gate \
  --dropin-artifact runtime/zig/zig-out/lib/libwebgpu_doe.<so|dylib> \
  --with-substantiation-gate \
  --substantiation-policy config/substantiation-policy.json
# disable per-window claim rehearsal artifacts only when intentionally running diagnostics:
#   --no-with-claim-rehearsal-artifacts

# optional standalone substantiation gate from existing window summaries/reports:
python3 bench/substantiation_gate.py \
  --policy config/substantiation-policy.json \
  --summary bench/out/release-claim-windows.json

# tested-profile inventory database + simple dashboard:
python3 bench/tools/build_test_inventory_dashboard.py \
  --report-glob "bench/out/**/dawn-vs-doe*.json"

# baseline trend package (JSON + markdown):
python3 bench/tools/build_baseline_dataset.py \
  --report-glob "bench/out/**/dawn-vs-doe*.json"

# optional visualization after the pipeline report exists:
python3 bench/native-compare/visualize_dawn_vs_doe.py --report bench/out/dawn-vs-doe.amd.vulkan.release.json --out bench/out/dawn-vs-doe.amd.vulkan.release.html
# optional machine-readable distribution analysis:
python3 bench/native-compare/visualize_dawn_vs_doe.py --report bench/out/dawn-vs-doe.amd.vulkan.release.json --analysis-out bench/out/dawn-vs-doe.amd.vulkan.release.distribution.json
```

## Building dawn_perf_tests

Use the upstream source:

- https://dawn.googlesource.com/dawn (canonical mirror: https://github.com/google/dawn)

Prerequisites:

- `git`
- `cmake` (3.21+ recommended) when using `--build-system cmake`
- `depot_tools` (`gn`, `autoninja`) when using `--build-system gn`
- working C/C++ compiler + linker

If `gn` is missing, install depot_tools and re-run:

```bash
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git ~/depot_tools
export PATH="$HOME/depot_tools:$PATH"
```

Or point scripts at explicit binaries:

```bash
python3 bench/bootstrap_dawn.py --build-system gn --gn-bin /path/to/gn --ninja-bin /path/to/ninja ...
```

Preferred bootstrap flow (run from this repo):

```bash
python3 bench/bootstrap_dawn.py --build-system gn --targets dawn_perf_tests
```

If bootstrap fails with:

```text
Could not find gn executable at: .../buildtools/.../gn/gn
```

run the same command again; this repo now auto-populates `buildtools` from Dawn’s `DEPS` and
attempts a CIPD install of GN.

If your environment cannot write `bench/vendor/dawn/buildtools`, use explicit standalone
binaries.

If this exact message persists:

```text
gn.py: Unable to find gn in your $PATH
gn.py: Could not find gn executable at: .../buildtools/.../gn/gn
```

this usually means the `depot_tools` wrapper cannot initialize itself. Use a dedicated standalone gn for this step:

```bash
brew install gn ninja
python3 bench/bootstrap_dawn.py \
  --build-system gn \
  --gn-bin $(which gn) \
  --ninja-bin $(which ninja) \
  --source-dir bench/vendor/dawn \
  --build-dir bench/vendor/dawn/out/Release \
  --targets dawn_perf_tests \
  --parallel 8
```

Then rerun with the normal command (explicit gn args are optional once cache is warm):

```bash
python3 bench/bootstrap_dawn.py --build-system gn --targets dawn_perf_tests
```

For an already checked-out Dawn tree, you can also run manifest-only after a successful first bootstrap:

```bash
python3 bench/bootstrap_dawn.py --manifest-only --build-system gn --targets dawn_perf_tests
```

You can disable bootstrap of Dawn buildtools if you prefer:

```bash
python3 bench/bootstrap_dawn.py --build-system gn --skip-gn-bootstrap ...
```

That produces `bench/vendor/dawn/out/Release/dawn_perf_tests` (or your configured build dir)
and writes `bench/fixtures/dawn_runtime_state.json`.

Once built, discover test names and then wire one of them through `dawn_workload_map.json`:

```bash
bench/vendor/dawn/out/Release/dawn_perf_tests --gtest_list_tests
bench/vendor/dawn/out/Release/dawn_perf_tests --gtest_filter=DrawCallPerf.Run/Vulkan__e_skip_validation
```

`dawn_workload_map.json` in this directory holds workload-to-filter mappings.

## Dawn state artifact

`bench/fixtures/dawn_runtime_state.json` is emitted by `bootstrap_dawn.py` and records the checkout path, branch, build type, generator, and resolved binary paths.

## v0 Intent

The scripts are minimal harnesses to establish deterministic I/O contracts early.
They are expanded into real GPU benchmark/test runners as implementation matures.

## Dawn filter resolution policy (fail-fast by default)

`dawn_benchmark_adapter.py` now treats filter selection as an explicit contract:

- Explicit `--dawn-filter` always wins.
- Otherwise the adapter reads `--dawn-filter-map` at `filters.<workload>` only (no implicit default key fallback).
- Autodiscovery is **disabled by default**.
- Autodiscovery runs only when the selected map value is the literal token `@autodiscover`.
- If no filter is resolved and autodiscovery was not explicitly requested, the adapter exits non-zero.

This prevents silent fallback behavior and avoids reporting non-comparable startup timings as valid benchmark results.

### Opt-in autodiscovery

Use `@autodiscover` in your map only where you want dynamic filter selection:

```json
{
  "schemaVersion": 1,
  "filters": {
    "upload_write_buffer_1kb": "@autodiscover"
  }
}
```

### Explicit mapping (no autodiscovery)

```json
{
  "schemaVersion": 1,
  "filters": {
    "upload_write_buffer_1kb": "BufferUploadPerf.Run/Vulkan_AMD_Radeon_Graphics__RADV_GFX1151__WriteBuffer_BufferSize_1KB"
  }
}
```

### Hard-fail guardrails in adapter

Adapter exits non-zero when any of the following occur:

- requested adapter backend/vendor does not exist in detected Dawn adapters
- gtest filter matches zero tests (`Running 0 tests` or no-match warning)
- selected benchmark test is skipped/unsupported (for example `Info: Test unsupported:`)

These failures are intentional and indicate the run is not comparable.

## Config-first run expansion (recommended)

`bench/cli.py run-config` expands one side of a compare config into standalone
run receipts so you do not need to pass long placeholder-heavy templates
inline.

Use:

```bash
python3 bench/cli.py run-config \
  --config bench/native-compare/compare.config.example.json \
  --side baseline

python3 bench/cli.py run-config \
  --config bench/native-compare/compare.config.example.json \
  --side comparison

python3 bench/cli.py compare \
  <baseline.run.json> \
  <comparison.run.json>
```

Config fields (CLI-compatible, config-first):

```json
{
  "workloads": "bench/workloads/specialized/workloads.generic.json",
  "baseline": {
    "name": "doe",
    "commandTemplate": "env LD_LIBRARY_PATH=bench/vendor/dawn/out/Release:$LD_LIBRARY_PATH runtime/zig/zig-out/bin/doe-zig-runtime --commands {commands} --quirks {quirks} --vendor {vendor} --api {api} --family {family} --driver {driver} --backend native --execute --trace --trace-jsonl {trace_jsonl} --trace-meta {trace_meta} {extra_args}"
  },
  "comparison": {
    "name": "dawn",
    "commandTemplate": "python3 bench/native-compare/dawn_benchmark_adapter.py --dawn-state bench/fixtures/dawn_runtime_state.json --dawn-filter-map bench/dawn_workload_map.json --workload {workload} --dawn-extra-args=--backend=vulkan --dawn-extra-args=--adapter-vendor-id=0x1002 --trace-jsonl {trace_jsonl} --trace-meta {trace_meta}"
  },
  "run": {
    "iterations": 3,
    "warmup": 1,
    "out": "bench/out/dawn-vs-doe.ryzen.json",
    "workspace": "bench/out/runtime-comparisons.ryzen",
    "workloadCohort": "all"
  },
  "comparability": {
    "mode": "strict",
    "requireTimingClass": "operation",
    "allowBaselineNoExecution": false
  },
  "resource": {
    "probe": "none",
    "sampleMs": 100,
    "sampleTargetCount": 0
  }
}
```

Notes:

- `comparison.commandTemplate` is required in the compare config.
- CLI flags still work and keep precedence when explicitly provided.
- When `run-config --config` is present, missing CLI fields are filled from
  config.

## AMD + Vulkan preset (config-driven)

A ready-to-run AMD Vulkan governed compare preset is now included:

- config: `bench/native-compare/compare.config.amd.vulkan.compare.json`
- workloads: `bench/workloads/workloads.amd.vulkan.json`
- Dawn filter map: `bench/dawn_workload_map.amd.autodiscover.json`
- AMD quirks list (empty/no-op baseline): `examples/quirks/amd_radv_noop_list.json`

Additional AMD Vulkan presets:

- compare-dev: `bench/native-compare/compare.config.amd.vulkan.compare-dev.json`
- release claim mode on the governed comparable cohort: `bench/native-compare/compare.config.amd.vulkan.release.json`
- comparable-only frontier diagnostics outside the governed cohort: `bench/native-compare/compare.config.amd.vulkan.frontier.json`
- mixed comparable/directional engineering runs: `bench/native-compare/compare.config.amd.vulkan.explore.json`
- diagnostic smoke sanity set: `bench/native-compare/compare.config.amd.vulkan.smoke.json`

Preset behavior:

- Doe side is AMD-profiled in workload fields (`vendor=amd`, `api=vulkan`, `family=gfx11`, `driver=24.0.0`). The default Doe runtime currently expects `driver` to be a semver string.
- Dawn side is constrained to Vulkan + AMD vendor id (`--backend=vulkan`, `--adapter-vendor-id=0x1002`).
- Dawn filter selection is config-controlled and explicit via `@autodiscover` in the map.
- Autodiscovery is opt-in only (from map token `@autodiscover`); otherwise adapter fails fast.
- Compare/release presets use strict operation-level timing (`mode=strict`, `requireTimingClass=operation`).
- strict mode will fail fast if the configured Doe runtime binary does not support upload knobs or appears stale relative to upload/runtime Zig sources.
- Governed upload workloads are configured for strict apples-to-apples matching against Dawn `BufferUploadPerf WriteBuffer`:
  `baselineUploadBufferUsage=copy-dst`, `baselineIgnoreFirstOps=1`, and explicit per-size
  `baselineCommandRepeat`/`baselineTimingDivisor`/`baselineUploadSubmitEvery` values in
  `bench/workloads/workloads.amd.vulkan.json`.

Run from `` directory with a shared timestamp so both sides land under the same
artifact suffix:

```bash
TS=20260411T000000Z
python3 bench/cli.py run-config --config bench/native-compare/compare.config.amd.vulkan.compare.json --side baseline --timestamp "$TS"
python3 bench/cli.py run-config --config bench/native-compare/compare.config.amd.vulkan.compare.json --side comparison --timestamp "$TS"
```

Additional AMD Vulkan runs:

```bash
# diagnostic smoke sanity
python3 bench/cli.py run-config --config bench/native-compare/compare.config.amd.vulkan.smoke.json --side baseline
python3 bench/cli.py run-config --config bench/native-compare/compare.config.amd.vulkan.smoke.json --side comparison

# governed release claim matrix (15 timed samples)
python3 bench/cli.py run-config --config bench/native-compare/compare.config.amd.vulkan.release.json --side baseline
python3 bench/cli.py run-config --config bench/native-compare/compare.config.amd.vulkan.release.json --side comparison

# all comparable workloads from the main catalog, including non-governed frontier workloads
python3 bench/cli.py run-config --config bench/native-compare/compare.config.amd.vulkan.frontier.json --side baseline
python3 bench/cli.py run-config --config bench/native-compare/compare.config.amd.vulkan.frontier.json --side comparison

# mixed comparable/directional engineering space
python3 bench/cli.py run-config --config bench/native-compare/compare.config.amd.vulkan.explore.json --side baseline
python3 bench/cli.py run-config --config bench/native-compare/compare.config.amd.vulkan.explore.json --side comparison

# focused engineering slice from the explore preset
python3 bench/cli.py run-config --config bench/native-compare/compare.config.amd.vulkan.explore.json --side baseline --workload-filter render_draw_throughput_baseline,texture_sampling_raster_baseline
python3 bench/cli.py run-config --config bench/native-compare/compare.config.amd.vulkan.explore.json --side comparison --workload-filter render_draw_throughput_baseline,texture_sampling_raster_baseline

# canonical one-command variants:
python3 bench/runners/run_release_pipeline.py --config bench/native-compare/compare.config.amd.vulkan.release.json --strict-amd-vulkan --with-claim-gate
# disable compare HTML generation when you only want JSON/workspace artifacts:
python3 bench/runners/run_release_pipeline.py --config bench/native-compare/compare.config.amd.vulkan.release.json --no-compare-html-output
```

If Dawn cannot access an AMD Vulkan adapter on the host (for example, missing `/dev/dri` access),
run fails by design and is reported as non-comparable.

Quick host preflight (recommended before strict runs):

```bash
python3 bench/runners/preflight_bench_host.py --strict-amd-vulkan
```

Strict AMD preflight now includes a Dawn adapter probe (`dawn_perf_tests --gtest_list_tests`
with `--backend=vulkan --adapter-vendor-id=0x1002`) plus a Doe-side adapter probe resolved
through `vulkaninfo --summary`. Strict runs fail early unless Doe and Dawn agree on the same
AMD vendor/device identity. This catches cases where `/dev/dri/renderD128` appears readable
via OS-level checks but the two runtimes would land on different effective adapters.

## Apples-to-apples timing configuration

Workloads can now control per-run command stream expansion:

- `baselineCommandRepeat` (default `1`)
- `comparisonCommandRepeat` (default `1`)
- `baselineIgnoreFirstOps` / `comparisonIgnoreFirstOps` (default `0`)
- `baselineUploadBufferUsage` / `comparisonUploadBufferUsage` (default `copy-dst-copy-src`, valid: `copy-dst-copy-src`, `copy-dst`)
- `baselineUploadSubmitEvery` / `comparisonUploadSubmitEvery` (default `1`)

When repeat is greater than `1`, `bench/cli.py compare` still executes one
logical workload unit with the configured repeat count, but Doe command-stream
lanes now prefer structural repeat via `doe-zig-runtime --command-repeat N`
instead of materializing giant repeated JSON arrays. Non-Doe lanes and plan
surfaces still fall back to explicit expansion when required. Use repeat with
timing divisors to compare on the same unit:

- `baselineTimingDivisor`
- `comparisonTimingDivisor`

Example strategy for upload workloads:

- set `baselineCommandRepeat: 50`
- set explicit `baselineUploadSubmitEvery` per workload size (for example, `50`, `2`, `1`, `4`)
- set `baselineUploadBufferUsage: "copy-dst"`
- set `baselineIgnoreFirstOps: 1`
- set `baselineTimingDivisor: 50`
- keep Dawn benchmark metric as per-iteration (`dawn-perf-wall-time`)

This reduces one-command overhead distortion and reports per-upload timing units.

The AMD Vulkan preset (`bench/workloads/workloads.amd.vulkan.json`) applies this upload microbenchmark mode by default.

Strict comparability fail-fast rules for Dawn `BufferUploadPerf ... WriteBuffer` workloads:

- `baselineUploadBufferUsage` must be `copy-dst`.
- `baselineCommandRepeat` must be divisible by `baselineUploadSubmitEvery`.
- (generic rule) `comparisonCommandRepeat` must be divisible by `comparisonUploadSubmitEvery`.

## Dawn-vs-Doe apples-to-apples contract

Claimable Dawn-vs-Doe performance results must satisfy this contract.

- run with `comparability.mode=strict` and `comparability.requireTimingClass=operation`
- for claimable speed statements, also run with `claimability.mode=local|release`
- keep matched workload semantics across both sides: backend/adapter constraints, operation shape, repeat accounting, and timing unit normalization
- use explicit workload config knobs for methodology; do not rely on implicit runtime behavior
- for upload workloads, explicitly set and report:
  `baselineIgnoreFirstOps`/`comparisonIgnoreFirstOps`,
  `baselineUploadBufferUsage`/`comparisonUploadBufferUsage`,
  `baselineUploadSubmitEvery`/`comparisonUploadSubmitEvery`,
  `baselineTimingDivisor`/`comparisonTimingDivisor`
- strict mode must fail fast on mismatched comparability settings or adapter/filter/test validity failures

Two benchmark intents are supported and must be reported separately:

- `apples-to-apples`: implementation-parity workloads (`workloadComparable=true`) with strict comparability.
- `doe-advantage`: Doe-optimized workloads (directional by workload contract) that still use the same strict timing basis (`operation`) for fairness.

Important:

- Dawn-vs-Doe strict runs do not allow mixed timing mechanisms for claim-grade evidence.
- For claim-grade apples-to-apples runs, keep strict operation timing. Use `process-wall` only for diagnostic overhead views.

Directional investigation runs are allowed, but they must be explicitly marked non-comparable (`workloadComparable=false` or `--include-noncomparable-workloads`) and must not be presented as apples-to-apples claims.

## Delta sign convention

Performance deltas are reported from the compare report's baseline role using
ratio-style speedup:

- formula: `((comparisonMs / baselineMs) - 1) * 100`
- positive percent: baseline runtime is faster
- negative percent: baseline runtime is slower
- zero: parity

For the usual Doe-vs-Dawn compare report (`baseline=doe`, `comparison=dawn`),
this means:

- positive percent: Doe is faster than Dawn
- negative percent: Doe is slower than Dawn

Interpretation examples:

- `+300%` => baseline is `4x` faster
- `+400%` => baseline is `5x` faster
- `-50%` => baseline is `2x` slower

`bench/cli.py compare` now writes `artifactKind: compare-report` with `schemaVersion: 1`.
`bench/cli.py claim` writes a separate sibling `artifactKind: claim-report` with `schemaVersion: 1`.

Canonical compare reports include fast-end, median, tail metrics plus the clearer `workloadUnitWall` timing view:

- workload stats include `p10Ms`, `p50Ms`, `p95Ms`, `p99Ms`
- workload deltas include `p10Percent`, `p50Percent`, `p95Percent`, `p99Percent`
- overall delta summary includes `overall.deltaPercent` and `overallWorkloadUnitWall.deltaPercent`
- workload timing interpretation includes selected-scope metadata and a workload-unit wall view (`timingInterpretation.selectedTiming`, `timingInterpretation.workloadUnitWall`)
- reports may also include `overallWorkloadUnitWall` for end-to-end process-wall aggregation across comparable workloads
- legacy aliases remain during migration: `timingInterpretation.headlineProcessWall` and `overallHeadlineProcessWall`
- HTML visualization emphasizes `p10/p50/p95/p99`
- claimability now lives in the sidecar claim report:
  `claimPolicy`, workload claim rows, top-level `claimStatus`, and `reasons`

Historical note:

- older compare payloads predate the `compare-report` / `claim-report` split and remain historical only.

## Local Metal strict lanes

Additive local-metal presets:

- `bench/native-compare/compare.config.apple.metal.compare.json`
- `bench/native-compare/compare.config.apple.metal.release.json`
- `bench/native-compare/compare.config.apple.metal.frontier.json`
- `bench/native-compare/compare.config.apple.metal.explore.json`
- `bench/native-compare/compare.config.apple.metal.smoke.json`

Host preflight:

```bash
python3 bench/runners/preflight_metal_host.py
```

Single-workload strict sweep (repeat one workload and emit median/tail deltas):

```bash
python3 bench/runners/run_single_workload_sweep.py \
  --config bench/native-compare/compare.config.apple.metal.compare.json \
  --workload upload_write_buffer_64kb \
  --repeats 5
```

Blocking gate sequence for strict Apple Metal comparable/release lanes:

```bash
python3 bench/runners/run_blocking_gates.py \
  --report bench/out/dawn-vs-doe.apple.metal.compare.json \
  --with-backend-selection-gate \
  --with-shader-artifact-gate \
  --with-metal-sync-conformance-gate \
  --with-metal-timing-policy-gate \
  --backend-runtime-policy config/backend-runtime-policy.json \
  --backend-timing-policy config/backend-timing-policy.json
```

For release claims, enforce backend telemetry in claim gate:

```bash
python3 bench/cli.py compare \
  --config bench/native-compare/compare.config.apple.metal.release.json

python3 bench/gates/claim_gate.py \
  --report bench/out/dawn-vs-doe.apple.metal.release.json \
  --require-comparison-status comparable \
  --require-claim-status claimable \
  --require-claimability-mode release \
  --require-min-timed-samples 15 \
  --require-backend-telemetry \
  --expected-backend-id doe_metal
```

## Market-readiness evidence bundle

Use this when you need scoped external evidence, not just a raw compare report.

Canonical command:

```bash
python3 bench/runners/run_market_readiness_bundle.py \
  --config bench/native-compare/compare.config.apple.metal.release.json \
  --report bench/out/metal.npm.compare.json \
  --cts-config bench/fixtures/cts_subset.fawn-node.json
```

Outputs (prefix defaults to `<report>.market-readiness.*`):

- claim scope: `*.claim-scope.json`, `*.claim-scope.md`
- footprint: `*.footprint.json`, `*.footprint.md`
- CTS subset: `*.cts.json`, `*.cts.md`
- manifest: `*.manifest.json`

Optional model ceiling matrix artifact:

```bash
python3 bench/runners/run_market_readiness_bundle.py \
  --config bench/native-compare/compare.config.apple.metal.release.json \
  --report bench/out/metal.npm.compare.json \
  --cts-config bench/fixtures/cts_subset.fawn-node.json \
  --model-capacity-config bench/fixtures/model_capacity_matrix.template.json
```

Model matrix source contract (example template):
- `bench/fixtures/model_capacity_matrix.template.json`

Vendored CTS prerequisite:

```bash
cd bench/vendor/dawn/third_party/webgpu-cts
npm install
```

## Governed CSL smoke surface

Use this to exercise the CSL prep path end to end. Without `--csl-cmaddr`,
SDK runtime commands target local simfabric. With `--csl-cmaddr IP_ADDRESS:PORT`,
the same runtime command targets a CS system; credentials remain external to
Doe and are inherited from the SDK environment.

```bash
python3 bench/runners/run_csl_governed_lane.py \
  --driver-executable runtime/zig/tools/csl_sdk_driver.py \
  --csl-sdk-root /path/to/cerebras-sdk

python3 bench/runners/run_csl_governed_lane.py \
  --driver-executable runtime/zig/tools/csl_sdk_driver.py \
  --csl-sdk-root /path/to/cerebras-sdk \
  --csl-cmaddr IP_ADDRESS:PORT
```

What it does:
- builds `doe-csl-bundle-emitter` and `doe-csl-sim-runner`
- emits a real smoke `layout.csl` / `pe_program.csl` bundle from WGSL
- materializes a `csl_simulator_plan`
- probes the external Cerebras SDK driver contract
- writes a governed CSL compare-surface report plus referenced artifacts

Executable resolution:
- `--csl-sdk-root` resolves `cslc` and `cs_python` from the SDK root unless
  `--cslc-executable` or `--runtime-executable` is passed explicitly.
- `--csl-cmaddr` is also accepted through `$DOE_CSL_CMADDR`; command receipts
  record that a system endpoint was requested but redact the actual endpoint.
- other SDK credentials stay in the host environment and are not serialized
  into Doe artifacts.

Optional simulator receipt gate:

```bash
python3 bench/runners/run_blocking_gates.py \
  --report bench/out/dawn-vs-doe.json \
  --with-csl-simulator-gate \
  --csl-simulator-report bench/out/csl-governed-lane.report.json
```

Add `--csl-simulator-require-ready` only when the host has the Cerebras SDK
runtime or a CS system endpoint configured and simulator/runtime execution is
expected to succeed.

Without `cslc` and the Cerebras SDK installed, this surface should finish as
`blocked` / diagnostic with explicit blocker reasons rather than pretending to run.

## Cerebras hardware-validation evidence bundle

Use this when preparing an external ask (e.g. a hardware-access request email).
The bundle packages the software proof into one verifiable archive so the
claims the repo records line up with the bytes a reviewer holds.

One-command prep:

```bash
bench/tools/prepare_cerebras_validation_bundle.sh
```

Runs, in order: `run_cerebras_evidence_bundle.py` (5 local gates) →
`pack_cerebras_validation_archive.py` (builds
`bench/out/doe-cerebras-evidence-YYYYMMDD-HHMM-<shortSha>[-dirty].tar.gz`
with a top-level `README.md` / `CLAIM_SCOPE.md` / `CEREBRAS_ASK.md` /
`LOCAL_INSPECTION.md` / `BUNDLE_META.json` / `MANIFEST.txt` plus
governance + receipt + rollup files) → `verify_cerebras_validation_archive.py`
(manifest sha integrity + claim-role taxonomy + BUNDLE_META completeness +
claim-discipline scan on archive text).

Related tools:

- `bench/tools/summarize_cerebras_evidence_archive.sh <archive>` — print
  E2B/31B/MoE status + bundle verdict entirely from inside the tarball.
- `bench/tools/verify_cerebras_validation_archive.py --archive <path>` —
  re-run just the verifier against a received bundle.

Regression surface that protects the pipeline:

- `bench/tools/e2b_layer_block_self_check.py` — 34 in-loop contracts
  including C16 (pack+verify round-trip), C17 (viewer `/api` routes
  including bundle-summary + evidence-commands), C18 (demo HTML +
  cross-links + command-copy controls), C19 (bundle-summary shape +
  verdict/step consistency), C20 (lane labels), C21 (MoE TODO
  artifactKind), C22 (packager INCLUDE_FILES ↔ CLAIM_ROLE sync), C23
  (packer ↔ verifier extension deny-list sync), C24 (bash -n on bundle
  shell scripts), C25 (data-copy-for ↔ element id consistency), C26
  (summarize script integration), C27 (emulator lane soft-fails CSL
  contract check structurally: WGSL-before-try + unchecked branch +
  cslContract field), C28 (bundle-doc skip-lists sync across packer ↔
  gate ↔ verifier, AST-based), C29 (pointer doc not in INCLUDE_FILES,
  stale-lag guard), C30 (prep-script stage ordering: gates → pack →
  verify → pointer-write), C31 (cerebras-evidence-bundle-tools.md
  lists every on-disk cerebras-* tool), C32 (packer path-substring
  deny-list ↔ verifier FORBIDDEN_PATH_SUBSTRINGS sync — catches a
  hand-edited archive with e.g. `bench/out/scratch/*.json`). See
  `bench/tools/cerebras-evidence-bundle-tools.md` for the full index.
- `bench/gates/claim_discipline_gate.py` — rejects hardware-claim and
  26B/A4B MoE-claim prose anywhere outside rule-enumerating docs.

The bundle is scoped to **evidence + hashes + commands only** — no SDK
binaries, weight bytes, or simulator logs. See
`docs/cerebras-hardware-runbook.md` for the parent ask and
`docs/cerebras-evidence-bundle.md` for the bundle's own reviewer
workflow.

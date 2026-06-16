# Doe status: runtime backends and benchmark lanes

This is a live topical status shard. Follow the shared shard policy in
[`README.md`](README.md).

## 2026-06-16 — Shared evidence blocker taxonomy is gated

Runner-visible evidence blockers now have a shared taxonomy at
`config/evidence-blocker-taxonomy.json` with a schema target and focused gate.
The vocabulary covers provider setup, native WebGPU availability, adapter
selection, hidden fallback, shader/pipeline/dispatch/readback failures, digest
gaps, checkpoint stops, runtime-incomplete states, receipt invalidity, and the
existing model-runtime `executionBlocker` enum. This gives receipt emitters a
stable set of codes to emit without changing receipt payloads in the same pass.
The Chromium runtime selector policy and browser unsupported/fallback reason
taxonomy also map browser-specific fallback reasons into the shared blocker
vocabulary. Developer-visible browser fallback explanations now carry
`evidenceBlockerCode`, so forced-Doe/browser diagnostics can preserve browser
reason detail while still participating in Doe receipt taxonomy checks.

Validation:

- `python3 bench/gates/evidence_blocker_taxonomy_gate.py`
- `python3 bench/gates/schema_gate.py`
- `python3 -m unittest bench.tests.test_evidence_blocker_taxonomy_gate bench.tests.test_config_schemas`
- `python3 browser/chromium/scripts/check-browser-runtime-selector-policy.py --policy config/browser-runtime-selector-policy.json --json`
- `python3 -m unittest bench.tests.test_browser_runtime_selector_policy`
- `python3 bench/tools/check_browser_unsupported_reason_taxonomy.py --taxonomy config/browser-unsupported-reason-taxonomy.json --json`
- `python3 -m unittest bench.tests.test_browser_unsupported_reason_taxonomy`
- `python3 browser/chromium/scripts/check-browser-fallback-explanations.py --explanations examples/browser-fallback-explanations.sample.json --taxonomy-root . --runtime-identity-root . --json`
- `python3 -m unittest bench.tests.test_browser_fallback_explanations`

## 2026-06-08 — Package warmup accounting is corrected; Bun Vulkan is claimable

The native compare runner now treats `iterations` as the number of timed
samples and executes `warmup` as real pre-sample runs that are discarded before
statistics are computed. Package WebGPU timing still uses the compare runner's
sample-level warmup; there is no separate package execution warmup contract.

Fresh AMD Vulkan Gemma270m package resident warm receipts split by runtime
host. The Bun row is strict-comparable and the local claim sidecar is
claimable on selected operation timing with structural work, timing phase,
resident-buffer load, shader source receipt, and readback-capture obligations
passing. The Node row is diagnostic under the stricter submit-scope audit: Doe
reports native addon command-replay work inside submit timing while the Dawn
package side reports zero for that submit sub-scope, so strict comparability
now blocks before any speed claim. The same Node row also has negative selected
operation p50/p95 tails. Workload-unit wall remains diagnostic only and is not
used to promote the row.

Artifacts:

- Node Doe receipt:
  `bench/out/amd-vulkan/20260608T204904Z/gemma270m.node-package.decode.resident.warm.ir.workspace/run-artifacts/doe_gpu_node_package_prepared_resident/doe_gpu_node_package_prepared_resident-inference_gemma3_270m_decode_1tok-20260608T204904Z.run.json`
- Node Dawn receipt:
  `bench/out/amd-vulkan/20260608T205217Z/gemma270m.node-package.decode.resident.warm.ir.workspace/run-artifacts/node_webgpu_package_prepared_resident/node_webgpu_package_prepared_resident-inference_gemma3_270m_decode_1tok-20260608T205217Z.run.json`
- Node strict submit-scope audit compare:
  `bench/out/amd-vulkan/20260608T205217Z/gemma270m.node-package.decode.resident.warm.ir.strict-scope-audit.compare.json`
- Node local claim:
  `bench/out/amd-vulkan/20260608T205217Z/gemma270m.node-package.decode.resident.warm.ir.strict-scope-audit.claim.json`
- Bun Doe receipt:
  `bench/out/amd-vulkan/20260608T205428Z/gemma270m.bun-package.decode.resident.warm.ir.workspace/run-artifacts/doe_gpu_bun_package_prepared_resident/doe_gpu_bun_package_prepared_resident-inference_gemma3_270m_decode_1tok-20260608T205428Z.run.json`
- Bun Dawn receipt:
  `bench/out/amd-vulkan/20260608T205740Z/gemma270m.bun-package.decode.resident.warm.ir.workspace/run-artifacts/bun_webgpu_package_prepared_resident/bun_webgpu_package_prepared_resident-inference_gemma3_270m_decode_1tok-20260608T205740Z.run.json`
- Bun strict compare:
  `bench/out/amd-vulkan/20260608T205740Z/gemma270m.bun-package.decode.resident.warm.ir.clean-process-warm.compare.json`
- Bun local claim:
  `bench/out/amd-vulkan/20260608T205740Z/gemma270m.bun-package.decode.resident.warm.ir.clean-process-warm.claim.json`

Validation:

- `python3 -m unittest bench.tests.test_runner_plan_support`
- `python3 -m unittest bench.tests.test_node_webgpu_executor`
- `python3 -m unittest bench.tests.test_compare_assessment`
- `python3 bench/cli.py run-config --config bench/native-compare/compare.config.amd.vulkan.gemma270m.node-package.decode.resident.warm.ir.json --side baseline --warmup 16 --iterations 16`
- `python3 bench/cli.py run-config --config bench/native-compare/compare.config.amd.vulkan.gemma270m.node-package.decode.resident.warm.ir.json --side comparison --warmup 16 --iterations 16`
- strict operation-timing submit-scope audit compare over the fresh Node
  receipts listed above
- local claim-policy diagnostic sidecar over the fresh Node strict
  submit-scope audit compare listed above
- `python3 bench/cli.py run-config --config bench/native-compare/compare.config.amd.vulkan.gemma270m.bun-package.decode.resident.warm.ir.json --side baseline --warmup 16 --iterations 16`
- `python3 bench/cli.py run-config --config bench/native-compare/compare.config.amd.vulkan.gemma270m.bun-package.decode.resident.warm.ir.json --side comparison --warmup 16 --iterations 16`
- strict operation-timing compare over the fresh Bun receipts listed above
- local claim-policy pass over the fresh Bun strict compare listed above

## 2026-06-08 — Bun FFI Vulkan lazy dispatch routes through Vulkan replay

Vulkan recorded command payloads now carry a captured binding-state snapshot at
record time. Queue-submit replay can consume that snapshot directly while still
falling back to the prior flat-buffer collector when older command payloads do
not provide one. Descriptor hashes remain derived from the actual buffer
handles, offsets, sizes, and binding access metadata, so synchronization tracking
continues to see the resources that the recorded dispatch used.

Bun FFI also no longer sends Linux/Vulkan lazy compute dispatch flushes through
the Metal-only direct path. The direct flush entry point delegates Vulkan work to
the existing Vulkan batch replay path, preserving the fast-path shape while
executing real Vulkan dispatch and copy work. This is a correctness and replay
plumbing change, not a promoted Dawn-vs-Doe performance claim.

Validation:

- `zig fmt runtime/zig/src/doe_native_command_types.zig runtime/zig/src/doe_vulkan_compute_native.zig runtime/zig/src/doe_compute_ext_native.zig runtime/zig/src/doe_compute_fast.zig runtime/zig/src/doe_compute_fast_vulkan.zig`
- `zig build test` from `runtime/zig`
- `zig build dropin-full` from `runtime/zig`
- `zig build dropin` from `runtime/zig`
- `npm --prefix packages/doe-gpu run build:addon`
- `git diff --check`
- Node native zero-dispatch repro with the rebuilt `runtime/zig/zig-out/lib/libwebgpu_doe.so`
- Bun FFI lazy command-buffer smoke with the rebuilt `runtime/zig/zig-out/lib/libwebgpu_doe.so`

## 2026-06-08 — Vulkan replay copy barrier narrowed, package rows still diagnostic

Vulkan recorded-submit replay now carries source and destination buffer handles
into replayed buffer-copy recording. The compute-write visibility barrier for a
copy is narrowed to the buffers that actually participate in the copy when the
runtime has complete pending-write tracking; incomplete tracking still falls
back to the prior global compute-to-transfer barrier. Transfer-write visibility
remains on the prior global path after a scoped transfer-write experiment was
rejected by receipt tails.

Fresh AMD Vulkan Node and Bun package resident warm receipts remain strict
comparable but diagnostic. The local claim sidecars keep both rows out of
claimable status because selected operation timing is still not positive at the
required tails. Workload-unit wall is recorded in the compare artifacts for
diagnosis only and is not used to promote either row. The next focused runtime
target is native batch replay/submit cost inside selected submit-wait, followed
by the recorded command-buffer replay metadata path used by non-package
`queue.submit`.

Artifacts:

- Node Doe receipt:
  `bench/out/amd-vulkan/20260608T200524Z/gemma270m.node-package.decode.resident.warm.ir.workspace/run-artifacts/doe_gpu_node_package_prepared_resident/doe_gpu_node_package_prepared_resident-inference_gemma3_270m_decode_1tok-20260608T200524Z.run.json`
- Node Dawn receipt:
  `bench/out/amd-vulkan/20260608T200443Z/gemma270m.node-package.decode.resident.warm.ir.workspace/run-artifacts/node_webgpu_package_prepared_resident/node_webgpu_package_prepared_resident-inference_gemma3_270m_decode_1tok-20260608T200443Z.run.json`
- Node strict compare:
  `bench/out/amd-vulkan/20260608T200524Z/gemma270m.node-package.decode.resident.warm.ir.scoped-copy-barrier.compare.json`
- Node local claim:
  `bench/out/amd-vulkan/20260608T200524Z/gemma270m.node-package.decode.resident.warm.ir.scoped-copy-barrier.claim.json`
- Bun Doe receipt:
  `bench/out/amd-vulkan/20260608T200657Z/gemma270m.bun-package.decode.resident.warm.ir.workspace/run-artifacts/doe_gpu_bun_package_prepared_resident/doe_gpu_bun_package_prepared_resident-inference_gemma3_270m_decode_1tok-20260608T200657Z.run.json`
- Bun Dawn receipt:
  `bench/out/amd-vulkan/20260608T200706Z/gemma270m.bun-package.decode.resident.warm.ir.workspace/run-artifacts/bun_webgpu_package_prepared_resident/bun_webgpu_package_prepared_resident-inference_gemma3_270m_decode_1tok-20260608T200706Z.run.json`
- Bun strict compare:
  `bench/out/amd-vulkan/20260608T200657Z/gemma270m.bun-package.decode.resident.warm.ir.scoped-copy-barrier.compare.json`
- Bun local claim:
  `bench/out/amd-vulkan/20260608T200657Z/gemma270m.bun-package.decode.resident.warm.ir.scoped-copy-barrier.claim.json`

Validation:

- `zig fmt runtime/zig/src/backend/vulkan/native_runtime.zig runtime/zig/src/backend/vulkan/vk_compute_sync.zig runtime/zig/src/backend/vulkan/vk_upload.zig runtime/zig/src/doe_compute_fast_vulkan.zig runtime/zig/src/doe_queue_submit_vulkan.zig`
- `git diff --check`
- `zig build test` from `runtime/zig`
- `zig build dropin-full` from `runtime/zig`
- `npm --prefix packages/doe-gpu run build:addon`
- `python3 bench/cli.py run-config --config bench/native-compare/compare.config.amd.vulkan.gemma270m.node-package.decode.resident.warm.ir.json --side baseline`
- `python3 bench/cli.py run-config --config bench/native-compare/compare.config.amd.vulkan.gemma270m.node-package.decode.resident.warm.ir.json --side comparison`
- strict operation-timing compare over the fresh Node receipts listed above
- local claim-policy diagnostic sidecar over the fresh Node strict compare listed
  above
- `python3 bench/cli.py run-config --config bench/native-compare/compare.config.amd.vulkan.gemma270m.bun-package.decode.resident.warm.ir.json --side baseline`
- `python3 bench/cli.py run-config --config bench/native-compare/compare.config.amd.vulkan.gemma270m.bun-package.decode.resident.warm.ir.json --side comparison`
- strict operation-timing compare over the fresh Bun receipts listed above
- local claim-policy diagnostic sidecar over the fresh Bun strict compare listed
  above

## 2026-06-08 — Vulkan package pipeline cache is explicit evidence

The AMD Vulkan Node and Bun package resident warm configs now run Doe through
an explicit package pipeline-cache executor. The executor injects
`DOE_PIPELINE_CACHE_DIR` with an artifact-adjacent cache directory, the Vulkan
runtime honors that directory for its persistent pipeline cache, and package
receipts record cache backend/state/reason/warmup/flush telemetry through the
native queue. The flush happens after selected execution timing, so cache
persistence is visible without moving cache I/O into the measured operation
window.

Fresh Node and Bun package receipts after this change are strict-comparable but
still diagnostic. Structural work, timing class, timing phase, resident-buffer
load shape, shader source receipts, and readback captures pass the blocking
comparability obligations. The local claim sidecars keep both rows out of
claimable status because selected operation timing is not positive at the
required tails. Workload-unit wall remains diagnostic only and is not used to
promote either row. The next focused optimization target is the native Vulkan
package queue-submit path inside selected submit/wait, not claim-policy
relaxation.

Artifacts:

- Node Doe receipt:
  `bench/out/amd-vulkan/20260608T185448Z/gemma270m.node-package.decode.resident.warm.ir.workspace/run-artifacts/doe_gpu_node_package_prepared_resident/doe_gpu_node_package_prepared_resident-inference_gemma3_270m_decode_1tok-20260608T185448Z.run.json`
- Node Dawn receipt:
  `bench/out/amd-vulkan/20260608T185459Z/gemma270m.node-package.decode.resident.warm.ir.workspace/run-artifacts/node_webgpu_package_prepared_resident/node_webgpu_package_prepared_resident-inference_gemma3_270m_decode_1tok-20260608T185459Z.run.json`
- Node strict compare:
  `bench/out/amd-vulkan/20260608T185459Z/gemma270m.node-package.decode.resident.warm.ir.vulkan-cache.compare.json`
- Node local claim:
  `bench/out/amd-vulkan/20260608T185459Z/gemma270m.node-package.decode.resident.warm.ir.vulkan-cache.claim.json`
- Bun Doe receipt:
  `bench/out/amd-vulkan/20260608T185747Z/gemma270m.bun-package.decode.resident.warm.ir.workspace/run-artifacts/doe_gpu_bun_package_prepared_resident/doe_gpu_bun_package_prepared_resident-inference_gemma3_270m_decode_1tok-20260608T185747Z.run.json`
- Bun Dawn receipt:
  `bench/out/amd-vulkan/20260608T185755Z/gemma270m.bun-package.decode.resident.warm.ir.workspace/run-artifacts/bun_webgpu_package_prepared_resident/bun_webgpu_package_prepared_resident-inference_gemma3_270m_decode_1tok-20260608T185755Z.run.json`
- Bun strict compare:
  `bench/out/amd-vulkan/20260608T185755Z/gemma270m.bun-package.decode.resident.warm.ir.vulkan-cache.compare.json`
- Bun local claim:
  `bench/out/amd-vulkan/20260608T185755Z/gemma270m.bun-package.decode.resident.warm.ir.vulkan-cache.claim.json`

Validation:

- `python3 bench/cli.py run-config --config bench/native-compare/compare.config.amd.vulkan.gemma270m.node-package.decode.resident.warm.ir.json --side baseline`
- `python3 bench/cli.py run-config --config bench/native-compare/compare.config.amd.vulkan.gemma270m.node-package.decode.resident.warm.ir.json --side comparison`
- strict operation-timing compare over the fresh Node receipts listed above
- local claim-policy diagnostic sidecar over the fresh Node strict compare listed
  above
- `python3 bench/cli.py run-config --config bench/native-compare/compare.config.amd.vulkan.gemma270m.bun-package.decode.resident.warm.ir.json --side baseline`
- `python3 bench/cli.py run-config --config bench/native-compare/compare.config.amd.vulkan.gemma270m.bun-package.decode.resident.warm.ir.json --side comparison`
- strict operation-timing compare over the fresh Bun receipts listed above
- local claim-policy diagnostic sidecar over the fresh Bun strict compare listed
  above

## 2026-06-08 — Node package dispatch prewarm now unwraps public objects

The Node package prewarm path now accepts the public `GPUComputePipeline` and
`GPUBindGroup` objects passed by the shared package executor. It unwraps those
objects to native handles before calling the N-API prepared-dispatch prewarm
binding, matching the fixed Bun path and making the setup prewarm request
actually prepare the recorded dispatch commands.

Fresh Node package receipts after this change remain strict-comparable but
diagnostic. The local claim sidecar keeps the row out of claimable status
because selected operation timing is still not positive at the required tails.
The setup prewarm cost is recorded outside selected timing through the existing
package setup telemetry.

Artifacts:

- Node Doe receipt:
  `bench/out/amd-vulkan/20260608T182532Z/gemma270m.node-package.decode.resident.warm.ir.workspace/run-artifacts/doe_gpu_node_package_prepared_resident/doe_gpu_node_package_prepared_resident-inference_gemma3_270m_decode_1tok-20260608T182532Z.run.json`
- Node Dawn receipt:
  `bench/out/amd-vulkan/20260608T182745Z/gemma270m.node-package.decode.resident.warm.ir.workspace/run-artifacts/node_webgpu_package_prepared_resident/node_webgpu_package_prepared_resident-inference_gemma3_270m_decode_1tok-20260608T182745Z.run.json`
- Node strict compare:
  `bench/out/amd-vulkan/20260608T182745Z/gemma270m.node-package.decode.resident.warm.ir.node-prewarm-fix.compare.json`
- Node local claim:
  `bench/out/amd-vulkan/20260608T182745Z/gemma270m.node-package.decode.resident.warm.ir.node-prewarm-fix.claim.json`

Validation:

- `node --check packages/doe-gpu/src/vendor/webgpu/index.js`
- direct Node prepared-session debug run confirmed dispatch prewarm succeeds
- Node package baseline/comparison runs listed above
- strict operation-timing compare over the fresh Node receipts listed above
- local claim-policy pass over the fresh strict compare listed above

## 2026-06-08 — Bun package dispatch prewarm now unwraps public objects

The Bun FFI package prewarm path now accepts the same public
`GPUComputePipeline` and `GPUBindGroup` objects that the shared package
executor passes to Node. It unwraps those objects to native handles before
packing the Vulkan prewarm call. This fixes a Bun-only setup prewarm failure
that previously left dispatch prewarm recorded as unavailable work with zero
setup cost.

Fresh Bun package receipts after this change remain strict-comparable but
diagnostic. The local claim sidecar keeps the row out of claimable status
because selected operation timing tails are still not positive. The setup
prewarm cost is recorded outside selected timing through the existing package
setup telemetry.

Artifacts:

- Bun Doe receipt:
  `bench/out/amd-vulkan/20260608T182127Z/gemma270m.bun-package.decode.resident.warm.ir.workspace/run-artifacts/doe_gpu_bun_package_prepared_resident/doe_gpu_bun_package_prepared_resident-inference_gemma3_270m_decode_1tok-20260608T182127Z.run.json`
- Bun Dawn receipt:
  `bench/out/amd-vulkan/20260608T182225Z/gemma270m.bun-package.decode.resident.warm.ir.workspace/run-artifacts/bun_webgpu_package_prepared_resident/bun_webgpu_package_prepared_resident-inference_gemma3_270m_decode_1tok-20260608T182225Z.run.json`
- Bun strict compare:
  `bench/out/amd-vulkan/20260608T182225Z/gemma270m.bun-package.decode.resident.warm.ir.bun-prewarm-fix.compare.json`
- Bun local claim:
  `bench/out/amd-vulkan/20260608T182225Z/gemma270m.bun-package.decode.resident.warm.ir.bun-prewarm-fix.claim.json`

Validation:

- `node --check packages/doe-gpu/src/vendor/webgpu/bun-ffi.js`
- direct Bun prepared-session debug run confirmed dispatch prewarm succeeds
- Bun package baseline/comparison runs listed above
- strict operation-timing compare over the fresh Bun receipts listed above
- local claim-policy pass over the fresh strict compare listed above

## 2026-06-08 — Vulkan prepared binding-state cache remains diagnostic

Vulkan package dispatch replay now keeps a small compute-pipeline-local cache
of prepared binding states keyed by retained bind-group identities. The cache
does not skip dispatches, copy/readback work, submit/wait work, or compute
write tracking. Descriptor hashes remain derived from the actual resource
handles, offsets, sizes, and binding metadata captured from the bind groups.

Fresh Node and Bun package receipts after this change remain strict-comparable
but diagnostic. The local claim sidecars keep both rows out of claimable
status because selected operation timing tails are still not positive.

Artifacts:

- Node Doe receipt:
  `bench/out/amd-vulkan/20260608T181347Z/gemma270m.node-package.decode.resident.warm.ir.workspace/run-artifacts/doe_gpu_node_package_prepared_resident/doe_gpu_node_package_prepared_resident-inference_gemma3_270m_decode_1tok-20260608T181347Z.run.json`
- Node Dawn receipt:
  `bench/out/amd-vulkan/20260608T181413Z/gemma270m.node-package.decode.resident.warm.ir.workspace/run-artifacts/node_webgpu_package_prepared_resident/node_webgpu_package_prepared_resident-inference_gemma3_270m_decode_1tok-20260608T181413Z.run.json`
- Node strict compare:
  `bench/out/amd-vulkan/20260608T181413Z/gemma270m.node-package.decode.resident.warm.ir.pipeline-binding-cache.compare.json`
- Node local claim:
  `bench/out/amd-vulkan/20260608T181413Z/gemma270m.node-package.decode.resident.warm.ir.pipeline-binding-cache.claim.json`
- Bun Doe receipt:
  `bench/out/amd-vulkan/20260608T181449Z/gemma270m.bun-package.decode.resident.warm.ir.workspace/run-artifacts/doe_gpu_bun_package_prepared_resident/doe_gpu_bun_package_prepared_resident-inference_gemma3_270m_decode_1tok-20260608T181449Z.run.json`
- Bun Dawn receipt:
  `bench/out/amd-vulkan/20260608T181458Z/gemma270m.bun-package.decode.resident.warm.ir.workspace/run-artifacts/bun_webgpu_package_prepared_resident/bun_webgpu_package_prepared_resident-inference_gemma3_270m_decode_1tok-20260608T181458Z.run.json`
- Bun strict compare:
  `bench/out/amd-vulkan/20260608T181458Z/gemma270m.bun-package.decode.resident.warm.ir.pipeline-binding-cache.compare.json`
- Bun local claim:
  `bench/out/amd-vulkan/20260608T181458Z/gemma270m.bun-package.decode.resident.warm.ir.pipeline-binding-cache.claim.json`

Validation:

- `zig build test` from `runtime/zig`
- `zig build dropin -Doptimize=ReleaseFast` from `runtime/zig`
- `zig build dropin-full -Doptimize=ReleaseFast` from `runtime/zig`
- Node and Bun package baseline/comparison runs listed above
- strict operation-timing compares over the fresh package receipts listed above
- local claim-policy passes over the fresh strict compares listed above

## 2026-06-08 — Vulkan hot compute-state cache remains diagnostic

Vulkan pipeline-state switching now checks a fixed hot cache for inactive
compute pipeline/descriptor state before falling back to the hash-map cache.
The cache preserves the existing active/inactive ownership model: active state
is still removed from the cache when restored, cached state is still destroyed
through the existing release path, descriptor preparation still runs through
the normal binding hash path, and compute binding capture remains on every
prepared dispatch. The patch does not change command order, dispatch shape,
copy/readback behavior, submit/wait behavior, or selected timing scope.

Fresh Node package receipts after this change remain strict-comparable but
diagnostic. The local claim sidecar keeps the row out of claimable status
because selected operation timing tails are still not positive. Bun needs a
fresh post-`dropin` package receipt before this change is used as Bun evidence.

Artifacts:

- Node Doe receipt:
  `bench/out/amd-vulkan/20260608T180326Z/gemma270m.node-package.decode.resident.warm.ir.workspace/run-artifacts/doe_gpu_node_package_prepared_resident/doe_gpu_node_package_prepared_resident-inference_gemma3_270m_decode_1tok-20260608T180326Z.run.json`
- Node Dawn receipt:
  `bench/out/amd-vulkan/20260608T180401Z/gemma270m.node-package.decode.resident.warm.ir.workspace/run-artifacts/node_webgpu_package_prepared_resident/node_webgpu_package_prepared_resident-inference_gemma3_270m_decode_1tok-20260608T180401Z.run.json`
- Node strict compare:
  `bench/out/amd-vulkan/20260608T180401Z/gemma270m.node-package.decode.resident.warm.ir.hot-compute-state.compare.json`
- Node local claim:
  `bench/out/amd-vulkan/20260608T180401Z/gemma270m.node-package.decode.resident.warm.ir.hot-compute-state.claim.json`

Validation:

- `zig build test` from `runtime/zig`
- `zig build dropin -Doptimize=ReleaseFast` from `runtime/zig`
- `zig build dropin-full -Doptimize=ReleaseFast` from `runtime/zig`
- `DOE_WEBGPU_SUBMIT_BREAKDOWN=1 /usr/bin/python3 bench/cli.py run-config --config bench/native-compare/compare.config.amd.vulkan.gemma270m.node-package.decode.resident.warm.ir.json --side baseline`
- `/usr/bin/python3 bench/cli.py run-config --config bench/native-compare/compare.config.amd.vulkan.gemma270m.node-package.decode.resident.warm.ir.json --side comparison`
- post-hoc strict operation-timing compare over the fresh Node Doe and Dawn
  receipts listed above
- local claim-policy pass over the fresh Node strict compare listed above

## 2026-06-08 — Vulkan package dispatch prewarm is setup-only telemetry

Vulkan package prepared sessions now expose a setup-only prepared-dispatch
prewarm hook through the drop-in library, Node N-API bridge, Bun FFI bridge,
and `doe-gpu` package surface. The hook prepares Vulkan pipeline/layout and
descriptor state for the prepared dispatch list before selected execution
timing starts. It does not record command buffers, submit GPU work, wait for
completion, perform copies, skip dispatches, or fold the setup cost into
selected operation timing. Package receipts record the hook through native
fast-path telemetry and setup prewarm breakdown fields.

The current AMD Vulkan Node and Bun package rows remain diagnostic. Strict
claim sidecars still require selected-operation timing to win at the required
tails before a row can become claimable. A per-bind-group dispatch-state cache
probe was rejected after a clean diagnostic run because it did not materially
change the selected replay-preparation target and added runtime object state.

Artifacts:

- Retained Node setup-prewarm diagnostic:
  `bench/out/amd-vulkan/20260608T172719Z/gemma270m.node-package.decode.resident.warm.ir.workspace/run-artifacts/doe_gpu_node_package_prepared_resident/doe_gpu_node_package_prepared_resident-inference_gemma3_270m_decode_1tok-20260608T172719Z.run.json`
- Rejected bind-group dispatch-state cache probe:
  `bench/out/amd-vulkan/20260608T173707Z/gemma270m.node-package.decode.resident.warm.ir.workspace/run-artifacts/doe_gpu_node_package_prepared_resident/doe_gpu_node_package_prepared_resident-inference_gemma3_270m_decode_1tok-20260608T173707Z.run.json`
- Current Node resident claim boundary:
  `bench/out/amd-vulkan/20260608T162947Z/gemma270m.node-package.decode.resident.warm.ir.claim.json`
- Current Bun resident claim boundary:
  `bench/out/amd-vulkan/20260608T162858Z/gemma270m.bun-package.decode.resident.warm.ir.claim.json`

Validation:

- `zig build test` from `runtime/zig`
- `python3 -m unittest bench.tests.test_node_webgpu_executor bench.tests.test_bun_webgpu_executor`
- `python3 -m json.tool config/package-dispatch-prefix-profile.schema.json`
- `node --check bench/executors/node-webgpu/executor.js`
- `node --check packages/doe-gpu/src/vendor/webgpu/index.js`
- `node --check packages/doe-gpu/src/vendor/webgpu/bun-ffi.js`
- `node --check packages/doe-gpu/src/vendor/webgpu/bun.js`
- `node --check packages/doe-gpu/src/bun.js`
- `zig build dropin-full -Doptimize=ReleaseFast` from `runtime/zig`
- `npm --prefix packages/doe-gpu run build:addon`

## 2026-06-08 — AMD Vulkan resident package configs are explicit and diagnostic

AMD Vulkan now has explicit resident-buffer-load warm package configs for the
Gemma 3 270M decode package shape on Bun, Node WebGPU wrapper, and Node
native-direct. These configs mirror the existing resident contract: both sides
use prepared-session executors with `_prepared_resident_buffer_loads`, preload
static file-backed buffer loads before selected timing, and let strict compare
enforce resident mode and resident preload shape matching.

The new rows are strict-comparable but remain diagnostic. The local claim
sidecars keep them out of claimable status because selected operation timing
tails are not positive across the required percentiles. The diagnostic split
continues to point at Doe Vulkan replay preparation / submit work as the next
runtime target, not a harness-side timing-scope change. Two code probes were
not kept: a Node flat-batch N-API submit ABI increased Node package prep cost,
and replacing descriptor-update scratch `ArrayListUnmanaged` allocations with
bounded stack arrays did not improve Vulkan replay preparation.

Configs:

- `bench/native-compare/compare.config.amd.vulkan.gemma270m.bun-package.decode.resident.warm.ir.json`
- `bench/native-compare/compare.config.amd.vulkan.gemma270m.node-package.decode.resident.warm.ir.json`
- `bench/native-compare/compare.config.amd.vulkan.gemma270m.node.direct.decode.resident.warm.ir.json`

Artifacts:

- Bun resident compare:
  `bench/out/amd-vulkan/20260608T162858Z/gemma270m.bun-package.decode.resident.warm.ir.compare.json`
- Bun resident claim:
  `bench/out/amd-vulkan/20260608T162858Z/gemma270m.bun-package.decode.resident.warm.ir.claim.json`
- Node resident compare:
  `bench/out/amd-vulkan/20260608T162947Z/gemma270m.node-package.decode.resident.warm.ir.compare.json`
- Node resident claim:
  `bench/out/amd-vulkan/20260608T162947Z/gemma270m.node-package.decode.resident.warm.ir.claim.json`
- Node native-direct resident compare:
  `bench/out/amd-vulkan/20260608T163309Z/gemma270m.node.direct.decode.resident.warm.ir.compare.json`
- Node native-direct resident claim:
  `bench/out/amd-vulkan/20260608T163309Z/gemma270m.node.direct.decode.resident.warm.ir.claim.json`
- Node resident submit-breakdown probe:
  `bench/out/amd-vulkan/20260608T163040Z/gemma270m.node-package.decode.resident.warm.ir.workspace/run-artifacts/doe_gpu_node_package_prepared_resident/doe_gpu_node_package_prepared_resident-inference_gemma3_270m_decode_1tok-20260608T163040Z.run.json`
- Rejected descriptor-scratch probe:
  `bench/out/amd-vulkan/20260608T163544Z/gemma270m.node-package.decode.resident.warm.ir.workspace/run-artifacts/doe_gpu_node_package_prepared_resident/doe_gpu_node_package_prepared_resident-inference_gemma3_270m_decode_1tok-20260608T163544Z.run.json`

## 2026-06-08 — Vulkan replay copy-prefix fusion remains diagnostic

Vulkan package replay now finalizes pending streaming `queue.writeBuffer`
copies as an ordered replay-prefix command buffer when a deferred recorded
submit is active. The prefix and replay command buffers submit together in one
Vulkan submit, preserving WebGPU command order, dispatch shape, readback
semantics, and the existing transfer-to-compute visibility barrier. Streaming
copy command buffers are now pooled by in-flight slot so Doe does not reset a
queued copy command buffer before the queue drain proves it safe, and staging
buffer growth drains queued copy work before replacing staging memory.

The AMD Vulkan Gemma64 warm package rows on Bun and Node remain
strict-comparable but diagnostic. The local claim sidecars keep both rows out
of claimable status because selected operation timing tails are not positive
across the required percentiles. Two follow-up probes were not kept: lowering
the package dynamic-write batching threshold used the batch ABI but made the
Doe-only diagnostic receipt worse, and a guarded `vkCmdUpdateBuffer` path for
small dynamic writes also made the Doe-only diagnostic receipt worse.

Artifacts:

- Bun compare:
  `bench/out/amd-vulkan/20260608T155831Z/gemma64.bun-package.warm.ir.streaming-copy-prefix.same-window.compare.json`
- Bun claim:
  `bench/out/amd-vulkan/20260608T155831Z/gemma64.bun-package.warm.ir.streaming-copy-prefix.same-window.claim.json`
- Bun Doe receipt:
  `bench/out/amd-vulkan/20260608T155831Z/gemma64.bun-package.warm.ir.workspace/run-artifacts/doe_gpu_bun_package_prepared/doe_gpu_bun_package_prepared-inference_gemma3_270m_prefill_64tok_decode_64tok-20260608T155831Z.run.json`
- Node compare:
  `bench/out/amd-vulkan/20260608T155928Z/gemma64.node-package.warm.ir.streaming-copy-prefix.same-window.compare.json`
- Node claim:
  `bench/out/amd-vulkan/20260608T155928Z/gemma64.node-package.warm.ir.streaming-copy-prefix.same-window.claim.json`
- Node Doe receipt:
  `bench/out/amd-vulkan/20260608T155928Z/gemma64.node-package.warm.ir.workspace/run-artifacts/doe_gpu_node_package_prepared/doe_gpu_node_package_prepared-inference_gemma3_270m_prefill_64tok_decode_64tok-20260608T155928Z.run.json`
- Submit breakdown probe:
  `bench/out/amd-vulkan/20260608T155801Z/gemma64.bun-package.warm.ir.workspace/run-artifacts/doe_gpu_bun_package_prepared/doe_gpu_bun_package_prepared-inference_gemma3_270m_prefill_64tok_decode_64tok-20260608T155801Z.run.json`
- Rejected write-batching probe:
  `bench/out/amd-vulkan/20260608T160205Z/gemma64.bun-package.warm.ir.workspace/run-artifacts/doe_gpu_bun_package_prepared/doe_gpu_bun_package_prepared-inference_gemma3_270m_prefill_64tok_decode_64tok-20260608T160205Z.run.json`
- Rejected update-buffer probe:
  `bench/out/amd-vulkan/20260608T160521Z/gemma64.bun-package.warm.ir.workspace/run-artifacts/doe_gpu_bun_package_prepared/doe_gpu_bun_package_prepared-inference_gemma3_270m_prefill_64tok_decode_64tok-20260608T160521Z.run.json`

Validation:

- `zig build test` from `runtime/zig`
- `zig build dropin-full -Doptimize=ReleaseFast` from `runtime/zig`
- `npm --prefix packages/doe-gpu run build:addon`
- `git diff --check`

## 2026-06-08 — Vulkan package binding-state cache remains diagnostic

Vulkan package replay now caches collected binding metadata for repeated
prepared dispatch states within one package submit batch. Cache hits still flow
through the normal Vulkan prepare and dispatch path, so descriptor lifetime,
binding-capture, compute-write tracking, and transfer/compute visibility
barriers stay on the existing runtime path. The package Node/Bun submit
wrappers also keep small queue-submit scratch/telemetry cleanup, and the Vulkan
fence-pool fallback drain now waits in-flight fences with a batched wait call.

The AMD Vulkan Gemma64 warm package rows on Bun and Node remain
strict-comparable but diagnostic. The local claim sidecars keep both rows out
of claimable status because selected operation timing tails are not positive
across the required percentiles. The useful next target is still reducing
Vulkan package submit count or native driver-submit exposure without changing
the WebGPU command order, dispatch shape, readback semantics, or timing scope.

Artifacts:

- Bun compare:
  `bench/out/amd-vulkan/20260608T154119Z/gemma64.bun-package.warm.ir.binding-state-cache.same-window.compare.json`
- Bun claim:
  `bench/out/amd-vulkan/20260608T154119Z/gemma64.bun-package.warm.ir.binding-state-cache.same-window.claim.json`
- Bun Doe receipt:
  `bench/out/amd-vulkan/20260608T154119Z/gemma64.bun-package.warm.ir.workspace/run-artifacts/doe_gpu_bun_package_prepared/doe_gpu_bun_package_prepared-inference_gemma3_270m_prefill_64tok_decode_64tok-20260608T154119Z.run.json`
- Node compare:
  `bench/out/amd-vulkan/20260608T154221Z/gemma64.node-package.warm.ir.binding-state-cache.same-window.compare.json`
- Node claim:
  `bench/out/amd-vulkan/20260608T154221Z/gemma64.node-package.warm.ir.binding-state-cache.same-window.claim.json`
- Node Doe receipt:
  `bench/out/amd-vulkan/20260608T154221Z/gemma64.node-package.warm.ir.workspace/run-artifacts/doe_gpu_node_package_prepared/doe_gpu_node_package_prepared-inference_gemma3_270m_prefill_64tok_decode_64tok-20260608T154221Z.run.json`

Validation:

- `zig build test` from `runtime/zig`
- `zig build dropin-full -Doptimize=ReleaseFast` from `runtime/zig`
- `node --check packages/doe-gpu/src/vendor/webgpu/index.js`
- `bun --check packages/doe-gpu/src/vendor/webgpu/bun-ffi.js`
- `npm --prefix packages/doe-gpu run build:addon`
- `git diff --check`

## 2026-06-08 — Vulkan package replay caches are strict but still diagnostic

Vulkan package replay now caches immutable Vulkan buffer ids on bind groups and
reuses consecutive prepared dispatch state when the pipeline and bind-group
objects are unchanged. The replay path still records every dispatch, preserves
descriptor hashing from resource handles, offsets, and sizes, and keeps
compute-write tracking/barrier capture on every recorded dispatch.

The final AMD Vulkan Gemma64 warm package rows on both Bun and Node remain
strict-comparable but diagnostic. The local claim sidecars keep both rows out
of claimable status because selected operation timing tails are not positive.
The latest breakdown still points at Vulkan submit/replay work as the next
optimization front rather than a harness fairness issue.

Artifacts:

- Bun compare:
  `bench/out/amd-vulkan/20260608T150640Z/gemma64.bun-package.warm.ir.bindgroup-prepared-reuse.same-window.compare.json`
- Bun claim:
  `bench/out/amd-vulkan/20260608T150640Z/gemma64.bun-package.warm.ir.bindgroup-prepared-reuse.same-window.claim.json`
- Bun Doe receipt:
  `bench/out/amd-vulkan/20260608T150640Z/gemma64.bun-package.warm.ir.workspace/run-artifacts/doe_gpu_bun_package_prepared/doe_gpu_bun_package_prepared-inference_gemma3_270m_prefill_64tok_decode_64tok-20260608T150640Z.run.json`
- Node compare:
  `bench/out/amd-vulkan/20260608T150727Z/gemma64.node-package.warm.ir.bindgroup-prepared-reuse.same-window.compare.json`
- Node claim:
  `bench/out/amd-vulkan/20260608T150727Z/gemma64.node-package.warm.ir.bindgroup-prepared-reuse.same-window.claim.json`
- Node Doe receipt:
  `bench/out/amd-vulkan/20260608T150727Z/gemma64.node-package.warm.ir.workspace/run-artifacts/doe_gpu_node_package_prepared/doe_gpu_node_package_prepared-inference_gemma3_270m_prefill_64tok_decode_64tok-20260608T150727Z.run.json`
- Submit breakdown probe:
  `bench/out/amd-vulkan/20260608T145918Z/gemma64.bun-package.warm.ir.workspace/run-artifacts/doe_gpu_bun_package_prepared/doe_gpu_bun_package_prepared-inference_gemma3_270m_prefill_64tok_decode_64tok-20260608T145918Z.run.json`

Validation:

- `zig build test` from `runtime/zig`
- `zig build dropin-full -Doptimize=ReleaseFast` from `runtime/zig`
- `npm --prefix packages/doe-gpu run build:addon`
- `git diff --check`

## 2026-06-08 — Vulkan package sync policy and replay prep stay diagnostic

Vulkan deferred-submit synchronization is now a manifest-backed policy. The
backend runtime policy schema requires `deferredSubmissionSyncPolicy`, the
policy hash seed moved with that contract, and the diagnostic
`vulkan_doe_compute_only_fence_diagnostic` lane requires both a compute-only
queue family and fence-pool deferred submission tracking. Package trace
metadata now reports the selected deferred-sync policy beside the existing
queue-family telemetry, so fence-vs-timeline diagnostics are receipt-visible.

The Vulkan package replay path now carries precomputed static pipeline/layout
hashes, prepares package batch dispatches directly from validated bind groups
where the fast path has already surfaced them, and records compute pipeline and
descriptor binds through the existing Vulkan bind-state cache helpers. These
changes preserve descriptor hashing and compute-write binding capture; they do
not skip commands, resource changes, copies, readback, submit, or wait work.

Current AMD Vulkan Gemma64 warm package rows on Node and Bun remain
diagnostic, not claimable. The final Node and Bun same-window reports are
strict-comparable with matching execution shape and no path asymmetry, but the
local claim sidecars keep the rows diagnostic because selected operation
timing tails are not positive. The submit breakdown still points at native
Vulkan replay preparation/recording plus driver submit as the next optimization
front.

Artifacts:

- Node compare:
  `bench/out/amd-vulkan/20260608T143945Z/gemma64.node-package.warm.ir.compute-only-fence.same-window.compare.json`
- Node claim:
  `bench/out/amd-vulkan/20260608T143945Z/gemma64.node-package.warm.ir.compute-only-fence.same-window.claim.json`
- Node Doe receipt:
  `bench/out/amd-vulkan/20260608T143945Z/gemma64.node-package.warm.ir.workspace/run-artifacts/doe_gpu_node_package_prepared/doe_gpu_node_package_prepared-inference_gemma3_270m_prefill_64tok_decode_64tok-20260608T143945Z.run.json`
- Bun compare:
  `bench/out/amd-vulkan/20260608T144045Z/gemma64.bun-package.warm.ir.compute-only-fence.same-window.compare.json`
- Bun claim:
  `bench/out/amd-vulkan/20260608T144045Z/gemma64.bun-package.warm.ir.compute-only-fence.same-window.claim.json`
- Bun Doe receipt:
  `bench/out/amd-vulkan/20260608T144045Z/gemma64.bun-package.warm.ir.workspace/run-artifacts/doe_gpu_bun_package_prepared/doe_gpu_bun_package_prepared-inference_gemma3_270m_prefill_64tok_decode_64tok-20260608T144045Z.run.json`
- Submit breakdown probe:
  `bench/out/amd-vulkan/20260608T143833Z/gemma64.bun-package.warm.ir.workspace/run-artifacts/doe_gpu_bun_package_prepared/doe_gpu_bun_package_prepared-inference_gemma3_270m_prefill_64tok_decode_64tok-20260608T143833Z.run.json`

Validation:

- `python3 bench/gates/schema_gate.py`
- `node --check packages/doe-gpu/src/vendor/webgpu/index.js`
- `node --check bench/executors/node-webgpu/executor.js`
- `bun --check packages/doe-gpu/src/vendor/webgpu/bun-ffi.js`
- `python3 -m unittest bench.tests.test_config_validation bench.tests.test_node_webgpu_executor -q`
- `zig build test` from `runtime/zig`
- `zig build dropin-full -Doptimize=ReleaseFast` from `runtime/zig`
- `npm --prefix packages/doe-gpu run build:addon`
- `git diff --check`

## 2026-06-08 — Vulkan queue-family policy is manifest-backed telemetry

Doe Vulkan queue-family selection now has an explicit runtime-policy contract.
`config/backend-runtime-policy.json` schema version 3 requires
`queueFamilyPolicy` on every lane, with `prefer_graphics_compute`,
`prefer_compute_only`, and `require_compute_only` as the only accepted values.
The default AMD Vulkan Doe lanes keep the previous graphics+compute preference,
while compute-only probes must be declared in policy and `require_compute_only`
fails closed if no compute-only family exists.

Trace rows and trace-meta receipts now emit the requested queue-family policy
and the selected family shape: kind, queue count, timestamp-valid bits, and
graphics support. This makes queue-family experiments auditable before they are
allowed into package comparability or claim gates. It does not promote any
diagnostic row to claimable evidence by itself.

## 2026-06-07 — Doe Chromium Vulkan canvas path reaches submit

The local Fawn Chromium build now loads the Doe WebGPU runtime on the Linux
Vulkan path far enough to create a browser WebGPU canvas texture and complete a
clear render pass without losing the device. The immediate crash was Chromium
treating the Doe WebGPU-backed device as a native Dawn Vulkan device for shared
image mailbox access; the decoder now records Doe devices as WebGPU-backed for
mailbox metadata and routes that browser canvas shared-image path through
Chromium's existing Skia fallback instead of calling native Dawn
`WrapVulkanImage()`.

This is diagnostic browser progress, not browser claim evidence. The regular
Doe-mode browser smoke no longer records the surface/canvas crash, but compute
readback and external image paths still lose the external instance or fail
their browser API checks. The next browser work is to keep the WebGPU backend
instance alive through general buffer mapping/readback and then replace the
Skia copy fallback with a native Doe-compatible shared-image path before any
browser performance claim is allowed.

Artifacts:

- Doe browser smoke:
  `browser/chromium/artifacts/20260607T163908Z/dawn-vs-doe.browser.playwright-smoke.diagnostic.json`

Validation:

- `zig build dropin`
- `zig build dropin-full`
- `ninja -C browser/chromium/src/out/fawn_release headless_shell`
- focused local-origin CDP canvas probe against
  `browser/chromium/src/out/fawn_release/headless_shell`
- `python3 browser/chromium/scripts/check-browser-smoke-report.py --smoke-report browser/chromium/artifacts/20260607T163908Z/dawn-vs-doe.browser.playwright-smoke.diagnostic.json --require-modes doe --no-require-strict`
  still fails because the full browser smoke remains diagnostic.
- `python3 runtime/zig/tools/check_core_import_fence.py`
- `zig build test-core` and `zig build test-full` still fail on existing
  expected-error test logging after their unit-test bodies pass/skip; no import
  fence violation remains.
- `git diff --check`
- `git -C browser/chromium/src diff --check`

## 2026-06-07 — AMD Vulkan package matrix and Node write-batch policy

The promoted AMD Vulkan package lanes for Gemma64 and Gemma1B now have
strict-comparable, locally claimable Node and Bun receipts for warm and cold
package modes. The claim surface remains narrow: selected operation timing,
strict comparability, structural-equivalence gates, timing-policy gates, and
claim-gate telemetry checks must pass before a row is treated as claimable.

The claim gate now requires Doe package claim rows to expose package fast-path
telemetry in successful trace metadata. A claimable package row must make the
native package path, readback mode, write breakdown, selected setup-timing
scope, and native fast-path availability visible in the receipt. This prevents
package comparisons from being promoted when the accelerated path or timing
scope is hidden.

The Node Doe package surface exposes standard addon `queueWriteBufferBatch` and
`queueWriteBufferBatchDataPtrs` exports and wires the package queue backend to
the existing native compact and per-entry pointer batch ABIs. The schema
migration is additive and backward-compatible. New artifacts emit explicit
booleans for `packageNativeFastPaths.queueWriteBufferBatch` and
`packageNativeFastPaths.queueWriteBufferBatchDataPtrs`.

The AMD Vulkan Gemma64 warm probe showed that batching the current small
dynamic-write groups is not a selected-timing improvement. The package
execution policy therefore keeps Node batching available but requires larger
consecutive write groups before the executor uses it. The final Gemma64 warm
Node receipt reports the native batch capability while keeping the current
workload on direct writes.

Artifacts:

- Gemma64 warm Node compare:
  `bench/out/amd-vulkan/20260607T141441Z/gemma64.node-package.warm.ir.compare.json`
- Gemma64 warm Node claim:
  `bench/out/amd-vulkan/20260607T141441Z/gemma64.node-package.warm.ir.claim.json`
- Gemma64 warm Node coherence:
  `bench/out/amd-vulkan/20260607T141441Z/gemma64.node-package.warm.ir.comparability-coherence.json`
- Gemma64 warm Bun compare:
  `bench/out/amd-vulkan/20260607T124200Z/gemma64.bun-package.warm.ir.compare.json`
- Gemma64 warm Bun claim:
  `bench/out/amd-vulkan/20260607T124200Z/gemma64.bun-package.warm.ir.claim.json`
- Gemma64 cold Node compare:
  `bench/out/amd-vulkan/20260607T135646Z/gemma64.node-package.ir.compare.json`
- Gemma64 cold Node claim:
  `bench/out/amd-vulkan/20260607T135646Z/gemma64.node-package.ir.claim.json`
- Gemma64 cold Bun compare:
  `bench/out/amd-vulkan/20260607T135813Z/gemma64.bun-package.ir.compare.json`
- Gemma64 cold Bun claim:
  `bench/out/amd-vulkan/20260607T135813Z/gemma64.bun-package.ir.claim.json`
- Gemma1B warm Node compare:
  `bench/out/amd-vulkan/20260607T135013Z/gemma1b.node-package.warm.ir.compare.json`
- Gemma1B warm Node claim:
  `bench/out/amd-vulkan/20260607T135013Z/gemma1b.node-package.warm.ir.claim.json`
- Gemma1B warm Bun compare:
  `bench/out/amd-vulkan/20260607T135129Z/gemma1b.bun-package.warm.ir.compare.json`
- Gemma1B warm Bun claim:
  `bench/out/amd-vulkan/20260607T135129Z/gemma1b.bun-package.warm.ir.claim.json`
- Gemma1B cold Node compare:
  `bench/out/amd-vulkan/20260607T135358Z/gemma1b.node-package.ir.compare.json`
- Gemma1B cold Node claim:
  `bench/out/amd-vulkan/20260607T135358Z/gemma1b.node-package.ir.claim.json`
- Gemma1B cold Bun compare:
  `bench/out/amd-vulkan/20260607T135517Z/gemma1b.bun-package.ir.compare.json`
- Gemma1B cold Bun claim:
  `bench/out/amd-vulkan/20260607T135517Z/gemma1b.bun-package.ir.claim.json`
- Node write-batch policy probe:
  `bench/out/amd-vulkan/20260607T141302Z/gemma64.node-package.warm.ir.workspace/run-artifacts/doe_gpu_node_package_prepared/doe_gpu_node_package_prepared-inference_gemma3_270m_prefill_64tok_decode_64tok-20260607T141302Z.run.json`

Validation:

- `git diff --check`
- `python3 -m json.tool config/package-execution-policy.json >/dev/null`
- `node --check packages/doe-gpu/src/vendor/webgpu/index.js`
- `node --check bench/executors/node-webgpu/executor.js`
- `node --check bench/tools/package_dispatch_prefix_profile.mjs`
- `bun --check packages/doe-gpu/src/vendor/webgpu/bun-ffi.js`
- `python3 -m json.tool config/trace-meta.schema.json >/dev/null`
- `python3 -m json.tool config/package-dispatch-prefix-profile.schema.json >/dev/null`
- `python3 -m unittest bench.tests.test_node_webgpu_executor bench.tests.test_bun_webgpu_executor bench.tests.test_package_dispatch_prefix_profile bench.tests.test_claim_gate -q`
- `npm --prefix packages/doe-gpu run build:addon`
- `node -e "const addon=require('./packages/doe-gpu/build/Release/doe_napi.node'); for (const name of ['queueWriteBufferBatch','queueWriteBufferBatchDataPtrs']) { if (typeof addon[name] !== 'function') { throw new Error(name + ' export missing'); } }"`
- `python3 bench/gates/claim_gate.py --report bench/out/amd-vulkan/20260607T141441Z/gemma64.node-package.warm.ir.compare.json --claim-report bench/out/amd-vulkan/20260607T141441Z/gemma64.node-package.warm.ir.claim.json --require-comparison-status comparable --require-claim-status claimable --require-claimability-mode local --require-min-timed-samples 15 --config bench/native-compare/compare.config.amd.vulkan.gemma64.node-package.warm.ir.json`
- `python3 bench/gates/comparability_coherence_gate.py --report bench/out/amd-vulkan/20260607T141441Z/gemma64.node-package.warm.ir.compare.json --benchmark-policy config/benchmark-methodology-thresholds.json --require-pass --out bench/out/amd-vulkan/20260607T141441Z/gemma64.node-package.warm.ir.comparability-coherence.json`
- `python3 bench/gates/structural_equivalence_gate.py --report bench/out/amd-vulkan/20260607T141441Z/gemma64.node-package.warm.ir.compare.json --require-all-pass`
- `python3 bench/gates/timing_policy_gate.py --backend vulkan --report bench/out/amd-vulkan/20260607T141441Z/gemma64.node-package.warm.ir.compare.json`

## 2026-06-07 — AMD Vulkan package Node and Bun claimable

The AMD Vulkan package prepared lane now executes the Doe Vulkan path through
the native package bridge for the Gemma warm workload without the earlier
missing-bind-group/runtime-state failure. The Node package comparison is
strict-comparable and locally claimable against the Dawn-backed Node WebGPU
package. Bun now exposes the same native batch/flush symbols to the Linux
Vulkan FFI table, so the Bun package comparison is also strict-comparable and
locally claimable.

The browser lane was advanced to the documented AMD Vulkan browser superset
front door. No promoted AMD Vulkan browser claim profile exists yet; the
available browser surface is diagnostic. A stock-Chrome `auto` selector run
completed and selected Doe without fallback. The remaining browser blockers are
render-bundle and surface/canvas runtime failures recorded in the browser
diagnostic artifact, and this host has no local Fawn Chromium build under the
expected release output path.

Artifacts:

- Node compare report:
  `bench/out/amd-vulkan/20260607T122747Z/gemma64.node-package.warm.ir.compare.json`
- Node claim report:
  `bench/out/amd-vulkan/20260607T122747Z/gemma64.node-package.warm.ir.claim.json`
- Node comparability-coherence gate result:
  `bench/out/amd-vulkan/20260607T122747Z/gemma64.node-package.warm.ir.comparability-coherence.json`
- Node Doe run receipt:
  `bench/out/amd-vulkan/20260607T122747Z/gemma64.node-package.warm.ir.workspace/run-artifacts/doe_gpu_node_package_prepared/doe_gpu_node_package_prepared-inference_gemma3_270m_prefill_64tok_decode_64tok-20260607T122747Z.run.json`
- Node Dawn package run receipt:
  `bench/out/amd-vulkan/20260607T122747Z/gemma64.node-package.warm.ir.workspace/run-artifacts/node_webgpu_package_prepared/node_webgpu_package_prepared-inference_gemma3_270m_prefill_64tok_decode_64tok-20260607T122747Z.run.json`
- Bun compare report:
  `bench/out/amd-vulkan/20260607T124200Z/gemma64.bun-package.warm.ir.compare.json`
- Bun claim report:
  `bench/out/amd-vulkan/20260607T124200Z/gemma64.bun-package.warm.ir.claim.json`
- Bun comparability-coherence gate result:
  `bench/out/amd-vulkan/20260607T124200Z/gemma64.bun-package.warm.ir.comparability-coherence.json`
- Bun Doe run receipt:
  `bench/out/amd-vulkan/20260607T124149Z/gemma64.bun-package.warm.ir.workspace/run-artifacts/doe_gpu_bun_package_prepared/doe_gpu_bun_package_prepared-inference_gemma3_270m_prefill_64tok_decode_64tok-20260607T124149Z.run.json`
- Bun WebGPU package run receipt:
  `bench/out/amd-vulkan/20260607T124200Z/gemma64.bun-package.warm.ir.workspace/run-artifacts/bun_webgpu_package_prepared/bun_webgpu_package_prepared-inference_gemma3_270m_prefill_64tok_decode_64tok-20260607T124200Z.run.json`
- Browser diagnostic report:
  `browser/chromium/artifacts/20260607T124449Z/dawn-vs-doe.browser-layered.superset.diagnostic.json`
- Browser diagnostic summary:
  `browser/chromium/artifacts/20260607T124449Z/dawn-vs-doe.browser-layered.superset.summary.json`
- Browser diagnostic check:
  `browser/chromium/artifacts/20260607T124449Z/dawn-vs-doe.browser-layered.superset.check.json`

Validation:

- `zig build dropin -Doptimize=ReleaseFast`
- `npm --prefix packages/doe-gpu run build:addon`
- `bun --check packages/doe-gpu/src/vendor/webgpu/bun-ffi.js`
- `node --check bench/executors/package-webgpu/runner-core.js`
- `python3 -m unittest bench.tests.test_package_dispatch_prefix_profile -q`
- `python3 bench/cli.py compare bench/out/amd-vulkan/20260607T122747Z/gemma64.node-package.warm.ir.workspace/run-artifacts/doe_gpu_node_package_prepared/doe_gpu_node_package_prepared-inference_gemma3_270m_prefill_64tok_decode_64tok-20260607T122747Z.run.json bench/out/amd-vulkan/20260607T122747Z/gemma64.node-package.warm.ir.workspace/run-artifacts/node_webgpu_package_prepared/node_webgpu_package_prepared-inference_gemma3_270m_prefill_64tok_decode_64tok-20260607T122747Z.run.json --comparability strict --require-timing-class operation --out bench/out/amd-vulkan/20260607T122747Z/gemma64.node-package.warm.ir.compare.json`
- `python3 bench/cli.py claim bench/out/amd-vulkan/20260607T122747Z/gemma64.node-package.warm.ir.compare.json --config bench/native-compare/compare.config.amd.vulkan.gemma64.node-package.warm.ir.json --mode local --min-timed-samples 15 --out bench/out/amd-vulkan/20260607T122747Z/gemma64.node-package.warm.ir.claim.json`
- `python3 bench/gates/claim_gate.py --report bench/out/amd-vulkan/20260607T122747Z/gemma64.node-package.warm.ir.compare.json --claim-report bench/out/amd-vulkan/20260607T122747Z/gemma64.node-package.warm.ir.claim.json --require-comparison-status comparable --require-claim-status claimable --require-claimability-mode local --require-min-timed-samples 15 --config bench/native-compare/compare.config.amd.vulkan.gemma64.node-package.warm.ir.json`
- `python3 bench/gates/comparability_coherence_gate.py --report bench/out/amd-vulkan/20260607T122747Z/gemma64.node-package.warm.ir.compare.json --benchmark-policy config/benchmark-methodology-thresholds.json --require-pass --out bench/out/amd-vulkan/20260607T122747Z/gemma64.node-package.warm.ir.comparability-coherence.json`
- `python3 bench/gates/structural_equivalence_gate.py --report bench/out/amd-vulkan/20260607T122747Z/gemma64.node-package.warm.ir.compare.json --require-all-pass`
- `python3 bench/gates/timing_policy_gate.py --backend vulkan --report bench/out/amd-vulkan/20260607T122747Z/gemma64.node-package.warm.ir.compare.json`
- `python3 bench/cli.py compare bench/out/amd-vulkan/20260607T124149Z/gemma64.bun-package.warm.ir.workspace/run-artifacts/doe_gpu_bun_package_prepared/doe_gpu_bun_package_prepared-inference_gemma3_270m_prefill_64tok_decode_64tok-20260607T124149Z.run.json bench/out/amd-vulkan/20260607T124200Z/gemma64.bun-package.warm.ir.workspace/run-artifacts/bun_webgpu_package_prepared/bun_webgpu_package_prepared-inference_gemma3_270m_prefill_64tok_decode_64tok-20260607T124200Z.run.json --comparability strict --require-timing-class operation --benchmark-policy config/benchmark-methodology-thresholds.json --out bench/out/amd-vulkan/20260607T124200Z/gemma64.bun-package.warm.ir.compare.json`
- `python3 bench/cli.py claim bench/out/amd-vulkan/20260607T124200Z/gemma64.bun-package.warm.ir.compare.json --config bench/native-compare/compare.config.amd.vulkan.gemma64.bun-package.warm.ir.json --mode local --min-timed-samples 15 --benchmark-policy config/benchmark-methodology-thresholds.json --out bench/out/amd-vulkan/20260607T124200Z/gemma64.bun-package.warm.ir.claim.json`
- `python3 bench/gates/claim_gate.py --report bench/out/amd-vulkan/20260607T124200Z/gemma64.bun-package.warm.ir.compare.json --claim-report bench/out/amd-vulkan/20260607T124200Z/gemma64.bun-package.warm.ir.claim.json --require-comparison-status comparable --require-claim-status claimable --require-claimability-mode local --require-min-timed-samples 15 --config bench/native-compare/compare.config.amd.vulkan.gemma64.bun-package.warm.ir.json`
- `python3 bench/gates/comparability_coherence_gate.py --report bench/out/amd-vulkan/20260607T124200Z/gemma64.bun-package.warm.ir.compare.json --benchmark-policy config/benchmark-methodology-thresholds.json --require-pass --out bench/out/amd-vulkan/20260607T124200Z/gemma64.bun-package.warm.ir.comparability-coherence.json`
- `python3 bench/gates/structural_equivalence_gate.py --report bench/out/amd-vulkan/20260607T124200Z/gemma64.bun-package.warm.ir.compare.json --require-all-pass`
- `python3 bench/gates/timing_policy_gate.py --backend vulkan --report bench/out/amd-vulkan/20260607T124200Z/gemma64.bun-package.warm.ir.compare.json`
- `python3 browser/chromium/scripts/generate-browser-projection-manifest.py --workloads bench/workloads/specialized/workloads.amd.vulkan.superset.json`
- `npm --prefix browser/chromium ci`
- `python3 browser/chromium/scripts/run-browser-benchmark-superset.py --mode auto --chrome /usr/bin/google-chrome-stable`

## 2026-06-06 — AMD Vulkan repeat submit shape is receipt-visible

Native Vulkan repeated dispatch no longer silently splits one
`kernel_dispatch` command into 50-dispatch queue submissions. The repeat helper
now records the whole command repeat in one Vulkan command buffer and one queue
submit, preserving the selected-operation submit shape used by the Dawn delegate
path for independent matvec repeats.

Trace metadata now emits `executionSubmitCount` alongside
`executionDispatchCount`, and strict comparability treats submit-count mismatch
as a structural execution-shape failure when both sides report it. The
standalone structural-equivalence gate checks the same field. This prevents a
future row from passing as apples-to-apples when both sides dispatched the same
work but split it across different queue-submit shapes.

Follow-up:

- Owner: Doe runtime/bench. Split
  `bench/native_compare_modules/compare_assessment.py` before adding more
  obligations; the file is already past the Python tooling sharding threshold.
  Next split target: move execution-shape obligation collection/comparison into
  a focused `execution_shape.py` helper under `bench/native_compare_modules/`.

Fresh focused AMD Vulkan matvec evidence is comparable but diagnostic under
release claim policy; see the claim report for the current tail result.
A tighter focused rerun with the same strict policy also remains comparable and
diagnostic; see the tight claim report for the current selected-operation tail
result.

Artifacts:

- Focused compare report:
  `bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.20260607T033258Z.json`
- Focused claim report:
  `bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.20260607T033258Z.claim.json`
- Comparability-coherence gate result:
  `bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.20260607T033258Z.comparability-coherence.json`
- Doe run receipt:
  `bench/out/scratch/matvec-unroll4/20260607T033232Z/runtime-comparisons.amd.vulkan.matvec-unroll4/run-artifacts/doe/doe-compute_matvec_32768x2048_f32-20260607T033232Z.run.json`
- Dawn delegate run receipt:
  `bench/out/scratch/matvec-unroll4/20260607T033258Z/runtime-comparisons.amd.vulkan.matvec-unroll4/run-artifacts/dawn_delegate/dawn_delegate-compute_matvec_32768x2048_f32-20260607T033258Z.run.json`
- Tight focused compare report:
  `bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.tight.20260607T034640Z.json`
- Tight focused claim report:
  `bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.tight.20260607T034640Z.claim.json`
- Tight comparability-coherence gate result:
  `bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.tight.20260607T034640Z.comparability-coherence.json`
- Tight Doe run receipt:
  `bench/out/scratch/matvec-unroll4/20260607T034640Z/tight-runtime-comparisons/run-artifacts/doe/doe-compute_matvec_32768x2048_f32-20260607T034640Z.run.json`
- Tight Dawn delegate run receipt:
  `bench/out/scratch/matvec-unroll4/20260607T034640Z/tight-runtime-comparisons/run-artifacts/dawn_delegate/dawn_delegate-compute_matvec_32768x2048_f32-20260607T034640Z.run.json`

Validation:

- `python3 -m py_compile bench/native_compare_modules/compare_assessment.py bench/gates/structural_equivalence_gate.py bench/tests/test_compare_assessment.py`
- `python3 -m unittest bench.tests.test_compare_assessment`
- `python3 -m unittest bench.tests.test_compare_assessment bench.tests.test_compare_from_artifacts bench.tests.test_dawn_native_plan_executor bench.tests.test_doe_direct_plan_executor bench.tests.test_webgpu_plan_executor`
- `python3 bench/gates/schema_gate.py`
- `zig build test-wgsl`
- `zig build test`
- `zig build -Doptimize=ReleaseFast`
- `python3 bench/runners/preflight_bench_host.py --strict-amd-vulkan`
- `python3 bench/cli.py run-config --config bench/out/scratch/matvec-unroll4/compare.config.amd.vulkan.matvec-unroll4.json --side baseline`
- `python3 bench/cli.py run-config --config bench/out/scratch/matvec-unroll4/compare.config.amd.vulkan.matvec-unroll4.json --side comparison`
- `python3 bench/cli.py compare bench/out/scratch/matvec-unroll4/20260607T033232Z/runtime-comparisons.amd.vulkan.matvec-unroll4/run-artifacts/doe/doe-compute_matvec_32768x2048_f32-20260607T033232Z.run.json bench/out/scratch/matvec-unroll4/20260607T033258Z/runtime-comparisons.amd.vulkan.matvec-unroll4/run-artifacts/dawn_delegate/dawn_delegate-compute_matvec_32768x2048_f32-20260607T033258Z.run.json --comparability strict --require-timing-class operation --out bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.20260607T033258Z.json`
- `python3 bench/cli.py claim bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.20260607T033258Z.json --config bench/out/scratch/matvec-unroll4/compare.config.amd.vulkan.matvec-unroll4.json --out bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.20260607T033258Z.claim.json` (diagnostic exit)
- `python3 bench/gates/structural_equivalence_gate.py --report bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.20260607T033258Z.json --require-all-pass`
- `python3 bench/gates/comparability_coherence_gate.py --report bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.20260607T033258Z.json --require-pass --out bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.20260607T033258Z.comparability-coherence.json`
- `python3 bench/gates/claim_gate.py --report bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.20260607T033258Z.json --claim-report bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.20260607T033258Z.claim.json --require-comparison-status comparable --require-claim-status diagnostic --require-claimability-mode release --require-min-timed-samples 15 --config bench/out/scratch/matvec-unroll4/compare.config.amd.vulkan.matvec-unroll4.json --expected-workload-contract bench/workloads/workloads.amd.vulkan.json --require-workload-contract-hash --require-workload-id-set-match --require-backend-telemetry --expected-backend-id doe_vulkan`
- `python3 bench/gates/trace_gate.py --report bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.20260607T033258Z.json --semantic-parity-mode auto`
- `python3 bench/gates/timing_policy_gate.py --backend vulkan --report bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.20260607T033258Z.json`
- `python3 bench/gates/comparable_runtime_invariants_gate.py --report bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.20260607T033258Z.json`
- `python3 bench/gates/backend_selection_gate.py --report bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.20260607T033258Z.json`
- `python3 bench/gates/shader_artifact_gate.py --report bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.20260607T033258Z.json`
- `python3 bench/gates/spec_diff_gate.py`
- `python3 bench/gates/comparability_obligation_parity_gate.py`
- `python3 bench/cli.py run-config --config bench/out/scratch/matvec-unroll4/compare.config.amd.vulkan.matvec-unroll4.json --side baseline --warmup 8 --iterations 40 --timestamp 20260607T034640Z --workspace bench/out/scratch/matvec-unroll4/tight-runtime-comparisons --out bench/out/scratch/matvec-unroll4/tight-placeholder.json`
- `python3 bench/cli.py run-config --config bench/out/scratch/matvec-unroll4/compare.config.amd.vulkan.matvec-unroll4.json --side comparison --warmup 8 --iterations 40 --timestamp 20260607T034640Z --workspace bench/out/scratch/matvec-unroll4/tight-runtime-comparisons --out bench/out/scratch/matvec-unroll4/tight-placeholder.json`
- `python3 bench/cli.py compare bench/out/scratch/matvec-unroll4/20260607T034640Z/tight-runtime-comparisons/run-artifacts/doe/doe-compute_matvec_32768x2048_f32-20260607T034640Z.run.json bench/out/scratch/matvec-unroll4/20260607T034640Z/tight-runtime-comparisons/run-artifacts/dawn_delegate/dawn_delegate-compute_matvec_32768x2048_f32-20260607T034640Z.run.json --comparability strict --require-timing-class operation --out bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.tight.20260607T034640Z.json`
- `python3 bench/cli.py claim bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.tight.20260607T034640Z.json --config bench/out/scratch/matvec-unroll4/compare.config.amd.vulkan.matvec-unroll4.json --out bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.tight.20260607T034640Z.claim.json` (diagnostic exit)
- `python3 bench/gates/structural_equivalence_gate.py --report bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.tight.20260607T034640Z.json --require-all-pass`
- `python3 bench/gates/comparability_coherence_gate.py --report bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.tight.20260607T034640Z.json --require-pass --out bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.tight.20260607T034640Z.comparability-coherence.json`
- `python3 bench/gates/claim_gate.py --report bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.tight.20260607T034640Z.json --claim-report bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.tight.20260607T034640Z.claim.json --require-comparison-status comparable --require-claim-status diagnostic --require-claimability-mode release --require-min-timed-samples 15 --config bench/out/scratch/matvec-unroll4/compare.config.amd.vulkan.matvec-unroll4.json --expected-workload-contract bench/workloads/workloads.amd.vulkan.json --require-workload-contract-hash --require-workload-id-set-match --require-backend-telemetry --expected-backend-id doe_vulkan`
- `python3 bench/gates/trace_gate.py --report bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.tight.20260607T034640Z.json --semantic-parity-mode auto`
- `python3 bench/gates/timing_policy_gate.py --backend vulkan --report bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.tight.20260607T034640Z.json`
- `python3 bench/gates/comparable_runtime_invariants_gate.py --report bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.tight.20260607T034640Z.json`
- `python3 bench/gates/backend_selection_gate.py --report bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.tight.20260607T034640Z.json`
- `python3 bench/gates/shader_artifact_gate.py --report bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.tight.20260607T034640Z.json`

## 2026-06-06 — AMD Vulkan matvec repeat synchronization is explicit

Kernel dispatch replay now carries an explicit repeat-synchronization contract.
`kernel_dispatch` defaults to dependent repeats, and matvec replay fixtures mark
their repeated dispatches as independent so the Vulkan backend can preserve the
same dispatch count without inserting unnecessary inter-dispatch shader-memory
barriers.

The focused AMD Vulkan fairness audit now keeps host kernel prewarm outside
selected operation timing and prevents compute/pipeline rows from using
workload-unit wall as a fallback claim metric when selected operation timing
loses. The current two-row focused report is comparable; the known-good
concurrent compute row is claimable on selected operation timing, while the
naive matvec row remains diagnostic.

A follow-up matvec kernel-shape probe keeps the naive swizzle0 source on
row-base vector unroll, the best source variant from this probe set. The row is
still diagnostic under selected operation timing, so this is not a promotion.

Artifacts:

- Focused current-harness compare report:
  `bench/out/scratch/current-vulkan-fairness/dawn-vs-doe.amd.vulkan.current-fairness.fixed.json`
- Focused current-harness claim report:
  `bench/out/scratch/current-vulkan-fairness/dawn-vs-doe.amd.vulkan.current-fairness.fixed.claim.json`
- Focused row-base vector-unroll compare report:
  `bench/out/scratch/current-vulkan-fairness/dawn-vs-doe.amd.vulkan.current-fairness.rowbase-unroll4.json`
- Focused row-base vector-unroll claim report:
  `bench/out/scratch/current-vulkan-fairness/dawn-vs-doe.amd.vulkan.current-fairness.rowbase-unroll4.claim.json`
- Focused matvec repeat-shape compare report:
  `bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.final.json`
- Focused matvec repeat-shape claim report:
  `bench/out/scratch/matvec-unroll4/dawn-vs-doe.amd.vulkan.matvec-unroll4.final.claim.json`
- Focused matvec compare config:
  `bench/out/scratch/matvec-unroll4/compare.config.amd.vulkan.matvec-unroll4.json`
- Doe run receipt:
  `bench/out/scratch/matvec-unroll4/20260606T223256Z/runtime-comparisons.amd.vulkan.matvec-unroll4/run-artifacts/doe/doe-compute_matvec_32768x2048_f32-20260606T223256Z.run.json`
- Dawn delegate run receipt:
  `bench/out/scratch/matvec-unroll4/20260606T223327Z/runtime-comparisons.amd.vulkan.matvec-unroll4/run-artifacts/dawn_delegate/dawn_delegate-compute_matvec_32768x2048_f32-20260606T223327Z.run.json`

Validation:

- `python3 -m unittest bench.tests.test_claimability bench.tests.test_kernel_prewarm_timing`
- `zig build test-wgsl`
- `zig build -Doptimize=ReleaseFast -Dlean-verified=true`
- `python3 bench/gates/schema_gate.py`
- `python3 bench/gates/comparability_obligation_parity_gate.py`
- `python3 bench/gates/doe_private_strategy_leak_gate.py`
- `python3 bench/tools/generate_backend_workloads.py --verify`
- `python3 bench/gates/spirv_val_gate.py --spirv-val /usr/bin/spirv-val --compile --discover-wgsl --require --emit-spirv-bin runtime/zig/zig-out/bin/doe-emit-spirv`
- `spirv-val bench/kernels/matrix_vector_mul_32768x2048_f32_naive_swizzle0.spv`
- `bash pipeline/lean/check.sh && bash pipeline/lean/extract.sh`
- `zig build test -Doptimize=ReleaseFast`

## 2026-06-06 — AMD Vulkan repeat-dispatch refresh leaves naive matvec as blocker

Native Vulkan repeated kernel dispatch now records bounded dispatch batches with
compute memory barriers between repeats, preserving dispatch-count semantics
while avoiding per-repeat submit/wait inflation. Compute-write visibility for
buffer capture moved out of the hot dispatch path into the capture path.

The AMD Vulkan release refresh was rerun from receipt-first artifacts with the
rebuilt runtime. The refreshed claim artifact is comparable but diagnostic; the
remaining non-claimable workload is `compute_matvec_32768x2048_f32`. The
prewarm-provenance claim interpretation used for the refresh was superseded by
the current focused-harness audit above: host kernel prewarm is diagnostic
outside selected operation timing, and compute/pipeline claims stay on selected
operation timing.

Artifacts:

- Full refreshed compare report:
  `bench/out/amd-vulkan/20260606T192207Z/dawn-vs-doe.amd.vulkan.release.refresh.json`
- Full refreshed claim report:
  `bench/out/amd-vulkan/20260606T192207Z/dawn-vs-doe.amd.vulkan.release.refresh.claim.json`
- Focused prewarm blocker compare report:
  `bench/out/amd-vulkan/20260606T191535Z/dawn-vs-doe.amd.vulkan.repeat-blockers.json`
- Focused prewarm blocker claim report:
  `bench/out/amd-vulkan/20260606T191535Z/dawn-vs-doe.amd.vulkan.repeat-blockers.claim.json`
- Prior full release claim reinterpreted with the prewarm provenance rule:
  `bench/out/amd-vulkan/20260606T183804Z/dawn-vs-doe.amd.vulkan.release.post-prewarm-claim.json`

Validation:

- `zig build -Doptimize=ReleaseFast`
- `env PYTHONPATH=bench:. python3 -m unittest bench.tests.test_claimability bench.tests.test_kernel_prewarm_timing bench.tests.test_report_conformance bench.tests.test_compare_from_artifacts`

## 2026-06-01 — Package queue prefix receipts classify measurement stability

The package dispatch-prefix profiler now writes an explicit
`stabilityDiagnostics` block. Each primary nanosecond summary records dispersion
ratios, and the top-level diagnostics classify full-plan and dispatch-prefix
measurements as stable, unstable, or insufficient-sample. This turns noisy
package rows into receipt-visible evidence instead of relying on ad-hoc median
inspection before changing runtime policy.

Fresh Node and Bun queue-submit completion receipts were generated with the new
diagnostics. The Node receipt classifies the measured queue row as stable in the
current window; the Bun receipt keeps the noisy row visible as unstable, which
matches the earlier readback-policy non-promotion decision.

Artifacts:

- Node queue stability prefix receipt:
  `bench/out/apple-metal/20260601T005018Z_package_queue_stability_receipts/node-doe-queue-stability.prefix-profile.json`
- Bun queue stability prefix receipt:
  `bench/out/apple-metal/20260601T005018Z_package_queue_stability_receipts/bun-doe-queue-stability.prefix-profile.json`
- Prefix profile tool:
  `bench/tools/package_dispatch_prefix_profile.mjs`
- Prefix profile schema and sample:
  `config/package-dispatch-prefix-profile.schema.json` and
  `examples/package-dispatch-prefix-profile.sample.json`

Validation:

- `node --check bench/tools/package_dispatch_prefix_profile.mjs`
- `python3 -m unittest bench.tests.test_package_dispatch_prefix_profile`
- `python3 bench/gates/schema_gate.py`
- Direct schema validation of the generated prefix profiles and package trace
  metadata under
  `bench/out/apple-metal/20260601T005018Z_package_queue_stability_receipts/`

## 2026-06-01 — Bun queue readback policy kept on mapAsync after stability probe

The Bun FFI queue-submit completion row was re-tested with the policy
`mapAsync` path and the forced native map/read/copy/unmap path. A first paired
probe favored native readback, but the confirmation window contradicted that
result at the full-plan level. The package policy therefore keeps the Bun FFI
queue row on `mapAsync` instead of promoting the narrower native-readback win.

The dispatch-prefix profiler now emits dispersion diagnostics on every
nanosecond summary. This makes noisy promotion candidates visible inside the
receipt itself instead of requiring an ad-hoc side analysis.

Artifacts:

- Bun queue readback first paired probe:
  `bench/out/apple-metal/20260601T004218Z_bun_queue_readback_mode_probe/bun-doe-policy.prefix-profile.json`
  and
  `bench/out/apple-metal/20260601T004218Z_bun_queue_readback_mode_probe/bun-doe-native-readback.prefix-profile.json`
- Bun queue readback confirmation probe:
  `bench/out/apple-metal/20260601T004419Z_bun_queue_policy_native_vs_mapasync_confirm/bun-doe-policy-native.prefix-profile.json`
  and
  `bench/out/apple-metal/20260601T004419Z_bun_queue_policy_native_vs_mapasync_confirm/bun-doe-forced-mapasync.prefix-profile.json`
- Bun queue readback stability-diagnostic receipt with dispersion fields:
  `bench/out/apple-metal/20260601T004626Z_bun_queue_readback_stability_diagnostics/bun-doe-policy-mapasync.prefix-profile.json`
  and
  `bench/out/apple-metal/20260601T004626Z_bun_queue_readback_stability_diagnostics/bun-doe-forced-native.prefix-profile.json`
- Policy file:
  `config/package-execution-policy.json`
- Prefix profile schema:
  `config/package-dispatch-prefix-profile.schema.json`

Validation:

- `node --check bench/tools/package_dispatch_prefix_profile.mjs`
- Direct schema validation of the new prefix profiles and package trace
  metadata under
  `bench/out/apple-metal/20260601T004626Z_bun_queue_readback_stability_diagnostics/`
- Direct schema validation of `config/package-execution-policy.json`

## 2026-06-01 — Node and Bun package receipts carry native fast-path identity

The `doe-gpu` Bun condition entry now exports `nativeFastPathInfo()` alongside
Node, and the Bun FFI provider includes the same native fast-path identity in
`providerInfo()`. Package executor trace metadata and dispatch-prefix profile
samples now carry `packageNativeFastPaths`, so Node and Bun receipts can prove
which queue, dispatch, batch, and readback native symbols were available during
the measured run.

Fresh Node and Bun queue-submit completion prefix profiles were generated from
the same package workload. They are diagnostic package receipts, not a broad
speed claim; use the artifact phase breakdowns and fast-path counters to inspect
the current per-host path.

Artifacts:

- Node package native fast-path identity prefix receipt:
  `bench/out/apple-metal/20260601T003753Z_package_native_fastpath_identity/node-doe-queue-nativefast.prefix-profile.json`
- Bun package native fast-path identity prefix receipt:
  `bench/out/apple-metal/20260601T003753Z_package_native_fastpath_identity/bun-doe-queue-nativefast.prefix-profile.json`
- Bun runtime fast-path export:
  `packages/doe-gpu/src/vendor/webgpu/bun.js`
- Bun FFI fast-path symbol identity:
  `packages/doe-gpu/src/vendor/webgpu/bun-ffi.js`
- Package executor trace metadata:
  `bench/executors/node-webgpu/executor.js`
- Trace metadata schema coverage:
  `config/trace-meta.schema.json`

Validation:

- `node --check packages/doe-gpu/src/vendor/webgpu/bun-ffi.js`
- `node --check packages/doe-gpu/src/vendor/webgpu/bun.js`
- `node --check packages/doe-gpu/src/bun.js`
- `node --check bench/executors/node-webgpu/executor.js`
- `node --check bench/tools/package_dispatch_prefix_profile.mjs`
- `python3 -m unittest bench.tests.test_node_webgpu_executor bench.tests.test_package_dispatch_prefix_profile`
- `npm run test:smoke`
- `npm run test:integration`
- `npm run test:integration:bun`
- `python3 bench/gates/schema_gate.py`
- Direct schema validation of the generated package trace metadata under
  `bench/out/apple-metal/20260601T003753Z_package_native_fastpath_identity/`

## 2026-05-31 — Node package native fast-path diagnostics identify the real queue bottleneck

The `doe-gpu` package surface now exposes native fast-path availability through
`nativeFastPathInfo()` and includes the same data in `providerInfo()`. This
distinguishes missing native symbols from a path that is available but not a
completion win, which matters for the Node/Bun developer wedge and for receipt
debugging on source-built addons.

The latest Node queue-submit receipts show the current fast path remains native
dispatch-copy command-buffer construction followed by native readback
flush-and-map. A submit-batched dispatch-copy completion experiment and a Metal
shared-event wait experiment were both measured and not promoted; the artifacts
keep the rejected candidates separate from the current path. The named
bottleneck remains the readback queue-completion phase in the current receipt.

Artifacts:

- Current rebuilt native-command-buffer receipt:
  `bench/out/apple-metal/20260531T_node_package_native_cb_rebuilt_current/node-doe-queue-native-cb.prefix-profile.json`
- Submit-batched completion experiment:
  `bench/out/apple-metal/20260531T_node_package_dispatch_flush_postflush_current/node-doe-queue-dispatch-flush.prefix-profile.json`
- Metal shared-event wait experiment:
  `bench/out/apple-metal/20260531T_node_package_shared_event_wait_current/node-doe-queue-shared-event-wait.prefix-profile.json`
- Native fast-path package export:
  `packages/doe-gpu/src/vendor/webgpu/index.js`

Validation:

- `npm run build:addon`
- `zig build dropin -Doptimize=ReleaseFast`
- `python3 -m unittest bench.tests.test_node_webgpu_executor bench.tests.test_package_dispatch_prefix_profile`

## 2026-05-31 — Node package fast-path counters now flow into prefix receipts

The Node `doe-gpu` package surface now exports `fastPathStats`, matching the
Bun package visibility used by package receipts. The counters cover native
command-buffer construction, combined flush-and-map readback, and native
dispatch-flush evidence when the submit breakdown proves the completed flush.
The prefix profiler now carries `packageFastPathStats` and
`packageReadbackMode` into each sample, so Node package artifacts can identify
which runtime path actually fired without scraping trace metadata sidecars.

Fresh Node queue-submit/readback prefix receipts were generated for the default
native readback path and the forced `mapAsync` probe. They confirm that the
Node full-plan path is using native command-buffer construction plus
flush-and-map readback; the next package bottleneck remains the readback
completion phase named in the artifact phase breakdowns.

Artifacts:

- Node package default readback fast-path prefix receipt:
  `bench/out/apple-metal/20260531T_node_package_fastpath_stats_current/node-doe-queue-fastpath.prefix-profile.json`
- Node package forced-`mapAsync` fast-path prefix receipt:
  `bench/out/apple-metal/20260531T_node_package_fastpath_stats_mapasync/node-doe-queue-fastpath-mapasync.prefix-profile.json`
- Updated prefix profile schema:
  `config/package-dispatch-prefix-profile.schema.json`

Validation:

- `python3 -m unittest bench.tests.test_node_webgpu_executor bench.tests.test_package_dispatch_prefix_profile`
- `python3 bench/gates/schema_gate.py`

## 2026-05-31 — Node package dispatch-prefix profile now ranks terminal residuals

The package dispatch-prefix profiler now emits readback summaries, adjacent
prefix delta rankings, and full-plan phase residual rankings. The explicit Node
resident decode lane has fresh Doe-backed, forced-`mapAsync` Doe-backed, and
Dawn-backed `node-webgpu` prefix profiles. The diagnostic window confirms the
terminal readback phase is the named residual to optimize next; the forced
`mapAsync` profile remains diagnostic and does not promote a Node resident
decode readback policy because the earlier no-env policy verification did not
hold.

Artifacts:

- Prefix-profile schema and sample:
  `config/package-dispatch-prefix-profile.schema.json` and
  `examples/package-dispatch-prefix-profile.sample.json`
- Doe-backed Node resident decode prefix profile:
  `bench/out/apple-metal/20260531T_node_package_dispatch_prefix_profile/node-doe.prefix-profile.json`
- Forced-`mapAsync` Doe-backed Node resident decode prefix profile:
  `bench/out/apple-metal/20260531T_node_package_dispatch_prefix_profile/node-doe-mapasync.prefix-profile.json`
- Dawn-backed `node-webgpu` resident decode prefix profile:
  `bench/out/apple-metal/20260531T_node_package_dispatch_prefix_profile/node-webgpu.prefix-profile.json`

## 2026-05-31 — Node package resident decode has explicit Doe-vs-Dawn config

The Apple Metal resident decode package lane now has an explicit Node package
config for Doe-backed WebGPU vs Dawn-backed `node-webgpu`, separate from the
native-direct Node lane. The default no-env run is comparable but diagnostic;
Doe's selected timing is still gated by terminal readback and submit wrapper
work. A forced `mapAsync` readback probe was also run against the same
comparison receipt, but the no-env policy verification contradicted that probe,
so no new Node decode readback policy was promoted.

Artifacts:

- Explicit Node package resident decode config:
  `bench/native-compare/compare.config.apple.metal.gemma270m.node-package.decode.resident.warm.ir.json`
- Default explicit Node package resident decode diagnostic:
  `bench/out/apple-metal/20260531T_node_package_explicit_config/node-package-explicit.compare.json`
  and
  `bench/out/apple-metal/20260531T_node_package_explicit_config/node-package-explicit.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T_node_package_explicit_config/node-package-explicit.phase-delta.json`
- Forced `mapAsync` probe:
  `bench/out/apple-metal/20260531T_node_package_explicit_mapasync/node-package-mapasync.compare.json`
  and
  `bench/out/apple-metal/20260531T_node_package_explicit_mapasync/node-package-mapasync.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T_node_package_explicit_mapasync/node-package-mapasync.phase-delta.json`
- No-env policy verification that blocked promotion:
  `bench/out/apple-metal/20260531T_node_package_policy_mapasync_decode/node-package-policy-mapasync.compare.json`
  and
  `bench/out/apple-metal/20260531T_node_package_policy_mapasync_decode/node-package-policy-mapasync.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T_node_package_policy_mapasync_decode/node-package-policy-mapasync.phase-delta.json`

## 2026-05-31 — Bun FFI prepared package pack has claimable symmetric coverage receipts

The strict compare timing-plausibility obligation now distinguishes asymmetric
operation-wall undercoverage from symmetric low operation coverage. Symmetric
low coverage stays visible in the obligation details and remains comparable;
one-sided or high-asymmetry low coverage still blocks strict comparison.

The refreshed Bun FFI prepared package-developer pack is a local claim for the
named package workloads only. It does not broaden the resident decode claim or
publish a fastest-everywhere runtime claim.

The package execution policy now selects `mapAsync` readback for the Bun FFI
prepared package-developer workloads covered by the policy evidence. The
canonical no-env policy rerun is comparable and claimable for that named pack,
and the Doe-side run receipts record the selected readback mode directly in
trace metadata.

The same readback policy is now promoted for the Node `doe-gpu` package path
on the prepared package-developer pack. The pre-policy Node package receipt
remains diagnostic because the queue-submit micro workload loses on selected
timing; the no-env policy rerun is comparable and claimable, with Doe-side
receipts recording `mapAsync`.

The Bun FFI submit path now keeps native submit phase breakdown behind the
`DOE_WEBGPU_SUBMIT_BREAKDOWN=1` diagnostic flag instead of taking breakdown
symbols on the default package path. The default path still records wrapper
and addon-call submit timing, while diagnostic runs can opt into native replay,
submit, flush, and wait attribution. Bun FFI shader creation also caches encoded
WGSL bytes for repeated source strings before entering the native flat create
helper.

The public Bun entry now prefers the Bun FFI backend on macOS and Linux when
the native library loads, with `DOE_BUN_WEBGPU_BACKEND=full` available to force
the full path. Public Bun also re-exports FFI fast-path counters so install-path
receipts can show dispatch/readback fast-path use. The current public Bun
prepared package-developer reruns are diagnostic, not promoted claims, because
the small queue/readback rows still need stabilization on this lane.

The public-vs-direct Bun FFI vector diagnostic now has a swapped-order
order-sensitivity receipt. That receipt makes the current intra-Doe public
wrapper comparison diagnostic-only until the order-sensitive phases are
controlled; stable package-vs-competitor claims still need the regular compare,
claim, and phase attribution artifacts.

The public Bun readback policy is now workload-scoped from install-path
receipts: the buffer upload/readback row stays on `mapAsync`, while the image,
queue-submit, and vector rows use native map/read/copy/unmap on this Apple
Metal lane. The same-window public-vs-`bun-webgpu` rerun remains diagnostic,
so this is an install-path optimization policy update rather than a promoted
public Bun speed claim.

The resident decode diagnostics also now reduce repeated small readback digest
work across samples, avoid duplicate tiny-readback decode/object-filtering in
capture summaries, and emit `packageFastPathStats` so submit-path receipts show
which Bun FFI fast paths fired. The follow-up resident decode reruns are
diagnostic because selected timing remains dominated by submit/readback wait
variance in those samples.

Artifacts:

- Bun FFI prepared package-developer digest claim:
  `bench/out/apple-metal/20260531T_after_digest_cache/package-developer.bun-ffi.prepared.digest.compare.json`
  and
  `bench/out/apple-metal/20260531T_after_digest_cache/package-developer.bun-ffi.prepared.digest.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T_after_digest_cache/package-developer.bun-ffi.prepared.digest.phase-delta.json`
- Bun FFI prepared package-developer mapAsync policy claim:
  `bench/out/apple-metal/20260531T_policy_readback_mapasync/package-developer.bun-ffi.prepared.policy-mapasync.compare.json`
  and
  `bench/out/apple-metal/20260531T_policy_readback_mapasync/package-developer.bun-ffi.prepared.policy-mapasync.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T_policy_readback_mapasync/package-developer.bun-ffi.prepared.policy-mapasync.phase-delta.json`
- Bun FFI prepared package-developer submit-breakdown opt-out claim:
  `bench/out/apple-metal/20260531T_submit_breakdown_optout/package-developer.bun-ffi.prepared.submit-fast.compare.json`
  and
  `bench/out/apple-metal/20260531T_submit_breakdown_optout/package-developer.bun-ffi.prepared.submit-fast.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T_submit_breakdown_optout/package-developer.bun-ffi.prepared.submit-fast.phase-delta.json`
- Bun FFI submit-breakdown off/on diagnostic:
  `bench/out/apple-metal/20260531T_submit_breakdown_ab/package-developer.bun-ffi.prepared.breakdown-off-vs-on.phase-delta.json`
- Public Bun prepared package path before FFI default:
  `bench/out/apple-metal/20260531T_bun_public_package_current/package-developer.bun.prepared.compare.json`
  and
  `bench/out/apple-metal/20260531T_bun_public_package_current/package-developer.bun.prepared.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T_bun_public_package_current/package-developer.bun.prepared.phase-delta.json`
- Public Bun prepared FFI-default diagnostics:
  `bench/out/apple-metal/20260531T_bun_public_ffi_default/package-developer.bun.prepared.ffi-default.compare.json`
  and
  `bench/out/apple-metal/20260531T_bun_public_ffi_default/package-developer.bun.prepared.ffi-default.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T_bun_public_ffi_default/package-developer.bun.prepared.ffi-default.phase-delta.json`
- Public Bun FFI fast-path counter smoke:
  `bench/out/apple-metal/20260531T_bun_public_fastpath_stats/20260531T132859Z/package-queue.public-ffi.baseline.workspace/run-artifacts/doe_gpu_bun_package_prepared/doe_gpu_bun_package_prepared-package_queue_submit_completion-20260531T132859Z.run.json`
- Public Bun vs direct Bun FFI order-sensitivity diagnostic:
  `bench/out/apple-metal/20260531T_bun_public_vs_ffi_order_sensitivity/package-vector.public-vs-ffi.order-sensitivity.json`
- Public Bun readback mode A/B and same-window competitor diagnostics:
  `bench/out/apple-metal/20260531T_public_readback_mode_ab/public-bun.mapasync-vs-native.phase-delta.json`,
  `bench/out/apple-metal/20260531T_public_readback_mode_ab/public-bun.mapasync-vs-bun-webgpu.compare.json`,
  `bench/out/apple-metal/20260531T_public_readback_mode_ab/public-bun.mapasync-vs-bun-webgpu.claim.json`,
  `bench/out/apple-metal/20260531T_public_readback_mode_ab/public-bun.mapasync-vs-bun-webgpu.phase-delta.json`,
  `bench/out/apple-metal/20260531T_public_readback_mode_ab/public-bun.native-vs-bun-webgpu.compare.json`,
  `bench/out/apple-metal/20260531T_public_readback_mode_ab/public-bun.native-vs-bun-webgpu.claim.json`,
  and
  `bench/out/apple-metal/20260531T_public_readback_mode_ab/public-bun.native-vs-bun-webgpu.phase-delta.json`
- Public Bun readback policy split smoke receipts:
  `bench/out/apple-metal/20260531T_public_readback_policy_split/queue.workspace/run-artifacts/doe/doe-package_queue_submit_completion-20260531T135402Z.run.json`
  and
  `bench/out/apple-metal/20260531T_public_readback_policy_split/buffer.workspace/run-artifacts/doe/doe-package_buffer_upload_readback_1mb-20260531T135402Z.run.json`
- Public Bun no-env policy split diagnostic:
  `bench/out/apple-metal/20260531T_public_policy_split_compare/public-bun.policy-split-vs-bun-webgpu.compare.json`,
  `bench/out/apple-metal/20260531T_public_policy_split_compare/public-bun.policy-split-vs-bun-webgpu.claim.json`,
  and
  `bench/out/apple-metal/20260531T_public_policy_split_compare/public-bun.policy-split-vs-bun-webgpu.phase-delta.json`
- Node package prepared pre-policy diagnostic:
  `bench/out/apple-metal/20260531T_node_package_prepared_current/package-developer.node.prepared.compare.json`
  and
  `bench/out/apple-metal/20260531T_node_package_prepared_current/package-developer.node.prepared.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T_node_package_prepared_current/package-developer.node.prepared.phase-delta.json`
- Node package prepared mapAsync policy claim:
  `bench/out/apple-metal/20260531T_node_package_policy_mapasync/package-developer.node.prepared.policy-mapasync.compare.json`
  and
  `bench/out/apple-metal/20260531T_node_package_policy_mapasync/package-developer.node.prepared.policy-mapasync.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T_node_package_policy_mapasync/package-developer.node.prepared.policy-mapasync.phase-delta.json`
- Bun FFI prepared package-developer mapAsync policy baseline receipts:
  `bench/out/apple-metal/20260531T_policy_readback_mapasync/20260531T130209Z/package-developer.bun-ffi.prepared.policy-mapasync.baseline.workspace/run-artifacts/doe_gpu_bun_package_ffi_prepared/doe_gpu_bun_package_ffi_prepared-package_buffer_upload_readback_1mb-20260531T130209Z.run.json`,
  `bench/out/apple-metal/20260531T_policy_readback_mapasync/20260531T130209Z/package-developer.bun-ffi.prepared.policy-mapasync.baseline.workspace/run-artifacts/doe_gpu_bun_package_ffi_prepared/doe_gpu_bun_package_ffi_prepared-package_image_rgba_invert_1024-20260531T130209Z.run.json`,
  `bench/out/apple-metal/20260531T_policy_readback_mapasync/20260531T130209Z/package-developer.bun-ffi.prepared.policy-mapasync.baseline.workspace/run-artifacts/doe_gpu_bun_package_ffi_prepared/doe_gpu_bun_package_ffi_prepared-package_queue_submit_completion-20260531T130209Z.run.json`,
  and
  `bench/out/apple-metal/20260531T_policy_readback_mapasync/20260531T130209Z/package-developer.bun-ffi.prepared.policy-mapasync.baseline.workspace/run-artifacts/doe_gpu_bun_package_ffi_prepared/doe_gpu_bun_package_ffi_prepared-package_vector_scale_add_262k-20260531T130209Z.run.json`
- Bun FFI resident decode process digest-cache diagnostic:
  `bench/out/apple-metal/20260531T_after_process_digest_cache/gemma270m.bun-ffi.decode.resident.process-digest.compare.json`
  and
  `bench/out/apple-metal/20260531T_after_process_digest_cache/gemma270m.bun-ffi.decode.resident.process-digest.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T_after_process_digest_cache/gemma270m.bun-ffi.decode.resident.process-digest.phase-delta.json`
- Bun FFI resident decode capture-object diagnostic:
  `bench/out/apple-metal/20260531T_after_capture_object_fast/gemma270m.bun-ffi.decode.resident.capture-object.compare.json`
  and
  `bench/out/apple-metal/20260531T_after_capture_object_fast/gemma270m.bun-ffi.decode.resident.capture-object.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T_after_capture_object_fast/gemma270m.bun-ffi.decode.resident.capture-object.phase-delta.json`
- Bun FFI resident fast-path counter smoke:
  `bench/out/apple-metal/20260531T_after_fastpath_stats/20260531T125046Z/gemma270m.bun-ffi.decode.resident.fastpath-stats.baseline.workspace/run-artifacts/doe_gpu_bun_package_ffi_prepared_resident/doe_gpu_bun_package_ffi_prepared_resident-inference_gemma3_270m_decode_1tok-20260531T125046Z.run.json`

## 2026-05-31 — Bun FFI resident decode receipts split readback capture cost

Package trace-meta now records `readbackCaptureTotalNs` inside
`packageStepBreakdownNs`, and the package phase-delta tool groups it under
readback harness cost. The executor also caches exact small readback digests
inside a timed sample so repeated identical captures still emit per-repeat
receipt entries without rehashing the same bytes every cycle.

The refreshed Bun FFI resident decode run is a local claim for the exact
Gemma 270M prepared resident decode contract only. It is not a blanket
Bun/Node package claim, and the phase report still keeps submit/readback
internals visible as the next tuning target.

Artifacts:

- Bun FFI resident decode readback-capture diagnostic before digest caching:
  `bench/out/apple-metal/20260531T_after_readback_capture/gemma270m.bun-ffi.decode.resident.capture.compare.json`
  and
  `bench/out/apple-metal/20260531T_after_readback_capture/gemma270m.bun-ffi.decode.resident.capture.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T_after_readback_capture/gemma270m.bun-ffi.decode.resident.capture.phase-delta.json`
- Bun FFI resident decode digest-cache claim:
  `bench/out/apple-metal/20260531T_after_digest_cache/gemma270m.bun-ffi.decode.resident.digest.compare.json`
  and
  `bench/out/apple-metal/20260531T_after_digest_cache/gemma270m.bun-ffi.decode.resident.digest.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T_after_digest_cache/gemma270m.bun-ffi.decode.resident.digest.phase-delta.json`

## 2026-05-31 — Bun FFI resident decode lane has explicit batch policy and pointer-list write ABI

The Bun FFI package lane now has a resident decode compare config,
`bench/native-compare/compare.config.apple.metal.gemma270m.bun-ffi.decode.resident.warm.ir.json`,
which compares `doe-gpu/bun-ffi` against Bun WebGPU without changing the
public Bun package default.

The drop-in dylib exports `doeNativeQueueWriteBufferBatchDataPtrs` alongside
the compact contiguous-data batch ABI. Bun FFI uses the pointer-list ABI when
available so native batching can avoid copying each batch into a temporary
payload buffer. The package executor also reads `config/package-execution-policy.json`
for write-batching policy; the current Bun FFI policy keeps small resident
decode write groups on direct writes and reserves the hidden batch method for
larger consecutive write groups.

Current resident decode evidence is diagnostic, not a promoted speed claim:
the trace shows correct token readback and explicit write-batching attribution,
while selected timing is still gated by submit/readback phases.

Artifacts:

- Bun FFI compact-batch diagnostic:
  `bench/out/apple-metal/20260531T114620Z/gemma270m.bun-ffi.decode.resident.warm.compact-batch.compare.json`
  and
  `bench/out/apple-metal/20260531T114620Z/gemma270m.bun-ffi.decode.resident.warm.compact-batch.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T114620Z/gemma270m.bun-ffi.decode.resident.warm.compact-batch.phase-delta.json`
- Bun FFI pointer-list batch diagnostic:
  `bench/out/apple-metal/20260531T115148Z/gemma270m.bun-ffi.decode.resident.warm.ptr-batch.compare.json`
  and
  `bench/out/apple-metal/20260531T115148Z/gemma270m.bun-ffi.decode.resident.warm.ptr-batch.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T115148Z/gemma270m.bun-ffi.decode.resident.warm.ptr-batch.phase-delta.json`
- Bun FFI policy-gated resident decode diagnostic:
  `bench/out/apple-metal/20260531T115907Z/gemma270m.bun-ffi.decode.resident.warm.submit-array.compare.json`
  and
  `bench/out/apple-metal/20260531T115907Z/gemma270m.bun-ffi.decode.resident.warm.submit-array.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T115907Z/gemma270m.bun-ffi.decode.resident.warm.submit-array.phase-delta.json`
- Bun FFI prepared package-developer claim:
  `bench/out/apple-metal/20260531T120415Z/package-developer.bun-ffi.prepared.policy.compare.json`
  and
  `bench/out/apple-metal/20260531T120415Z/package-developer.bun-ffi.prepared.policy.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T120415Z/package-developer.bun-ffi.prepared.policy.phase-delta.json`

## 2026-05-31 — Browser layered score shows paired mode scores and texture phase timing

The browser layered score sidecar now reports paired baseline/comparison mode
scores plus comparison percent delta instead of presenting a single
baseline-index number as the headline. The score sidecar keeps the legacy
relative `score` field for compatibility, but the CLI and schema expose the
paired mode fields for row, category, row-weighted overall, and
category-balanced overall summaries.

Focused browser diagnostics can carry a category `workloadFilter`; the checker
validates isolated category reports, rejects rows outside the selected filter,
and accepts cross-category reports that combine L1 browser API rows with L2
visual page rows. Texture L1 scenarios now emit sampled `textureMs` plus
phase-level timing summaries so the score can measure the texture path
separately from adapter/device startup while preserving total `elapsedMs` as
evidence.

The browser lane now has separate local wrappers for stock Chrome vs Fawn
consumer diagnostics and same-Fawn-binary Dawn vs Doe runtime isolation:
`browser/chromium/scripts/run-consumer-bench.sh` and
`browser/chromium/scripts/run-fawn-runtime-bench.sh`.

Artifacts:

- Focused texture/visual diagnostic and score:
  `browser/chromium/artifacts/20260531T114730Z/chrome-vs-fawn.browser-layered.superset.diagnostic.json`
  and
  `browser/chromium/artifacts/20260531T114730Z/chrome-vs-fawn.browser-layered.superset.score.json`

## 2026-05-31 — Bun FFI package lane split from public Bun default

The Bun package benchmark runner now has an explicit diagnostic provider id,
`doe-ffi`, which imports `packages/doe-gpu/src/vendor/webgpu/bun-ffi.js`
directly. Registry executors `doe_bun_package_ffi` and
`doe_bun_package_ffi_prepared` let the FFI lane run through normal
`bench/cli.py run`, compare, claim, and phase-delta flows. This section records
the split before the later public Bun default moved to FFI on supported native
hosts.

The drop-in dylib now exports
`doeNativeCreateComputeDispatchCopyCommandBufferOneBindGroup` for the common
Bun FFI shape where a lazy dispatch+copy command buffer carries a single bind
group. The JS FFI path uses that helper before falling back to the generic
bind-group pointer-array helper.

The Bun FFI setup path also has flat native helpers for buffer creation, WGSL
shader module creation, main-entry compute pipeline creation, buffer-only bind
group layout creation, buffer-only bind group creation, and single-layout
pipeline layout creation. Bun FFI now uses structured create errors instead of
running native shader preflight on every `GPUDevice.createShaderModule` call.
The native shader path now keeps process-local WGSL shader-module metadata for
long-lived Bun/Node processes, and the buffer-only bind group layout fast path
stores its small layout entries inline in the native layout object.
The shared package WebGPU surface now also bypasses generic bind-group layout
and bind-group normalization for small buffer-only descriptor shapes when the
backend exposes flat helpers. Bun FFI uses that shared fast path and now keeps
lazy dispatch+copy command buffers batched through `finish()` so `queue.submit()`
can use the native direct-flush path. Bun FFI also prefers Doe's native
`queueWriteBuffer` entrypoint when the symbol is available, keeping package
uploads inside the Doe runtime path.
The flat readback helper now performs queue synchronization, deferred copy or
resolve draining, map/copy/unmap, and breakdown capture inside one native call.
The shared-memory direct-copy experiment remains diagnostic-only and is not part
of the current package path.
Bun FFI direct single-dispatch and batch-dispatch submit now have native phase
attribution for command replay, command submit, queue flush, wait, and
deferred-copy work.
Direct dispatch+copy submission keeps queue completion pending until
`onSubmittedWorkDone`, map, or readback drains the queue, so package receipts
attribute completion waits to the explicit wait/readback phase instead of
silently completing at submit.
The `gpu.compute` helper now relies on the package map/readback drain and uses
the native map-read-copy-unmap fast path when available, avoiding an extra
helper-level queue wait before readback.

Artifacts:

- Public macOS Bun package cold:
  `bench/out/apple-metal/20260531T000734Z/apple.metal.package-developer.bun.public.macos-full.compare.json`
  and
  `bench/out/apple-metal/20260531T000734Z/apple.metal.package-developer.bun.public.macos-full.claim.json`
- Public macOS Bun package async-submit cold:
  `bench/out/apple-metal/20260531T020936Z/apple.metal.package-developer.bun.public-async-submit.compare.json`
  and
  `bench/out/apple-metal/20260531T020936Z/apple.metal.package-developer.bun.public-async-submit.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T020936Z/apple.metal.package-developer.bun.public-async-submit.phase-delta.json`
- Public macOS Bun package prepared:
  `bench/out/apple-metal/20260531T000819Z/apple.metal.package-developer.bun.public.macos-full.prepared.compare.json`
  and
  `bench/out/apple-metal/20260531T000819Z/apple.metal.package-developer.bun.public.macos-full.prepared.claim.json`
- Bun FFI one-bind-group cold diagnostics:
  `bench/out/apple-metal/20260531T001955Z/apple.metal.package-developer.bun.ffi-one-bg.claim-floor.compare.json`
  and
  `bench/out/apple-metal/20260531T001955Z/apple.metal.package-developer.bun.ffi-one-bg.claim-floor.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T001955Z/apple.metal.package-developer.bun.ffi-one-bg.claim-floor.phase-delta.json`
- Bun FFI one-bind-group prepared:
  `bench/out/apple-metal/20260531T002122Z/apple.metal.package-developer.bun.ffi-one-bg.prepared.compare.json`
  and
  `bench/out/apple-metal/20260531T002122Z/apple.metal.package-developer.bun.ffi-one-bg.prepared.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T002122Z/apple.metal.package-developer.bun.ffi-one-bg.prepared.phase-delta.json`
- Bun FFI flat setup with create-preflight removed:
  `bench/out/apple-metal/20260531T004030Z/apple.metal.package-developer.bun.ffi-flat-setup-no-preflight.compare.json`
  and
  `bench/out/apple-metal/20260531T004030Z/apple.metal.package-developer.bun.ffi-flat-setup-no-preflight.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T004030Z/apple.metal.package-developer.bun.ffi-flat-setup-no-preflight.phase-delta.json`
- Bun FFI inline-layout cold package surface:
  `bench/out/apple-metal/20260531T005759Z/apple.metal.package-developer.bun.ffi-inline-layout.compare.json`
  and
  `bench/out/apple-metal/20260531T005759Z/apple.metal.package-developer.bun.ffi-inline-layout.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T005759Z/apple.metal.package-developer.bun.ffi-inline-layout.phase-delta.json`
- Bun FFI direct-flush cold package surface:
  `bench/out/apple-metal/20260531T011131Z/apple.metal.package-developer.bun.ffi-direct-flush.compare.json`
  and
  `bench/out/apple-metal/20260531T011131Z/apple.metal.package-developer.bun.ffi-direct-flush.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T011131Z/apple.metal.package-developer.bun.ffi-direct-flush.phase-delta.json`
- Bun FFI direct-flush prepared package surface:
  `bench/out/apple-metal/20260531T011712Z/apple.metal.package-developer.bun.ffi-direct-flush.prepared.compare.json`
  and
  `bench/out/apple-metal/20260531T011712Z/apple.metal.package-developer.bun.ffi-direct-flush.prepared.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T011712Z/apple.metal.package-developer.bun.ffi-direct-flush.prepared.phase-delta.json`
- Bun FFI async-submit prepared package surface:
  `bench/out/apple-metal/20260531T021207Z/apple.metal.package-developer.bun.ffi-async-submit.prepared.compare.json`
  and
  `bench/out/apple-metal/20260531T021207Z/apple.metal.package-developer.bun.ffi-async-submit.prepared.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T021207Z/apple.metal.package-developer.bun.ffi-async-submit.prepared.phase-delta.json`
- Bun FFI batch-attributed prepared package surface:
  `bench/out/apple-metal/20260531T021713Z/apple.metal.package-developer.bun.ffi-batch-breakdown.prepared.compare.json`
  and
  `bench/out/apple-metal/20260531T021713Z/apple.metal.package-developer.bun.ffi-batch-breakdown.prepared.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T021713Z/apple.metal.package-developer.bun.ffi-batch-breakdown.prepared.phase-delta.json`
- Bun FFI direct-write current cold package surface:
  `bench/out/apple-metal/20260531T014904Z/apple.metal.package-developer.bun.ffi-direct-write-rerun.compare.json`
  and
  `bench/out/apple-metal/20260531T014904Z/apple.metal.package-developer.bun.ffi-direct-write-rerun.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T014904Z/apple.metal.package-developer.bun.ffi-direct-write-rerun.phase-delta.json`
- Bun FFI batch-attributed cold package surface:
  `bench/out/apple-metal/20260531T021812Z/apple.metal.package-developer.bun.ffi-batch-breakdown.compare.json`
  and
  `bench/out/apple-metal/20260531T021812Z/apple.metal.package-developer.bun.ffi-batch-breakdown.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T021812Z/apple.metal.package-developer.bun.ffi-batch-breakdown.phase-delta.json`
- Bun FFI current vector isolation:
  `bench/out/apple-metal/20260531T014835Z/apple.metal.package-developer.bun.ffi-current-vector.compare.json`
  and
  `bench/out/apple-metal/20260531T014835Z/apple.metal.package-developer.bun.ffi-current-vector.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T014835Z/apple.metal.package-developer.bun.ffi-current-vector.phase-delta.json`
- Bun FFI current image isolation after reverting the one-bind-group direct-flush
  experiment:
  `bench/out/apple-metal/20260531T015351Z/apple.metal.package-developer.bun.ffi-reverted-image.compare.json`
  and
  `bench/out/apple-metal/20260531T015351Z/apple.metal.package-developer.bun.ffi-reverted-image.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T015351Z/apple.metal.package-developer.bun.ffi-reverted-image.phase-delta.json`
- Bun FFI private Metal buffer diagnostic:
  `bench/out/apple-metal/20260531T014806Z/apple.metal.package-developer.bun.ffi-private-vector.compare.json`
  and
  `bench/out/apple-metal/20260531T014806Z/apple.metal.package-developer.bun.ffi-private-vector.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T014806Z/apple.metal.package-developer.bun.ffi-private-vector.phase-delta.json`
- Node native-direct refreshed cold package surface:
  `bench/out/apple-metal/20260531T011812Z/apple.metal.package-developer.node.native-direct.current-2.compare.json`
  and
  `bench/out/apple-metal/20260531T011812Z/apple.metal.package-developer.node.native-direct.current-2.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T011812Z/apple.metal.package-developer.node.native-direct.current-2.phase-delta.json`
- Node native-direct async-submit cold package surface:
  `bench/out/apple-metal/20260531T021008Z/apple.metal.package-developer.node.native-direct-async-submit.compare.json`
  and
  `bench/out/apple-metal/20260531T021008Z/apple.metal.package-developer.node.native-direct-async-submit.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T021008Z/apple.metal.package-developer.node.native-direct-async-submit.phase-delta.json`
- Bun prepared Gemma 270M package decode async-submit:
  `bench/out/apple-metal/20260531T021923Z/gemma270m.bun-package.decode.warm.async-submit.compare.json`
  and
  `bench/out/apple-metal/20260531T021923Z/gemma270m.bun-package.decode.warm.async-submit.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T021923Z/gemma270m.bun-package.decode.warm.async-submit.phase-delta.json`
- Node native-direct prepared Gemma 270M decode async-submit:
  `bench/out/apple-metal/20260531T022005Z/gemma270m.node.direct.decode.warm.async-submit.compare.json`
  and
  `bench/out/apple-metal/20260531T022005Z/gemma270m.node.direct.decode.warm.async-submit.claim.json`
  with phase attribution at
  `bench/out/apple-metal/20260531T022005Z/gemma270m.node.direct.decode.warm.async-submit.phase-delta.json`

Verified:

- `node --check bench/executors/run-bun-webgpu-plan.js && node --check bench/executors/node-webgpu/executor.js && node --check packages/doe-gpu/src/vendor/doe-namespace.js && node --check packages/doe-gpu/src/vendor/webgpu/shared/full-surface.js && node --check packages/doe-gpu/src/vendor/webgpu/index.js && node --check packages/doe-gpu/src/vendor/webgpu/bun-ffi.js && node --check packages/doe-gpu/src/vendor/webgpu/bun.js`
- `python3 -m unittest bench.tests.test_bun_webgpu_executor bench.tests.test_executor_registry bench.tests.test_package_dispatch_prefix_profile bench.tests.test_package_phase_delta`
- `zig build test-core`
- `zig build dropin -Doptimize=ReleaseFast`
- `npm --prefix packages/doe-gpu run stage:prebuilds`
- `npm --prefix packages/doe-gpu run test:integration`
- `npm --prefix packages/doe-gpu run test:integration:bun`

## 2026-05-30 — Fawn visual pages are browser workflow diagnostics

The browser layered workflow manifest now includes optional
`fawn_visual_resource` rows for the checked-in Fawn HTML demos. The layered
Playwright runner can navigate those pages through the local browser benchmark
server, wait for their own frame telemetry, sample animation-frame cadence, and
emit `avgFrameMs`, `p95FrameMs`, `avgFps`, and frame-count metrics as L2
diagnostic rows. Layered reports and score rows now carry the visual resource
path plus SHA-256, so a visual score remains bound to the exact checked-in page
that ran.

The visual rows remain optional and `l2_diagnostic_only`; they do not widen L0
parity claims. Workflow governance now requires visual resources to stay under
`browser/chromium/resources/*.html`, verifies that the files exist, and requires
the frame telemetry metric set. The browser layered score includes visual rows
under the `visual` category only when both Dawn and forced Doe complete the page
workload.

## 2026-05-30 — Chrome-vs-Fawn browser score sidecar

The browser layered superset runner now has a diagnostic scoring sidecar for
side-by-side stock Chrome versus Fawn Chromium runs. The scorer consumes the
existing `browser-layered-diagnostic` report, keeps the output
`claimStatus=diagnostic`, and emits separate paired scores for stock Chrome and
Fawn plus comparison percent delta. It also keeps both row-weighted and
category-balanced summaries from shared positive timing metrics. The macOS
wrapper `browser/chromium/scripts/run-consumer-bench.sh` resolves stock Chrome,
the host Fawn Chromium binary, and the full Doe WebGPU dylib before running the
layered workload matrix with explicit iteration knobs.

The existing Fawn demo HTML files remain manual visual surfaces; the score uses
the controlled Playwright layered workloads so the artifacts keep runtime mode,
browser path, metric, category, and exclusion evidence.

The score artifact is now part of browser artifact identity coverage. The
schema requires workload identity, browser environment evidence, baseline and
comparison executable/runtime hashes, shader compiler identity, adapter
identity, and the source mode-result trace hashes from the layered report.

The browser layered runner and superset checker now support explicit
category-focused diagnostic runs. Focused reports record `workloadFilter`
before/after row counts, stay diagnostic, and are checked only against selected
categories so weak surfaces can be tuned without running the full browser
matrix. Score sidecars copy the same filter, preventing a focused score from
looking like full-superset evidence.

## 2026-05-30 — Chromium smoke covers render bundles and indirect draw

The browser smoke harness now treats render bundle replay, render-pass indirect
draw, and timestamp query resolve as strict smoke checks. The source-binary Dawn
and forced-Doe smoke run linked from the Chromium integration overlay exercises
`createRenderBundleEncoder`/`executeBundles`, `drawIndirect`, and
`timestampWrites`/`resolveQuerySet` before the mini timing probes run.

The browser smoke schema, sample artifact, and Python smoke validator now
require the strict smoke rows enforced by the JS runner: compute, triangle
render, render bundle, indirect draw, timestamp query, XR-compatible adapter
request, external copy, and external texture import. The Chromium integration
overlay moved the render-bundle and indirect-draw capability rows from untested
implementation status to diagnostic browser evidence, still blocked on
`chromium_runtime_active` promotion before any claimable performance wording.
The overlay checker's active-runtime requirement set now includes external
copy, external texture import, render bundle replay, and render-pass indirect
draw so a later phase promotion cannot skip those source-owned paths.

Smoke artifact:

- `browser/chromium/artifacts/20260530T170216Z/dawn-vs-doe.browser.playwright-smoke.diagnostic.json`

## 2026-05-30 — Chromium active-Doe buffer mailbox fails closed

Active-Doe shared-buffer mailbox association now fails at the decoder command
boundary while no native buffer handle source is wired for Doe. Chromium logs
`doe_shared_buffer_unsupported` and returns `kInvalidArguments` before wire
buffer injection instead of installing a placeholder Doe error buffer or calling
Dawn-owned shared-buffer representations with Doe handles.

The source checkout gate now requires both the unsupported marker and the
fail-closed return sequence. The proc-surface contract still requires Doe-local
shared-buffer proc names so the generated Dawn wire table cannot satisfy those
names through native fallback, but active mailbox association stays blocked
until real native buffer import lands.

## 2026-05-30 — Chromium active-Doe texture mailbox imports IOSurface memory

Active-Doe texture mailbox association now imports macOS IOSurface-backed
shared texture memory through Doe instead of injecting a Doe error texture. The
Chromium decoder obtains the shared-image IOSurface, calls Doe's raw
`wgpuDeviceImportSharedTextureMemory` proc, creates a raw Doe `WGPUTexture`,
begins shared-texture access, injects that handle into the wire server, and ends
shared-texture access during present teardown before marking the shared image
cleared. The path does not call generated Dawn C++ wrappers with Doe handles.

Doe's drop-in shared texture memory procs now own the IOSurface descriptor path:
the import retains the IOSurface, validates it through the native Metal import
bridge, creates Doe textures backed by imported `MTLTexture` handles, reports
shared texture properties, and returns success from begin/end access. Shared
buffer memory and shared fences remain explicit unsupported paths until a real
native buffer/fence handle source exists.

The Chromium source gate now rejects the old texture error-object bridge by
requiring `doe_shared_image_iosurface_bridge`, native shared-texture import,
begin/end access, the IOSurface handle accessor, and
`doe_present_shared_texture_end_access`. The Doe proc-surface config/checker now
tracks this as `browserSharedMemoryBehavior`.

Verified:

- `zig build dropin-full --summary none`
- `zig build test --summary none`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_doe_chromium_proc_surface.py bench/tests/test_chromium_source_checkout.py -q`
- `python3 -m py_compile bench/tools/check_doe_chromium_proc_surface.py bench/tools/check_chromium_source_checkout.py bench/tests/test_doe_chromium_proc_surface.py bench/tests/test_chromium_source_checkout.py`
- `python3 bench/gates/schema_gate.py`
- `python3 bench/tools/check_doe_chromium_proc_surface.py --require-ready --json`
- `source browser/chromium/scripts/env.sh && python3 bench/tools/check_chromium_source_checkout.py --source-root browser/chromium/src --root . --require-ready --require-runtime-selector --json`
- `source browser/chromium/scripts/env.sh && autoninja -C browser/chromium/src/out/fawn_release gl_tests`
- `source browser/chromium/scripts/env.sh && browser/chromium/src/out/fawn_release/gl_tests --gtest_filter=WebGPUDecoderTest.*`
- `browser/chromium/scripts/run-smoke.sh --chrome browser/chromium/src/out/fawn_release/Chromium.app/Contents/MacOS/Chromium --doe-lib runtime/zig/zig-out/lib/libwebgpu_doe_full.dylib --mode both --headless true --strict --upload-iters 5 --dispatch-iters 3 --suite-timeout-ms 60000 --op-timeout-ms 10000`

Smoke artifact:

- `browser/chromium/artifacts/20260530T170216Z/dawn-vs-doe.browser.playwright-smoke.diagnostic.json`

## 2026-05-30 — Node/Bun package developer lane has native-direct evidence

The Node/Bun developer wedge now has a package workload pack covering buffer
upload/readback, vector dispatch, image transform dispatch, pipeline creation,
and queue submit/completion behavior. The pack is driven by explicit
package-surface compare configs for Node, Node native-direct, and Bun, with
run receipts feeding strict compare and claim sidecars.

Node now exposes `createNativeDirect()` from `doe-gpu` and the package
executor can run it as `doe_node_native_direct`. Receipts keep the package
identity as `doe-gpu` while recording the execution backend as native-direct.
The promoted compare catalog now includes the Apple Metal native-direct Node
package-developer lane.

The package phase-delta tool compares receipt sets and reports raw plus grouped
setup, binding, submit, write, and readback buckets. Current Node native-direct
and Bun package-developer reports are claimable; see the claim artifacts under
`bench/out/apple-metal/20260530T162758Z/` and
`bench/out/apple-metal/20260530T163132Z/`.

Bun package plans now share the terminal-readback `mapAsync` completion policy
used by Node package plans when the readback structurally follows the last
write/copy into the mapped buffer. Prepared-session package configs use
`bench/workloads/workloads.package.developer.prepared.json`, which repeats full
steady-state plan cycles inside each timed sample and leaves shader, module, and
pipeline creation to the cold package-developer pack because setup is excluded
from prepared-session selected timing. File-backed synthetic assets are cached
inside the executor process so repeated prepared cycles do not include repeated
asset file reads. Static `writeBuffer` payloads are also materialized once per
plan step inside the executor invocation. Current prepared-session Node
native-direct and Bun reports are claimable; see the claim artifacts under
`bench/out/apple-metal/20260530T171625Z/` and
`bench/out/apple-metal/20260530T171340Z/`.

Node native-direct and Bun package now also have cold and prepared
package-inference decode configs for the Gemma 3 270M shaped single-token
workload. The 270M shaped IR adds matched package readback captures: a
logits-prefix capture for prefill and sampled-token captures for decode.
Prepared decode configs use `bench/workloads/workloads.package.inference.prepared.json`
so each timed sample repeats the full decode plan cycle and normalizes by cycle.
Package trace metadata now records compact readback capture summaries: byte
length, SHA-256, semantic phase, and decoded `u32` values when available.
Strict compare now treats a readback capture mismatch as a blocking
comparability failure, so a claimable package decode report proves matching
terminal capture bytes in addition to matching execution shape.
The local plan assets are materialized through
`bench/tools/materialize_plan_assets.py`, and the receipt-first compare flow
emits strict-comparable, claimable reports at
`bench/out/apple-metal/20260530T180023Z/gemma270m.node.direct.decode.ir.claim.json`
and
`bench/out/apple-metal/20260530T180733Z/gemma270m.node.direct.decode.warm.ir.claim.json`
for Node native-direct, plus
`bench/out/apple-metal/20260530T180153Z/gemma270m.bun-package.decode.ir.claim.json`
and
`bench/out/apple-metal/20260530T180815Z/gemma270m.bun-package.decode.warm.ir.claim.json`
for Bun. Phase deltas for those runs are next to the compare reports.
The compare taxonomy now has explicit package-surface workload ids for
`gemma270m-decode` and `package-developer`, plus an explicit
`doe_native_direct_vs_dawn_node_webgpu_package` family with
`package_node_native_direct_providers`. The generated taxonomy expansion and
promoted catalog expose the Node native-direct and Bun package profiles as
promoted Apple Metal entries, keeping front-door selection, run-config provider
flags, and taxonomy reporting in sync.
Package trace metadata now also includes `packageWriteBreakdown`, which records
write counts and bytes by data kind and semantic phase, including static
file-backed buffer loads versus dynamic writes. The phase-delta tool carries
those distributions from run receipts so resident-state inference lanes can be
specified from explicit upload evidence. Package executors now accept
`--resident-buffer-loads` only with `--prepared-session`; that mode preloads
static file-backed buffer loads before selected timing, records
`packageResidentBufferLoadBreakdown`, and skips those static writes inside the
repeated steady loop. The existing prepared decode executors remain full-cycle
workloads. Separate registry ids ending in `_prepared_resident_buffer_loads`
select the resident-state shape for Node, native-direct, and Bun package runs.
Phase-delta reports now carry both raw resident preload totals and amortized
per-cycle resident preload buckets. The promoted workload id is
`gemma270m-decode-resident`, with resident warm configs for Doe native-direct
on Node vs Dawn-backed `node-webgpu` and Doe package WebGPU on Bun vs
Dawn-backed `bun-webgpu`. Strict compare now also blocks
resident-vs-full-cycle package mixes by requiring matching
`packageResidentBufferLoads` modes and matching resident preload count/byte
shapes on package execution traces. Resident mode also rejects plans where a
preloaded static buffer receives dynamic writes in the selected loop.

Touched:

- `bench/lib/compare_axes.py`
- `bench/executors/node-webgpu/executor.js`
- `bench/executors/package-webgpu/runner-core.js`
- `bench/executors/node-webgpu/synthetic-assets.js`
- `config/compare-taxonomy.json`
- `config/compare-taxonomy.schema.json`
- `config/generated/compare-taxonomy-expanded.jsonl`
- `config/trace-meta.schema.json`
- `bench/native-compare/compare.config.apple.metal.gemma270m.node.direct.decode.ir.json`
- `bench/native-compare/compare.config.apple.metal.gemma270m.node.direct.decode.warm.ir.json`
- `bench/native-compare/compare.config.apple.metal.gemma270m.node.direct.decode.resident.warm.ir.json`
- `bench/native-compare/compare.config.apple.metal.gemma270m.bun-package.decode.ir.json`
- `bench/native-compare/compare.config.apple.metal.gemma270m.bun-package.decode.warm.ir.json`
- `bench/native-compare/compare.config.apple.metal.gemma270m.bun-package.decode.resident.warm.ir.json`
- `bench/ir/gemma3_270m.json`
- `bench/plans/generated/inference_gemma3_270m_decode_1tok.plan.json`
- `bench/plans/generated/inference_gemma3_270m_prefill_32tok.plan.json`
- `bench/plans/generated/inference_gemma3_270m_prefill_64tok_decode_64tok.plan.json`
- `bench/plans/generated/compat/inference_gemma3_270m_decode_1tok_commands.json`
- `bench/plans/generated/compat/inference_gemma3_270m_prefill_32tok_commands.json`
- `bench/plans/generated/compat/inference_gemma3_270m_prefill_64tok_decode_64tok_commands.json`
- `bench/native_compare_modules/comparability_runtime.py`
- `bench/native_compare_modules/compare_assessment.py`
- `bench/native_compare_modules/executor_registry.py`
- `bench/native_compare_modules/run_artifact.py`
- `bench/native_compare_modules/runner.py`
- `bench/tools/generate_compare_taxonomy.py`
- `bench/tools/package_phase_delta.py`
- `bench/tests/test_node_webgpu_executor.py`
- `bench/tests/test_bun_webgpu_executor.py`
- `bench/tests/test_executor_registry.py`
- `bench/tests/test_compare_taxonomy.py`
- `bench/tests/test_compare_from_artifacts.py`
- `bench/tests/test_promoted_compare.py`
- `bench/tests/test_package_phase_delta.py`
- `bench/tests/test_run_artifact.py`
- `bench/tests/test_runner_plan_support.py`
- `bench/tests/test_backend_workload_catalog.py`
- `bench/workloads/workloads.package.inference.json`
- `bench/workloads/workloads.package.inference.prepared.json`
- `bench/workloads/workloads.package.developer.prepared.json`
- `config/promoted-compare-catalog.json`
- `docs/node-bun-developer-wedge.md`
- `examples/inference_gemma3_270m_decode_1tok_commands.json`
- `examples/inference_gemma3_270m_prefill_32tok_commands.json`
- `examples/inference_gemma3_270m_prefill_64tok_decode_64tok_commands.json`
- `packages/doe-gpu/README.md`
- `packages/doe-gpu/src/vendor/webgpu/index.js`
- `packages/doe-gpu/test/integration/first-kernel-receipt-test.js`
- `packages/doe-gpu/test/integration/test-integration-first-kernel-bun.js`
- `packages/doe-gpu/test/integration/test-integration-first-kernel.js`
- `packages/doe-gpu/test/smoke/test-smoke-load.js`
- `runtime/bridge/webgpu-addon/doe_napi_nd_infra.c`
- `runtime/bridge/webgpu-addon/doe_napi_nd_encoder.c`
- `runtime/bridge/webgpu-addon/doe_napi_nd_immediates.c`

Verified:

- `npm --prefix packages/doe-gpu run build:addon`
- `npm --prefix packages/doe-gpu run test:smoke`
- `python3 -m unittest bench.tests.test_node_webgpu_executor bench.tests.test_run_artifact bench.tests.test_compare_from_artifacts bench.tests.test_package_phase_delta bench.tests.test_runner_plan_support`
- `python3 -m unittest bench.tests.test_node_webgpu_executor bench.tests.test_backend_workload_catalog bench.tests.test_package_phase_delta`
- `python3 -m unittest bench.tests.test_node_webgpu_executor bench.tests.test_package_phase_delta bench.tests.test_executor_registry bench.tests.test_compare_taxonomy bench.tests.test_promoted_compare bench.tests.test_backend_workload_catalog bench.tests.test_compare_from_artifacts bench.tests.test_runner_plan_support`
- `python3 -m unittest bench.tests.test_bun_webgpu_executor`
- `python3 -m unittest bench.tests.test_compare_from_artifacts`
- `node --check bench/executors/node-webgpu/executor.js`
- `node --check bench/executors/package-webgpu/runner-core.js`
- `python3 -m json.tool config/trace-meta.schema.json >/dev/null`
- `python3 -m py_compile bench/native_compare_modules/compare_assessment.py bench/native_compare_modules/comparability_runtime.py bench/native_compare_modules/run_artifact.py bench/native_compare_modules/executor_registry.py bench/native_compare_modules/runner.py bench/tools/package_phase_delta.py`
- `python3 -m py_compile bench/tools/package_phase_delta.py bench/tools/generate_compare_taxonomy.py bench/lib/compare_axes.py bench/native_compare_modules/executor_registry.py`
- `python3 bench/gates/schema_gate.py`
- `python3 bench/tools/generate_compare_taxonomy.py --write`
- `python3 bench/tools/generate_compare_taxonomy.py --verify`
- `python3 bench/cli.py run-config --side baseline --config bench/native-compare/compare.config.apple.metal.package-developer.node.direct.ir.json`
- `python3 bench/cli.py compare --comparability strict --require-timing-class operation --out bench/out/apple-metal/20260530T162758Z/apple.metal.package-developer.node.direct.ir.compare.json bench/out/apple-metal/20260530T162758Z/package-developer.node.direct.ir.workspace/run-artifacts/doe_gpu_node_native_direct/*.run.json bench/out/apple-metal/20260530T161827Z/package-developer.node.direct.ir.workspace/run-artifacts/node_webgpu_package/*.run.json`
- `python3 bench/cli.py claim bench/out/apple-metal/20260530T162758Z/apple.metal.package-developer.node.direct.ir.compare.json --config bench/native-compare/compare.config.apple.metal.package-developer.node.direct.ir.json --mode local --out bench/out/apple-metal/20260530T162758Z/apple.metal.package-developer.node.direct.ir.claim.json`
- `python3 bench/cli.py run-config --side baseline --config bench/native-compare/compare.config.apple.metal.package-developer.bun.ir.json`
- `python3 bench/cli.py run-config --side comparison --config bench/native-compare/compare.config.apple.metal.package-developer.bun.ir.json`
- `python3 bench/cli.py compare --comparability strict --require-timing-class operation --out bench/out/apple-metal/20260530T163132Z/apple.metal.package-developer.bun.ir.compare.json bench/out/apple-metal/20260530T163043Z/package-developer.bun.ir.workspace/run-artifacts/doe_gpu_bun_package/*.run.json bench/out/apple-metal/20260530T163132Z/package-developer.bun.ir.workspace/run-artifacts/bun_webgpu_package/*.run.json`
- `python3 bench/cli.py claim bench/out/apple-metal/20260530T163132Z/apple.metal.package-developer.bun.ir.compare.json --config bench/native-compare/compare.config.apple.metal.package-developer.bun.ir.json --mode local --out bench/out/apple-metal/20260530T163132Z/apple.metal.package-developer.bun.ir.claim.json`
- `python3 bench/cli.py run-config --side baseline --config bench/native-compare/compare.config.apple.metal.package-developer.node.direct.prepared.ir.json`
- `python3 bench/cli.py run-config --side comparison --config bench/native-compare/compare.config.apple.metal.package-developer.node.direct.prepared.ir.json`
- `python3 bench/cli.py compare --comparability strict --require-timing-class operation --out bench/out/apple-metal/20260530T171625Z/apple.metal.package-developer.node.direct.prepared.null-void.compare.json bench/out/apple-metal/20260530T171625Z/package-developer.node.direct.prepared.ir.workspace/run-artifacts/doe_gpu_node_native_direct_prepared/*.run.json bench/out/apple-metal/20260530T171250Z/package-developer.node.direct.prepared.ir.workspace/run-artifacts/node_webgpu_package_prepared/*.run.json`
- `python3 bench/cli.py claim bench/out/apple-metal/20260530T171625Z/apple.metal.package-developer.node.direct.prepared.null-void.compare.json --config bench/native-compare/compare.config.apple.metal.package-developer.node.direct.prepared.ir.json --out bench/out/apple-metal/20260530T171625Z/apple.metal.package-developer.node.direct.prepared.null-void.claim.json`
- `python3 bench/tools/package_phase_delta.py --baseline-label doe-native-direct-prepared --comparison-label node-webgpu-prepared --baseline-glob 'bench/out/apple-metal/20260530T171625Z/package-developer.node.direct.prepared.ir.workspace/run-artifacts/doe_gpu_node_native_direct_prepared/*.run.json' --comparison-glob 'bench/out/apple-metal/20260530T171250Z/package-developer.node.direct.prepared.ir.workspace/run-artifacts/node_webgpu_package_prepared/*.run.json' --json-out bench/out/apple-metal/20260530T171625Z/apple.metal.package-developer.node.direct.prepared.null-void.webgpu.phase-delta.json`
- `python3 bench/cli.py run-config --side baseline --config bench/native-compare/compare.config.apple.metal.package-developer.bun.prepared.ir.json`
- `python3 bench/cli.py run-config --side comparison --config bench/native-compare/compare.config.apple.metal.package-developer.bun.prepared.ir.json`
- `python3 bench/cli.py compare --comparability strict --require-timing-class operation --out bench/out/apple-metal/20260530T171340Z/apple.metal.package-developer.bun.prepared.asset-cache.compare.json bench/out/apple-metal/20260530T171329Z/package-developer.bun.prepared.ir.workspace/run-artifacts/doe_gpu_bun_package_prepared/*.run.json bench/out/apple-metal/20260530T171340Z/package-developer.bun.prepared.ir.workspace/run-artifacts/bun_webgpu_package_prepared/*.run.json`
- `python3 bench/cli.py claim bench/out/apple-metal/20260530T171340Z/apple.metal.package-developer.bun.prepared.asset-cache.compare.json --config bench/native-compare/compare.config.apple.metal.package-developer.bun.prepared.ir.json --out bench/out/apple-metal/20260530T171340Z/apple.metal.package-developer.bun.prepared.asset-cache.claim.json`
- `python3 bench/tools/package_phase_delta.py --baseline-label doe-bun-prepared --comparison-label bun-webgpu-prepared --baseline-glob 'bench/out/apple-metal/20260530T171329Z/package-developer.bun.prepared.ir.workspace/run-artifacts/doe_gpu_bun_package_prepared/*.run.json' --comparison-glob 'bench/out/apple-metal/20260530T171340Z/package-developer.bun.prepared.ir.workspace/run-artifacts/bun_webgpu_package_prepared/*.run.json' --json-out bench/out/apple-metal/20260530T171340Z/apple.metal.package-developer.bun.prepared.asset-cache.phase-delta.json`
- `node packages/doe-gpu/test/integration/test-integration-first-kernel.js`
- `bun packages/doe-gpu/test/integration/test-integration-first-kernel-bun.js`
- `npm --prefix packages/doe-gpu run test:integration`
- `npm --prefix packages/doe-gpu run test:integration:bun`
- `python3 bench/tools/materialize_plan_assets.py --plan bench/plans/generated/inference_gemma3_270m_decode_1tok.plan.json`
- `python3 bench/tools/generate_backend_workloads.py`
- `python3 bench/tools/generate_backend_workloads.py --verify`
- `node bench/executors/run-node-webgpu-plan.js --provider doe-direct --plan bench/plans/generated/inference_gemma3_270m_decode_1tok.plan.json --trace-meta bench/out/scratch/gemma270m-decode-capture-doe-direct.meta.json --trace-jsonl bench/out/scratch/gemma270m-decode-capture-doe-direct.ndjson --workload inference_gemma3_270m_decode_1tok`
- `node bench/executors/run-node-webgpu-plan.js --provider node-webgpu --plan bench/plans/generated/inference_gemma3_270m_decode_1tok.plan.json --trace-meta bench/out/scratch/gemma270m-decode-capture-node-webgpu.meta.json --trace-jsonl bench/out/scratch/gemma270m-decode-capture-node-webgpu.ndjson --workload inference_gemma3_270m_decode_1tok`
- `python3 bench/cli.py run-config --config bench/native-compare/compare.config.apple.metal.gemma270m.node.direct.decode.ir.json --side baseline`
- `python3 bench/cli.py run-config --config bench/native-compare/compare.config.apple.metal.gemma270m.node.direct.decode.ir.json --side comparison`
- `python3 bench/cli.py compare bench/out/apple-metal/20260530T180014Z/gemma270m.node.direct.decode.ir.workspace/run-artifacts/doe_gpu_node_native_direct/doe_gpu_node_native_direct-inference_gemma3_270m_decode_1tok-20260530T180014Z.run.json bench/out/apple-metal/20260530T180023Z/gemma270m.node.direct.decode.ir.workspace/run-artifacts/node_webgpu_package/node_webgpu_package-inference_gemma3_270m_decode_1tok-20260530T180023Z.run.json --baseline-product doe_gpu_node_native_direct --comparison-product node_webgpu_package --out bench/out/apple-metal/20260530T180023Z/gemma270m.node.direct.decode.ir.compare.json`
- `python3 bench/cli.py claim bench/out/apple-metal/20260530T180023Z/gemma270m.node.direct.decode.ir.compare.json --config bench/native-compare/compare.config.apple.metal.gemma270m.node.direct.decode.ir.json --out bench/out/apple-metal/20260530T180023Z/gemma270m.node.direct.decode.ir.claim.json`
- `python3 bench/tools/package_phase_delta.py --baseline-glob 'bench/out/apple-metal/20260530T180014Z/gemma270m.node.direct.decode.ir.workspace/run-artifacts/doe_gpu_node_native_direct/*.run.json' --comparison-glob 'bench/out/apple-metal/20260530T180023Z/gemma270m.node.direct.decode.ir.workspace/run-artifacts/node_webgpu_package/*.run.json' --baseline-label doe_gpu_node_native_direct --comparison-label node_webgpu_package --json-out bench/out/apple-metal/20260530T180023Z/gemma270m.node.direct.decode.ir.phase-delta.json`
- `python3 bench/cli.py run-config --config bench/native-compare/compare.config.apple.metal.gemma270m.node.direct.decode.warm.ir.json --boundary package_surface --runtime-host node --temperature warm --comparison-view doe_native_direct_vs_dawn_node_webgpu_package --provider-set package_node_native_direct_providers --baseline-provider-id doe-direct --comparison-provider-id node-webgpu --side baseline`
- `python3 bench/cli.py run-config --config bench/native-compare/compare.config.apple.metal.gemma270m.node.direct.decode.warm.ir.json --boundary package_surface --runtime-host node --temperature warm --comparison-view doe_native_direct_vs_dawn_node_webgpu_package --provider-set package_node_native_direct_providers --baseline-provider-id doe-direct --comparison-provider-id node-webgpu --side comparison`
- `python3 bench/cli.py compare bench/out/apple-metal/20260530T180721Z/gemma270m.node.direct.decode.warm.ir.workspace/run-artifacts/doe_gpu_node_native_direct_prepared/doe_gpu_node_native_direct_prepared-inference_gemma3_270m_decode_1tok-20260530T180721Z.run.json bench/out/apple-metal/20260530T180733Z/gemma270m.node.direct.decode.warm.ir.workspace/run-artifacts/node_webgpu_package_prepared/node_webgpu_package_prepared-inference_gemma3_270m_decode_1tok-20260530T180733Z.run.json --baseline-product doe_gpu_node_native_direct_prepared --comparison-product node_webgpu_package_prepared --out bench/out/apple-metal/20260530T180733Z/gemma270m.node.direct.decode.warm.ir.compare.json`
- `python3 bench/cli.py claim bench/out/apple-metal/20260530T180733Z/gemma270m.node.direct.decode.warm.ir.compare.json --config bench/native-compare/compare.config.apple.metal.gemma270m.node.direct.decode.warm.ir.json --out bench/out/apple-metal/20260530T180733Z/gemma270m.node.direct.decode.warm.ir.claim.json`
- `python3 bench/tools/package_phase_delta.py --baseline-glob 'bench/out/apple-metal/20260530T180721Z/gemma270m.node.direct.decode.warm.ir.workspace/run-artifacts/doe_gpu_node_native_direct_prepared/*.run.json' --comparison-glob 'bench/out/apple-metal/20260530T180733Z/gemma270m.node.direct.decode.warm.ir.workspace/run-artifacts/node_webgpu_package_prepared/*.run.json' --baseline-label doe_gpu_node_native_direct_prepared --comparison-label node_webgpu_package_prepared --json-out bench/out/apple-metal/20260530T180733Z/gemma270m.node.direct.decode.warm.ir.phase-delta.json`
- `python3 bench/cli.py run-config --config bench/native-compare/compare.config.apple.metal.gemma270m.bun-package.decode.ir.json --boundary package_surface --runtime-host bun --temperature cold --comparison-view doe_vs_dawn_bun_webgpu_package --provider-set package_bun_providers --baseline-provider-id doe --comparison-provider-id bun-webgpu --side baseline`
- `python3 bench/cli.py run-config --config bench/native-compare/compare.config.apple.metal.gemma270m.bun-package.decode.ir.json --boundary package_surface --runtime-host bun --temperature cold --comparison-view doe_vs_dawn_bun_webgpu_package --provider-set package_bun_providers --baseline-provider-id doe --comparison-provider-id bun-webgpu --side comparison`
- `python3 bench/cli.py compare bench/out/apple-metal/20260530T180144Z/gemma270m.bun-package.decode.ir.workspace/run-artifacts/doe_gpu_bun_package/doe_gpu_bun_package-inference_gemma3_270m_decode_1tok-20260530T180144Z.run.json bench/out/apple-metal/20260530T180153Z/gemma270m.bun-package.decode.ir.workspace/run-artifacts/bun_webgpu_package/bun_webgpu_package-inference_gemma3_270m_decode_1tok-20260530T180153Z.run.json --baseline-product doe_gpu_bun_package --comparison-product bun_webgpu_package --out bench/out/apple-metal/20260530T180153Z/gemma270m.bun-package.decode.ir.compare.json`
- `python3 bench/cli.py claim bench/out/apple-metal/20260530T180153Z/gemma270m.bun-package.decode.ir.compare.json --config bench/native-compare/compare.config.apple.metal.gemma270m.bun-package.decode.ir.json --out bench/out/apple-metal/20260530T180153Z/gemma270m.bun-package.decode.ir.claim.json`
- `python3 bench/tools/package_phase_delta.py --baseline-glob 'bench/out/apple-metal/20260530T180144Z/gemma270m.bun-package.decode.ir.workspace/run-artifacts/doe_gpu_bun_package/*.run.json' --comparison-glob 'bench/out/apple-metal/20260530T180153Z/gemma270m.bun-package.decode.ir.workspace/run-artifacts/bun_webgpu_package/*.run.json' --baseline-label doe_gpu_bun_package --comparison-label bun_webgpu_package --json-out bench/out/apple-metal/20260530T180153Z/gemma270m.bun-package.decode.ir.phase-delta.json`
- `python3 bench/cli.py run-config --config bench/native-compare/compare.config.apple.metal.gemma270m.bun-package.decode.warm.ir.json --boundary package_surface --runtime-host bun --temperature warm --comparison-view doe_vs_dawn_bun_webgpu_package --provider-set package_bun_providers --baseline-provider-id doe --comparison-provider-id bun-webgpu --side baseline`
- `python3 bench/cli.py run-config --config bench/native-compare/compare.config.apple.metal.gemma270m.bun-package.decode.warm.ir.json --boundary package_surface --runtime-host bun --temperature warm --comparison-view doe_vs_dawn_bun_webgpu_package --provider-set package_bun_providers --baseline-provider-id doe --comparison-provider-id bun-webgpu --side comparison`
- `python3 bench/cli.py compare bench/out/apple-metal/20260530T180803Z/gemma270m.bun-package.decode.warm.ir.workspace/run-artifacts/doe_gpu_bun_package_prepared/doe_gpu_bun_package_prepared-inference_gemma3_270m_decode_1tok-20260530T180803Z.run.json bench/out/apple-metal/20260530T180815Z/gemma270m.bun-package.decode.warm.ir.workspace/run-artifacts/bun_webgpu_package_prepared/bun_webgpu_package_prepared-inference_gemma3_270m_decode_1tok-20260530T180815Z.run.json --baseline-product doe_gpu_bun_package_prepared --comparison-product bun_webgpu_package_prepared --out bench/out/apple-metal/20260530T180815Z/gemma270m.bun-package.decode.warm.ir.compare.json`
- `python3 bench/cli.py claim bench/out/apple-metal/20260530T180815Z/gemma270m.bun-package.decode.warm.ir.compare.json --config bench/native-compare/compare.config.apple.metal.gemma270m.bun-package.decode.warm.ir.json --out bench/out/apple-metal/20260530T180815Z/gemma270m.bun-package.decode.warm.ir.claim.json`
- `python3 bench/tools/package_phase_delta.py --baseline-glob 'bench/out/apple-metal/20260530T180803Z/gemma270m.bun-package.decode.warm.ir.workspace/run-artifacts/doe_gpu_bun_package_prepared/*.run.json' --comparison-glob 'bench/out/apple-metal/20260530T180815Z/gemma270m.bun-package.decode.warm.ir.workspace/run-artifacts/bun_webgpu_package_prepared/*.run.json' --baseline-label doe_gpu_bun_package_prepared --comparison-label bun_webgpu_package_prepared --json-out bench/out/apple-metal/20260530T180815Z/gemma270m.bun-package.decode.warm.ir.phase-delta.json`
- `node bench/executors/run-node-webgpu-plan.js --provider doe-direct --prepared-session --resident-buffer-loads --plan bench/plans/generated/inference_gemma3_270m_decode_1tok.plan.json --trace-meta bench/out/scratch/resident-buffer-loads.node-direct.meta.json --trace-jsonl bench/out/scratch/resident-buffer-loads.node-direct.ndjson --workload inference_gemma3_270m_decode_1tok --command-repeat 2`
- `bun bench/executors/run-bun-webgpu-plan.js --provider doe --prepared-session --resident-buffer-loads --plan bench/plans/generated/inference_gemma3_270m_decode_1tok.plan.json --trace-meta bench/out/scratch/resident-buffer-loads.bun-doe.meta.json --trace-jsonl bench/out/scratch/resident-buffer-loads.bun-doe.ndjson --workload inference_gemma3_270m_decode_1tok --command-repeat 2`
- `python3 bench/cli.py run --product doe --executor-id doe_node_native_direct_prepared_resident_buffer_loads --workloads bench/workloads/workloads.package.inference.prepared.json --workload-id inference_gemma3_270m_decode_1tok --iterations 1 --warmup 0 --out bench/out/scratch/resident-buffer-loads.registry-run`
- `python3 bench/tools/package_phase_delta.py --baseline-glob 'bench/out/scratch/resident-buffer-loads.registry-run/run-artifacts/doe/*.run.json' --comparison-glob 'bench/out/scratch/resident-buffer-loads.registry-run/run-artifacts/doe/*.run.json' --baseline-label doe-direct-resident --comparison-label doe-direct-resident --json-out bench/out/scratch/resident-buffer-loads.phase-delta.json --top 3`
- `python3 bench/cli.py compare --dry-run --backend apple-metal --surface package --workload gemma270m-decode-resident --mode warm`
- `python3 bench/cli.py compare --dry-run --backend apple-metal --surface package --workload gemma270m-decode-resident --mode warm --package-runtime bun`
- `python3 bench/cli.py run-config --config bench/native-compare/compare.config.apple.metal.gemma270m.node.direct.decode.resident.warm.ir.json --side baseline --iterations 1 --warmup 0 --workspace bench/out/scratch/resident-node-compare.baseline.workspace --out bench/out/scratch/resident-node-compare.baseline.json --no-timestamp-output`
- `python3 bench/cli.py run-config --config bench/native-compare/compare.config.apple.metal.gemma270m.node.direct.decode.resident.warm.ir.json --side comparison --iterations 1 --warmup 0 --workspace bench/out/scratch/resident-node-compare.comparison.workspace --out bench/out/scratch/resident-node-compare.comparison.json --no-timestamp-output`
- `python3 bench/cli.py compare bench/out/scratch/resident-node-compare.baseline.workspace/run-artifacts/doe_gpu_node_native_direct_prepared_resident/*.run.json bench/out/scratch/resident-node-compare.comparison.workspace/run-artifacts/node_webgpu_package_prepared_resident/*.run.json --baseline-product doe_gpu_node_native_direct_prepared_resident --comparison-product node_webgpu_package_prepared_resident --out bench/out/scratch/resident-node-compare.compare.json`
- `python3 bench/tools/package_phase_delta.py --baseline-glob 'bench/out/scratch/resident-node-compare.baseline.workspace/run-artifacts/doe_gpu_node_native_direct_prepared_resident/*.run.json' --comparison-glob 'bench/out/scratch/resident-node-compare.comparison.workspace/run-artifacts/node_webgpu_package_prepared_resident/*.run.json' --baseline-label doe-native-direct-resident --comparison-label node-webgpu-resident --json-out bench/out/scratch/resident-node-compare.phase-delta.json --top 5`
- `python3 bench/cli.py run-config --config bench/native-compare/compare.config.apple.metal.gemma270m.bun-package.decode.resident.warm.ir.json --side baseline --iterations 1 --warmup 0 --workspace bench/out/scratch/resident-bun-compare.baseline.workspace --out bench/out/scratch/resident-bun-compare.baseline.json --no-timestamp-output`
- `python3 bench/cli.py run-config --config bench/native-compare/compare.config.apple.metal.gemma270m.bun-package.decode.resident.warm.ir.json --side comparison --iterations 1 --warmup 0 --workspace bench/out/scratch/resident-bun-compare.comparison.workspace --out bench/out/scratch/resident-bun-compare.comparison.json --no-timestamp-output`
- `python3 bench/cli.py compare bench/out/scratch/resident-bun-compare.baseline.workspace/run-artifacts/doe_gpu_bun_package_prepared_resident/*.run.json bench/out/scratch/resident-bun-compare.comparison.workspace/run-artifacts/bun_webgpu_package_prepared_resident/*.run.json --baseline-product doe_gpu_bun_package_prepared_resident --comparison-product bun_webgpu_package_prepared_resident --out bench/out/scratch/resident-bun-compare.compare.json`
- `python3 bench/tools/package_phase_delta.py --baseline-glob 'bench/out/scratch/resident-bun-compare.baseline.workspace/run-artifacts/doe_gpu_bun_package_prepared_resident/*.run.json' --comparison-glob 'bench/out/scratch/resident-bun-compare.comparison.workspace/run-artifacts/bun_webgpu_package_prepared_resident/*.run.json' --baseline-label doe-bun-resident --comparison-label bun-webgpu-resident --json-out bench/out/scratch/resident-bun-compare.phase-delta.json --top 5`
- `jq '.workloads[0].comparability | {comparable, blockingFailedObligations}' bench/out/scratch/resident-node-compare.compare.json`
- `jq '.workloads[0].comparability | {comparable, blockingFailedObligations}' bench/out/scratch/resident-bun-compare.compare.json`
- `git diff --check`

## 2026-05-30 — Chromium forced-Doe wire runtime is active in source

Forced Doe source selection now requires a browser-facing WGPU proc surface,
the full generated Dawn wire proc table through `wgpuGetProcAddress`, and a
Doe-local browser interop proc surface for shared texture, shared buffer, shared
fence, and error-object procs. Chromium now creates a Doe `WGPUInstance` from
the selected Doe dylib and injects it into the WebGPU wire server in forced-Doe
mode while leaving the default Dawn path unchanged.

Doe now has a schema-backed proc-surface config and checker for the Chromium
lane. The checker loads the current Doe WebGPU dylib, verifies direct exports,
parses the generated `DawnProcTable` header, verifies every table entry resolves
through `wgpuGetProcAddress`, verifies required browser interop procs are mapped
in Doe's local resolver before native fallback, verifies the error-object
implementation source allocates tagged Doe handles, validates macOS IOSurface
shared texture import behavior, keeps shared-buffer and shared-fence imports
explicitly unsupported, and confirms the runtime artifact can bootstrap an
instance. Doe now owns explicit browser shared-memory proc names so the
generated wire proc table cannot satisfy those names by falling through to Dawn.
Doe also owns non-null error-object constructors for Chromium error texture and
error buffer requests: the handles are tagged as Doe error objects, carry
descriptor metadata, release through Doe, and reject use as normal GPU
resources. Active Doe imports texture mailboxes through native IOSurface shared
texture memory and rejects shared-buffer mailbox association before wire
injection until a real native buffer handle source lands.

The Chromium decoder unit coverage now includes a successful Doe wire runtime
lifecycle path. `DoeWireRuntimeOwnsAndReleasesInstanceLifecycle` loads the
generated wire proc table through the same helper used by forced-Doe selection,
creates a test instance, processes events through the loaded proc table, releases
the owned instance, and verifies the runtime is cleared. The source-checkout
gate now requires that lifecycle test marker.

Browser runtime selection now propagates adapter denylist match details into
every runtime selection row. Auto mode still selects Dawn with
`profile_denylisted` when the policy blocks a profile; forced modes keep their
explicit runtime while carrying the same `adapterDenylist` detail for audit.
The policy contract now lists those detail fields as observability fields, and
the smoke/report validators reject `profile_denylisted` rows that omit the
matched denylist detail.

Chromium source adapter filtering now emits equivalent denylist detail once
adapter identity is available. The formatted `adapter_denylist_detail` row
carries the typed `profile_denylisted` reason, vendor/device IDs,
adapter/backend type, and blocklist reason before the adapter is rejected. The
source-checkout gate now requires those markers and the formatter unit test.

Fresh browser smoke now runs against the built source Chromium binary and is
linked from the Chromium integration overlay. The report remains diagnostic;
see the artifact path in `config/webgpu-integration-chromium.json`.

The Chromium integration overlay checker now validates the linked smoke report
as source-runtime evidence for `source_selector_wire_runtime_active`: both
`dawn` and forced-`doe` rows must be present, strict, hash-valid, fallback-free,
and tied to a `browser/chromium/src/out` binary with a `libwebgpu_doe` runtime
for the Doe lane.

Browser smoke artifacts now carry top-level `runtimeSelections` as a schema and
validator requirement, matching the source of runtime identity consumed by the
overlay and promotion tooling.

The source Chromium lane also has a fresh layered superset diagnostic run with
required browser rows passing in both Dawn and forced-Doe modes. The report,
summary, and checker output live under
`browser/chromium/artifacts/20260530T145523Z/` and remain diagnostic rather
than claim evidence.

The browser smoke hash validator now uses JS-compatible numeric
canonicalization so reports emitted by the JS Playwright harness validate in
Python even when diagnostic deltas use small exponent-range floats.

Touched:

- `browser/chromium/src/gpu/command_buffer/service/webgpu_decoder_impl.cc`
- `browser/chromium/src/gpu/command_buffer/service/webgpu_decoder_impl.h`
- `browser/chromium/src/gpu/command_buffer/service/webgpu_decoder_unittest.cc`
- `runtime/zig/src/wgpu_dropin_lib.zig`
- `runtime/zig/src/dropin/dropin_browser_shared_memory.zig`
- `bench/tools/check_chromium_source_checkout.py`
- `bench/tools/check_doe_chromium_proc_surface.py`
- `bench/browser/browser_gate.py`
- `bench/tests/test_chromium_source_checkout.py`
- `bench/tests/test_doe_chromium_proc_surface.py`
- `bench/tests/test_browser_gate.py`
- `bench/tests/test_browser_runtime_selector_mjs.py`
- `bench/runners/run_blocking_gates.py`
- `bench/tests/test_run_blocking_gates_wiring.py`
- `browser/chromium/scripts/browser-runtime-selector.mjs`
- `browser/chromium/scripts/check-browser-benchmark-superset.py`
- `browser/chromium/scripts/check-browser-runtime-selector-policy.py`
- `config/browser-runtime-selector-policy.json`
- `config/browser-runtime-selector-policy.schema.json`
- `config/doe-chromium-proc-surface.json`
- `config/doe-chromium-proc-surface.schema.json`
- `config/browser-smoke-report.schema.json`
- `config/schema-targets.json`
- `config/webgpu-integration-chromium.json`
- `config/webgpu-integration-chromium.schema.json`
- `examples/browser-smoke-report.sample.json`
- `browser/chromium/chromium-bringup.md`
- `browser/chromium/contracts/runtime-selector-and-fallback.contract.md`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `zig build dropin-full` from `runtime/zig`
- `zig build test-full` from `runtime/zig`
- `python3 bench/tools/check_doe_chromium_proc_surface.py --require-ready --json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_chromium_source_checkout.py bench/tests/test_doe_chromium_proc_surface.py bench/tests/test_webgpu_integration_chromium_checker.py -q`
- `python3 -m py_compile bench/tools/check_chromium_source_checkout.py bench/tools/check_doe_chromium_proc_surface.py bench/tools/check_webgpu_integration_chromium.py bench/tests/test_chromium_source_checkout.py bench/tests/test_doe_chromium_proc_surface.py bench/tests/test_webgpu_integration_chromium_checker.py`
- `./browser/chromium/scripts/run-smoke.sh --chrome browser/chromium/src/out/fawn_release/Chromium.app/Contents/MacOS/Chromium --mode both --headless true --strict --upload-iters 5 --dispatch-iters 3 --suite-timeout-ms 60000 --op-timeout-ms 10000`
- `python3 browser/chromium/scripts/check-browser-smoke-report.py --smoke-report browser/chromium/artifacts/20260530T160428Z/dawn-vs-doe.browser.playwright-smoke.diagnostic.json --json`
- `autoninja -C browser/chromium/src/out/fawn_release chrome` under `browser/chromium/scripts/env.sh`
- `./browser/chromium/scripts/run-bench.sh --chrome browser/chromium/src/out/fawn_release/Chromium.app/Contents/MacOS/Chromium --mode both --headless true --strict-run`
- `./browser/chromium/scripts/run-smoke.sh --mode both --headless true --strict --upload-iters 5 --dispatch-iters 3 --suite-timeout-ms 60000 --op-timeout-ms 10000`
- `python3 browser/chromium/scripts/check-browser-smoke-report.py --smoke-report browser/chromium/artifacts/20260530T140623Z/dawn-vs-doe.browser.playwright-smoke.diagnostic.json --json`
- `node --check browser/chromium/scripts/browser-runtime-selector.mjs browser/chromium/scripts/webgpu-playwright-smoke.mjs browser/chromium/scripts/webgpu-playwright-layered-bench.mjs browser/chromium/scripts/webgpu-playwright-ort-bench.mjs`
- `python3 browser/chromium/scripts/check-browser-runtime-selector-policy.py --policy config/browser-runtime-selector-policy.json --json`
- `python3 -m py_compile bench/browser/browser_gate.py bench/tools/check_doe_chromium_proc_surface.py bench/tools/check_chromium_source_checkout.py bench/tools/check_webgpu_integration_chromium.py bench/runners/run_blocking_gates.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_doe_chromium_proc_surface.py bench/tests/test_chromium_source_checkout.py bench/tests/test_webgpu_integration_chromium_checker.py bench/tests/test_run_blocking_gates_wiring.py bench/tests/test_chromium_patch_manifest.py bench/tests/test_browser_gate.py -q`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_chromium_source_checkout.py bench/tests/test_doe_chromium_proc_surface.py bench/tests/test_webgpu_integration_chromium_checker.py bench/tests/test_run_blocking_gates_wiring.py bench/tests/test_chromium_patch_manifest.py bench/tests/test_browser_gate.py bench/tests/test_browser_runtime_selector_mjs.py bench/tests/test_browser_benchmark_superset_checker.py -q`
- `python3 bench/gates/schema_gate.py`
- `python3 bench/tools/check_webgpu_integration_chromium.py --overlay config/webgpu-integration-chromium.json --verify-artifact-root . --json`
- `python3 bench/tools/check_chromium_patch_manifest.py --manifest config/chromium-patch-manifest.json --policy config/chromium-fork-maintenance-policy.json --root . --json`
- `python3 bench/tools/check_chromium_source_checkout.py --source-root browser/chromium/src --root . --require-ready --require-runtime-selector --json` under `browser/chromium/scripts/env.sh`
- `autoninja -C browser/chromium/src/out/fawn_release gl_tests` under `browser/chromium/scripts/env.sh`
- `browser/chromium/src/out/fawn_release/gl_tests --gtest_filter=WebGPUDecoderTest.*` under `browser/chromium/scripts/env.sh`
- `git diff --check`
- `git -C browser/chromium/src diff --check -- gpu/command_buffer/service/webgpu_decoder_impl.cc gpu/command_buffer/service/webgpu_decoder_unittest.cc gpu/command_buffer/service/webgpu_decoder_impl.h gpu/config/gpu_switches.cc gpu/config/gpu_switches.h`

## 2026-05-30 — Chromium source selector is wired fail-closed

The mounted Chromium checkout now exposes the WebGPU runtime selector switches
and typed fail-closed reason markers required by the source selector gate. The
selector keeps default Dawn behavior unchanged, fails closed in forced Doe mode
for missing artifacts, disabled profiles, incomplete proc surfaces, and the
remaining Dawn-native dependency, and lets `auto` mode fall back through typed
warnings.

The Chromium integration overlay now records `source_selector_wired`. Browser
smoke artifacts remain diagnostic until Chromium's WebGPU instance and wire path
are owned by the Doe native bridge.

Touched:

- `browser/chromium/src/gpu/config/gpu_switches.h`
- `browser/chromium/src/gpu/config/gpu_switches.cc`
- `browser/chromium/src/gpu/command_buffer/service/webgpu_decoder_impl.h`
- `browser/chromium/src/gpu/command_buffer/service/webgpu_decoder_impl.cc`
- `browser/chromium/src/gpu/command_buffer/service/webgpu_decoder_unittest.cc`
- `bench/tools/check_webgpu_integration_chromium.py`
- `config/webgpu-integration-chromium.json`
- `config/webgpu-integration-chromium.schema.json`
- `browser/chromium/chromium-bringup.md`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 bench/tools/check_chromium_source_checkout.py --source-root browser/chromium/src --root . --require-runtime-selector --json` under `browser/chromium/scripts/env.sh`
- `python3 bench/tools/check_webgpu_integration_chromium.py --overlay config/webgpu-integration-chromium.json --verify-artifact-root . --json`
- `python3 -m py_compile bench/tools/check_chromium_source_checkout.py bench/tools/check_webgpu_integration_chromium.py bench/runners/run_blocking_gates.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_chromium_source_checkout.py bench/tests/test_webgpu_integration_chromium_checker.py bench/tests/test_run_blocking_gates_wiring.py bench/tests/test_chromium_patch_manifest.py -q`
- `python3 bench/gates/schema_gate.py`
- `autoninja -C browser/chromium/src/out/fawn_release gpu_unittests` under `browser/chromium/scripts/env.sh`
- `autoninja -C browser/chromium/src/out/fawn_release gl_tests` under `browser/chromium/scripts/env.sh`
- `browser/chromium/src/out/fawn_release/gl_tests --gtest_filter=WebGPUDecoderTest.*` under `browser/chromium/scripts/env.sh`

## 2026-05-27 — Browser derived artifacts reject duplicate IDs

Canvas/WebGPU fusion, GPU scheduler, WebGPU effect, and local-AI workload
checkers now reject duplicate IDs before building reference sets. Ambiguous
surface, node, work-class, pipeline, probe, and workload references can no
longer pass structural checks.

Touched:

- `browser/chromium/scripts/check-browser-canvas-webgpu-fusion.py`
- `browser/chromium/scripts/check-browser-gpu-scheduler.py`
- `browser/chromium/scripts/check-browser-webgpu-effect-experiment.py`
- `browser/chromium/scripts/check-browser-local-ai-workloads.py`
- `bench/tests/test_browser_canvas_webgpu_fusion.py`
- `bench/tests/test_browser_gpu_scheduler.py`
- `bench/tests/test_browser_webgpu_effect_experiment.py`
- `bench/tests/test_browser_local_ai_workloads.py`
- `browser/chromium/contracts/browser-canvas-webgpu-fusion.contract.md`
- `browser/chromium/contracts/browser-gpu-scheduler.contract.md`
- `browser/chromium/contracts/browser-webgpu-effect-experiment.contract.md`
- `browser/chromium/contracts/browser-local-ai-workloads.contract.md`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 -m py_compile browser/chromium/scripts/check-browser-canvas-webgpu-fusion.py browser/chromium/scripts/check-browser-gpu-scheduler.py browser/chromium/scripts/check-browser-webgpu-effect-experiment.py browser/chromium/scripts/check-browser-local-ai-workloads.py bench/tests/test_browser_canvas_webgpu_fusion.py bench/tests/test_browser_gpu_scheduler.py bench/tests/test_browser_webgpu_effect_experiment.py bench/tests/test_browser_local_ai_workloads.py`
- `python3 browser/chromium/scripts/check-browser-canvas-webgpu-fusion.py --probe examples/browser-canvas-webgpu-fusion.sample.json --json`
- `python3 browser/chromium/scripts/check-browser-gpu-scheduler.py --probe examples/browser-gpu-scheduler.sample.json --json`
- `python3 browser/chromium/scripts/check-browser-webgpu-effect-experiment.py --experiment examples/browser-webgpu-effect-experiment.sample.json --json`
- `python3 browser/chromium/scripts/check-browser-local-ai-workloads.py --workloads examples/browser-local-ai-workloads.sample.json --json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_canvas_webgpu_fusion.py bench/tests/test_browser_gpu_scheduler.py bench/tests/test_browser_webgpu_effect_experiment.py bench/tests/test_browser_local_ai_workloads.py -q`

## 2026-05-27 — Browser projection manifests use repo-relative sources

The browser benchmark superset checker now rejects absolute or
parent-traversal `sourceWorkloadsPath` and `rulesPath` values in projection
manifests before hashing the referenced files. The projection-manifest schema
now carries the same repo-relative path boundary.

Touched:

- `browser/chromium/scripts/check-browser-benchmark-superset.py`
- `browser/chromium/bench/projection-manifest.schema.json`
- `bench/tests/test_browser_benchmark_superset_checker.py`
- `browser/chromium/bench/README.md`
- `browser/chromium/contracts/browser-benchmark-superset.contract.md`
- `bench/README.md`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 -m py_compile browser/chromium/scripts/check-browser-benchmark-superset.py bench/tests/test_browser_benchmark_superset_checker.py`
- `python3 browser/chromium/scripts/check-browser-benchmark-superset.py --require-promotion-approvals --json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_benchmark_superset_checker.py -q`

## 2026-05-27 — Browser workflow approvals require contract-owner coverage

Browser workflow governance now requires the workflow manifest and promotion
approval artifact to agree exactly on required promotion roles, including the
module-contract owner. The standalone workflow checker, promotion-approval
cross-check, and layered superset checker now reject manifests that drop a
required approval role while the approvals artifact still lists it.

Touched:

- `browser/chromium/scripts/check-browser-workflow-manifest.py`
- `browser/chromium/scripts/check-browser-promotion-approvals.py`
- `browser/chromium/scripts/check-browser-benchmark-superset.py`
- `browser/chromium/bench/workflows/browser-workflow-manifest.json`
- `browser/chromium/bench/workflows/browser-workflow-manifest.schema.json`
- `browser/chromium/bench/workflows/browser-promotion-approvals.schema.json`
- `bench/tests/test_browser_workflow_governance.py`
- `bench/tests/test_browser_benchmark_superset_checker.py`
- `browser/chromium/bench/README.md`
- `browser/chromium/chromium-bringup.md`
- `browser/chromium/contracts/browser-benchmark-superset.contract.md`
- `bench/README.md`
- `docs/process.md`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 -m py_compile browser/chromium/scripts/check-browser-workflow-manifest.py browser/chromium/scripts/check-browser-promotion-approvals.py browser/chromium/scripts/check-browser-benchmark-superset.py bench/tests/test_browser_workflow_governance.py bench/tests/test_browser_benchmark_superset_checker.py`
- `python3 browser/chromium/scripts/check-browser-workflow-manifest.py --manifest browser/chromium/bench/workflows/browser-workflow-manifest.json --json`
- `python3 browser/chromium/scripts/check-browser-promotion-approvals.py --approvals browser/chromium/bench/workflows/browser-promotion-approvals.json --workflows browser/chromium/bench/workflows/browser-workflow-manifest.json --json`
- `python3 browser/chromium/scripts/check-browser-benchmark-superset.py --require-promotion-approvals --json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_workflow_governance.py bench/tests/test_browser_benchmark_superset_checker.py -q`

## 2026-05-27 — Browser milestone evidence paths are repo-relative

The browser milestone checker now rejects absolute or parent-traversal evidence
paths before checking local files. Milestone governance can no longer use a
manifest evidence row to inspect paths outside the repo while reporting local
browser-lane evidence coverage.

Touched:

- `browser/chromium/scripts/check-browser-milestones.py`
- `bench/tests/test_browser_workflow_governance.py`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 -m py_compile browser/chromium/scripts/check-browser-milestones.py bench/tests/test_browser_workflow_governance.py`
- `python3 browser/chromium/scripts/check-browser-milestones.py --manifest browser/chromium/bench/workflows/browser-milestones.json --json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_workflow_governance.py bench/tests/test_run_blocking_gates_wiring.py -q`

## 2026-05-27 — Browser unsupported taxonomy checker enforces row semantics

The browser unsupported/fallback reason taxonomy checker now validates reason
code shape, allowed categories, allowed capabilities, allowed statuses, unique
capability/status lists, category/status consistency, note presence, and the
boundary that non-visible reason codes remain diagnostic-only.

Touched:

- `bench/tools/check_browser_unsupported_reason_taxonomy.py`
- `bench/tests/test_browser_unsupported_reason_taxonomy.py`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 -m py_compile bench/tools/check_browser_unsupported_reason_taxonomy.py bench/tests/test_browser_unsupported_reason_taxonomy.py`
- `python3 bench/tools/check_browser_unsupported_reason_taxonomy.py --taxonomy config/browser-unsupported-reason-taxonomy.json --json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_unsupported_reason_taxonomy.py bench/tests/test_browser_fallback_explanations.py -q`

## 2026-05-27 — Browser capture policy checker enforces artifact policy

The standalone browser capture policy checker now validates permission-gate
taxonomy, artifact data policy taxonomy, and developer visibility for replay
surfaces. Replay-capable developer-visible artifacts no longer rely on schema
validation alone for those policy fields.

Touched:

- `bench/tools/check_browser_capture_policy.py`
- `bench/tests/test_browser_capture_policy.py`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 -m py_compile bench/tools/check_browser_capture_policy.py bench/tests/test_browser_capture_policy.py`
- `python3 bench/tools/check_browser_capture_policy.py --policy config/browser-capture-policy.json --json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_capture_policy.py -q`

## 2026-05-27 — Browser claim gate rejects unsafe patch manifest paths

The browser claim gate no longer resolves `patchIsolation.patchManifestPath`
with a raw `root / path` join. It now rejects absolute or parent-traversal
manifest paths from the fork-maintenance policy before invoking the Chromium
patch-manifest checker or recording claim-report metadata.

Touched:

- `bench/browser/browser_claim_gate.py`
- `bench/tests/test_browser_claim_gate.py`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 -m py_compile bench/browser/browser_claim_gate.py bench/tests/test_browser_claim_gate.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_claim_gate.py -q`

## 2026-05-27 — Browser release and map verifiers reject path escapes

Chromium integration overlay verification now rejects unsafe
`smokeTestArtifact` paths before loading the linked smoke report. Browser claim
promotion and release bundle verification now require referenced artifact paths
to resolve under `--verify-files-root` before hashing. Responsibility-map claim
bindings now reject absolute or parent-traversal paths before stale-reference
checks.

Touched:

- `bench/tools/check_webgpu_integration_chromium.py`
- `bench/tools/check_browser_claim_promotion_receipt.py`
- `bench/tools/check_browser_release_artifact_bundle.py`
- `bench/tools/check_browser_responsibility_map.py`
- `bench/tests/test_webgpu_integration_chromium_checker.py`
- `bench/tests/test_browser_claim_promotion_receipt.py`
- `bench/tests/test_browser_release_artifact_bundle.py`
- `bench/tests/test_browser_responsibility_map.py`
- `bench/README.md`
- `docs/process.md`
- `browser/chromium/contracts/browser-responsibility-map.contract.md`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 -m py_compile bench/tools/check_webgpu_integration_chromium.py bench/tools/check_browser_claim_promotion_receipt.py bench/tools/check_browser_release_artifact_bundle.py bench/tools/check_browser_responsibility_map.py bench/tests/test_webgpu_integration_chromium_checker.py bench/tests/test_browser_claim_promotion_receipt.py bench/tests/test_browser_release_artifact_bundle.py bench/tests/test_browser_responsibility_map.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_webgpu_integration_chromium_checker.py bench/tests/test_browser_claim_promotion_receipt.py bench/tests/test_browser_release_artifact_bundle.py bench/tests/test_browser_responsibility_map.py -q`
- `python3 bench/tools/check_webgpu_integration_chromium.py --overlay config/webgpu-integration-chromium.json --verify-artifact-root . --json`
- `python3 bench/tools/check_browser_release_artifact_bundle.py --bundle examples/browser-release-artifact-bundle.sample.json --verify-files-root . --json`
- `python3 bench/tools/check_browser_responsibility_map.py --map config/browser-responsibility-map.json --root . --json`

## 2026-05-27 — Native command graph replay verifies linked files

Native command graph receipts now emit repo-relative run-receipt and command
paths for repo-owned inputs. Replay checks gained `--verify-files-root`, which
rejects unsafe linked paths and verifies both linked file hashes before relying
on the command graph hash chain.

Touched:

- `bench/tools/build_native_command_graph_receipt.py`
- `bench/tools/replay_native_command_graph_receipt.py`
- `bench/runners/run_blocking_gates.py`
- `bench/tests/test_native_command_graph_receipt.py`
- `bench/tests/test_run_blocking_gates_wiring.py`
- `examples/native-command-graph-receipt.sample.json`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 -m py_compile bench/tools/build_native_command_graph_receipt.py bench/tools/replay_native_command_graph_receipt.py bench/runners/run_blocking_gates.py bench/tests/test_native_command_graph_receipt.py bench/tests/test_run_blocking_gates_wiring.py`
- `python3 bench/tools/build_native_command_graph_receipt.py --run-receipt examples/run-receipt.sample.json --commands examples/kernel_dispatch_commands.json --out examples/native-command-graph-receipt.sample.json`
- `python3 bench/tools/replay_native_command_graph_receipt.py --receipt examples/native-command-graph-receipt.sample.json --verify-files-root . --json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_native_command_graph_receipt.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `python3 bench/gates/schema_gate.py`
- `git diff --check`

## 2026-05-27 — Native evidence verification rejects traversal

Native no-fallback report verification now rejects absolute or parent-traversal
`runReceiptPath` values before hashing run receipts. The no-fallback report
builder emits repo-relative paths for repo-owned receipts. Native backend
coverage verification now rejects unsafe `evidencePath` values before loading
covered-row evidence.

Touched:

- `bench/tools/build_native_no_fallback_report.py`
- `bench/tools/check_native_no_fallback_report.py`
- `bench/tools/check_native_backend_coverage_matrix.py`
- `bench/tests/test_native_no_fallback_report.py`
- `bench/tests/test_native_backend_coverage_matrix.py`
- `examples/native-no-fallback-report.sample.json`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 -m py_compile bench/tools/build_native_no_fallback_report.py bench/tools/check_native_no_fallback_report.py bench/tools/check_native_backend_coverage_matrix.py bench/tests/test_native_no_fallback_report.py bench/tests/test_native_backend_coverage_matrix.py`
- `python3 bench/tools/build_native_no_fallback_report.py --run-receipt examples/run-receipt.sample.json --out examples/native-no-fallback-report.sample.json`
- `python3 bench/tools/check_native_no_fallback_report.py --report examples/native-no-fallback-report.sample.json --verify-files-root . --json`
- `python3 bench/tools/check_native_backend_coverage_matrix.py --matrix config/native-backend-coverage-matrix.json --verify-evidence-root . --json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_native_no_fallback_report.py bench/tests/test_native_backend_coverage_matrix.py bench/tests/test_native_pipeline_cache_receipts.py bench/tests/test_native_upload_path_receipts.py bench/tests/test_native_resource_reuse_receipts.py -q`
- `python3 bench/gates/schema_gate.py`
- `git diff --check`

## 2026-05-27 — Browser media and fallback evidence paths reject traversal

Browser media-path probe and fallback-explanation checkers now reject absolute
or parent-traversal developer-visible evidence paths. Media probes also validate
media source paths with the same repo-relative path rule. The media capture
policy resolver now uses the supplied path text rather than an undefined local
name.

Touched:

- `browser/chromium/scripts/check-browser-media-path-probe.py`
- `browser/chromium/scripts/check-browser-fallback-explanations.py`
- `bench/tests/test_browser_media_path_probe.py`
- `bench/tests/test_browser_fallback_explanations.py`
- `browser/chromium/contracts/browser-media-path-probe.contract.md`
- `browser/chromium/contracts/browser-fallback-explanations.contract.md`
- `examples/browser-release-artifact-bundle.sample.json`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 -m py_compile browser/chromium/scripts/check-browser-media-path-probe.py browser/chromium/scripts/check-browser-fallback-explanations.py bench/tests/test_browser_media_path_probe.py bench/tests/test_browser_fallback_explanations.py`
- `python3 browser/chromium/scripts/check-browser-media-path-probe.py --probe examples/browser-media-path-probe.sample.json --capture-policy-root . --runtime-identity-root . --json`
- `python3 browser/chromium/scripts/check-browser-fallback-explanations.py --explanations examples/browser-fallback-explanations.sample.json --taxonomy-root . --runtime-identity-root . --json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_media_path_probe.py bench/tests/test_browser_fallback_explanations.py bench/tests/test_browser_gate.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `python3 bench/tools/build_browser_release_artifact_bundle.py --bundle-id browser-release-diagnostic-sample-v1 --release-status diagnostic --browser-binary browser/chromium/out/fawn_release_local/Fawn.app/Contents/MacOS/Chromium --doe-runtime runtime/zig/zig-out/lib/libwebgpu_doe_full.dylib --shader-compiler runtime/zig/zig-out/bin/doe-zig-runtime --claim-report examples/browser-claim-report.sample.json --promotion-receipt examples/browser-claim-promotion-receipt.sample.json --out examples/browser-release-artifact-bundle.sample.json`
- `python3 bench/tools/check_browser_release_artifact_bundle.py --bundle examples/browser-release-artifact-bundle.sample.json --verify-files-root . --json`
- `python3 bench/gates/schema_gate.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py bench/tests/test_chromium_*.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `git diff --check`

## 2026-05-27 — Browser CTS and recovery paths reject traversal

Browser CTS subset and recovery parity checkers now reject absolute or
parent-traversal artifact/evidence paths while still allowing diagnostic
repo-relative paths and smoke-report fragment anchors. The new failure code is
`unsafe_artifact_path`.

Touched:

- `browser/chromium/scripts/check-browser-cts-subset.py`
- `browser/chromium/scripts/check-browser-recovery-parity.py`
- `bench/tests/test_browser_cts_subset.py`
- `bench/tests/test_browser_recovery_parity.py`
- `browser/chromium/contracts/browser-cts-subset.contract.md`
- `browser/chromium/contracts/browser-recovery-parity.contract.md`
- `examples/browser-release-artifact-bundle.sample.json`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 -m py_compile browser/chromium/scripts/check-browser-cts-subset.py browser/chromium/scripts/check-browser-recovery-parity.py bench/tests/test_browser_cts_subset.py bench/tests/test_browser_recovery_parity.py`
- `python3 browser/chromium/scripts/check-browser-cts-subset.py --subset examples/browser-cts-subset.sample.json --json`
- `python3 browser/chromium/scripts/check-browser-recovery-parity.py --parity examples/browser-recovery-parity.sample.json --json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_cts_subset.py bench/tests/test_browser_recovery_parity.py bench/tests/test_browser_gate.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `python3 bench/tools/build_browser_release_artifact_bundle.py --bundle-id browser-release-diagnostic-sample-v1 --release-status diagnostic --browser-binary browser/chromium/out/fawn_release_local/Fawn.app/Contents/MacOS/Chromium --doe-runtime runtime/zig/zig-out/lib/libwebgpu_doe_full.dylib --shader-compiler runtime/zig/zig-out/bin/doe-zig-runtime --claim-report examples/browser-claim-report.sample.json --promotion-receipt examples/browser-claim-promotion-receipt.sample.json --out examples/browser-release-artifact-bundle.sample.json`
- `python3 bench/tools/check_browser_release_artifact_bundle.py --bundle examples/browser-release-artifact-bundle.sample.json --verify-files-root . --json`
- `python3 bench/gates/schema_gate.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py bench/tests/test_chromium_*.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `git diff --check`

## 2026-05-27 — Browser pipeline cache source workload paths are repo-relative

Browser pipeline cache receipt validation now rejects unsafe
`sourceWorkloadsPath` values before loading the source local-AI workload
artifact. The checker reports `unsafe_source_workloads_path` for absolute or
parent-traversal paths and `invalid_source_workloads` for source files that do
not decode as JSON objects.

Touched:

- `browser/chromium/scripts/check-browser-pipeline-cache-receipts.py`
- `bench/tests/test_browser_pipeline_cache_receipts.py`
- `browser/chromium/contracts/browser-pipeline-cache-receipts.contract.md`
- `examples/browser-release-artifact-bundle.sample.json`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 -m py_compile browser/chromium/scripts/check-browser-pipeline-cache-receipts.py bench/tests/test_browser_pipeline_cache_receipts.py`
- `python3 browser/chromium/scripts/check-browser-pipeline-cache-receipts.py --receipts examples/browser-pipeline-cache-receipts.sample.json --verify-workloads-root . --runtime-identity-root . --json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_pipeline_cache_receipts.py bench/tests/test_browser_gate.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `python3 bench/tools/build_browser_release_artifact_bundle.py --bundle-id browser-release-diagnostic-sample-v1 --release-status diagnostic --browser-binary browser/chromium/out/fawn_release_local/Fawn.app/Contents/MacOS/Chromium --doe-runtime runtime/zig/zig-out/lib/libwebgpu_doe_full.dylib --shader-compiler runtime/zig/zig-out/bin/doe-zig-runtime --claim-report examples/browser-claim-report.sample.json --promotion-receipt examples/browser-claim-promotion-receipt.sample.json --out examples/browser-release-artifact-bundle.sample.json`
- `python3 bench/tools/check_browser_release_artifact_bundle.py --bundle examples/browser-release-artifact-bundle.sample.json --verify-files-root . --json`
- `python3 bench/gates/schema_gate.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py bench/tests/test_chromium_*.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `git diff --check`

## 2026-05-27 — Browser artifact checkers reject schema-version drift

Standalone browser artifact checkers now reject wrong top-level
`schemaVersion` values before accepting nested rows. Pipeline cache receipts
also gained the same direct `artifactKind` guard as the other browser artifact
families, and flight-recorder replay rejects source schema drift as a fatal
replay failure.

Touched:

- `browser/chromium/scripts/check-browser-canvas-webgpu-fusion.py`
- `browser/chromium/scripts/check-browser-cts-subset.py`
- `browser/chromium/scripts/check-browser-fallback-explanations.py`
- `browser/chromium/scripts/check-browser-gpu-scheduler.py`
- `browser/chromium/scripts/check-browser-local-ai-workloads.py`
- `browser/chromium/scripts/check-browser-media-path-probe.py`
- `browser/chromium/scripts/check-browser-pipeline-cache-receipts.py`
- `browser/chromium/scripts/check-browser-recovery-parity.py`
- `browser/chromium/scripts/check-browser-shader-links.py`
- `browser/chromium/scripts/check-browser-webgpu-effect-experiment.py`
- `browser/chromium/scripts/replay-browser-gpu-flight-recorder.py`
- `bench/tests/test_browser_checker_artifact_kind.py`
- `bench/tests/test_browser_gpu_flight_recorder_contract.py`
- browser artifact contract docs
- `examples/browser-release-artifact-bundle.sample.json`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 -m py_compile browser/chromium/scripts/check-browser-media-path-probe.py browser/chromium/scripts/check-browser-webgpu-effect-experiment.py browser/chromium/scripts/check-browser-canvas-webgpu-fusion.py browser/chromium/scripts/check-browser-gpu-scheduler.py browser/chromium/scripts/check-browser-local-ai-workloads.py browser/chromium/scripts/check-browser-fallback-explanations.py browser/chromium/scripts/check-browser-cts-subset.py browser/chromium/scripts/check-browser-recovery-parity.py browser/chromium/scripts/check-browser-pipeline-cache-receipts.py browser/chromium/scripts/check-browser-shader-links.py browser/chromium/scripts/replay-browser-gpu-flight-recorder.py bench/tests/test_browser_checker_artifact_kind.py bench/tests/test_browser_gpu_flight_recorder_contract.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_checker_artifact_kind.py bench/tests/test_browser_gpu_flight_recorder_contract.py bench/tests/test_browser_pipeline_cache_receipts.py bench/tests/test_browser_shader_links.py -q`
- `python3 bench/tools/build_browser_release_artifact_bundle.py --bundle-id browser-release-diagnostic-sample-v1 --release-status diagnostic --browser-binary browser/chromium/out/fawn_release_local/Fawn.app/Contents/MacOS/Chromium --doe-runtime runtime/zig/zig-out/lib/libwebgpu_doe_full.dylib --shader-compiler runtime/zig/zig-out/bin/doe-zig-runtime --claim-report examples/browser-claim-report.sample.json --promotion-receipt examples/browser-claim-promotion-receipt.sample.json --out examples/browser-release-artifact-bundle.sample.json`
- `python3 bench/tools/check_browser_release_artifact_bundle.py --bundle examples/browser-release-artifact-bundle.sample.json --verify-files-root . --json`
- `python3 bench/gates/schema_gate.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py bench/tests/test_chromium_*.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `git diff --check`

## 2026-05-27 — Browser structural checkers reject wrong artifact kinds

Browser structural checkers for derived probes, CTS subset, and recovery parity
now reject mismatched top-level `artifactKind` values before accepting internal
rows. This prevents a payload from passing a checker only because its nested
shape happens to match another browser artifact family.

Touched:

- `browser/chromium/scripts/check-browser-canvas-webgpu-fusion.py`
- `browser/chromium/scripts/check-browser-cts-subset.py`
- `browser/chromium/scripts/check-browser-fallback-explanations.py`
- `browser/chromium/scripts/check-browser-gpu-scheduler.py`
- `browser/chromium/scripts/check-browser-local-ai-workloads.py`
- `browser/chromium/scripts/check-browser-media-path-probe.py`
- `browser/chromium/scripts/check-browser-recovery-parity.py`
- `browser/chromium/scripts/check-browser-webgpu-effect-experiment.py`
- `bench/tests/test_browser_checker_artifact_kind.py`
- browser derived/CTS/recovery contract docs
- `examples/browser-release-artifact-bundle.sample.json`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 -m py_compile browser/chromium/scripts/check-browser-media-path-probe.py browser/chromium/scripts/check-browser-webgpu-effect-experiment.py browser/chromium/scripts/check-browser-canvas-webgpu-fusion.py browser/chromium/scripts/check-browser-gpu-scheduler.py browser/chromium/scripts/check-browser-local-ai-workloads.py browser/chromium/scripts/check-browser-fallback-explanations.py browser/chromium/scripts/check-browser-cts-subset.py browser/chromium/scripts/check-browser-recovery-parity.py bench/tests/test_browser_checker_artifact_kind.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_checker_artifact_kind.py bench/tests/test_browser_canvas_webgpu_fusion.py bench/tests/test_browser_cts_subset.py bench/tests/test_browser_fallback_explanations.py bench/tests/test_browser_gpu_scheduler.py bench/tests/test_browser_local_ai_workloads.py bench/tests/test_browser_media_path_probe.py bench/tests/test_browser_recovery_parity.py bench/tests/test_browser_webgpu_effect_experiment.py -q`
- `python3 bench/tools/build_browser_release_artifact_bundle.py --bundle-id browser-release-diagnostic-sample-v1 --release-status diagnostic --browser-binary browser/chromium/out/fawn_release_local/Fawn.app/Contents/MacOS/Chromium --doe-runtime runtime/zig/zig-out/lib/libwebgpu_doe_full.dylib --shader-compiler runtime/zig/zig-out/bin/doe-zig-runtime --claim-report examples/browser-claim-report.sample.json --promotion-receipt examples/browser-claim-promotion-receipt.sample.json --out examples/browser-release-artifact-bundle.sample.json`
- `python3 bench/tools/check_browser_release_artifact_bundle.py --bundle examples/browser-release-artifact-bundle.sample.json --verify-files-root . --json`
- `python3 bench/gates/schema_gate.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py bench/tests/test_chromium_*.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `git diff --check`

## 2026-05-27 — Browser flight replay binds responsibility-map version

Browser GPU flight-recorder replay now resolves the capture's
`responsibilityMap.path` under an explicit `--responsibility-map-root` and
rejects unsafe paths, missing map files, invalid map JSON, and stale
`mapVersion` values before accepting a replay report.

Touched:

- `browser/chromium/scripts/replay-browser-gpu-flight-recorder.py`
- `bench/browser/browser_gate.py`
- `bench/runners/run_blocking_gates.py`
- `bench/tests/test_browser_gpu_flight_recorder_contract.py`
- `bench/tests/test_run_blocking_gates_wiring.py`
- `browser/chromium/contracts/browser-gpu-flight-recorder.contract.md`
- `examples/browser-release-artifact-bundle.sample.json`
- `docs/process.md`
- `docs/browser-lane.md`
- `docs/chromium-webgpu-task-list.md`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 -m py_compile browser/chromium/scripts/replay-browser-gpu-flight-recorder.py bench/browser/browser_gate.py bench/runners/run_blocking_gates.py bench/tests/test_browser_gpu_flight_recorder_contract.py bench/tests/test_run_blocking_gates_wiring.py`
- `python3 browser/chromium/scripts/replay-browser-gpu-flight-recorder.py --flight-recorder examples/browser-gpu-flight-recorder.sample.json --capture-policy config/browser-capture-policy.json --responsibility-map-root . --json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_gpu_flight_recorder_contract.py bench/tests/test_browser_gate.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `python3 bench/tools/build_browser_release_artifact_bundle.py --bundle-id browser-release-diagnostic-sample-v1 --release-status diagnostic --browser-binary browser/chromium/out/fawn_release_local/Fawn.app/Contents/MacOS/Chromium --doe-runtime runtime/zig/zig-out/lib/libwebgpu_doe_full.dylib --shader-compiler runtime/zig/zig-out/bin/doe-zig-runtime --claim-report examples/browser-claim-report.sample.json --promotion-receipt examples/browser-claim-promotion-receipt.sample.json --out examples/browser-release-artifact-bundle.sample.json`
- `python3 bench/tools/check_browser_release_artifact_bundle.py --bundle examples/browser-release-artifact-bundle.sample.json --verify-files-root . --json`
- `python3 bench/gates/schema_gate.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py bench/tests/test_chromium_*.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `git diff --check`

## 2026-05-27 — Derived browser artifacts verify runtime identity references

Derived browser artifact checkers now accept `--runtime-identity-root` and
resolve `runtimeIdentity.runtimeIdentityPath` before accepting selected runtime
or fallback state. The shared checker accepts both `browser_runtime_identity`
artifacts and source browser smoke reports, which keeps sample artifacts and
smoke-generated artifacts under the same identity-binding rule.

Touched:

- `browser/chromium/scripts/browser_runtime_identity_reference.py`
- `browser/chromium/scripts/check-browser-canvas-webgpu-fusion.py`
- `browser/chromium/scripts/check-browser-media-path-probe.py`
- `browser/chromium/scripts/check-browser-gpu-scheduler.py`
- `browser/chromium/scripts/check-browser-webgpu-effect-experiment.py`
- `browser/chromium/scripts/check-browser-local-ai-workloads.py`
- `browser/chromium/scripts/check-browser-fallback-explanations.py`
- `browser/chromium/scripts/check-browser-pipeline-cache-receipts.py`
- `bench/browser/browser_gate.py`
- `bench/runners/run_blocking_gates.py`
- `bench/tests/test_browser_runtime_identity_reference.py`
- `bench/tests/test_browser_derived_runtime_identity_reference.py`
- `bench/tests/test_run_blocking_gates_wiring.py`
- browser derived artifact contract docs
- `examples/browser-release-artifact-bundle.sample.json`
- `bench/README.md`
- `docs/process.md`
- `docs/browser-lane.md`
- `docs/chromium-webgpu-task-list.md`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 -m py_compile browser/chromium/scripts/browser_runtime_identity_reference.py browser/chromium/scripts/check-browser-media-path-probe.py browser/chromium/scripts/check-browser-webgpu-effect-experiment.py browser/chromium/scripts/check-browser-canvas-webgpu-fusion.py browser/chromium/scripts/check-browser-gpu-scheduler.py browser/chromium/scripts/check-browser-local-ai-workloads.py browser/chromium/scripts/check-browser-fallback-explanations.py browser/chromium/scripts/check-browser-pipeline-cache-receipts.py bench/browser/browser_gate.py bench/runners/run_blocking_gates.py bench/tests/test_browser_runtime_identity_reference.py bench/tests/test_browser_derived_runtime_identity_reference.py bench/tests/test_run_blocking_gates_wiring.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_runtime_identity_reference.py bench/tests/test_browser_derived_runtime_identity_reference.py bench/tests/test_browser_media_path_probe.py bench/tests/test_browser_local_ai_workloads.py bench/tests/test_browser_fallback_explanations.py bench/tests/test_browser_pipeline_cache_receipts.py bench/tests/test_run_blocking_gates_wiring.py -q`
- derived checker sample commands with `--runtime-identity-root .`
- `python3 bench/tools/build_browser_release_artifact_bundle.py --bundle-id browser-release-diagnostic-sample-v1 --release-status diagnostic --browser-binary browser/chromium/out/fawn_release_local/Fawn.app/Contents/MacOS/Chromium --doe-runtime runtime/zig/zig-out/lib/libwebgpu_doe_full.dylib --shader-compiler runtime/zig/zig-out/bin/doe-zig-runtime --claim-report examples/browser-claim-report.sample.json --promotion-receipt examples/browser-claim-promotion-receipt.sample.json --out examples/browser-release-artifact-bundle.sample.json`
- `python3 bench/tools/check_browser_release_artifact_bundle.py --bundle examples/browser-release-artifact-bundle.sample.json --verify-files-root . --json`
- `python3 bench/gates/schema_gate.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py bench/tests/test_chromium_*.py bench/tests/test_run_blocking_gates_wiring.py -q`

## 2026-05-27 — Browser flight replay checks graph identity and ordering

Browser GPU flight-recorder replay now rejects duplicate command node IDs,
missing/invalid/duplicate submit IDs, ordering edges that point backward,
unknown shader/resource references, stale timing node references, and invalid
frame presentation nodes. The release bundle sample was regenerated because the
flight-recorder contract hash changed.

Touched:

- `browser/chromium/scripts/replay-browser-gpu-flight-recorder.py`
- `bench/tests/test_browser_gpu_flight_recorder_contract.py`
- `browser/chromium/contracts/browser-gpu-flight-recorder.contract.md`
- `examples/browser-release-artifact-bundle.sample.json`
- `docs/process.md`
- `docs/browser-lane.md`
- `docs/chromium-webgpu-task-list.md`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 -m py_compile browser/chromium/scripts/replay-browser-gpu-flight-recorder.py bench/tests/test_browser_gpu_flight_recorder_contract.py`
- `python3 browser/chromium/scripts/replay-browser-gpu-flight-recorder.py --flight-recorder examples/browser-gpu-flight-recorder.sample.json --capture-policy config/browser-capture-policy.json --json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_gpu_flight_recorder_contract.py -q`
- `python3 bench/tools/check_browser_release_artifact_bundle.py --bundle examples/browser-release-artifact-bundle.sample.json --verify-files-root . --json`
- `python3 bench/gates/schema_gate.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py bench/tests/test_chromium_*.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `git diff --check`

## 2026-05-27 — Browser shader links verify source flight-recorder rows

Browser shader-link validation now resolves `sourceFlightRecorderPath` with
`--verify-flight-recorder-root` and rejects missing, duplicate, extra, or
drifted shader rows before checking WGSL lowering receipts. The browser gate
and standalone blocking runner now pass the flight-recorder verification root,
and artifact identity coverage records the capture ID plus shader hash anchors.

Touched:

- `config/browser-shader-links.schema.json`
- `config/browser-artifact-identity-coverage.json`
- `browser/chromium/scripts/check-browser-shader-links.py`
- `bench/browser/browser_gate.py`
- `bench/runners/run_blocking_gates.py`
- `bench/tests/test_browser_shader_links.py`
- `bench/tests/test_run_blocking_gates_wiring.py`
- `browser/chromium/contracts/browser-shader-links.contract.md`
- `examples/browser-release-artifact-bundle.sample.json`
- `docs/process.md`
- `docs/browser-lane.md`
- `docs/chromium-webgpu-task-list.md`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 -m py_compile browser/chromium/scripts/check-browser-shader-links.py bench/browser/browser_gate.py bench/runners/run_blocking_gates.py bench/tests/test_browser_shader_links.py bench/tests/test_run_blocking_gates_wiring.py`
- `python3 browser/chromium/scripts/check-browser-shader-links.py --links examples/browser-shader-links.sample.json --verify-flight-recorder-root . --verify-lowering-root . --json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_shader_links.py bench/tests/test_browser_gate.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `python3 bench/tools/check_browser_artifact_identity_coverage.py --coverage config/browser-artifact-identity-coverage.json --root . --json`
- `python3 bench/tools/check_browser_release_artifact_bundle.py --bundle examples/browser-release-artifact-bundle.sample.json --verify-files-root . --json`
- `python3 bench/gates/schema_gate.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py bench/tests/test_chromium_*.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `git diff --check`

## 2026-05-27 — Browser pipeline cache receipts verify source workload coverage

Browser pipeline cache receipts now record `sourceWorkloadsPath`, carry shader
source/IR/backend hashes on each receipt row, and can be checked against the
source local-AI workload artifact. The checker rejects missing, duplicate,
extra, or source-drifted workload receipts when `--verify-workloads-root` is
supplied. The browser gate and standalone blocking runner both pass that root.

Touched:

- `config/browser-pipeline-cache-receipts.schema.json`
- `examples/browser-pipeline-cache-receipts.sample.json`
- `browser/chromium/scripts/build-browser-pipeline-cache-receipts.py`
- `browser/chromium/scripts/check-browser-pipeline-cache-receipts.py`
- `bench/browser/browser_gate.py`
- `bench/runners/run_blocking_gates.py`
- `bench/tests/test_browser_pipeline_cache_receipts.py`
- `bench/tests/test_run_blocking_gates_wiring.py`
- `config/browser-artifact-identity-coverage.json`
- `browser/chromium/contracts/browser-pipeline-cache-receipts.contract.md`
- `examples/browser-release-artifact-bundle.sample.json`
- `docs/process.md`
- `docs/browser-lane.md`
- `docs/chromium-webgpu-task-list.md`
- `bench/README.md`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 -m py_compile browser/chromium/scripts/check-browser-pipeline-cache-receipts.py browser/chromium/scripts/build-browser-pipeline-cache-receipts.py bench/browser/browser_gate.py bench/runners/run_blocking_gates.py bench/tests/test_browser_pipeline_cache_receipts.py bench/tests/test_run_blocking_gates_wiring.py`
- `python3 browser/chromium/scripts/check-browser-pipeline-cache-receipts.py --receipts examples/browser-pipeline-cache-receipts.sample.json --verify-workloads-root . --json`
- `python3 bench/tools/check_browser_artifact_identity_coverage.py --coverage config/browser-artifact-identity-coverage.json --root . --json`
- `python3 bench/tools/check_browser_release_artifact_bundle.py --bundle examples/browser-release-artifact-bundle.sample.json --verify-files-root . --json`
- `python3 bench/gates/schema_gate.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_pipeline_cache_receipts.py bench/tests/test_browser_gate.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py bench/tests/test_chromium_*.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `git diff --check`

## 2026-05-27 — Local AI workload receipts hash shader IR and backend output

Browser local-AI workload rows now require shader IR and backend-output hashes
alongside the existing shader source hash and path anchors. The builder emits
those hashes from smoke-derived workload evidence, and the checker rejects rows
whose shader identity does not bind source, IR, and backend output.

Touched:

- `config/browser-local-ai-workloads.schema.json`
- `examples/browser-local-ai-workloads.sample.json`
- `browser/chromium/scripts/build-browser-local-ai-workloads.py`
- `browser/chromium/scripts/check-browser-local-ai-workloads.py`
- `bench/tests/test_browser_local_ai_workloads.py`
- `browser/chromium/contracts/browser-local-ai-workloads.contract.md`
- `examples/browser-release-artifact-bundle.sample.json`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 -m py_compile browser/chromium/scripts/check-browser-local-ai-workloads.py browser/chromium/scripts/build-browser-local-ai-workloads.py bench/tests/test_browser_local_ai_workloads.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_local_ai_workloads.py -q`
- `python3 browser/chromium/scripts/check-browser-local-ai-workloads.py --workloads examples/browser-local-ai-workloads.sample.json --json`
- `python3 browser/chromium/scripts/build-browser-local-ai-workloads.py --report examples/browser-smoke-report.sample.json --mode doe --out /tmp/browser-local-ai-workloads.verify.json && python3 browser/chromium/scripts/check-browser-local-ai-workloads.py --workloads /tmp/browser-local-ai-workloads.verify.json`
- `python3 bench/tools/check_browser_artifact_identity_coverage.py --coverage config/browser-artifact-identity-coverage.json --root . --json`
- `python3 bench/tools/check_browser_release_artifact_bundle.py --bundle examples/browser-release-artifact-bundle.sample.json --verify-files-root . --json`
- `python3 bench/gates/schema_gate.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py bench/tests/test_chromium_*.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `git diff --check`

## 2026-05-27 — Browser fallback explanations use governed reason codes

Browser unsupported and fallback reason codes now have a schema-backed taxonomy.
Fallback explanation artifacts carry the taxonomy path, the checker rejects
unknown reason codes and capability/status mismatches, and release bundles
hash-bind the taxonomy with the other browser policies. The smoke harness also
passes the taxonomy into the fallback-explanations builder.

Touched:

- `config/browser-unsupported-reason-taxonomy.schema.json`
- `config/browser-unsupported-reason-taxonomy.json`
- `config/browser-fallback-explanations.schema.json`
- `examples/browser-fallback-explanations.sample.json`
- `bench/tools/check_browser_unsupported_reason_taxonomy.py`
- `browser/chromium/scripts/build-browser-fallback-explanations.py`
- `browser/chromium/scripts/check-browser-fallback-explanations.py`
- `browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `bench/browser/browser_gate.py`
- `bench/runners/run_blocking_gates.py`
- `bench/tests/test_browser_unsupported_reason_taxonomy.py`
- `bench/tests/test_browser_fallback_explanations.py`
- `bench/tools/build_browser_release_artifact_bundle.py`
- `bench/tools/check_browser_release_artifact_bundle.py`
- `bench/tests/test_browser_release_artifact_bundle.py`
- `bench/tests/test_run_blocking_gates_wiring.py`
- `config/schema-targets.json`
- `config/browser-artifact-identity-coverage.json`
- `examples/browser-release-artifact-bundle.sample.json`
- `bench/README.md`
- `docs/browser-lane.md`
- `docs/chromium-webgpu-task-list.md`
- `docs/process.md`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 -m py_compile bench/tools/check_browser_unsupported_reason_taxonomy.py browser/chromium/scripts/check-browser-fallback-explanations.py browser/chromium/scripts/build-browser-fallback-explanations.py bench/runners/run_blocking_gates.py bench/browser/browser_gate.py bench/tests/test_browser_unsupported_reason_taxonomy.py bench/tests/test_browser_fallback_explanations.py bench/tests/test_browser_release_artifact_bundle.py bench/tests/test_run_blocking_gates_wiring.py`
- `node --check browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_unsupported_reason_taxonomy.py bench/tests/test_browser_fallback_explanations.py bench/tests/test_browser_release_artifact_bundle.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `python3 bench/tools/check_browser_unsupported_reason_taxonomy.py --taxonomy config/browser-unsupported-reason-taxonomy.json --json`
- `python3 browser/chromium/scripts/check-browser-fallback-explanations.py --explanations examples/browser-fallback-explanations.sample.json --taxonomy-root . --json`
- `python3 browser/chromium/scripts/build-browser-fallback-explanations.py --report examples/browser-smoke-report.sample.json --mode doe --taxonomy config/browser-unsupported-reason-taxonomy.json --out /tmp/browser-fallback-explanations.verify.json && python3 browser/chromium/scripts/check-browser-fallback-explanations.py --explanations /tmp/browser-fallback-explanations.verify.json --taxonomy-root .`
- `python3 bench/tools/check_browser_release_artifact_bundle.py --bundle examples/browser-release-artifact-bundle.sample.json --verify-files-root . --json`
- `python3 bench/tools/check_browser_artifact_identity_coverage.py --coverage config/browser-artifact-identity-coverage.json --root . --json`
- `python3 bench/gates/schema_gate.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py bench/tests/test_chromium_*.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `git diff --check`

## 2026-05-27 — Browser artifact identity coverage is gated

Browser evidence now has a schema-backed identity coverage manifest. The
checker validates that smoke reports, flight recorders, derived browser probes,
shader links, replay reports, CTS/recovery pairs, claim reports, promotion
receipts, and release bundles carry their declared identity anchors. Browser
release bundles now hash-bind this coverage manifest with the other browser
policies.

Touched:

- `config/browser-artifact-identity-coverage.schema.json`
- `config/browser-artifact-identity-coverage.json`
- `bench/tools/check_browser_artifact_identity_coverage.py`
- `bench/tests/test_browser_artifact_identity_coverage.py`
- `bench/tools/build_browser_release_artifact_bundle.py`
- `bench/tools/check_browser_release_artifact_bundle.py`
- `bench/tests/test_browser_release_artifact_bundle.py`
- `bench/runners/run_blocking_gates.py`
- `bench/tests/test_run_blocking_gates_wiring.py`
- `config/schema-targets.json`
- `examples/browser-release-artifact-bundle.sample.json`
- `bench/README.md`
- `docs/browser-lane.md`
- `docs/chromium-webgpu-task-list.md`
- `docs/process.md`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 -m py_compile bench/tools/check_browser_artifact_identity_coverage.py bench/tools/build_browser_release_artifact_bundle.py bench/tools/check_browser_release_artifact_bundle.py bench/runners/run_blocking_gates.py bench/tests/test_browser_artifact_identity_coverage.py bench/tests/test_browser_release_artifact_bundle.py bench/tests/test_run_blocking_gates_wiring.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_artifact_identity_coverage.py bench/tests/test_browser_release_artifact_bundle.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `python3 bench/tools/check_browser_artifact_identity_coverage.py --coverage config/browser-artifact-identity-coverage.json --root . --json`
- `python3 bench/tools/check_browser_release_artifact_bundle.py --bundle examples/browser-release-artifact-bundle.sample.json --verify-files-root . --json`
- `python3 bench/gates/schema_gate.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py bench/tests/test_chromium_*.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `git diff --check`

## 2026-05-29 — Chromium source selector claims now require source markers

The browser lane no longer treats wrapper diagnostics as proof that Chromium
owns the Doe runtime seam. `check_chromium_source_checkout.py` now has a
`--require-runtime-selector` mode that requires the source checkout to expose
the runtime selector switches and typed fail-closed reason markers before
source-level selector ownership can be claimed. The Chromium integration overlay
now records the current state as `source_selector_required`; browser smoke
artifacts remain diagnostic until that source gate passes.

Current local diagnostic state: `blocked` because the external
`/Volumes/MACOS/fawn-browser` checkout is not mounted, leaving
`browser/chromium/src` as a dangling symlink.

Touched:

- `bench/tools/check_chromium_source_checkout.py`
- `config/chromium-source-checkout-check.schema.json`
- `examples/chromium-source-checkout-check.sample.json`
- `bench/runners/run_blocking_gates.py`
- `config/webgpu-integration-chromium.json`
- `config/webgpu-integration-chromium.schema.json`
- `bench/tools/check_webgpu_integration_chromium.py`
- `browser/chromium/chromium-bringup.md`
- `docs/chromium-webgpu-task-list.md`
- `docs/process.md`
- `docs/status/runtime-backends-and-bench.md`

## 2026-05-27 — Chromium source checkout has an explicit preflight gate

Chromium source-dependent seam work now has a schema-backed checkout readiness
report. The checker distinguishes repo-owned browser evidence work from
source-level Chromium patch work by validating the source root markers and
Chromium build tools. Diagnostic mode records the current blocker without
breaking source-free gates; the optional blocking-runner gate requires readiness
when source-level Chromium work is being claimed.

Current local diagnostic state: `blocked` because `browser/chromium/src` is not
present and `gclient`, `gn`, and `autoninja` are not on `PATH`.

Touched:

- `config/chromium-source-checkout-check.schema.json`
- `examples/chromium-source-checkout-check.sample.json`
- `bench/tools/check_chromium_source_checkout.py`
- `bench/tests/test_chromium_source_checkout.py`
- `bench/runners/run_blocking_gates.py`
- `bench/tests/test_run_blocking_gates_wiring.py`
- `config/schema-targets.json`
- `bench/README.md`
- `browser/chromium/chromium-bringup.md`
- `docs/chromium-webgpu-task-list.md`
- `docs/process.md`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 -m py_compile bench/tools/check_chromium_source_checkout.py bench/runners/run_blocking_gates.py bench/tests/test_chromium_source_checkout.py bench/tests/test_run_blocking_gates_wiring.py`
- `python3 bench/tools/check_chromium_source_checkout.py --source-root browser/chromium/src --root . --json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_chromium_source_checkout.py bench/tests/test_chromium_patch_manifest.py bench/tests/test_chromium_fork_maintenance_policy.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `python3 bench/gates/schema_gate.py`

## 2026-05-27 — Media path probes bind browser capture policy

Browser media-path probe artifacts now reference the `media_path_probe` row in
`config/browser-capture-policy.json`. The checker validates that the referenced
policy row is origin scoped, secure-context/DevTools gated, hash-only for raw
page data, redacted/hash-only for artifacts, non-replayable, and developer
visible before accepting external-texture or media-copy diagnostics.

Touched:

- `config/browser-capture-policy.schema.json`
- `config/browser-capture-policy.json`
- `config/browser-media-path-probe.schema.json`
- `bench/tools/check_browser_capture_policy.py`
- `browser/chromium/scripts/build-browser-media-path-probe.py`
- `browser/chromium/scripts/check-browser-media-path-probe.py`
- `browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `bench/browser/browser_gate.py`
- `bench/runners/run_blocking_gates.py`
- `bench/tests/test_browser_media_path_probe.py`
- `bench/tests/test_browser_capture_policy.py`
- `bench/tests/test_run_blocking_gates_wiring.py`
- `browser/chromium/contracts/browser-media-path-probe.contract.md`
- `examples/browser-media-path-probe.sample.json`
- `examples/browser-release-artifact-bundle.sample.json`
- `bench/README.md`
- `docs/browser-lane.md`
- `docs/chromium-webgpu-task-list.md`
- `docs/process.md`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 -m py_compile browser/chromium/scripts/check-browser-media-path-probe.py browser/chromium/scripts/build-browser-media-path-probe.py bench/tools/check_browser_capture_policy.py bench/browser/browser_gate.py bench/runners/run_blocking_gates.py bench/tests/test_browser_media_path_probe.py bench/tests/test_browser_capture_policy.py bench/tests/test_browser_gate.py bench/tests/test_run_blocking_gates_wiring.py bench/tests/test_browser_release_artifact_bundle.py`
- `node --check browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_media_path_probe.py bench/tests/test_browser_capture_policy.py bench/tests/test_browser_gate.py bench/tests/test_run_blocking_gates_wiring.py bench/tests/test_browser_release_artifact_bundle.py -q`
- `python3 bench/tools/check_browser_capture_policy.py --policy config/browser-capture-policy.json --json`
- `python3 browser/chromium/scripts/check-browser-media-path-probe.py --probe examples/browser-media-path-probe.sample.json --capture-policy-root . --json`
- `python3 browser/chromium/scripts/build-browser-media-path-probe.py --report examples/browser-smoke-report.sample.json --mode doe --capture-policy config/browser-capture-policy.json --out /tmp/browser-media-path-probe.verify.json && python3 browser/chromium/scripts/check-browser-media-path-probe.py --probe /tmp/browser-media-path-probe.verify.json --capture-policy-root .`
- `python3 bench/tools/check_browser_release_artifact_bundle.py --bundle examples/browser-release-artifact-bundle.sample.json --verify-files-root . --json`
- `python3 bench/gates/schema_gate.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `git diff --check`

## 2026-05-27 — Browser release bundles bind Chromium patch manifest

Browser release artifact bundles now include `config/chromium-patch-manifest.json`
as a required policy artifact. The bundle checker rejects release evidence that
binds the fork-maintenance policy without the manifest that enumerates the
browser-owned Chromium integration delta.

Touched:

- `bench/tools/build_browser_release_artifact_bundle.py`
- `bench/tools/check_browser_release_artifact_bundle.py`
- `bench/tests/test_browser_release_artifact_bundle.py`
- `examples/browser-release-artifact-bundle.sample.json`
- `bench/README.md`
- `docs/process.md`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 -m py_compile bench/tools/build_browser_release_artifact_bundle.py bench/tools/check_browser_release_artifact_bundle.py bench/tests/test_browser_release_artifact_bundle.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_release_artifact_bundle.py -q`
- `python3 bench/tools/check_browser_release_artifact_bundle.py --bundle examples/browser-release-artifact-bundle.sample.json --verify-files-root . --json`
- `python3 bench/gates/schema_gate.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_release_artifact_bundle.py bench/tests/test_browser_shader_links.py bench/tests/test_browser_gpu_flight_recorder_contract.py bench/tests/test_chromium_patch_manifest.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py bench/tests/test_wgsl_*.py bench/tests/test_native_*.py bench/tests/test_webgpu_integration_chromium_checker.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `git diff --check`

## 2026-05-27 — Browser shader links bind WGSL lowering receipts

Browser shader-link artifacts now carry the WGSL lowering receipt path and row
ID for each shader. The shader-link checker can verify those anchors against
`wgsl_lowering_link_receipt` rows, including source hash, IR hash, backend
target, and backend output hash equality.

Touched:

- `config/browser-gpu-flight-recorder.schema.json`
- `config/browser-shader-links.schema.json`
- `examples/browser-gpu-flight-recorder.sample.json`
- `examples/browser-shader-links.sample.json`
- `browser/chromium/scripts/build-browser-shader-links.py`
- `browser/chromium/scripts/check-browser-shader-links.py`
- `browser/chromium/contracts/browser-shader-links.contract.md`
- `bench/browser/browser_gate.py`
- `bench/runners/run_blocking_gates.py`
- `bench/tests/test_browser_gpu_flight_recorder_contract.py`
- `bench/tests/test_browser_shader_links.py`
- `bench/tests/test_run_blocking_gates_wiring.py`
- `docs/chromium-webgpu-task-list.md`
- `docs/process.md`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 -m py_compile browser/chromium/scripts/build-browser-shader-links.py browser/chromium/scripts/check-browser-shader-links.py bench/browser/browser_gate.py bench/runners/run_blocking_gates.py bench/tests/test_browser_shader_links.py bench/tests/test_browser_gpu_flight_recorder_contract.py bench/tests/test_run_blocking_gates_wiring.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_shader_links.py bench/tests/test_browser_gpu_flight_recorder_contract.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `python3 browser/chromium/scripts/check-browser-shader-links.py --links examples/browser-shader-links.sample.json --verify-lowering-root . --json`
- `python3 browser/chromium/scripts/build-browser-shader-links.py --flight-recorder examples/browser-gpu-flight-recorder.sample.json --out /tmp/browser-shader-links.verify.json`
- `python3 browser/chromium/scripts/check-browser-shader-links.py --links /tmp/browser-shader-links.verify.json --verify-lowering-root .`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py bench/tests/test_wgsl_*.py bench/tests/test_native_*.py bench/tests/test_webgpu_integration_chromium_checker.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `python3 bench/gates/schema_gate.py`
- `git diff --check`

## 2026-05-27 — Chromium patch manifest gates fork isolation

Chromium fork policy now names a schema-backed patch manifest. The manifest
records repo-owned browser integration deltas, allowed patch roots, rollback
paths, evidence paths, and whether a row needs a Chromium source checkout.
`check_chromium_patch_manifest.py` validates those rows against the fork policy
and the promoted browser gate, repeated browser claim gate, and blocking runner
can all enforce the manifest.

Touched:

- `config/chromium-patch-manifest.schema.json`
- `config/chromium-patch-manifest.json`
- `config/chromium-fork-maintenance-policy.schema.json`
- `config/chromium-fork-maintenance-policy.json`
- `config/schema-targets.json`
- `bench/tools/check_chromium_patch_manifest.py`
- `bench/tools/check_chromium_fork_maintenance_policy.py`
- `bench/browser/browser_gate.py`
- `bench/browser/browser_claim_gate.py`
- `bench/runners/run_blocking_gates.py`
- `bench/tests/test_chromium_patch_manifest.py`
- `bench/tests/test_chromium_fork_maintenance_policy.py`
- `bench/tests/test_run_blocking_gates_wiring.py`
- `bench/README.md`
- `docs/process.md`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 -m py_compile bench/tools/check_chromium_patch_manifest.py bench/tools/check_chromium_fork_maintenance_policy.py bench/tests/test_chromium_patch_manifest.py bench/tests/test_chromium_fork_maintenance_policy.py bench/browser/browser_gate.py bench/browser/browser_claim_gate.py bench/runners/run_blocking_gates.py bench/tests/test_run_blocking_gates_wiring.py`
- `python3 bench/tools/check_chromium_fork_maintenance_policy.py --policy config/chromium-fork-maintenance-policy.json --root . --json`
- `python3 bench/tools/check_chromium_patch_manifest.py --manifest config/chromium-patch-manifest.json --policy config/chromium-fork-maintenance-policy.json --root . --json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_chromium_patch_manifest.py bench/tests/test_chromium_fork_maintenance_policy.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_gate.py bench/tests/test_browser_claim_gate.py bench/tests/test_browser_runtime_selector_policy.py bench/tests/test_browser_runtime_selector_mjs.py -q`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py bench/tests/test_wgsl_*.py bench/tests/test_native_*.py bench/tests/test_webgpu_integration_chromium_checker.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `python3 bench/gates/schema_gate.py`
- `git diff --check`

## 2026-05-26 — Blocking runner can gate standalone evidence artifacts

The canonical blocking runner can now call the standalone browser, WGSL, and
native artifact checkers through opt-in flags. Browser milestone, policy,
probe, promotion, release, and replay artifacts, WGSL corpus/diagnostic/
robustness/lowering evidence, and native upload/cache/reuse/command-graph/
no-fallback/coverage receipts can be promoted through `run_blocking_gates.py`
without a parallel gate path.

The browser smoke harness now normalizes path arguments before spawning
artifact builders, so relative `--out` and evidence paths work through the lane
wrappers even though builders run from the repo root. A local forced-Doe/both
smoke run produced and validated the browser task-ledger artifacts under
`browser/chromium/artifacts/20260526T223345Z/`.
The smoke report itself now has a standalone checker and opt-in blocking-runner
gate. It validates the diagnostic partition, strict-mode evidence, forced
runtime identity, hidden-fallback state, adapter/compiler identity, workload
identity, report hash, and mode-result hash chain without launching Chromium.
The sample smoke report is now covered by `config/browser-smoke-report.schema.json`
and the schema target registry.
Flight-recorder replay is now exposed as its own blocking-runner gate, so an
existing `browser_gpu_flight_recorder` artifact can be replayed against the
browser capture policy without running the full browser diagnostic gate.
Browser claim-promotion receipts are also exposed as a standalone
blocking-runner gate, so forced-Doe/no-hidden-fallback promotion evidence can be
checked without rerunning the browser claim window.
The browser milestone manifest is now registered with schema gate and exposed as
`--with-browser-milestones-gate`.
The browser promotion-approval and workflow manifests are now registered with
schema gate as well, so all browser workflow governance JSON under
`browser/chromium/bench/workflows/` is schema-checked.
Those governance manifests now also have standalone semantic checkers and
blocking-runner hooks for approval role coverage, approval state, workflow row
requirements, L2 claim scope, metric uniqueness, and L0-boundary claim language.
Browser runtime identity now has a standalone semantic checker and blocking
runner hook. The package identity producer only marks Doe active when Chromium
selector evidence explicitly reports `fallbackApplied=false` and
`hiddenFallbackAllowed=false`.
The Chromium integration overlay now has a semantic checker and blocking-runner
hook for required browser seam coverage, external-texture blocked state,
wire-protocol notes, and optional smoke-artifact linkage.
The overlay now points at an existing local smoke artifact so
`--verify-artifact-root .` exercises the linkage instead of only schema shape.
Browser claim policies now have a standalone semantic checker and blocking
runner hook. The release policy is schema-registered alongside the local policy.
Browser ownership now has a standalone semantic checker and blocking-runner hook
for promoted runtime-integration, compatibility, and methodology ownership.
Browser claim reports now have a schema-backed sample, and the browser
promotion/release sample artifacts have builder-computed hashes instead of
placeholder hashes. The promotion receipt sample verifies against repo files;
the release bundle sample verifies on this host against the local browser,
runtime, and compiler artifacts named in the bundle.
The native no-fallback and WGSL corpus materialization samples now also pass
their strict file-verification modes: the no-fallback report is generated from
the sample run receipt, and the WGSL corpus materialization receipt points at
tracked materialized WGSL files under `examples/`.
WGSL lowering-link and minimization receipts now have file-verification modes as
well. The lowering-link checker verifies source hashes and linked Doe receipt
paths; the minimization checker verifies source and candidate WGSL hashes.

Touched:

- `bench/runners/run_blocking_gates.py`
- `bench/tools/build_browser_claim_promotion_receipt.py`
- `bench/browser/browser_gate.py`
- `bench/tests/test_browser_gate.py`
- `bench/tests/test_run_blocking_gates_wiring.py`
- `bench/tests/test_browser_runtime_identity_checker.py`
- `bench/tests/test_webgpu_integration_chromium_checker.py`
- `bench/tests/test_browser_claim_policy_checker.py`
- `bench/tests/test_browser_claim_promotion_receipt.py`
- `bench/tests/test_browser_ownership_checker.py`
- `bench/tests/test_browser_workflow_governance.py`
- `bench/tests/test_native_no_fallback_report.py`
- `bench/tests/test_wgsl_corpus_manifest.py`
- `bench/tests/test_wgsl_lowering_link_receipt.py`
- `bench/tests/test_wgsl_minimization_receipt.py`
- `bench/tools/check_webgpu_integration_chromium.py`
- `bench/tools/check_wgsl_lowering_link_receipt.py`
- `bench/tools/check_wgsl_minimization_receipt.py`
- `bench/tools/check_browser_claim_policy.py`
- `bench/tools/check_browser_ownership.py`
- `browser/chromium/scripts/check-browser-smoke-report.py`
- `browser/chromium/scripts/check-browser-runtime-identity.py`
- `browser/chromium/scripts/check-browser-promotion-approvals.py`
- `browser/chromium/scripts/check-browser-workflow-manifest.py`
- `config/browser-claim-report.schema.json`
- `config/browser-smoke-report.schema.json`
- `config/schema-targets.json`
- `examples/browser-claim-report.sample.json`
- `examples/browser-claim-promotion-receipt.sample.json`
- `examples/browser-release-artifact-bundle.sample.json`
- `examples/browser-smoke-report.sample.json`
- `examples/native-no-fallback-report.sample.json`
- `examples/wgsl-corpus-materialization.sample.json`
- `examples/wgsl-corpus-materialized/browser-wgsl-corpus-v0/`
- `examples/wgsl-lowering-link-receipt.sample.json`
- `examples/wgsl-minimization-receipt.sample.json`
- `examples/wgsl-minimize/invalid-missing-return/`
- `browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `browser/chromium/chromium-bringup.md`
- `packages/doe-gpu/src/browser.js`
- `packages/doe-gpu/test/unit/browser-runtime-identity.test.js`
- `bench/README.md`
- `docs/process.md`

Verified:

- `python3 -m py_compile bench/browser/browser_gate.py browser/chromium/scripts/check-browser-smoke-report.py bench/runners/run_blocking_gates.py bench/tests/test_browser_gate.py bench/tests/test_run_blocking_gates_wiring.py`
- `python3 -m py_compile browser/chromium/scripts/check-browser-runtime-identity.py bench/tests/test_browser_runtime_identity_checker.py`
- `python3 -m py_compile bench/tools/check_webgpu_integration_chromium.py bench/tests/test_webgpu_integration_chromium_checker.py`
- `python3 -m py_compile bench/tools/check_browser_claim_policy.py bench/tests/test_browser_claim_policy_checker.py`
- `python3 -m py_compile bench/tools/check_browser_ownership.py bench/tests/test_browser_ownership_checker.py`
- `python3 -m py_compile browser/chromium/scripts/check-browser-promotion-approvals.py browser/chromium/scripts/check-browser-workflow-manifest.py bench/tests/test_browser_workflow_governance.py`
- `python3 -m py_compile bench/tools/build_browser_claim_promotion_receipt.py bench/tools/build_browser_release_artifact_bundle.py bench/tests/test_browser_claim_promotion_receipt.py bench/tests/test_browser_release_artifact_bundle.py`
- `python3 -m py_compile bench/tools/build_native_no_fallback_report.py bench/tools/check_native_no_fallback_report.py bench/tools/materialize_wgsl_corpus_manifest.py bench/tools/check_wgsl_corpus_materialization.py bench/tests/test_native_no_fallback_report.py bench/tests/test_wgsl_corpus_manifest.py`
- `python3 -m py_compile bench/tools/check_wgsl_lowering_link_receipt.py bench/tools/check_wgsl_minimization_receipt.py bench/tests/test_wgsl_lowering_link_receipt.py bench/tests/test_wgsl_minimization_receipt.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_gate.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_runtime_identity_checker.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_webgpu_integration_chromium_checker.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_claim_policy_checker.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_claim_promotion_receipt.py bench/tests/test_browser_release_artifact_bundle.py -q`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_native_no_fallback_report.py bench/tests/test_wgsl_corpus_manifest.py -q`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_wgsl_lowering_link_receipt.py bench/tests/test_wgsl_minimization_receipt.py -q`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_ownership_checker.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_workflow_governance.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `python3 browser/chromium/scripts/check-browser-runtime-identity.py --identity examples/browser-runtime-identity.sample.json`
- `python3 browser/chromium/scripts/check-browser-promotion-approvals.py --approvals browser/chromium/bench/workflows/browser-promotion-approvals.json`
- `python3 browser/chromium/scripts/check-browser-workflow-manifest.py --manifest browser/chromium/bench/workflows/browser-workflow-manifest.json`
- `python3 bench/tools/check_webgpu_integration_chromium.py --overlay config/webgpu-integration-chromium.json`
- `python3 bench/tools/check_webgpu_integration_chromium.py --overlay config/webgpu-integration-chromium.json --verify-artifact-root .`
- `python3 bench/tools/check_browser_claim_policy.py --policy config/browser-claim-policy.json`
- `python3 bench/tools/check_browser_claim_policy.py --policy config/browser-claim-policy.release.json`
- `python3 bench/tools/check_browser_claim_promotion_receipt.py --receipt examples/browser-claim-promotion-receipt.sample.json --verify-files-root .`
- `python3 bench/tools/check_browser_release_artifact_bundle.py --bundle examples/browser-release-artifact-bundle.sample.json --verify-files-root .`
- `python3 bench/tools/check_browser_ownership.py --ownership config/browser-ownership.json`
- `python3 bench/tools/check_native_no_fallback_report.py --report examples/native-no-fallback-report.sample.json --verify-files-root .`
- `python3 bench/tools/check_wgsl_corpus_materialization.py --receipt examples/wgsl-corpus-materialization.sample.json --verify-files-root .`
- `python3 bench/tools/check_wgsl_lowering_link_receipt.py --receipt examples/wgsl-lowering-link-receipt.sample.json --verify-files-root .`
- `python3 bench/tools/check_wgsl_minimization_receipt.py --receipt examples/wgsl-minimization-receipt.sample.json --verify-files-root .`
- `node packages/doe-gpu/test/unit/browser-runtime-identity.test.js`
- `python3 browser/chromium/scripts/check-browser-smoke-report.py --smoke-report examples/browser-smoke-report.sample.json`
- `python3 browser/chromium/scripts/check-browser-smoke-report.py --smoke-report browser/chromium/artifacts/20260526T223345Z/dawn-vs-doe.browser.playwright-smoke.diagnostic.json`
- `python3 browser/chromium/scripts/replay-browser-gpu-flight-recorder.py --flight-recorder examples/browser-gpu-flight-recorder.sample.json --capture-policy config/browser-capture-policy.json --out /tmp/browser-gpu-flight-replay.gate.json`
- `python3 bench/tools/check_browser_claim_promotion_receipt.py --receipt examples/browser-claim-promotion-receipt.sample.json`
- `python3 browser/chromium/scripts/check-browser-milestones.py --manifest browser/chromium/bench/workflows/browser-milestones.json`
- `node --check browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_smoke_flight_recorder_flags.py bench/tests/test_browser_gate.py -q`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py bench/tests/test_wgsl_*.py bench/tests/test_native_*.py bench/tests/test_run_blocking_gates_wiring.py -q`
- `python3 bench/gates/schema_gate.py`
- `git diff --check`
- `./scripts/run-smoke.sh --mode both --headless true --strict --out artifacts/20260526T223345Z/dawn-vs-doe.browser.playwright-smoke.diagnostic.json` with all optional browser artifact output flags enabled
- `python3 browser/chromium/scripts/check-browser-benchmark-superset.py`
- `python3 bench/tools/check_native_pipeline_cache_receipts.py --receipts examples/native-pipeline-cache-receipts.sample.json`

## 2026-05-26 — Native coverage matrix can verify evidence files

The native backend coverage matrix checker now accepts `--verify-evidence-root`
to resolve covered-row evidence paths, require the files to exist, and validate
that the referenced artifact kind matches the coverage class.

Touched:

- `bench/tools/check_native_backend_coverage_matrix.py`
- `bench/tests/test_native_backend_coverage_matrix.py`

Verified:

- `python3 -m py_compile bench/tools/check_native_backend_coverage_matrix.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_native_backend_coverage_matrix.py -q`
- `python3 bench/tools/check_native_backend_coverage_matrix.py --matrix config/native-backend-coverage-matrix.json --verify-evidence-root .`

## 2026-05-26 — Native command graph sample is replay-valid

The native command graph sample now carries the replay-computed row hash and
terminal trace hash. The native command graph test suite validates the sample
against the schema and replay checker so sample evidence cannot drift from the
hash-chain contract.

Touched:

- `examples/native-command-graph-receipt.sample.json`
- `bench/tests/test_native_command_graph_receipt.py`

Verified:

- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_native_command_graph_receipt.py -q`
- `python3 bench/tools/replay_native_command_graph_receipt.py --receipt examples/native-command-graph-receipt.sample.json`
- `python3 bench/gates/schema_gate.py`

## 2026-05-26 — Native no-fallback reports have a standalone checker

Strict native no-fallback reports now have an independent checker. It validates
native Doe runtime identity, disabled fallback state, row/summary consistency,
failure mirroring, and can optionally verify source run-receipt hashes.

Touched:

- `bench/tools/check_native_no_fallback_report.py`
- `bench/tests/test_native_no_fallback_report.py`

Verified:

- `python3 -m py_compile bench/tools/check_native_no_fallback_report.py bench/tools/build_native_no_fallback_report.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_native_no_fallback_report.py -q`
- `python3 bench/tools/check_native_no_fallback_report.py --report examples/native-no-fallback-report.sample.json`

## 2026-05-26 — Browser release bundles bind promotion receipts

Browser release artifact bundles now carry `promotionReceipts` alongside claim
reports. The bundle builder hashes browser claim promotion receipts, the schema
requires them, and the checker rejects bundles without
`browser_claim_promotion_receipt` evidence. When file verification is enabled,
the checker also validates promotion receipts and requires them to cover every
bundled claim report hash.
Default release bundles now bind the active Track A browser contracts used by
the runtime selector, benchmark superset, claim methodology, responsibility
map, CTS subset, recovery parity, flight recorder, shader links, and
smoke-derived capability artifacts.

Touched:

- `bench/tools/build_browser_release_artifact_bundle.py`
- `bench/tools/check_browser_release_artifact_bundle.py`
- `config/browser-release-artifact-bundle.schema.json`
- `examples/browser-release-artifact-bundle.sample.json`
- `bench/tests/test_browser_release_artifact_bundle.py`
- `bench/README.md`
- `browser/chromium/README.md`

Verified:

- `python3 -m py_compile bench/tools/build_browser_release_artifact_bundle.py bench/tools/check_browser_release_artifact_bundle.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_release_artifact_bundle.py -q`
- `python3 bench/tools/check_browser_release_artifact_bundle.py --bundle examples/browser-release-artifact-bundle.sample.json`
- `python3 -m py_compile bench/tools/check_browser_release_artifact_bundle.py bench/tools/check_browser_claim_promotion_receipt.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_release_artifact_bundle.py bench/tests/test_browser_claim_promotion_receipt.py -q`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_release_artifact_bundle.py -q`
- `python3 bench/tools/check_browser_release_artifact_bundle.py --bundle examples/browser-release-artifact-bundle.sample.json && python3 bench/gates/schema_gate.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py -q`
- `python3 bench/gates/schema_gate.py`
- `git diff --check`

## 2026-05-26 — Browser gate validates flight recorder and shader links

The promoted browser diagnostic gate now asks smoke to emit a forced-Doe
`browser_gpu_flight_recorder` and paired `browser_shader_links` artifact. The
gate replays the flight recorder through the capture-policy-governed replay
checker, validates shader links with a standalone checker, and preserves the
new artifacts in repeated browser-claim windows.

Touched:

- `bench/browser/browser_gate.py`
- `bench/browser/browser_claim_gate.py`
- `browser/chromium/scripts/check-browser-shader-links.py`
- `bench/tests/test_browser_gate.py`
- `bench/tests/test_browser_claim_gate.py`
- `bench/tests/test_browser_shader_links.py`
- `docs/process.md`
- `browser/chromium/README.md`

Verified:

- `python3 -m py_compile browser/chromium/scripts/check-browser-shader-links.py browser/chromium/scripts/replay-browser-gpu-flight-recorder.py bench/browser/browser_gate.py bench/browser/browser_claim_gate.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_shader_links.py bench/tests/test_browser_gate.py bench/tests/test_browser_claim_gate.py bench/tests/test_browser_gpu_flight_recorder_contract.py -q`
- `python3 browser/chromium/scripts/check-browser-shader-links.py --links examples/browser-shader-links.sample.json && python3 browser/chromium/scripts/replay-browser-gpu-flight-recorder.py --flight-recorder examples/browser-gpu-flight-recorder.sample.json --capture-policy config/browser-capture-policy.json --out /tmp/browser-gpu-flight-replay.json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py -q`
- `python3 bench/gates/schema_gate.py`
- `git diff --check`

## 2026-05-26 — Browser pipeline cache receipts have a standalone checker

Browser pipeline cache receipt validation now lives in
`check-browser-pipeline-cache-receipts.py`. The promoted browser gate calls the
same checker as standalone validation, so cache-state, creation-status, hidden
fallback, and fallback-reason failures are enforced consistently.

Touched:

- `browser/chromium/scripts/check-browser-pipeline-cache-receipts.py`
- `bench/browser/browser_gate.py`
- `bench/tests/test_browser_pipeline_cache_receipts.py`
- `bench/tests/test_browser_gate.py`

Verified:

- `python3 -m py_compile browser/chromium/scripts/check-browser-pipeline-cache-receipts.py bench/browser/browser_gate.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_pipeline_cache_receipts.py bench/tests/test_browser_gate.py -q`
- `python3 browser/chromium/scripts/check-browser-pipeline-cache-receipts.py --receipts examples/browser-pipeline-cache-receipts.sample.json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py -q`
- `python3 bench/gates/schema_gate.py`
- `git diff --check`

## 2026-05-26 — Browser release bundles bind capture policy

Browser release artifact bundle defaults and checks now include
`config/browser-capture-policy.json`. Release evidence therefore hash-binds the
origin-scope, raw-page-data, replay, and developer-visibility policy used by
browser capture artifacts.

Touched:

- `bench/tools/build_browser_release_artifact_bundle.py`
- `bench/tools/check_browser_release_artifact_bundle.py`
- `bench/tests/test_browser_release_artifact_bundle.py`
- `examples/browser-release-artifact-bundle.sample.json`

Verified:

- `python3 -m py_compile bench/tools/build_browser_release_artifact_bundle.py bench/tools/check_browser_release_artifact_bundle.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_release_artifact_bundle.py -q`
- `python3 bench/tools/check_browser_release_artifact_bundle.py --bundle examples/browser-release-artifact-bundle.sample.json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py -q`
- `python3 bench/gates/schema_gate.py`
- `git diff --check`

## 2026-05-26 — Browser claim windows preserve gate artifact maps

The repeated browser claim gate now preserves the full per-window browser-gate
artifact map in claim reports, including CTS subset, recovery parity, and
smoke-derived capability probe artifacts. Reused artifact roots discover the
same known artifact names when present so older windows remain readable while
new windows keep the richer evidence map.

Touched:

- `bench/browser/browser_claim_gate.py`
- `bench/tests/test_browser_claim_gate.py`

Verified:

- `python3 -m py_compile bench/browser/browser_claim_gate.py bench/tests/test_browser_claim_gate.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_claim_gate.py bench/tests/test_browser_claim_promotion_receipt.py -q`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py -q`
- `python3 bench/gates/schema_gate.py`
- `git diff --check`

## 2026-05-26 — Browser gate emits capability probe artifacts

The promoted browser diagnostic gate now asks the smoke runner to emit the
smoke-derived browser capability artifacts and validates them before accepting
the gate report: canvas/WebGPU fusion, media-path probe, GPU scheduler, WebGPU
effect experiment, local AI workloads, pipeline cache receipts, and fallback
explanations. Gate output records each artifact path, hash, and per-artifact
ok status.

Touched:

- `bench/browser/browser_gate.py`
- `bench/tests/test_browser_gate.py`
- `docs/process.md`

Verified:

- `python3 -m py_compile bench/browser/browser_gate.py browser/chromium/scripts/check-browser-canvas-webgpu-fusion.py browser/chromium/scripts/check-browser-media-path-probe.py browser/chromium/scripts/check-browser-gpu-scheduler.py browser/chromium/scripts/check-browser-webgpu-effect-experiment.py browser/chromium/scripts/check-browser-local-ai-workloads.py browser/chromium/scripts/build-browser-pipeline-cache-receipts.py browser/chromium/scripts/check-browser-fallback-explanations.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_gate.py bench/tests/test_browser_canvas_webgpu_fusion.py bench/tests/test_browser_media_path_probe.py bench/tests/test_browser_gpu_scheduler.py bench/tests/test_browser_webgpu_effect_experiment.py bench/tests/test_browser_local_ai_workloads.py bench/tests/test_browser_pipeline_cache_receipts.py bench/tests/test_browser_fallback_explanations.py -q`
- `python3 browser/chromium/scripts/check-browser-canvas-webgpu-fusion.py --probe examples/browser-canvas-webgpu-fusion.sample.json && python3 browser/chromium/scripts/check-browser-media-path-probe.py --probe examples/browser-media-path-probe.sample.json && python3 browser/chromium/scripts/check-browser-gpu-scheduler.py --probe examples/browser-gpu-scheduler.sample.json && python3 browser/chromium/scripts/check-browser-webgpu-effect-experiment.py --experiment examples/browser-webgpu-effect-experiment.sample.json && python3 browser/chromium/scripts/check-browser-local-ai-workloads.py --workloads examples/browser-local-ai-workloads.sample.json && python3 browser/chromium/scripts/build-browser-pipeline-cache-receipts.py --workloads examples/browser-local-ai-workloads.sample.json --out /tmp/browser-pipeline-cache-receipts.json && python3 browser/chromium/scripts/check-browser-fallback-explanations.py --explanations examples/browser-fallback-explanations.sample.json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py -q`
- `python3 bench/gates/schema_gate.py`
- `git diff --check`

## 2026-05-26 — Browser gate emits recovery parity evidence

The promoted browser diagnostic gate now asks the smoke runner to emit
`browser_recovery_parity` and validates it before accepting the gate report.
Gate output records the recovery parity path, recovery parity hash, and
`recoveryParityOk` status alongside smoke, CTS subset, and layered evidence.

Touched:

- `bench/browser/browser_gate.py`
- `bench/tests/test_browser_gate.py`
- `docs/process.md`

Verified:

- `python3 -m py_compile bench/browser/browser_gate.py browser/chromium/scripts/check-browser-recovery-parity.py browser/chromium/scripts/build-browser-recovery-parity.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_gate.py bench/tests/test_browser_recovery_parity.py -q`
- `python3 browser/chromium/scripts/check-browser-recovery-parity.py --parity examples/browser-recovery-parity.sample.json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py -q`
- `python3 bench/gates/schema_gate.py`
- `git diff --check`

## 2026-05-26 — Browser gates enforce capture policy

The single-window browser gate now runs the browser capture-policy checker
before browser preflight. The repeated browser claim gate checks the same policy
before accepting new or reused windows and forwards the policy path to each
browser-gate window. Gate reports and claim reports record the policy path used
for origin scope, raw-page-data handling, replay permission, and developer
visibility.

Touched:

- `bench/browser/browser_gate.py`
- `bench/browser/browser_claim_gate.py`
- `docs/process.md`

Verified:

- `python3 -m py_compile bench/browser/browser_gate.py bench/browser/browser_claim_gate.py bench/tools/check_browser_capture_policy.py`
- `python3 bench/tools/check_browser_capture_policy.py --policy config/browser-capture-policy.json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_capture_policy.py bench/tests/test_browser_gate.py -q`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py -q`
- `python3 bench/gates/schema_gate.py`
- `git diff --check`

## 2026-05-26 — Browser release bundles require claim policy binding

Browser release artifact bundle checks now require the browser claim policy
artifact in addition to runtime-selector and fork-maintenance policies. This
keeps a release bundle from hash-binding claim reports without also binding the
policy that made those reports promotable.

Touched:

- `bench/tools/check_browser_release_artifact_bundle.py`
- `bench/tests/test_browser_release_artifact_bundle.py`
- `examples/browser-release-artifact-bundle.sample.json`

Verified:

- `python3 -m py_compile bench/tools/check_browser_release_artifact_bundle.py bench/tools/build_browser_release_artifact_bundle.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_release_artifact_bundle.py -q`
- `python3 bench/tools/check_browser_release_artifact_bundle.py --bundle examples/browser-release-artifact-bundle.sample.json`
- `python3 bench/gates/schema_gate.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py -q`
- `git diff --check`

## 2026-05-26 — Browser gates enforce fork maintenance policy

The single-window browser gate now runs the Chromium fork-maintenance policy
checker before browser preflight. The repeated browser claim gate checks the
same policy before accepting new or reused windows and forwards the policy path
to each browser-gate window. Gate reports and claim reports record the policy
path used for fork isolation, Dawn rollback, and release artifact requirements.

Touched:

- `bench/browser/browser_gate.py`
- `bench/browser/browser_claim_gate.py`
- `docs/process.md`

Verified:

- `python3 -m py_compile bench/browser/browser_gate.py bench/browser/browser_claim_gate.py bench/tools/check_chromium_fork_maintenance_policy.py`
- `python3 bench/tools/check_chromium_fork_maintenance_policy.py --policy config/chromium-fork-maintenance-policy.json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_chromium_fork_maintenance_policy.py bench/tests/test_browser_gate.py -q`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py -q`
- `python3 bench/gates/schema_gate.py`
- `git diff --check`

## 2026-05-26 — Browser gate emits CTS subset evidence

The promoted browser diagnostic gate now asks the smoke runner to emit a paired
`browser_cts_subset` artifact and validates it before accepting the gate report.
Gate output records the CTS subset path, CTS subset hash, and `ctsSubsetOk`
status alongside smoke and layered evidence.

Touched:

- `bench/browser/browser_gate.py`
- `bench/tests/test_browser_gate.py`
- `docs/process.md`
- `browser/chromium/README.md`

Verified:

- `python3 -m py_compile bench/browser/browser_gate.py browser/chromium/scripts/check-browser-cts-subset.py browser/chromium/scripts/build-browser-cts-subset.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_gate.py bench/tests/test_browser_cts_subset.py -q`
- `python3 browser/chromium/scripts/check-browser-cts-subset.py --subset examples/browser-cts-subset.sample.json`
- `python3 bench/gates/schema_gate.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py -q`
- `bash -n browser/chromium/scripts/run-with-lane-defaults.sh browser/chromium/scripts/run-smoke.sh browser/chromium/scripts/run-bench.sh`
- `git diff --check`

## 2026-05-26 — Browser superset wrapper accepts selector auto mode

The browser layered superset wrapper and checker now accept diagnostic
`--mode auto`. Auto-mode reports validate the selector decision as
`selectionMode=auto` with a concrete selected runtime, visible fallback reason
codes, and selected-runtime artifact identity. Lane wrappers no longer block
auto diagnostics when the Doe runtime artifact is absent; forced `doe` and
`both` paths still fail closed before execution.

Touched:

- `browser/chromium/scripts/run-with-lane-defaults.sh`
- `browser/chromium/scripts/run-browser-benchmark-superset.py`
- `browser/chromium/scripts/check-browser-benchmark-superset.py`
- `bench/browser/browser_gate.py`
- `bench/tests/test_browser_benchmark_superset_checker.py`
- `bench/tests/test_browser_doe_lib_defaults.py`
- `browser/chromium/contracts/browser-benchmark-superset.contract.md`
- `browser/chromium/README.md`
- `bench/README.md`

Verified:

- `bash -n browser/chromium/scripts/run-with-lane-defaults.sh browser/chromium/scripts/run-bench.sh browser/chromium/scripts/run-smoke.sh`
- `python3 -m py_compile browser/chromium/scripts/run-browser-benchmark-superset.py browser/chromium/scripts/check-browser-benchmark-superset.py bench/browser/browser_gate.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_benchmark_superset_checker.py bench/tests/test_browser_doe_lib_defaults.py -q`
- `python3 browser/chromium/scripts/run-browser-benchmark-superset.py --mode auto --doe-lib /tmp/does-not-exist-libwebgpu_doe_full.so --dry-run`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py -q`
- `python3 bench/gates/schema_gate.py`
- `python3 browser/chromium/scripts/check-browser-runtime-selector-policy.py --policy config/browser-runtime-selector-policy.json`
- `git diff --check`

## 2026-05-26 — Browser auto selection supports profile denylist fallback

The shared browser runtime selector now normalizes a runtime profile, emits it
inside every `runtimeSelection`, and applies the policy denylist in diagnostic
`auto` mode. A denylisted profile selects Dawn with `profile_denylisted`.
Browser gate checks now require profile observability fields so selector
reports match the policy's required observability contract.

Touched:

- `browser/chromium/scripts/browser-runtime-selector.mjs`
- `browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `browser/chromium/scripts/webgpu-playwright-layered-bench.mjs`
- `browser/chromium/scripts/webgpu-playwright-ort-bench.mjs`
- `bench/browser/browser_gate.py`
- `browser/chromium/scripts/check-browser-benchmark-superset.py`
- `bench/tests/test_browser_runtime_selector_mjs.py`
- `bench/tests/test_browser_gate.py`
- `bench/tests/test_browser_benchmark_superset_checker.py`
- `browser/chromium/contracts/runtime-selector-and-fallback.contract.md`

Verified:

- `node --check browser/chromium/scripts/browser-runtime-selector.mjs browser/chromium/scripts/webgpu-playwright-smoke.mjs browser/chromium/scripts/webgpu-playwright-layered-bench.mjs browser/chromium/scripts/webgpu-playwright-ort-bench.mjs`
- `python3 -m py_compile bench/browser/browser_gate.py browser/chromium/scripts/check-browser-benchmark-superset.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py -q`

## 2026-05-26 — Browser runners support policy-backed auto selection

The browser Playwright smoke, layered, and ORT diagnostic runners now accept
`--mode auto` and read `config/browser-runtime-selector-policy.json`. Auto mode
selects Dawn with `global_disable_active` when the configured kill switch is set,
selects Dawn with `runtime_artifact_missing` when the Doe runtime artifact is
absent, and selects Doe when the runtime artifact is available. Forced `dawn`
and `doe` modes keep fail-closed forced-mode semantics.

Touched:

- `browser/chromium/scripts/browser-runtime-selector.mjs`
- `browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `browser/chromium/scripts/webgpu-playwright-layered-bench.mjs`
- `browser/chromium/scripts/webgpu-playwright-ort-bench.mjs`
- `bench/tests/test_browser_runtime_selector_mjs.py`
- `browser/chromium/contracts/runtime-selector-and-fallback.contract.md`

Verified:

- `node --check browser/chromium/scripts/browser-runtime-selector.mjs browser/chromium/scripts/webgpu-playwright-smoke.mjs browser/chromium/scripts/webgpu-playwright-layered-bench.mjs browser/chromium/scripts/webgpu-playwright-ort-bench.mjs`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_runtime_selector_mjs.py bench/tests/test_browser_smoke_flight_recorder_flags.py bench/tests/test_browser_ort_runtime_selection.py -q`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py -q`

## 2026-05-26 — Browser reports expose workload identity

Browser smoke, layered, and ORT diagnostics now emit a top-level
`workloadIdentity` block. Smoke reports hash the smoke workload suite, layered
reports bind the source workload/projection/workflow manifests, and ORT reports
hash the selected task config. The browser gate and benchmark-superset checker
reject reports without workload identity.

Touched:

- `browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `browser/chromium/scripts/webgpu-playwright-layered-bench.mjs`
- `browser/chromium/scripts/webgpu-playwright-ort-bench.mjs`
- `browser/chromium/scripts/check-browser-benchmark-superset.py`
- `bench/browser/browser_gate.py`
- `bench/tests/test_browser_gate.py`
- `bench/tests/test_browser_benchmark_superset_checker.py`
- `bench/tests/test_browser_ort_runtime_selection.py`
- `browser/chromium/contracts/browser-benchmark-superset.contract.md`
- `browser/chromium/contracts/browser-claim-methodology.contract.md`

Verified:

- `node --check browser/chromium/scripts/webgpu-playwright-smoke.mjs browser/chromium/scripts/webgpu-playwright-layered-bench.mjs browser/chromium/scripts/webgpu-playwright-ort-bench.mjs`
- `python3 -m py_compile browser/chromium/scripts/check-browser-benchmark-superset.py bench/browser/browser_gate.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py -q`

## 2026-05-26 — Browser gates run the runtime selector policy check

The single-window browser gate now runs the runtime-selector policy checker
before browser preflight, and the repeated browser claim gate checks the same
policy before accepting new or reused windows. Gate reports and claim reports
record the runtime-selector policy path used for the run.

Touched:

- `bench/browser/browser_gate.py`
- `bench/browser/browser_claim_gate.py`
- `bench/README.md`
- `browser/chromium/README.md`
- `docs/process.md`

Verified:

- `python3 -m py_compile bench/browser/browser_gate.py bench/browser/browser_claim_gate.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_*.py -q`

## 2026-05-26 — Browser mode evidence requires trace hash fields

Browser report gates now require per-mode trace hash fields. Smoke and layered
diagnostics already emitted mode hash chains; ORT browser diagnostics now emit
the same `previousHash`/`hash` chain and a report hash. The browser gate and
benchmark-superset checker reject mode evidence without trace hashes.

Touched:

- `browser/chromium/scripts/webgpu-playwright-ort-bench.mjs`
- `browser/chromium/scripts/check-browser-benchmark-superset.py`
- `bench/browser/browser_gate.py`
- `bench/tests/test_browser_gate.py`
- `bench/tests/test_browser_benchmark_superset_checker.py`
- `bench/tests/test_browser_ort_runtime_selection.py`
- `browser/chromium/contracts/browser-benchmark-superset.contract.md`
- `browser/chromium/contracts/browser-claim-methodology.contract.md`

Verified:

- `node --check browser/chromium/scripts/webgpu-playwright-smoke.mjs browser/chromium/scripts/webgpu-playwright-layered-bench.mjs browser/chromium/scripts/webgpu-playwright-ort-bench.mjs`
- `python3 -m py_compile browser/chromium/scripts/check-browser-benchmark-superset.py bench/browser/browser_gate.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_gate.py bench/tests/test_browser_benchmark_superset_checker.py bench/tests/test_browser_ort_runtime_selection.py -q`

## 2026-05-26 — Browser reports bind shader compiler identity

Browser smoke, layered, and ORT diagnostics now emit
`shaderCompilerIdentity` per mode. Dawn mode binds the compiler surface to the
Dawn/Chromium runtime artifact hash, while Doe mode binds it to the Doe runtime
library hash. The browser gate and benchmark-superset checker reject reports
that omit shader-compiler identity.

Touched:

- `browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `browser/chromium/scripts/webgpu-playwright-layered-bench.mjs`
- `browser/chromium/scripts/webgpu-playwright-ort-bench.mjs`
- `browser/chromium/scripts/check-browser-benchmark-superset.py`
- `bench/browser/browser_gate.py`
- `bench/tests/test_browser_gate.py`
- `bench/tests/test_browser_benchmark_superset_checker.py`
- `bench/tests/test_browser_ort_runtime_selection.py`
- `browser/chromium/contracts/browser-benchmark-superset.contract.md`
- `browser/chromium/contracts/browser-claim-methodology.contract.md`

Verified:

- `node --check browser/chromium/scripts/webgpu-playwright-smoke.mjs browser/chromium/scripts/webgpu-playwright-layered-bench.mjs browser/chromium/scripts/webgpu-playwright-ort-bench.mjs`
- `python3 -m py_compile browser/chromium/scripts/check-browser-benchmark-superset.py bench/browser/browser_gate.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_gate.py bench/tests/test_browser_benchmark_superset_checker.py bench/tests/test_browser_ort_runtime_selection.py -q`

## 2026-05-26 — Browser reports hash adapter identity

Browser smoke, layered, and ORT diagnostics now emit stable adapter identity
digests instead of relying on raw `adapterInfo` alone. The browser gate and
benchmark-superset checker reject an available adapter when the adapter identity
digest is missing, so browser-lane evidence identifies both the runtime
artifacts and the adapter surface used for the run.

Touched:

- `browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `browser/chromium/scripts/webgpu-playwright-layered-bench.mjs`
- `browser/chromium/scripts/webgpu-playwright-ort-bench.mjs`
- `browser/chromium/scripts/check-browser-benchmark-superset.py`
- `bench/browser/browser_gate.py`
- `bench/tests/test_browser_gate.py`
- `bench/tests/test_browser_benchmark_superset_checker.py`
- `bench/tests/test_browser_ort_runtime_selection.py`
- `browser/chromium/contracts/browser-benchmark-superset.contract.md`
- `browser/chromium/contracts/browser-claim-methodology.contract.md`

Verified:

- `node --check browser/chromium/scripts/webgpu-playwright-smoke.mjs browser/chromium/scripts/webgpu-playwright-layered-bench.mjs browser/chromium/scripts/webgpu-playwright-ort-bench.mjs`
- `python3 -m py_compile browser/chromium/scripts/check-browser-benchmark-superset.py bench/browser/browser_gate.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_gate.py bench/tests/test_browser_benchmark_superset_checker.py bench/tests/test_browser_ort_runtime_selection.py -q`

## 2026-05-26 — Browser runtime identity records the Dawn fallback runtime

Browser runtime-selection evidence now names the Dawn fallback runtime
explicitly instead of relying on a generic runtime identity slot. Smoke,
layered, and ORT browser runners emit `artifactIdentity.dawnRuntimePath` and
`artifactIdentity.dawnRuntimeSha256`, while the browser gate and superset
checker reject reports that omit the Dawn fallback hash. The selector policy now
requires concrete browser executable, Doe runtime, Dawn fallback runtime,
fallback-state, and launch-argument observability fields.

Touched:

- `browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `browser/chromium/scripts/webgpu-playwright-layered-bench.mjs`
- `browser/chromium/scripts/webgpu-playwright-ort-bench.mjs`
- `browser/chromium/scripts/check-browser-benchmark-superset.py`
- `browser/chromium/scripts/check-browser-runtime-selector-policy.py`
- `bench/browser/browser_gate.py`
- `config/browser-runtime-selector-policy.json`
- `config/browser-runtime-selector-policy.schema.json`
- `browser/chromium/contracts/runtime-selector-and-fallback.contract.md`
- `browser/chromium/contracts/browser-claim-methodology.contract.md`

Verified:

- `node --check browser/chromium/scripts/webgpu-playwright-smoke.mjs browser/chromium/scripts/webgpu-playwright-layered-bench.mjs browser/chromium/scripts/webgpu-playwright-ort-bench.mjs`
- `python3 -m py_compile browser/chromium/scripts/check-browser-runtime-selector-policy.py browser/chromium/scripts/check-browser-benchmark-superset.py bench/browser/browser_gate.py`
- `python3 browser/chromium/scripts/check-browser-runtime-selector-policy.py --policy config/browser-runtime-selector-policy.json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_runtime_selector_policy.py bench/tests/test_browser_gate.py bench/tests/test_browser_benchmark_superset_checker.py bench/tests/test_browser_ort_runtime_selection.py -q`
- `python3 bench/gates/schema_gate.py`
- `git diff --check`

## 2026-05-26 — Browser responsibility map rejects stale claim bindings

The browser responsibility map now has a repo tool and gate wiring that enforce
the contract beyond schema shape. It checks required CPU/GPU entries, required
claim-candidate binding fields, claim-binding path existence, boundary endpoint
references, and scope-status values before a map can support browser claim
language. The single-window browser gate and repeated browser claim gate both
run the check, including repeated-claim reuse mode.

Touched:

- `bench/tools/check_browser_responsibility_map.py`
- `bench/browser/browser_gate.py`
- `bench/browser/browser_claim_gate.py`
- `bench/tests/test_browser_responsibility_map.py`
- `browser/chromium/contracts/browser-responsibility-map.contract.md`
- `bench/README.md`
- `docs/chromium-webgpu-task-list.md`

Verified:

- `python3 -m py_compile bench/tools/check_browser_responsibility_map.py`
- `python3 -m py_compile bench/browser/browser_gate.py bench/browser/browser_claim_gate.py`
- `python3 bench/tools/check_browser_responsibility_map.py --map config/browser-responsibility-map.json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_responsibility_map.py -q`

## 2026-05-26 — Browser flight recorder enforces capture policy at build time

The browser GPU flight-recorder builder now reads the browser capture policy
and normalizes unsafe component privacy input before emitting the artifact.
Origin-scope violations, raw page data, and explicit debug capture requests are
reported as typed `browser_policy` failures while the emitted privacy block
stays schema-valid and hash/redaction-only.
The browser flight replay report also records its capture-policy path and
rejects replay when the `flight_replay` surface is not developer-visible,
replay-enabled, and gated by secure-context DevTools opt-in.

Touched:

- `browser/chromium/scripts/build-browser-gpu-flight-recorder.py`
- `browser/chromium/scripts/replay-browser-gpu-flight-recorder.py`
- `browser/chromium/contracts/browser-gpu-flight-recorder.contract.md`
- `config/browser-gpu-flight-replay.schema.json`
- `examples/browser-gpu-flight-replay.sample.json`
- `bench/tests/test_browser_gpu_flight_recorder_contract.py`

Verified:

- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_gpu_flight_recorder_contract.py -q`
- `python3 browser/chromium/scripts/replay-browser-gpu-flight-recorder.py --flight-recorder examples/browser-gpu-flight-recorder.sample.json --capture-policy config/browser-capture-policy.json`

## 2026-05-26 — Browser release and claim promotion receipts are generated

Browser promotion evidence now has producers in addition to schemas and
checkers. The repeated browser claim gate writes a
`browser_claim_promotion_receipt` next to the claim report, so forced-Doe,
claim-policy pass, and hidden-fallback evidence are captured as a generated
artifact. Release bundle construction now has a deterministic builder that
hash-binds the browser binary, Doe runtime, shader compiler, contracts, claim
reports, and policies. Both checkers can verify referenced file hashes when
the artifact files are available.

Touched:

- `bench/tools/build_browser_claim_promotion_receipt.py`
- `bench/tools/build_browser_release_artifact_bundle.py`
- `bench/tools/check_browser_claim_promotion_receipt.py`
- `bench/tools/check_browser_release_artifact_bundle.py`
- `bench/browser/browser_claim_gate.py`
- `bench/tests/test_browser_claim_promotion_receipt.py`
- `bench/tests/test_browser_release_artifact_bundle.py`
- `browser/chromium/README.md`
- `docs/process.md`
- `docs/chromium-webgpu-task-list.md`

Verified:

- `python3 -m py_compile bench/tools/build_browser_claim_promotion_receipt.py bench/tools/build_browser_release_artifact_bundle.py bench/browser/browser_claim_gate.py bench/tools/check_browser_claim_promotion_receipt.py bench/tools/check_browser_release_artifact_bundle.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_claim_promotion_receipt.py bench/tests/test_browser_release_artifact_bundle.py -q`

## 2026-05-26 — Browser smoke emits CTS subset diagnostics

The Playwright smoke lane can now materialize `browser_cts_subset` from paired
Dawn and forced-Doe mode results. The builder projects smoke evidence into the
declared CTS buckets as diagnostic browser-lane evidence; it does not replace
real CTS execution, but it keeps paired browser CTS artifacts schema-backed
while the browser CTS runner is still outside the repo lane.

Touched:

- `browser/chromium/scripts/build-browser-cts-subset.py`
- `browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `bench/tests/test_browser_cts_subset.py`
- `bench/tests/test_browser_smoke_flight_recorder_flags.py`
- `browser/chromium/contracts/browser-cts-subset.contract.md`
- `browser/chromium/README.md`
- `docs/chromium-webgpu-task-list.md`

Verified:

- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_cts_subset.py bench/tests/test_browser_smoke_flight_recorder_flags.py -q`
- `node --check browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `python3 browser/chromium/scripts/build-browser-cts-subset.py --report <browser-smoke-both.json> --out <browser-cts-subset.json>`
- `python3 browser/chromium/scripts/check-browser-cts-subset.py --subset <browser-cts-subset.json>`

## 2026-05-26 — Browser smoke emits fallback explanations

The Playwright smoke lane can now materialize
`browser_fallback_explanations` from the selected mode result plus any
companion artifacts emitted in the same smoke run. Missing companion artifacts
become typed unsupported rows with developer actions that name the required
smoke flag, keeping fallback visibility explicit instead of implicit.

Touched:

- `browser/chromium/scripts/build-browser-fallback-explanations.py`
- `browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `bench/tests/test_browser_fallback_explanations.py`
- `bench/tests/test_browser_smoke_flight_recorder_flags.py`
- `browser/chromium/contracts/browser-fallback-explanations.contract.md`
- `browser/chromium/README.md`
- `docs/chromium-webgpu-task-list.md`

Verified:

- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_fallback_explanations.py bench/tests/test_browser_smoke_flight_recorder_flags.py -q`
- `node --check browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `python3 browser/chromium/scripts/build-browser-fallback-explanations.py --report <browser-smoke.json> --mode doe --out <browser-fallback-explanations.json>`
- `python3 browser/chromium/scripts/check-browser-fallback-explanations.py --explanations <browser-fallback-explanations.json>`

## 2026-05-26 — Browser smoke can emit pipeline cache receipts

The Playwright smoke lane can now build `browser_pipeline_cache_receipts`
immediately after optional local-AI workload emission. The smoke CLI requires
`--pipeline-cache-receipts-out` to be paired with `--local-ai-workloads-out`,
so cache hit/miss and pipeline creation receipts stay anchored to the generated
workload artifact.

Touched:

- `browser/chromium/scripts/build-browser-pipeline-cache-receipts.py`
- `browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `bench/tests/test_browser_smoke_flight_recorder_flags.py`
- `browser/chromium/contracts/browser-pipeline-cache-receipts.contract.md`

Verified:

- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_smoke_flight_recorder_flags.py bench/tests/test_browser_pipeline_cache_receipts.py -q`
- `node --check browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `python3 browser/chromium/scripts/build-browser-pipeline-cache-receipts.py --workloads <browser-local-ai-workloads.json> --out <browser-pipeline-cache-receipts.json>`

## 2026-05-26 — Browser smoke can emit shader links from flight recorder output

The Playwright smoke lane can now build `browser_shader_links` immediately
after optional flight-recorder emission. The smoke CLI requires
`--shader-links-out` to be paired with `--flight-recorder-out`, so shader
provenance stays anchored to the generated capture artifact rather than a
detached path.

Touched:

- `browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `bench/tests/test_browser_smoke_flight_recorder_flags.py`
- `browser/chromium/contracts/browser-shader-links.contract.md`

Verified:

- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_smoke_flight_recorder_flags.py bench/tests/test_browser_shader_links.py -q`
- `node --check browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `python3 browser/chromium/scripts/build-browser-shader-links.py --flight-recorder <flight-recorder.json> --out <shader-links.json>`

## 2026-05-26 — Browser smoke emits local AI workload artifacts

The Playwright smoke lane can now materialize `browser_local_ai_workloads`
from selected mode results. The builder maps compute smoke evidence into the
required embedding, ranking, image transform, video transform, and model
inference rows, hashes model/shader/input/output identity, and preserves the
no-hidden-fallback contract for downstream cache receipts.

Touched:

- `browser/chromium/scripts/build-browser-local-ai-workloads.py`
- `browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `bench/tests/test_browser_local_ai_workloads.py`
- `browser/chromium/contracts/browser-local-ai-workloads.contract.md`
- `browser/chromium/README.md`
- `docs/chromium-webgpu-task-list.md`

Verified:

- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_local_ai_workloads.py -q`
- `node --check browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `python3 browser/chromium/scripts/build-browser-local-ai-workloads.py --report <browser-smoke.json> --mode doe --out <browser-local-ai-workloads.json>`
- `python3 browser/chromium/scripts/check-browser-local-ai-workloads.py --workloads <browser-local-ai-workloads.json>`

## 2026-05-26 — Browser smoke emits WebGPU effect experiments

The Playwright smoke lane can now materialize a
`browser_webgpu_effect_experiment` from selected mode results. The builder uses
the render smoke output as a WebGPU-backed visual-effect probe, keeps layout,
accessibility, and security ownership explicitly browser-owned, and emits
typed diagnostic rows where smoke does not prove frame timing or browser
ownership boundaries.

Touched:

- `browser/chromium/scripts/build-browser-webgpu-effect-experiment.py`
- `browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `bench/tests/test_browser_webgpu_effect_experiment.py`
- `browser/chromium/contracts/browser-webgpu-effect-experiment.contract.md`
- `browser/chromium/README.md`
- `docs/chromium-webgpu-task-list.md`

Verified:

- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_webgpu_effect_experiment.py -q`
- `node --check browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `python3 browser/chromium/scripts/build-browser-webgpu-effect-experiment.py --report <browser-smoke.json> --mode doe --out <browser-webgpu-effect-experiment.json>`
- `python3 browser/chromium/scripts/check-browser-webgpu-effect-experiment.py --experiment <browser-webgpu-effect-experiment.json>`

## 2026-05-26 — Browser smoke emits GPU scheduler probes

The Playwright smoke lane can now materialize a
`browser_gpu_scheduler_probe` from selected mode results. The builder binds the
required WebGPU, canvas, video, CSS effects, local AI, and compositor-adjacent
work classes, carries runtime identity, maps device-loss evidence, and keeps
unmeasured scheduling behavior as typed diagnostic rows.

Touched:

- `browser/chromium/scripts/build-browser-gpu-scheduler.py`
- `browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `bench/tests/test_browser_gpu_scheduler.py`
- `browser/chromium/contracts/browser-gpu-scheduler.contract.md`
- `browser/chromium/README.md`
- `docs/chromium-webgpu-task-list.md`

Verified:

- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_gpu_scheduler.py -q`
- `node --check browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `python3 browser/chromium/scripts/build-browser-gpu-scheduler.py --report <browser-smoke.json> --mode doe --out <browser-gpu-scheduler.json>`
- `python3 browser/chromium/scripts/check-browser-gpu-scheduler.py --probe <browser-gpu-scheduler.json>`

## 2026-05-26 — Browser ORT reports carry runtime selector identity

The browser ORT workload runner now emits the same runtime selector identity
surface as the smoke and layered browser lanes. Each mode result records forced
runtime mode, hidden-fallback denial, browser executable hash, Doe library hash
for forced Doe, selector version, and launch-argument hash.

Touched:

- `browser/chromium/scripts/webgpu-playwright-ort-bench.mjs`
- `bench/tests/test_browser_ort_runtime_selection.py`

Verified:

- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_ort_runtime_selection.py -q`
- `node --check browser/chromium/scripts/webgpu-playwright-ort-bench.mjs`

## 2026-05-26 — Browser smoke emits canvas/WebGPU fusion probes

The Playwright smoke lane can now materialize a
`browser_canvas_webgpu_fusion_probe` from selected mode results. The builder
binds canvas 2D, WebGPU render, image-filter, and presentation surfaces to a
visible graph, hashes the presentation output, carries timing scopes, and emits
per-surface fallback reasons.

Touched:

- `browser/chromium/scripts/build-browser-canvas-webgpu-fusion.py`
- `browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `bench/tests/test_browser_canvas_webgpu_fusion.py`
- `browser/chromium/contracts/browser-canvas-webgpu-fusion.contract.md`
- `browser/chromium/README.md`
- `docs/chromium-webgpu-task-list.md`

Verified:

- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_canvas_webgpu_fusion.py -q`
- `node --check browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `python3 browser/chromium/scripts/build-browser-canvas-webgpu-fusion.py --report <browser-smoke.json> --mode doe --out <canvas-webgpu-fusion.json>`
- `python3 browser/chromium/scripts/check-browser-canvas-webgpu-fusion.py --probe <canvas-webgpu-fusion.json>`

## 2026-05-26 — Browser smoke emits recovery parity artifacts

The Playwright smoke lane now records validation-error capture,
`device.lost` surface availability, and post-diagnostic compute recovery. A
new builder converts paired Dawn/Doe smoke output into a schema-backed
`browser_recovery_parity` artifact; crash and hang remain typed diagnostic rows
until a harness exercises those cases directly.

Touched:

- `browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `browser/chromium/scripts/build-browser-recovery-parity.py`
- `bench/tests/test_browser_recovery_parity.py`
- `browser/chromium/contracts/browser-recovery-parity.contract.md`
- `browser/chromium/README.md`
- `docs/chromium-webgpu-task-list.md`

Verified:

- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_recovery_parity.py -q`
- `node --check browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `python3 browser/chromium/scripts/build-browser-recovery-parity.py --report <browser-smoke-both.json> --out <recovery-parity.json>`
- `python3 browser/chromium/scripts/check-browser-recovery-parity.py --parity <recovery-parity.json>`

## 2026-05-26 — Browser smoke emits media path probes

The Playwright smoke lane can now materialize a schema-backed
`browser_media_path_probe` from real smoke results. The builder extracts
`copyExternalImageToTexture` and `importExternalTexture` output digests from a
selected mode and records shared texture import as typed unsupported evidence
when the smoke report does not exercise that path.

Touched:

- `browser/chromium/scripts/build-browser-media-path-probe.py`
- `browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `bench/tests/test_browser_media_path_probe.py`
- `browser/chromium/contracts/browser-media-path-probe.contract.md`
- `docs/chromium-webgpu-task-list.md`

Verified:

- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_media_path_probe.py -q`
- `node --check browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `python3 browser/chromium/scripts/build-browser-media-path-probe.py --report <smoke-report.json> --mode doe --out <media-path-probe.json>`
- `python3 browser/chromium/scripts/check-browser-media-path-probe.py --probe <media-path-probe.json>`

## 2026-05-26 — Blocking runner enforces compare output partitioning

The canonical blocking runner now runs `compare_output_partition_gate.py` by
default. Claim-gate runs cannot disable it, so diagnostic rows cannot slip into
claimable compare output through the standard gate sequence.

Touched:

- `bench/runners/run_blocking_gates.py`
- `bench/tests/test_run_blocking_gates_wiring.py`
- `docs/process.md`

Verified:

- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_run_blocking_gates_wiring.py bench/tests/test_compare_output_partition_gate.py -q`

## 2026-05-26 — Browser superset checker validates runtime selector identity

The browser benchmark superset checker now rejects required-mode report rows
that lack forced-mode runtime selector evidence, browser executable hashes, Doe
library hashes, or hidden-fallback denial.

Touched:

- `browser/chromium/scripts/check-browser-benchmark-superset.py`
- `bench/tests/test_browser_benchmark_superset_checker.py`

Verified:

- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_benchmark_superset_checker.py -q`

## 2026-05-26 — Browser lane defaults prefer the full Doe WebGPU library

Browser smoke, layered, ORT, and superset lane wrappers now resolve
`libwebgpu_doe_full` before the compute-only `libwebgpu_doe` default.

Touched:

- `browser/chromium/scripts/run-browser-benchmark-superset.py`
- `browser/chromium/scripts/lane-paths.sh`
- `browser/chromium/scripts/patch-chromium-app-doe.sh`
- `browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `browser/chromium/scripts/webgpu-playwright-layered-bench.mjs`
- `browser/chromium/scripts/webgpu-playwright-ort-bench.mjs`

Verified:

- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_doe_lib_defaults.py -q`

## 2026-05-26 — Native command graph receipts include submit and bind group identity

Native command graph receipts now use `schemaVersion=2` and carry submit
identity plus per-command bind group references:

- `config/native-command-graph-receipt.schema.json`
- `bench/tools/build_native_command_graph_receipt.py`
- `bench/tools/replay_native_command_graph_receipt.py`

The builder records `submitId`, `bindGroupRefs`, graph-level `bindGroups`, and
`summary.submitCount`. The replay checker rejects hash-chain drift, submit-count
drift, and bind-group set drift.

Verified:

- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_native_command_graph_receipt.py -q`
- `python3 bench/gates/schema_gate.py`

## 2026-05-26 — Browser claim promotion receipt checks forced-Doe windows

Browser claim promotion now has a schema-backed receipt:

- `config/browser-claim-promotion-receipt.schema.json`
- `examples/browser-claim-promotion-receipt.sample.json`
- `bench/tools/check_browser_claim_promotion_receipt.py`

The checker requires promotion artifacts to be forced-Doe runs, rejects hidden
fallback, requires each artifact to pass the browser claim policy, and requires
the hidden-fallback check to pass before a receipt can be promotable.

Verified:

- `python3 bench/tools/check_browser_claim_promotion_receipt.py --receipt examples/browser-claim-promotion-receipt.sample.json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_claim_promotion_receipt.py -q`

## 2026-05-26 — Browser release artifact bundle is schema-backed

Browser release evidence now has a schema-backed artifact bundle:

- `config/browser-release-artifact-bundle.schema.json`
- `examples/browser-release-artifact-bundle.sample.json`
- `bench/tools/check_browser_release_artifact_bundle.py`

The checker requires hash-bound browser binary, Doe runtime, shader compiler,
contract, browser claim report, runtime selector policy, and fork maintenance
policy artifacts. Release-candidate bundles cannot carry failure codes.

Verified:

- `python3 bench/tools/check_browser_release_artifact_bundle.py --bundle examples/browser-release-artifact-bundle.sample.json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_release_artifact_bundle.py -q`

## 2026-05-26 — Chromium fork maintenance policy is schema-backed

Chromium fork maintenance, rollback, and release artifact requirements now have
a schema-backed policy:

- `config/chromium-fork-maintenance-policy.schema.json`
- `config/chromium-fork-maintenance-policy.json`
- `bench/tools/check_chromium_fork_maintenance_policy.py`

The checker keeps Doe-owned patch roots separate from the local Chromium
checkout, requires a Dawn fallback path and kill-switch policy for rollback, and
requires release artifacts to bind the browser binary, Doe runtime, compiler,
and claim report.

Verified:

- `python3 bench/tools/check_chromium_fork_maintenance_policy.py --policy config/chromium-fork-maintenance-policy.json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_chromium_fork_maintenance_policy.py -q`

## 2026-05-26 — Browser capture policy gates replay and raw data

Developer-visible browser capture and replay surfaces now have a schema-backed
policy:

- `config/browser-capture-policy.schema.json`
- `config/browser-capture-policy.json`
- `bench/tools/check_browser_capture_policy.py`

The checker requires capture surfaces to be origin-scoped, gates replay behind
secure-context developer opt-in, forbids raw page data unless it is hashed or
redacted, and requires a reason for developer-visible surfaces that do not
support replay.

Verified:

- `python3 bench/tools/check_browser_capture_policy.py --policy config/browser-capture-policy.json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_capture_policy.py -q`

## 2026-05-26 — Native backend coverage matrix is explicit

Native backend workload coverage now has a schema-backed matrix:

- `config/native-backend-coverage-matrix.schema.json`
- `config/native-backend-coverage-matrix.json`
- `bench/tools/check_native_backend_coverage_matrix.py`

The checker requires every Doe native backend to declare upload, pipeline
creation, compute, readback, small command stream, cache behavior, concurrency,
and tail coverage. Covered rows require evidence paths; diagnostic and missing
rows require reason codes.

Verified:

- `python3 bench/tools/check_native_backend_coverage_matrix.py --matrix config/native-backend-coverage-matrix.json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_native_backend_coverage_matrix.py -q`

## 2026-05-26 — Native resource reuse receipts preserve semantics

Command encoder and resource reuse now have a schema-backed receipt contract:

- `config/native-resource-reuse-receipts.schema.json`
- `examples/native-resource-reuse-receipts.sample.json`
- `bench/tools/check_native_resource_reuse_receipts.py`

The checker rejects reuse unless workload semantics allow it, keeps hidden
fallback disabled, and requires resource identity plus command order preservation
before a reused path can remain claim-eligible.

Verified:

- `python3 bench/tools/check_native_resource_reuse_receipts.py --receipts examples/native-resource-reuse-receipts.sample.json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_native_resource_reuse_receipts.py -q`

## 2026-05-26 — Native upload paths expose asymmetry before claims

Native upload path evidence now has a schema-backed receipt contract:

- `config/native-upload-path-receipts.schema.json`
- `examples/native-upload-path-receipts.sample.json`
- `bench/tools/check_native_upload_path_receipts.py`

The checker keeps strict comparable upload rows on the staging-copy path,
requires recorded copy commands for that path, rejects path-asymmetric rows
when they are claim-eligible, and requires an explicit note for hardware path
asymmetry.

Verified:

- `python3 bench/tools/check_native_upload_path_receipts.py --receipts examples/native-upload-path-receipts.sample.json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_native_upload_path_receipts.py -q`

## 2026-05-26 — Native pipeline cache receipts require cold and warm modes

Native pipeline cache behavior now has a schema-backed receipt contract:

- `config/native-pipeline-cache-receipts.schema.json`
- `examples/native-pipeline-cache-receipts.sample.json`
- `bench/tools/check_native_pipeline_cache_receipts.py`

The checker requires each workload to carry both cold and warm rows, rejects
warm rows that still report cache creation or miss states, rejects cold rows
that claim a cache hit, preserves hidden-fallback denial, and requires a note
whenever path asymmetry is present.

Verified:

- `python3 bench/tools/check_native_pipeline_cache_receipts.py --receipts examples/native-pipeline-cache-receipts.sample.json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_native_pipeline_cache_receipts.py -q`

## 2026-05-26 — Compare reports reject mixed claim and diagnostic output

Runtime compare reports now have a gate that keeps claimable rows separate from
diagnostic rows:

- `bench/gates/compare_output_partition_gate.py`
- `bench/tests/test_compare_output_partition_gate.py`

The gate rejects comparable top-level reports with comparability failures, rows
marked claim-eligible without comparable workload status, rows carrying
diagnostic comparability reasons while claim-eligible, and diagnostic benchmark
rows marked claim-eligible.

Verified:

- `python3 bench/gates/compare_output_partition_gate.py --report examples/compare-report.sample.json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_compare_output_partition_gate.py -q`

## 2026-05-26 — Strict native no-fallback reports are schema-backed

Strict native Doe run receipts can now be collected into a no-fallback report:

- `config/native-no-fallback-report.schema.json`
- `examples/native-no-fallback-report.sample.json`
- `bench/tools/build_native_no_fallback_report.py`

The report requires `product=doe`, `runtimeHost=native`, a `doe_*` execution
backend, and no per-sample fallback marker. Rows that fail those checks remain
non-promotable and carry typed failure codes.

Verified:

- `python3 bench/tools/build_native_no_fallback_report.py --run-receipt examples/run-receipt.sample.json --out /tmp/native-no-fallback-report.json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_native_no_fallback_report.py -q`

## 2026-05-26 — Native command graph receipts are replay-checkable

Native runtime runs can now be converted into a schema-backed command graph
receipt:

- `config/native-command-graph-receipt.schema.json`
- `examples/native-command-graph-receipt.sample.json`
- `bench/tools/build_native_command_graph_receipt.py`
- `bench/tools/replay_native_command_graph_receipt.py`

The builder binds a run receipt, command JSON, runtime identity, buffers,
textures, pipelines, normalized command rows, command counts, and a deterministic
row hash chain. The replay checker recomputes the hash chain and rejects row,
sequence, terminal-hash, or command-count drift.

Verified:

- `python3 bench/tools/build_native_command_graph_receipt.py --run-receipt examples/run-receipt.sample.json --commands examples/kernel_dispatch_commands.json --out /tmp/native-command-graph.json`
- `python3 bench/tools/replay_native_command_graph_receipt.py --receipt /tmp/native-command-graph.json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_native_command_graph_receipt.py -q`

## 2026-05-26 — Browser CTS subset artifact is schema-backed

The browser seam lane now has a browser-level CTS subset contract for paired
Dawn and forced-Doe evidence:

- `browser/chromium/contracts/browser-cts-subset.contract.md`
- `config/browser-cts-subset.schema.json`
- `examples/browser-cts-subset.sample.json`
- `browser/chromium/scripts/check-browser-cts-subset.py`

The structural checker requires Dawn and forced-Doe artifact paths, browser CTS
bucket coverage, typed reason codes for diagnostic or mismatch rows, parity
status discipline, and no hidden fallback.

Verified:

- `python3 bench/gates/schema_gate.py`
- `python3 browser/chromium/scripts/check-browser-cts-subset.py --subset examples/browser-cts-subset.sample.json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_cts_subset.py -q`

## 2026-05-26 — Browser runtime selector policy is schema-backed

The browser runtime selector now has a schema-backed policy artifact:

- `config/browser-runtime-selector-policy.schema.json`
- `config/browser-runtime-selector-policy.json`
- `browser/chromium/scripts/check-browser-runtime-selector-policy.py`

The checker requires exact `dawn`, `doe`, and `auto` selection modes, emergency
kill-switch precedence, the typed fallback taxonomy, denylist reason discipline,
forced-Doe fail-closed behavior, and selector observability fields.

Verified:

- `python3 bench/gates/schema_gate.py`
- `python3 browser/chromium/scripts/check-browser-runtime-selector-policy.py --policy config/browser-runtime-selector-policy.json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_runtime_selector_policy.py -q`

## 2026-05-26 — Browser recovery parity checks are schema-backed

The browser seam lane now has a Dawn-vs-Doe recovery parity contract:

- `browser/chromium/contracts/browser-recovery-parity.contract.md`
- `config/browser-recovery-parity.schema.json`
- `examples/browser-recovery-parity.sample.json`
- `browser/chromium/scripts/check-browser-recovery-parity.py`

The structural checker requires crash, hang, device-loss, validation-error, and
recovery case coverage, matching status discipline for parity rows, typed reason
codes for diagnostic or mismatch rows, and no hidden fallback in forced-Doe
mode.

Verified:

- `python3 bench/gates/schema_gate.py`
- `python3 browser/chromium/scripts/check-browser-recovery-parity.py --parity examples/browser-recovery-parity.sample.json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_recovery_parity.py -q`

## 2026-05-26 — Browser media path probes are schema-backed

The browser seam lane now has an external texture and media-path probe
contract:

- `browser/chromium/contracts/browser-media-path-probe.contract.md`
- `config/browser-media-path-probe.schema.json`
- `examples/browser-media-path-probe.sample.json`
- `browser/chromium/scripts/check-browser-media-path-probe.py`

The structural checker requires `GPUExternalTexture`,
`copyExternalImageToTexture`, and shared texture/import probe coverage with
media digests, output digests, explicit fallback reasons, and no raw media in
the artifact.

Verified:

- `python3 bench/gates/schema_gate.py`
- `python3 browser/chromium/scripts/check-browser-media-path-probe.py --probe examples/browser-media-path-probe.sample.json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_media_path_probe.py -q`

## 2026-05-26 — Browser fallback explanations are schema-backed

The browser capability lane now has a developer-visible unsupported-capability
and fallback explanation contract:

- `browser/chromium/contracts/browser-fallback-explanations.contract.md`
- `config/browser-fallback-explanations.schema.json`
- `examples/browser-fallback-explanations.sample.json`
- `browser/chromium/scripts/check-browser-fallback-explanations.py`

The structural checker requires reason codes, developer actions, evidence
paths, no hidden fallback, and matching `fallback` status whenever fallback is
applied.

Verified:

- `python3 bench/gates/schema_gate.py`
- `python3 browser/chromium/scripts/check-browser-fallback-explanations.py --explanations examples/browser-fallback-explanations.sample.json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_fallback_explanations.py -q`

## 2026-05-26 — Browser pipeline cache receipts are schema-backed

The browser capability lane now has a developer-visible cache hit/miss and
pipeline creation receipt contract:

- `browser/chromium/contracts/browser-pipeline-cache-receipts.contract.md`
- `config/browser-pipeline-cache-receipts.schema.json`
- `examples/browser-pipeline-cache-receipts.sample.json`
- `browser/chromium/scripts/build-browser-pipeline-cache-receipts.py`

The builder consumes browser local AI workload artifacts and emits one receipt
per workload cache row with workload identity, shader identity, cache key, cache
state, pipeline creation path, and fallback status.

Verified:

- `python3 bench/gates/schema_gate.py`
- `python3 browser/chromium/scripts/build-browser-pipeline-cache-receipts.py --workloads examples/browser-local-ai-workloads.sample.json --out /tmp/browser-pipeline-cache-receipts.json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_pipeline_cache_receipts.py -q`

## 2026-05-26 — Browser local AI workload receipts are schema-backed

The browser capability lane now has a local AI workload and receipt contract:

- `browser/chromium/contracts/browser-local-ai-workloads.contract.md`
- `config/browser-local-ai-workloads.schema.json`
- `examples/browser-local-ai-workloads.sample.json`
- `browser/chromium/scripts/check-browser-local-ai-workloads.py`

The structural checker requires embeddings, ranking, image transforms, video
transforms, and model inference workload rows. Each row must carry model
identity, shader identity, pipeline cache state, input contract, output digest,
and fallback status.

Verified:

- `python3 bench/gates/schema_gate.py`
- `python3 browser/chromium/scripts/check-browser-local-ai-workloads.py --workloads examples/browser-local-ai-workloads.sample.json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_local_ai_workloads.py -q`

## 2026-05-26 — Browser WebGPU effect experiment is schema-backed

The browser capability lane now has a contract for explicit WebGPU-backed
HTML/CSS visual effect experiments:

- `browser/chromium/contracts/browser-webgpu-effect-experiment.contract.md`
- `config/browser-webgpu-effect-experiment.schema.json`
- `examples/browser-webgpu-effect-experiment.sample.json`
- `browser/chromium/scripts/check-browser-webgpu-effect-experiment.py`

The structural checker requires every effect surface to be WebGPU-backed while
layout, accessibility, and security semantics remain browser-owned. It also
requires output-hash, semantics-boundary, fallback-behavior, frame-timing, and
security-policy probes.

Verified:

- `python3 bench/gates/schema_gate.py`
- `python3 browser/chromium/scripts/check-browser-webgpu-effect-experiment.py --experiment examples/browser-webgpu-effect-experiment.sample.json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_webgpu_effect_experiment.py -q`

## 2026-05-26 — Browser GPU scheduler probe is schema-backed

The browser capability lane now has a page-level GPU scheduler probe contract:

- `browser/chromium/contracts/browser-gpu-scheduler.contract.md`
- `config/browser-gpu-scheduler.schema.json`
- `examples/browser-gpu-scheduler.sample.json`
- `browser/chromium/scripts/check-browser-gpu-scheduler.py`

The structural checker requires coverage for WebGPU, canvas, video, CSS
effects, local AI, and compositor-adjacent work classes, plus priority,
fairness, frame-deadline, origin-quota, device-loss, and fallback-behavior
probe kinds.

Verified:

- `python3 bench/gates/schema_gate.py`
- `python3 browser/chromium/scripts/check-browser-gpu-scheduler.py --probe examples/browser-gpu-scheduler.sample.json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_gpu_scheduler.py -q`

## 2026-05-26 — Browser shader links build from flight-recorder artifacts

Developer-visible shader links now have a contract, schema, sample artifact,
and builder:

- `browser/chromium/contracts/browser-shader-links.contract.md`
- `config/browser-shader-links.schema.json`
- `examples/browser-shader-links.sample.json`
- `browser/chromium/scripts/build-browser-shader-links.py`

The builder consumes a `browser_gpu_flight_recorder` artifact and emits
source-to-IR-to-backend shader links. Missing source, IR, or backend anchors
produce typed failures instead of partial developer links.

Verified:

- `python3 bench/gates/schema_gate.py`
- `python3 browser/chromium/scripts/build-browser-shader-links.py --flight-recorder examples/browser-gpu-flight-recorder.sample.json --out /tmp/browser-shader-links.json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_shader_links.py -q`

## 2026-05-26 — Canvas/WebGPU fusion probe is schema-backed

The browser capability lane now has a canvas/WebGPU fusion probe contract:

- `browser/chromium/contracts/browser-canvas-webgpu-fusion.contract.md`
- `config/browser-canvas-webgpu-fusion.schema.json`
- `examples/browser-canvas-webgpu-fusion.sample.json`
- `browser/chromium/scripts/check-browser-canvas-webgpu-fusion.py`

The probe shape binds canvas 2D, WebGPU, image-filter, and presentation surfaces
to responsibility-map entries, visible graph edges, output hashes, timing
scopes, fallback reasons, and an origin-scoped no-raw-page-data policy.

Verified:

- `python3 bench/gates/schema_gate.py`
- `python3 browser/chromium/scripts/check-browser-canvas-webgpu-fusion.py --probe examples/browser-canvas-webgpu-fusion.sample.json`

## 2026-05-26 — Browser runtime identity surface is explicit

The package browser shim now exposes
`createBrowserRuntimeIdentity()` from `packages/doe-gpu/src/browser.js`.
Without a Chromium runtime-selection artifact, the identity reports the surface
as `browser_wrapper_probe` and keeps `doeRuntimeActive=false`. When a
runtime-selection artifact is supplied, the same shape can report a
Chromium-lane `dawn` or `doe` runtime decision without implying that the package
shim itself replaced `navigator.gpu`.

Schema and sample:

- `config/browser-runtime-identity.schema.json`
- `examples/browser-runtime-identity.sample.json`

Verified:

- `python3 bench/gates/schema_gate.py`
- `node packages/doe-gpu/test/unit/browser-runtime-identity.test.js`

## 2026-05-26 — Browser GPU flight recorder contract is schema-backed

The Chromium browser lane now has a page-level GPU flight-recorder contract and
sample artifact schema:

- `browser/chromium/contracts/browser-gpu-flight-recorder.contract.md`
- `config/browser-gpu-flight-recorder.schema.json`
- `examples/browser-gpu-flight-recorder.sample.json`

The contract binds browser runtime identity, adapter identity, the active browser
responsibility map, shader source/IR/backend hashes, bind groups, buffers,
textures, command graph, timings, frame hashes, typed failure codes, and capture
privacy policy before browser replay or developer-visible capture work can
promote. The builder requires an explicit component manifest for shader
source/IR/backend and graph fields, so compiler evidence is not synthesized from
browser timings. The Playwright smoke lane can now emit the artifact directly
when given `--flight-recorder-components`, `--flight-recorder-out`, and
`--flight-recorder-mode`.

Verified:

- `python3 bench/gates/schema_gate.py`
- `python3 browser/chromium/scripts/build-browser-gpu-flight-recorder.py --report browser/chromium/artifacts/20260525T202040Z/dawn-vs-doe.browser.playwright-smoke.diagnostic.json --components examples/browser-gpu-flight-recorder.sample.json --out /tmp/browser-gpu-flight-recorder.prototype.json`
- `./browser/chromium/scripts/run-smoke.sh --mode doe --strict --upload-iters 1 --dispatch-iters 1 --out /tmp/browser-smoke-flight.diagnostic.json --flight-recorder-components examples/browser-gpu-flight-recorder.sample.json --flight-recorder-out /tmp/browser-smoke-flight-recorder.json --flight-recorder-mode doe`
- `python3 browser/chromium/scripts/replay-browser-gpu-flight-recorder.py --flight-recorder /tmp/browser-smoke-flight-recorder.json`
- `python3 browser/chromium/scripts/replay-browser-gpu-flight-recorder.py --flight-recorder examples/browser-gpu-flight-recorder.sample.json`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_gpu_flight_recorder_contract.py -q`

## 2026-05-26 — Browser responsibility map is schema-backed

The Chromium browser lane now has a schema-backed responsibility map for the
task-list CPU/GPU boundary work:

- `config/browser-responsibility-map.schema.json`
- `config/browser-responsibility-map.json`
- `browser/chromium/contracts/browser-responsibility-map.contract.md`

The map separates browser CPU duties, GPU duties, and CPU/GPU crossings, then
classifies each surface with the task-list taxonomy. Every
`doe_claim_candidate` entry must name its contract, schema, workload source,
gate, and artifact path before claim language can route through that surface.

Verified:

- `python3 bench/gates/schema_gate.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_responsibility_map.py -q`

## 2026-05-26 — Benchmark artifact hashing is shared and streaming

Benchmark IR materialization, synthetic asset manifests, and report conformance
now use `bench/lib/hash_utils.py` for canonical JSON hashes and file hashes.
The shared file hash path streams artifact bytes instead of loading the whole
file into memory.

Verified:

- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_benchmark_ir.py bench/tests/test_synthetic_assets.py bench/tests/test_report_conformance.py -q`
- `python3 -m py_compile bench/lib/hash_utils.py bench/lib/benchmark_ir.py bench/lib/synthetic_assets.py bench/lib/report_conformance.py`

## 2026-05-26 — Compare reports use diagnostic for failed comparability

New Dawn-vs-Doe compare reports now classify failed comparability or coherence
as `comparisonStatus=diagnostic`. The schema, conformance checker, claim gate,
report builder, viewer styling, and regression tests now use the same two-status
comparison contract: `comparable` for claim-eligible evidence and `diagnostic`
for engineering evidence.

Verified:

- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_compare_from_artifacts.py bench/tests/test_report_conformance.py -q`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_config_schemas.py bench/tests/test_comparability_coherence_smoke_floor.py -q`
- `python3 bench/gates/schema_gate.py`

## 2026-05-25 — Schema gate no longer depends on local generated bench output

The schema gate now treats generated `bench/out/` data targets as optional when
the local artifact is absent, while still validating those artifacts when they
exist. The provenance sidecar contract keeps positive schema coverage through
`examples/doe-promoted-artifact-provenance.sample.json`, and provenance globs
that scan generated bundle sidecars are explicitly marked `allowEmpty`.

Verified:

- `python3 bench/gates/schema_gate.py`
- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_schema_gate.py bench/tests/test_config_schemas.py -q`

## 2026-05-25 — Native delegate identity is pinned in run receipts

Run receipts now unwrap `env` launchers before hashing the benchmark runner and
record `runtimeIdentity.nativeDelegate` for Dawn-backed native lanes when the
delegate WebGPU library is discoverable from the launch library path. This keeps
Dawn-vs-Doe evidence tied to both the shared runner binary and the delegated
Dawn library instead of hashing the shell wrapper.

Verified:

- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_run_artifact.py bench/tests/test_compare_from_artifacts.py bench/tests/test_report_conformance.py -q`
- `python3 bench/cli.py run-config --side comparison --config bench/native-compare/compare.config.apple.metal.release.json --workload-filter compute_concurrent_execution_single --out bench/out/apple-metal/identity-check/dawn-vs-doe.apple.metal.identity-check.json --workspace bench/out/apple-metal/identity-check/runtime-comparisons.apple.metal.identity-check`

## 2026-05-25 — Browser executable identity is pinned in diagnostics

Browser smoke and layered diagnostics now hash the resolved Chromium executable
for both Dawn and Doe modes. The browser gate requires
`artifactIdentity.browserExecutableSha256`, so browser evidence is tied to the
exact executable plus the Doe runtime library when Doe mode is selected.

Current refreshed evidence:

- `browser/chromium/artifacts/20260525T202040Z/dawn-vs-doe.browser.playwright-smoke.diagnostic.json`
- `browser/chromium/artifacts/20260525T202052Z/dawn-vs-doe.browser-layered.superset.diagnostic.json`
- `browser/chromium/artifacts/20260525T202052Z/dawn-vs-doe.browser-layered.superset.check.json`
- `browser/chromium/artifacts/20260525T202052Z/dawn-vs-doe.browser-layered.superset.summary.json`

Verified:

- `PYTHONPATH=bench:. python3 -m pytest bench/tests/test_browser_gate.py -q`
- `node --check browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `node --check browser/chromium/scripts/webgpu-playwright-layered-bench.mjs`
- `./browser/chromium/scripts/preflight.sh --mode bench`
- `./browser/chromium/scripts/run-smoke.sh --mode both --strict`
- `./browser/chromium/scripts/run-bench.sh --mode both --strict-run`

## 2026-05-25 — Browser smoke and layered diagnostics refreshed

Fresh browser-lane diagnostics were generated through the wrapper entrypoints
after bench-mode preflight was tightened. Use the artifacts as the source of
truth for runtime identity, fallback state, required-row status, and browser
proxy timings:

- `browser/chromium/artifacts/20260525T192219Z/dawn-vs-doe.browser.playwright-smoke.diagnostic.json`
- `browser/chromium/artifacts/20260525T192228Z/dawn-vs-doe.browser-layered.superset.diagnostic.json`
- `browser/chromium/artifacts/20260525T192228Z/dawn-vs-doe.browser-layered.superset.check.json`
- `browser/chromium/artifacts/20260525T192228Z/dawn-vs-doe.browser-layered.superset.summary.json`

Verified:

- `./browser/chromium/scripts/run-smoke.sh --mode both --strict`
- `./browser/chromium/scripts/run-bench.sh --mode both`

## 2026-05-25 — Browser bench preflight fails closed on missing executors

The Chromium browser lane preflight now treats the resolved browser executable
and Doe runtime library as required in `--mode bench`. General/build preflight
still reports them as warnings, but a benchmark preflight no longer passes when
the run wrapper would fail immediately on missing paths.

Verified:

- `./browser/chromium/scripts/preflight.sh --mode bench`
- `FAWN_CHROME_BIN=/tmp/not-a-chromium FAWN_DOE_LIB=/tmp/not-a-doe-lib ./browser/chromium/scripts/preflight.sh --mode bench`
- `FAWN_CHROME_BIN=/tmp/not-a-chromium FAWN_DOE_LIB=/tmp/not-a-doe-lib ./browser/chromium/scripts/preflight.sh --mode general`

## 2026-05-25 — Apple Metal preflight checks executor artifacts

The local Apple Metal preflight now verifies the actual compare-lane executor
artifacts before a run can proceed:

- `runtime/zig/zig-out/bin/doe-zig-runtime`
- `bench/vendor/dawn/out/Release/libwebgpu_dawn.dylib`

The Dawn delegate library check also inspects the exported WebGPU C ABI symbols
required by the delegate lane. This prevents a host-only Metal toolchain smoke
from being treated as a runnable Doe-vs-Dawn compare preflight.

Verified:

- `python3 bench/runners/preflight_metal_host.py`
- `python3 -m pytest bench/tests/test_preflight_metal_host.py -q`

## 2026-05-25 — Apple Metal copy contracts enter the release claim lane

Apple Metal native Doe-vs-Dawn release evidence has been refreshed after the
copy transfer contracts were strengthened from diagnostic-only rows into
claim-eligible release rows.

- buffer-to-texture and texture-to-texture rows now use the governed release
  repeat/window contract instead of the previous smoke-sized window.
- the default texture-to-texture command fixture now uses the larger transfer
  shape used by the stronger copy fixtures instead of the tiny smoke fixture.
- both sides now run the copy rows with deferred queue sync, so the repeated
  copy stream is encoded as one drained workload unit.
- the release claim policy can still select workload-unit wall timing for copy
  rows whose per-copy operation timing is below the useful measurement floor.

Release artifacts:

- `bench/out/apple-metal/release/20260525T190747Z/runtime-comparisons.apple.metal.release/run-artifacts/doe/`
- `bench/out/apple-metal/release/20260525T190829Z/runtime-comparisons.apple.metal.release/run-artifacts/dawn_delegate/`
- `bench/out/apple-metal/release/20260525T190829Z/dawn-vs-doe.apple.metal.release.compare.json`
- `bench/out/apple-metal/release/20260525T190829Z/dawn-vs-doe.apple.metal.release.claim.json`

The broader local compare lane can still carry diagnostic/non-claim rows for
methodology auditing. Marketing or release claims should cite the release claim
artifact above.

## 2026-05-25 — Apple Metal release claim uses complete operation timing

Apple Metal native Doe-vs-Dawn release evidence has been refreshed after two
timing-scope fixes in the compare harness:

- render macro workloads now keep full operation timing instead of encode-only
  timing; encode-only selection remains limited to render domains where encode
  is the comparable operation scope.
- kernel-dispatch traces now fold host kernel prewarm into selected operation
  timing when the trace actually contains `kernel_dispatch`; non-kernel copy
  and render traces keep their ordinary operation timing source.

Release artifacts:

- `bench/out/apple-metal/release/20260525T184401Z/runtime-comparisons.apple.metal.release/run-artifacts/doe/`
- `bench/out/apple-metal/release/20260525T184443Z/runtime-comparisons.apple.metal.release/run-artifacts/dawn_delegate/`
- `bench/out/apple-metal/release/20260525T184443Z/dawn-vs-doe.apple.metal.release.compare.json`
- `bench/out/apple-metal/release/20260525T184443Z/dawn-vs-doe.apple.metal.release.claim.json`

The broader local compare lane still includes diagnostic/non-claim rows for
methodology auditing. Marketing or release claims should cite the release claim
artifact above, whose selector excludes rows that are not claim-eligible.

## 2026-05-25 — P0 multi-draw fixtures use explicit indirect commands

The `render_multidraw` and `render_multidraw_indexed` fixtures now exercise
the explicit `draw_indirect` / `draw_indexed_indirect` command path instead of
implicitly enabling multi-draw from ordinary direct render draws. The WebGPU
full path now sizes and writes one indirect argument record per requested draw
before using the p0 multi-draw API; if the argument staging write cannot be
prepared, execution falls back to the regular draw loop.

Fresh directional evidence:

- `bench/out/apple-metal/explore/20260525T181045Z/runtime-comparisons.apple.metal.explore/run-artifacts/doe/doe-render_multidraw-20260525T181045Z.run.json`
- `bench/out/apple-metal/explore/20260525T181045Z/runtime-comparisons.apple.metal.explore/run-artifacts/doe/doe-render_multidraw_indexed-20260525T181045Z.run.json`
- `bench/out/apple-metal/explore/20260525T181126Z/runtime-comparisons.apple.metal.explore/run-artifacts/dawn_delegate/dawn_delegate-render_multidraw-20260525T181126Z.run.json`
- `bench/out/apple-metal/explore/20260525T181126Z/runtime-comparisons.apple.metal.explore/run-artifacts/dawn_delegate/dawn_delegate-render_multidraw_indexed-20260525T181126Z.run.json`

The rows remain directional until governed apples-to-apples evidence is
recorded.

## 2026-05-25 — Browser gate now records forced-runtime identity

The Chromium Track A browser gate now validates explicit runtime-selection
evidence for both Dawn and Doe modes. Smoke and layered browser artifacts carry
forced mode, selected runtime, fallback status, selector version, launch-args
hash, and Doe runtime artifact hash for Doe mode.

Current refreshed evidence:

- `browser/chromium/artifacts/20260525T163954Z/dawn-vs-doe.browser.playwright-smoke.diagnostic.json`
- `browser/chromium/artifacts/20260525T163954Z/dawn-vs-doe.browser-layered.superset.diagnostic.json`
- `browser/chromium/artifacts/20260525T163954Z/dawn-vs-doe.browser-layered.superset.summary.json`
- `browser/chromium/artifacts/20260525T163954Z/dawn-vs-doe.browser-layered.superset.check.json`
- `bench/out/browser-promotion/20260525T163954Z/browser_gate.json`

The gate passes with zero failures. The output remains diagnostic; the next
promotion boundary is a formal browser claim lane.

## Current state

- Apple Metal native Doe-vs-Dawn fair-cold compare defaults are in place.
- AMD Vulkan now has Doe-side `VkPipelineCache` support and renewed strict
  compare evidence.
- Apple Metal package lanes and AMD Vulkan package lanes both have current
  narrow claimable surfaces.
- Benchmark reporting is artifact-first; JSON receipts under `bench/out/` are
  the canonical output surface.

## Active blockers

- Backend-wide claim language is still narrower than the existence of isolated
  claimable rows.
- D3D12 claim evidence still requires a suitable Windows host.
- Broader Metal and ORT/WebGPU package claims remain mixed or narrow.

## Landed infrastructure

- Fair-cold compare defaults on Metal
- Vulkan pipeline-cache implementation and optional persistence
- Artifact-first compare/claim/report flows
- Bench output viewer as the single tracked local HTML surface

## Ground truth

- Backend benchmark status is no longer the main source of status-log volume.
- This shard exists so backend and benchmark updates stop crowding compiler and
  Cerebras work into a single giant dated file.

## Use this shard for

- Native backend compare status
- Package-lane status
- Benchmark methodology / claim updates
- Backend-specific performance evidence

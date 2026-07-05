# Doe status archive: runtime Vulkan browser probes — 2026-07-04

This archive holds dated runtime-backend and benchmark-lane history previously
kept inline in `docs/status/runtime-backends-and-bench.md`.

Do not add new live status entries here. New status belongs in
[`../runtime-backends-and-bench.md`](../runtime-backends-and-bench.md).

## 2026-07-04 — Vulkan browser sync and subgroup probes rejected after replay baseline audit

The current Vulkan browser baseline remains the recorded-repeat replay path
with the explicit subgroup policy and fast fence-pool wait accounting. A round
of focused paired-balanced compute probes tested additional sync,
command-buffer, queue-family, and subgroup variants. Correctness stayed green
for the completed strict runs, but the score sidecars rejected the probes as
default-lane changes. The source changes were reverted unless they were
already part of the accepted baseline.

Rejected probe artifacts:
`browser/chromium/artifacts/current-vulkan-command-pool-reset-only/dawn-vs-doe.browser.playwright-smoke.command-pool-reset-only.json`,
`browser/chromium/artifacts/current-vulkan-command-pool-reset-only/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`,
`browser/chromium/artifacts/current-vulkan-fence-depth-256/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`,
`browser/chromium/artifacts/current-vulkan-fence-depth-256-rerun/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`,
`browser/chromium/artifacts/current-vulkan-fence-depth-192/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`,
`browser/chromium/artifacts/current-vulkan-fence-precreate-256/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`,
`browser/chromium/artifacts/current-vulkan-fence-depth-256-latest-drain/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`,
`browser/chromium/artifacts/current-vulkan-fence-drain-prune-signaled/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`,
`browser/chromium/artifacts/current-vulkan-subgroup-workgroup64-plus-fence256/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`,
`browser/chromium/artifacts/current-vulkan-compute-only-fence-diagnostic-fence256/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`,
`browser/chromium/artifacts/current-vulkan-replay-command-buffer-flags-zero/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`,
and
`browser/chromium/artifacts/current-vulkan-single-flush-fence-marker-diagnostic/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`.

Additional rejected diagnostics from the same audit:
`browser/chromium/artifacts/current-vulkan-noop-entry-return/dawn-vs-doe.browser.playwright-smoke.noop-entry-return.json`,
`browser/chromium/artifacts/current-vulkan-noop-entry-return/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`,
`browser/chromium/artifacts/current-vulkan-timeline-sync-policy/dawn-vs-doe.browser.playwright-smoke.timeline-sync-policy.json`,
and
`browser/chromium/artifacts/current-vulkan-timeline-sync-policy/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`.

Treat these sidecars as negative evidence for changing the default Vulkan
browser path to reset-only command pools, deeper fence rings, pre-created fence
pools, latest-fence-only drain, signaled-fence pruning, lower workgroup-memory
subgroup suppression thresholds, compute-only app queue selection, replay
command buffers without one-time usage, or single flush-marker synchronization.
The remaining work is still compute dispatch wait overhead, especially direct
dispatch sweep rows and small no-op dispatch rows.

## 2026-07-04 — Vulkan replay command-buffer reuse flag probe rejected

A Vulkan replay probe removed `VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT`
from recorded-submit replay command-buffer begin info, testing whether a
reused replay buffer should avoid the one-time usage hint. Strict browser smoke
stayed correct, but the focused paired-balanced compute score rejected the
change: the full compute category regressed and the strict source-comparable
slice weakened against the accepted recorded-repeat replay artifact. The
source change was reverted.

The probe artifacts are:
`browser/chromium/artifacts/current-vulkan-replay-reusable-cmd-buffer/dawn-vs-doe.browser.playwright-smoke.vulkan-replay-reusable-cmd-buffer.json`,
`browser/chromium/artifacts/current-vulkan-replay-reusable-cmd-buffer/fawn-dawn-vs-fawn-doe.browser-layered.superset.diagnostic.json`,
`browser/chromium/artifacts/current-vulkan-replay-reusable-cmd-buffer/fawn-dawn-vs-fawn-doe.browser-layered.superset.check.json`,
and
`browser/chromium/artifacts/current-vulkan-replay-reusable-cmd-buffer/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`.
Treat the score sidecar as negative evidence for changing the replay
command-buffer usage hint without a narrower workload-specific reason.

## 2026-07-04 — Vulkan large-workgroup subgroup-size selector rejected

A Vulkan pipeline probe selected required subgroup size 64 only for SPIR-V
compute entries whose `OpExecutionMode LocalSize` reported a large local X
dimension, leaving the existing required subgroup size otherwise unchanged.
Strict browser smoke stayed correct, but the focused paired-balanced compute
score rejected the rule: the full compute score regressed, and the strict
source-comparable compute slice moved from a Doe lead to a Doe deficit against
the accepted recorded-repeat replay artifact. The source change was reverted.

The probe artifacts are:
`browser/chromium/artifacts/current-vulkan-subgroup64-probe/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`,
`browser/chromium/artifacts/current-vulkan-large-workgroup-subgroup64/dawn-vs-doe.browser.playwright-smoke.vulkan-large-workgroup-subgroup64.json`,
`browser/chromium/artifacts/current-vulkan-large-workgroup-subgroup64/fawn-dawn-vs-fawn-doe.browser-layered.superset.diagnostic.json`,
`browser/chromium/artifacts/current-vulkan-large-workgroup-subgroup64/fawn-dawn-vs-fawn-doe.browser-layered.superset.check.json`,
and
`browser/chromium/artifacts/current-vulkan-large-workgroup-subgroup64/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`.
Treat these sidecars as negative evidence for subgroup-size selection based on
local workgroup size alone.

## 2026-07-04 — Vulkan buffer-scoped compute barrier probe rejected

A Vulkan sync probe replaced the broad compute-write visibility barrier for
tracked current bindings with per-buffer barriers for the intersecting tracked
storage buffers. Strict browser smoke stayed correct, and the focused
paired-balanced compute run showed useful movement on some individual rows, but
the full compute score and strict-comparable compute slice regressed against
the accepted recorded-repeat replay artifact. The source change was reverted.

The probe artifacts are:
`browser/chromium/artifacts/current-vulkan-buffer-scope-compute-barrier/dawn-vs-doe.browser.playwright-smoke.vulkan-buffer-scope-compute-barrier.json`,
`browser/chromium/artifacts/current-vulkan-buffer-scope-compute-barrier/fawn-dawn-vs-fawn-doe.browser-layered.superset.diagnostic.json`,
`browser/chromium/artifacts/current-vulkan-buffer-scope-compute-barrier/fawn-dawn-vs-fawn-doe.browser-layered.superset.check.json`,
and
`browser/chromium/artifacts/current-vulkan-buffer-scope-compute-barrier/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`.
Treat the score sidecar as negative evidence for changing the default compute
barrier shape without a narrower source-comparable win.

## 2026-07-04 — Vulkan loop-only bounds-elision probe rejected

A Vulkan WGSL-to-SPIR-V runtime probe extended dispatch-validated storage
preconditions to loop-only affine runtime-array indices, removing
`OpArrayLength`/`UMin` clamps from the checked matvec vector-load path. The
emitted SPIR-V validated and strict paired smoke stayed correct. The focused
paired-balanced compute score rejected the change: one strict matvec row
improved, but the full compute category and strict source-comparable slice
regressed against the accepted recorded-repeat replay artifact. The source
behavior was reverted; only matcher file-size cleanup remains.

The probe artifacts are:
`bench/out/scratch/strict-compute-codegen/matvec_swizzle1.loop-elide.spv`,
`bench/out/scratch/strict-compute-codegen/matvec_swizzle1.loop-elide.spvasm`,
`bench/out/scratch/strict-compute-codegen/workgroup_non_atomic.loop-elide.spv`,
`bench/out/scratch/strict-compute-codegen/workgroup_non_atomic.loop-elide.spvasm`,
`browser/chromium/artifacts/current-vulkan-loop-bounds-elide/dawn-vs-doe.browser.playwright-smoke.vulkan-loop-bounds-elide.json`,
`browser/chromium/artifacts/current-vulkan-loop-bounds-elide/fawn-dawn-vs-fawn-doe.browser-layered.superset.diagnostic.json`,
`browser/chromium/artifacts/current-vulkan-loop-bounds-elide/fawn-dawn-vs-fawn-doe.browser-layered.superset.check.json`,
and
`browser/chromium/artifacts/current-vulkan-loop-bounds-elide/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`.
Treat these sidecars as negative evidence for assuming loop-only
dispatch-validated bounds elision is a default Vulkan browser win.

## 2026-07-04 — Vulkan cross-submit replay deferral probe rejected

A browser-path Vulkan probe left recorded replay open across WebGPU
`queue.submit` calls and relied on explicit queue drains to finalize and wait.
Strict paired smoke stayed correct, and the focused paired-balanced
compute/memory run improved memory rows, but the compute category and the
strict source-comparable compute slice regressed against the accepted recorded
repeat replay artifact. The source change was reverted; keep per-submit replay
finalization as the current browser path.

The probe artifacts are:
`browser/chromium/artifacts/current-vulkan-deferred-submit-replay/dawn-vs-doe.browser.playwright-smoke.vulkan-deferred-submit-replay.json`,
`browser/chromium/artifacts/current-vulkan-deferred-submit-replay/fawn-dawn-vs-fawn-doe.browser-layered.superset.diagnostic.json`,
`browser/chromium/artifacts/current-vulkan-deferred-submit-replay/fawn-dawn-vs-fawn-doe.browser-layered.superset.check.json`,
and
`browser/chromium/artifacts/current-vulkan-deferred-submit-replay/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`.
Treat the score sidecar as negative evidence for cross-submit replay deferral
unless a later change proves strict source-comparable compute does not regress.

## 2026-07-04 — Command object pool probe rejected

A browser-path runtime probe added bounded recycling for native command
encoders, compute passes, command buffers, and small recorded-command lists to
reduce allocator churn in short direct-dispatch loops. Strict browser smoke
stayed correct, and repeated focused paired-balanced compute runs improved the
full directional compute score. The probe was rejected because both runs
weakened the strict source-comparable compute slice versus the accepted
recorded-repeat replay artifact.

The probe artifacts are:
`browser/chromium/artifacts/current-command-object-pool/dawn-vs-doe.browser.playwright-smoke.command-object-pool.json`,
`browser/chromium/artifacts/current-command-object-pool/fawn-dawn-vs-fawn-doe.browser-layered.superset.diagnostic.json`,
`browser/chromium/artifacts/current-command-object-pool/fawn-dawn-vs-fawn-doe.browser-layered.superset.check.json`,
`browser/chromium/artifacts/current-command-object-pool/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`,
`browser/chromium/artifacts/current-command-object-pool-repeat/fawn-dawn-vs-fawn-doe.browser-layered.superset.diagnostic.json`,
`browser/chromium/artifacts/current-command-object-pool-repeat/fawn-dawn-vs-fawn-doe.browser-layered.superset.check.json`,
and
`browser/chromium/artifacts/current-command-object-pool-repeat/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`.
Treat these sidecars as negative evidence for accepting allocator-pool gains
that trade away strict source-comparable browser compute evidence.

## 2026-07-04 — SPIR-V storage-buffer coherent decoration probe rejected

A Vulkan SPIR-V emitter probe matched Tint's storage-buffer variable shape by
adding `Coherent` decoration on storage-buffer globals. The emitted workgroup
SPIR-V validated with `spirv-val`, and strict browser smoke stayed correct for
both Dawn and Doe. The focused paired-balanced compute report rejected the
change: the current strict-comparable slice lost its existing Doe lead, and the
full focused compute score also moved away from the current no-batch wrapper
baseline.

The probe artifacts are:
`bench/out/scratch/workgroup-codegen-probe/doe_workgroup_atomic_coherent.spvasm`,
`bench/out/scratch/workgroup-codegen-probe/doe_workgroup_non_atomic_coherent.spvasm`,
`browser/chromium/artifacts/current-spirv-storage-coherent/dawn-vs-doe.browser.playwright-smoke.spirv-storage-coherent.json`,
`browser/chromium/artifacts/current-spirv-storage-coherent/fawn-dawn-vs-fawn-doe.browser-layered.superset.diagnostic.json`,
`browser/chromium/artifacts/current-spirv-storage-coherent/fawn-dawn-vs-fawn-doe.browser-layered.superset.check.json`,
and
`browser/chromium/artifacts/current-spirv-storage-coherent/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`.
The code was reverted; these artifacts are negative evidence for adding
storage-buffer `Coherent` as a default Vulkan browser-path optimization.

## 2026-07-04 — Browser source-kernel sample-batch probe rejected

A focused Fawn Dawn-vs-Doe compute probe switched source-kernel submit cadence
to `sample-batch-v1`, so each source-kernel sample submitted the whole sample
command stream under the same paired-balanced mode schedule. The run stayed
diagnostic: the strict report recorded a required Dawn-side row failure before
the wrapper finalizer could produce its usual sidecars, and the manual score
sidecar still shows mixed strict rows plus a worse focused compute score than
the current no-batch wrapper baseline.

The probe artifacts are:
`browser/chromium/artifacts/current-sample-batch-source-kernel-probe/fawn-dawn-vs-fawn-doe.browser-layered.superset.diagnostic.json`,
`browser/chromium/artifacts/current-sample-batch-source-kernel-probe/fawn-dawn-vs-fawn-doe.browser-layered.superset.check.json`,
and
`browser/chromium/artifacts/current-sample-batch-source-kernel-probe/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`.
Treat this as negative evidence for changing the Fawn runtime wrapper's
default source-kernel submit cadence under the current Vulkan browser path.

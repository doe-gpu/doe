# Doe status: runtime backends and benchmark lanes

This is a live topical status shard. Follow the shared shard policy in
[`README.md`](README.md).

## 2026-07-05 — Apple Metal package and release rows refreshed for 0.4.7

The macOS Apple Metal Node package row is now claim-indexed against
`bench/out/apple-metal/20260706T001434Z/gemma64.node-package.warm.ir.compare.json`
with claim sidecar
`bench/out/apple-metal/20260706T001434Z/gemma64.node-package.warm.ir.claim.json`.
The package fix keeps dispatch-only lazy command buffers on the batched submit
path and bounds Node host shadows so large static package uploads do not copy
through an internal JS shadow unless a small-buffer direct-read path needs it.

The full Apple Metal native release matrix is also claim-indexed against
`bench/out/apple-metal/release/20260706T001555Z/runtime.apple-metal.release.json`
with claim sidecar
`bench/out/apple-metal/release/20260706T001555Z/runtime.apple-metal.release.claim.json`.
The release artifact keeps the `upload_write_buffer_1mb_staged` row comparable
and positive under the release tail checks.

## 2026-07-05 — Vulkan resource-op failures now reach error scopes

The Vulkan drop-in resource helpers for clearBuffer, texture write, and texture
copy paths no longer log native failures and then report the operation as
silently handled. Missing Vulkan runtime state, missing native resources,
unregistered buffers, unmapped CPU-side transfer buffers, and native
texture-read/write/copy failures now deliver a WebGPU internal error through
the device error-scope stack while keeping the Vulkan path from falling into an
unrelated Metal-style fallback.

The behavior remains fail-closed for the Vulkan backend: if the native Vulkan
path is selected and cannot perform the operation, the operation is consumed
with an explicit error-scope report instead of pretending a successful no-op.

## 2026-07-04 — Vulkan browser replay baseline retained after rejected probes

The current Vulkan browser baseline remains recorded-repeat replay with
explicit subgroup policy and fast fence-pool wait accounting. The latest sync,
command-buffer, queue-family, subgroup, coherent-decoration, command-pool, and
source-kernel submit-cadence probes were rejected by focused paired-balanced
evidence and their source changes were reverted unless already part of the
accepted baseline.

Detailed negative evidence is archived at
[`archive/2026-07-04-runtime-vulkan-browser-probes.md`](archive/2026-07-04-runtime-vulkan-browser-probes.md).
Treat that archive and the referenced score sidecars as the audit trail before
revisiting any of those default-lane changes.

## 2026-07-04 — Vulkan recorded repeat replay reuses the prepared command buffer

The Vulkan drop-in replay path now begins recorded dispatch replay once for a
coalesced repeated dispatch command and records the repeated dispatches into
that prepared command buffer. This preserves the same dispatch sequence and the
same per-dispatch synchronization helpers, while removing redundant host replay
setup from the repeat loop.

Strict browser smoke for the rebuilt runtime is recorded at
`browser/chromium/artifacts/current-vulkan-recorded-repeat-replay/dawn-vs-doe.browser.playwright-smoke.vulkan-recorded-repeat-replay.json`.
The focused paired-balanced compute report is
`browser/chromium/artifacts/current-vulkan-recorded-repeat-replay/fawn-dawn-vs-fawn-doe.browser-layered.superset.diagnostic.json`
with checker sidecar
`browser/chromium/artifacts/current-vulkan-recorded-repeat-replay/fawn-dawn-vs-fawn-doe.browser-layered.superset.check.json`
and score sidecar
`browser/chromium/artifacts/current-vulkan-recorded-repeat-replay/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`.
Treat the score sidecar as the source of truth for row movement. The probe is
accepted as a runtime replay cleanup, but the sidecar still shows remaining
browser compute rows where Doe is behind Dawn.

## 2026-07-04 — Fawn runtime bench wrapper is paired-balanced by default

`browser/chromium/scripts/run-fawn-runtime-bench.sh` now passes
`modeSchedule=paired-balanced` and `strict-run` by default. This makes the
same-binary Fawn Dawn-vs-Doe browser-runtime front door match the current fair
evidence discipline instead of relying on the grouped historical default.

The wrapper still writes the standard layered report, summary, checker, and
score artifacts under `browser/chromium/artifacts/`. The README and wrapper
test now cover the default schedule and strict required-row handling.

## 2026-07-04 — SPIR-V direct compute entry probe rejected

A Vulkan SPIR-V emitter probe removed the compute entry wrapper for eligible
compute entry functions and emitted builtin inputs directly on the user entry
function. The emitted focused kernels validated with `spirv-val`, but
paired-balanced browser evidence rejected the change for the default Vulkan
browser path. The strict smoke stayed correct, but the focused paired-balanced
compute score and strict-comparable score regressed against the current
no-batch wrapper baseline.

The probe artifacts are:
`browser/chromium/artifacts/current-spirv-direct-compute-entry/dawn-vs-doe.browser.playwright-smoke.spirv-direct-compute-entry.json`,
`browser/chromium/artifacts/current-spirv-direct-compute-entry/fawn-dawn-vs-fawn-doe.browser-layered.superset.diagnostic.json`,
`browser/chromium/artifacts/current-spirv-direct-compute-entry/fawn-dawn-vs-fawn-doe.browser-layered.superset.check.json`,
and
`browser/chromium/artifacts/current-spirv-direct-compute-entry/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`.
The paired-balanced rejection artifacts are:
`browser/chromium/artifacts/current-spirv-direct-compute-entry-paired/fawn-dawn-vs-fawn-doe.browser-layered.superset.diagnostic.json`,
`browser/chromium/artifacts/current-spirv-direct-compute-entry-paired/fawn-dawn-vs-fawn-doe.browser-layered.superset.check.json`,
and
`browser/chromium/artifacts/current-spirv-direct-compute-entry-paired/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`.
A grouped no-batch comparison artifact is recorded at
`browser/chromium/artifacts/current-no-batch-grouped-refresh/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`.
The code was reverted to wrapper emission; these artifacts are negative
default-lane evidence for direct compute entry emission under the current
Vulkan browser path.

## 2026-07-04 — Vulkan deferred command-buffer batching rejected

The Vulkan recorded-submit replay path keeps one-at-a-time deferred
command-buffer allocation. A refreshed no-batch run is the current evidence for
the rebuilt runtime after command-buffer batching probes were rejected.

Strict browser smoke for the current no-batch rebuilt runtime is recorded at
`browser/chromium/artifacts/current-deferred-command-buffer-no-batch-refresh/dawn-vs-doe.browser.playwright-smoke.deferred-command-buffer-no-batch.refresh.json`.
The refreshed focused compute report is
`browser/chromium/artifacts/current-deferred-command-buffer-no-batch-refresh/fawn-dawn-vs-fawn-doe.browser-layered.superset.diagnostic.json`
with checker sidecar
`browser/chromium/artifacts/current-deferred-command-buffer-no-batch-refresh/fawn-dawn-vs-fawn-doe.browser-layered.superset.check.json`
and score sidecar
`browser/chromium/artifacts/current-deferred-command-buffer-no-batch-refresh/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`.
The checker requires both Dawn and Doe modes. Treat this as diagnostic evidence
only; the full focused compute category is still not a Dawn-beating performance
claim.

Initial pool-batch evidence remains at
`browser/chromium/artifacts/current-deferred-command-buffer-pool-batch/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`.
The refreshed current-hash pool-batch artifact at
`browser/chromium/artifacts/current-deferred-command-buffer-pool-batch-refresh/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`
failed to preserve the current no-batch focused evidence, so the code was
reverted and both batch artifacts are negative or superseded evidence, not
current runtime behavior.

A SPIR-V entry-wrapper inline-hint probe was rejected after
`browser/chromium/artifacts/current-spirv-entry-inline-hint/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`
regressed the focused compute score. The code was reverted; the artifact is
negative evidence for marking wrapper-backed WGSL functions as `Inline` under
the current Vulkan browser path.

A fence-capacity-sized command-buffer batch probe was rejected after
`browser/chromium/artifacts/current-deferred-command-buffer-fence-capacity/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`
regressed the focused compute score. The code was reverted.

## 2026-07-04 — Vulkan SPIR-V atomics now use WGSL relaxed semantics

Doe's WGSL-to-SPIR-V emitter now lowers WGSL atomic builtins with relaxed
SPIR-V memory semantics while retaining the existing workgroup/device scope
selection. This aligns the Vulkan shader path with WGSL's atomic memory model
instead of over-emitting acquire/release semantics and storage-class memory
semantics for atomic operations.

Previous focused compute evidence for the rebuilt runtime is
`browser/chromium/artifacts/current-relaxed-atomic-semantics/fawn-dawn-vs-fawn-doe.browser-layered.superset.diagnostic.json`
with checker sidecar
`browser/chromium/artifacts/current-relaxed-atomic-semantics/fawn-dawn-vs-fawn-doe.browser-layered.superset.check.json`
and score sidecar
`browser/chromium/artifacts/current-relaxed-atomic-semantics/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`.
The run uses the current projection contract hash and the strict Fawn binary,
and the checker requires both Dawn and Doe modes. Treat this as a correctness
fix with diagnostic row movement only; it does not promote the full focused
compute category to a performance claim.

Strict browser smoke for the same rebuilt runtime is recorded at
`browser/chromium/artifacts/current-relaxed-atomic-semantics/dawn-vs-doe.browser.playwright-smoke.relaxed-atomic-semantics.json`.
The receipt keeps the prior `importExternalTexture` and timestamp-query
correctness blockers green for both Dawn and Doe under the strict Fawn binary.

A buffer-scoped compute-write barrier probe was rejected after
`browser/chromium/artifacts/current-buffer-scoped-compute-barrier/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`
regressed the focused compute score. The code was reverted; the artifact is
negative evidence for replacing the current global compute-to-compute barrier
with per-buffer barriers under the current Vulkan replay path.

## 2026-07-04 — Browser projections separate strict claims from directional rows

The browser projection manifest contract is now schema v5. Strict browser
projection rows must carry `benchmarkClass=comparable`; component-only and
non-projectable rows must carry `benchmarkClass=directional` even when the
source workload remains claim-eligible in the L0 superset. This keeps source
provenance separate from browser claimability and prevents component diagnostics
from entering strict browser score evidence as comparable rows.

The default AMD Vulkan and Apple Metal generated projection manifests were
regenerated under the new contract:
`browser/chromium/bench/generated/browser_projection_manifest.json` and
`browser/chromium/bench/generated/browser_projection_manifest.apple.metal.json`.
Existing layered reports generated under earlier projection contract hashes
remain runtime evidence, but they must be regenerated before being cited as
current browser-superset checker-green artifacts. This is evidence-discipline
work only; it does not change the current browser runtime performance result or
promote any directional row to a release claim.

Previous schema-v5, report-schema-v4 focused compute evidence is
`browser/chromium/artifacts/current-source-kernel-phase-telemetry/fawn-dawn-vs-fawn-doe.browser-layered.superset.diagnostic.json`
with score sidecar
`browser/chromium/artifacts/current-source-kernel-phase-telemetry/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`.
The run uses `modeSchedule=paired-balanced`, passes the browser superset
checker, and keeps required browser runtime setup green for both Dawn and Doe.
The full focused compute category remains negative because direct dispatch and
workgroup rows still lose. Compute component dispatch rows and strict
source-kernel rows now emit `dispatchElapsedMs`, `encodeSubmitMs`, and `waitMs`.
Treat this as superseded diagnostic evidence, not as a release performance
claim. Older report-schema-v3 focused compute artifacts remain superseded by
report-schema-v4 evidence.

A scoped compute-write buffer-barrier probe was rejected after
`browser/chromium/artifacts/current-scoped-compute-barrier-fix/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`
regressed the focused compute score. The code was reverted; the artifact is
negative evidence for replacing the current global compute-to-compute barrier
with per-buffer barriers under the current Vulkan replay path.

A resource-free direct-dispatch batching probe was also rejected after
`browser/chromium/artifacts/current-resource-free-direct-batch-probe/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`
regressed the focused compute score and worsened direct-dispatch wait-side
timing. The code was reverted; the artifact is negative evidence for carrying
Vulkan recorded replay across WebGPU `queue.submit` boundaries for
resource-free direct-dispatch rows under the current browser path.

Queue-policy probes were rejected as default-lane changes. The existing
`vulkan_doe_compute_only_fence_diagnostic` lane produced diagnostic evidence at
`browser/chromium/artifacts/current-compute-only-fence-v3-diagnostic/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`,
but hard compute-only selection remains a diagnostic lane, not a default app
policy. A graphics-compute fence-pool app-lane probe at
`browser/chromium/artifacts/current-vulkan-app-fence-v3-probe/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`
and a prefer-compute-only fence-pool app-lane probe at
`browser/chromium/artifacts/current-vulkan-app-prefer-compute-fence-v4-probe/fawn-dawn-vs-fawn-doe.browser-layered.superset.score.json`
regressed the focused evidence. Both temporary config changes were reverted.

## 2026-07-04 — Vulkan resource destruction now drains pending queue work

Vulkan buffer, texture, texture-view, sampler, and query-set destruction now
drains pending runtime queue work before destroying the backend handle. This
closes a resource lifetime gap where a WebGPU object could be released after
`queue.submit` while Doe still had deferred Vulkan work referencing that object.
The change is a correctness prerequisite for any future cross-submit batching;
it is not a performance claim.

Current strict browser smoke evidence is
`browser/chromium/artifacts/current-vulkan-lifetime-flush-fix/dawn-vs-doe.browser.playwright-smoke.vulkan-lifetime-flush.texture-view.releasefast.json`.
It keeps timestamp-query and `importExternalTexture` smoke correctness green.

Current focused compute evidence for the rebuilt runtime is
`browser/chromium/artifacts/current-vulkan-lifetime-flush-fix/dawn-vs-doe.browser.layered-compute.vulkan-lifetime-flush.texture-view.releasefast.json`
with score sidecar
`browser/chromium/artifacts/current-vulkan-lifetime-flush-fix/dawn-vs-doe.browser.layered-compute.vulkan-lifetime-flush.texture-view.releasefast.score.json`.
The report was generated before projection manifest schema v5 and must be
rerun before it is cited as current browser-superset checker-green evidence. It
remains diagnostic: Doe is still behind Dawn for the focused compute category
under the same strict Fawn binary.

A cross-submit replay batching probe was rejected after
`browser/chromium/artifacts/current-cross-submit-replay-batch-probe/dawn-vs-doe.browser.layered-compute.cross-submit-replay-batch.releasefast.score.json`
regressed the focused current-binary browser score. The code was reverted; the
artifact remains negative evidence for deferring the Vulkan driver submit beyond
the WebGPU `queue.submit` boundary under the current runtime design.

Two later queue-replay probes were also rejected before retention. An untimed
recorded-replay command-buffer submit batch deferred Vulkan submits to the flush
boundary, but strict smoke did not produce a usable report. A repeated-dispatch
command-buffer reuse probe passed local build and unit tests, but Doe-only
browser smoke did not produce a usable report. Both patches were reverted; do
not treat either idea as promoted without new smoke evidence.

## 2026-07-04 — Browser prepared-dispatch replay cache retained, single-submit dispatch still blocks

The Vulkan browser queue-submit replay path now keeps a submit-local prepared
dispatch state and reuses it only for adjacent recorded dispatch commands with
the same compute pipeline and exactly matching recorded Vulkan binding state.
This preserves the submitted WebGPU command stream, dispatch count, barriers,
and command order while avoiding redundant Vulkan pipeline/binding preparation
inside multi-dispatch compute passes.

Current focused evidence for the rebuilt runtime is
`browser/chromium/artifacts/current-prepared-dispatch-cache-fix/dawn-vs-doe.browser.layered-compute.prepared-dispatch-cache.refresh.releasefast.json`
with score sidecar
`browser/chromium/artifacts/current-prepared-dispatch-cache-fix/dawn-vs-doe.browser.layered-compute.prepared-dispatch-cache.refresh.releasefast.score.json`.
The report validates with the browser benchmark superset checker and remains
diagnostic: Doe improves selected multi-dispatch rows but is still behind Dawn
for the focused compute category under the same strict Fawn binary.

The companion strict smoke artifact is
`browser/chromium/artifacts/current-prepared-dispatch-cache-fix/dawn-vs-doe.browser.playwright-smoke.prepared-dispatch-cache.releasefast.json`.
It keeps timestamp-query and `importExternalTexture` smoke correctness green,
while the dispatch smoke still shows the single-submit compute path as the
active browser blocker.

Cross-`queue.submit` Vulkan driver-submit batching was not promoted in this
entry. It could reduce single-submit overhead, but it also requires an explicit
resource-lifetime contract so command buffers cannot reference buffers,
pipelines, query sets, or textures destroyed after WebGPU `queue.submit` and
before `onSubmittedWorkDone`.

A Vulkan-only no-binding command-recording fast path was also rejected after
`browser/chromium/artifacts/current-no-binding-recording-fastpath-fix/dawn-vs-doe.browser.layered-compute.no-binding-recording-fastpath.releasefast.score.json`
regressed the focused current-binary browser score. The code was reverted; the
artifact remains negative evidence for the single-submit dispatch blocker.

## 2026-07-04 — Browser replay fastpath retained, direct submit remains the compute blocker

The Vulkan recorded-submit replay path now reuses the active replay command
buffer when a prepared direct dispatch records more work into the same
queue-submit replay. This removes repeated streaming-copy flush and submission
state checks inside an already-active recorded replay while preserving the
existing per-dispatch transfer/compute visibility barriers and command order.

Current default-policy focused evidence for the rebuilt runtime is
`browser/chromium/artifacts/current-replay-fastpath-refresh/dawn-vs-doe.browser.layered-compute.replay-fastpath.refresh.releasefast.json`
with score sidecar
`browser/chromium/artifacts/current-replay-fastpath-refresh/dawn-vs-doe.browser.layered-compute.replay-fastpath.refresh.releasefast.score.json`.
The report validates with the browser benchmark superset checker and remains
diagnostic: the compute category is still behind Dawn under the same strict Fawn
binary. Direct-dispatch submit-heavy rows and selected source-kernel rows remain
active blockers.

Current strict smoke correctness evidence for the same rebuilt runtime is
`browser/chromium/artifacts/current-replay-fastpath-refresh/dawn-vs-doe.browser.playwright-smoke.replay-fastpath.refresh.releasefast.json`.
It keeps the timestamp-query and `importExternalTexture` browser smoke blockers
closed while preserving the existing upload-win and dispatch-loss shape.

Earlier retained evidence for the replay fastpath is
`browser/chromium/artifacts/current-replay-fastpath-retained/dawn-vs-doe.browser.layered-compute.replay-fastpath-retained.releasefast.json`
with score sidecar
`browser/chromium/artifacts/current-replay-fastpath-retained/dawn-vs-doe.browser.layered-compute.replay-fastpath-retained.releasefast.score.json`.

Follow-on probes were rejected rather than promoted. A submit-local
prepared-dispatch cache was removed after
`browser/chromium/artifacts/current-submit-prepare-cache-fix/dawn-vs-doe.browser.layered-compute.submit-prepare-cache.releasefast.score.json`
showed mixed row movement and a worse focused score. A no-binding static
pipeline-hash shortcut was also removed after
`browser/chromium/artifacts/current-no-binding-static-hash-fix/dawn-vs-doe.browser.layered-compute.no-binding-static-hash.releasefast.score.json`
failed to improve the focused browser evidence. Deferred command-buffer
batch-growth probes were reverted after
`browser/chromium/artifacts/current-command-buffer-batch-fix/dawn-vs-doe.browser.layered-compute.command-buffer-batch.releasefast.score.json`,
`browser/chromium/artifacts/current-command-buffer-batch-refresh/dawn-vs-doe.browser.layered-compute.command-buffer-batch.refresh.releasefast.score.json`,
and
`browser/chromium/artifacts/current-command-buffer-batch-256-fix/dawn-vs-doe.browser.layered-compute.command-buffer-batch-256.releasefast.score.json`
failed to produce stable current-binary improvement. A repeated-dispatch replay
loop probe was reverted after
`browser/chromium/artifacts/current-repeated-dispatch-replay-refresh/dawn-vs-doe.browser.layered-compute.repeated-dispatch-replay.refresh.releasefast.score.json`
failed the same current-binary check. The existing
`vulkan_doe_compute_only_fence_diagnostic` policy was also run as a diagnostic
at
`browser/chromium/artifacts/current-fence-policy-diagnostic/dawn-vs-doe.browser.layered-compute.compute-only-fence-diagnostic.releasefast.score.json`;
that path likewise does not justify changing the release lane policy.

## 2026-07-04 — Browser compute projections now measure command-shaped dispatch

The generated browser projection manifest now detects compute workloads whose
source command artifact is made of direct dispatch commands or indirect dispatch
commands. It emits `generic_direct_dispatch_component` workloads with
`directDispatchArgs` and `generic_indirect_dispatch_component` workloads with
`indirectDispatchArgs`, both hash-linked to the source command artifact. The
Playwright layered runner accepts the new direct and indirect scenario templates
and records command-shaped dispatch metrics, including dispatch kind, argument
shape, submit count, dispatch count, and command hash.

The browser benchmark superset checker now validates direct and indirect command
hashes and runtime metrics, including paired-balanced aggregation. The generated
manifest schema also records the argument contracts, and the browser benchmark
README names the fields so the projection is inspectable.

Current focused evidence is
`browser/chromium/artifacts/current-direct-indirect-projection-fix/dawn-vs-doe.browser.layered-compute.direct-indirect-projection.releasefast.json`
with score sidecar
`browser/chromium/artifacts/current-direct-indirect-projection-fix/dawn-vs-doe.browser.layered-compute.direct-indirect-projection.releasefast.score.json`.
The run is still diagnostic. It improves command-shape evidence for direct and
indirect dispatch, but the compute category remains blocked by direct-dispatch
and workgroup-memory losses under the same-browser matched runtime path.

Follow-up: shard `browser/chromium/scripts/check-browser-benchmark-superset.py`
by extracting projection-manifest parsing and runtime-evidence validators; owner
runtime-bench.

## 2026-07-04 — Vulkan compute indirect now replays the real indirect buffer

The Doe Vulkan drop-in compute path now records `dispatchWorkgroupsIndirect`
against the caller's Vulkan buffer instead of reading the dispatch dimensions on
the host and copying them into a Doe-owned indirect-args buffer. Vulkan compute
buffers now carry indirect-buffer usage, and the replay path emits transfer and
compute visibility barriers for indirect-command reads.

Focused browser evidence is in
`browser/chromium/artifacts/current-indirect-dispatch-fix/doe.compute-dispatch-indirect.probe.releasefast.json`.
The strict Doe and Dawn smoke artifacts for the same ReleaseFast runtime rebuild
are
`browser/chromium/artifacts/current-indirect-dispatch-fix/dawn-vs-doe.browser.playwright-smoke.doe.indirect-fix.releasefast.json`
and
`browser/chromium/artifacts/current-indirect-dispatch-fix/dawn-vs-doe.browser.playwright-smoke.dawn.indirect-fix.releasefast.json`.

The paired browser compute score remains diagnostic and behind Dawn; see
`browser/chromium/artifacts/current-indirect-dispatch-fix/dawn-vs-doe.browser.layered-compute.indirect-fix.releasefast.score.json`.
That earlier projection still used the generic empty direct-dispatch browser
component for indirect source workloads. The command-shaped projection entry
above supersedes that limitation. The active performance blocker remains browser
direct-dispatch submit overhead under matched timing scope.

## 2026-07-04 — Browser external texture smoke passes in strict Fawn

The Doe browser path now routes Chromium shared-image mailbox textures through
the Skia upload fallback when the selected WebGPU runtime is Doe's external
`BackendType::WebGPU` path. This avoids attempting a Dawn-native shared-image
import for a Doe external-runtime texture while still sampling the real
shared-image pixels through a normal Doe texture.

The rebuilt strict Fawn binary at `browser/chromium/src/out/fawn_release/chrome`
has SHA256
`42355e5944508d58a1a121fbfc088d190e7a7e8ea1ca85e4c2453b0c1867c3dd`. Current
focused evidence is
`browser/chromium/artifacts/current-external-texture-fix/dawn-vs-doe.browser.playwright-smoke.doe.external-texture-v2.json`;
the same binary also has the Dawn-mode companion artifact at
`browser/chromium/artifacts/current-external-texture-fix/dawn-vs-doe.browser.playwright-smoke.dawn.external-texture-v2.json`.

The strict smoke correctness blockers for timestamp query output and
`importExternalTexture` are no longer active in those artifacts. Browser release
readiness remains blocked on public release-candidate packaging and on the
mixed Dawn-vs-Doe performance evidence, especially compute-dispatch rows.

## 2026-07-04 — Browser timestamp smoke now rejects and fixes zero readback

The Playwright browser smoke now fails timestamp queries that resolve to all
zero values instead of accepting monotonic `[0, 0]` output. The timestamp probe
also records a tiny compute dispatch inside the timestamped pass, so the check
observes query writes around real GPU work.

The Doe Vulkan drop-in path now routes `wgpuDeviceCreateQuerySet` through the
descriptor ABI wrapper, records compute-pass `timestampWrites`, replays Vulkan
query writes/resolves in queue-submit order, and drains Vulkan map-read
readbacks before exposing mapped data. Current focused evidence is
`browser/chromium/artifacts/current-timestamp-fix/dawn-vs-doe.browser.playwright-smoke.doe.timestamp-fix-v11.json`.

That artifact shows the timestamp smoke producing non-zero values. Strict
`chrome` smoke remains blocked by `importExternalTexture`; the previous
zero-timestamp blocker is no longer the active failure.

## 2026-07-03 — Browser package inputs record release build profile

Browser package-input preflights now emit a `buildProfile` section when an
`args.gn` file is present beside the Chromium output or app bundle. The
release-candidate path requires the documented Fawn release profile:
`is_official_build=true`, `dcheck_always_on=false`, no Chrome-for-Testing or
branded Chrome identity, zero symbol levels, `use_clang_modules=false`, and the
Doe WebGPU backend flag.

This prevents a local `is_debug=false` Chromium build with DCHECKs, missing
official-build optimization, or profile drift from looking release-candidate
ready. Diagnostic Linux archives remain packageable, but the candidate blockers
now name the build-profile mismatch explicitly.

The Linux Fawn GUI benchmark investigation rebuilt
`browser/chromium/src/out/fawn_release/chrome` with the strict official Fawn
profile and added the matching `fawn-release-build.json` stamp. The rebuilt
binary is Chromium `149.0.7781.0` with SHA256
`b87b89932046d6f5d1eab0f0d54c36b3a186a2d1b335fd4ac61efbb44b0623bd`.
Package input preflight now passes with `buildProfile.releaseProfileMatched=true`;
the Linux artifact remains diagnostic-only because the first release lane is
macOS arm64.

Corrected same-binary evidence does not support a "Doe crushes Dawn" claim.
The strict Fawn smoke shows Doe faster on 64 KiB upload but slower on compute
dispatch, and Doe still fails `importExternalTexture` while returning zero
timestamp values. The focused paired-balanced layered run over compute and
memory rows completed with zero required row failures, but the score is
Doe `41.93` vs Dawn `58.07` overall, and category-balanced Doe `42.09` vs Dawn
`57.91`. The summary artifact is
`bench/out/public-browser-release/20260703T233418Z/fawn-strict-release-profile-investigation-summary.json`.

## 2026-07-03 — Dawn replacement readiness is platform-sliced

`config/dawn-replacement-frontier.json` now splits each Dawn replacement
frontier row into explicit evidence slices keyed by operating system,
architecture, GPU API, GPU vendor, and runtime host. The schema and gate require
those slices, validate their evidence paths, blocker definitions, and claim-index
references, and reject a claim-allowed row if any of its slices remains blocked.

The readiness rollup now emits those slices beside the product rows and reports
slice-level claim state separately from product-row claim state. This makes
native Linux AMD Vulkan, drop-in Linux AMD Vulkan, Chromium macOS Apple Metal,
Chromium Linux AMD Vulkan, Chromium Windows D3D12, CTS, package, and compiler
coverage inspectable without inflating the broader replacement claim. See
`examples/dawn-replacement-readiness-report.sample.json` for the current
machine-readable state.

## 2026-07-02 — Linux drop-in cutover rehearsal is indexed

The drop-in ABI runtime lane now has a claim-indexed Linux Vulkan cutover
rehearsal receipt. The evidence binds the ReleaseFast `libwebgpu_doe.so`
artifact to the drop-in symbol, behavior, proc-resolution, and benchmark gates,
then binds rollback to the AMD Vulkan Dawn delegate release claim. See
`bench/out/dropin/20260702T164301Z/linux-dropin-report.json`,
`bench/out/dropin/20260702T164301Z/dropin-cutover-rehearsal-receipt.json`,
`bench/out/dropin/20260702T164301Z/dropin-cutover-rehearsal.claim.json`, and
`examples/dawn-replacement-readiness-report.sample.json` for the current
machine-readable state.

## 2026-07-02 — AMD Vulkan release claim is indexed

The AMD Vulkan native Doe-vs-Dawn release lane now has a claim-indexed release
artifact. The run passed strict AMD/Vulkan preflight, blocking gates, structural
equivalence, shader-artifact validation, Vulkan sync/timing policy gates,
release claim gating, and claim-rehearsal artifact generation. See
`bench/out/amd-vulkan/20260702T163200Z/dawn-vs-doe.amd.vulkan.release.json`,
`bench/out/amd-vulkan/20260702T163200Z/dawn-vs-doe.amd.vulkan.release.claim.json`,
and
`bench/out/amd-vulkan/20260702T163200Z/dawn-vs-doe.amd.vulkan.release.claim-rehearsal.manifest.json`
for the machine-readable evidence.

## 2026-07-02 — Package-input eligibility is schema-bound

`config/browser-release-package-inputs-check.schema.json` now treats
`releaseCandidateEligible=true` as a schema-level release claim. Eligible
package-input receipts must also be passing, release-candidate-mode receipts
with no failures or release-candidate blockers, the initial macOS arm64 zip
platform, release-candidate channel identity, and arm64 Mach-O browser/runtime
tool inputs plus packaged plist metadata.

The package-input checker already emitted that state; the schema now rejects
manually edited candidate receipts before higher-level release, provenance,
finalizer, runtime-frontier, readiness, or claim-index gates consume them. The
Chromium browser row remains blocked on `chromium_release_build_evidence`
until a real release-candidate archive lands.

## 2026-07-02 — Browser candidate byte checks stay release-scoped

Browser release-candidate validation now keeps the byte-exact archive member
checks on the candidate path while allowing diagnostic bundles to carry blocked
Chromium checkout evidence without recalculating candidate runtime-frontier
identity. The same candidate path still verifies the browser executable, Doe
runtime, Dawn fallback runtime, archive manifest member hashes, and runtime
frontier release identity before a browser artifact can promote.

The release-candidate staging tool now emits `webgpuAvailable=true` into the
proof-page diagnostics it binds, matching the proof-page receipt and published
proof-surface contract. The Chromium browser row remains blocked on
`chromium_release_build_evidence` until a real release-candidate archive lands.

## 2026-07-02 — Public gallery pages expose backend receipt facts

Browser public gallery pages now have to visibly expose the backend receipt
facts for each linked execution receipt: receipt/workload ID, WGSL source
shader and hash, lowering path, backend, driver/device identity, output or
frame hash, and setup/encode/submit-wait timing phases. The proof-surface
builder, proof-surface checker, and public-gallery receipt builder all enforce
the same page-content rule, including HTML-escaped source text.

The five checked gallery samples now show those facts for compute, rendering,
tensor, shader-edge, and benchmark-trace receipts. The public-gallery receipts,
published proof surface, proof-surface check, launch receipt, provenance
report, release bundle, runtime frontier bundle, and Dawn replacement readiness
sample were refreshed. The Chromium browser row remains blocked on
`chromium_release_build_evidence`.

## 2026-07-02 — Proof pages expose WebGPU availability

The browser proof-page receipt and published proof-surface schemas now require
`diagnostics.webgpuAvailable=true`. The proof-page receipt builder emits and
validates the field, the proof-surface builder and checker reject unavailable
WebGPU diagnostics, and the checked `about:doe` sample visibly shows the
availability state before the proof surface can bind it.

The Dawn replacement readiness rollup now exposes
`publishedProofSurface.webgpuAvailable=true` for the Chromium browser row, so
downloadable-browser evidence carries an explicit WebGPU-available diagnostic
beside the active Doe backend and compiler path.

## 2026-07-02 — Launch receipts reject unlinked observed IDs

Browser release launch receipts now require `observedReceiptIds` to contain
exactly the proof-page, public-gallery, Dawn comparison, and Doe comparison
receipt IDs named by the launch receipt. The schema caps the list at four
unique IDs, the launch receipt builder rejects extra IDs before emission, and
the release bundle checker, readiness rollup, and claim-index browser release
checks now fail candidate evidence that carries unlinked observed receipt IDs.

This keeps packaged-browser launch evidence closed over the proof surface
instead of allowing extra runtime receipts to sit outside the public proof
gallery.

## 2026-07-02 — Launch receipts prove fallback was not used

Browser release launch receipts now carry `hiddenFallbackUsed=false` alongside
the existing hidden-fallback policy state. The launch receipt builder emits the
field, the release artifact bundle checker rejects candidate launch evidence
that reports fallback usage, and the Dawn replacement readiness rollup keeps
the Chromium browser row blocked when the packaged-browser launch does not
prove hidden fallback stayed unused.

The checked diagnostic sample was refreshed through launch, provenance, release
bundle, runtime frontier, and readiness receipts. It remains blocked on
`chromium_release_build_evidence`.

## 2026-07-02 — Candidate package inputs bind shader compiler identity

macOS browser release-candidate package inputs now require the
`shaderCompiler` artifact to carry Mach-O identity for the declared platform
architecture, matching the browser executable, Doe runtime, and Dawn fallback
runtime checks. Release-bundle, provenance, finalizer, finalizer-check, and
readiness consumers reuse the same package-input helper, so stale compiler
identity can no longer pass by only being executable.

## 2026-07-02 — Archive manifests bind package-input source paths

Browser release archive manifest verification now checks that each
package-sourced required member named by `sourcePackageInputs` records a
`members.<role>.sourcePath` matching the corresponding package-input `path`.
The Dawn replacement readiness rollup now mirrors the same check when it
summarizes browser release-candidate consistency. Generated metadata remains
allowed to omit `sourcePath`. This closes a same-bytes/different-source
ambiguity before a release-candidate archive can serve as Chromium browser
evidence.

## 2026-07-01 — Provenance preflight keeps failing package identity

The release-candidate provenance checker now keeps using a loaded
`browser_release_package_inputs_check` report as the browser product, platform,
and packaged-member source of truth even when that package-input report is not
release-candidate eligible. The report still fails closed on the package-input
candidate blockers and the initial macOS arm64 policy, but the checked browser
readiness sample no longer adds provenance product/platform drift on top of the
real blocker. See `examples/browser-release-candidate-provenance.sample.json`
and `examples/dawn-replacement-readiness-report.sample.json` for the current
machine-readable state.

## 2026-07-01 — Candidate consumers require package-input binary identity

Release-candidate provenance, staging, finalizer, finalizer-check, and release
bundle verification now reject stale package-input reports that claim macOS
release-candidate eligibility without Mach-O arm64 identity on the packaged
browser executable, Doe runtime, and Dawn fallback runtime. The checked-in
diagnostic browser sample remains diagnostic, but stale JSON can no longer
drive candidate evidence merely by setting `releaseCandidateEligible=true`.

## 2026-07-01 — Proof-surface comparison receipts bind release artifacts

The browser proof-surface comparison sample now uses the release bundle's
browser, Dawn fallback, Doe runtime, and compiler artifact identities in the
same-page smoke report, and the Dawn/Doe execution receipts now bind the smoke
report through command-graph evidence. The published proof surface, proof check,
launch receipt, release bundle, runtime-frontier bundle, provenance report, and
readiness sample were refreshed so browser release consistency no longer carries
the comparison artifact/hash mismatch failures. The remaining browser release
consistency failures are the real candidate-state blockers: diagnostic bundle
status, noncandidate package inputs, failing provenance, and failing finalizer.

## 2026-07-01 — Candidate provenance binds package inputs before eligibility

Browser release-candidate provenance reports now hash-bind the
`browser_release_package_inputs_check` artifact even when that package-input
report is not release-candidate eligible. Noncandidate package inputs still
produce explicit provenance failures and cannot drive staged candidate artifact
generation, but readiness no longer reports missing package-input provenance
when the failing preflight artifact is present and hash-matched.

## 2026-07-01 — Proof-surface check requires public gallery URLs

The checked-in browser published proof-surface check now runs with
`--require-public-urls` and still passes against the sample proof gallery. The
release bundle, runtime-frontier bundle, release-candidate provenance report,
and readiness sample were refreshed so the browser release consistency rollup
no longer carries the `proof_surface_check_without_public_urls` blocker. The
frontier remains blocked on `chromium_release_build_evidence` until the
diagnostic Linux/x64 archive is replaced by real release-candidate browser
evidence.

## 2026-07-01 — Browser diagnostic archive matches package inputs

The browser release archive packer now has a diagnostic-only required-members
mode for compact samples, and generated ZIP members use fixed timestamps with
deflated payloads. The checked-in diagnostic archive, archive manifest,
public-download receipt, proof page receipt, proof surface, launch receipt,
release bundle, runtime-frontier bundle, claim-index pointer, and readiness
sample now agree on the Linux/x64 package-input paths and hashes instead of
labeling Linux inputs as a macOS app bundle. The browser frontier still remains
blocked on `chromium_release_build_evidence`; the release-candidate provenance
report and finalizer continue to fail until real macOS arm64 release-candidate
package inputs exist.

## 2026-07-01 — Finalizer check sample enforces pass mode

The checked-in browser release-candidate finalizer-check sample now runs with
`--verify-files-root`, so the receipt proves the finalizer report path and hash
were checked. The underlying finalizer remains an honest
`provenance_preflight` failure, and the checker now uses `--require-pass`, so
the checker receipt itself fails with `finalizer_report_not_pass` until final
browser release evidence is real. Readiness therefore drops the stale
`finalizer_check_without_file_verification` and
`finalizer_check_without_require_pass` failures and reports the stricter
`finalizer_check_not_pass` failure instead.

## 2026-07-01 — Browser archives reject fake macOS binary members

Browser release-candidate archive checks now inspect packaged browser/runtime
members before accepting macOS arm64 evidence. The release artifact bundle
checker and readiness consistency rollup reject a release-candidate archive
whose browser executable, Doe runtime, or Dawn fallback runtime is not Mach-O
for the declared platform architecture. Forcing the current diagnostic sample
through the release-candidate checker now reports the shell `Chromium` member
and ELF x64 runtimes instead of letting archive path names stand in for binary
identity.

## 2026-07-01 — Browser package inputs record binary identity

Browser release package-input receipts now record detected file format and
architecture for browser/runtime/compiler inputs. The package-input checker
rejects macOS package inputs whose browser executable, Doe runtime, or Dawn
fallback runtime is not Mach-O for the declared platform arch, and the
readiness rollup rejects stale release-candidate package-input artifacts that
omit or falsify those binary identity facts. The default sample remains
diagnostic Linux/x64 evidence and now explicitly records `chrome-wrapper` as a
script and the local runtimes/compiler as ELF x64, preserving the
`chromium_release_build_evidence` blocker until a real macOS arm64 browser
release exists.

## 2026-07-01 — Browser proof sample uses concrete diagnostics

The checked-in browser proof page sample now reports concrete TSIR/HostPlan/CSL
status values (`available`/`not_applicable`) instead of placeholder
`diagnostic` values. The proof-page receipt, published proof-surface manifest,
proof-surface check, launch receipt, provenance report, release bundle,
runtime-frontier bundle, and readiness sample hashes were refreshed so the
default Chromium browser release checklist no longer carries the
`browser_release_proof_surface_non_release_diagnostic_status` failure.

## 2026-07-01 — Browser readiness keeps failed candidates on release blocker

Generated browser readiness rows now keep `chromium_release_build_evidence` as
the blocker when a custom runtime-frontier bundle is otherwise claimable but
release-candidate consistency still fails. This prevents scratch
release-candidate rehearsals from rendering as blocked with no blocker code.

## 2026-07-01 — Claim-index proof pages require concrete diagnostics

Claim-indexed Chromium browser proof surfaces now reject `diagnostic`,
`placeholder`, `sample`, `tbd`, `todo`, or `unknown` TSIR/HostPlan/CSL status
values on `about:doe`. The readiness rollup reuses the same proof-surface
validator, so release-candidate browser evidence now surfaces
`browser_release_proof_surface_non_release_diagnostic_status` when proof-page
diagnostics are still placeholders.

## 2026-07-01 — Browser release consistency exposes failure-code summary

Browser release-candidate readiness consistency now emits `failureCount` and
sorted unique `failureCodes` beside the detailed failure rows. The Chromium
release-build blocker can now be consumed as a compact checklist while still
preserving each path-specific failure needed to close the downloadable-browser
evidence gap.

## 2026-07-01 — Finalizer-check receipts bind checked artifacts

Clean browser release-candidate finalizer-check receipts now copy the checked
finalizer `inputs.packageInputs`, `inputs.provenanceReport`,
`outputs.releaseArtifactBundle`, and `outputs.runtimeFrontierBundle` artifact
identities. The readiness rollup rejects missing or stale checker bindings
against the finalizer report, and the claim-index browser release gate rejects
claim-indexed releases whose finalizer-check receipt does not bind the same
package-input, provenance, release-bundle, and runtime-frontier artifacts named
by the browser release row.

## 2026-07-01 — Finalizer hash-binds provenance input

Passing browser release-candidate finalizer reports now hash-bind
`inputs.provenanceReport` beside `inputs.packageInputs`. The finalizer checker,
readiness rollup, and claim-index browser release gate verify that the bound
provenance report matches the final release bundle, component artifacts,
package-input receipt, and configured browser release path/hash, so final
browser release evidence cannot be separated from the provenance preflight that
authorized it.

## 2026-07-01 — Provenance staging rejects dirty package inputs

The browser release-candidate provenance preflight and staging tool now reject
package-input receipts that are candidate-labelled but still dirty. Both paths
require release-candidate eligibility, `evidenceMode=release_candidate`, empty
package-input failures, empty release-candidate blockers, and
`summary.packageable=true`, so staged proof/provenance artifacts cannot derive
from stale packageability evidence.

## 2026-07-01 — Finalizer rejects dirty package inputs

The browser release-candidate finalizer now rejects package-input receipts that
are candidate-labelled but still dirty. Final assembly and finalizer-check
validation both require `releaseCandidateEligible=true`,
`evidenceMode=release_candidate`, empty package-input failures, empty
release-candidate blockers, and `summary.packageable=true`, so stale
packageability receipts cannot survive into final browser release evidence.

## 2026-07-01 — Release manifests reject diagnostic source package inputs

Release-candidate archive manifest verification now rejects `sourcePackageInputs`
receipts that are merely diagnostic/packageable. The manifest checker requires
the source package-input receipt to be release-candidate eligible, carry
`evidenceMode=release_candidate`, have no failures or release-candidate
blockers, and report `summary.packageable=true`, so the release archive
manifest cannot hash-bind the wrong packageability lane.

## 2026-07-01 — Release bundles reject diagnostic package inputs

Release-candidate browser bundle verification now rejects package-input
receipts that are merely diagnostic/packageable. The release bundle checker
requires the package-input receipt to be release-candidate eligible, carry
`evidenceMode=release_candidate`, have no failures or release-candidate
blockers, and report `summary.packageable=true`, so a Linux diagnostic package
preflight cannot satisfy the final browser release bundle boundary.

## 2026-07-01 — Browser package inputs reject malformed platform identity

The browser release package-input preflight now rejects invalid platform OS and
architecture values while preserving schema-valid failed reports. The
package-input schema allows malformed platform identity only on failed reports
and still requires macOS/Linux, arm64/x64, and zip package format whenever
`status=pass`, so malformed platform identity cannot become packageable browser
release evidence.

## 2026-07-01 — Browser package inputs reject malformed product identity

The browser release package-input preflight now rejects invalid product IDs,
invalid product channels, and empty `browserProduct.version` values while
preserving schema-valid failed reports. The package-input schema allows
malformed product identity only on failed reports and still requires canonical
product ID, display name, channel, and non-empty version whenever `status=pass`,
so malformed product identity cannot become packageable browser release
evidence.

## 2026-07-01 — Browser package inputs reject unsafe member paths

The browser release package-input preflight now has focused regression coverage
for non-normalized browser executable package paths, app metadata package paths,
and explicit Doe/Dawn runtime archive-path overrides. Mutated package-input
reports fail with `invalid_archive_member_path` before archive creation, so the
earliest packageability receipt enforces the same packaged-member path
discipline as the release bundle, readiness, and claim-index gates.

## 2026-07-01 — Browser readiness rejects unsafe app metadata paths

The Dawn replacement readiness rollup now rejects unsafe
`browserAppMetadataArchivePath` values before loading packaged app metadata
from the release archive. Focused macOS and non-macOS regressions mutate the
Info.plist and browser-metadata JSON member paths to include current segments
and require `release_archive_app_metadata_path_unsafe`, keeping app metadata
evidence under the same archive-member path rules as packaged browser/runtime
bytes.

## 2026-07-01 — Browser readiness rejects unsafe archive member indexes

The Dawn replacement readiness rollup now rejects unsafe
`releaseArchiveManifest.archiveMembers` paths before accepting the manifest
index as release-candidate evidence. A focused regression mutates the packaged
browser member path to include an empty segment, proving readiness reports
`release_archive_manifest_archive_member_path_unsafe` instead of trusting
normalized archive syntax.

## 2026-07-01 — Browser claim index rejects unsafe archive member syntax

The public claim-index browser release gate now rejects unsafe archive member
paths in both release artifact bundles and release archive manifests. Focused
claim-index regressions cover `browserExecutableArchivePath` with a current
segment and manifest `members.browserExecutable.archivePath` with an empty
segment, so malformed packaged-browser member paths fail before public
claim-index evidence can rely on normalized archive syntax.

## 2026-07-01 — Browser release archive members reject hidden path segments

The browser release bundle checker and Dawn replacement readiness rollup now
reject archive member paths with empty, current, parent, absolute, or backslash
segments before matching packaged browser/runtime bytes. Focused regressions
cover `browserExecutableArchivePath` values such as `Fawn.app/./...` and
`Fawn.app//...`, preventing normalized archive paths from satisfying
release-candidate evidence.

## 2026-07-01 — Browser claim index rejects outside proof receipts

The claim-index proof-surface receipt checks now have focused regression
coverage for unsafe proof-page diagnostic receipt and public-gallery receipt
paths. Mutated published proof surfaces that point those receipt artifacts at
absolute files outside the repo fail with the corresponding `_incomplete`
errors before the public gate loads or hashes the receipts.

## 2026-07-01 — Browser claim index rejects outside execution receipts

The claim-index proof-surface receipt checks now have focused regression
coverage for unsafe backend execution receipt paths. A mutated published proof
surface that points a Dawn comparison receipt at an absolute file outside the
repo fails with `browser_release_proof_surface_receipt_incomplete`, so
Dawn-vs-Doe browser receipts must remain repository-relative before the public
claim gate loads or hashes them.

## 2026-07-01 — Browser claim index rejects outside comparison artifacts

The claim-index same-page comparison checks now have focused regression
coverage for unsafe comparison artifact paths. A mutated published proof surface
that points `comparisonReceipts[0].comparisonArtifact.path` at an absolute file
outside the repo fails with
`browser_release_proof_surface_comparison_artifact_incomplete`, so Dawn-vs-Doe
comparison evidence cannot be backed by an out-of-tree smoke report.

## 2026-07-01 — Browser claim index rejects outside galleries

The claim-index proof-gallery checks now have focused regression coverage for
unsafe gallery page artifact paths. A mutated published proof surface that
points `galleryPages[0].artifact.path` at an absolute file outside the repo
fails with `browser_release_proof_surface_public_gallery_receipt_incomplete`,
so hosted gallery receipt evidence cannot be backed by an out-of-tree local
page artifact.

## 2026-07-01 — Browser claim index rejects outside proof pages

The claim-index browser release proof-surface checks now have focused
regression coverage for unsafe `about:doe` proof-page artifact paths. A mutated
published proof surface that points `proofPage.artifact.path` at an absolute
file outside the repo fails with
`browser_release_proof_surface_proof_page_receipt_incomplete`, keeping public
proof-page content tied to repository-relative evidence.

## 2026-07-01 — Browser readiness rejects outside support artifacts

The browser release readiness surface now has focused regression coverage for
release-support artifact path safety. A mutated release bundle can no longer
point a support policy at an absolute file outside the repo, even when the
outside file's SHA-256 is supplied; readiness reports
`release_support_artifact_path_unsafe` before trusting that artifact.

## 2026-07-01 — Browser claim index refuses outside release paths

`claim_index_browser_release.py` now routes browser-release hash and byte-length
checks through field-aware repository-relative path guards. A focused claim-index
regression points `browserRelease.releaseArchivePath` at an absolute zip outside
the repo and proves the public gate reports the unsafe path without statting
that outside file as release evidence.

## 2026-07-01 — Browser readiness rejects outside release artifacts

`build_dawn_replacement_readiness_report.py` now requires release archive,
archive-manifest, and release-support artifact paths to stay
repository-relative before readiness hashes or opens those files. Focused
browser readiness regressions point release archive and manifest evidence at
absolute files outside the repo and require explicit unsafe-path failures, so a
downloadable-browser proof path cannot be satisfied by out-of-tree artifacts.

## 2026-07-01 — Tint frontier rejects unsafe receipt paths

`build_dawn_replacement_readiness_report.py` now rejects Tint compiler frontier
bundle compiler-evidence and component-receipt rows whose hash-bound paths are
absolute or escape the repository. Focused readiness regressions mutate a
compiler evidence path to `..` and a target-validation receipt path to an
absolute path, proving the Dawn/Tint rollup checks repository-relative identity
before trusting receipt hashes.

## 2026-07-01 — Tint frontier bundles hash-bind component receipts

`check_tint_compiler_frontier_bundle.py` now emits SHA-256 values for compiler
evidence reports, WGSL lowering-link receipts, target-validation receipts, and
phase-benchmark receipts. The Tint frontier schema and Dawn/Tint readiness
rollup now require those hashes and verify them against referenced file bytes
before accepting the bundle as frontier evidence. Focused builder/readiness
regressions prove missing or stale hash links fail before compiler blocker
state is trusted.

## 2026-07-01 — Readiness rejects stale frontier summary counts

`build_dawn_replacement_readiness_report.py` now rejects frontier bundle
evidence when `summary.claimBlockerCount` or `summary.failureCount` drifts from
the actual `claimBlockers` or `failures` arrays. Focused Tint readiness
regressions mutate only those summary counts, proving the Dawn/Tint rollup
cannot expose stale compiler blocker totals while keeping the underlying
claim-blocker list unchanged.

## 2026-07-01 — Browser claim index binds finalizer summaries

`claim_index_browser_release.py` now rejects claim-indexed Chromium browser
release rows whose finalizer report summary claimability drifts from the
runtime frontier bundle or whose `summary.releaseBundleIdentitySha256` drifts
from the release artifact bundle identity projection. Focused claim-index
regressions mutate only those summary fields while refreshing finalizer and
readiness hashes, proving the public claim gate does not rely only on a stale
finalizer-check receipt.

## 2026-07-01 — Browser finalizers bind release identity projection

`browser_release_candidate_finalizer` reports now carry
`summary.releaseBundleIdentitySha256`, and both the finalizer checker and Dawn
replacement readiness rollup reject summaries whose release identity projection
drifts from the emitted release artifact bundle. Focused finalizer and
readiness regressions mutate only that summary hash, proving release-candidate
promotion receipts cannot summarize a stale browser bundle identity.

## 2026-07-01 — Browser claim index mirrors release identity projection

`claim_index_browser_release.py` now rejects claim-indexed Chromium browser
release rows whose runtime frontier
`componentReceipts.releaseArtifactBundle` summary does not bind the loaded
release artifact bundle `artifactKind` and release identity projection hash.
The focused claim-index regression mutates only that runtime-frontier identity
hash and refreshes dependent release/finalizer/readiness hashes, proving public
claim rows cannot combine a clean runtime frontier with a stale release bundle
summary.

## 2026-07-01 — Browser readiness mirrors release identity projection

`build_dawn_replacement_readiness_report.py` now rejects browser runtime
frontier bundles whose `componentReceipts.releaseArtifactBundle.artifactKind`
or `releaseBundleIdentitySha256` drifts from the loaded release artifact
bundle. A focused readiness regression mutates only the runtime-frontier
release identity hash, proving the Chromium rollup sees stale release-summary
identity instead of relying only on `bundleId` and `releaseStatus`.

## 2026-07-01 — Browser release bundles bind runtime-frontier release identity

`check_browser_runtime_frontier_bundle.py` now records the release bundle
`artifactKind` and a self-stable release-bundle identity projection hash in
`componentReceipts.releaseArtifactBundle`. `check_browser_release_artifact_bundle.py`
rejects release bundles whose linked runtime frontier summarizes a different
artifact kind or release identity projection, and it now validates the release
bundle top-level `schemaVersion`/`artifactKind` before trusting component
evidence. Focused regressions cover stale runtime-frontier release identity and
release artifact-kind drift, while the checked-in browser release/frontier
samples and readiness sample were regenerated from the updated gates.

## 2026-07-01 — Proof-surface checker binds comparison mode results

`check_browser_published_proof_surface.py` now rejects published browser proof
surfaces when a same-page comparison artifact's Dawn or Doe mode result
runtime selector, driver identity, or declared adapter/device identity drifts
from the linked execution receipt. The focused checker regression mutates the
Doe smoke mode-result driver while preserving the smoke report hash chain,
proving the proof-surface checker catches stale side-by-side comparison
artifacts before release bundles and claim-index rows consume the surface.

## 2026-07-01 — Browser comparison artifacts bind receipt identities

`claim_index_browser_release_receipts.py` now rejects Chromium proof surfaces
when a same-page Dawn/Doe comparison artifact's mode result runtime selector,
driver identity, or declared adapter/device identity drifts from the linked
Dawn or Doe execution receipt. Focused claim-index and readiness regressions
mutate the Doe mode-result driver while keeping receipt command evidence
hash-bound to the comparison artifact, proving the public browser-release gate
sees smoke-artifact-to-receipt identity drift instead of accepting unrelated
side-by-side evidence.

## 2026-07-01 — Browser claim index rejects repeated archive paths

`claim_index_browser_release.py` now rejects claim-indexed Chromium browser
release rows whose release artifact bundle aliases required packaged member
paths or whose release archive manifest repeats an `archiveMembers` path.
Focused claim-index regressions mutate the release bundle and manifest while
refreshing dependent hashes, proving the public claim gate sees the repeated
archive identities instead of relying only on lower-level release checks.

## 2026-07-01 — Browser readiness rejects repeated archive paths

`build_dawn_replacement_readiness_report.py` now rejects release-candidate
readiness when the release artifact bundle aliases required packaged member
paths, the release archive manifest repeats an `archiveMembers` path, or the
release zip repeats a filename. Focused readiness regressions cover all three
cases so the browser frontier row cannot summarize ambiguous release archive
identity as consistent evidence.

## 2026-07-01 — Browser release bundles reject aliased role paths

`check_browser_release_artifact_bundle.py` now rejects release artifact bundles
whose packaged browser executable, app metadata, Doe runtime, or Dawn fallback
runtime fields reuse the same archive member path. The focused bundle
regression points the Dawn fallback runtime at the Doe runtime path and proves
the release-candidate checker reports the duplicate before the evidence can
flow into public download, launch, proof-surface, or manifest matching.

## 2026-07-01 — Browser archive manifests reject duplicate members

`browser_release_archive_manifest.py` now rejects duplicate
`archiveMembers[].archivePath` entries and duplicate filenames inside the
referenced release zip before matching manifest rows to packaged bytes. Focused
manifest regressions prove both the manifest-index duplicate and repeated zip
member cases fail even when the rest of the release archive identity is kept
consistent.

## 2026-07-01 — Browser archives reject aliased members

`package-browser-release-archive.py` now rejects duplicate required archive
member paths before writing a browser release zip or manifest, so the packaged
browser executable, app metadata, Doe runtime, and Dawn fallback runtime roles
cannot silently alias one zip member. The focused packer regression points the
Dawn fallback runtime at the Doe runtime archive path and proves packaging
fails without producing either release artifact.

## 2026-07-01 — Browser launch builders reject duplicate observations

`build_browser_release_launch_receipt.py` now refuses duplicate
`observedReceiptIds` before emitting packaged-browser launch receipts, and
`check_browser_release_artifact_bundle.py` rejects release-candidate bundles
whose launch receipt repeats an observed receipt ID. Focused builder and bundle
checker regressions append a duplicate observation and prove both layers fail
before the claim-index/readiness gates consume the receipt.

## 2026-07-01 — Browser launch observed receipts are unique

`claim_index_browser_release_proof.py` and the Dawn replacement readiness
rollup now reject duplicate `browser_release_launch_receipt.observedReceiptIds`
values, so packaged-browser launch evidence cannot repeat one observed receipt
while claiming the required proof/gallery/Dawn/Doe receipts were captured.
Focused claim-index and readiness regressions append a duplicate observed
receipt ID and prove both gates fail on the repeated launch observation.

## 2026-07-01 — Browser gallery URLs are unique

`claim_index_browser_release_proof.py` now rejects duplicate
`galleryPages[].url` values in published browser proof surfaces, so public
gallery coverage cannot reuse one hosted URL across multiple rows while
changing only local artifact identities. Focused claim-index and readiness
regressions duplicate a gallery URL and prove both gates fail on the repeated
hosted page identity.

## 2026-07-01 — Browser proof-page payload links are unique

`claim_index_browser_release_proof.py` now rejects duplicate
`proofPage.receiptPayloads` receipt IDs or artifact paths in published browser
proof surfaces, while still allowing those receipts to be referenced by
gallery and comparison rows. Focused claim-index and readiness regressions
append a duplicate proof-page receipt payload link and prove both gates fail on
the repeated proof-page payload identity.

## 2026-07-01 — Browser comparisons reject repeated evidence

`claim_index_browser_release_proof.py` now rejects duplicate
`comparisonReceipts[].comparisonArtifact.path` values and duplicate Dawn/Doe
receipt pairs across published proof-surface comparison rows. Focused
claim-index and readiness regressions clone a valid comparison under a new
`comparisonId` and prove both gates fail on the repeated comparison artifact
and receipt-pair identities.

## 2026-07-01 — Browser gallery receipt links are unique

`claim_index_browser_release_gallery.py` now rejects duplicate gallery
`receiptIds`, duplicate `receiptArtifacts[].receiptId`, and duplicate
`receiptArtifacts[].path` values, so a public gallery row cannot count one
execution receipt multiple times. Focused claim-index and readiness
regressions duplicate a gallery receipt artifact while keeping the public
gallery receipt payload aligned, proving both gates fail on the repeated
receipt identity.

## 2026-07-01 — Browser recent receipts require unique IDs

`claim_index_browser_release_proof.py` now rejects duplicate
`proofPage.recentReceiptIds` values in published browser proof surfaces, so the
`about:doe` proof page cannot pad recent execution evidence with repeated
receipt IDs. Focused claim-index and readiness regressions append a duplicate
recent receipt ID and prove both gates fail on the ambiguous proof-page
receipt list.

## 2026-07-01 — Browser comparisons require paired receipts

`claim_index_browser_release_proof.py` now rejects same-page Dawn/Doe
comparison rows that reuse the same execution receipt ID or payload path for
both runtimes. Focused claim-index and readiness regressions mutate the Doe
side of a comparison row to point at the Dawn receipt and prove both gates fail
before a self-comparison can back browser release evidence.

## 2026-07-01 — Browser galleries require unique artifacts

`claim_index_browser_release_proof.py` now rejects duplicate
`galleryPages[].artifact.path` values in published browser proof surfaces, so
public gallery coverage cannot reuse one HTML artifact for multiple gallery
rows. Focused claim-index and readiness regressions append a duplicate gallery
row and prove both gates fail on the duplicate gallery artifact identity.

## 2026-07-01 — Browser comparisons must run from gallery pages

`claim_index_browser_release_proof.py` now rejects proof-surface
`comparisonReceipts[].runner.pageArtifactPath` values that do not match a
published proof-gallery artifact. Focused claim-index and readiness regressions
move the same-page Dawn/Doe comparison runner to an off-surface page and prove
both gates fail before the browser proof surface can support a claim.

## 2026-07-01 — Browser proof surfaces require unique comparison IDs

`claim_index_browser_release_proof.py` now rejects duplicate published
proof-surface `comparisonReceipts[].comparisonId` values, so same-page
Dawn/Doe comparison evidence cannot be ambiguous even when every row is
otherwise structurally valid. Focused claim-index and readiness regressions
append a duplicate valid comparison row and prove both gates fail on the
duplicate comparison identity.

## 2026-07-01 — Browser proof surfaces reject malformed comparison rows

`claim_index_browser_release_proof.py` now validates every published
proof-surface `comparisonReceipts` row instead of accepting the surface after
finding one valid same-page Dawn/Doe comparison. Focused claim-index and
readiness regressions append an incomplete comparison row to an otherwise valid
surface and prove both gates reject the malformed surplus comparison evidence.

## 2026-07-01 — Compiler readiness validates Tint component entries

`build_dawn_replacement_readiness_report.py` now fails readable Tint compiler
frontier bundle evidence closed when entries inside `loweringLinks`,
`targetValidations`, or `phaseBenchmarks` drift from the Tint bundle schema.
Focused regressions mutate one receipt in each component array and prove the
rollup keeps schema-valid failed frontier evidence with field-specific
consistency failures.

## 2026-07-01 — Compiler readiness validates Tint report entries

`build_dawn_replacement_readiness_report.py` now fails readable Tint compiler
frontier bundle evidence closed when `compilerEvidenceReports` entries drift
from the Tint bundle schema, including malformed counters and blocker-summary
entries. Focused regressions mutate those copied compiler report fields and
prove readiness keeps schema-valid failed frontier evidence with field-specific
consistency failures.

## 2026-07-01 — Compiler readiness validates Tint frontier collections

`build_dawn_replacement_readiness_report.py` now fails readable Tint compiler
frontier bundle evidence closed when required bundle collections drift:
`requiredTargets`, `coverageByTarget`, or the `componentReceipts`
`loweringLinks`/`targetValidations`/`phaseBenchmarks` arrays. Focused
regressions mutate each collection class and prove readiness keeps schema-valid
failed frontier evidence with field-specific consistency failures.

## 2026-07-01 — Compiler readiness exposes malformed Tint reports

`build_dawn_replacement_readiness_report.py` now fails readable Tint compiler
frontier bundle evidence closed when `compilerEvidenceReports` is malformed.
A focused regression mutates that required compiler bundle collection and
proves the readiness rollup keeps schema-valid failed frontier evidence with a
field-specific consistency failure.

## 2026-07-01 — Browser readiness validates release component details

`build_dawn_replacement_readiness_report.py` now fails readable browser runtime
frontier bundle evidence closed when nested release-artifact component details
drift, including `artifactVerification` fields and `claimReports` summary
items. Focused regressions mutate those nested release component fields and
prove the rollup emits schema-valid failed evidence with field-specific
consistency failures.

## 2026-07-01 — Browser readiness validates frontier component fields

`build_dawn_replacement_readiness_report.py` now fails readable browser runtime
frontier bundle evidence closed when required fields inside the runtime
identity, claim-promotion, or release-artifact component summaries are missing
or malformed. Focused regressions mutate one field in each component summary
and prove the rollup emits schema-valid failed evidence with field-specific
consistency failures.

## 2026-07-01 — Browser readiness validates frontier components

`build_dawn_replacement_readiness_report.py` now fails readable browser runtime
frontier bundle evidence closed when a required `componentReceipts` summary is
missing or is not an object. Focused regressions mutate the runtime identity
and release-artifact component summaries and prove the rollup keeps
schema-valid failed evidence with field-specific consistency failures.

## 2026-07-01 — Browser readiness validates frontier failure entries

`build_dawn_replacement_readiness_report.py` now fails readable runtime frontier
bundle evidence closed when a `failures` entry is malformed. A focused browser
regression mutates only the runtime frontier bundle `failures` payload and
proves the readiness rollup keeps schema-valid failed evidence with a
field-specific consistency failure.

## 2026-07-01 — Browser readiness validates frontier blocker entries

`build_dawn_replacement_readiness_report.py` now fails readable runtime frontier
bundle evidence closed when an active frontier `claimBlockers` entry for the
row is missing its readiness failure shape. A focused browser regression mutates
the `chromium_release_build_evidence` blocker and proves the rollup emits
schema-valid failed bundle evidence with a field-specific consistency failure.

## 2026-07-01 — Browser readiness validates frontier summary shapes

`build_dawn_replacement_readiness_report.py` now fails readable browser runtime
frontier bundle evidence closed when `summary` carries non-scalar values or
`claimBlockerSummary` entries drift from the readiness failure-summary shape.
Focused regressions mutate those copied fields and prove the rollup stays
schema-valid while preserving a field-specific consistency failure.

## 2026-07-01 — Browser readiness exposes malformed frontier collections

`build_dawn_replacement_readiness_report.py` now fails readable browser runtime
frontier bundle evidence closed when `claimBlockerSummary`, `failures`, or
`componentReceipts` is malformed, and when the browser-required
`claimBlockerSummary` field is missing. Focused regressions mutate each
collection field and prove the readiness rollup keeps the bundle visible with a
field-specific consistency failure.

## 2026-07-01 — Browser readiness validates frontier bundle scalars

`build_dawn_replacement_readiness_report.py` now fails readable runtime frontier
bundle evidence closed when `status`, `claimabilityStatus`, or `summary` drift
from the readiness schema contract. Focused regressions mutate those fields on
the browser runtime frontier bundle and prove the rollup stays schema-valid,
keeps the malformed bundle visible, and records field-specific consistency
failures.

## 2026-07-01 — Browser readiness exposes malformed frontier blockers

`build_dawn_replacement_readiness_report.py` now keeps readable runtime frontier
bundle JSON in `frontierBundleEvidence` when `claimBlockers` is malformed,
marking that evidence failed and adding a specific consistency failure. A
focused regression mutates only the browser runtime frontier bundle
`claimBlockers` contract field and proves the malformed bundle no longer
disappears from the rollup.

## 2026-07-01 — Browser readiness exposes malformed frontier bundles

`build_dawn_replacement_readiness_report.py` now keeps readable runtime frontier
bundle JSON in `frontierBundleEvidence` even when its `artifactKind` is wrong,
marking that evidence failed and adding a specific consistency failure. A
focused regression mutates only the browser runtime frontier bundle contract
field and proves the malformed bundle no longer disappears from the rollup.

## 2026-07-01 — Browser readiness rejects malformed release bundles

`build_dawn_replacement_readiness_report.py` now distinguishes browser release
artifact bundles with the wrong `artifactKind` from genuinely missing release
bundle evidence. A focused regression mutates only that release-bundle contract
field and proves readiness keeps support artifacts out of typed evidence while
adding the specific consistency failure.

## 2026-07-01 — Browser readiness rejects malformed finalizer checks

`build_dawn_replacement_readiness_report.py` now distinguishes release-candidate
finalizer-check receipts with the wrong `artifactKind` from genuinely missing
finalizer-check evidence. A focused regression mutates only that checker
contract field and proves readiness keeps the malformed receipt out of typed
evidence while adding the specific consistency failure.

## 2026-07-01 — Browser readiness rejects malformed finalizer reports

`build_dawn_replacement_readiness_report.py` now distinguishes release-candidate
finalizer reports with the wrong `artifactKind` from genuinely missing
finalizer evidence. A focused regression mutates only that finalizer contract
field and proves readiness keeps the malformed report out of typed evidence
while adding the specific consistency failure.

## 2026-07-01 — Browser readiness rejects malformed provenance reports

`build_dawn_replacement_readiness_report.py` now distinguishes release-candidate
provenance reports with the wrong `artifactKind` from genuinely missing
provenance evidence. A focused regression mutates only that provenance contract
field and proves readiness keeps the malformed report out of typed evidence
while adding the specific consistency failure.

## 2026-07-01 — Browser readiness rejects malformed package inputs

`build_dawn_replacement_readiness_report.py` now distinguishes package-input
preflight reports with the wrong `artifactKind` from genuinely missing
package-input evidence. A focused regression mutates only that preflight
contract field and proves readiness keeps the malformed report out of typed
evidence while adding the specific consistency failure.

## 2026-07-01 — Browser readiness rejects malformed proof surfaces

`build_dawn_replacement_readiness_report.py` now distinguishes published proof
surfaces with the wrong `artifactKind` from genuinely missing proof-surface
evidence. A focused regression mutates only that proof-surface contract field
and proves readiness keeps the malformed manifest out of typed evidence while
adding the specific consistency failure.

## 2026-07-01 — Browser readiness rejects malformed Chromium checkout reports

`build_dawn_replacement_readiness_report.py` now distinguishes Chromium source
checkout reports with the wrong `artifactKind` from genuinely missing checkout
evidence. A focused regression mutates only that checkout report contract field
and proves readiness keeps the malformed report out of typed evidence while
adding the specific consistency failure.

## 2026-07-01 — Browser readiness rejects malformed launch receipts

`build_dawn_replacement_readiness_report.py` now distinguishes browser release
launch receipts with the wrong `artifactKind` from genuinely missing launch
evidence. A focused regression mutates only that launch receipt contract field
and proves readiness keeps the malformed launch receipt out of typed evidence
while adding the specific consistency failure.

## 2026-07-01 — Browser readiness rejects malformed public download receipts

`build_dawn_replacement_readiness_report.py` now distinguishes public-download
receipts with the wrong `artifactKind` from genuinely missing download
evidence. A focused regression mutates only that receipt contract field and
proves readiness keeps the malformed receipt out of typed evidence while adding
the specific consistency failure.

## 2026-07-01 — Browser readiness rejects malformed proof-surface check reports

`build_dawn_replacement_readiness_report.py` now distinguishes proof-surface
checker reports with the wrong `artifactKind` from genuinely missing checker
evidence. A focused regression mutates only that checker contract field and
proves readiness keeps the malformed report out of typed evidence while adding
the specific consistency failure.

## 2026-07-01 — Browser readiness requires launch comparison identity

`build_dawn_replacement_readiness_report.py` now rejects browser release launch
receipts that omit same-page Dawn/Doe `comparisonId` or `workloadId` identity.
A focused regression clears only those launch receipt fields, proving the
Chromium row cannot promote on comparison evidence that lacks a stable
comparison/workload key.

## 2026-07-01 — Browser readiness validates release archive manifest contracts

`build_dawn_replacement_readiness_report.py` now rejects release archive
manifests whose `schemaVersion` or `artifactKind` drift before readiness uses
their archive/member bindings. A focused regression mutates only those manifest
contract fields while re-hashing the bundle references, proving the Chromium
row fails on manifest contract drift rather than stale artifact hashes.

## 2026-07-01 — Browser readiness binds launch comparison artifacts to proof surface

`build_dawn_replacement_readiness_report.py` now rejects browser release launch
receipts whose same-page Dawn/Doe `comparisonArtifactPath` drifts from the
comparison artifact declared by the published proof surface. A focused
regression mutates only that launch receipt path, proving the Chromium row
cannot promote on a launch receipt that points at a different comparison report.

## 2026-07-01 — Browser readiness requires launch comparison artifact links

`build_dawn_replacement_readiness_report.py` now rejects browser release launch
receipts that omit the same-page Dawn/Doe `comparisonArtifactPath`. A focused
regression clears only that launch receipt field, proving readiness requires
the browser launch proof to bind the comparison report artifact before the
Chromium row can promote.

## 2026-07-01 — Browser readiness checks launch comparison page identity

`build_dawn_replacement_readiness_report.py` now rejects browser release launch
receipts whose same-page Dawn/Doe comparison `pageArtifactPath` differs from
the loaded proof-gallery artifact. A focused regression mutates only the launch
receipt comparison page path, proving readiness mirrors the lower release
bundle checker instead of depending only on proof-surface cross-checks.

## 2026-07-01 — Browser readiness checks finalizer claimability summaries

`build_dawn_replacement_readiness_report.py` now rejects passing browser
release-candidate finalizer reports whose `summary.claimabilityStatus` does
not match the runtime-frontier bundle used by the Chromium readiness row. A
focused regression emits a passing finalizer report with a stale claimability
summary, proving the rollup mirrors the lower finalizer checker before trusting
final assembly evidence.

## 2026-07-01 — Browser readiness mirrors runtime-frontier release identity

`build_dawn_replacement_readiness_report.py` now rejects browser runtime
frontier bundles whose `releaseArtifactBundle` component summary drifts from
the loaded release bundle `bundleId`, `releaseStatus`, or optional SHA-256. A
focused regression points readiness at a runtime-frontier bundle with a stale
release-component `bundleId`, proving the Chromium rollup checks both sides of
the release-bundle/frontier binding.

## 2026-07-01 — Browser readiness requires release-bundled package inputs

`build_dawn_replacement_readiness_report.py` now rejects browser release
artifact bundles that do not hash-bind the same
`browser_release_package_inputs_check` report loaded by readiness. A focused
regression points the runtime frontier at a release bundle with a stale
embedded package-input SHA, proving the rollup checks the release bundle's
`packageInputs` artifact instead of trusting only adjacent packageability
evidence.

## 2026-07-01 — Browser readiness checks package-input schema version

`build_dawn_replacement_readiness_report.py` now records the
`browser_release_package_inputs_check` schema version and rejects package-input
reports whose `schemaVersion` is not `1`, matching the lower release-bundle
checker before release-candidate archive inputs are trusted. A focused
readiness regression mutates only the package-input schema version, proving
the Chromium rollup fails on contract drift even when the preflight otherwise
still names the expected browser/runtime/compiler inputs.

## 2026-07-01 — Browser readiness binds release bundle back to runtime frontier

`build_dawn_replacement_readiness_report.py` now rejects browser release
artifact bundles whose embedded `runtimeFrontierBundle` artifact does not match
the runtime frontier bundle driving the Chromium readiness row. A focused
regression mutates only the release bundle's embedded runtime-frontier SHA and
points the runtime-frontier component at that bundle, proving the rollup checks
the reverse hash binding instead of allowing a release bundle and frontier
receipt from different candidates to be combined.

## 2026-07-01 — Browser readiness checks packaged runtime member bytes

`build_dawn_replacement_readiness_report.py` now directly opens the release
archive zip and verifies the packaged browser executable, Doe runtime, and
Dawn fallback runtime members against the release artifact bundle. The rollup
rejects missing, unsafe, directory, non-executable browser binary, or stale
member bytes before browser release evidence can become claimable. A focused
regression rewrites only the packaged Doe runtime member while updating the
outer archive SHA, proving the readiness check compares member bytes against
`doeRuntime.sha256` and not only the archive-level hash or manifest summary.

## 2026-07-01 — Browser readiness rejects invalid release zips

`build_dawn_replacement_readiness_report.py` now directly validates release
archives declared with `packageFormat=zip` before the manifest/member checks.
The readiness rollup rejects non-zip archive bytes or corrupt zip members at
`releaseArtifactBundle.releaseArchive.path`, matching the lower release-bundle
checker's archive-surface rule. A focused regression points the release bundle
at a hash-matching text file named like a zip, proving archive SHA identity
alone cannot satisfy browser release evidence.

## 2026-07-01 — Browser readiness checks non-macOS archive metadata

`build_dawn_replacement_readiness_report.py` now reads non-macOS browser
metadata JSON from the release archive zip and rejects product, platform,
executable path, Doe runtime path, or Dawn fallback runtime path drift from
the release artifact bundle. A focused readiness regression builds a Linux
style archive with stale Doe runtime metadata, proving the Dawn replacement
rollup checks packaged browser metadata bytes for later Linux/Windows release
lanes instead of only mirroring the macOS `Info.plist` path.

## 2026-07-01 — Browser readiness checks macOS archive app metadata

`build_dawn_replacement_readiness_report.py` now reads the macOS
`Info.plist` member from the release archive zip and rejects product name,
bundle identifier, version, package type, or executable-name drift from the
release artifact bundle. A focused readiness regression mutates `CFBundleName`
inside a copied browser release archive, proving the Dawn replacement rollup
checks packaged app metadata bytes instead of only trusting the release archive
manifest.

## 2026-07-01 — Browser readiness checks release product and platform

`build_dawn_replacement_readiness_report.py` now rejects release artifact
bundles whose `browserProduct` is not Doe Browser or Fawn Doe, whose product
metadata is incomplete, whose product channel drifts from diagnostic or
release-candidate status, whose platform tuple is invalid, or whose
release-candidate platform is not the initial macOS arm64 zip target. Focused
readiness regressions mutate the release bundle product ID and release-candidate
platform independently, matching the lower release-bundle checker before the
Chromium browser row can become claimable.

## 2026-07-01 — Browser readiness checks release bundle candidate status

`build_dawn_replacement_readiness_report.py` now rejects loaded browser
release artifact bundles whose `releaseStatus` is not `release_candidate`, and
rejects candidate evidence whose release bundle still carries `failureCodes`.
The readiness report now mirrors the lower release-bundle checker for the
primary Chromium release-candidate transition instead of relying only on the
runtime-frontier component summary to surface that blocker.

## 2026-07-01 — Browser readiness checks release support artifacts

`build_dawn_replacement_readiness_report.py` now summarizes the release
artifact bundle's contract, browser claim report, claim-promotion receipt, and
policy artifacts under `releaseCandidateEvidence.releaseSupportArtifacts`.
Readiness rejects missing required support kinds and stale support artifact
hashes, matching the lower release-bundle checker so a Chromium release row
cannot hide missing claim policy, capture policy, patch manifest, artifact
identity coverage, unsupported-reason taxonomy, claim report, promotion
receipt, or contract evidence behind a passing archive summary.

## 2026-07-01 — Browser readiness checks Chromium source checkout evidence

`build_dawn_replacement_readiness_report.py` now attaches the configured
`chromium_source_checkout_check` report to the Chromium browser release
candidate evidence and rejects schema-version drift, blocked checkout status,
missing source roots, missing runtime-selector enforcement, missing required
checks, or path/hash drift from the release artifact bundle. Focused readiness
regressions mutate the source-checkout report independently from the release
bundle, proving the Dawn replacement rollup cannot certify a browser release
candidate without hash-bound Chromium checkout/runtime-selector evidence.

## 2026-07-01 — Browser readiness checks public download receipt URL

`build_dawn_replacement_readiness_report.py` now rejects public-download
receipts whose own `url` is not public HTTPS, matching the lower release-bundle
checker in addition to the release bundle archive URL check. A focused
readiness regression points the receipt at localhost while leaving the release
bundle URL unchanged, proving the Dawn replacement rollup cannot certify a
non-public served-byte receipt for the downloadable browser archive.

## 2026-07-01 — Browser readiness checks release receipt schema versions

`build_dawn_replacement_readiness_report.py` now records public-download and
packaged-browser launch receipt `schemaVersion` values and rejects versions
other than `1`, matching the lower release-bundle checker while keeping the
readiness report itself schema-valid for bad candidate evidence. Focused
readiness regressions mutate each receipt version independently, proving the
Dawn replacement rollup cannot certify off-contract release receipt payloads.

## 2026-07-01 — Browser readiness requires launch receipt identity

`build_dawn_replacement_readiness_report.py` now rejects packaged-browser
launch receipts that omit `receiptId` or `observedAt`, matching the lower
release-bundle checker before browser claim promotion. A focused readiness
regression clears the launch receipt ID, proving the Dawn replacement rollup
cannot certify anonymous launch evidence for the downloadable browser archive.

## 2026-07-01 — Browser readiness validates release archive zip members

`build_dawn_replacement_readiness_report.py` now rejects release archive
manifests whose `archiveMembers` index omits required packaged members or
whose declared member metadata does not match the release archive zip. Focused
readiness regressions remove the Doe runtime from `archiveMembers` and mutate
the Doe runtime member byte length while keeping the release bundle hash-bound
to each manifest, proving the Dawn replacement rollup checks the manifest body
against the downloadable archive bytes.

## 2026-07-01 — Browser readiness binds release archive manifest archive

`build_dawn_replacement_readiness_report.py` now rejects release archive
manifests whose nested `archive` path, hash, kind, or byte length drifts from
the release artifact bundle archive. A focused readiness regression mutates the
manifest archive hash while keeping the release bundle hash-bound to that
manifest, proving the Dawn replacement rollup cannot certify a manifest that
describes a different downloadable archive.

## 2026-07-01 — Browser readiness binds release archive manifest members

`build_dawn_replacement_readiness_report.py` now rejects release archive
manifests whose required packaged executable or runtime member paths, hashes,
or executable state drift from the release artifact bundle. A focused readiness
regression mutates the manifest Doe runtime member hash while keeping the
release bundle hash-bound to that manifest, proving the Dawn replacement
rollup cannot certify an archive manifest that names different packaged bytes.

## 2026-07-01 — Browser readiness binds release archive manifest identity

`build_dawn_replacement_readiness_report.py` now rejects release archive
manifests whose `browserProduct` or `platform` identity drifts from the
release artifact bundle. A focused readiness regression mutates the archive
manifest browser product while keeping the release bundle hash-bound to that
manifest, proving the Dawn replacement rollup cannot certify a browser archive
whose manifest describes a different product identity.

## 2026-07-01 — Browser readiness verifies release archive file hashes

`build_dawn_replacement_readiness_report.py` now rejects browser release
artifact bundles whose release archive or release archive manifest SHA-256 does
not match the referenced file bytes. A focused readiness regression mutates the
release bundle's manifest SHA while keeping the runtime frontier component
hash-bound to that bundle, proving the Dawn replacement rollup cannot certify a
downloadable browser release bundle with stale archive-manifest file identity.

## 2026-07-01 — Browser readiness validates proof-page and gallery receipts

`build_dawn_replacement_readiness_report.py` now uses the shared claim-index
proof-surface receipt validator in the browser readiness consistency surface.
Alongside backend and comparison receipts, the rollup now checks proof-page
diagnostic receipts and public gallery receipts for hash identity, diagnostics,
release provenance, recent receipt IDs, hosted/gallery/proof artifact identity,
workload IDs, and visible page content matching the published proof surface. A
focused readiness regression mutates the proof-page receipt diagnostics while
updating the receipt hash, proving readiness checks receipt payload content and
not only referenced file identity.

## 2026-07-01 — Browser readiness binds comparison receipts

`build_dawn_replacement_readiness_report.py` now validates comparison receipt
payload binding for published proof surfaces. The readiness rollup rejects
Dawn/Doe receipt pairs whose workload, source shader, device, driver, output,
command evidence, command coverage, timing class, comparison artifact binding,
or comparison-policy evidence drift. A focused readiness regression mutates the
Doe execution receipt output hash while updating the proof-surface artifact
reference, proving the rollup checks same-page Dawn/Doe receipt parity instead
of only checking that receipt files exist.

## 2026-07-01 — Browser readiness validates backend receipts

`build_dawn_replacement_readiness_report.py` now validates execution receipt
references exposed by the published proof surface. The rollup rejects stale or
incomplete backend receipt payloads before browser claim promotion, including
missing receipt IDs, workload IDs, WGSL source shader text/hash, lowering
paths, backend identity, driver/device identity, output identity, command
evidence, command coverage, fallback state, or timing phases. A focused
readiness regression points the proof surface at a hash-updated Doe execution
receipt with no timing block, proving the rollup checks the receipt payload and
not only the proof-surface summary.

## 2026-07-01 — Browser readiness runs proof-surface claim validation

`build_dawn_replacement_readiness_report.py` now runs the claim-index
published proof-surface validator inside the browser readiness consistency
surface. The rollup rejects missing `about:doe` diagnostics, missing recent
receipt links, incomplete required gallery coverage, unrecognized gallery
categories, and invalid same-page Dawn/Doe comparison evidence before browser
claim promotion. A focused readiness regression removes
`proofPage.recentReceiptIds`, proving compact proof-surface summaries cannot
hide unbacked proof-page receipt state.

## 2026-07-01 — Browser readiness binds proof compiler identity

`build_dawn_replacement_readiness_report.py` now rejects published proof
surfaces whose `about:doe` diagnostics `compilerPath` does not match the
release artifact bundle `shaderCompiler.path`. A focused readiness regression
mutates only the proof-surface diagnostics compiler path, proving the Dawn
replacement rollup cannot certify a proof page that advertises a different
compiler artifact than the downloadable browser release bundle carries.

## 2026-07-01 — Browser readiness binds proof runtime identity hashes

`build_dawn_replacement_readiness_report.py` now applies the same
proof-surface runtime identity hash binding used by the claim-index browser
release gate. The readiness rollup loads the runtime identity artifact named by
the published proof surface and rejects it unless the provider or
runtime-selection artifact hashes match the release bundle browser binary, Doe
runtime, and Dawn fallback runtime hashes. A focused readiness regression
mutates the loaded runtime identity's Doe runtime hash without changing the
release bundle, proving the Dawn replacement rollup cannot certify `about:doe`
diagnostics that point at a different packaged runtime identity.

## 2026-07-01 — Browser readiness fails closed on missing release bundles

`build_dawn_replacement_readiness_report.py` now records a consistency failure
when the browser runtime frontier bundle's `releaseArtifactBundle` component
does not load as a `browser_release_artifact_bundle`. A focused readiness
regression mutates only a temporary runtime frontier bundle's release artifact
path to a missing JSON file, proving the Dawn replacement rollup cannot skip
release-bundle identity checks when the runtime frontier receipt points at
missing or wrong-kind release evidence.

## 2026-07-01 — Browser readiness rejects dirty claimable frontier bundles

`build_dawn_replacement_readiness_report.py` now rejects browser runtime
frontier bundles that claim `claimabilityStatus=claimable` while still carrying
failed status, failures, claim blockers, claim-blocker summaries, or nonzero
summary failure/blocker counts. The same readiness check also rejects claimable
frontier bundles whose runtime identity component is not active Doe, whose
promotion component is not promotable, or whose release-bundle component is not
a verified release candidate. It also requires the promotion component path to
be listed by the release artifact bundle's `promotionReceipts`. Focused
readiness regressions mutate temporary runtime frontier bundles into those
contradictory states, proving the
Dawn replacement rollup cannot summarize a dirty frontier receipt as if
claim-index promotion were the only remaining browser release step.

## 2026-07-01 — Browser readiness binds release proof identity

`build_dawn_replacement_readiness_report.py` now rejects package-input,
provenance, proof-surface, public-download, and browser-launch evidence whose
browser product, platform, archive, or packaged member identities drift from
the release artifact bundle. Focused readiness regressions mutate only
package-input product identity, provenance platform identity, proof-surface
product/archive identity, public-download platform identity, or launch product
identity, proving the Dawn replacement rollup cannot certify downloadable
browser evidence that the claim-index browser release gate would reject for
release identity drift.

## 2026-07-01 — Browser promotion requires passing frontier bundle state

`build_dawn_replacement_readiness_report.py` now emits the browser
claim-index promotion blocker only when the browser runtime frontier bundle
reports `status=pass`, `claimabilityStatus=claimable`, and clean
release-candidate consistency. Focused claim-promotion tests cover the
passing path and the failed-frontier-bundle path, preventing a failed
frontier receipt from being summarized as if claim-index promotion were the
only remaining browser release step.

## 2026-07-01 — Browser readiness binds launch fields to proof surface

`build_dawn_replacement_readiness_report.py` now reuses the claim-index
launch/proof-surface matcher and records readiness consistency failures when a
browser launch receipt's proof page, loaded gallery page, comparison row,
active backend, or observed receipt fields drift from the published proof
surface. A focused readiness regression mutates only the launch receipt gallery
artifact path to an unlisted gallery page, proving the Dawn replacement rollup
cannot certify a packaged-browser launch receipt that is hash-bound to the
right proof surface but does not match its published page evidence.

## 2026-07-01 — Browser readiness requires public release archive URLs

`build_dawn_replacement_readiness_report.py` now rejects release artifact
bundles whose `releaseArchive.downloadUrl` is not public HTTPS, even when the
public-download receipt and bundle agree on the same URL. A focused readiness
regression mutates a temporary release bundle to a localhost archive URL and
points a temporary runtime frontier bundle at it, proving the Dawn replacement
rollup cannot certify downloadable-browser evidence that the claim-index
browser release gate would reject as non-public.

## 2026-07-01 — Browser readiness requires public launch gallery evidence

`build_dawn_replacement_readiness_report.py` now rejects browser launch
receipts whose loaded proof-gallery URL is not public HTTPS or whose gallery
category is not one of the published proof-gallery categories. Focused
readiness regressions mutate only the launch receipt gallery URL or category,
proving the Dawn replacement rollup cannot certify a packaged-browser launch
receipt that the claim-index browser release gate would reject as local,
non-public, or off-contract gallery evidence.

## 2026-07-01 — Browser readiness verifies public-download receipt length

`build_dawn_replacement_readiness_report.py` now rejects browser public-download
receipts that omit `receiptId`, omit `observedAt`, report non-positive
`contentLengthBytes`, or report a content length that does not match the
release archive bytes. Focused readiness regressions mutate only the public
download receipt identity fields or content length, proving the Dawn
replacement rollup cannot certify a hosted browser archive receipt that the
claim-index browser release gate would reject as incomplete or byte-drifted.

## 2026-07-01 — Browser readiness rejects dirty package-input preflights

`build_dawn_replacement_readiness_report.py` now rejects browser package-input
preflight evidence that is not `evidenceMode=release_candidate`, and rejects
pass-status package-input reports that still carry failures, release-candidate
blockers, or `summary.packageable=false`. Focused readiness regressions cover
the checked-in diagnostic package-input sample plus a pass-labeled package
preflight with mutated blocker/failure/packageable fields, proving the Dawn
replacement rollup cannot certify package evidence that the claim-index browser
release gate would reject.

## 2026-07-01 — Browser readiness rejects pass-status provenance failures

`build_dawn_replacement_readiness_report.py` now carries provenance report
`summary` into the browser release-candidate evidence summary and rejects
provenance evidence that reports `status=pass` while still carrying failures or
a nonzero summary failure count. A focused readiness regression mutates only the
provenance status and failure fields, proving the Dawn replacement rollup
cannot certify a release-candidate provenance preflight that hides failed
component checks behind pass status.

## 2026-07-01 — Browser readiness rejects pass-status proof-surface-check failures

`build_dawn_replacement_readiness_report.py` now rejects browser proof-surface
checker evidence that reports `status=pass` while still carrying nonzero
failures. A focused readiness regression mutates only the checker failure list
on an otherwise pass-labeled proof-surface check, proving the Dawn replacement
rollup cannot certify a published proof surface whose checker hid failed public
gallery or diagnostics validation behind pass status.

## 2026-07-01 — Browser readiness rejects pass-status finalizer failures

`build_dawn_replacement_readiness_report.py` now rejects browser finalizer and
finalizer-check evidence that reports `status=pass` while still carrying
nonzero failure counts, including the finalizer summary failure count. Focused
readiness regressions mutate only the finalizer or finalizer-check failure
fields in an otherwise passing pair, proving the Dawn replacement rollup cannot
promote a release-candidate finalizer that hides failed checks behind pass
status.

## 2026-07-01 — Browser readiness binds finalizer package inputs

`build_dawn_replacement_readiness_report.py` now carries passing browser
finalizer `inputs.packageInputs` into the release-candidate evidence summary
and rejects candidate consistency when that input artifact does not match the
package-input receipt used by the browser row. Focused readiness regressions
build a passing finalizer/finalizer-check pair, then mutate only the finalizer
package-input hash to prove the Dawn replacement rollup cannot certify a
finalizer report assembled from stale package-input evidence.

## 2026-07-01 — Browser readiness binds finalizer output bundles

`build_dawn_replacement_readiness_report.py` now carries passing browser
finalizer `outputs.releaseArtifactBundle` and `outputs.runtimeFrontierBundle`
into the release-candidate evidence summary and rejects candidate consistency
when those output artifacts do not match the release bundle and runtime-frontier
bundle used by the browser row. Focused readiness regressions build a passing
finalizer/finalizer-check pair, then mutate only the output bundle hashes to
prove the Dawn replacement rollup cannot certify a finalizer report for
different downloadable-browser bytes.
The same readiness consistency surface now also requires the proof-surface
checker receipt named by release-candidate evidence to match the release
artifact bundle's `proofSurfaceCheck` artifact.

## 2026-07-01 — Release proof pages reject vague Doe subsystem statuses

`build_browser_proof_page_receipt.py` and
`check_browser_published_proof_surface.py` now reject release-candidate or
release proof-page evidence when TSIR, HostPlan, or CSL diagnostics still use
placeholder status values such as `diagnostic` or `unknown`. Diagnostic samples
can stay explicitly diagnostic, but claimable browser release evidence must show
concrete subsystem state on the proof page and in the matching diagnostic
receipt.

## 2026-07-01 — Browser package inputs validate macOS app metadata

`check_browser_release_package_inputs.py` now rejects macOS release-candidate
package inputs unless `packageRootName` matches the `.app` bundle directory and
the packaged `Info.plist` binds the browser product name, bundle identifier,
version, executable name, and `APPL` package type. The focused package-input
regressions cover both product metadata drift and package-root drift, so a
browser release-candidate preflight cannot advance with archive member paths
under the wrong bundle root or with app metadata that would fail later release
bundle verification.

## 2026-07-01 — Published proof surfaces require concrete receipt identity

`browser_execution_receipt` schema validation and published proof-surface
assembly now require concrete driver profile fields, adapter-info SHA-256,
adapter label, feature count, dispatch count, and the setup/encode/submit-wait
timing phases. The checked browser execution receipt samples now carry the same
concrete driver/device identity required by `build_browser_execution_receipt.py`,
and the proof-surface/release/readiness samples were regenerated against the
stricter receipt hashes. Focused regressions prove schema validation rejects
placeholder driver identity and the proof-surface checker rejects incomplete
device identity before those receipts can back browser release evidence.

## 2026-07-01 — Browser execution receipts reject placeholder driver/device identity

`build_browser_execution_receipt.py` now rejects browser smoke rows whose
runtime-selection profile still reports placeholder driver fields such as
`unknown`, and requires adapter identity to include a concrete adapter, device,
or name label alongside the adapter-info hash. The checked smoke comparison
sample now carries concrete sample profile/device identity with refreshed
mode-result and report hashes. Focused regressions mutate only the driver field
or remove the adapter/device labels, proving per-run browser receipts cannot
turn placeholder environment identity into claim-shaped driver/device evidence.

## 2026-07-01 — Proof-page receipts require visible diagnostics and provenance

`build_browser_proof_page_receipt.py` now reads the captured `about:doe` proof
page before emitting a diagnostic receipt and requires visible page content for
the diagnostics, release provenance, and recent receipt IDs that the receipt
claims. Focused regressions remove only the compiler path, release archive
hash, or a recent receipt ID from the captured page fixture, proving proof-page
receipt evidence cannot be produced from a diagnostics page that hides the
identity fields later consumed by the published proof surface.

## 2026-07-01 — Public gallery receipts require visible hosted evidence

`build_browser_public_gallery_receipt.py` now decodes the served gallery page
before emitting a public gallery receipt and requires visible page content for
the category, workload contract path, workload IDs, receipt IDs, and execution
receipt artifact paths that the receipt claims. Focused regressions remove only
the workload ID or receipt artifact link from the hosted page fixture, proving
public gallery evidence cannot be produced from a hosted page that hides the
workload/receipt links later used by the proof surface.

## 2026-07-01 — Public download receipts validate archive manifests before emission

`build_browser_public_download_receipt.py` now loads the release archive
manifest before emitting hosted-download evidence and requires the manifest
archive path, archive SHA-256, archive byte length, browser product, platform,
and packaged executable/app/Doe runtime/Dawn fallback runtime member paths to
match the public download receipt. Focused regressions mutate only the manifest
archive hash or packaged Doe runtime member path while refreshing the manifest
hash argument, proving hosted-download evidence cannot be produced from a
generic or stale archive manifest.

## 2026-07-01 — Browser launch receipts validate archive manifests before emission

`build_browser_release_launch_receipt.py` now loads the release archive
manifest before emitting a packaged-browser launch receipt and requires the
manifest archive path, archive SHA-256, archive byte length, browser product,
platform, and packaged executable/app/Doe runtime/Dawn fallback runtime member
paths to match the launch receipt inputs. Focused regressions mutate only the
manifest archive hash or the packaged Doe runtime member path, proving a launch
receipt cannot be produced from a generic or stale manifest that merely gets
hash-linked after the fact.

## 2026-07-01 — Browser proof-surface builder backs recent receipts across the surface

`build_browser_published_proof_surface.py` now validates proof-page
`recentReceiptIds` against every receipt linked by the assembled proof surface:
proof-page payloads, gallery receipt artifacts, and same-page Dawn/Doe
comparison receipts. The focused builder suite now reconstructs the checked-in
sample again while still rejecting an actually unlinked recent receipt ID,
proving producer-side validation matches the claim-index rule for surface-wide
recent receipt coverage.

## 2026-07-01 — Browser claim-index binds proof runtime identity hashes

`claim_index_gate.py` now loads the runtime identity artifact named by a
claim-indexed Chromium proof surface and requires its provider or
runtime-selection artifact hashes to match the release bundle browser binary,
Doe runtime, and Dawn fallback runtime hashes. The unit browser-release fixture
now publishes those runtime identity hashes, and a focused regression mutates
the loaded runtime identity's Doe runtime hash without changing the release
bundle, proving a proof surface cannot point `about:doe` diagnostics at runtime
bytes outside the packaged release evidence.

## 2026-07-01 — Browser claim-index binds launch receipt IDs to proof payloads

`claim_index_gate.py` now loads the proof-surface proof-page diagnostic receipt
and loaded gallery public receipt payloads while validating the packaged-browser
launch receipt. The launch receipt's proof-page and gallery receipt IDs must
match those payload `receiptId` values, not just appear in
`observedReceiptIds`. A focused regression rewrites the launch proof/gallery
receipt IDs and observed list while leaving the proof surface unchanged,
proving launch evidence cannot substitute arbitrary observed IDs for the
receipt payloads published by the proof surface.

## 2026-07-01 — Browser claim-index binds proof compiler path

`claim_index_gate.py` now rejects claim-indexed Chromium proof surfaces whose
`about:doe` diagnostics `compilerPath` differs from the release artifact
bundle's `shaderCompiler.path`. A focused regression keeps the diagnostics
compiler path non-empty but points it at a different compiler, proving
claim-indexed proof pages cannot report a Doe compiler path unrelated to the
shipped release compiler artifact.

## 2026-07-01 — Browser claim-index binds command evidence to comparison bytes

`claim_index_gate.py` now rejects claim-indexed Chromium same-page comparison
receipts whose Dawn or Doe execution receipt names the comparison artifact path
but does not hash-bind the comparison artifact file hash or report hash in its
command evidence. The unit browser-release fixture now adds
`commandGraph.artifactSha256` after generating the strict smoke comparison
artifact and refreshes the receipt refs. A focused regression mutates only the
Doe receipt's comparison artifact hash while leaving the graph hash and
artifact path intact, proving receipt command evidence cannot point at a report
path without binding the report bytes.

## 2026-07-01 — Browser claim-index binds comparison runtime hashes

`claim_index_gate.py` now rejects claim-indexed Chromium proof surfaces whose
same-page strict smoke `comparisonArtifact` names runtime-selection browser
binary, Dawn fallback runtime, or Doe runtime hashes that differ from the
release artifact bundle. The check covers both top-level `runtimeSelections`
and each `modeResults[*].runtimeSelection`. A focused regression mutates only
the top-level Doe runtime hash in the smoke report, recomputes the report hash,
and refreshes the proof-surface comparison artifact hash, proving the
comparison report cannot come from browser/runtime bytes outside the packaged
release evidence.

## 2026-07-01 — Browser claim-index enforces strict comparison smoke reports

`claim_index_gate.py` now reuses the browser smoke validator on same-page
`comparisonArtifact` payloads, including strict-mode, report-hash, and
mode-result hash-chain checks. The unit browser-release fixture now emits a
real strict smoke report with Dawn/Doe runtime selections, shader compiler
identity, adapter identity, smoke-pass sections, chained mode hashes, and a
report hash. A focused regression corrupts only the Doe mode-result hash while
refreshing the proof-surface artifact reference, proving claim-indexed browser
comparison evidence cannot pass with a hash-matched but internally forged smoke
report.

## 2026-07-01 — Browser claim-index binds same-page comparison artifacts

`claim_index_gate.py` now follows the proof surface's same-page
`comparisonArtifact`, verifies the referenced smoke report file hash, requires
the report to cover both Dawn and Doe modes with no hidden fallback/errors, and
checks its timing class against the declared comparison policy. The gate also
requires both Dawn and Doe execution receipt command evidence to name that same
comparison artifact path. Focused regressions mutate only the comparison
artifact bytes or the Doe receipt command-evidence path, proving a
claim-indexed Chromium proof surface cannot advertise side-by-side receipt
parity while linking those receipts to a different or stale comparison report.

## 2026-07-01 — Browser claim-index binds packaged artifact hashes

`claim_index_gate.py` now rejects claim-indexed Chromium browser rows whose
package-input report binds browser binary, Doe runtime, Dawn fallback runtime,
or shader compiler path/hash/kind values that differ from the release artifact
bundle. The gate also checks release archive manifest member hashes and the
browser executable bit against release-bundle artifacts. Focused regressions
mutate only the package-input Doe runtime hash or the manifest Doe runtime
member hash, then refresh surrounding bundle/finalizer/readiness references
where needed, proving claim-indexed browser evidence cannot swap packaged
runtime bytes behind matching member paths.

## 2026-07-01 — Browser claim-index binds archive manifest identity

`claim_index_gate.py` now rejects claim-indexed Chromium browser rows whose
release archive manifest does not bind the release artifact bundle's browser
product, platform, and packaged executable/app/runtime member paths. When the
manifest carries `sourcePackageInputs`, the gate also requires that artifact
ref to match the release bundle's package-input receipt. Focused regressions
mutate only the manifest Doe runtime member path or a present
`sourcePackageInputs` ref, proving manifest body drift is visible to the
public claim index instead of only to lower release-bundle tooling.

## 2026-07-01 — Browser claim-index binds release identity tuple

`claim_index_gate.py` now rejects claim-indexed Chromium browser rows whose
package-input, public-download, provenance, proof-surface release provenance,
or launch receipt identity drifts from the release artifact bundle's browser
product, platform, and packaged member paths. Focused regressions mutate only
package-input product version, public-download platform architecture, or
provenance expected Doe runtime member path, then refresh the surrounding
bundle/readiness/finalizer hashes needed for each mutation, proving a coherent
release bundle cannot certify a different packaged browser identity.

## 2026-07-01 — Browser claim-index binds runtime frontier identity components

`claim_index_gate.py` now rejects claim-indexed Chromium browser rows whose
claimable runtime frontier bundle does not bind
`componentReceipts.runtimeIdentity` to the proof surface's Doe runtime identity
or `componentReceipts.claimPromotionReceipt` to a promotable promotion receipt
listed in the release artifact bundle. Focused regressions mutate only each
runtime-frontier component path, then refresh the release-bundle, finalizer,
finalizer-check, and readiness hash references around it, proving claimable
runtime-frontier status cannot certify a different runtime selector or
promotion receipt.

## 2026-07-01 — Browser claim-index binds runtime frontier release component

`claim_index_gate.py` now rejects claim-indexed Chromium browser rows whose
claimable runtime frontier bundle does not bind
`componentReceipts.releaseArtifactBundle` to the exact release-candidate bundle
path and verified-file state named by `browserRelease.releaseArtifactBundlePath`.
The focused regression changes only that component path inside the runtime
frontier bundle, then refreshes the release-bundle, finalizer, finalizer-check,
and readiness hash references around it, proving claimable runtime-frontier
status cannot certify a different browser release bundle.

## 2026-07-01 — Browser claim-index binds provenance components

`claim_index_gate.py` now rejects claim-indexed Chromium browser rows whose
release-candidate provenance report does not bind `componentArtifacts` for
package inputs, public download receipt, proof surface, proof-surface check,
and browser launch receipt to the exact paths, kinds, and file hashes named by
`browserRelease`. The focused regression mutates only the provenance
proof-surface component hash, then refreshes the readiness hash reference
around that provenance report, proving clean provenance status cannot certify
nearby or stale component receipts.

## 2026-07-01 — Browser claim-index rejects dirty preflights

`claim_index_gate.py` now rejects claim-indexed Chromium browser rows whose
package-input preflight is not `evidenceMode=release_candidate`, still exposes
`releaseCandidateBlockers` or `failures`, or has `summary.packageable=false`.
It also rejects pass-labeled provenance reports with non-empty `failures` or
nonzero `summary.failureCount`. Focused regressions dirty each preflight while
refreshing the surrounding release-bundle, finalizer, finalizer-check, and
readiness hashes needed for that mutation, proving claim-indexed browser
evidence cannot hide package/provenance blockers behind pass labels.

## 2026-07-01 — Browser claim-index binds finalizer artifacts

`claim_index_gate.py` now rejects claim-indexed Chromium browser rows whose
passing finalizer report does not bind `outputs.releaseArtifactBundle`,
`outputs.runtimeFrontierBundle`, and `inputs.packageInputs` to the exact paths,
kinds, and file hashes named by `browserRelease`. Focused regressions mutate
only the finalizer output bundle hash or package-input hash, then refresh the
finalizer-check and readiness hash references around that report, proving a
passing finalizer status cannot certify a different bundle or input receipt.

## 2026-07-01 — Browser claim-index checks public download observation

`claim_index_gate.py` now rejects claim-indexed Chromium browser rows whose
loaded public download receipt is not a GET observation with non-empty
`receiptId`/`observedAt` and positive `contentLengthBytes` matching the release
archive bytes. Focused regressions mutate only the public download method or
served byte length, then refresh the release-bundle and readiness hash
references around that receipt, proving a 200 label and matching SHA-256 are
not enough for downloadable-browser evidence.

## 2026-07-01 — Browser claim-index requires public archive URLs

`claim_index_gate.py` now rejects claim-indexed Chromium browser rows whose
`browserRelease.downloadUrl` is not a public HTTPS URL, using the same
reserved/local-host policy as the published proof-gallery checks. The focused
regression regenerates a complete browser-release evidence fixture with the
archive URL consistently set to a `.test` host, proving internal receipt
agreement is not enough for claim-indexed downloadable-browser evidence.

## 2026-07-01 — Browser claim-index binds launch proof-surface identity

`claim_index_gate.py` now rejects claim-indexed Chromium browser rows whose
loaded packaged-browser launch receipt does not bind `proofSurface.path`,
`proofSurface.sha256`, and `proofSurface.kind` to the exact published proof
surface named by `browserRelease.proofSurfacePath`. The focused regression
changes only the launch receipt's checked proof-surface hash, then refreshes
the release-bundle and readiness hash references around that receipt, proving
claim-indexed browser evidence cannot launch against one proof surface while
the claim index names another.

## 2026-07-01 — Browser claim-index binds finalizer-check identity

`claim_index_gate.py` now rejects claim-indexed Chromium browser rows whose
loaded finalizer-check receipt does not bind `finalizerReportPath` and
`finalizerReportSha256` to the exact finalizer report named by
`browserRelease.finalizerReportPath`. The focused regression changes only the
finalizer-check receipt's checked finalizer hash, then refreshes the readiness
hash reference around that receipt, proving claim-indexed browser evidence
cannot accept a stale finalizer-check receipt for different finalizer bytes.

## 2026-07-01 — Browser claim-index rejects dirty pass receipts

`claim_index_gate.py` now rejects claim-indexed Chromium browser rows whose
pass-labeled proof-surface checker report, finalizer report, or
finalizer-check receipt still exposes non-empty `failures`; finalizer reports
also require `summary.failureCount=0`. Focused regressions inject failures into
each receipt while preserving the pass status fields and refreshing surrounding
release-bundle/readiness hash references, proving claim-indexed browser
evidence cannot hide proof-surface or finalizer blockers behind passing labels.

## 2026-07-01 — Browser claim-index rejects dirty runtime frontiers

`claim_index_gate.py` now rejects claim-indexed Chromium browser rows whose
loaded runtime frontier bundle is marked claimable while still exposing
`claimBlockers`, `claimBlockerSummary`, `failures`, or nonzero summary counts.
The focused regression injects a runtime-frontier failure while preserving
`status=pass` and `claimabilityStatus=claimable`, then refreshes the
release-bundle and readiness hash references, proving claim-indexed browser
evidence cannot hide runtime-frontier blockers behind claimable labels.

## 2026-07-01 — Browser claim-index binds proof-surface checker identity

`claim_index_gate.py` now rejects claim-indexed Chromium browser rows whose
loaded `browser_published_proof_surface_check` report does not bind
`surfacePath` and `surfaceSha256` to the exact proof surface named by
`browserRelease.proofSurfacePath`. The focused regression changes only the
checker report's `surfaceSha256`, then refreshes the release-bundle and
readiness hash references around that changed checker artifact, proving the
claim index cannot accept a passing checker report for stale or different proof
surface bytes.

## 2026-07-01 — Browser claim-index galleries reject unknown categories

`claim_index_gate.py` now rejects claim-indexed Chromium proof-surface gallery
rows whose `category` is not one of the public proof gallery categories:
compute, rendering, tensor, shader_edge, or benchmark_trace. The focused
regression appends a sixth `local_only` gallery row while keeping the required
five categories present, proving claim-indexed browser evidence cannot smuggle
private/local gallery surfaces into the public proof gallery.

## 2026-07-01 — Browser claim-index galleries require public URLs

`claim_index_gate.py` now uses the shared public-URL validator for claim-indexed
Chromium browser launch gallery URLs and proof-surface gallery URLs, matching
the stricter published proof-surface checker semantics. The focused regression
keeps the gallery URL HTTPS but moves it to `gallery.test`, then updates the
proof-surface gallery row, public gallery receipt, and launch receipt to match,
proving claim-indexed browser evidence cannot pass with reserved/test gallery
hosts masquerading as hosted public proof pages.

## 2026-07-01 — Browser claim-index galleries bind workload IDs to receipts

`claim_index_gate.py` now rejects proof-surface gallery rows whose
`workloadIds` do not match the unique workload IDs loaded from the linked
execution receipt payloads. The focused regression mutates the compute gallery
row, hosted gallery receipt, and visible gallery artifact to advertise
`unit-other-workload` while leaving the linked execution receipt payload at
`unit-compute`, proving claim-indexed Chromium gallery evidence cannot claim a
workload that the backend receipt did not run.

## 2026-07-01 — Browser claim-index galleries bind receipt IDs to artifacts

`claim_index_gate.py` now rejects proof-surface gallery rows whose
`receiptIds` do not exactly match the linked execution receipt artifact IDs.
The focused regression mutates the compute gallery row to advertise
`unit-compute-other`, then refreshes the hosted gallery receipt, gallery HTML,
proof page, and diagnostic receipt hashes, proving claim-indexed Chromium
gallery evidence cannot name one receipt ID while linking a different backend
receipt JSON.

## 2026-07-01 — Browser claim-index proof pages reject unbacked recent receipts

`claim_index_gate.py` now rejects proof-page `recentReceiptIds` entries that
are not backed by an exposed execution receipt artifact from proof-page payloads,
gallery rows, or same-page Dawn/Doe comparison receipts. The focused regression
adds a visible `unit-phantom-receipt` ID to `about:doe` and the diagnostic
receipt while refreshing the proof-page hashes, proving claim-indexed Chromium
proof surfaces cannot advertise recent receipts that have no inspectable
source-preserving backend receipt.

## 2026-07-01 — Browser claim-index proof pages link every recent receipt

`claim_index_gate.py` now derives recent receipt payload links from every
execution receipt artifact exposed by the proof surface, including proof-page
payloads, gallery rows, and same-page Dawn/Doe comparison receipts. The
focused regression keeps the tensor gallery receipt ID visible on `about:doe`
while removing only its receipt JSON path and refreshing the proof-page hashes,
proving a claim-indexed Chromium proof page cannot name a recent receipt
without linking the inspectable source-preserving backend receipt. The
published proof-surface checker now enforces the same link contract.

## 2026-07-01 — Browser claim-index proof pages cover gallery receipts

`claim_index_gate.py` now requires proof-page `recentReceiptIds` to include
the execution receipt IDs exposed by gallery rows, in addition to proof-page
payload links and Dawn/Doe comparison receipts. The focused regression removes
only the tensor gallery receipt ID from `about:doe` recent receipts, proving a
claim-indexed Chromium proof surface cannot publish hash-checked gallery
execution receipts that are absent from the browser diagnostics page. The
checked-in proof-page sample, proof-surface sample, launch receipt, provenance,
release bundle, readiness report, and exact-hash tests were updated to the new
receipt coverage chain.

## 2026-07-01 — Browser claim-index comparison policies bind loaded receipts

`claim_index_gate.py` now derives same-page `comparisonPolicy` declarations
from the loaded Dawn/Doe execution receipt payloads, covering workload, source
shader, driver/device, timing scope, command coverage, output identity kind,
and no-hidden-fallback state. The focused regression flips only
`comparisonPolicy.outputIdentity` from `same_output_hash` to
`same_frame_hash`, leaving both receipts unchanged, proving claim-indexed
Chromium rows cannot advertise frame-hash comparison policy when the loaded
receipts prove output-hash identity.

## 2026-07-01 — Browser claim-index execution receipts bind source hash aliases

`claim_index_gate.py` now rejects loaded browser execution receipts when an
optional `sourceShader.sourceSha256` alias is malformed or disagrees with the
inline `sourceShader.source` bytes. The focused regression poisons only the
alias on a tensor execution receipt while refreshing the proof-surface receipt
hash reference, proving claim-indexed Chromium rows cannot publish competing
WGSL source identities inside the same receipt.

## 2026-07-01 — Browser claim-index comparison receipts bind shader entry point

`claim_index_gate.py` now compares browser execution receipt source identity
as language, entry point, and source hash/text for paired Dawn/Doe same-page
comparisons. The focused regression mutates only the Doe receipt entry point
while refreshing the proof-surface receipt hashes, proving claim-indexed
Chromium rows cannot promote a same-source comparison that executed a different
shader entry point.

## 2026-07-01 — Browser claim-index execution receipts require WGSL source metadata

`claim_index_gate.py` now rejects loaded browser execution receipts unless
`sourceShader.language` is `wgsl` and `sourceShader.entryPoint` is present,
in addition to the existing inline source/hash check. The focused regression
mutates a gallery execution receipt's source language while refreshing the
proof-surface receipt hash reference, proving claim-indexed Chromium rows
cannot promote receipts that preserve bytes but hide the WebGPU shader source
contract.

## 2026-07-01 — Browser claim-index comparison receipts bind output identity kind

`claim_index_gate.py` now compares both the output digest and whether that
digest is reported as `outputHash` or `frameHash` for paired Dawn/Doe browser
execution receipts. The focused regression changes the Doe receipt from
`outputHash` to `frameHash` while keeping the same digest and refreshing the
proof-surface receipt hashes, proving same-page comparisons cannot mix compute
output and render-frame identity classes.

## 2026-07-01 — Browser claim-index execution receipts bind lowering to runtime

`claim_index_gate.py` now rejects loaded browser execution receipts whose
`loweringPath` does not match `selectedRuntime`: Dawn receipts must use the
WGSL/Tint/Dawn route, while Doe receipts must use a WGSL/Doe/WebGPU route and
must not carry Tint/Dawn-native markers. The focused regression mutates the Doe
receipt to use the Dawn lowering route while refreshing the proof-surface
receipt hashes, proving a claim-indexed Chromium row cannot promote a
Doe-selected receipt that lowered through the incumbent route.

## 2026-07-01 — Browser claim-index comparison receipts bind command evidence

`claim_index_gate.py` now compares the hash identity of loaded command evidence
from paired Dawn/Doe browser execution receipts before accepting a same-page
comparison. The focused regression mutates the Doe receipt's command graph hash
while refreshing the proof-surface receipt hashes, proving a claim-indexed
Chromium row cannot promote paired receipts that ran against different command
evidence.

## 2026-07-01 — Browser claim-index execution receipts bind backend to runtime

`claim_index_gate.py` now rejects loaded browser execution receipts whose
backend identity does not match `selectedRuntime` (`webgpu-dawn` for Dawn and
`webgpu-doe` for Doe). The focused regression mutates the Doe execution
receipt backend while refreshing the proof-surface receipt hashes, proving a
claim-indexed Chromium row cannot promote a Doe-selected receipt with an
unrelated backend label.

## 2026-07-01 — Browser claim-index execution receipts require numeric timing phases

`claim_index_gate.py` now rejects loaded browser execution receipts unless the
timing block includes `timingClass` plus non-negative integer nanosecond
`setupNs`, `encodeNs`, and `submitWaitNs` phases. The focused regression
replaces a gallery execution receipt's `submitWaitNs` with a non-numeric value
while refreshing the proof-surface receipt hash reference, proving claim-indexed
Chromium rows cannot promote with placeholder timing evidence.

## 2026-07-01 — Browser claim-index receipt references must be unambiguous

`claim_index_gate.py` now rejects claim-indexed Chromium proof surfaces that
repeat an execution receipt path/runtime reference with conflicting receipt ID,
hash, or kind, and also rejects one receipt ID pointing at multiple artifact
paths. The focused regression appends a duplicate proof-page execution receipt
reference with the same path but a different receipt ID, proving conflicting
references cannot be skipped by path/runtime de-duplication.

## 2026-07-01 — Browser claim-index comparison receipts bind workload identity

`claim_index_gate.py` now compares loaded Dawn/Doe browser execution receipt
payloads against each other and against the proof-surface comparison row's
`workloadId`. The focused regression mutates the Doe comparison receipt
workload while refreshing the proof-surface artifact hashes, proving a
same-page comparison cannot promote with receipt payloads from a different
workload.

## 2026-07-01 — Browser claim-index execution receipts require command evidence

`claim_index_gate.py` now rejects loaded browser execution receipts unless they
declare `schemaVersion=1`, a non-empty `workloadId`, and at least one
hash-identified command evidence block through `commandGraph` or
`flightRecorderRef`. The focused regression removes both command evidence
anchors from a gallery execution receipt while refreshing the proof-surface
receipt hash reference, proving claim-indexed Chromium rows cannot promote
without a run-provenance anchor.

## 2026-07-01 — Browser claim-index execution receipts require output SHA identity

`claim_index_gate.py` now rejects loaded browser execution receipts unless they
carry exactly one lowercase SHA-256 output identity, either `outputHash` or
`frameHash`. The focused regression mutates a gallery execution receipt to
replace its output hash with a non-SHA value while refreshing the proof-surface
receipt hash reference, proving claim-indexed Chromium rows cannot promote with
a weak output identity hidden behind valid artifact hashes.
The output-identity and no-hidden-fallback payload checks now live in
`bench/gates/claim_index_browser_release_receipt_state.py`, keeping the
execution/proof-page receipt shard below its current local cap for the next
claim-index invariant.

## 2026-07-01 — Browser claim-index execution receipts reject fallback drift

`claim_index_gate.py` now checks every loaded browser execution receipt payload
for explicit no-hidden-fallback state: `runtimeSelectorState.selectedRuntime`
must match the top-level runtime, selector and fallback `fallbackApplied` flags
must be false, hidden fallback must be disabled, and fallback reason codes must
be empty strings. The focused regression mutates a gallery execution receipt to
apply selector fallback and allow hidden fallback while refreshing the
proof-surface receipt hash reference, proving claim-indexed Chromium rows
cannot promote with fallback drift hidden behind valid receipt hashes.

## 2026-07-01 — Browser claim-index execution receipts require complete command coverage

`claim_index_gate.py` now checks every loaded browser execution receipt payload
for complete command coverage: positive `commandCount`, non-negative
`successCount`, `successCount == commandCount`, and non-negative bounded
`dispatchCount` when present. The focused regression mutates a gallery
execution receipt to partial success and refreshes the proof-surface hash
reference, proving claim-indexed Chromium rows cannot promote with incomplete
work evidence hidden behind valid receipt hashes.

## 2026-07-01 — Browser claim-index comparison receipts require driver parity

`claim_index_gate.py` now compares the loaded Dawn/Doe browser execution
receipt payloads for driver identity as well as device identity before accepting
a claim-indexed Chromium same-page comparison. The focused regression mutates
the Doe receipt driver and refreshes the proof-surface artifact hashes, proving
the mismatch is rejected as comparison payload drift rather than as a stale
file reference.

## 2026-07-01 — Browser claim-index proof pages must show release provenance

`claim_index_gate.py` now reads the hash-verified `about:doe` proof-page
artifact for claim-indexed Chromium proof surfaces and requires the page text
to show release provenance fragments from the proof surface: browser product,
platform tuple, packaged member paths, release archive, archive manifest, and
public download receipt fields. The complete browser-release fixture now uses
the full release-provenance shape, and focused coverage updates the proof-page
artifact plus diagnostic-receipt hashes before proving that hidden provenance
still blocks promotion.

## 2026-07-01 — Browser claim-index comparison pages must show receipts

`claim_index_gate.py` now reads the same-page comparison runner gallery
artifact for claim-indexed Chromium proof surfaces and requires that page to
show the comparison ID, workload ID, runner page/scope/modes, side-by-side
receipt marker, comparison artifact path, and both Dawn/Doe receipt IDs and
payload links. The focused regression keeps gallery artifact and public receipt
hashes fresh while hiding the comparison fragments, proving that JSON-only
same-page comparison evidence cannot promote.

## 2026-07-01 — Browser claim-index galleries must show receipts

`claim_index_gate.py` now reads each hash-verified public gallery HTML artifact
for claim-indexed Chromium proof surfaces and requires the page content to show
the gallery category, workload contract, workload IDs, receipt IDs, and receipt
artifact links exposed by the proof surface. The public gallery receipt checks
now live in `bench/gates/claim_index_browser_release_gallery.py`, while the
aggregate proof-surface receipt entrypoint remains unchanged. Focused coverage
updates the gallery artifact, proof-surface reference, and public receipt hashes
before proving that hidden receipt links still block promotion.

## 2026-07-01 — Browser claim-index proof pages must show diagnostics

`claim_index_gate.py` now reads the hash-verified proof-page artifact for
claim-indexed Chromium proof surfaces and requires the page content to show the
active Doe diagnostics, compiler path, TSIR/HostPlan/CSL status,
hidden-fallback-disabled state, recent receipt IDs, and receipt payload links
exposed by the proof surface. The focused claim-index receipt coverage now
updates all proof-page and diagnostic-receipt hashes before proving that missing
visible diagnostic content still blocks promotion.

## 2026-07-01 — Browser claim-index proof surfaces load proof-page receipts

`claim_index_gate.py` now follows the claim-indexed Chromium proof surface's
proof-page `diagnosticReceipt` reference, verifies the receipt file hash, loads
the `browser_proof_page_receipt` payload, and requires it to bind the proof-page
artifact hash and byte length, `about:doe` URL, runtime identity path,
diagnostics, release provenance, and recent receipt IDs exposed by the proof
surface. The complete browser-release fixture now writes real proof-page HTML
and a proof-page diagnostic receipt, and focused coverage rejects proof-page
receipt payload drift.

## 2026-07-01 — Browser claim-index proof surfaces load public gallery receipts

`claim_index_gate.py` now follows each claim-indexed Chromium proof-surface
gallery `publicReceipt` reference, verifies the receipt file hash, loads the
`browser_public_gallery_receipt` payload, and requires it to bind the hosted URL,
HTTP 200 status, gallery artifact hash and byte length, workload contract,
workload IDs, receipt IDs, and receipt artifact paths exposed by the proof
surface. The complete browser-release fixture now writes real gallery HTML and
public gallery receipt files instead of placeholder hashes, and focused coverage
rejects public gallery receipt payload drift.

The browser proof-surface receipt checks now live in
`bench/gates/claim_index_browser_release_receipts.py`; launch/proof-surface
shape checks remain in `bench/gates/claim_index_browser_release_proof.py`.

## 2026-07-01 — Browser claim-index proof surfaces load execution receipts

`claim_index_gate.py` now rejects claim-indexed Chromium proof surfaces whose
`about:doe` diagnostics omit the compiler path or TSIR/HostPlan/CSL status, and
it requires proof-page `recentReceiptIds` to cover the execution receipts
exposed by the proof page and same-page comparison rows. Focused coverage now
rejects missing proof-page diagnostics and stale recent-receipt coverage.

`claim_index_gate.py` now cross-checks claim-indexed Chromium browser launch
receipts against the loaded published proof surface. The launch receipt's proof
page URL/artifact, loaded gallery URL/category/artifact, same-page comparison
row, Dawn/Doe receipt IDs, and active backend must match the proof surface, and
focused coverage rejects a launch receipt that names a gallery page outside the
published proof surface.

`claim_index_gate.py` now follows execution receipt artifact references from
the claim-indexed Chromium proof surface, verifies the referenced file hashes,
and checks the loaded `browser_execution_receipt` payloads for receipt IDs,
source shader text/hash, lowering path, backend, driver/device identity, output
or frame hash, and timing fields. The complete browser-release fixture now
emits real execution receipt JSON for its proof-page, gallery, and same-page
comparison references, and the focused tests reject a stale/incomplete Doe
execution receipt. The gate also compares loaded Dawn/Doe comparison receipt
payloads for source, device, output/frame, command coverage, and timing-class
identity, with focused coverage for mismatched output hashes.

## 2026-07-01 — Browser claim-index rows bind release-bundle components

`claim_index_gate.py` now re-hashes loaded Chromium `browserRelease` component
receipts and compares them against the release artifact bundle's component
summaries for the runtime frontier bundle, release archive manifest, package
inputs, public download receipt, proof surface, proof-surface check, and launch
receipt. Future claim-indexed Chromium browser rows also fail when any required
release-bundle component summary is absent, so a public row cannot point at
receipt files that differ from the aggregate release bundle. Focused
claim-index tests now cover component hash drift and missing claim-indexed
bundle components.

## 2026-07-01 — Browser claim-index promotion requires full proof surface

`claim_index_gate.py` now directly validates the loaded
`browser_published_proof_surface` artifact for future claim-indexed Chromium
browser rows. Promotion requires `about:doe` Doe diagnostics,
hidden-fallback-disabled state, hosted gallery pages for compute, rendering,
tensor, shader-edge, and benchmark-trace categories, and a same-page Dawn/Doe
comparison receipt with source, device, command-coverage, and fallback parity.
The focused claim-index tests now include regressions for missing gallery
coverage and weakened proof-surface comparison parity.

The Chromium `browserRelease` validation helpers have been split out of
`bench/gates/claim_index_gate.py`: generic claim/report validation remains in
the main gate, archive/readiness/release evidence checks live in
`bench/gates/claim_index_browser_release.py`, and launch/proof-surface checks
live in `bench/gates/claim_index_browser_release_proof.py`.

## 2026-07-01 — Browser claim-index promotion requires launch proof surfaces

`claim_index_gate.py` now treats packaged-browser launch proof as part of the
Chromium claim-index promotion boundary. Future claim-indexed Chromium browser
rows must load a launch receipt proving a release-archive Doe WebGPU launch,
active `webgpu-doe` backend, loaded `about:doe` proof page, loaded HTTPS
gallery page, same-page Dawn/Doe comparison mode, side-by-side Dawn/Doe receipt
emission, and observed proof/gallery/Dawn/Doe receipt IDs. The focused
claim-index tests now include a complete claim-indexed browser-release fixture
and regressions for proof-page drift plus missing side-by-side/observed receipt
evidence.

## 2026-07-01 — Browser claim-index rows bind release archive identity

`browserRelease` claim-index evidence now carries first-class release archive
path/SHA-256, release archive manifest path/SHA-256, and public download URL
fields for Chromium browser rows. `claim_index_gate.py` hashes the local archive
and manifest when present, compares those fields against the readiness row's
public download receipt evidence, and rejects rows when the release bundle,
provenance report, public download receipt, published proof surface, or launch
receipt names a different archive or manifest identity. The checked-in
`browser-chromium-release` scaffold now points at the sample macOS arm64 zip and
manifest bytes, and the regenerated readiness sample preserves the same
`browserRelease` object in the browser row's compact claim-index entry.

## 2026-07-01 — Browser claim-index release evidence binds to readiness rows

`claim_index_gate.py` now checks a Chromium browser claim-index entry's
`browserRelease` paths and readiness-exposed receipt hashes against the
Chromium browser row in the named Dawn replacement readiness report. The gate
compares the runtime frontier bundle, release artifact bundle, package-input
preflight, provenance report, public download receipt, proof surface,
proof-surface check, launch receipt, finalizer, and finalizer-check paths
against the readiness row's `frontierBundleEvidence`, verifies loaded
release-candidate receipt file hashes where the readiness row carries `sha256`,
and now includes hashes for the runtime frontier bundle and release artifact
bundle summaries as well as the release-candidate receipt summaries. It also
requires the readiness row to include the matching claim-index entry with the
same `browserRelease` object. Future claim-indexed Chromium browser rows now
also fail if their typed browser release artifacts are missing from optional
`bench/out` locations, instead of silently skipping those release checks.

## 2026-07-01 — Claim index gets a typed Chromium browser release lane

`reports/claim-index.json` now has a scaffolded `browser-chromium-release`
entry for the downloadable Chromium-family browser surface, with typed
`browserRelease` evidence paths for the runtime frontier bundle, release
artifact bundle, package-input preflight, release-candidate provenance, public
download receipt, proof surface, proof-surface check, launch receipt, finalizer,
finalizer check, and Dawn replacement readiness report. The claim-index schema
now accepts `surface=browser-chromium` only with `runtimeHost=browser` and that
typed release-evidence object. `claim_index_gate.py` validates those artifact
kinds when the files are present; for any future claim-indexed Chromium browser
row it also requires loaded release evidence to be passing, release-candidate
grade, file-verified where relevant, launched through Doe WebGPU with hidden
fallback disabled, and backed by a claimable browser readiness row. The tracked
entry remains scaffolded because the checked-in browser release evidence is
still diagnostic.

## 2026-07-01 — Browser readiness names the claim-index promotion gate

The Dawn replacement readiness report now fails closed when a Chromium browser
release-candidate evidence chain is internally claimable but the frontier row
has not yet been promoted for public replacement language. In that state the
browser row reports `browser_claim_index_promotion` instead of showing a
blocked readiness row with no blockers, making the next gate explicit:
promotion through the frontier manifest and public claim index after the
release-candidate runtime frontier, package-input, provenance, launch,
proof-surface, finalizer, finalizer-check, and hosted-download evidence are
all claimable and hash-bound. The checked-in diagnostic sample still blocks on
`chromium_release_build_evidence`, while the scratch browser release-candidate
rehearsal now reaches the promotion blocker with clean candidate consistency.

## 2026-07-01 — Browser release-candidate staging preserves proof-surface paths

`stage_browser_release_candidate_provenance.py` now canonicalizes same-page
comparison `pageArtifactPath` values with the same proof-surface artifact-path
rule used by `build_browser_published_proof_surface.py`: repo-root artifacts
remain repository-relative in the emitted proof surface, while artifacts staged
outside the repo stay absolute. This fixes the repo-root release rehearsal case
where gallery page artifacts were emitted as repository-relative paths but
comparison runners were staged as absolute paths, causing the proof-surface
builder to reject an otherwise matching Dawn-vs-Doe same-page comparison.
Focused coverage now asserts the repo-root path shape directly, and the
scratch browser release-candidate rehearsal under
`bench/out/scratch/browser-release-candidate-rehearsal/` now stages provenance,
finalizes the release artifact bundle, passes the finalizer check with
`--require-pass`, and produces a readiness report whose browser
release-candidate consistency surface is clean. The canonical checked-in sample
remains diagnostic until its own release-candidate artifacts are rebuilt and
published.

## 2026-07-01 — Browser readiness rollup fails closed on candidate receipts

The Dawn replacement readiness report now treats the Chromium release-candidate
receipt chain as a consistency surface, not just summary metadata. When browser
release-candidate evidence is present, the rollup emits explicit consistency
failures for a non-passing provenance report, non-passing finalizer report,
non-passing finalizer-check receipt, package inputs that are not
release-candidate eligible, or a provenance report that does not bind the same
package-input preflight named by the release-candidate evidence. The blocking
runner now also refuses the browser release-candidate provenance gate unless
`--browser-release-candidate-provenance-package-inputs` names that package-input
preflight, so the release lane cannot fall back to hand-entered product/member
paths. The provenance checker now also rejects package-input-backed provenance
unless the release archive manifest binds the same preflight as
`sourcePackageInputs`, pulling the archive-source binding forward before final
bundle assembly. Passing finalizer reports now require `inputs.packageInputs`
in the schema, and the finalizer checker rejects pass reports that omit that
binding before verifying it against the emitted release bundle. Finalizer-check
receipts now bind the checked finalizer report path/hash, and the readiness
rollup rejects a stale finalizer-check receipt paired with a different finalizer
report. Readiness also requires the finalizer-check receipt to show file
verification and `--require-pass`, so a diagnostic check run cannot satisfy
release-candidate evidence. The rollup now also loads the public download
receipt directly and compares its hosted URL/status, served archive hash,
archive path, and archive-manifest binding against the provenance report and
release artifact bundle, so hosted-download proof is visible as first-class
candidate evidence. The rollup also loads the packaged-browser launch receipt
and checks it against the provenance report, release artifact bundle, release
archive, release archive manifest, proof surface, packaged member paths,
`about:doe` proof-page load, hosted gallery load, same-page Dawn/Doe comparison
load, observed receipt IDs, and active Doe WebGPU runtime state. Configured
candidate receipt paths now also fail closed when the artifact is missing or
does not load as the expected `artifactKind`, so a custom rollup cannot silently
drop release-candidate evidence. Package-input evidence in the readiness rollup
now also requires the release archive manifest to bind the same report as
`sourcePackageInputs`, matching the release-bundle checker's source-package
contract before final assembly. The current sample therefore shows the browser
blocker as
both the broad
`chromium_release_build_evidence` frontier blocker and the concrete receipt
chain that must be rebuilt: release-candidate package inputs, provenance,
launch, finalizer, and finalizer-check evidence all have to pass together
before the Chromium row can support a downloadable-browser replacement claim.

## 2026-07-01 — Browser release package inputs gain a preflight receipt

`check_browser_release_package_inputs.py` now emits a schema-backed
`browser_release_package_inputs_check` report before archive creation. The
report verifies the package directory, packaged browser executable, Doe runtime,
Dawn fallback runtime, shader compiler, archive member paths, product/platform
identity, generated Linux browser metadata, and any package-member replacement
state. The checked-in sample binds the current Linux `fawn_release` output and
passes packageability while remaining diagnostic: release-candidate eligibility
is still blocked on the initial macOS arm64 zip lane and release-candidate
product channel. `schema_gate.py`, browser artifact identity coverage,
Chromium release evidence paths, `run_blocking_gates.py`, the bench README, and
the Chromium release runbook now include this preflight so browser release work
can prove package inputs before claiming a downloadable public browser.
The Dawn replacement frontier manifest and readiness report now also bind this
package-input receipt under the Chromium release-build blocker. The readiness
rollup records the packageable Linux diagnostic inputs, their release-candidate
blockers, and the current archive-member drift against the macOS release-bundle
sample, so the next browser release rebuild target is visible at the top-level
frontier report. `build_browser_release_artifact_bundle.py --package-inputs`
now consumes the passing package-input report to derive the bundle's
product/platform identity, packaged member paths, browser binary, Doe runtime,
Dawn fallback runtime, and shader compiler, keeping the packageability preflight
and release-bundle assembly on the same artifact identity, hash-binding that
preflight as `packageInputs`; release-candidate bundles now require that
binding, duplicate explicit bundle paths must match that preflight, and verified
bundles require the archive manifest's `sourcePackageInputs` to match the same
report. The deterministic
release archive packer now accepts the same package-input report to derive the
package directory, runtime inputs, product/platform identity, and packaged member
paths before writing the zip and archive manifest, and package-input-driven
manifests hash-bind that source preflight as `sourcePackageInputs`. The
release-candidate finalizer now accepts the same package-input report, requires
it to be release-candidate eligible, derives the final bundle paths from it, and
rejects duplicate explicit paths that drift from the preflight receipt. Passing
finalizer reports now bind the package-input report under `inputs.packageInputs`,
and the finalizer checker verifies that receipt against the emitted release
bundle. The release-candidate provenance checker and post-download provenance
stager now also use that package-input receipt to derive product/platform and
packaged member paths and bind it under `componentArtifacts.packageInputs` in
the provenance report; the staging helper requires that receipt and rejects
proof-page compiler-path drift from its shader-compiler input.

## 2026-07-01 — Published browser proof surfaces enter replacement readiness

The published proof-surface checker now writes a schema-backed
`browser_published_proof_surface_check` report to `--out`, binding the checked
proof-surface path/hash, file-verification flag, public-gallery URL enforcement
flag, status, and failures. Schema targets and browser artifact identity
coverage now include the checker report sample. The Dawn replacement readiness
report now loads the browser release-candidate provenance report, published
proof-surface manifest, and proof-surface checker report for the Chromium
browser row. The row's
`frontierBundleEvidence.releaseCandidateEvidence` now includes hash-bound
summaries for the provenance report, proof surface, proof-surface check,
finalizer report, and finalizer-check receipt. The proof-surface summary records
the `about:doe` diagnostics URL, active Doe backend, browser product/platform
tuple, release archive URL/hash, required gallery category set, linked receipt
payload scope, and same-page comparison receipt scope. Readiness also checks
that the proof-surface path/hash matches the provenance report component
artifact, release artifact bundle `proofSurface` artifact, and proof-surface
checker receipt, and it rejects checker receipts that did not verify files or
require public gallery URLs. The current sample remains blocked because the
release-candidate provenance report still names diagnostic product/provenance
drift, but the top-level Dawn replacement rollup now exposes the exact browser
artifact that must be rebuilt and published. The frontier manifest now names the
provenance report, proof surface, and proof-surface check alongside the runtime
frontier and finalizer receipts for Chromium release-build evidence.
`run_blocking_gates.py` also exposes the published proof-surface checker through
`--with-browser-published-proof-surface-gate`, including file verification,
public-gallery URL enforcement, and checker-report output passthroughs for
release lanes. The release artifact bundle schema, builder, checker, and
release-candidate finalizer now also hash-bind that checker report through
`proofSurfaceCheck`, and release-candidate verification requires it to pass with
file verification and public URL enforcement enabled.
The release-candidate provenance preflight now also includes
`proofSurfaceCheck` in `componentArtifacts`, rejects stale or failing checker
reports before finalizer assembly, and the staging helper writes that checker
report beside the rebuilt proof surface.

## 2026-07-01 — Candidate finalizer reports gain an independent checker

`check_browser_release_candidate_finalizer.py` now validates
`browser_release_candidate_finalizer` reports after assembly and emits the
schema-backed `browser_release_candidate_finalizer_check` report. Failed
finalizer reports remain acceptable diagnostic evidence by default, while claim
lanes can require `status=pass` with `--require-pass`. Passing reports must be
checked with `--verify-files-root`; the checker verifies both emitted output
hashes, re-runs the release-candidate release bundle checker on the emitted
bundle, confirms the finalizer runtime frontier output matches the bundle's
embedded `runtimeFrontierBundle`, compares the finalizer summary with the
generated runtime frontier output, rejects malformed failure entries on failed
reports, and rejects failure-only fields on passing reports.
`run_blocking_gates.py` exposes this through
`--with-browser-release-candidate-finalizer-gate` and
`--browser-release-candidate-finalizer-require-pass`, and can forward a durable
checker report path through `--browser-release-candidate-finalizer-check-out`.
The Chromium release recipe now includes the finalizer check immediately after
final bundle assembly, and `schema_gate.py` covers the checker report sample. Browser
artifact identity coverage now also anchors the finalizer-check report status
and checked finalizer status, and the release artifact bundle sample carries
the refreshed identity-coverage policy hash. The checker-report schema now
also encodes the pass/fail invariant: pass reports carry no failures, while
fail reports carry at least one failure.
The Dawn replacement readiness report now carries those browser
release-candidate finalizer and finalizer-check summaries under the Chromium
browser row's `frontierBundleEvidence.releaseCandidateEvidence`, so the
top-level replacement rollup exposes the candidate-promotion gate state beside
the browser runtime frontier blocker. The rollup also records whether the
finalizer-check receipt's `finalizerStatus` matches the finalizer report status,
and the Dawn replacement frontier manifest now points the Chromium release-build
blocker and browser row at the finalizer and finalizer-check samples.

## 2026-07-01 — Candidate finalizer binds staged provenance into release bundles

`finalize_browser_release_candidate_bundle.py` now makes the release-candidate
bundle assembly depend on a passing
`browser_release_candidate_provenance_report` and emits a schema-backed
`browser_release_candidate_finalizer` report at `--report-out`. The finalizer
checks that the report status, product, platform, component paths, component
hashes, and download URL still match the archive, archive manifest, public
download receipt, proof surface, and browser launch receipt supplied to final
assembly. Only after that preflight passes does it delegate to the
runtime-frontier bootstrap path, write the generated frontier receipt,
hash-bind it into the final release artifact bundle, and run release-candidate
verification. The finalizer report now hash-binds both emitted outputs: the
release artifact bundle and generated runtime frontier bundle. Focused coverage
proves a synthetic candidate can produce a verified bundle and durable
finalizer report, and that a failed provenance report stops before final bundle
outputs are written. Browser artifact identity coverage now anchors the
finalizer report status, phase, and failure list. The Chromium release recipe
now treats this finalizer as the candidate-promotion entrypoint, with
`build_browser_release_artifact_bundle.py` remaining the lower-level assembler.

## 2026-07-01 — Candidate provenance staging rebuilds local proof artifacts

`stage_browser_release_candidate_provenance.py` now consumes a candidate
archive, archive manifest, already-produced public download receipt,
proof-page capture, and proof-surface template, then emits the candidate
proof-page receipt, rebuilt proof surface, proof-surface checker report,
browser launch receipt, and candidate provenance preflight report. The stage
reuses the existing proof-page, proof-surface, launch-receipt, and provenance
validators, resolving template artifact inputs under `--verify-files-root`, so it
does not weaken the public download requirement: the public download receipt
must still come from the hosted archive GET builder. Focused coverage stages a
synthetic candidate archive/public-download receipt and proves the resulting
proof surface, proof-surface checker report, launch receipt, and provenance
report pass. This turns the current diagnostic provenance drift into a
repeatable post-download rebuild step before the final release bundle uses
runtime-frontier bootstrap.

## 2026-07-01 — Release-candidate provenance has a preflight gate

`check_browser_release_candidate_provenance.py` now emits a schema-backed
`browser_release_candidate_provenance_report` before final browser release
bundle assembly. The preflight checks that the archive manifest, public
download receipt, proof surface, proof-page receipt, and browser launch receipt
all bind the same macOS arm64 release-candidate product/platform/provenance
tuple, and that the proof-surface checker report passed with file verification
and public URL enforcement against the same proof-surface path/hash. The
blocking runner exposes it as
`--with-browser-release-candidate-provenance-gate` and now requires
`--browser-release-candidate-provenance-package-inputs`, while final promotion
still requires the release artifact bundle and runtime frontier gates. The
checked-in sample report names the current diagnostic-to-candidate drift explicitly:
release archive manifest product, public download product, proof surface
release provenance, proof-page receipt release provenance, and browser launch
product.

## 2026-07-01 — Release bundle builder bootstraps frontier receipts

`build_browser_release_artifact_bundle.py` now has a two-pass
`--bootstrap-runtime-frontier` path for release-candidate bundles. The builder
can write a provisional bundle with a runtime-frontier placeholder, generate
the frontier receipt against the intended final bundle path, bind the generated
frontier SHA-256 into the final release bundle, and run final candidate
verification. The regression fixture uses a structurally claimable browser
claim report and proves the final bundle passes `require_release_candidate`
after the generated frontier receipt is hash-bound. Final checker comparisons
for runtime-frontier promotion receipts and runtime identity paths now resolve
paths under the verification root, so absolute and root-relative artifact
references cannot create false mismatches. The Chromium release recipe now uses
that bootstrap path for final bundle production, and a candidate rehearsal
against the checked-in diagnostic artifacts confirms that product/channel
provenance must be rebuilt through the archive manifest, public download
receipt, proof surface, and launch receipt rather than relabeled.

## 2026-07-01 — Runtime frontier builder can bootstrap release candidates

`check_browser_runtime_frontier_bundle.py` now checks release bundles with the
runtime-frontier artifact shape required but without recursively loading the
frontier receipt that it is constructing. The final release artifact bundle
checker still loads and verifies the finalized `runtimeFrontierBundle` artifact
for release-candidate audits. Focused coverage proves a synthetic
release-candidate bundle can produce a claimable frontier while the final
release checker still rejects the same bundle until the frontier artifact file
exists and hash-binds correctly. The checked-in diagnostic sample remains
blocked only because its release bundle is still diagnostic, not because the
frontier builder cannot represent a candidate bundle.

## 2026-07-01 — Chromium source checkout passes browser-runtime selectors

The Chromium source-checkout sample now runs against the real
`browser/chromium/src` tree with `requireRuntimeSelector=true` and reports
`status=pass` with no missing required markers. The last stale blocker was the
adapter-denylist source-field unit-test marker; the Chromium WebGPU decoder now
exposes a production formatter for those denial details, and
`webgpu_decoder_unittest.cc` verifies that the formatted log line carries the
profile-denylisted reason, adapter-detail tag, vendor ID, device ID, and
blocklist reason. The browser release artifact bundle now hash-binds that
passing checkout report. The release-candidate audit now advances past the
Chromium source-checkout requirement. The runtime identity sample is also
bound to the release bundle's packaged browser wrapper, Doe runtime, Dawn
fallback runtime, and embedded compiler hashes, so the candidate audit now
remains blocked on diagnostic release status and runtime-frontier claimability.

## 2026-07-01 — WebGPU backend uses IOSurface native import path

Chromium mailbox association no longer routes every `BackendType::WebGPU`
device through the Skia fallback. Non-CPU WebGPU devices now use
`AssociateMailboxDawn`, and `IOSurfaceImageBacking::ProduceDawn` accepts the
WebGPU backend alongside Metal for the IOSurface
`SharedTextureMemoryIOSurfaceDescriptor` import path. The IOSurface Dawn
representation carries its backend type so WebGPU begin-access avoids the
Metal-only device lookup, and only Metal devices are stored in the
Metal-device scheduled-future map. The Chromium source-checkout gate now proves
the WebGPU mailbox route, IOSurface Dawn representation, and IOSurface handle
import from those concrete source paths.

## 2026-07-01 — Present mailbox path ends shared access explicitly

`HandleDissociateMailboxForPresent` now calls a named
`EndAccessForPresent()` hook before erasing the associated shared-image entry.
The Dawn implementation resets the scoped Dawn access, so
`DawnImageRepresentation::ScopedAccess` runs its `EndAccess()` path before the
present clear decision moves on; the Skia fallback uses the same hook to keep
its upload/destroy behavior idempotent. The Chromium source-checkout gate now
requires that hook, the present-path call, and the map erase ordering instead
of a placeholder marker. The checkout sample remains blocked on the IOSurface
bridge/representation/handle and adapter-denylist unit-test source markers
listed by the sample report.

## 2026-07-01 — Chromium checkout gate proves Dawn runtime lifecycle

The Chromium source-checkout runtime-selector gate now supports composite
source markers and uses them for the Doe wire runtime instance and lifecycle
checks. Those checks now require the real Dawn WebGPU backend owner path:
`LoadDoeWireProcTable`, external runtime library opening, `mInnerInstance`
creation through the loaded proc table, `wgpuInstanceRelease` proc loading, and
the `Backend::~Backend()` release/nulling path in
`third_party/dawn/src/dawn/native/webgpu/BackendWGPU.cpp`. This retires the
stale expectation that the runtime instance has to appear as a Chromium service
wrapper token while still rejecting partial lifecycle matches. The checkout
sample remains blocked on the IOSurface bridge/handle, present shared-texture
end-access, and adapter-denylist unit-test source markers listed by the sample
report.

## 2026-06-30 — Chromium checkout gate follows Dawn WebGPU runtime loader

The Dawn WebGPU backend now logs explicit Doe external-runtime failure reasons
for library load failure, missing `wgpuGetProcAddress`, incomplete required
proc-table entries, and null instance creation while keeping required external
runtime selection fail-closed. The Chromium source-checkout runtime-selector
gate now accepts those diagnostics, the `LoadDoeWireProcTable` loader, and the
native shared texture/render/external-texture proc coverage from
`third_party/dawn/src/dawn/native/webgpu/BackendWGPU.cpp` instead of requiring
duplicated strings in `gpu/command_buffer/service/webgpu_decoder_impl.cc`.
The bound checkout sample remains blocked on the wire runtime instance and
lifecycle test, IOSurface bridge/handle, present shared-texture end-access,
and adapter-denylist unit-test markers listed by the sample report.

## 2026-06-30 — Doe shared-buffer mailbox path fails closed

The Chromium WebGPU service now rejects `AssociateMailboxForBuffer` for devices
whose metadata reports the WebGPU/Doe backend, returning
`error::kInvalidArguments` with the explicit
`doe_shared_buffer_unsupported` reason instead of attempting the Dawn shared
buffer representation path. The source-checkout runtime-selector gate now
passes the shared-buffer unsupported and fail-closed markers while continuing
to block on the remaining runtime loading, shared-image, render, external
texture, and unit-test source markers listed by the checkout report.

## 2026-06-30 — Release bundles bind Chromium source checkout diagnostics

The browser release artifact bundle sample now hash-binds
`examples/chromium-source-checkout-check.sample.json`, so the release evidence
chain carries Chromium source-checkout state instead of omitting it until the
release-candidate lane. Diagnostic bundle checks accept blocked checkout
reports when they are structurally consistent; release-candidate checks still
require `requireRuntimeSelector=true`, `status=pass`, and an empty
`missingRequired` list. The Chromium WebGPU service now reports
`unknown_selection_error` for forced-Doe no-adapter results and logs Doe
adapter-denylist source fields (`profile_denylisted`,
`adapter_denylist_detail`, `vendor_id`, and `blocklist_reason`) when a forced
Doe adapter is denied. The source-checkout gate under
`browser/chromium/scripts/env.sh` now passes those markers while continuing to
block on the remaining runtime-selector, proc-surface, and shared-image source
markers listed by the checkout report.

## 2026-06-30 — Browser execution receipts require inline shader source

The browser execution receipt schema now requires `sourceShader.source` and
`sourceShader.sha256`, and the receipt builder requires `--source-shader
<file>` instead of allowing a hash-only source identity. Optional
`--source-shader-sha256` is treated as an assertion against the file bytes. This
aligns the per-run schema with the published proof-surface policy: every
claimable browser WebGPU receipt must preserve the shader source body, lowering
path, backend, driver/device identity, output or frame hash, timing evidence,
and receipt ID.

## 2026-06-30 — Release candidates require packaged-browser launch receipts

Browser release candidates now require a hash-bound
`browserLaunchReceipt` artifact. The receipt contract binds the same product,
platform, release archive, release archive manifest, proof surface, and
packaged executable/app/runtime member paths as the release bundle, then records
that the packaged browser was launched from the archive with Doe active, hidden
fallback disabled, WebGPU available, the proof page loaded, a hosted gallery
page loaded, a same-page Dawn/Doe comparison row loaded, and the proof,
gallery, Dawn, and Doe receipt IDs observed. The release bundle checker loads
that receipt under file verification and rejects release candidates when any
of those identities drift from the proof surface. The producer helper now
loads the proof surface before emission and rejects proof-page, gallery,
comparison, backend, product, platform, archive, and archive-member drift while
building `browser_release_launch_receipt` JSON from observed launch facts.
Focused tests cover missing launch receipts, WebGPU-unavailable launches,
proof backend drift, and comparison-row drift.

## 2026-06-30 — Release archives require executable browser members

The browser release archive packer now rejects a package whose declared browser
binary lacks executable permissions before writing the zip. The release artifact
bundle checker also rejects verified archives when
`browserExecutableArchivePath` points at a non-executable zip member, so a
release-candidate archive cannot satisfy the downloadable-browser gate with
bytes that hash-match but cannot run. Regression coverage landed in both the
packer tests and release-bundle checker tests.

## 2026-06-30 — Release candidates bind Chromium source checkout evidence

Browser release candidates now require a hash-bound
`chromiumSourceCheckout` artifact in the release artifact bundle. The checker
loads that report under file verification and rejects release-candidate bundles
unless it is a `chromium_source_checkout_check` payload with `status=pass`,
`requireRuntimeSelector=true`, and no missing required checks. The bundle
builder accepts `--chromium-source-checkout`, and focused release-bundle tests
cover missing, blocked, and runtime-selector-disabled checkout reports.

## 2026-06-30 — Public receipt builders fail closed on identity

Published proof pages now bind their `activeBackend` diagnostic value to the
backend reported by a linked Doe execution receipt. The proof-surface builder
rejects a proof-page receipt before manifest emission when the diagnostics name
a backend that none of the linked Doe receipts used, and the proof-surface
checker enforces the same rule under file verification. The checked-in proof
page sample now reports `webgpu-doe`, matching the Doe execution receipt
backend, rather than the generic `webgpu` label.

The public download receipt builder now rejects missing receipt IDs,
observation identity, release archive paths, release archive manifest hash,
browser product identity, platform identity, and packaged executable/app/runtime
member paths before emitting a receipt. The public gallery receipt builder now
does the same for receipt IDs, observation identity, gallery artifact path,
workload contract path, workload IDs, receipt IDs, and receipt artifact paths.
Focused builder tests cover these direct entry points so schema-invalid public
receipt JSON is stopped at the producer boundary.

## 2026-06-30 — Release candidates bind proof runtime identity to shipped artifacts

The browser release artifact bundle checker now loads the proof surface
`runtimeIdentityPath` for release candidates and compares runtime identity
artifact hashes back to the same shipped release artifacts. Either
`provider.artifactIdentity` or `runtimeSelection.artifactIdentity` may carry the
hashes, but `browserExecutableSha256`, `doeLibSha256`, and
`dawnRuntimeSha256` must match the bundle `browserBinary`, `doeRuntime`, and
`dawnFallbackRuntime` SHA-256 values. Candidate fixtures now stamp those hashes
from the generated browser, Doe runtime, and Dawn fallback files, and the
regression test corrupts the Doe runtime hash to prove the checker rejects a
proof page that reports active Doe for different packaged bytes.

The same release-candidate checker now compares proof-page diagnostics
`compilerPath` against the bundle `shaderCompiler.path`. Candidate fixtures
stamp the proof-page HTML and diagnostic receipt from the generated compiler
artifact, and the regression test rewrites those linked proof artifacts while
leaving the bundle compiler artifact unchanged to prove the mismatch is
rejected.

Published proof-surface checks now require linked browser execution receipts to
carry inline `sourceShader.source` and `sourceShader.sha256`. The checked-in
Dawn/Doe compute, rendering, tensor, shader-edge, and benchmark-trace receipt
samples now include source text with matching source hashes, and the
proof-surface sample passes the public URL/source-text gate. The checker also
rejects receipts whose declared source hash does not match the inline source
text.
The proof-surface producer now enforces the same discipline before emitting a
manifest: execution receipts must carry inline source, source hashes must match
that source, and paired Dawn/Doe comparison receipts must share source shader
identity before the builder declares `same_source_shader_identity`.
The producer and checker now also require paired comparison receipts to share
driver identity as well as device identity before accepting
`same_device_identity`, so a Dawn-vs-Doe browser comparison cannot mask driver
drift behind matching workload/source/output fields.
The proof-surface producer now rejects comparison entries before manifest
emission when paired receipts have the wrong Dawn/Doe runtime labels, workload
identity drift, comparison-row workload drift, or command-coverage drift. That
keeps `same_workload_id` and `exact_match` from being producer assertions over
unchecked receipt pairs.
It also rejects any linked execution receipt that is missing lowering path,
backend, command evidence, output identity, timing phases, complete command
coverage, or clean runtime selector/fallback state before hash-linking that
receipt into the published proof surface.
The proof-page receipt now has producer-side linkage too: every
`recentReceiptIds` entry must be backed by one of the execution receipt
payloads linked from the same proof page before the surface is emitted.
The same receipt gate now rejects proof-page receipts that do not report the
expected load type, loaded status, receipt ID, diagnostics object, release
provenance object, and observation identity.
The proof-page artifact itself is now checked by the producer for visible
diagnostics, release provenance, recent receipt IDs, receipt payload links, and
comparison evidence before it can back a published proof surface.
Gallery page artifacts now get the same producer-side visibility check for
category, workload contract path, workload IDs, receipt IDs, and receipt
artifact links before they can be hash-linked into the proof surface.
Public gallery receipts are also rejected by the producer when they do not
report GET, status code 200, receipt ID, and observation identity.
Comparison rows now get the same producer discipline: the runner
`pageArtifactPath` must match one of the gallery artifacts emitted by the
builder, and the comparison artifact must validate as a strict Dawn+Doe
Chromium WebGPU smoke report with a valid hash chain before the surface is
written.

## 2026-06-30 — Release archive packer supports Linux package evidence

The browser release archive packer now accepts generic `--package-dir` input
while retaining `--app-dir` compatibility, and can emit deterministic Linux
zip archives with the same schema-backed release archive manifest used by the
macOS lane. Linux packages get a browser metadata JSON member when one is not
already present; the release bundle checker reads that metadata from the zip
and verifies product identity, platform tuple, browser executable member path,
Doe runtime member path, and Dawn fallback runtime member path against the
release bundle. The release-candidate gate remains macOS arm64 zip first, so
Linux archive support is diagnostic evidence until the macOS release-candidate
lane is complete.

## 2026-06-30 — Public download receipts bind archive manifests

Browser public download receipts now bind the release archive manifest path and
SHA-256 in addition to the hosted URL, served archive hash, byte length,
product identity, platform tuple, and packaged member paths. The public
download receipt builder requires `--release-archive-manifest` and computes the
manifest hash, the release-bundle checker rejects manifest path/hash drift
between `publicDownloadReceipt` and `releaseArchiveManifest`, and the browser
artifact identity coverage manifest treats those fields as part of the receipt
identity. The checked-in proof page, proof-page receipt, published proof
surface, and release artifact bundle samples were re-hashed through that
evidence chain.

## 2026-06-30 — Public gallery receipts bind workload and receipt identity

Published browser gallery proof now binds workload IDs, receipt IDs, and
receipt artifact paths across the hosted page receipt, proof-surface gallery
row, linked execution receipt payloads, and visible gallery page content.
`bench/tools/build_browser_public_gallery_receipt.py` now derives those fields
from `--receipt-payload` execution receipts, public gallery receipt schemas
require `workloadIds`, `receiptIds`, and `receiptArtifactPaths`, and
`bench/tools/build_browser_published_proof_surface.py` derives gallery
`workloadIds` from the linked execution receipts before checking the public
receipt. The proof-surface checker rejects missing workload IDs, public receipt
workload/receipt drift, and gallery rows whose declared workload IDs do not
match the linked receipt payloads. The checked-in gallery samples now use
category-specific Doe execution receipts for rendering, tensor, shader-edge,
and benchmark-trace pages instead of reusing the compute receipt.

## 2026-06-30 — Browser proof comparisons carry explicit policy evidence

Published browser proof-surface comparisons now carry a schema-backed
`comparisonPolicy` next to the same-page Dawn/Doe runner and paired execution
receipts. The policy declares same workload ID, same source shader identity,
same adapter/device identity, same timing scope, exact command coverage match,
output hash/frame hash policy, and no hidden fallback. The proof-surface
builder derives the policy from the paired receipt payloads, and the checker
rejects missing policy fields or policy values that drift from the Dawn/Doe
receipt payloads. The artifact identity coverage manifest now treats those
policy fields as part of the published proof surface identity.

Focused verification:

- `python3 -m unittest bench.tests.test_browser_published_proof_surface bench.tests.test_browser_published_proof_surface_builder`
- `python3 bench/tools/check_browser_published_proof_surface.py --surface examples/browser-published-proof-surface.sample.json --verify-files-root . --json`

## 2026-06-30 — Browser release bundles bind downloadable archive identity

The browser release artifact bundle now has concrete public-download and proof
surface anchors: `releaseArchive`, `releaseArchiveManifest`,
`browserProduct`, `platform`, and `proofSurface` identity.
Release-candidate bundles must hash-bind the
downloadable archive, name the browser product as Doe Browser or Fawn Doe,
identify the OS/architecture/package format, name the executable, Doe runtime,
and Dawn fallback runtime paths inside the archive, bind the archive manifest,
bind macOS app metadata to the same product identity, and still bind the browser
executable, Doe runtime, Dawn fallback runtime, shader compiler, proof surface,
claim reports, promotion receipts, contracts, runtime frontier bundle receipt,
and policies. The builder accepts
`--release-archive`, `--release-archive-url`, `--platform-os`,
`--platform-arch`, `--browser-binary-archive-path`, and
`--dawn-fallback-runtime`; it also accepts
`--release-archive-manifest`, `--browser-app-metadata-archive-path`,
`--doe-runtime-archive-path`,
`--dawn-fallback-runtime-archive-path`, `--public-download-receipt`,
`--runtime-frontier-bundle`, `--product-id`, `--product-name`,
`--product-version`, and `--product-channel`. The checker rejects release
candidates that are not the initial macOS arm64 zip platform or that omit the
archive, release archive manifest, public HTTPS archive download URL, public
download receipt, browser product identity, platform identity, packaged app
metadata/executable/runtime member paths, Dawn fallback runtime hash, proof
surface hash, or runtime frontier bundle receipt. The release-bundle schema now mirrors that
release-candidate structure instead of leaving the downloadable archive and
proof artifacts as checker-only requirements. Builder verification now also
checks the runtime frontier receipt against the intended `--out` bundle path.
Public URL validation is deterministic and does not fetch the network, but it
does reject localhost, single-label hosts, non-global IP literals, and
reserved/test suffixes such as `.local`, `.localhost`, `.test`, `.example`,
and `.invalid`, plus the reserved `example.com` family.
`bench/tools/build_browser_public_download_receipt.py` now performs the hosted
archive GET and emits the schema-backed public download receipt with served
content hash, byte length, product identity, platform tuple, archive path, and
packaged member paths; it can also compare the served bytes against the local
release archive before writing the receipt.
The browser archive packer now creates deterministic macOS zip archives from a
`.app` bundle, injects explicit Doe and Dawn runtime members, and emits a
schema-backed release archive manifest with archive hash, product/platform
identity, required member paths, member hashes, byte lengths, and
executable-bit state. It rejects mismatched product identity before packaging,
so `doe-browser` maps to `Doe Browser` and `fawn-doe` maps to `Fawn Doe`.
The release bundle checker loads that manifest and verifies it against the
release bundle identity plus the actual zip member metadata under
`--verify-files-root`.

Runtime frontier receipts are now content-bound back to the release bundle:
the release checker loads the referenced frontier receipt, requires pass
status, compares the summarized release path, `bundleId`, and `releaseStatus`,
requires the frontier claim-promotion receipt path to match the release bundle
`promotionReceipts`, requires the frontier runtime identity path to match the
proof surface `runtimeIdentityPath`, and requires verified release artifact
files, passing component summaries, promotion status `promotable`, and
`claimabilityStatus=claimable` with no frontier claim blockers or failures for
release candidates. A hash-bound frontier receipt for a different release
bundle, promotion receipt, runtime identity, blocked/failed frontier, or
non-promotable component no longer satisfies the release-candidate evidence
surface.
The runtime frontier composer now enforces the same input binding before it
emits a pass receipt: the supplied promotion receipt must be bundled by the
release artifact bundle, and the supplied runtime identity must match the proof
surface `runtimeIdentityPath`.
The runtime frontier schema also rejects `claimabilityStatus=claimable` receipts
that carry blockers, failures, or non-passing component summaries.

Release-candidate public download receipts must bind a successful GET of the
hosted archive URL to the same SHA-256 as `releaseArchive.sha256`, the same
archive path, browser product identity, platform tuple, executable archive
member path, app metadata member path, Doe runtime archive member path, Dawn
fallback runtime archive member path, and byte length as the verified local
archive. A hosted URL without this matching receipt no longer satisfies the
public-download gate.

Release-candidate gallery pages now follow the same served-byte discipline:
each hosted gallery URL must link a `browser_public_gallery_receipt` artifact
whose successful GET result matches the hash-bound gallery page artifact,
content length, category, URL, and workload contract path. A gallery URL alone
no longer satisfies the public proof-surface gate. The proof-surface schema now
requires every required gallery category, hosted gallery URLs, and public
gallery receipt artifacts for every gallery row; schema targets validate the
proof surface plus each public gallery receipt sample, public URL fields must
be HTTPS and reject obvious local or reserved hosts, and identity coverage
anchors each gallery URL plus receipt hash.
`bench/tools/build_browser_public_gallery_receipt.py` now performs the hosted
gallery GET and emits the schema-backed public gallery receipt with served
content hash, byte length, category, URL, local gallery artifact path, workload
contract path, and observation time; it can compare hosted bytes against the
local gallery artifact before writing the receipt.

Release-candidate proof pages also require a `browser_proof_page_receipt`
artifact for the local diagnostics page. The receipt must prove the internal
diagnostics URL loaded bytes matching the hash-bound proof page artifact,
content length, runtime identity path, active-Doe diagnostics fields, release
provenance, and recent receipt IDs. The proof page and proof-page receipt
schemas require `activeRuntime=doe` and `fallbackPolicyState=hidden_fallback_disabled`.
`bench/tools/build_browser_proof_page_receipt.py` now emits that receipt from
the captured diagnostics page artifact, active-Doe diagnostics fields, release
archive, archive manifest, public download receipt, product/platform identity,
packaged member paths, runtime identity path, and recent receipt IDs.
The proof page must visibly show the browser product, platform, archive hash,
hosted download URL, release archive manifest, public download receipt, and packaged
executable/app/runtime member paths. A local proof-page HTML fixture without
this matching receipt no longer satisfies the proof-page gate.
The release-bundle checker now also compares that proof-page release provenance
against the enclosing release bundle, so a proof surface for one downloadable
browser archive cannot satisfy a different release bundle.

When file verification is enabled, release archives declared as
`packageFormat=zip` must also pass zip integrity checks, and the declared
executable member must hash-match `browserBinary.sha256`. This prevents a
release-candidate bundle from satisfying the public-download gate with a hashed
non-zip payload or a zip that does not contain the declared browser executable.

The default release-bundle contract set now includes the published browser
release contract, and the Chromium fork-maintenance policy now requires release
archive hashes and platform identity. The checked-in sample bundle remains
diagnostic, but verifies against the repo-local sample archive fixture with
`--verify-files-root`.

The new published proof-surface manifest checker verifies the local diagnostics
proof page artifact, the checked capture policy gate, active Doe runtime
identity, required gallery categories, linked execution receipt payloads, and
paired Dawn-vs-Doe comparison receipts. With file verification enabled, the
proof page artifact must show the declared diagnostics, receipt links, each
comparison ID, workload ID, same-page runner metadata, comparison artifact, and
both Dawn/Doe receipt payload links, and the declared runner gallery page must
expose those comparison links together on the same page. Each gallery page
artifact must also show its category, workload contract path, receipt IDs, and
receipt artifact links. Execution receipts must carry the receipt ID, selected
runtime, source shader identity, lowering path, backend, driver/device identity, command graph
or flight-recorder identity, command coverage, output hash or frame hash,
runtime selector state, fallback state, and timing class. The schema now binds
top-level runtime identity to `runtimeSelectorState.selectedRuntime`, and the
checker rejects selector fallback drift, incomplete command coverage, or
dispatch counts that exceed the declared command count. The checker also
compares paired Dawn/Doe receipt payloads for matching workload, source,
output, timing, device, and command coverage identity, and it validates linked
browser smoke comparison artifacts through the existing strict Dawn/Doe
smoke-report gate. The browser release bundle checker delegates to that
proof-surface checker when file verification is enabled and requires hosted
HTTPS gallery page URLs for release candidates, so a release candidate cannot
pass with a dangling proof page, gallery page, receipt payload, comparison
receipt reference, missing public gallery URL, reserved/test gallery URL,
invalid capture policy, non-Doe runtime identity, incomplete execution receipt,
page content drift, mismatched comparison evidence, a split comparison gallery,
or a comparison artifact that does not prove both Dawn and Doe modes.
`bench/tools/build_browser_execution_receipt.py` now builds those per-run
browser execution receipts from smoke-report runtime-selection evidence plus
explicit shader identity, output/frame hash, command coverage, and timing
inputs, failing closed on runtime selector drift, hidden fallback, fallback
reason codes, or impossible command coverage before proof-surface assembly.
`bench/tools/build_browser_published_proof_surface.py` now assembles that
manifest from concrete proof-page, proof-page receipt, execution receipt,
gallery receipt, and paired comparison artifacts, recomputing artifact hashes
and rejecting stale proof-page or gallery public receipts before the release
bundle consumes the proof surface.

Tracked sharding follow-up: owner `browser-proof-surface`; split
`bench/tools/check_browser_published_proof_surface.py` into proof-page receipt,
gallery receipt, and comparison receipt checker modules. The current checker
exceeds the Python tooling line cap while the published-browser proof surface
is still being hardened.

Tracked sharding follow-up: owner `browser-release-surface`; split
`bench/tools/check_browser_release_artifact_bundle.py` into release archive,
proof/runtime frontier, and promotion/policy checker modules; split
`bench/tests/test_browser_release_artifact_bundle.py` into archive, proof
surface, runtime frontier, and builder fixture test modules. The archive
manifest hook now pushes both legacy files past the Python tooling line cap,
with new manifest-specific code already isolated in dedicated modules.
Also split `bench/tests/test_browser_runtime_frontier_bundle.py` into sample,
release-fixture, and claimability component test modules; the release manifest
fixture pushes that test file past the Python tooling line cap.

Touched:

- `bench/tools/build_browser_release_artifact_bundle.py`
- `bench/tools/_public_url.py`
- `bench/tools/check_browser_capture_policy.py`
- `bench/tools/check_browser_release_artifact_bundle.py`
- `bench/tools/check_browser_published_proof_surface.py`
- `bench/tools/browser_release_archive_manifest.py`
- `bench/tools/check_chromium_fork_maintenance_policy.py`
- `bench/tests/test_package_browser_release_archive.py`
- `bench/tests/test_browser_release_archive_manifest_binding.py`
- `bench/tests/test_browser_published_proof_surface.py`
- `bench/tests/test_browser_public_url_schemas.py`
- `bench/tests/test_browser_release_artifact_bundle.py`
- `bench/tests/test_browser_runtime_frontier_bundle.py`
- `bench/tests/test_chromium_fork_maintenance_policy.py`
- `browser/chromium/README.md`
- `browser/chromium/scripts/package-browser-release-archive.py`
- `browser/chromium/contracts/browser-published-release.contract.md`
- `browser/chromium/plan.md`
- `bench/README.md`
- `config/browser-capture-policy.json`
- `config/browser-capture-policy.schema.json`
- `config/browser-execution-receipt.schema.json`
- `config/browser-proof-page-receipt.schema.json`
- `config/browser-release-archive-manifest.schema.json`
- `config/browser-public-gallery-receipt.schema.json`
- `config/browser-published-proof-surface.schema.json`
- `config/browser-public-download-receipt.schema.json`
- `config/browser-release-artifact-bundle.schema.json`
- `config/browser-artifact-identity-coverage.json`
- `config/browser-artifact-identity-coverage.schema.json`
- `config/chromium-fork-maintenance-policy.json`
- `config/chromium-fork-maintenance-policy.schema.json`
- `config/chromium-patch-manifest.json`
- `config/schema-targets.json`
- `docs/chromium-webgpu-task-list.md`
- `examples/browser-release-archive-manifest.sample.json`
- `examples/browser-release-artifact-bundle.sample.json`
- `examples/browser-proof-page-receipt.sample.json`
- `examples/browser-public-download-receipt.sample.json`
- `examples/browser-public-gallery-receipt.sample.json`
- `examples/browser-published-proof-surface.sample.json`
- `examples/browser-proof-page.sample.html`
- `examples/browser-gallery-compute.sample.html`
- `examples/browser-gallery-rendering.sample.html`
- `examples/browser-gallery-tensor.sample.html`
- `examples/browser-gallery-shader-edge.sample.html`
- `examples/browser-gallery-benchmark-trace.sample.html`
- `examples/browser-dawn-execution-receipt.sample.json`
- `examples/browser-doe-execution-receipt.sample.json`
- `examples/browser-release-archive.sample.zip`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 -m zipfile -t examples/browser-release-archive.sample.zip`
- `python3 -m compileall -q bench/tools/_public_url.py bench/tools/check_browser_published_proof_surface.py bench/tools/check_browser_capture_policy.py bench/tools/build_browser_release_artifact_bundle.py bench/tools/check_browser_release_artifact_bundle.py bench/tools/browser_release_archive_manifest.py bench/tests/test_browser_published_proof_surface.py bench/tests/test_browser_release_artifact_bundle.py bench/tests/test_browser_release_archive_manifest_binding.py bench/tests/test_browser_runtime_frontier_bundle.py`
- `python3 bench/tools/check_browser_capture_policy.py --policy config/browser-capture-policy.json --json`
- `python3 bench/tools/check_browser_published_proof_surface.py --surface examples/browser-published-proof-surface.sample.json --verify-files-root . --json`
- `python3 browser/chromium/scripts/check-browser-smoke-report.py --smoke-report examples/browser-smoke-report.sample.json --json`
- `python3 bench/tools/check_browser_release_artifact_bundle.py --bundle examples/browser-release-artifact-bundle.sample.json --verify-files-root . --json`
- `python3 bench/tools/check_browser_artifact_identity_coverage.py --coverage config/browser-artifact-identity-coverage.json --root . --json`
- `python3 bench/tools/check_chromium_fork_maintenance_policy.py --policy config/chromium-fork-maintenance-policy.json --root . --json`
- `python3 bench/tools/check_chromium_patch_manifest.py --manifest config/chromium-patch-manifest.json --policy config/chromium-fork-maintenance-policy.json --root . --json`
- `python3 bench/tools/check_browser_runtime_frontier_bundle.py --runtime-identity examples/browser-runtime-identity.selector.sample.json --claim-promotion-receipt examples/browser-claim-promotion-receipt.sample.json --release-artifact-bundle examples/browser-release-artifact-bundle.sample.json --verify-files-root . --out /tmp/browser-runtime-frontier-bundle.new.json`
- `python3 browser/chromium/scripts/check-browser-milestones.py`
- `python3 -m unittest bench.tests.test_browser_published_proof_surface bench.tests.test_browser_release_artifact_bundle bench.tests.test_browser_runtime_frontier_bundle bench.tests.test_chromium_fork_maintenance_policy`
- `python3 -m unittest bench.tests.test_browser_public_url_schemas`
- `python3 -m unittest bench.tests.test_package_browser_release_archive`
- `python3 -m unittest bench.tests.test_browser_release_archive_manifest_binding`
- `env PYTHONPATH=. python3 -c "from pathlib import Path; import tempfile; from bench.tests import test_browser_release_artifact_bundle as t; funcs=[t.test_browser_release_artifact_bundle_candidate_requires_public_download_receipt,t.test_browser_release_artifact_bundle_candidate_rejects_public_download_hash_mismatch,t.test_browser_release_artifact_bundle_candidate_rejects_failed_public_download,t.test_browser_release_artifact_bundle_builder_accepts_verified_candidate]; [func(Path(tempfile.mkdtemp())) for func in funcs]; print('selected release bundle tests passed')"`
- `python3 bench/gates/schema_gate.py`
- `git diff --check`
- `git -C browser/chromium/src/third_party/dawn diff --check`

## 2026-06-30 — Published browser release bar is explicit

The Chromium browser lane now names the credible public proof artifact: a
downloadable Chromium-family browser build with Doe active in the WebGPU path,
per-run source-preserving receipts, Dawn-vs-Doe comparison mode, hosted proof
gallery pages, release zips with SHA-256, and a local proof page such as
`about:doe`. The requirement is captured in the new draft published-release
contract and linked from the browser README, acceptance plan, and canonical
Chromium WebGPU task list.

This does not promote any browser output to claimable. Browser evidence remains
diagnostic until the published release contract, comparison gallery, proof page,
and release artifact bundle all pass their gates.

Touched:

- `browser/chromium/contracts/browser-published-release.contract.md`
- `browser/chromium/contracts/README.md`
- `browser/chromium/README.md`
- `browser/chromium/plan.md`
- `docs/chromium-webgpu-task-list.md`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 browser/chromium/scripts/check-browser-milestones.py`
- `python3 bench/gates/schema_gate.py`
- `git diff --check`

## 2026-06-30 — Forced-Doe browser smoke clears external texture probes

The forced-Doe Chromium smoke now preserves the browser external-copy path and
creates external textures without crashing the GPU process. The prior
external-texture GPU-process crash was narrowed with a GDB GPU-process capture,
then fixed in the WebGPU-on-WebGPU external texture wrapper by treating the
single-plane YUV conversion matrix as optional, matching Dawn's base external
texture parameter path. The wrapper also now validates plane inner handles and
returns an explicit creation error if the Doe layer returns no external texture
handle.

The latest GPU-process debug capture no longer reports the render-bundle
encoder double-free that appeared in the previous browser-smoke run.

New evidence:

- `browser/chromium/artifacts/current-smoke-headless-wgpu-browser-copy-hook/dawn-vs-doe.browser.playwright-smoke.doe-external-yuv-default.json`
- `browser/chromium/artifacts/current-smoke-headless-wgpu-browser-copy-hook/dawn-vs-doe.browser.playwright-smoke.both-external-yuv-default.json`
- `browser/chromium/artifacts/current-smoke-headless-wgpu-browser-copy-hook/browser-media-path-probe.doe-both-external-yuv-default.json`
- `browser/chromium/artifacts/current-smoke-headless-wgpu-browser-copy-hook/chrome-doe-external-yuv-default.log`
- `browser/chromium/artifacts/current-smoke-headless-wgpu-browser-copy-hook/gpu-process-gdb-external-noassert.log`

The browser lane remains diagnostic until the published release contract,
comparison gallery, proof page, and release artifact bundle all pass their
gates.

Touched:

- `browser/chromium/src/third_party/dawn/src/dawn/native/webgpu/ExternalTextureWGPU.cpp`
- `browser/chromium/src/third_party/dawn/src/dawn/native/webgpu/ExternalTextureWGPU.h`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `zig fmt runtime/zig/src/render_bundle.zig`
- `zig build dropin-full`
- `third_party/depot_tools/clang-format -i third_party/dawn/src/dawn/native/webgpu/ExternalTextureWGPU.cpp third_party/dawn/src/dawn/native/webgpu/ExternalTextureWGPU.h`
- `git diff --check`
- `git -C browser/chromium/src/third_party/dawn diff --check`
- `ninja -C browser/chromium/src/out/fawn_release headless_shell`
- `env CHROME_LOG_FILE=/home/x/deco/doe/browser/chromium/artifacts/current-smoke-headless-wgpu-browser-copy-hook/chrome-doe-external-yuv-default.log node browser/chromium/scripts/webgpu-playwright-smoke.mjs --mode doe --chrome /home/x/deco/doe/browser/chromium/src/out/fawn_release/headless_shell --doe-lib /home/x/deco/doe/runtime/zig/zig-out/lib/libwebgpu_doe_full.so --runtime-selector-policy /home/x/deco/doe/config/browser-runtime-selector-policy.json --out /home/x/deco/doe/browser/chromium/artifacts/current-smoke-headless-wgpu-browser-copy-hook/dawn-vs-doe.browser.playwright-smoke.doe-external-yuv-default.json --chrome-arg --enable-logging --chrome-arg --v=1 --chrome-arg '--vmodule=*webgpu*=2,*dawn*=2,*gpu*=1'`
- `env CHROME_LOG_FILE=/home/x/deco/doe/browser/chromium/artifacts/current-smoke-headless-wgpu-browser-copy-hook/chrome-both-external-yuv-default.log ./browser/chromium/scripts/run-smoke.sh --mode both --strict --runtime-selector-policy /home/x/deco/doe/config/browser-runtime-selector-policy.json --out /home/x/deco/doe/browser/chromium/artifacts/current-smoke-headless-wgpu-browser-copy-hook/dawn-vs-doe.browser.playwright-smoke.both-external-yuv-default.json --chrome /home/x/deco/doe/browser/chromium/src/out/fawn_release/headless_shell --doe-lib /home/x/deco/doe/runtime/zig/zig-out/lib/libwebgpu_doe_full.so`
- `python3 browser/chromium/scripts/check-browser-smoke-report.py --smoke-report browser/chromium/artifacts/current-smoke-headless-wgpu-browser-copy-hook/dawn-vs-doe.browser.playwright-smoke.both-external-yuv-default.json --json`
- `python3 browser/chromium/scripts/build-browser-media-path-probe.py --report browser/chromium/artifacts/current-smoke-headless-wgpu-browser-copy-hook/dawn-vs-doe.browser.playwright-smoke.both-external-yuv-default.json --mode doe --out browser/chromium/artifacts/current-smoke-headless-wgpu-browser-copy-hook/browser-media-path-probe.doe-both-external-yuv-default.json`
- `python3 browser/chromium/scripts/check-browser-media-path-probe.py --probe browser/chromium/artifacts/current-smoke-headless-wgpu-browser-copy-hook/browser-media-path-probe.doe-both-external-yuv-default.json --capture-policy-root . --runtime-identity-root . --json`

## 2026-06-30 — Browser smoke preserves media blocker evidence

The Chromium WebGPU smoke harness now records per-source
`copyExternalImageToTexture` attempts and runs its mini upload/dispatch timing
probes before external media probes can invalidate the Doe queue. This keeps
forced-Doe, no-hidden-fallback browser smoke evidence useful even while the
external media path remains diagnostic.

The Chromium source checkout was rebuilt for `headless_shell` after adding
queue-completion retention for transient browser copy resources in the
`GPUQueue` external-copy paths. That source hardening compiled, but the fresh
smoke artifact still reports the existing Doe-only external Instance blocker.
The new smoke artifact is:

- `browser/chromium/artifacts/current-smoke-headless-preexternal-benches/dawn-vs-doe.browser.playwright-smoke.diagnostic.json`

A Doe media-path probe was generated from that smoke report and passes the
media-probe checker while preserving the failed external-texture and
copy-external-image statuses:

- `browser/chromium/artifacts/current-smoke-headless-preexternal-benches/browser-media-path-probe.doe.json`

Touched:

- `browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `browser/chromium/src/third_party/blink/renderer/modules/webgpu/gpu_queue.cc`
- `browser/chromium/src/third_party/blink/renderer/modules/webgpu/gpu_queue.h`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `node --check browser/chromium/scripts/webgpu-playwright-smoke.mjs`
- `ninja -C browser/chromium/src/out/fawn_release headless_shell`
- `./browser/chromium/scripts/run-smoke.sh --mode both --strict --runtime-selector-policy /home/x/deco/doe/config/browser-runtime-selector-policy.json --out /home/x/deco/doe/browser/chromium/artifacts/current-smoke-headless-preexternal-benches/dawn-vs-doe.browser.playwright-smoke.diagnostic.json --chrome /home/x/deco/doe/browser/chromium/src/out/fawn_release/headless_shell --doe-lib /home/x/deco/doe/runtime/zig/zig-out/lib/libwebgpu_doe_full.so` (diagnostic exit while the external media checks remain failed)
- `python3 browser/chromium/scripts/build-browser-media-path-probe.py --report browser/chromium/artifacts/current-smoke-headless-preexternal-benches/dawn-vs-doe.browser.playwright-smoke.diagnostic.json --mode doe --out browser/chromium/artifacts/current-smoke-headless-preexternal-benches/browser-media-path-probe.doe.json`
- `python3 browser/chromium/scripts/check-browser-media-path-probe.py --probe browser/chromium/artifacts/current-smoke-headless-preexternal-benches/browser-media-path-probe.doe.json --capture-policy-root . --runtime-identity-root . --json`
- `python3 browser/chromium/scripts/check-browser-smoke-report.py --smoke-report browser/chromium/artifacts/current-smoke-headless-preexternal-benches/dawn-vs-doe.browser.playwright-smoke.diagnostic.json --json` (expected diagnostic failure on Doe external media checks)
- `git -C browser/chromium/src diff --check -- third_party/blink/renderer/modules/webgpu/gpu_queue.cc third_party/blink/renderer/modules/webgpu/gpu_queue.h`

## 2026-06-30 — Browser structural receipts bind projection manifest

The browser claim gate now accepts the generated browser projection manifest as
an explicit artifact input and uses it to bind strict claim rows to governed
`browserWorkload` metadata when reused layered reports do not duplicate that
metadata inline. The browser claim report schema records
`projectionManifestPath`, so source-kernel command hashes, kernel hashes, and
dispatch shape evidence stay traceable in the emitted claim report.

The reused Chromium browser claim report under
`bench/out/scratch/browser-claim-reuse-20260309T015157Z/` was regenerated from
the existing repeated-window artifacts. Its structural receipt now passes the
source-command identity, source-kernel dispatch, dispatch-shape parity, and
checker-report requirements. The composed browser runtime frontier bundle and
the Dawn replacement readiness rollup were rebuilt from that claim report. The
browser row remains diagnostic on claim-policy/tail health, promotion
forced-Doe and hidden-fallback evidence, and `releaseStatus=diagnostic`; see the
frontier bundle JSON for the current blocker breakdown.

Touched:

- `bench/browser/browser_claim_gate.py`
- `bench/tests/test_browser_claim_gate.py`
- `config/browser-claim-report.schema.json`
- `examples/browser-claim-report.sample.json`
- `examples/browser-claim-promotion-receipt.sample.json`
- `examples/browser-release-artifact-bundle.sample.json`
- `examples/browser-runtime-frontier-bundle.sample.json`
- `bench/out/scratch/browser-claim-reuse-20260309T015157Z/browser_claim_report.json`
- `bench/out/scratch/browser-claim-reuse-20260309T015157Z/browser_claim_report.promotion-receipt.json`
- `bench/out/scratch/browser-claim-reuse-20260309T015157Z/browser-release-artifact-bundle.json`
- `bench/out/scratch/browser-claim-reuse-20260309T015157Z/browser-runtime-frontier-bundle.json`
- `bench/out/scratch/dawn-replacement-readiness-report.json`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 -m py_compile bench/browser/browser_claim_gate.py bench/tools/check_browser_release_artifact_bundle.py bench/tools/check_browser_runtime_frontier_bundle.py bench/tests/test_browser_claim_gate.py bench/tests/test_browser_release_artifact_bundle.py bench/tests/test_browser_runtime_frontier_bundle.py`
- `PYTHONPATH=bench:. python3 -m unittest bench.tests.test_browser_claim_gate bench.tests.test_browser_release_artifact_bundle bench.tests.test_browser_runtime_frontier_bundle`
- Local fixture runner for module-level browser claim/release tests, because
  `pytest` is not installed in this environment.
- Diagnostic artifact regeneration with `python3 bench/browser/browser_claim_gate.py --reuse-artifact-root browser/chromium/artifacts/20260309T015157Z/browser-claim --report bench/out/scratch/browser-claim-reuse-20260309T015157Z/browser_claim_report.json --promotion-receipt-out bench/out/scratch/browser-claim-reuse-20260309T015157Z/browser_claim_report.promotion-receipt.json --json`; the command exits nonzero while the claim policy remains diagnostic.
- `python3 bench/tools/build_browser_claim_promotion_receipt.py --claim-report examples/browser-claim-report.sample.json --out examples/browser-claim-promotion-receipt.sample.json --receipt-id browser-claim-promotion-sample --claim-policy config/browser-claim-policy.json`
- `python3 bench/tools/build_browser_release_artifact_bundle.py --bundle-id browser-release-diagnostic-sample-v1 --release-status diagnostic --browser-binary browser/chromium/src/out/fawn_release/chrome-wrapper --doe-runtime runtime/zig/zig-out/lib/libwebgpu_doe.so --shader-compiler runtime/zig/zig-out/bin/doe-zig-runtime --claim-report examples/browser-claim-report.sample.json --promotion-receipt examples/browser-claim-promotion-receipt.sample.json --verify-files-root . --out examples/browser-release-artifact-bundle.sample.json`
- `python3 bench/tools/check_browser_runtime_frontier_bundle.py --runtime-identity examples/browser-runtime-identity.selector.sample.json --claim-promotion-receipt examples/browser-claim-promotion-receipt.sample.json --release-artifact-bundle examples/browser-release-artifact-bundle.sample.json --verify-files-root . --out examples/browser-runtime-frontier-bundle.sample.json --json`
- `python3 bench/tools/build_browser_release_artifact_bundle.py --bundle-id browser-release-diagnostic-reuse-20260309T015157Z --release-status diagnostic --browser-binary browser/chromium/src/out/fawn_release/chrome-wrapper --doe-runtime runtime/zig/zig-out/lib/libwebgpu_doe.so --shader-compiler runtime/zig/zig-out/bin/doe-zig-runtime --claim-report bench/out/scratch/browser-claim-reuse-20260309T015157Z/browser_claim_report.json --promotion-receipt bench/out/scratch/browser-claim-reuse-20260309T015157Z/browser_claim_report.promotion-receipt.json --verify-files-root . --out bench/out/scratch/browser-claim-reuse-20260309T015157Z/browser-release-artifact-bundle.json`
- `python3 bench/tools/check_browser_runtime_frontier_bundle.py --runtime-identity examples/browser-runtime-identity.selector.sample.json --claim-promotion-receipt bench/out/scratch/browser-claim-reuse-20260309T015157Z/browser_claim_report.promotion-receipt.json --release-artifact-bundle bench/out/scratch/browser-claim-reuse-20260309T015157Z/browser-release-artifact-bundle.json --verify-files-root . --out bench/out/scratch/browser-claim-reuse-20260309T015157Z/browser-runtime-frontier-bundle.json --json`
- `python3 bench/tools/build_dawn_replacement_readiness_report.py --browser-frontier-bundle bench/out/scratch/browser-claim-reuse-20260309T015157Z/browser-runtime-frontier-bundle.json --tint-frontier-bundle bench/out/scratch/tint-compiler-frontier-bundle.spirv.json --out bench/out/scratch/dawn-replacement-readiness-report.json --json`
- `python3 bench/gates/schema_gate.py`
- `python3 bench/gates/dawn_replacement_frontier_gate.py`
- `git diff --check`

## 2026-06-30 — Browser claim reuse evidence composes diagnostic blockers

The repeated-window Chromium browser claim artifacts under
`browser/chromium/artifacts/20260309T015157Z/browser-claim/` now compose into a
verified diagnostic browser release bundle and a browser runtime frontier
bundle under `bench/out/scratch/browser-claim-reuse-20260309T015157Z/`. The
release bundle checker still fails closed for release candidates, but diagnostic
release bundles can now carry diagnostic promotion receipts as claim blockers
instead of rejecting the bundle before the frontier layer can name the blocker.

The refreshed Dawn replacement readiness report now points the Chromium browser
row at
`bench/out/scratch/browser-claim-reuse-20260309T015157Z/browser-runtime-frontier-bundle.json`.
That bundle passes component checks and file/hash verification while preserving
the remaining browser blockers: claim-policy promotion evidence, hidden-fallback
promotion evidence, source-kernel structural receipts, dispatch-shape parity,
and `releaseStatus=diagnostic`.

Touched:

- `bench/tools/check_browser_release_artifact_bundle.py`
- `bench/tools/check_browser_runtime_frontier_bundle.py`
- `bench/tests/test_browser_release_artifact_bundle.py`
- `bench/tests/test_browser_runtime_frontier_bundle.py`
- `bench/out/scratch/browser-claim-reuse-20260309T015157Z/browser-release-artifact-bundle.json`
- `bench/out/scratch/browser-claim-reuse-20260309T015157Z/browser-runtime-frontier-bundle.json`
- `bench/out/scratch/dawn-replacement-readiness-report.json`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 -m py_compile bench/tools/check_browser_release_artifact_bundle.py bench/tools/check_browser_runtime_frontier_bundle.py bench/tests/test_browser_release_artifact_bundle.py bench/tests/test_browser_runtime_frontier_bundle.py`
- `PYTHONPATH=bench:. python3 -m unittest bench.tests.test_browser_release_artifact_bundle bench.tests.test_browser_runtime_frontier_bundle`
- Local fixture runner for `bench.tests.test_browser_release_artifact_bundle`
  module-level tests, because `pytest` is not installed in this environment.
- `python3 bench/tools/build_browser_release_artifact_bundle.py --bundle-id browser-release-diagnostic-reuse-20260309T015157Z --release-status diagnostic --browser-binary browser/chromium/src/out/fawn_release/chrome-wrapper --doe-runtime runtime/zig/zig-out/lib/libwebgpu_doe.so --shader-compiler runtime/zig/zig-out/bin/doe-zig-runtime --claim-report bench/out/scratch/browser-claim-reuse-20260309T015157Z/browser_claim_report.json --promotion-receipt bench/out/scratch/browser-claim-reuse-20260309T015157Z/browser_claim_report.promotion-receipt.json --verify-files-root . --out bench/out/scratch/browser-claim-reuse-20260309T015157Z/browser-release-artifact-bundle.json`
- `python3 bench/tools/check_browser_release_artifact_bundle.py --bundle bench/out/scratch/browser-claim-reuse-20260309T015157Z/browser-release-artifact-bundle.json --verify-files-root . --json`
- `python3 bench/tools/check_browser_runtime_frontier_bundle.py --runtime-identity examples/browser-runtime-identity.selector.sample.json --claim-promotion-receipt bench/out/scratch/browser-claim-reuse-20260309T015157Z/browser_claim_report.promotion-receipt.json --release-artifact-bundle bench/out/scratch/browser-claim-reuse-20260309T015157Z/browser-release-artifact-bundle.json --verify-files-root . --out bench/out/scratch/browser-claim-reuse-20260309T015157Z/browser-runtime-frontier-bundle.json --json`
- `python3 bench/tools/build_dawn_replacement_readiness_report.py --browser-frontier-bundle bench/out/scratch/browser-claim-reuse-20260309T015157Z/browser-runtime-frontier-bundle.json --tint-frontier-bundle bench/out/scratch/tint-compiler-frontier-bundle.spirv.json --out bench/out/scratch/dawn-replacement-readiness-report.json --json`
- `python3 bench/gates/schema_gate.py`
- `python3 bench/gates/dawn_replacement_frontier_gate.py`
- `git diff --check`

## 2026-06-30 — Browser release bundle sample verifies local artifacts

The browser release artifact bundle sample now points at local, existing
Chromium wrapper, Doe runtime, and shader-compiler artifacts and passes
file/hash verification under `--verify-files-root .`. The composed browser
runtime frontier sample was regenerated with that verification root, so its
release-bundle component now records verified artifact evidence while still
blocking browser runtime claimability on `releaseStatus=diagnostic`.

The Dawn replacement readiness rollup was refreshed from the verified browser
frontier bundle plus the current Tint compiler frontier bundle. The Chromium
browser row therefore no longer has stale missing-file/hash-mismatch release
bundle evidence in the local sample path; the remaining browser frontier blocker
is publishing a real release-candidate browser bundle rather than a diagnostic
sample.

Touched:

- `examples/browser-release-artifact-bundle.sample.json`
- `examples/browser-runtime-frontier-bundle.sample.json`
- `bench/out/scratch/dawn-replacement-readiness-report.json`
- `bench/tests/test_browser_runtime_frontier_bundle.py`
- `docs/status/runtime-backends-and-bench.md`

Verified:

- `python3 bench/tools/build_browser_release_artifact_bundle.py --bundle-id browser-release-diagnostic-sample-v1 --release-status diagnostic --browser-binary browser/chromium/src/out/fawn_release/chrome-wrapper --doe-runtime runtime/zig/zig-out/lib/libwebgpu_doe.so --shader-compiler runtime/zig/zig-out/bin/doe-zig-runtime --claim-report examples/browser-claim-report.sample.json --promotion-receipt examples/browser-claim-promotion-receipt.sample.json --verify-files-root . --out examples/browser-release-artifact-bundle.sample.json`
- `python3 bench/tools/check_browser_release_artifact_bundle.py --bundle examples/browser-release-artifact-bundle.sample.json --verify-files-root . --json`
- `python3 bench/tools/check_browser_runtime_frontier_bundle.py --runtime-identity examples/browser-runtime-identity.selector.sample.json --claim-promotion-receipt examples/browser-claim-promotion-receipt.sample.json --release-artifact-bundle examples/browser-release-artifact-bundle.sample.json --verify-files-root . --out examples/browser-runtime-frontier-bundle.sample.json --json`
- `python3 bench/tools/build_dawn_replacement_readiness_report.py --browser-frontier-bundle examples/browser-runtime-frontier-bundle.sample.json --tint-frontier-bundle bench/out/scratch/tint-compiler-frontier-bundle.spirv.json --out bench/out/scratch/dawn-replacement-readiness-report.json --json`
- `python3 -m py_compile bench/tests/test_browser_runtime_frontier_bundle.py bench/tools/check_browser_runtime_frontier_bundle.py bench/tools/build_browser_release_artifact_bundle.py bench/tools/check_browser_release_artifact_bundle.py`
- `PYTHONPATH=bench:. python3 -m unittest bench.tests.test_browser_release_artifact_bundle bench.tests.test_browser_runtime_frontier_bundle bench.tests.test_dawn_replacement_readiness_report`
- `python3 bench/gates/schema_gate.py`
- `python3 bench/gates/dawn_replacement_frontier_gate.py`
- `git diff --check`

## 2026-06-30 — Browser runtime frontier bundle composes claim blockers

`bench/tools/check_browser_runtime_frontier_bundle.py` now composes browser
runtime identity, browser claim-promotion, browser release-bundle, and bundled
browser claim-report evidence into a composed Chromium runtime frontier receipt.
The sample bundle is registered with the schema gate and remains diagnostic: it
passes the component receipt checks but still requires release-candidate
Chromium build evidence before the browser runtime frontier row can be
promoted.

The optional blocking runner now exposes
`--with-browser-runtime-frontier-bundle-gate`. Use `--require-claimable` only
for claim lanes; diagnostic/frontier audits should preserve the claim blockers
in the emitted bundle.

Claimable browser frontier bundles now require the browser release artifact
bundle's referenced files and hashes to verify under `--verify-files-root`.
Without that root, the composed receipt records
`artifactVerification.verified=false` and cannot clear Chromium release-build
evidence even if a release bundle labels itself as a release candidate.
The Dawn replacement readiness report now reads the composed browser frontier
bundle for the browser row, so cleared runtime-identity and structural receipt
evidence no longer remains listed as active browser blockers.
That report is now schema-registered and carries `frontierBundleEvidence` for
the browser row, including the release-bundle status and artifact-verification
summary from the composed frontier bundle. See
`examples/dawn-replacement-readiness-report.sample.json` for the current
contract shape.
The browser frontier bundle also emits a grouped `claimBlockerSummary`, so the
readiness row distinguishes release-status blockers from file/hash verification
blockers when generated bundles are used.
The readiness builder also accepts `--browser-frontier-bundle`, so generated
Chromium runtime frontier bundles can drive local readiness rollups without
editing the frontier manifest.
`build_browser_release_artifact_bundle.py` now also fails closed for
`release_candidate` output unless the bundle verifies under `--verify-files-root`,
so release-candidate browser evidence cannot be minted without concrete
artifact files and matching hashes.
The standalone browser release-bundle checker and optional blocking runner now
also expose release-candidate mode, allowing claim lanes to reject diagnostic
browser release bundles before they reach the composed frontier bundle.

Browser claim reports now carry `structuralReceipts` summaries generated from
the repeated-window browser superset checker outputs. The frontier bundle
checks those summaries for source-command identity, source-kernel dispatch
coverage, dispatch-shape parity, and passing checker reports before allowing the
browser structural-equivalence blocker to clear.

`bench/tools/build_browser_runtime_identity.py` now extracts selector-backed
`browser_runtime_identity` artifacts from browser reports with Chromium
runtime-selection evidence. The selector sample is schema-registered and lets
the composed browser frontier bundle use Doe-active, no-hidden-fallback runtime
identity evidence instead of the wrapper-probe sample.

## 2026-06-29 — Dawn replacement frontier is gate-backed

`config/dawn-replacement-frontier.json` now names the Dawn/Tint replacement
frontier across native Metal, Vulkan, D3D12, Node package, Bun package, Deno
package, Chromium browser, WGSL/Tint compiler, CTS conformance, drop-in ABI,
and release claim indexing. The matching schema and
`bench/gates/dawn_replacement_frontier_gate.py` require each row to carry
evidence paths or public claim-index entries. Blocker codes now live in the same
manifest with exit criteria, and the gate rejects undefined or unused blockers.

The gate only allows a frontier row to be `claimAllowed=true` when it references
public claim-index entries that are claim-indexed, comparable, claimable, and
carry claim sidecar paths. Universal Dawn replacement remains blocked while any
product frontier row is diagnostic, missing, unsupported, or covered-only; the
release evidence row must stay covered or claimable. The frontier intentionally
excludes the spatial-retargeting lane.

The canonical blocking runner now also enables the native backend coverage
matrix check by default. That default validates required Metal, Vulkan, and
D3D12 coverage rows without requiring local generated evidence files; lanes that
publish evidence can still pass `--native-backend-coverage-evidence-root` for
artifact-kind verification.

## 2026-06-29 — wgpu adapter no longer emits mock evidence

`bench/native-compare/wgpu_benchmark_adapter.py` now fails closed unless a real
`--wgpu-runner` is available. The previous placeholder trace writer has been
removed, so three-way Doe/Dawn/wgpu work cannot satisfy compare tooling with
synthetic timing or mock adapter metadata. The adapter also requires the runner
to emit both trace metadata and JSONL trace outputs before returning success.

## 2026-06-29 — Tool surface exports are gate-backed

`config/tool-surfaces.json` now lists the full public `doe-gpu` package
entrypoint set, including Bun, Deno, and `node-webgpu` entry files. The new
`bench/gates/tool_surface_gate.py` validates declared surface paths and checks
the public package surface against `packages/doe-gpu/package.json` export
targets, so public package exports cannot drift from the manifest silently.

The canonical blocking runner invokes the tool-surface gate by default. Package
docs now name `node-webgpu` alongside the other documented subpath entrypoints.

## 2026-06-29 — Public claim index is gate-backed

`reports/claim-index.json` now has a schema target and a blocking semantic gate:
`bench/gates/claim_index_gate.py`. Claim-indexed rows must carry
`comparisonStatus=comparable`, `claimStatus=claimable`, and a claim sidecar
path. Diagnostic and status-only rows cannot be marked claimable. The gate also
checks local compare/claim artifacts when they are present under the indexed
paths while allowing bulky generated `bench/out` artifacts to remain absent from
the tracked tree.

The Apple browser ORT row is now explicitly diagnostic in the claim index and
the README SVG summary shows the ORT row as a mixed Node/Bun claim plus browser
diagnostic boundary rather than a browser speed claim.

## 2026-06-27 — Browser Chromium/Dawn versus Fawn/Doe fairness refresh

The raw Chromium browser lane now separates strict source-comparable browser
rows from directional/component diagnostics in the score sidecar. Projection
manifests record browser-executed workload parameters, including upload byte
counts, texture dimensions, mip counts, and compute projection class. Compute
rows can now promote to `source_kernel_dispatch_v1` only when the manifest
links the browser row to the source command file, WGSL kernel file, hashes,
dispatch shape, repeat count, warmup dispatch count, and storage bindings.
Directional upload rows remain visible for bottleneck diagnosis but are
excluded from `strictComparable`; oversized browser uploads stay `l0_only`;
compute rows that do not execute source shader semantics remain component-only.

The browser score sidecar now follows the Doe-vs-Dawn compare convention:
Doe is the default baseline, Dawn is the default comparison, and positive
`comparisonDeltaPercent` / `baselineLeadPercent` means the baseline mode is
faster. For the default Chromium runtime-swap score, positive therefore means
Doe beat Dawn.

The layered runner now records runtime order and supports grouped, paired, or
paired-balanced mode scheduling. Grouped mode preserves the historical
all-Dawn/all-Doe pass. Paired mode alternates runtimes per row and records the
schedule unit in `modeRunDetails`. Paired-balanced mode runs both row orders and
averages numeric metrics per runtime, so order-sensitive reports have
receipt-visible order-balance evidence. Non-grouped schedules execute
strict-comparable rows before component diagnostics so component probes do not
precondition strict browser evidence.

Fresh diagnostic artifacts from the grouped and reverse-order same-Fawn runs,
the order-balanced full Apple browser run, and the stock Chrome versus Fawn/Doe
consumer diagnostic, live under:

- `browser/chromium/artifacts/20260627T172252Z/`
- `browser/chromium/artifacts/20260627T172452Z/`
- `browser/chromium/artifacts/20260627TfullPairedBalancedStrictFirstZ/`
- `browser/chromium/artifacts/20260627T172555Z/`

Status: grouped same-Fawn reports remain order-sensitive diagnostics. The
strict-first paired-balanced same-Fawn Apple browser report is the current fair
raw Chromium runtime-swap diagnostic. The stock Chrome versus Fawn/Doe artifact
is also diagnostic because the compared browser versions/build classes do not
match and release-class Fawn build evidence is not present.

## 2026-06-26 — Apple Metal Doe-baseline compare refresh

The macOS Metal compare lane was refreshed from new receipts with Doe as the
baseline and Dawn as the comparison across native strict, native release, Node
package, Bun package, Node ORT, Bun ORT, and browser ORT. The promoted native,
package, and Node/Bun ORT reports are claimable under their configured
claimability modes; browser ORT remains a strict comparable browser-lane
receipt with claimability intentionally off in its config.

Stack fixes from the refresh:

- ORT Node/Bun reports now use trace-meta process wall as the selected
  process-wall timing boundary, rather than Python wrapper wall.
- successful vendor-node traces emit `workloadUnitWallSource` so the selected
  wall-time source is explicit in receipts.
- Bun's WebGPU FFI adapter identity reports Darwin Metal subgroup bounds that
  match the Dawn-backed Bun provider on this host.
- the browser ORT harness resolves the existing lane-volume Transformers.js
  build and records browser ORT source identity hashes in trace metadata.
- the Node package command encoder materializes lazy dispatch/copy commands at
  `finish()` so submit telemetry and command-buffer identity do not diverge.

Fresh compare and claim artifacts:

- native strict compare:
  `bench/out/apple-metal/compare/20260626T183822Z/dawn-vs-doe.apple.metal.compare.json`
- native strict claim:
  `bench/out/apple-metal/compare/20260626T183822Z/dawn-vs-doe.apple.metal.claim.json`
- native release compare:
  `bench/out/apple-metal/release/20260626T184854Z/dawn-vs-doe.apple.metal.release.json`
- native release claim:
  `bench/out/apple-metal/release/20260626T184854Z/dawn-vs-doe.apple.metal.release.claim.json`
- Node package compare:
  `bench/out/apple-metal/20260626T185557Z/gemma64.node-package.warm.ir.compare.json`
- Node package claim:
  `bench/out/apple-metal/20260626T185557Z/gemma64.node-package.warm.ir.claim.json`
- Bun package compare:
  `bench/out/apple-metal/20260626T185725Z/gemma64.bun-package.warm.ir.compare.json`
- Bun package claim:
  `bench/out/apple-metal/20260626T185725Z/gemma64.bun-package.warm.ir.claim.json`
- Node ORT compare:
  `bench/out/apple-metal-ort-node/20260626T192328Z/gemma270m.compare.json`
- Node ORT claim:
  `bench/out/apple-metal-ort-node/20260626T192328Z/gemma270m.claim.json`
- Bun ORT compare:
  `bench/out/apple-metal-ort-bun/20260626T192011Z/gemma270m-prefill32-decode1.compare.json`
- Bun ORT claim:
  `bench/out/apple-metal-ort-bun/20260626T192011Z/gemma270m-prefill32-decode1.claim.json`
- browser ORT compare:
  `bench/out/browser-ort-webgpu-compare/20260626T193131Z/browser.compare.json`

Validation run against the fresh artifacts:

- `compare_output_partition_gate.py`
- `comparability_coherence_gate.py --require-pass`
- `structural_equivalence_gate.py --require-all-pass`
- `claim_gate.py` for native strict, native release, Node package, Bun package,
  Node ORT, and Bun ORT

The README backend evidence summary now references these Apple Metal reports
through `reports/claim-index.json` and shows AMD Vulkan with its current
diagnostic/status boundary in `assets/readme/backend-evidence-summary.svg`.

## 2026-06-18 — AMD Vulkan Node and Bun package readback audit

The AMD Vulkan package resident decode anchors are diagnostic under the current
fairness contract. The historical Node and Bun compare/claim sidecars remain
useful evidence, but they are not clean Doe-wins-Dawn product claims after the
effective readback-path audit. Regenerated strict compares from the same
receipts now block comparability because the Doe side used
`native-map-read-copy-unmap` while the Dawn package side used `mapAsync`.
New package trace metadata emits `packageEffectiveReadbackPaths` so fresh
receipts record the actual path taken. Older package receipts are still audited
from readback timing buckets.
The claim gate now requires that effective-path list on successful Doe package
trace metadata before a package row can be treated as claimable.

The historical workload manifest recorded by these anchors is preserved through
`config/workload-manifest-archives.json` and
`bench/workloads/archive/workloads.package.inference.prepared.20260614.json`.
These are package-surface, prepared-session, resident-buffer-load artifacts over
`inference_gemma3_270m_decode_1tok`, with operation-timing compare reports and
local claim sidecars.

Node anchor:

- compare:
  `bench/out/amd-vulkan/20260614T194937Z/gemma270m.node-package.decode.resident.warm.ir.compare.json`
- claim:
  `bench/out/amd-vulkan/20260614T194937Z/gemma270m.node-package.decode.resident.warm.ir.claim.json`
- regenerated post-hoc claim from the same receipts:
  `/tmp/doe-node-package-readback-current.claim.json`
- result:
  under the current comparability code, regenerated output is
  `comparisonStatus=diagnostic`, `claimStatus=diagnostic` because effective
  readback paths differ. The checked-in sidecar is historical evidence, not a
  current fair-readback product claim.

Bun anchor:

- compare:
  `bench/out/amd-vulkan/20260608T205740Z/gemma270m.bun-package.decode.resident.warm.ir.clean-process-warm.compare.json`
- claim:
  `bench/out/amd-vulkan/20260608T205740Z/gemma270m.bun-package.decode.resident.warm.ir.clean-process-warm.claim.json`
- regenerated post-hoc claim from the same receipts:
  `/tmp/doe-bun-package-readback-current.claim.json`
- result:
  the historical checked-in sidecar says `claimStatus=claimable`, but current
  comparability code and benchmark policy regenerate this lane as
  `comparisonStatus=diagnostic`, `claimStatus=diagnostic`. The old sidecar is
  also stale with respect to the current benchmark policy hash.
- fairness note:
  this historical Bun anchor carries a selected-timing win that trips the
  configured suspicious-speedup policy and also has effective readback-path
  mismatch. Treat it as diagnostic until the compared paths are structurally
  fair.

Fresh promotion against the current tracked workload manifest remains blocked
from this host. The claim reports above are valid local claim reports, but the
promotion gate still rejects them when it requires the current
`bench/workloads/workloads.package.inference.prepared.json` hash:
the receipts carry
`33df5777c08ba8d8cd39cf4834387c52d820052e801ed38df5899038c9bddbcd`, while
the current tracked manifest is
`7d6d1152fe78b002609e8a4e022a320fe4bf3bc78abed476ce4a93db91a623bf`.
That freshness blocker is independent of the readback-path blocker. The current
manifest also carries newer plan, compatibility-command, and source-IR hashes,
so these anchors must not be promoted as current-manifest release evidence until
fresh AMD Vulkan package receipts are generated with matched effective readback
paths.

The hardware blocker is also unchanged: `vulkaninfo --summary` exposes only
llvmpipe because RADV cannot open `/dev/dri/renderD128` with
`VK_ERROR_INCOMPATIBLE_DRIVER`, and PID `3681148` is still in `Ds` state while
holding `/dev/dri/renderD128`. Fresh AMD Vulkan Node/Bun receipts need that
render node cleared before the current-manifest promotion gate can pass.

Local validation:

- regenerated Node strict compare:
  `/tmp/doe-node-package-readback-current.compare.json`
- regenerated Node local claim:
  `/tmp/doe-node-package-readback-current.claim.json`
- regenerated Bun strict compare:
  `/tmp/doe-bun-package-readback-current.compare.json`
- regenerated Bun local claim:
  `/tmp/doe-bun-package-readback-current.claim.json`
- `python3 bench/gates/claim_gate.py --report /tmp/doe-node-package-readback-current.compare.json --claim-report /tmp/doe-node-package-readback-current.claim.json --require-comparison-status diagnostic --require-claim-status diagnostic --require-claimability-mode local --require-min-timed-samples 15 --config bench/native-compare/compare.config.amd.vulkan.gemma270m.node-package.decode.resident.warm.ir.json`
- `python3 bench/gates/claim_gate.py --report /tmp/doe-bun-package-readback-current.compare.json --claim-report /tmp/doe-bun-package-readback-current.claim.json --require-comparison-status diagnostic --require-claim-status diagnostic --require-claimability-mode local --require-min-timed-samples 15 --config bench/native-compare/compare.config.amd.vulkan.gemma270m.bun-package.decode.resident.warm.ir.json`

Expected current-promotion rejection:

- `python3 bench/gates/claim_gate.py --report bench/out/amd-vulkan/20260614T194937Z/gemma270m.node-package.decode.resident.warm.ir.compare.json --claim-report bench/out/amd-vulkan/20260614T194937Z/gemma270m.node-package.decode.resident.warm.ir.claim.json --require-comparison-status comparable --require-claim-status claimable --require-claimability-mode local --require-min-timed-samples 15 --config bench/native-compare/compare.config.amd.vulkan.gemma270m.node-package.decode.resident.warm.ir.json --expected-workload-contract bench/workloads/workloads.package.inference.prepared.json --require-workload-contract-hash`
- `vulkaninfo --summary`
- `ps -o pid,ppid,stat,etime,cmd -p 3681148`
- `fuser -v /dev/dri/renderD128`

## 2026-06-17 — Delegate queue wait guard is explicit evidence

The `doe-zig-runtime` CLI now exposes
`--webgpu-ffi-queue-wait-timeout-ns` for WebGPU FFI delegate queue waits. The
guard is wired through the backend interface to Dawn/WebKit delegate lanes and
is emitted as `webgpuFfiQueueWaitTimeoutNs` in trace-meta when that delegate
path is active. Direct Doe Vulkan/Metal/D3D12 lanes do not claim this field,
because their native wait primitives are not the WebGPU FFI wait loop.

The AMD Vulkan release preset declares the guard in its command templates so a
delegate queue wait limit is visible in the workload receipt instead of hidden
inside runtime code. A focused `compute_workgroup_atomic_1024` rerun completed
on both sides and produced post-hoc compare and claim artifacts:

- compare:
  `bench/out/amd-vulkan/20260617T140952Z/dawn-vs-doe.amd.vulkan.release.atomic-current.compare.json`
- claim:
  `bench/out/amd-vulkan/20260617T140952Z/dawn-vs-doe.amd.vulkan.release.atomic-current.claim.json`

This is not the full AMD Vulkan package history. Earlier Node and Bun package
compare receipts already exist. The stricter package status from June 8 split
Bun and Node at that point, but the June 18 package anchor section above records
the later Node and Bun anchors plus the current effective-readback and
current-manifest blockers. Use these artifacts for the June 17 package-lane
context:

- historical Node package compare:
  `bench/out/amd-vulkan/20260410T235522Z/gemma270m.node-package.ir.compare.json`
- historical Bun package compare:
  `bench/out/amd-vulkan/20260410T235541Z/gemma270m.bun-package.ir.compare.json`
- historical Bun package claim:
  `bench/out/amd-vulkan/20260608T205740Z/gemma270m.bun-package.decode.resident.warm.ir.clean-process-warm.claim.json`
- June 8 Node package diagnostic claim sidecar:
  `bench/out/amd-vulkan/20260608T205217Z/gemma270m.node-package.decode.resident.warm.ir.strict-scope-audit.claim.json`

The host blocker applies to fresh strict AMD release promotion from this shell,
not to the existence of prior AMD Vulkan package evidence. `vulkaninfo` exposes
only llvmpipe after RADV fails to open `/dev/dri/renderD128`, and a stale
DiffusionGemma/Doppler benchmark process remains in uninterruptible sleep while
holding the render node's reported VRAM allocation. Broader rerun promotion
must wait for a clean AMD render node before the release lane is updated.

Validation:

- `zig build -Doptimize=ReleaseFast` from `runtime/zig`
- focused AMD Vulkan release baseline and comparison runs with
  `--workload-filter compute_workgroup_atomic_1024`
- post-hoc compare and release claim over the focused receipts listed above
- `python3 bench/gates/schema_gate.py`
- `python3 -m unittest bench.tests.test_native_compare_config_support bench.tests.test_compare_assessment bench.tests.test_run_artifact`
- `zig build test` from `runtime/zig`
- `python3 -m unittest discover bench/tests`
- host-blocked strict AMD preflight:
  `python3 bench/runners/run_release_pipeline.py --config bench/native-compare/compare.config.amd.vulkan.release.json --strict-amd-vulkan --with-claim-gate --no-compare-html-output`

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

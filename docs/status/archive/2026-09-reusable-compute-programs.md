# Reusable compute programs

## Current boundary

Vulkan query resolution converts physical ticks to nanoseconds on the GPU.
Query-owned scratch and cached conversion pipelines support ordinary WebGPU
and retained programs, partial resolves, and later GPU consumers. The CPU query
retrieval and forced per-resolve wait are removed. Policy:
`config/vulkan-timestamp-policy.json`. Receipt version 3 identifies normalized
Doe units; historical receipts retain their original interpretation. Other Doe
backends and old addons/libraries fail timed preparation explicitly.

The prior-library units failure is retained in
`bench/out/compute-program/20260905-query-nanoseconds-failure/`.
The production shader passes an independent integer oracle covering fractional
periods, large counters, masking, and overflow; physical query intervals are
checked against host completion bounds. Node, Bun, and Electron qualify from
the same retained archives under
`bench/out/compute-program/20260905-query-nanoseconds-package/summary.json`.
The qualifier includes Bun's root FFI entry and program query-destruction,
cancellation, rollback, update, and interleaving regressions.

Current application evidence is
`bench/out/compute-program/20260905-query-nanoseconds-matrix/summary.json`;
verify with its retained `policy.json`. Native journals and SPIR-V checks are
under `bench/out/compute-program/20260905-query-nanoseconds-native/`.
The matrix retains ordinary Doe, prepared Doe, Dawn, and Deno/wgpu with frozen
oracles and complete invocation timing. Performance remains diagnostic;
large Deno host ratios remain suspicious. Requested allocation accounting
excludes internal query scratch and peak GPU memory. No independent adoption
or Metal transfer is inferred.

The older calibrated matrix and package remain under
`20260905-timed-program-final-matrix` and `20260905-timed-program-final-package`.
The earlier `20260905-gpu-timing-matrix` used an uninitialized native period
and mislabeled Deno/wgpu ticks: its GPU durations are invalid despite its
historical gate result. Device selection now reads physical calibration before
query creation. The gate retains that physical profile and separately checks
Deno/wgpu raw-tick calibration. Upstream audit sources remain under
`20260905-timestamp-source-audit` and `20260905-timestamp-wgpu-source-audit`.
Initial stage/quantization probes under `20260905-program-gpu-timing-probe`
and `20260905-program-gpu-timing-bottom` remain diagnostic.

Timestamp pass creation now uses the pinned WebGPU C layout in the addon.
The original crashing binary and reproduction remain in
`bench/out/compute-program/20260905-timestamp-abi-failure/`, with `SHA256SUMS`.
The repair shares the compute/render timestamp structure, sends render draw
limits through the canonical chained extension, and fixes the corresponding
Bun FFI render layouts. Bun FFI also preserves compute pass timestamp
descriptors and labels. Query resolves invalidate host buffer shadows.
`build:addon` compares pass layouts against the pinned header before linking;
its source list now comes from `binding.gyp`, including the program bridge.
This is an ABI correction with unchanged public descriptors and receipt schema.
Rebuild the addon before using timestamps with the pinned runtime.
The physical timestamp regression checks repeated pass boundaries and exact
shader output. Fresh retained-package qualification is recorded in
`bench/out/compute-program/20260905-query-nanoseconds-package/summary.json`.
The retained harness exercises explicit native selection on each host and
Bun's root FFI entry. The earlier all-host attempt retains its invalid
harness import under `20260905-timestamp-all-hosts-retained-package`.

The declared HoloScript LIF simulation now runs through the same program matrix
as the image and heat examples. Its pinned shader, upstream CPU twin, strict
membrane tolerances, and exact spike observables are retained in
`bench/out/compute-program/20260905-holoscript-lif-final-fixture/fixture.json`.
All providers batch the same ticks and execute the same output-packing pass.
This adapts orchestration explicitly; it does not replace the unchanged
application compatibility lane. The matrix retains diagnostic classification;
inspect individual tail and CPU rows before interpreting an advantage.
The unusually large Deno/wgpu ratios remain suspicious host comparisons.

The additive fixed-shape API and lifetime contract are documented in
[`reusable-compute-programs.md`](../../reusable-compute-programs.md).
Explicit `gpu-recorded` execution retains compiled Vulkan command buffers,
barriers, pipeline state, and descriptor pools. `native-recorded` retains host
recordings; ordinary WebGPU remains the control. Native buffer identity checks
and private pipeline ownership protect replay from stale allocations and cache
replacement. Interleaved execution, updates, rollback, and device destruction
are covered by the physical regression. Compute pipeline release now honors
retained references.
Replay now uses one shared conservative shader barrier, preserving the separate
indirect-argument dependency. Cancellation during readback mapping discards
output and releases the mapping; runs without a signal omit the cancellation
event-loop yield. Physical ordinary and recorded regressions cover these paths.
Transactional updates retain unchanged resource keys; the native contract check
rejects old binaries. Vulkan clears execute in submission order, and buffer
shadow validity follows recorded writes. Vulkan buffer copies now remain on
the GPU queue across separate submissions. The UMAP second-epoch failure is
fixed with an independent integer regression; its unchanged upstream suite
passes in `bench/out/external-projects/umap-gpu/execution-ownership-20260905-external-reuse/reproduction.json`.
The original failed receipt remains under `execution-ownership-20260905`.
No proof-elimination claim is made.

External compatibility reproduction also passes for the pinned HoloScript LIF
and EA MNIST harnesses. Receipts are under
`bench/out/external-projects/holoscript-snn-webgpu/execution-ownership-20260905-external-reuse/reproduction.json`
and
`bench/out/external-projects/electronicarts-cpp-ml-intro/execution-ownership-20260905-external-reuse/reproduction.json`.
These preserve each harness's existing oracle and diagnostic classification;
they do not establish prepared-plan performance or external adoption.

Provider qualification uses the same retained wrapper and platform package
archives across Node, Bun, and Electron main processes. The local artifact is
`bench/out/compute-program/20260905-query-nanoseconds-package/summary.json`.
This is physical AMD Vulkan qualification of a local candidate; registry
publication, native embedding, Metal, and D3D12 do not inherit it.

## Active acceptance gaps

GPU recording is implemented for Vulkan; Metal transfer remains open.
Changed programs currently rebuild their native recording and private pipeline
state while retaining unchanged public resources. Further reuse must preserve
the same lifetime checks.
The application matrix must establish an advantage over the strongest eligible
incumbent; a host-recording interface alone does not establish that advantage.
The examples and adapted external fixture do not complete the external
application portfolio or independent repeat-use gates. Measured peak device
memory, physical driver
loss and recovery, and Apple Metal transfer remain unevidenced in this lane.

## Ground truth

- Policies: `config/compute-program-evaluation.json` and
  `config/compute-program-external-evaluation.json`.
- Application evidence: `bench/out/compute-program/20260905-external-reuse-final/summary.json`.
  Verification uses its retained `policy.json`.
- Package evidence: `bench/out/compute-program/20260905-query-nanoseconds-package/summary.json`.
- Native trace and SPIR-V validation:
  `bench/out/compute-program/20260905-external-reuse-native-validation/image_edges.json`,
  `bench/out/compute-program/20260905-external-reuse-native-validation/heat_diffusion.json`,
  and `bench/out/compute-program/20260905-external-reuse-native-validation/holoscript_lif.json`.
  Both validation surfaces share `bench/lib/native_program_replay.py`; standalone
  invocation remains compatible through `program verify-native`.
- Evaluation policy migration: schema version 2 declares the prepared execution
  mode and nearest-rank percentile method. Python and JavaScript parity is
  tested; legacy comparison callers retain their estimator. Matrices now retain
  implementation sources and policy bytes alongside native binaries and outputs.
- Policy schema version 3 binds external fixtures; evaluation run schema
  version 2 records multiple input paths and the retained fixture. Historical
  versions remain readable. The fixture gate validates source references,
  input extents, and complete exact or strict numerical checks. Fixture
  preparation is discoverable through `program prepare-lif`.
- Allocation policy: `config/vulkan-buffer-memory-policy.json`; the earlier
  `bench/out/compute-program/20260905-final/summary.json` retains the prior
  allocation treatment without promotion.
- Regression: `packages/doe-gpu/test/integration/test-integration-compute-program.js`.
- Blocking gate behavior: [`process.md`](../../process.md).

History remains under [`archive/`](./); current measurements live only in
their artifacts.

## Compiler diagnostics and cache ownership at native pipeline reuse

Preserved from the live status after commit `301be4f5d`.

Vulkan compute and descriptor cache insertion now restores the active owner if
allocation fails. The regression also retries the insertion successfully.
The original ownership-loss reproduction is retained under
`bench/out/compute-program/20260905-vulkan-cache-ownership-failure/`.
The repaired source and successful native test log are retained under
`bench/out/compute-program/20260905-vulkan-cache-ownership-correction/`.

## Compiler corrections and package entrypoints

Vulkan shader wrappers now preserve parser/semantic causes and WGSL locations
instead of flattening them to `ShaderCompileFailed`. The native ABI and
compilation-info fields are unchanged; consumers need the rebuilt library.
Earlier receipts keep their original diagnostics. The reproduction is retained
under `bench/out/compute-program/20260905-compiler-diagnostics-failure/`.
The repaired output and successful native/package test logs are retained under
`bench/out/compute-program/20260905-compiler-diagnostics-correction/`.
Graphics translation emits each stage once, transfers owned SPIR-V directly,
and releases reflection allocations. The allocation-accounted failing case is
under `bench/out/compute-program/20260905-graphics-translation-memory-failure/accounted-case/`.

The package's first-kernel host entrypoints share WGSL, output validation, and
guaranteed device teardown. Electron retains its mapped-range probe. Their
receipt shape and workload hashes are unchanged. Compute declarations and
closed bundles share recursive JSON key ordering with historical hashes pinned
by the package contract tests. The public README starts with provider selection
and documents opt-in resident execution separately.


## Pipeline identity correction predecessor

## Buffer publication and replacement

Buffer registry capacity is reserved before allocation and GPU initialization.
Resizing drains prior work and keeps the old allocation until replacement
succeeds. Descriptor, receipt, and native ABI contracts are unchanged. The
original physical failure and corrected allocation/retry evidence are retained
under `bench/out/compute-program/20260905-buffer-publication-failure/` and
`bench/out/compute-program/20260905-buffer-publication-correction/`.

## Native pipeline reuse

Vulkan recordings now share live compiled pipelines through a device-owned
registry. Exact SPIR-V, entry-point, layout, and subgroup checks govern sharing;
descriptor pools remain private. The owner retains the creation layout for
older Vulkan implementations and destroys the pipeline at its last release.
Shader modules are temporary creation inputs. The build contract is
`config/vulkan-compute-pipeline-policy.json`; package and receipt versions keep
their meanings. Native handles, output, changed layouts/shaders, allocation
failures, creator teardown, and device isolation pass under both policy modes.
Source, policy controls, and logs are retained under
`bench/out/compute-program/20260905-shared-pipeline-native/`.


## Retained status before portable qualification

## Application execution from qualified packages

The existing evaluator accepts `--package-qualification` to install and execute
the exact archives retained by `program qualify-package`. Every provider uses
the installed executor; Doe loads its native library from the same installation.
Archive, installed-file, library, and source-parity checks accompany evaluation
artifact version 5. Workspace evaluation remains explicit and cannot satisfy
installed-package evidence.

The verified invocation-local matrix is
`bench/out/compute-program/20260905-installed-package-matrix/summary.json`.
The full frozen resident sequence also passes through that installation across
fresh Doe processes; reports are under
`bench/out/compute-program/20260905-installed-package-resident/`.
Dawn and wgpu still fail the unchanged resident oracle, so their resident
comparison remains inadmissible. This is repetition on the same AMD host,
not independent reproduction. Validation records are under
`bench/out/compute-program/20260905-installed-package-correction/`.

### Resident numerical correction

SPIR-V compute lowering now applies the versioned scalar arithmetic policy in
`config/spirv-compute-arithmetic-policy.json`. Ordinary and recorded Doe pass the
unchanged continuous HoloScript WGSL, initialization inputs, frozen sequence,
membrane tolerances, and exact spike oracle. Validated full-sequence reports are
under `bench/out/compute-program/20260905-resident-fusion-sequence/`; native
recording and SPIR-V verification live with the correction evidence.

The original identical failing provider bytes remain under
`bench/out/compute-program/20260905-resident-sequence-numerical-controls/`.
Host arithmetic localization and a deliberately rewritten-shader diagnostic are
retained separately. Final acceptance uses the original shader and CPU twin;
it does not substitute either diagnostic for the oracle.

The canonical external matrix under
`bench/out/compute-program/20260905-resident-fusion-external-matrix/` still fails
because Dawn fails the resident oracle. The separately retained wgpu control
also fails. Those failures exclude resident incumbent performance comparisons;
provider agreement is not correctness. The correction is currently physical
AMD Vulkan evidence, not Metal or Windows qualification.

The allocation-failure regression also repaired semantic and IR name ownership,
function publication, and robustness helper cleanup. Transform allocation
failures retain their `OutOfMemory` cause. Original failures are under
`bench/out/compute-program/20260905-fusion-sema-allocation-failure/`; full native,
compiler, package, and replay checks are retained under
`bench/out/compute-program/20260905-resident-fusion-correction/`.

### Concurrent completion and readback

The shared executor requests queue completion and mapping together, waits for
both, and preserves cleanup on either callback failure or cancellation.
Receipt version 5 names the completion mode and assigns mapping wait to
`submitWait`; earlier receipt versions keep their original timing interpretation.
Evaluation rejects mixed schedules. The retained scheduling experiment is under
`bench/out/compute-program/20260905-completion-overlap-diagnostic/`; its candidate
phase timings are diagnostic and must not be admitted as version 4 phase data.
The Deno control includes avoidable serial waiting in earlier matrices; its
large ratios cannot establish a runtime advantage.

### Exact descriptor cache identity

Vulkan descriptor reuse checks complete bindings and actual native allocation
identity. Recorded programs reject replaced buffers, images, samplers, and
orphaned texture views. Collision entries retain separate descriptor pools;
allocation failure preserves the previous owner. Descriptor preparation now
lives in `vk_descriptors.zig`, with native identity in
`vk_descriptor_identity.zig`; pipeline and cache ownership retain their existing
boundaries. The original wrong-buffer execution is retained under
`bench/out/compute-program/20260905-descriptor-identity-failure/`.
Correction evidence lives under
`bench/out/compute-program/20260905-descriptor-identity-correction/`.

### Exact pipeline cache identity

Active, hot, and spilled Vulkan compute cache hits check complete shader,
entry-point, layout, and effective subgroup identity. Hash collisions keep
separate owning entries so existing recordings retain their pipelines. Layout
reuse checks its definition. The original wrong-output reproduction is retained
under `bench/out/compute-program/20260905-pipeline-identity-failure/`;
corrected physical execution and native replay verification live under
`bench/out/compute-program/20260905-pipeline-identity-correction/`.

### Current boundary

`doe-gpu/compute-program` is the declared fixed-shape execution interface.
Descriptor version 2 adds invocation/program buffer lifetimes. Resident inputs
may be omitted after initialization; simulation buffers retain state. Optional
`readback: 'none'` keeps output on the GPU, and opaque output references support
same-device program composition with resource leases and generation checks.
Default invocation-local behavior remains compatible with descriptor version 1.
Native contract version 2 accepts both descriptor versions.

Receipt version 5 preserves instance and generation provenance, actual upload,
GPU input-copy, readback, and API submission work. Unobserved GPU bytes carry
null content hashes. Storage inputs can be writable WGSL state; their original
upload hash is never silently reused as a current-content assertion.
Cancellation after submitted resident work invalidates that program. Updates
retain unchanged buffer declarations and roll back failed preparation.
The full contract and migration are in
[`reusable-compute-programs.md`](../../reusable-compute-programs.md).

Vulkan `gpu-recorded` execution retains compiled GPU commands and private
pipeline state. `native-recorded` replays retained host commands in Zig;
`webgpu` retains public resources and reencodes. Timed Vulkan programs resolve
physical ticks to nanoseconds on the GPU under
`config/vulkan-timestamp-policy.json`; query ownership and counter identity
remain explicit. Other Doe backends and old addons fail timed preparation.

The current local package candidate is retained under
`bench/out/compute-program/20260905-resident-fusion-package/summary.json`.
Node, Bun, and Electron main processes install the same wrapper and platform
archives. Qualification includes resident state, GPU output leases, writable
inputs, stale references, cancellation, update rollback, timestamps, and
lifecycle recovery by explicit device destruction. This is AMD Vulkan evidence;
registry release admission and other platforms do not inherit it.

The application matrix is
`bench/out/compute-program/20260905-installed-package-matrix/summary.json`.
It preserves the image, heat, and adapted external HoloScript LIF oracles and
compares ordinary Doe, prepared Doe, Dawn, and Deno/wgpu. It validates legacy
invocation-local work under the current arithmetic and receipt contracts.
Resident acceptance and failing controls are recorded separately above. Performance remains diagnostic; large Deno host
ratios remain suspicious and require fairness review.
Native replay and SPIR-V verification for this matrix are retained with the
resident fusion correction.

### Active acceptance gaps

Metal GPU recording and physical transfer remain open; the known Mac host is
currently unreachable from this workspace. Windows requires an approved
physical D3D12 lane. Changed plans still rebuild command recordings and private
descriptor state while retaining unchanged public resources and compatible
live compute pipelines. Pipeline and descriptor sharing alone do not establish
reduced useful-operation latency.

The external portfolio, a measured application boundary crossing, cross-backend
resident sequence qualification, and independent repeat use remain open.
Requested allocation accounting excludes internal query scratch and is not a
measurement of peak GPU memory. Physical driver loss and recovery remain
unevidenced; explicit device destruction is a separate lifecycle test.

### Ground truth

- Program policies: `config/compute-program-evaluation.json` and
  `config/compute-program-external-evaluation.json`.
- Current matrix verification uses its retained `policy.json` with
  `python3 bench/cli.py program verify`.
- The matrix retains native journals and SPIR-V artifacts;
  `program verify-native` uses the shared `bench/lib/native_program_replay.py`.
- Physical regression:
  `packages/doe-gpu/test/integration/test-integration-compute-program.js`.
- Frozen external fixture:
  `bench/out/compute-program/20260905-holoscript-lif-final-fixture/fixture.json`.
- Unchanged external compatibility receipts remain under
  `bench/out/external-projects/` for UMAP, HoloScript LIF, and EA MNIST, using
  run label `execution-ownership-20260905-external-reuse`.
- Blocking requirements: [`process.md`](../../process.md).

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

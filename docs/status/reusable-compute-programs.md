# Reusable compute programs

## Current boundary

Programs now optionally retain timestamp queries in Vulkan GPU recordings,
validate their identity before replay, and return calibrated compute-pass GPU
duration separately from invocation wall time. Query destruction, updates,
cancellation, counter wraparound, and fractional timestamp periods have focused
regressions. Pass-end markers now use bottom-of-pipeline completion. The initial
probe exposed stage-scope differences and quantized Dawn readings; its outputs
under `20260905-program-gpu-timing-probe` and `20260905-program-gpu-timing-bottom`
remain diagnostic and must not be cited as an execution advantage.
Receipt schema version 2 adds explicit timing; evaluation policy version 4 owns
timing selection and Dawn quantization. Run schema version 3 retains GPU
statistics and the loaded Doe addon. The gate checks calibrated raw intervals,
statistics, allocation/readback work, and addon identity. Ordinary policies
leave timing off; the descriptor remains schema version 1.
Node addon and Bun FFI query destruction now release their native ownership
reference after invalidating the query, allowing retained command/program
references to drain and free the query pool.

The first timed matrix at `bench/out/compute-program/20260905-gpu-timing-matrix/`
used an uninitialized native timestamp period and mislabeled Deno/wgpu ticks;
its GPU durations are invalid despite the historical gate result. Device
selection now reads the physical period before any query pool is created.
The independent calibration gate binds a `vulkaninfo` profile to the selected
adapter and rejects the old default-period assumption. The pinned Deno source
and checksum-verified wgpu crates confirm raw Vulkan query results; the runner
records that source and calibrates ticks explicitly. Source audit artifacts
are retained under `20260905-timestamp-source-audit` and
`20260905-timestamp-wgpu-source-audit`. No GPU speed claim is promoted.

Native journals and SPIR-V are independently checked under
`bench/out/compute-program/20260905-timed-program-final-native/`.
The corrected matrix is
`bench/out/compute-program/20260905-timed-program-final-matrix/summary.json`; verify it
with its retained `policy.json`. It preserves the same external oracle and
includes ordinary Doe, prepared Doe, Dawn, and Deno/wgpu. Timing instrumentation
adds different query conversion paths, so its invocation ratios remain
diagnostic. Image and heat tail behavior does not establish a release win;
large Deno host ratios remain suspicious. The candidate package passes ordinary
and timed-program lifecycle qualification from the same retained archives in
`bench/out/compute-program/20260905-timed-program-final-package/summary.json`.

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
`bench/out/compute-program/20260905-timed-program-final-package/summary.json`.
The retained harness exercises explicit native selection on each host and
Bun's root FFI entry. The earlier all-host attempt retains its invalid
harness import under `20260905-timestamp-all-hosts-retained-package`.
Standard query-resolve unit normalization on non-unit-period Vulkan devices
remains separate from the explicit native-tick program calibration.

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
[`reusable-compute-programs.md`](../reusable-compute-programs.md).
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
`bench/out/compute-program/20260905-timed-program-final-package/summary.json`.
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
- Package evidence: `bench/out/compute-program/20260905-timed-program-final-package/summary.json`.
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
- Blocking gate behavior: [`process.md`](../process.md).

History remains under [`archive/`](archive/); current measurements live only in
their artifacts.

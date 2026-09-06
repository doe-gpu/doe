# Reusable compute programs

## Resident numerical correction

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

## Concurrent completion and readback

The shared executor requests queue completion and mapping together, waits for
both, and preserves cleanup on either callback failure or cancellation.
Receipt version 5 names the completion mode and assigns mapping wait to
`submitWait`; earlier receipt versions keep their original timing interpretation.
Evaluation rejects mixed schedules. The retained scheduling experiment is under
`bench/out/compute-program/20260905-completion-overlap-diagnostic/`; its candidate
phase timings are diagnostic and must not be admitted as version 4 phase data.
The Deno control includes avoidable serial waiting in earlier matrices; its
large ratios cannot establish a runtime advantage.

## Exact descriptor cache identity

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

## Exact pipeline cache identity

Active, hot, and spilled Vulkan compute cache hits check complete shader,
entry-point, layout, and effective subgroup identity. Hash collisions keep
separate owning entries so existing recordings retain their pipelines. Layout
reuse checks its definition. The original wrong-output reproduction is retained
under `bench/out/compute-program/20260905-pipeline-identity-failure/`;
corrected physical execution and native replay verification live under
`bench/out/compute-program/20260905-pipeline-identity-correction/`.

## Current boundary

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
[`reusable-compute-programs.md`](../reusable-compute-programs.md).

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
`bench/out/compute-program/20260905-resident-fusion-matrix/summary.json`.
It preserves the image, heat, and adapted external HoloScript LIF oracles and
compares ordinary Doe, prepared Doe, Dawn, and Deno/wgpu. It validates legacy
invocation-local work under the current arithmetic and receipt contracts.
Resident acceptance and failing controls are recorded separately above. Performance remains diagnostic; large Deno host
ratios remain suspicious and require fairness review.
Native replay and SPIR-V verification for this matrix are retained with the
resident fusion correction.

## Active acceptance gaps

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

## Ground truth

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
- Blocking requirements: [`process.md`](../process.md).

Earlier query-unit and ABI failures, physical corrections, and their original
artifact pointers remain in the [historical snapshot](archive/2026-09-reusable-compute-programs.md).

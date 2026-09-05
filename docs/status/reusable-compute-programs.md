# Reusable compute programs

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

## Resident sequence and cache ownership

The external fixture generator now freezes continuous simulation oracles before
GPU execution. Evaluation records warmups and lifecycle runs as part of the
state history; the gate rejects reuploads, clears, stale generations, missing
invocations, and reset outputs. The declared sequence is in
`bench/out/compute-program/20260905-holoscript-resident-sequence-fixture/fixture.json`.
The matrix under `bench/out/compute-program/20260905-resident-sequence-matrix/`
failed its original upstream numerical tolerance on repeated resident work.
Prepared Doe, ordinary Doe, Dawn, and wgpu produced identical failing output
bytes; controls are retained under
`bench/out/compute-program/20260905-resident-sequence-numerical-controls/`.
This is an open continuous-simulation numerical acceptance issue, not a
prepared-command speed result. The frozen oracle and tolerances remain intact.

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

## Current boundary

`doe-gpu/compute-program` is the declared fixed-shape execution interface.
Descriptor version 2 adds invocation/program buffer lifetimes. Resident inputs
may be omitted after initialization; simulation buffers retain state. Optional
`readback: 'none'` keeps output on the GPU, and opaque output references support
same-device program composition with resource leases and generation checks.
Default invocation-local behavior remains compatible with descriptor version 1.
Native contract version 2 accepts both descriptor versions.

Receipt version 4 records instance and generation provenance, actual upload,
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
`bench/out/compute-program/20260905-shared-pipeline-package/summary.json`.
Node, Bun, and Electron main processes install the same wrapper and platform
archives. Qualification includes resident state, GPU output leases, writable
inputs, stale references, cancellation, update rollback, timestamps, and
lifecycle recovery by explicit device destruction. This is AMD Vulkan evidence;
registry release admission and other platforms do not inherit it.

The application matrix is
`bench/out/compute-program/20260905-shared-pipeline-matrix/summary.json`.
It preserves the image, heat, and adapted external HoloScript LIF oracles and
compares ordinary Doe, prepared Doe, Dawn, and Deno/wgpu. It validates legacy
invocation-local work under the new receipt contract. It does not measure a
resident application sequence. Performance remains diagnostic; large Deno host
ratios remain suspicious and require fairness review.
Earlier native replay and SPIR-V validation results are retained separately under
`bench/out/compute-program/20260905-compiler-diagnostics-native/`.

## Active acceptance gaps

Metal GPU recording and physical transfer remain open; the known Mac host is
currently unreachable from this workspace. Windows requires an approved
physical D3D12 lane. Changed plans still rebuild command recordings and private
descriptor state while retaining unchanged public resources and compatible
live compute pipelines. Pipeline sharing alone does not establish reduced
useful-operation latency.

The external portfolio, a measured application boundary crossing, resident
sequence numerical qualification, and independent repeat use remain open.
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

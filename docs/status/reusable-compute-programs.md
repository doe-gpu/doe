# Reusable compute programs

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
`bench/out/compute-program/20260905-resident-program-package/summary.json`.
Node, Bun, and Electron main processes install the same wrapper and platform
archives. Qualification includes resident state, GPU output leases, writable
inputs, stale references, cancellation, update rollback, timestamps, and
lifecycle recovery by explicit device destruction. This is AMD Vulkan evidence;
registry release admission and other platforms do not inherit it.

The application matrix is
`bench/out/compute-program/20260905-resident-program-matrix/summary.json`.
It preserves the image, heat, and adapted external HoloScript LIF oracles and
compares ordinary Doe, prepared Doe, Dawn, and Deno/wgpu. It validates legacy
invocation-local work under the new receipt contract. It does not measure a
resident application sequence. Performance remains diagnostic; large Deno host
ratios remain suspicious and require fairness review.

## Active acceptance gaps

Metal GPU recording and physical transfer remain open; the known Mac host is
currently unreachable from this workspace. Windows requires an approved
physical D3D12 lane. Changed plans still rebuild native recordings and private
pipelines while retaining unchanged public resources.

The external portfolio, a measured application boundary crossing, resident
application sequence controls, and independent repeat use remain open.
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

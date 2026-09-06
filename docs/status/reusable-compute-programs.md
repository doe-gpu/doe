# Reusable compute programs

## Current boundary

`doe-gpu/compute-program` is the declared fixed-shape interface. Programs retain
resources, support invocation/program buffer lifetimes, optional GPU-only
output, and same-device composition through owned references. Updates preserve
unchanged resources and roll back failed preparation. Submitted cancellation
waits for completion and invalidates potentially modified resident state.

Vulkan `gpu-recorded` retains GPU commands; `native-recorded` replays host
commands in Zig; `webgpu` retains resources and reencodes. Pipeline and descriptor
reuse checks complete native identities. Changed declarations rebuild recordings
and private descriptor state. Receipt version 5 binds provenance, actual work,
and concurrent queue/mapping completion. Requested bytes are not peak memory.

The scalar SPIR-V arithmetic policy is explicit in
`config/spirv-compute-arithmetic-policy.json`. Ordinary and recorded Doe pass the
unchanged continuous HoloScript WGSL, inputs, frozen membrane tolerances, and
exact spike oracle on the qualified AMD Vulkan host. Other backend qualification
and general numerical improvement are not inferred.

## Qualification and reproduction

`program qualify-package` retains the same archives for fresh Node, Bun, and
Electron main-process installation. Qualification version 2 uses relative
artifact filenames so the evidence directory can move without rewriting hashes.
`program evaluate --package-qualification` consumes those archives, validates
installed files and loaded native identities, and keeps the complete package
inputs. Public contracts and migrations are in
[reusable compute programs](../reusable-compute-programs.md).

The portable package record is
`bench/out/compute-program/20260905-portable-package/summary.json`.
The matrix using a relocated copy is
`bench/out/compute-program/20260905-portable-package-matrix/summary.json`.
Earlier full-sequence installed-package reports remain under
`bench/out/compute-program/20260905-installed-package-resident/`.
These are repeated physical tests on the same AMD host, not independent
reproduction or registry publication. The matrix retains raw outputs, native
journals, SPIR-V, install records, source snapshots, and diagnostic comparisons.

## Open acceptance requirements

- Independently reproduce the simulation correction and establish a useful
  application benefit with preparation, correct output, and complete operation
  timing included. Dawn and wgpu still fail the resident oracle; their resident
  timings cannot enter an equivalent-work speed comparison. Large Deno ratios
  remain suspicious host-path observations. Correct invocation-local workloads
  still include incumbent tail losses.
- Reproduce the useful mechanism on physical Apple Metal. GPU recording is
  unsupported there, and the known Mac host is unreachable from this workspace.
  Windows needs an approved physical D3D12 lane. AMD package evidence does not
  qualify either platform or Electron renderer execution.
- Measure native and peak device memory, application-level concurrency and
  resource retention, real driver loss, hangs, and recovery. Explicit device
  destruction and requested buffer totals do not satisfy those requirements.
- Complete external portfolio transfer, release admission, authorized
  publication, and independent repeat use. Broader shader, conformance, and
  model-transcript gaps remain in [compiler and WebGPU](compiler-and-webgpu.md).
  Fawn remains an experimental distribution surface.

## Ground truth

- Policies: `config/compute-program-evaluation.json` and
  `config/compute-program-external-evaluation.json`.
- Matrix verification: `python3 bench/cli.py program verify`, with the retained
  matrix policy. Native replay and SPIR-V use `program verify-native`.
- Physical regressions:
  `packages/doe-gpu/test/integration/test-integration-compute-program.js`.
- Frozen resident fixture:
  `bench/out/compute-program/20260905-holoscript-resident-sequence-fixture/fixture.json`.
- Correction records: `bench/out/compute-program/20260905-resident-fusion-correction/`,
  `bench/out/compute-program/20260905-installed-package-correction/`, and
  `bench/out/compute-program/20260905-portable-package-correction/`.
- Blocking requirements: [process](../process.md).
- Preserved failures and previous boundaries:
  [historical records](archive/2026-09-reusable-compute-programs.md).

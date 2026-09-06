# Reusable compute programs

## Live simulation editing

The shipped Node terminal example has a resident heat simulation, parameter
changes, candidate preflight in a bounded process, obsolete-edit cancellation,
independent numerical acceptance, explicit reset decisions, and activation at
an iteration boundary. Every active frame is checked against the CPU stencil.
The original simulation advances during preflight; replacement preparation on
its device still pauses execution and reports its duration. This is an
application loop over the existing program contract, with policy outside Zig.

`packages/doe-gpu/test/integration/test-integration-live-simulation.js` exercises
invalid and numerically wrong shaders, overlapping edits, unchanged state,
changed state interpretation, stale/declined/approved resets, cancellation, and
reopening. Package qualification runs the application on Node only. Physical
Metal, prolonged memory testing, and an application performance advantage
remain separate acceptance work. Commands and limits are in
[reusable compute programs](../reusable-compute-programs.md).
The same retained wrapper and native package pass controlled host qualification
at `bench/out/compute-program/20260906-live-simulation-qualified/summary.json`.
Application comparisons from those exact packages are retained at
`bench/out/compute-program/20260906-live-simulation-applications/summary.json`;
the Deno/wgpu rows trigger the suspicious-speedup audit and remain diagnostic.
See `bench/out/compute-program/20260906-live-simulation-correction/README.md`
for source identities, test commands, archive extraction, and current limits.

## Explicit simulation state changes

Descriptor version 3 adds application-owned resident state formats and exact-edit
reset assessment. Destructive edits require explicit approval bound to the old
program instance and invocation revision; rejected or failed updates preserve
the old state. Earlier descriptor versions retain their existing behavior.
The migration and error contract are in
[reusable compute programs](../reusable-compute-programs.md#state-update-approval-migration).
The physical integration regression exercises each available execution mode.
State-update and independent-device qualification is retained in
`bench/out/compute-program/20260906-state-update-qualified/summary.json`.
Addon reflection failure qualification is retained in
`bench/out/compute-program/20260906-explicit-failures-qualified/summary.json`;
earlier package hashes retain their original scope. Subsequent native rendering
ownership acceptance is tracked in [compiler and WebGPU](compiler-and-webgpu.md).
The live-edit example above supplies application preflight and activation;
this contract alone does not establish asynchronous pipeline preparation.

## Native recorded command ownership

The native lifetime audit reproduced a lost copy and a crash when callers
released resources before deferred submission. Compute and copy recording now
retain native dependencies through encoder-to-command-buffer transfer; pass and
device ownership protect cleanup, including abandoned and failed construction.
The original failing probes, repaired output, runtime checks, and package
qualification are indexed under
`bench/out/compute-program/20260906-command-ownership/README.md`.
Public declaration and receipt schemas are unchanged. Rendering dependency
ownership, general object garbage collection, and physical driver loss remain
outside this acceptance evidence.
Qualification exposed unreleased finished encoder handles and an Electron crash
from unchecked external ArrayBuffer creation. Consumed command handles now
release; native-direct mapping uses host-owned storage with writable copy-back
and range detachment. The same retained-package regression exercises those
paths across the controlled hosts. Earlier native-direct mapping timings do not
measure the same host-copy work.
The exact-package application oracles and native SPIR-V checks are retained in
`bench/out/compute-program/20260906-command-ownership-audits/`.

## Evidence schema routing

The schema gate now distinguishes package qualification from application
matrices using the report's declared kind. This repairs the final-summary
directory-name collision without changing retained observations. The accepted
package and application summaries are explicit schema targets; unknown report
kinds and malformed bodies still fail. The migration is in
[schema enforcement](../config-schema-enforcement.md#schema-target-registry-migration).

## Resource lifetime correction

The physical retained-package image probe exposed buffer and descriptor
retention across program close, plus an unreleased queue reference at device
teardown. The correction releases program-owned native handles, destroys buffer
backing storage after queued work completes, and retires only affected Vulkan
descriptors. Native resources retain their cleanup device. Original failures,
intermediate diagnoses, and raw DRM checkpoint records are preserved under
`bench/out/compute-program/20260906-resource-retention-diagnostic/`.
The accepted package qualification, including DRM retention checks on each
controlled host, is
`bench/out/compute-program/20260906-resource-lifetime-qualified/summary.json`.
The image probe's raw timed/untimed checkpoints and CSV are under
`bench/out/compute-program/20260906-resource-lifetime-scratch/`.
The corresponding guarded application comparisons remain diagnostic in
`bench/out/compute-program/20260906-resource-lifetime-qualified-applications/summary.json`.
Continuous simulation audits and independent SPIR-V checks are retained in
`bench/out/compute-program/20260906-resource-lifetime-resident/`.
Reproduction commands, checksums, and intermediate failures are indexed in
`bench/out/compute-program/20260906-resource-lifetime-correction/README.md`.
This work does not establish peak GPU memory, arbitrary-object garbage
collection, physical driver-loss recovery, or another platform's behavior.

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

The AMD external evaluation policy now rejects timing runs with observed
unrelated DRM activity. Raw process-boundary observations are bound to each
measured output and rechecked by the matrix gate. This detects visible
contention without interrupting other clients; it does not establish exclusive
access or cover clients absent from both snapshots. Numerical audits remain
separate. The policy migration and visibility limits are documented in
[reusable compute programs](../reusable-compute-programs.md).
Guarded application records are in
`bench/out/compute-program/20260906-gpu-activity-matrix/summary.json`;
the controlled physical rejection and compatibility checks are retained in
`bench/out/compute-program/20260906-gpu-activity-correction/`.

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
The portable reproduction input archive is
`bench/out/compute-program/doe-amd-vulkan-reproduction-c2c349d0f.tar.gz`;
its checksum sidecar and the recipe under
`bench/out/compute-program/20260905-independent-reproduction/` bind the package,
frozen fixtures, controls, and source revision. Extracted-input runs from a
separate clean checkout are retained under that directory in
`clean-checkout-results/`. Tail stalls and observed unrelated GPU clients keep
the application measurements diagnostic.

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

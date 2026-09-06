# Doe status: compiler and WebGPU

This is the live status front door for the non-TSIR WGSL compiler and WebGPU
runtime path. Artifacts and executable tests own pass/fail state.

## Color attachment preservation

Native Vulkan recording now distinguishes the first recorded attachment use
from API draw-count accounting. The initial draw honors the declared color load;
later direct and bundled draws preserve previous color writes. Empty passes
also preserve existing color when `load` is requested. Render-pass dependencies
derive their source scope from the existing texture-layout owner.

The native-addon regression draws adjacent regions, loads them through an empty
pass, releases caller references, and checks the submitted pixels. The failing
reproduction, source correction, native checks, and exact-package qualification
are indexed at `bench/out/compute-program/20260906-render-load/README.md`.
This correction concerns existing color attachments. Depth/stencil attachment
identity, store/discard initialization, resolve behavior, render queries, and
broader render-pass conformance remain separate correctness work.

## Deferred rendering and native ownership

Vulkan draws are recorded as owned command snapshots and executed during queue
submission. Render passes and bundles retain pipelines, bindings, attachments,
vertex/index/indirect buffers, and their encoder/device dependencies. Caller
reference release is distinct from explicit destruction. The native-addon
regression writes vertex data after recording, releases caller references, and
checks the submitted image for direct and bundled draws.

Vertex-format ABI interpretation now has a shared typed owner checked against
the pinned WebGPU header, with backend-specific conversions kept local. Vulkan
render pipeline shader copies publish transactionally; allocator regressions
cover partial construction. Metal pipeline publication preserves its retained
layout and prepared vertex layouts. Native handle reference counts use atomic
lease operations; this does not establish general concurrent queue safety.

The acceptance checkpoint is indexed in
`bench/out/shader-ownership/20260906-owned-diagnostics/README.md`, with retained
package results at
`bench/out/compute-program/20260906-render-ownership-qualified/summary.json`.
This targeted image test does not establish full render-pass conformance,
attachment load/store and resolve behavior across multiple draws, render query
coverage, or physical Metal/D3D12 execution.

## Explicit shader failures and owned diagnostics

Reflection, required WGSL retention, and compiler diagnostics are repaired
through their native and compiler owners. Focused regressions exercise valid
empty interfaces, allocation failures, extraction capacity, source-context
retention, and concurrent compiler requests. The migration contract lives in
[shader compiler architecture](../shader-compiler-architecture.md).

Metal library cache ownership now resides on individual devices, with separate
shader leases and rollback of source and translation metadata. CPU reference
accounting does not qualify physical Metal behavior. Zig tests and retained-package
Vulkan regressions are indexed in
`bench/out/shader-ownership/20260906-owned-diagnostics/README.md`.
The same retained package passed Node, Bun, and Electron main-process qualification
in `bench/out/compute-program/20260906-shader-ownership-qualified/summary.json`;
independent image, heat, and simulation checks are retained in
`bench/out/compute-program/20260906-shader-ownership-audits/`.
Physical Metal validation is still required.


## Scalar compute fusion and allocation failures

The SPIR-V compute pipeline has a versioned arithmetic policy and a typed IR
transform preserving operand order and ownership. Its physical continuous
simulation correction, unchanged oracle, and remaining cross-backend boundary
are recorded in [reusable compute programs](reusable-compute-programs.md).

Allocation-failure regressions repair name publication in semantic analysis and
IR building, ownership transfer for entry points, and robustness builtin names.
Allocation errors now retain their original typed cause. Correction evidence is
under `bench/out/compute-program/20260905-resident-fusion-correction/`; this does
not establish general shader conformance or remove unrelated downstream gaps.

## Current boundary

- Doe has source-preserving WGSL lowering and backend emit paths for Metal,
  Vulkan, and D3D12/DXIL.
- Browser-corpus and CTS-subset evidence exists, but it does not establish full
  WebGPU conformance or a general Doe-over-Tint claim.
- The shared-contract WebGPU lane has transcript and parity plumbing but is not
  green end to end for the promoted model path.
- TSIR status lives in [`tsir.md`](tsir.md).

## Active blockers

- Close remaining WGSL semantic-analysis and backend-emission failures on real
  downstream shaders.
- Produce non-zero, oracle-validated state for the WebGPU model transcript
  path.
- Publish broader CTS evidence before using conformance or replacement
  language.
- Make compiler and runtime failure diagnostics preserve the original typed
  cause throughout package and native boundaries.

## Ground truth

- Compiler tests: `zig build test-wgsl` from `runtime/zig`
- CTS ledger: `config/webgpu-cts-evidence.json`
- Compiler evidence: schema-registered artifacts under `examples/` and
  `bench/out/`
- Historical entries:
  [`archive/2026-04-to-2026-07-compiler-and-webgpu.md`](archive/2026-04-to-2026-07-compiler-and-webgpu.md)

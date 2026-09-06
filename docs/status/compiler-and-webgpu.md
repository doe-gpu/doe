# Doe status: compiler and WebGPU

This is the live status front door for the non-TSIR WGSL compiler and WebGPU
runtime path. Artifacts and executable tests own pass/fail state.

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

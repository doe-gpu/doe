# Tiled matmul with Q4_K_M B input — TSIR schema fit report

Source: WGSL pinned at `runtime/zig/tests/wgsl/emit_csl_matmul_q4k_test.zig`
(`Q4K_TILED_MATMUL_WGSL`).

CSL emit sites:

- PE program: `runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_matmul_q4k.zig`
- Layout:     `runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig::emitMatmulQ4kLayout`
- Classifier: `runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_classify.zig::classify`
              (returns `tiled_matmul_q4k_dequant_b`)
- Validator:  `runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_validate.zig::validateTiledMatmulQ4k`
- Host plan:  `bench/runners/csl-runners/int4ple_summa_layout.py::b_tiles_from_q4k_bytes`
- Runner:     `bench/runners/csl-runners/int4ple_compile_target_sim_runner.py`
              (dtype `q4k_block256`, transform `weight_matrix_to_summa_q4k_tiles`)

## Why this directory holds only notes

The current `SemanticBody.op` enum in `config/doe-tsir-semantic.schema.json`
does not include a matmul shape. Available body ops are: `unknown`,
`fused_gemv`, `rms_norm`, `gather`, `residual_add`, `gelu_gated`,
`kv_write`, `kv_read`, `attention_scores`. None expresses
`C[m, n] = sum_k A[m, k] * dequantize(B_q4k)[n, k]`.

Adding `matmul` (and a Q4K-input variant) to the body op enum is a real
schema migration: it cascades to the reference interpreter dispatch, the
frontend's body inference, the digest tests, and the Lean proof
preconditions. That migration is out of scope for the fused-dequant SUMMA
wedge — which is intentionally a pure-emit + host-plan change that does
not touch the proof surface.

This kernel is therefore validated end-to-end through a different path:

- WGSL → classifier → CSL emit is pinned by
  `runtime/zig/tests/wgsl/emit_csl_matmul_q4k_test.zig` (tests Wedges
  1–5 — emit string contract, classifier routing, layout/PE-program
  pipeline).
- Host plan → fabric bytes is pinned by
  `bench/tests/test_int4ple_q4k_passthrough.py` (Wedge 6 — Q4K block
  alignment, byte-exact identity passthrough, output-dtype guard).
- End-to-end correctness is pinned by the validation-gate receipt pair:
  `bench/out/r3-1-31b-multi-token-decode/receipt.json` (baseline,
  `b_dtype=.f32_dense`) and `bench/out/r3-1-31b-multi-token-decode-q4k/
  receipt.json` (wedge, `b_dtype=.q4k_block256`). The pair is structurally
  validated by `bench/tests/test_q4k_summa_receipt_parity.py`.

## What lands here when the schema migration happens

When `matmul` (or `tiled_matmul_q4k`) is added to `SemanticBody.op`:

1. Drop `tiled_matmul_q4k.wgsl` here as a pinned snapshot of
   `Q4K_TILED_MATMUL_WGSL`.
2. Add `tiled_matmul_q4k.tsir-semantic.json` with `body.op = "matmul"`
   (or the chosen variant) and binding roles A=matrix, B=quant_matrix,
   C=output. Reductions array carries the K-axis sum with
   `accumulation = "f32"`, `associativity = "strict_ordered"`.
3. Add `tiled_matmul_q4k.tsir-realization.wse3.json` with a P×P PE grid,
   row-sliced A/C, broadcast-then-dequant B, K-axis reduction PE-local
   on the inner tile and SUMMA-stepped across the outer P tiles.
4. Add `tiled_matmul_q4k.tsir-realization.webgpu-generic.json` (1×1 PE
   grid, single device).
5. Register in `bench/tools/generate_tsir_real_manifest_fixtures.py
   ::KERNEL_EXACTNESS` with `("algorithm_exact", ("reduction_order",
   "accum_dtype", "dequant_path"), "", 0.0)` — the dequant-path
   invariant is what distinguishes the Q4K variant from a plain f32
   matmul.
6. Update the kernel-name allowlist in
   `bench/tests/test_generate_tsir_real_manifest_fixtures.py
   ::test_generated_entries_are_schema_valid_and_non_sentinel`.

The `algorithm_exact` class is correct here: the f32 SUMMA path and the
Q4K-on-PE path execute the same reduction order and the same f32
accumulation; the dequant arithmetic is bit-identical to Doppler's WGSL
`fused_matmul_q4_widetile.wgsl`.

## Status

- TSIR semantic / realization JSONs: NOT LANDED (blocked on body-op
  schema migration).
- Pin tests for the emit + classifier + host plan: GREEN (see file
  references above).
- Validation-gate receipt parity test: structure-only until both
  receipts exist (the f32_dense baseline must continue to land
  unchanged; the q4k_block256 receipt requires a simfabric run that
  invokes the new dispatch).

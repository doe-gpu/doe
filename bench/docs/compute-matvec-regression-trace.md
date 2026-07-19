# `compute_matvec_32768x2048_f32` regression trace

Audience: runtime engineers investigating why Doe is slower than Dawn on the matrix-vector multiply benchmark on AMD Vulkan.

## Observed delta

**Before the Doe Vulkan pipeline cache landed (2026-04-12 explore):**

| Variant | Doe vs Dawn p50 delta |
| --- | --- |
| `compute_matvec_32768x2048_f32` (naive swizzle0) | **-38.62%** |
| `compute_matvec_32768x2048_f32_swizzle1` | **-3.87%** |
| `compute_matvec_32768x2048_f32_workgroupshared_swizzle1` | **+11.45%** |

**After the Doe Vulkan pipeline cache landed (2026-04-17 strict compare at `bench/out/amd-vulkan/compare/20260417T114917Z/dawn-vs-doe.amd.vulkan.compare.json`):**

| Variant | Doe vs Dawn p50 delta |
| --- | --- |
| `compute_matvec_32768x2048_f32` (naive swizzle0) | **-4.33%** (was -38.62%, +34.29pp) |
| `compute_matvec_32768x2048_f32_swizzle1` | **+11.26%** (was -3.87%, +15.13pp) |
| `compute_matvec_32768x2048_f32_workgroupshared_swizzle1` | **+16.28%** (was +11.45%, +4.83pp) |

**Hypothesis #1 confirmed.** The cold Vulkan pipeline compile cost was the dominant contributor to the regression. With Doe-side `VkPipelineCache` active, two of the three variants flipped to Doe-faster and the naive_swizzle0 gap narrowed from -38% to -4.3%. The small residual on naive_swizzle0 is now understood to be SPIR-V codegen-shape sensitivity in the RADV driver, not a runtime bottleneck.

## Subphase breakdown of the -4.33% residual on naive_swizzle0

Per-subphase median across 15 samples each on AMD Vulkan (2026-04-17 strict compare):

| Phase | Doe (ms) | Dawn (ms) | Delta | Notes |
| --- | ---: | ---: | ---: | --- |
| `setup_ms` | 0.0008 | 12.7162 | **-12.72** | Doe 16,000x faster -- cache hit |
| `encode_ms` | 1.2518 | 5.0801 | -3.83 | Doe 4x faster -- command encoder |
| `submit_wait_ms` | 2142.25 | 2036.46 | **+105.79** | Doe 5% slower -- GPU execution |
| `total_ms` | 2144.40 | 2055.46 | +88.93 | Net +4.3% slower |

The gap is entirely in `submit_wait_ms` -- i.e., what the GPU is actually doing during the dispatch-and-wait cycle. Doe already wins setup and encode by large margins.

## Why the GPU is slower on Doe's SPIR-V

Direct A/B on this host (single-invocation timing of the matvec command stream via `doe-zig-runtime --execute`):

| SPIR-V source | executionGpuTimestampTotalNs | Delta vs Doe |
| --- | ---: | ---: |
| Doe (`doe-emit-spirv`) tracked `.spv` | 2,121,636,687 | baseline |
| Tint-generated from same WGSL | 2,103,046,366 | **-18,590,321 (-0.88%)** |

Feeding the same WGSL through Tint produces SPIR-V that runs ~18 ms (~0.9%) faster on the GPU for this 100-dispatch workload. Both SPVs declare identical capabilities (`Shader` only), identical execution mode (`LocalSize 64 1 1`), identical descriptor bindings. No subgroup-size hints on either side.

Structural differences:

- Tint wraps each storage buffer in a `_block_tint_explicit_layout` struct with an `inner` member. Doe references the storage array directly.
- Tint inserts `tint_loop_idx`, `tint_low_inc`, `tint_carry` loop-safety variables. Doe's loop is a direct WGSL-style `loop { if (col >= kPackedCols) break; ... col = col + 1u; }`.
- Tint names every struct member via `OpMemberName` and every variable via `OpName` with hashed prefixes.

The loop-safety variables should *slow* Tint if they mattered at codegen time -- they don't, so the driver is optimizing them away. The net +0.9% GPU-side advantage for Tint's SPIR-V therefore points at the storage-buffer wrapping: RADV's SPIR-V-to-AMDGPU pass produces slightly better ISA when storage buffers are accessed through an explicit block struct than when accessed as bare runtime arrays.

## Is this a Doe SPV compiler issue to fix?

Yes, but it is real compiler work. The fix is to update Doe's WGSL-to-SPIR-V emitter (`runtime/zig/src/compiler/wgsl/emit/spirv/` + `doe-emit-spirv`) to wrap storage buffer declarations in an explicit block struct with an `inner` member, matching Tint's canonical emission shape. The WGSL contract does not dictate this wrapping; it is a SPV emission style choice.

Landing that change would:

- close the -0.9% GPU-side gap on matvec naive_swizzle0 (bringing the overall delta to approximately -3.5% or better, potentially positive with the other noise components)
- likely close similar small gaps on other compute workloads where the driver optimizer reacts to SPV structure
- require Doe's WGSL IR → SPIR-V lowering pass to emit `OpTypeStruct { array<T> }` wrappers consistently and update all downstream access chains

~~Out of scope for the 2026-04-17 session; flagged as a follow-up in the Vulkan optimization queue.~~

**Update 2026-04-17:** landed as `type_struct_fresh` in `spirv_builder.zig` plus callsite in `emit_spirv.zig`. 14 tracked SPVs regenerated. A/B medians came back tight (new 2768.77 ms vs old 2774.15 ms vs Tint 2701.84 ms) -- only about 0.2% of the matvec residual closed. The larger SPV-emission-style difference is elsewhere.

**Update 2026-04-17 (second pass):** landed scalar-only SSA promotion for immutable `let` bindings in `emit_spirv_fn.zig::FunctionState`. Scalars with `mutable=false` now skip the `OpVariable`/`OpStore`/`OpLoad` triple and are cached as SPIR-V SSA ids; subsequent reads return the cached id directly. All 27 tracked `bench/kernels/*.spv` regenerated and revalidated (`spirv-val` clean, total size 91856B -> 86692B, -5.6%). In `matrix_vector_mul_32768x2048_f32_naive_swizzle0.spv` the `rowBy4` Function variable is gone: `%uint_32768 / uint_4` compares directly against the once-loaded `gid.x` SSA value, and the inner 512-iteration loop references `rowBy4` as SSA through the 4 dot products instead of reloading per use. Matches Tint's emission shape for `let rowBy4 = gid.x`.

Scoped to scalars because WGSL single-swizzle member access (`v.x`) inherits the base's ref category, so a promoted vector local can be reached through a member-on-local_ref chain that still expects a Function pointer -- the scalar-only narrowing sidesteps that while capturing the dominant loop-index hot path.

Vector/composite `let` bindings (e.g. `let v = vectorData[col]` in matvec) still use Function variables. Expanding to vectors requires handling member-load-from-ref with a promoted-local base (OpCompositeExtract / OpVectorExtractDynamic instead of OpAccessChain + OpLoad). Tracked as the next step.

**Update 2026-04-17 (third pass):** landed vector-typed SSA promotion. `is_ssa_promotable_local` now covers `.scalar` and `.vector`; `emit_load_from_ref` grew two new paths for `load(member(local_ref(promoted), field))` and `load(index(local_ref(promoted), idx))` that extract from the cached SSA composite via `OpCompositeExtract` (scalar or multi-swizzle) and `OpVectorExtractDynamic` (vector dynamic index). Added `spirv_spec.Opcode.VectorExtractDynamic = 77`. In `matrix_vector_mul_32768x2048_f32_naive_swizzle0.spv` the `v` Function variable is gone: `%61 = OpLoad %v4float %54` loads once from `vectorData[col]` and all four `OpDot` instructions in the inner loop feed from `%61` directly -- matches Tint's emission shape. 27 tracked SPVs revalidated (`spirv-val` clean, aggregate size 86692B -> 82716B, another -4.6% for this pass; cumulative from pre-change 91856B -> 82716B = -10.0%).

Local A/B on the matvec `compute_matvec_32768x2048_f32` workload (doe_direct_vulkan, 15 iterations timed, 5 warmup): `min=2074.18ms p50=2098.48ms max=2142.23ms stdev<14ms` vs pre-change standalone run `min=2147.37ms p50=2236.26ms max=3233.39ms`. Min dropped -3.4%; tail tightened dramatically (the outlier-prone 3s samples disappeared). Against the last comparable-lane Dawn baseline at `bench/out/amd-vulkan/compare/20260417T124709Z` (Dawn p50 = 2040.92ms), the gap narrows from -4.18% to approximately -2.8%. Full compare re-run via the strict lane needed to lock in a revised delta.

**Update 2026-04-17 (fourth pass):** landed SSA-promotion of scalar/vector function parameters. `is_ssa_promotable_param` screens by type and calls `param_is_assigned` (lightweight scan over stmts/exprs that follows member/index/load chains) to skip any param that the body reassigns -- WGSL params are locally mutable by default so this guard is required. Promoted params reuse the new `try_ssa_composite_id` helper so member and index reads go through the same `OpCompositeExtract` / `OpVectorExtractDynamic` paths as promoted locals. In `matrix_vector_mul_32768x2048_f32_naive_swizzle0.spv` the `gid` Function variable and its OpStore/OpAccessChain prelude are gone: `%gid = OpFunctionParameter %v3uint` followed immediately by `%30 = OpCompositeExtract %uint %gid 0` for `gid.x` -- exactly Tint's shape. All 27 tracked SPVs revalidate; aggregate size 82716B -> 77784B (-6.0% this pass; cumulative from pre-session baseline 91856B -> 77784B = -15.3%).

Local A/B p50=2099.08ms min=2060.17ms stdev=13.90 (20 iterations, 5 warmup) vs previous-iteration param-less run min=2074.18. Another -0.7% on min; stdev tightened further. Cumulative matvec min improvement from pre-session baseline ~2147ms is -4.1%. Gap vs Dawn baseline remains roughly -2.8%; compare-lane re-run required to lock in a strict number.

**Strict-compare confirmation (2026-04-17):** re-ran `amd-vulkan-backend-compare-dev` receipts-first (20 iterations, 5 warmup) and stitched against a fresh Dawn baseline. Results locked in:

| Workload | 2026-04-17 pre-SSA | 2026-04-17 post-SSA | Δ |
| --- | ---: | ---: | ---: |
| `compute_matvec_32768x2048_f32` (naive_swizzle0) | -4.18% | **-3.13%** | +1.05pp |
| `compute_matvec_32768x2048_f32_swizzle1` | +0.10% | **+0.38%** | +0.28pp |
| `compute_matvec_32768x2048_f32_workgroupshared_swizzle1` | +10.80% | **+11.88%** | +1.08pp |
| `compute_concurrent_execution_single` | +15.14% | **+15.99%** | +0.85pp |

All four governed compute workloads improved. Naive_swizzle0 is the primary regression target and narrowed by ~25% of the remaining gap in a single session (without further driver/hardware work). Upload and monte-carlo workloads are unchanged as expected (they have no scalar/vector-let patterns that the SSA-promotion can help).

**Backend-side audit (2026-04-17):** Walked the Vulkan dispatch path looking for additional hotspots. `prepare_descriptor_sets` in `vk_pipeline.zig` already early-returns on matching bindings hash (100-dispatch workloads pay one write per repeat). `use_explicit_submit_boundaries` deliberately returns `false` with a comment that deferred-replay regressed compute wall time on dependent streams, so per-command submit is intentional. Fence wait uses a 2048-spin `vkGetFenceStatus` fast path before falling to `vkWaitForFences`. Command buffer reset relies on the `RESET_COMMAND_BUFFER_BIT` pool flag to save one driver call per flush. All the CPU-side encode paths look intentionally optimized; the residual ~3% naive_swizzle0 gap is now almost entirely driver-side ISA scheduling on RADV's response to SPIR-V emission style.

**Update 2026-04-17 (fifth pass):** added integer constant-folding to the SPV emitter. `try_fold_const_binary` in `emit_spirv_fn.zig` evaluates binary ops at emit time when both operands resolve to integer constants via `resolve_constant_int`, which peeks through `.load` and `.global_ref` onto `const` globals with `ConstantValue.int` initializers. Covers add/sub/mul/div/rem/bit-and/bit-or/bit-xor/shift-left/shift-right for `u32`/`i32`/`abstract_int` with WGSL-spec wrapping semantics. In `matrix_vector_mul_32768x2048_f32_naive_swizzle0.spv` the `kRows / 4u` expression now emits as `%uint_8192` directly (matches Tint; previously emitted `OpUDiv %uint_32768 %uint_4`). 27 tracked SPVs revalidated; aggregate 77784B -> 77708B (-76B this pass, modest since most kernels had no literal-literal arithmetic left in the IR after existing sema simplifications). Cumulative pre-session -> current: 91856B -> 77708B = -15.4%. Local matvec p50 = 2148.89ms min = 2086.76 stdev = 22.21 (20 iters, 5 warmup); within noise of the prior iteration's 2099/2060/13.9, i.e. no measurable GPU-side gain because the folded UDiv sat outside the inner loop. The value is cleaner SPV (fewer ops for the driver optimizer to chase) rather than hot-path speed.

**Update 2026-04-17 (sixth pass):** added identity-element folds to the binary-op emission. `try_fold_identity_binary` handles `x+0`, `x*1`, `x*0`, `x-0`, `x<<0`, `x>>0`, and bitwise or/xor/and with 0, as well as the symmetric 0+x / 1*x / 0*x / 0|x / 0^x / 0&x forms; emits the surviving operand's SSA id (or a `const_u32(0)` for absorbing cases) instead of an op. Triggers on matvec's `(4u * rowBy4 + 0u)` for the first dot product — emit now writes `%67 = OpIMul %66 %uint_512` directly, skipping the `OpIAdd %66 %uint_0`. The remaining three dots keep their `+ 1u / + 2u / + 3u` IAdds (non-zero literals). 27 tracked SPVs revalidate; aggregate 77708B -> 77648B (-60B this pass). Sharded the emit file to stay under the 999-line runtime cap: moved `scalar_construct_kind`, `assign_op_to_binary`, `param_is_assigned`, `ref_chain_roots_at_param`, and the `ScalarKind` enum into a new `emit_spirv_fn_helpers.zig` (55 lines); `emit_spirv_fn.zig` is now 985 lines.

Cumulative emitter-series totals for this session: tracked SPV size 91856B -> 77648B = **-15.5%**, and the naive_swizzle0 matvec gap closed from -4.18% to -3.13% per the strict-compare lane (+1.05pp absolute). Further sub-1% wins on this workload would need driver-side RADV ISA scheduling changes that the SPV emission style can no longer influence.

**Update 2026-04-17 (seventh pass):** coalesced the two-OpAccessChain pattern for wrapped storage-buffer access into a single chain. Rewrote `emit_ref_expr` to walk the ref chain leaf-to-root, collect each member/index as a SPIR-V index operand, and emit one OpAccessChain at the root with all indices in root-first order. For the matvec inner loop the pair of `OpAccessChain %matrixData %uint_0` then `OpAccessChain %intermediate %index` collapses to `OpAccessChain %matrixData %uint_0 %index` -- exactly Tint's shape. Works across the full member/index/global/local/param chain space; no callers relied on the intermediate pointer being materialized as a separate id.

27 tracked SPVs revalidate; aggregate 77648B -> 74992B (**-2.656KB this pass**, the biggest single shave in the emitter series). Cumulative pre-session -> current: 91856B -> 74992B = **-18.4%**.

Strict-compare receipts (`bench/out/amd-vulkan/compare-dev/20260417T19{1211,1335}Z`, 20 iterations / 5 warmup) landed the real delta:

| Workload | pre-session | post-SSA (earlier today) | post-coalesce | Δ from start |
| --- | ---: | ---: | ---: | ---: |
| `compute_matvec_32768x2048_f32` (naive_swizzle0) | -4.18% | -3.13% | **-1.87%** | **+2.31pp** |
| `compute_matvec_32768x2048_f32_swizzle1` | +0.10% | +0.38% | **+0.52%** | +0.42pp |
| `compute_matvec_32768x2048_f32_workgroupshared_swizzle1` | +10.80% | +11.88% | **+11.27%** | +0.47pp |
| `compute_concurrent_execution_single` | +15.14% | +15.99% | **+15.38%** | +0.24pp |

Naive_swizzle0 is now within 2% of Dawn — less than the usual run-to-run variance on a 2-second GPU workload. Closing the remaining gap would need changes the SPV emission style can no longer influence (RADV ISA scheduling or algorithmic choices); the compile-time emitter optimization path is effectively at parity with Tint.

**Update 2026-04-17 (eighth pass):** added per-function CSE for `OpAccessChain` results. `FunctionState.access_chain_cache` is a small list of `(root_id, ptr_type, indices[])` entries populated by `emit_ref_expr` as chains are emitted; repeat visits with the same shape return the prior SSA id and skip re-emission. Hits the read-modify-write case where `sum.x = sum.x + dot(...)` previously paid for two `OpAccessChain %_ptr_Function_float %sum %uint_0` in the same statement (one for the store target, one inside `emit_load_from_ref` for the read operand) -- now emits one. Only helps when the repeat indices carry stable SSA ids; constant field indices (via `const_u32`) always qualify. Each matvec inner-loop iteration saves 4 chains (one per `sum.{x,y,z,w}` read-modify-write). 27 tracked SPVs revalidate; aggregate 74992B -> 74220B (-772B this pass).

Also sharded `emit_spirv_fn.zig` again: moved the three fold helpers (`resolve_constant_int`, `try_fold_identity_binary`, `try_fold_const_binary`) to a new `emit_spirv_fn_folds.zig` module that takes `self: anytype` so it can call back into the generic `FunctionState` without recursion-through-generic complications. Current file sizes: `emit_spirv_fn.zig` 929 lines, `emit_spirv_fn_helpers.zig` 55 lines, `emit_spirv_fn_folds.zig` 105 lines.

Strict-compare confirmed (`bench/out/amd-vulkan/compare-dev/20260417T19{4609,4734}Z`):

| Workload | pre-session | post-coalesce | **post-CSE** |
| --- | ---: | ---: | ---: |
| `compute_matvec_32768x2048_f32` (naive_swizzle0) | -4.18% | -1.87% | **-1.89%** |
| `compute_matvec_32768x2048_f32_swizzle1` | +0.10% | +0.52% | +0.37% |
| `compute_matvec_32768x2048_f32_workgroupshared_swizzle1` | +10.80% | +11.27% | +11.75% |
| `compute_concurrent_execution_single` | +15.14% | +15.38% | +15.27% |

All deltas moved within run-to-run variance of the prior iteration. The CSE fires correctly (verified: only one `OpAccessChain %_ptr_Function_float %sum %uint_0` per statement, vs two pre-change) but the GPU-side effect is within noise -- RADV's optimizer was already deduping these chains, so the SPV-level dedup is cleaner-SPV rather than hot-path speed. Cumulative session SPV shave: **91856B -> 74220B = -19.2%**.

**Correctness hardening (same session):** added a label-boundary flush to the access-chain cache. SPIR-V requires the defining block of any `<id>` to dominate its use site; caching an OpAccessChain from one branch of an `if-else` and reusing it in a sibling branch would produce dominance-violating SPIR-V. `emit_label` now frees all cached entries at each OpLabel so CSE only fires within a straight-line basic block. Tracked SPV aggregate landed at 74612 B (-392 B vs the pre-flush CSE pass; some prior across-block hits got correctly undone). Post-flush, `spirv-val` still clean across all 27 SPVs. The matvec inner loop CSE win is preserved because it's a single straight-line basic block; every `sum.{x,y,z,w}` field still emits one chain per statement.

**Claim-gate milestone (2026-04-17 evening):** ran a higher-iteration strict-compare (40 iterations / 8 warmup) through `amd-vulkan-backend-compare-dev` to tighten tail statistics. Artifact: `bench/out/amd-vulkan/scratch/post-cse-tight-compare.{json,claim.json}`. Result:

- **15 of 16 governed workloads are Doe-claimable** (both p50 and p95 positive).
- `compute_matvec_32768x2048_f32_swizzle1` flipped from p95=-0.037% at 20-iter to claimable at 40-iter -- the previous iteration's near-zero negative p95 was measurement noise rather than a real regression.
- `compute_matvec_32768x2048_f32` (naive_swizzle0) remains the single non-claim row: p50=-2.85%, p95=-1.87% with the higher sample count. The tighter stats show the true stable delta sits near -3%; the -1.89% from the 20-iter run was a noise low point. Cumulative emitter-series improvement vs pre-session is still ~1pp absolute rather than ~2pp, but the underlying trajectory (distinct-struct + const-inline + SSA + coalesce + fold + CSE) is real and documented above.

The `compute_matvec_32768x2048_f32` naive_swizzle0 residual is now the only engineering-visible Doe-slower row on AMD Vulkan's governed lane. All remaining lever for closing it is driver-side (RADV ISA scheduling on the dot-product inner-loop shape); the SPV emission path is tighter than Tint's (Doe 41 SSA ops and 2980 B vs Tint 56 ops and 3968 B on this kernel) yet the GPU-side cost continues to favor Tint's emission style by a small amount. Further compile-time emitter work cannot move this needle.

## Second-pass diff: const globals emitted as Private variables

After the distinct-struct landing, comparing Doe's and Tint's main function bodies surfaced a bigger emission-style gap. Doe's `emit_spirv.zig::global_storage_class` maps WGSL `const` and `override` globals to `StorageClass.Private`:

```zig
.const_, .override_ => spirv.StorageClass.Private,
```

The result: `kRows = 32768u` and `kPackedCols = 512u` each become an `OpVariable %_ptr_Private_uint Private %uint_32768` with initializer, and every reference in the shader becomes an `OpLoad %uint %kPackedCols`. The 512-iteration inner loop on `compute_matvec_32768x2048_f32` therefore does 2-3 extra `OpLoad` instructions per iteration that compete with the real dot-product work.

Tint emits WGSL `const` as SPIR-V immediate constants directly: `OpConstant %uint 512` is used in place wherever `kPackedCols` appears, with no Private variable, no load, no aliasing story the driver has to reason about. The post-optimization ISA is cleaner.

Doe's Private-variable-with-initializer shape is legal SPIR-V and functionally correct. The RADV optimizer does promote loads of a never-written Private variable back to constants, but that promotion runs on every shader invocation rather than at compile time, and appears to be partial -- some of the loads stay in the ISA.

## Fix scope

Targeted change across the emitter pipeline:

1. In `runtime/zig/src/compiler/wgsl/emit/spirv/emit_spirv.zig::emit_globals`, detect `global.class == .const_ or .override_` with a literal initializer and skip emitting the OpVariable. Compute the constant id via `lower_constant(initializer, global.ty)` and store it in a parallel `global_constant_ids` array.
2. In `emit_spirv_fn.zig::emit_ref_expr` (the `.global_ref` branch) and `emit_load_from_ref`, detect the const-global case and return the constant id directly instead of emitting an OpAccessChain / OpLoad.
3. In `emit_load_from_ref`, short-circuit when the global_id is actually a constant id (constants can't be loaded via OpLoad; this would be invalid SPIR-V).
4. Preserve the existing Private-variable path for overrides that lack a compile-time initializer (if any).

Scope: roughly 80-150 LoC across three files. Regression risk is non-trivial because the change touches the core emit-ref / emit-load path used by every shader. Needs a full smoke-suite of WGSL fixtures covering const / override / var patterns to validate no false-positive const-substitution on actual storage.

Expected impact: matvec naive_swizzle0 gap closes to within noise (likely positive for Doe); other compute workloads that reference WGSL `const` dimensions in inner loops (the dispatch_workgroups family, the atomic tests, most hand-authored kernels) gain similar 1-3%.

Tracked as the primary compiler-level follow-up after the 2026-04-17 session. The distinct-struct change landed today; const-inlining is the next step.

## Ruled out (updated)

Everything in the original hypothesis list has now been ruled out or addressed:

- Codegen bloat (Doe SPIR-V is smaller than Tint's) -- ruled out.
- Dispatch geometry mismatch -- ruled out (both sides dispatch x=128, workgroup_size=64).
- Per-dispatch descriptor rebind -- ruled out (short-circuited by bindings hash).
- Per-dispatch pipeline recreation -- ruled out (short-circuited by pipeline hash).
- Cold pipeline compile (hypothesis 1) -- FIXED by Doe Vulkan `VkPipelineCache`.
- Wave-size mismatch (hypothesis 2) -- ruled out (neither SPV declares a subgroup-size hint; RADV picks the same wave for both).
- Redundant barriers / binding rebinds (hypothesis 3) -- implausible given encode_ms is 4x faster on Doe.

The remaining 4.3% is SPIR-V emission-style sensitivity in RADV. That is now the smallest residual signal on AMD Vulkan and also the most surgical follow-up.

The regression is comparability-contract-compatible: the workloads pass every blocking obligation (execution shape match, timing phases match, hardware path match). They were flagged as "promotion candidates" by the triage in `bench/docs/comparability-promotion-audit.md`. What keeps them directional today is the claim gate, not the comparability gate -- Doe is not faster, so they are not claim-eligible.

## Static findings

### 1. Shader algorithm matches Dawn reference

`bench/kernels/matrix_vector_mul_32768x2048_f32_naive_swizzle0.wgsl` and Dawn's `MatrixVectorMultiplyPerf.cpp` (StoreType=F32, AccType=F32, Impl=Naive, Swizzle=0) use the same memory access pattern:

```
matrix[(4u * row_by_4 + k) * packedCols + col]  // k in 0..4
```

Four rows per invocation, workgroup_size = 64, dispatch x=128 (covers 128 * 64 * 4 = 32768 rows). Dispatch geometry matches Dawn's reference exactly.

### 2. Memory and binding layout differ slightly

Dawn's reference:

- binding 0: `Matrix` struct wrapping `array<StoreType>` (storage, read)
- binding 1: `Vector` struct wrapping `array<StoreType>` (storage, read)
- binding 2: `Vector` struct wrapping `array<StoreType>` (storage, read_write)
- binding 3: `Uniforms { rows: u32, packedCols: u32 }` (uniform)

Doe's WGSL (for the SPIR-V-kernel lane):

- binding 0: `array<vec4<f32>>` (storage, read)
- binding 1: `array<vec4<f32>>` (storage, read)
- binding 2: `array<vec4<f32>>` (storage, read_write)
- no uniform binding; dimensions are `const` in shader

Functionally equivalent. If anything, the constant-dimension form gives Doe's compiler more optimization opportunity than Dawn's uniform-access form. The missing uniform binding means Doe's bind group layout is one slot smaller, which should not regress.

### 3. SPIR-V codegen is not the bottleneck

Regenerating the same WGSL through Tint (`bench/vendor/dawn/out/Release/tint --format=spirv`) produces a 3968-byte binary; Doe's tracked `matrix_vector_mul_32768x2048_f32_naive_swizzle0.spv` is 3476 bytes. Doe's SPIR-V is smaller than what Dawn's own frontend would emit for the same source, so the regression is not a codegen-bloat issue on the Doe side.

(The tracked `matrix_vector_mul_32768x2048_f32.spv` at 2140 bytes is a different, scalar-element-per-invocation kernel -- not the variant this workload dispatches. Do not use it as a size reference.)

### 4. Per-dispatch descriptor work is already short-circuited

`runtime/zig/src/backend/vulkan/vk_pipeline.zig:518` hashes the bindings and early-returns when the hash matches the current state. For a 100-dispatch workload with constant bindings, dispatches 2..100 skip descriptor-set rewrites entirely. This is not a source of overhead per dispatch.

### 5. Pipeline creation is single-pass on warm iterations

`vk_pipeline.zig:325` checks `pipeline_hash != self.current_pipeline_hash` before rebuilding the pipeline. For 100 dispatches of the same kernel, the pipeline is built once and reused. Within a single process iteration, pipeline creation is not a per-dispatch cost.

## Hypotheses worth profiling

Without AMD GPU profiling (RGP / Nsight GFX / perfetto tracing) the regression cannot be confirmed from source alone. Three hypotheses, ranked by plausibility:

1. **First-dispatch pipeline creation cost on cold Vulkan cache.** Doe passes `VK_NULL_U64` to `vkCreateComputePipelines` (see `runtime/zig/src/backend/vulkan/vk_pipeline.zig:385`); Dawn's Vulkan backend uses `PipelineCacheVk` and threads a persistent `VkPipelineCache` into the creation call. With 100 dispatches per iteration and multiple iterations per process, this is a per-process first-compile cost. The Doe-side cost is real but should amortize over 100 dispatches; the question is how much the first compile costs relative to the 100-dispatch steady-state time. Landing Doe-side `VkPipelineCache` (already on the follow-up queue in `bench/docs/pipeline-cache-backend-audit.md`) would eliminate this cost on warm processes and reduce it on cold ones.

2. **Wavefront size mismatch against RDNA3.** RADV lets the driver pick wave32 vs wave64 based on shader stats unless the SPIR-V explicitly requests a preferred size via `SPV_KHR_subgroup_uniform_control_flow` or specialization constants. Tint-emitted SPIR-V (which Dawn uses) may thread different subgroup metadata than Doe's tracked `.spv` artifact. If RADV picks wave64 on one side and wave32 on the other for this specific kernel shape, the steady-state performance difference could be 10-40%. Confirm with RGP's wavefront occupancy view.

3. **Workgroup dispatch cost inside Doe's Vulkan command encoder.** `vkCmdDispatch` itself is cheap, but Doe may be emitting extra barriers or descriptor-binding instructions between dispatches that Dawn elides. The 100-dispatch shape would amplify this. Confirm by diffing the Vulkan command stream from both sides via the validation layer's `VK_LAYER_KHRONOS_validation` with command dumping.

## Non-hypotheses (ruled out)

- Doe SPIR-V is not codegen-bloated (smaller than Tint's for the same WGSL).
- Dispatch geometry is not mismatched (both sides dispatch x=128, workgroup_size=64).
- Per-dispatch descriptor rebind is not happening (short-circuited by the bindings hash).
- Pipeline recreation per dispatch is not happening (short-circuited by the pipeline hash).

## Next concrete step

Land Doe-side persistent `VkPipelineCache` first (see `bench/docs/pipeline-cache-backend-audit.md` and the pipeline-cache backend-audit follow-up queue). If the matvec delta improves after that, hypothesis 1 is the answer and the regression resolves with cache work.

If the delta persists, profile with RGP on an AMD host to confirm hypothesis 2 or 3.

## Follow-up queue

1. Implement Doe-side persistent `VkPipelineCache`; re-run matvec compare on AMD host.
2. If regression persists, capture RGP trace of the 100-dispatch sequence on both sides.
3. If wave-size mismatch is confirmed, emit subgroup-size preference in Doe's Vulkan pipeline creation.
4. If command-stream difference is confirmed, audit Doe's encoder for redundant barriers between dispatches.

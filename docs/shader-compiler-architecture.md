# Shader compiler architecture

## Diagnostic and reflection ownership

The addon rejects failed or oversized reflection results before allocating a
JavaScript array or reading native metadata. Bun FFI also checks both the count
query and publication result. A valid empty interface still produces an empty
array. Compilation-info JSON snapshots are thread-local boundary storage, and
module diagnostics are read under the reflection publication lock.

Shader handles retain their creating device. Pipeline creation rejects a shader
from another logical device. Metal adapters own their underlying device handle;
logical devices retain the adapter and own independent library and archive
caches. Releasing one logical device does not invalidate another device's cache.
The process-wide archive flush entry point enumerates live caches without owning
or sharing them. Compilation locks are per archive.

Compiler entry points accepting `Diagnostic` keep parser, semantic-analysis,
IR-construction, transformation, and emitter failures in the supplied value.
The diagnostic owns bounded message and context storage without allocating.
Views returned by that value remain valid until the owner is changed or
released. Native shader requests use that explicit path and copy compilation
messages into the shader's own storage, including allocation failures.

Migration: the existing Zig `lastError*` and C `doeNativeCopyLastError*`
interfaces remain compatibility adapters. Their state is per calling thread;
legacy views expire at the next call on that thread. Retain a `Diagnostic`
when results must survive another compilation. No global compilation lock is
introduced, and shader arithmetic and successful target bytes are unchanged.

Binding reflection distinguishes uncomputed, successfully published, and failed
metadata. Failed extraction cannot publish a ready empty interface; subsequent
queries preserve its error. A genuine zero-binding shader remains successful.
Required source retention fails creation with `OutOfMemory`, and the WebGPU
creation boundary still returns an error module when allocation permits it.

Migration: native binding-query extensions return `SIZE_MAX` on reflection
failure, including unavailable source and an invalid entry point. Callers must
check that sentinel before using the returned count and may copy the native
error details. Zero means a successfully determined empty interface. A query
with a smaller destination still reports the complete count and copies only
the available destination extent; internal extraction rejects a truncated
interface. No descriptor or receipt fields change.

Metal library caches belong to individual Doe devices. Exact source and the
translation configuration determine a hit; cached libraries and shader modules
each own a retained library reference. The translation configuration binds the
compiler, proof policy, and runtime lowering mode. Pipeline override constants
continue through separate compilation. Cache teardown releases only its own
references, and failed source or metadata allocation unwinds acquired state.
Physical Metal execution remains required to qualify this ownership correction.

Render pipelines retain their device and layout after successful construction.
Vulkan graphics code and entry-point copies are transactional: unavailable code
is a shader validation failure, and allocation failure releases partial copies
without publishing a pipeline. Metal pipeline publication preserves the layout
and vertex declarations already prepared by its native owner.

Migration: native rendering now retains dependencies through command-buffer
release, and Vulkan draw execution occurs at submission. Inputs written after
recording are therefore visible to submitted work. Vertex format values follow
the pinned WebGPU ABI through `contracts/vertex_format.zig`; Vulkan and D3D12
convert that exhaustive type locally, while Metal and the addon use the pinned
C constants. Legacy flat texture-copy addon calls use the existing native
argument order and reject origins or aspects that interface cannot represent.
No public descriptor fields change. Broader render-pass semantics and physical
platform coverage require their own acceptance evidence.


## Compute arithmetic policy

`config/spirv-compute-arithmetic-policy.json` selects scalar `f32` arithmetic
for compute-only SPIR-V modules at build time. `fuse-trailing-add` transforms
`(a + b*c) + d` into `a + fma(b,c,d)` in typed IR before emission. The operand
evaluation order and multiplicity remain unchanged. Integer, vector, graphics,
mixed-stage, and other target expressions retain their existing policy.

This uses WGSL's permitted reassociation followed by fusion of the resulting
multiply-add. It can reduce cancellation error in offset integration, but does
not promise improved accuracy for every input. Frozen application numerical
requirements remain blocking; agreement among providers is not an oracle.
The transform owns no workload names, source hashes, or input-specific rules.

Migration: the policy is an additive build contract; rebuild the native library
and retain the new library and generated SPIR-V identities. The original WGSL,
descriptor, and receipt fields keep their meanings. Existing pipeline reuse
compares actual SPIR-V words, so differently lowered programs cannot share a
pipeline merely because their source text matches. Changing the policy requires
schema validation, allocator and operand-order regressions, and physical
application evaluation before promotion. `source-order` retains the prior
compiler expression graph and does not control driver contraction.

The language permission is defined by the
[WGSL reassociation and fusion specification](https://gpuweb.github.io/gpuweb/wgsl/#reassociation-and-fusion).

## Pipeline

```
WGSL source text
       │
       ▼
┌─────────────┐
│   Lexer     │  token.zig, lexer.zig
│  (tokenize) │
└──────┬──────┘
       │ Token[]
       ▼
┌─────────────┐
│   Parser    │  parser.zig, ast.zig
│  (parse)    │
└──────┬──────┘
       │ Ast
       ▼
┌─────────────┐
│    Sema     │  sema.zig, sema_attrs.zig, sema_body.zig, sema_types.zig
│  (analyze)  │
│             │  name resolution, type resolution, builtin resolution,
│             │  binding/attribute extraction
└──────┬──────┘
       │ SemanticModule
       ▼
┌─────────────┐
│ IR Builder  │  ir_builder.zig → ir.zig
│  (lower)    │
│             │  typed SSA-like values, explicit blocks + control flow,
│             │  explicit address spaces, explicit bindings/builtins
└──────┬──────┘
       │ ir.Module
       ▼
┌─────────────┐
│ IR Validate │  ir_validate.zig
│  (verify)   │
└──────┬──────┘
       │ ir.Module (validated)
       │
       ├────────────────┬────────────────┐
       │                │                │
       ▼                ▼                ▼
┌────────────┐  ┌─────────────┐  ┌─────────────┐
│  Metal     │  │   Vulkan    │  │    D3D12    │
│            │  │             │  │             │
│ emit_msl   │  │ emit_spirv  │  │ emit_dxil   │
│ emit_msl_ir│  │ spirv_builder│  │ (native)   │
│            │  │             │  │             │
│ IR → MSL   │  │ IR → SPIR-V │  │ IR → DXIL  │
│ (text)     │  │ (binary)    │  │ (binary)   │
└─────┬──────┘  └──────┬──────┘  └──────┬──────┘
      │                │                │
      ▼                ▼                ▼
  MSL text        SPIR-V words     DXIL bytecode
      │                │                │
      ▼                ▼                ▼
 xcrun metal      VkCreateShader    D3D12 driver
 (platform)       Module (driver)
      │
      ▼
 MTLLibrary
```

Key invariant: every backend enters at `ir.Module`. No backend reads AST directly. The only external tool in the default pipeline is xcrun metal on macOS; Vulkan (SPIR-V) and D3D12 (DXIL) are fully native.

## WebGPU integration

The compiler is internal to the WebGPU API. Consumers never see IR, MSL, SPIR-V, or HLSL.

This diagram shows the **headless native path** (Node.js / Bun → Zig). The
browser wrapper path (`packages/doe-gpu/src/browser.js`) does not use the Doe
shader compiler — it delegates `createShaderModule` to the browser's own WebGPU
implementation, which compiles shaders internally.

```
JS / C application
       │
       │  wgpuDeviceCreateShaderModule(device, {code: "WGSL..."})
       ▼
┌──────────────────┐
│   WebGPU API     │  wgpu_dropin_lib.zig (symbol routing)
│   (C ABI)        │  doe_wgpu_native.zig (native impl)
└───────┬──────────┘
        │  stores WGSL source + extracts bindings
        │
        │  wgpuDeviceCreateComputePipeline(device, {module, entryPoint})
        ▼
┌──────────────────┐
│  Backend Router  │  picks Metal / Vulkan / D3D12 based on runtime
└───┬───────┬──────┴──────┐
    │       │             │
    ▼       ▼             ▼
  Metal   Vulkan        D3D12
  native  native        native
  runtime runtime       runtime
    │       │             │
    ▼       ▼             ▼
  doe_wgsl compiler (shared)
    │       │             │
    ▼       ▼             ▼
  MSL    SPIR-V      DXIL (native)
    │       │             │
    ▼       ▼             ▼
  Metal   Vulkan       D3D12
  driver  driver       driver
    │       │             │
    └───────┼─────────────┘
            ▼
    GPU pipeline object
            │
            ▼
    wgpuComputePassEncoderDispatchWorkgroups(...)
            │
            ▼
          GPU
```

## Corpus routing

The Chromium WebGPU task list routes browser-facing compiler coverage through
the schema-backed WGSL corpus manifest at
[`config/wgsl-browser-corpus.json`](../config/wgsl-browser-corpus.json). The
manifest rows bind source path, normalized source hash, expected validity,
expected backend targets, shader stages, and provenance before they can feed
Doe-vs-Tint evidence. The materializer
[`bench/tools/materialize_wgsl_corpus_manifest.py`](../bench/tools/materialize_wgsl_corpus_manifest.py)
requires repo-relative source paths, validates those hashes, and emits
normalized WGSL files plus a `wgsl_corpus_materialization` receipt. Receipt
verification keeps materialized and minimized candidate files under the supplied
`--verify-files-root` before hashing them.

## TSIR path for spatial backends

The current compiler pipeline in this document is the operative path for Metal,
Vulkan, and D3D12. It is also the frontend path that today's CSL classifier
consumes. The general WGSL -> spatial-backend route adds a Tiled
Spatial IR (TSIR) between Doe IR and backend emission so residency, tiling,
collectives, and exactness are declared in one place instead of re-derived by
per-kernel emitters.

This path is documented in
[`docs/tsir-lowering-plan.md`](./tsir-lowering-plan.md). Phase A compiler
surface (schema, digests, frontend, planner, reference interpreter,
collective-synthesis pass, and five backend emitters whose realization-only
entry points still serialize contract skeletons while their semantic-aware
entry points emit executable bodies for the Phase A bootstrap families)
is landed under `runtime/zig/src/compiler/tsir/`; live status is in
[`docs/status/tsir.md`](./status/tsir.md). TSIR is not yet the wired
executable compiler path for CSL or WebGPU — the live CSL lane still
routes through the classifier/template path and the Doe IR →
MSL/SPIR-V/HLSL WebGPU lanes remain live.

## Comparison with Dawn/Tint

Dawn is Google's WebGPU implementation. Tint is Dawn's shader compiler.
Tint is therefore a first-class Doe target, not incidental background. The
Chromium task list in
[`chromium-webgpu-task-list.md`](./chromium-webgpu-task-list.md) requires
compiler evidence against Tint before any Chromium WebGPU replacement claim can
promote.

| Dimension | Dawn/Tint | Doe |
|-----------|-----------|-----|
| Language | C++ | Zig |
| Compiler size | ~200K LOC (Tint) | ~13.7K LOC |
| IR | Mature SSA with transforms and optimization | Minimal typed IR, no optimization passes |
| Metal target | MSL text (same) | MSL text (same) |
| Vulkan target | Native SPIR-V writer (mature) | Native SPIR-V writer (new, compute-only) |
| D3D12 target | HLSL text → DXC (permanent) | Native DXIL bytecode (primary); HLSL text → DXC (fallback) |
| GLSL | Has a GLSL writer for compat | Not a target |
| Shader stages | Compute + vertex + fragment + full graphics | Compute + vertex + fragment |
| Optimization | Dead code elimination, constant folding, binding remapping, robustness injection | None yet |
| Robustness | Bounds checks, null guards per spec | IR robustness transform for arrays/vectors/matrices, runtime-sized arrays, and texture coordinates; Lean-proven bounds elimination for dispatch-fit patterns |
| Polyfills | Emulates missing features per driver | Explicit unsupported errors |

Structural similarity: both follow WGSL → AST → semantic analysis → typed IR → per-backend emission. Doe is ~15x smaller and does not yet have optimization passes, but does have robustness injection (bounds checks on arrays, runtime-sized arrays, vectors, matrices, and texture coordinates, with Lean-proven bounds elimination for dispatch-fit patterns).

Doe-vs-Tint compiler claims now use an explicit evidence contract:

- report schema:
  [`config/tint-compiler-evidence.schema.json`](../config/tint-compiler-evidence.schema.json)
- gate:
  `python3 bench/gates/tint_compiler_evidence_gate.py --report bench/out/tint-compiler-evidence.json`
- browser-corpus linkage config:
  [`bench/native-compare/compare_doe_vs_tint.browser-corpus.config.json`](../bench/native-compare/compare_doe_vs_tint.browser-corpus.config.json)
- benchmark-corpus SPIR-V config:
  [`bench/native-compare/compare_doe_vs_tint.benchmark-corpus.spirv.config.json`](../bench/native-compare/compare_doe_vs_tint.benchmark-corpus.spirv.config.json)

The gate requires toolchain identity, source and output hashes, validation
status, per-phase timing symmetry, and row-level comparability before a report
can be marked claimable. Diagnostic reports remain useful for compiler bring-up
but cannot support a Doe-over-Tint claim. The browser-corpus config reads
`config/wgsl-browser-corpus.json` directly, so compiler evidence rows carry the
same shader IDs, source paths, expected backend targets, source hashes, and
shader-stage metadata as the WGSL corpus manifest.
The Tint benchmark-corpus loader is target-aware, so MSL and SPIR-V compiler
evidence can use the same Dawn benchmark input list while preserving the
configured backend target in evidence rows.

Compiler result rows also carry `outputPath` next to `outputSha256`. The
target-backend validation checker,
`bench/tools/check_tint_compiler_target_validation.py`, reads a stored
`tint-compiler-evidence` report, requires the requested backend target rows,
checks Doe and Tint validation status/tool identity, verifies safe
repo-relative backend output and receipt paths, and can hash-check the emitted
backend files under `--verify-files-root`. Its receipt schema is
[`config/tint-compiler-target-validation.schema.json`](../config/tint-compiler-target-validation.schema.json).
The blocking-gates runner can invoke the same check through
`--with-tint-compiler-target-validation-gate` plus explicit
`--tint-compiler-target-validation-required-target` values.

Tint benchmark-corpus runs can also collect `phaseBenchmarkTimingsNs` from
Dawn's `tint_benchmark` scopes (`ParseWGSL`, `ValidateIR`, and the selected
backend generator). These values are benchmark-scope diagnostics only; they do
not satisfy the stricter `phaseTimingsNs` claimability contract, which still
requires exact named compiler phases.
Browser WGSL corpus rows use the same warm benchmark path after
`bench/tools/materialize_tint_warm_corpus.py` materializes the selected
`wgslCorpusManifest` row into Dawn's benchmark input list and rebuilds
`tint_benchmark`. The materialization receipt records the source manifest,
benchmark name, Dawn benchmark path, and rebuilt benchmark binary hash.
The diagnostic coverage checker,
`bench/tools/check_tint_phase_benchmark_evidence.py`, verifies that successful
Tint rows for the requested backend target carry those benchmark scopes and
emits a `tint_phase_benchmark_evidence` receipt. Its schema is
[`config/tint-phase-benchmark-evidence.schema.json`](../config/tint-phase-benchmark-evidence.schema.json).
The blocking-gates runner can invoke the same check through
`--with-tint-phase-benchmark-evidence-gate` plus explicit
`--tint-phase-benchmark-required-target` values. This receipt reports missing
exact phases as diagnostic row data, not as a substitute for exact
`phaseTimingsNs`.

The composed compiler frontier checker,
`bench/tools/check_tint_compiler_frontier_bundle.py`, binds the current
compiler evidence reports to their lowering-link, target-validation, and
phase-benchmark receipts. It allows the browser-corpus linkage/validation
receipt and benchmark-corpus phase receipt to remain separate evidence paths
while still producing one `tint_compiler_frontier_bundle` artifact for the
SPIR-V compiler frontier. The bundle passes when component receipts are
gate-clean and reports exact Tint phase gaps as `claimBlockers`; `--require-claimable`
promotes those blockers to hard failures for claim lanes. Its schema is
[`config/tint-compiler-frontier-bundle.schema.json`](../config/tint-compiler-frontier-bundle.schema.json).
The bundle also emits `phaseTimingCoverage`, a row-counted summary of Doe
exact-phase coverage, Tint exact-phase coverage, and Tint benchmark-scope
coverage across every supplied compiler-evidence path. Readiness copies and
validates that summary so the Tint blocker remains measurable instead of only
appearing as repeated claim-blocker strings.

Lowering-link claim bundles are generated from the same compiler evidence with
`bench/tools/build_wgsl_lowering_link_receipt.py`. The receipt binds each
evidence row back to the WGSL corpus manifest, then records the source hash,
Doe IR hash, Doe backend output hash, Tint backend output hash, both validation
statuses, both receipt paths, and the target backend identity. Linked rows are
therefore source-to-IR-to-backend receipts for the Doe side and comparator
artifact receipts for the Tint side.

Execution linkage is a separate contract. The repo-only
`bench/tools/program_execution_identity_receipt.py` composes one Doe shader
manifest with the exact runtime binary, command file, WGSL bytes, trace and
trace metadata, no-fallback backend identity, dispatch count, and independent
output oracle. The self-checking receipt prevents a valid compiler artifact
from being mistaken for evidence that the same artifact participated in a
successful execution. It does not claim driver-binary or operating-system
dependency identity.

## Why custom Zig IR (not SPIR-V as universal IR)

SPIR-V was evaluated as a universal IR: WGSL → SPIR-V → all backends.

Rejected because:

1. **Unnecessary round-trip.** SPIR-V-to-Metal mapping is mechanically sound (SPIRV-Cross and MoltenVK do it daily; the binding model is translatable). But using SPIR-V as IR means Doe would need both a SPIR-V writer (for Vulkan) and a SPIR-V reader (for MSL/DXIL input). An in-memory IR that all backends consume directly avoids both the write and the read for non-Vulkan targets.

2. **Vulkan-specific constructs leak into non-Vulkan backends.** SPIR-V carries Vulkan-specific concepts: interface variables, explicit StorageClass rules, structured merge/continue blocks. MSL and DXIL backends would need to translate through these constructs even though they don't need them. A purpose-built IR carries only what all backends share.

3. **Proof boundary complexity.** Lean verification targets the semantic IR. Proving properties on SPIR-V words requires modeling SPIR-V's type/decoration/storage-class system in Lean. A smaller, purpose-built IR with known invariants is easier to verify.

4. **Practical simplicity.** The custom IR is ~1,028 LOC (ir.zig + ir_builder.zig + ir_validate.zig). A SPIR-V reader of comparable scope would serve only the non-Vulkan backends.

Note: holding SPIR-V in-memory Zig structs without binary serialization was also considered. This carries SPIR-V's data model complexity (StorageClass rules, decoration system, merge blocks) without SPIR-V's tooling benefits (spirv-val requires serialized binary). Worst of both worlds.

## D3D12 backend strategy

### Why the driver eats DXIL, not HLSL

The D3D12 driver does not accept HLSL text. The actual chain is:

```
HLSL text          ← not consumed by driver
    │ (DXC)
    ▼
DXIL container     ← LLVM 3.7 bitcode + metadata + signatures
    │ (D3D12 API)
    ▼
D3D12 driver       ← consumes DXIL, compiles to GPU ISA
```

This is analogous to Metal (driver eats AIR, not MSL) and unlike Vulkan (driver eats SPIR-V directly, no intermediate compiler needed).

### Current architecture: native DXIL (primary), IR → HLSL → DXC (fallback)

The primary D3D12 path now generates DXIL bytecode natively in Zig. The native
emitter translates Doe IR to LLVM 3.7 bitcode via `dxil_builder`, serializes
it via `dxil_serialize`, and wraps it in a DXBC container via
`dxil_container`. No external toolchain is required.

DXC remains available as a fallback path for validation against the reference
compiler. The fallback generates HLSL text from the IR and invokes DXC to
produce DXIL, the same pattern as xcrun metal on macOS.

| Platform | Primary path | External tool needed | Binary format |
|----------|-------------|---------------------|---------------|
| macOS | IR → MSL text → xcrun metal | xcrun metal (on system) | metallib/AIR |
| Windows | IR → DXIL bytecode (native) | None | DXIL |
| Linux | IR → SPIR-V (native) | None | SPIR-V |

For the npm package, no external compiler download is needed on any platform:
- macOS: ~2MB (xcrun metal already on system)
- Linux: ~2MB (native SPIR-V, no external tool)
- Windows: ~2MB (native DXIL, no external tool)

DXC fallback contract (for validation or legacy use):

- explicit pin: `DOE_WGSL_DXC=/absolute/or/workspace-relative/path/to/dxc(.exe)`
- explicit PATH opt-in: `DOE_WGSL_DXC=PATH`
- explicit code path: `doe_wgsl.translateToDxilWithToolchainConfig(..., .{
  .executable = ...,
  .discovery = .explicit_config,
})`
- if `DOE_WGSL_DXC` is unset, the native path is used (no external tool needed)

### Native DXIL emission (implemented)

Native DXIL emission is now the primary D3D12 path. The implementation consists
of 6 modules (2,303 LOC total) that encode LLVM 3.7 bitcode, build DXIL
instructions from the Doe IR, serialize the bitcode, and wrap it in a DXBC
container.

| Pro | Con |
|-----|-----|
| Zero external dependencies | Must independently pass Microsoft's DXIL validator |
| Much faster compilation (skip LLVM optimization) | No optimization — driver must compensate |
| Full auditability for Lean verification | Must track DXIL spec revisions manually |
| Tiny binary | |

Remaining work: broader DXIL validator coverage, vertex/fragment stage
completeness, and production Windows evidence.

**Option B: SPIR-V → Mesa nir_to_dxil.** Mesa's Dozen driver (Microsoft-contributed, ships in WSL2) translates SPIR-V → NIR → DXIL in production. Since Doe already produces SPIR-V, this would cost zero new translation code.

| Pro | Con |
|-----|-----|
| Doe already produces SPIR-V — zero new translation code | Not currently available as a callable library |
| Production-proven (runs in every WSL2 install) | Bundling Mesa requires NIR (~50K LOC C) + nir_to_dxil (~15K LOC C) |
| Battle-tested DXIL output | Tracking Mesa releases for compatibility |

Currently blocked by availability: nir_to_dxil is internal to Mesa's Vulkan ICD with no standalone library packaging. If Microsoft or Mesa ever expose it as a callable library, this becomes the cheapest D3D12 path and should be re-evaluated.

### Paths evaluated and rejected

**IR → SPIR-V → DXC -spirv → DXIL.** Reuses Doe's SPIR-V output, but DXC's SPIR-V ingestion path is less tested than its HLSL path and pulls in SPIRV-Tools as an additional dependency. More fragile than HLSL→DXC with no clear benefit.

**IR → SPIR-V → custom SPIR-V-to-DXIL translator.** Same LLVM bitcode encoding problem as native DXIL, plus requires a SPIR-V reader Doe doesn't have. Strictly more work than native DXIL.

**LLVM IR as shared IR (DXIL falls out naturally).** DXIL is literally LLVM 3.7 IR, so this eliminates D3D12 translation entirely. But LLVM IR is designed for C/C++ optimization, not GPU shader semantics. MSL and SPIR-V backends would translate from the wrong abstraction level. Also defeats "2MB binary" unless Doe maintains an LLVM-compatible format without LLVM.

**Use Tint/Dawn for D3D12 only.** BSD-licensed, mature, handles everything. But adds ~200K LOC C++ for one backend, introduces a second shader compiler with potentially different behavior, and contradicts the self-contained thesis.

**Don't support D3D12.** WebGPU on Windows can run on Vulkan via lavapipe/Dozen. But D3D12 is the performant Windows path. Dropping it loses the Windows gaming/enterprise market.

## Current state

This document describes the compiler architecture, not live coverage totals.
Current compiler/runtime status belongs in
[`docs/status/compiler-and-webgpu.md`](./status/compiler-and-webgpu.md), and
TSIR implementation status belongs in [`docs/status/tsir.md`](./status/tsir.md).
Counts, pass/fail totals, and benchmark results should come from artifacts and
gates, not from prose in this architecture note.

## Related docs

- [`docs/architecture.md`](./architecture.md) — project-level
  architecture (where this doc sits in the broader compiler/runtime
  story)
- [`docs/csl-architecture.md`](./csl-architecture.md) — sibling
  compiler doc covering the Cerebras CSL lane
- [`docs/tsir-lowering-plan.md`](./tsir-lowering-plan.md) for the
  WGSL -> TSIR -> backend lowering architecture and parity-oracle contract
  (Phase A compiler surface landed; live status in
  [`docs/status/tsir.md`](./status/tsir.md))
- [`docs/loop-protocol.md`](./loop-protocol.md) — build-iteration vs
  parity-iteration discipline that drives incremental TSIR + parity
  landing

## Remaining work

Do not maintain a second live backlog in this architecture doc. Track current
compiler gaps in [`docs/status/compiler-and-webgpu.md`](./status/compiler-and-webgpu.md)
or, for TSIR-specific work, [`docs/status/tsir.md`](./status/tsir.md). Keep
this document focused on the stable pipeline shape and backend strategy.

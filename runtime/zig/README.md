# Doe Zig runtime

`runtime/zig/` owns the native runtime, WebGPU ABI, WGSL compiler, backend
implementations, TSIR lowering, and native tools. Public JavaScript behavior is
exposed through `packages/doe-gpu/`; benchmark and claim orchestration remains
under `bench/`.

## Source ownership

- `src/core/`: compute-focused runtime contract
- `src/full/`: full WebGPU additions with one-way dependency on core
- `src/backend/`: Metal, Vulkan, D3D12, and delegate execution
- `src/compiler/wgsl/`: WGSL frontend, transforms, and backend emitters
- `src/compiler/tsir/`: semantic and realization lowering
- `src/runtime/`: shared queues, caches, lifecycle, and execution policy
- `tools/`: source-layout, import, and line-limit checks

Use the nearest source module rather than adding catch-all utilities.

## Build and test

```bash
zig build
zig build test
zig build test-core
zig build test-full
zig build test-wgsl
zig build import-fence
zig build source-layout
zig build line-limits
```

Backend-specific builds and tools are listed by `zig build --help`. Hardware
execution requires the matching host, SDK, driver, and declared backend lane.

## Runtime contract

- Unsupported behavior is typed and explicit.
- Core must not import full-surface modules.
- Runtime-visible selection comes from config or declared call inputs.
- Promoted execution must preserve provider, backend, adapter, driver, command,
  output, and timing identity.
- Cache, timestamp, trace, and receipt failures cannot silently change semantic
  success.
- Synthetic backend state and hidden fallback are forbidden.

## Build tiers

`compute`, `headless`, and `full` tiers expose increasing WebGPU surface area.
Tier selection is a build contract, not evidence that every operation is
supported. Consult [`../../docs/doe-support-matrix.md`](../../docs/doe-support-matrix.md)
and current artifacts before making compatibility claims.

## Compiler and spatial paths

- WGSL architecture:
  [`../../docs/shader-compiler-architecture.md`](../../docs/shader-compiler-architecture.md)
- TSIR plan: [`../../docs/tsir-lowering-plan.md`](../../docs/tsir-lowering-plan.md)
- CSL architecture: [`../../docs/csl-architecture.md`](../../docs/csl-architecture.md)
- Proof elimination:
  [`../../docs/lean-bounds-elimination-design.md`](../../docs/lean-bounds-elimination-design.md)

Detailed tool invocations belong in focused runbooks and `zig build --help`,
not this module entrypoint.

# Doe Zig runtime

`runtime/zig/` owns the native runtime, WebGPU ABI, WGSL compiler, backend
implementations, TSIR lowering, and native tools. Public JavaScript behavior is
exposed through `packages/doe-gpu/`; benchmark and claim orchestration remains
under `bench/`.

## Source ownership

Start with the [generated source map](src/README.md). Its responsibility labels,
build views, and import boundaries come from [source-layout.json](source-layout.json).
The map distinguishes WebGPU object ownership, command execution through the
WebGPU ABI, shared execution services, and module incubation. Historical names
such as `core` and `full` are not evidence of which build ships a module.

Use the nearest owner rather than adding catch-all utilities. The import fence
enforces dependency direction; organization quality still requires reviewing
responsibility splits and actual consumers.

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

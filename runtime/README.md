# Runtime

`runtime/` contains the Doe engine and native bridge surfaces:

- `runtime/zig/`
  - the Zig runtime, compiler, and backend implementation
- `runtime/bridge/`
  - package-facing native bridge code, addon glue, and repo-only runtime
    integration surfaces such as the ONNX Runtime plugin EP scaffold

This directory owns execution. Packaging and helper-only JavaScript surfaces
live under `packages/`.

## Directory Ownership

Treat `runtime/` as several surfaces:

- Authored runtime implementation: `runtime/zig/src/`, `runtime/zig/build.zig`,
  and bridge source under `runtime/bridge/`.
- Runtime tests and examples: `runtime/zig/tests/` and `runtime/zig/examples/`.
  DRY repeated setup and assertions, but preserve behavioral coverage.
- Vendor surface: pinned third-party headers under bridge vendor directories
  are dependency inputs, not authored Doe runtime logic.
- Generated/build output: Zig caches, object files, probe shards, runtime-local
  benchmark output, and ORT smoke artifacts should stay untracked unless they
  are deliberately promoted as durable evidence.

Cleanup rule: authored source should stay explicit where backend semantics
diverge; share helpers only when behavior is already identical.

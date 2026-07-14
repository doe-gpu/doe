---
name: doe-development
description: Implement and validate Doe source-preserving compiler, native runtime, npm package, proof, trace, benchmark, and Chromium/Fawn work. Use for Zig, JavaScript, Python, Lean, config, backend, package, browser, or evidence changes in Doe.
---

# Doe Development

## Load The Contract

Read `AGENTS.md`, `docs/INDEX.md`, `docs/process.md`, and the language style
guide for every surface touched. Read `bench/README.md` before benchmark work.

## Ownership Map

- Ingestion, policy, and trace: `pipeline/agent/`, `pipeline/trace/`
- Proof obligations: `pipeline/lean/`
- Native specialization and backends: `runtime/zig/`
- Public npm contract: `packages/doe-gpu/`
- Benchmarks and claims: `bench/`, `config/`
- Browser evidence: `browser/chromium/`

Keep package, native runtime, browser artifact, and benchmark evidence as
separate surfaces. Preserve source identity through lowering and execution.

## Implement

1. Follow the stage order in `docs/process.md`; do not bypass an earlier gate to
   satisfy a later result.
2. Define the source object, normalized representation, HostPlan or lowering,
   backend execution, and receipt fields affected.
3. Implement latency-sensitive behavior in Zig, then remove runtime conditions
   only when proof artifacts discharge them.
4. Keep thresholds in config and unsupported behavior in the explicit error
   taxonomy.
5. Update schema, migration notes, trace/replay output, and status artifacts
   together when a runtime-visible contract changes.

## Validate

- Native WGSL/runtime: `cd runtime/zig && zig build test-wgsl`
- npm package: `npm --prefix packages/doe-gpu test`
- Promoted benchmark discovery: `python3 bench/cli.py compare --list-promoted`
- Benchmark changes: run the exact promoted or config-backed compare from
  `bench/README.md`
- Browser changes: run the declared Chromium/Fawn smoke and retain its artifact
- Final hygiene: `git diff --check`

Never promote a benchmark from metadata alone. Verify equivalent commands,
dispatches, timing phases, readback path, and non-zero work.

# Doe status

Status front door for Doe. Live topical shards live under
[`docs/status/`](status/). Dated history lives under
[`docs/status/archive/`](status/archive/). Shard policy lives in
[`docs/status/README.md`](status/README.md).

## How to use the status log

- Keep this file concise. It indexes current status; full detail belongs in the
  topical shards and receipt artifacts.
- Put new narrative status in the relevant live shard. Refresh this index only
  when the routing or headline state materially changes.
- Do not duplicate counts, pass/fail totals, benchmark percentages, hashes, or
  lane verdicts here. Link to the artifact or owning shard instead.
- Follow the shard and archive rules in [`docs/status/README.md`](status/README.md).

## Current status summary

| Area | Where current detail lives | Source-of-truth artifacts |
| --- | --- | --- |
| Doppler -> Doe -> Cerebras | [`docs/cerebras.md`](cerebras.md), [`docs/status/cerebras-csl.md`](status/cerebras-csl.md), [`docs/status/cerebras-csl-runtime-bringup.md`](status/cerebras-csl-runtime-bringup.md), model ledgers | `bench/out/r3-cerebras-status/snapshot.{json,md}` |
| TSIR lowering | [`docs/status/tsir.md`](status/tsir.md), [`docs/tsir-lowering-plan.md`](tsir-lowering-plan.md), [`docs/loop-protocol.md`](loop-protocol.md) | `reports/parity/` and manifest `integrityExtensions.lowerings[]` entries |
| Compiler and WebGPU runtime | [`docs/status/compiler-and-webgpu.md`](status/compiler-and-webgpu.md), [`docs/shader-compiler-architecture.md`](shader-compiler-architecture.md) | `zig build test-wgsl`, backend receipts, and schema-registered artifacts |
| Chromium WebGPU task list | [`docs/chromium-webgpu-task-list.md`](chromium-webgpu-task-list.md), [`docs/browser-lane.md`](browser-lane.md), [`browser/chromium/README.md`](../browser/chromium/README.md) | browser-lane milestone manifests, Playwright diagnostics, and browser compare artifacts |
| Runtime backends and benchmark lanes | [`docs/status/runtime-backends-and-bench.md`](status/runtime-backends-and-bench.md), [`docs/performance-strategy.md`](performance-strategy.md), [`docs/benchmark-taxonomy.md`](benchmark-taxonomy.md) | `bench/out/**/{*.json,*.claim.json}` and `browser/chromium/artifacts/**/*.json` |
| Claim and release discipline | [`docs/process.md`](process.md), [`docs/claim-discipline.md`](claim-discipline.md), [`docs/upgrade-policy.md`](upgrade-policy.md) | `config/*.json`, `config/*schema*.json`, and gate outputs |

Per-model Cerebras evidence checklists live at
[`docs/cerebras-model-ledgers.md`](cerebras-model-ledgers.md).
Do not mirror their acceptance bars here.

## Follow-up routing

Future follow-ups should go into the relevant topical shard instead of
expanding this index.

## Live topical shards

- [cerebras-csl.md](status/cerebras-csl.md)
- [cerebras-csl-runtime-bringup.md](status/cerebras-csl-runtime-bringup.md)
- [compiler-and-webgpu.md](status/compiler-and-webgpu.md)
- [tsir.md](status/tsir.md)
- [runtime-backends-and-bench.md](status/runtime-backends-and-bench.md)

## Dated archive shards

- [2026-04-25-late-and-cycles-16-21.md](status/archive/2026-04-25-late-and-cycles-16-21.md)
- [2026-04-25-loop-cycles-7-to-15.md](status/archive/2026-04-25-loop-cycles-7-to-15.md)
- [2026-04-24.md](status/archive/2026-04-24.md)
- [2026-04-24-tsir.md](status/archive/2026-04-24-tsir.md)
- [2026-04-19-to-2026-04-23.md](status/archive/2026-04-19-to-2026-04-23.md)
- [2026-04-16-to-2026-04-18.md](status/archive/2026-04-16-to-2026-04-18.md)
- [2026-04-02-to-2026-04-15.md](status/archive/2026-04-02-to-2026-04-15.md)
- [2026-03-30-to-2026-03-28.md](status/archive/2026-03-30-to-2026-03-28.md)
- [2026-03-27-to-2026-03-24.md](status/archive/2026-03-27-to-2026-03-24.md)
- [2026-03-23-to-2026-03-01.md](status/archive/2026-03-23-to-2026-03-01.md)
- [2026-02-and-legacy.md](status/archive/2026-02-and-legacy.md)

## Historical note

The shard split preserves original top-to-bottom ordering from the former
single-file log. The `2026-02-and-legacy` shard intentionally keeps some older
early-2026 backfilled sections in their original order rather than
reclassifying them retroactively.

# Doe status shard policy

This directory holds live topical status shards and dated archive shards.
`../status.md` is the front door; this file owns the rules for how status
material is organized.

## Ownership

- `../status.md` indexes the current fronts. Keep it concise.
- Live shards under this directory hold narrative status by topic.
- Archive shards under `archive/` hold dated history.
- Artifacts are the source of truth for counts, pass/fail totals, benchmark
  percentages, hashes, and receipt verdicts.

## Live shard rules

- Add new entries at the top of the relevant live shard.
- Split by subdomain before a live shard becomes hard to scan. Date-suffixed
  splits are acceptable when a subdomain cut does not fit cleanly.
- Do not copy current verdict tables into several docs. Link to the owning
  artifact or shard instead.
- Do not embed fresh counts or percentages in prose unless the doc is itself an
  artifact generated from receipts.

## Archive rules

Archive files are preserve-rather-than-frozen:

- keep original ordering and avoid retroactive re-sorting
- allow link fixes, typo fixes, format normalization, and deliberate archive
  splitting
- record substantive corrections as new entries that link back to the original

## Routing

| Topic | Live shard |
| --- | --- |
| Cerebras / CSL lane status | `cerebras-csl.md` |
| Gemma/Qwen CSL runtime bring-up | `cerebras-csl-runtime-bringup.md` |
| Compiler and non-TSIR WebGPU runtime work | `compiler-and-webgpu.md` |
| Continuous integration and workflow policy | `ci.md` |
| TSIR lowering work | `tsir.md` |
| Runtime backends and benchmark lanes | `runtime-backends-and-bench.md` |

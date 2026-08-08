# Doe status

This page routes current state. Artifacts own counts, timings, hashes, and
verdicts. Historical narrative lives under [`status/archive/`](status/archive/).

| Area | Live status | Ground truth |
| --- | --- | --- |
| Runtime and benchmarks | [`status/runtime-backends-and-bench.md`](status/runtime-backends-and-bench.md) | `reports/claim-index.json`, `bench/out/` |
| Compiler and WebGPU | [`status/compiler-and-webgpu.md`](status/compiler-and-webgpu.md) | `zig build test-wgsl`, schema-registered evidence |
| TSIR | [`status/tsir.md`](status/tsir.md) | `reports/parity/`, manifest lowering entries |
| Cerebras and CSL | [`status/cerebras-csl.md`](status/cerebras-csl.md) | `bench/out/r3-cerebras-status/snapshot.{json,md}` |
| CSL runtime bring-up | [`status/cerebras-csl-runtime-bringup.md`](status/cerebras-csl-runtime-bringup.md) | Cerebras snapshot and model ledgers |
| Continuous integration | [`status/ci.md`](status/ci.md) | workflows and CI inventory tests |
| Chromium | [`browser-lane.md`](browser-lane.md) | browser milestone manifest and artifacts |

Do not add dated progress entries here. Update the owning artifact or live
boundary, and preserve resolved narrative in an archive shard.

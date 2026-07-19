# TSIR bootstrap input-tensor fixtures

These are the input-tensor JSON artifacts consumed by the Zig
`doe-tsir-bootstrap-oracle` subprocess that backs `bench/tools/doe_parity.py`.

Shape contract (enforced by `runtime/zig/src/compiler/tsir/tools/tsir_bootstrap_oracle.zig`):

- top-level: `{ "kernel": <name>, "inputs": { <buffer-name>: <buffer>, ... } }`
- buffer: `{ "elem": "f32"|"f16"|"bf16"|"u32"|"u8", "shape": [<u64>, ...], "values": [<num>, ...] }`
  (or `"bytesHex": "<hex>"` in place of `values`)
- kernels recognized: `fused_gemv`, `rms_norm`, `gather`

Fixture | Buffers | Output shape
--- | --- | ---
`fused_gemv.json` | `W` (4x3 f32), `x` (3 f32) | `y` (4 f32)
`rms_norm.json`   | `input` (4 f32), `weight` (4 f32), `u` (2 f32; `u[1]` is epsilon at byte offset 4) | `output` (4 f32)
`gather.json`     | `indices` (2 u32), `table` (3x4 f32) | `output` (2x4 f32)

Paired with the manifest-entry fixtures in `../tsir-manifest-entries/` by
kernel name. The parity canary (`bench/gates/nightly_tsir_parity_canary.py`)
passes the input fixture via `--inputs` and the manifest entry via
`--manifest-lowering-entry`.

Additional manifest-shape probe fixtures in this directory are consumed by
`bench/runners/csl-runners/manifest_kernel_probe_runner.py` through
`../tsir-real-doppler-transcripts/`. Those fixtures are dispatch-plumbing
inputs only; they are not bootstrap oracle kernels and do not make numerical
Doppler parity claims.

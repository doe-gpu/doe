# Live simulation editing checkpoint

Component: doe-gpu examples and package qualification
Intent: preserved; additive application over existing compute-program state and execution contracts
Acceptance evidence: logs here and the retained package summary linked below
Boundary effects: application orchestration remains outside Zig; no new public package export

The Node terminal example owns candidate preflight, iteration-boundary activation, parameter changes, and explicit reset decisions. The GPU worker owns its device and resident program. A separate candidate process runs frozen independent heat-reference cases while the active simulation advances. Every active frame is also checked against that reference. Candidate authors supply WGSL; the reference and tolerance policy are shipped separately from the editable shader. Activation still prepares a replacement on the original device and reports the resulting pause.

## Reproduction

From the repository root:

```sh
node packages/doe-gpu/test/integration/test-integration-live-simulation.js
DOE_LIVE_EXECUTION=webgpu node packages/doe-gpu/test/integration/test-integration-live-simulation.js
DOE_LIVE_EXECUTION=native-recorded node packages/doe-gpu/test/integration/test-integration-live-simulation.js
node packages/doe-gpu/examples/live-simulation.js --write-shader heat.wgsl
node packages/doe-gpu/examples/live-simulation.js --backend vulkan --execution gpu-recorded
```

The terminal accepts `edit heat.wgsl`, `rate 0.1`, `format new-format`, `approve id`, `decline id`, `cancel`, `save path.wgsl`, `status`, and `quit`. The source files and policy hashes are in `SHA256SUMS` (verify from the repository root). `source.patch` binds changes after rendering checkpoint `2a3b8aa6e`. `archive-verification.log` records reconstruction of every matrix-referenced file hash; `verify-archive.py` reproduces that check.

`bench/out/compute-program/20260906-live-simulation-qualified/summary.json` binds the exact wrapper/platform archives and fresh Node, Bun, and Electron main-process installs. The live application regression runs on Node only; the other hosts qualify provider, reflection, prepared-program, rendering, and lifecycle behavior. The native binary is unchanged from the rendering checkpoint.

## Application comparisons

`comparison-policy.json` preserves the existing image and heat oracles and sampling configuration while enabling observed-DRM-activity rejection. The completed comparison is retained in `application-comparison.tar.xz`. Extract from the repository root with:

```sh
tar -xf bench/out/compute-program/20260906-live-simulation-correction/application-comparison.tar.xz
```

The archive preserves run reports, outputs, independent expected bytes, provider binaries, addon, source snapshot, native journals, hardware inventory, and activity observations. The installed package tree is also retained because the matrix references its bytes. Identical files are stored once using archive hard links; every original artifact path and content digest is preserved. Inspect `bench/out/compute-program/20260906-live-simulation-applications/summary.json` for each raw p50/p95/p99 sign, preparation recovery, CPU result, and diagnostic caveat. The Deno/wgpu gaps are explicitly suspicious. Their receipts place most elapsed time in submit/completion; this observation does not establish a native wgpu execution-speed advantage. A host-wait audit and a stronger wgpu control remain necessary.

Reproduce with:

```sh
python3 bench/cli.py program evaluate --backend vulkan --output bench/out/compute-program/live-simulation-reproduction --node /usr/bin/node --deno /tmp/doe-deno-2.9.6 --package-qualification bench/out/compute-program/20260906-live-simulation-qualified/summary.json --policy bench/out/compute-program/20260906-live-simulation-correction/comparison-policy.json
```

## Limits

Cancellation terminates candidate processes or waits for bounded active operations; it cannot preempt arbitrary GPU kernels. Heap limits constrain JavaScript heap, and RSS denotes host process memory. This checkpoint does not establish prolonged memory stability, physical driver-loss recovery, general agent acceleration, composition gains, native asynchronous pipeline creation, physical Metal or D3D12 application qualification, or performance leadership. The recorded heat comparison still needs its tail behavior improved before a release speed claim.

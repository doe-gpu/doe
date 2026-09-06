# Vulkan color-load correction

`baseline.txt` identifies the source before this correction. `before.log`
retains the failed native-addon image regression, and `source.patch` binds the
implementation and test delta. The test records adjacent draws, performs an
empty pass requesting color load, releases caller references, and checks the
submitted pixels. It exercises direct commands and render-bundle replay.

Vulkan native recording now publishes the initial color-load choice once per
attachment recording and loads previous color for subsequent draws. Actual
recording state is distinct from the API draw counter. The backend uses its
existing texture-layout source mapping for render-pass synchronization. This
changes the implementation of existing WebGPU behavior; it adds no public
fields or runtime toggles.

`native-run.log`, `native.jsonl`, retained SPIR-V, and
`native-validation.json` identify the physical draw execution and completion.
The exact package and controlled-host results are in
`../20260906-render-load-qualified/summary.json`. `release-fast.log` and
`debug.log` retain the canonical runtime/compiler test results. Current counts
and verdicts belong to those artifacts.

Reproduce from the repository root:

```bash
cd runtime/zig
zig build test test-wgsl dropin dropin-compute dropin-full -Doptimize=ReleaseFast --summary all
zig build test test-wgsl --summary all
cd ../../packages/doe-gpu-linux-x64
node ../doe-gpu/scripts/stage-platform-package.js
cd ../..
node packages/doe-gpu/test/integration/test-integration-native-render-ownership.js
python3 bench/cli.py program verify-native \
  --trace bench/out/compute-program/20260906-render-load/native.jsonl \
  --require-render-completion \
  --out /tmp/doe-render-load-native-validation.json
```

The loaded library is rebuilt from this source and staged before execution.
Retained package qualification independently installs its archives into clean
controlled-host projects. Local package installation is not npm publication;
Electron evidence covers its main process.

This is color preservation on existing attachments, not complete render-pass
conformance or a performance comparison. Depth/stencil attachment identity,
store/discard initialization, resolves, render queries, physical Metal/D3D12,
and real driver-loss recovery remain outside this checkpoint. Older evidence
retains its original scope and hashes.

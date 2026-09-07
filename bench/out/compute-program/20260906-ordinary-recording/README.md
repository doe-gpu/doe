# Owned ordinary recording and deferred texture copies

`baseline.txt` identifies the source before this correction. `source.patch`
binds native recording state, resource references, queue rejection, Vulkan copy
ordering, regressions, architecture reviews, and acceptance documentation.
`SHA256SUMS` binds this checkpoint's retained files.

Ordinary encoder, bundle, and query allocation failures previously could abort
while recorded resources remained owned. Recording now keeps its original
failure, reports it through the existing device error scopes, and rejects
further mutation. Finish transfers an error object when allocation permits;
queue submission validates the entire command-buffer list before backend work.
Prepared compute also rejects an error command buffer. Encoders, passes,
command buffers, and bundles release storage through their owning allocator.
Public signatures, descriptor fields, configuration, and receipt schemas are
unchanged. The migration is from process abort or usable partial recording to
explicit existing WebGPU allocation/validation failure categories.

Allocator-fault tests exercise actual native recording adapters across compute,
render, copy, query, and bundle work, including later growth after earlier
references were retained. They check abandoned recording, finish failure,
error-object publication, rejected replay/submission, and subsequent valid
recording. `debug.log` and `release-fast.log` retain canonical test results;
all native build tiers are included in the optimized build.

Vulkan buffer-to-texture copy previously called texture upload while recording.
It now reads the retained GPU source buffer at its recorded submission position.
Pure layout tests check the last accessed byte, strides, mip-relative extents,
array layers, volume depth, and compressed-block geometry. Combined depth/stencil
copy aspects remain explicitly unsupported by this copy path.

The C fixture `runtime/zig/tests/native_recorded_compute.c` checks the fused
constructors and the ordinary dispatch/texture-copy/readback sequence. It
initializes a texture, records and abandons a copy, and verifies that the texture
remains unchanged. It then records GPU compute, buffer-to-texture copy, and
readback, releases caller references, submits, and compares independent integer
results. `baseline-native-run.log` retains the abandoned-copy failure against
the preceding checkpoint's packaged native library; `native-run.log` retains
the corrected physical AMD Vulkan result from the same fixture executable.
The baseline library is extracted from the platform archive in
`../20260906-recorded-allocation-qualified/`; its identity is in
`baseline-library.sha256`.

`native.jsonl`, retained SPIR-V, and `native-validation.json` bind compute
execution and completion. The journal validator does not prove pixel correctness;
the C fixture's readback assertions do. `loaded-libraries.log` and
`native-library.sha256` bind the loaded corrected library. Its hash equals every
host library hash in `../20260906-ordinary-recording-qualified/summary.json`.
The archives there retain the actual Node/Bun/Electron package bytes. Electron
qualification covers the main process. The package's ordinary command helper
and the fused C entrypoints remain distinct tested paths.

Reproduce from the repository root:

```bash
cd runtime/zig
zig build test test-wgsl dropin dropin-compute dropin-full -Doptimize=ReleaseFast --summary all
zig build test test-wgsl --summary all
cd ../..
mkdir -p bench/out/compute-program/ordinary-qualification-tmp
TMPDIR="$PWD/bench/out/compute-program/ordinary-qualification-tmp" \
cc -std=c11 -Wall -Wextra -Werror runtime/zig/tests/native_recorded_compute.c \
  -I runtime/zig/vendor/webgpu-headers -L runtime/zig/zig-out/lib \
  -Wl,-rpath,"$PWD/runtime/zig/zig-out/lib" -lwebgpu_doe \
  -o bench/out/compute-program/ordinary-qualification-tmp/native-recorded-compute
timeout 30 bench/out/compute-program/ordinary-qualification-tmp/native-recorded-compute
cd packages/doe-gpu-linux-x64
node ../doe-gpu/scripts/stage-platform-package.js
cd ../..
TMPDIR="$PWD/bench/out/compute-program/ordinary-qualification-tmp" \
python3 bench/cli.py program qualify-package \
  --output bench/out/compute-program/ordinary-recording-reproduction \
  --node /usr/bin/node --bun /home/x/.bun/bin/bun \
  --electron /home/x/deco/doe/bench/out/toolchains/electron-43.4.0/node_modules/electron/dist/electron \
  --platform-package doe-gpu-linux-x64 --lifecycle-cycles 3 --timeout-ms 120000
python3 bench/cli.py program verify-native \
  --trace bench/out/compute-program/20260906-ordinary-recording/native.jsonl \
  --out bench/out/compute-program/ordinary-qualification-tmp/native-validation.json
```

The retained run used `depth-qualification-tmp` as disk-backed installation and
compiler scratch space. `tmp-quota-before-execution.log` records an initial
failed attempt before a fixture executable existed. The
`fixture-undefined-dimension-*` files preserve a preliminary fixture that omitted
the required C texture dimension; those are fixture failures before the copy
assertion, not runtime acceptance evidence. The final fixture declares it.

This checkpoint does not establish full render-pass state validation, texture
copy conformance, concurrent queues, physical Metal/D3D12, driver-loss recovery,
peak GPU memory, package publication, or application performance leadership.
Earlier artifacts retain their original boundaries and hashes.

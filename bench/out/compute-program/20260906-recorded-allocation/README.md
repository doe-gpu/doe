# Transactional native compute recording

`baseline.txt` identifies the source before this correction. `source.patch`
binds the typed builder, native adapters, allocator ownership, tests, and
documentation. Fused compute constructors previously acquired dependencies and
then panicked if recording storage could not grow. The builder reserves command
and reference storage before acquisition, retains completed private state,
unwinds failed construction, and transfers ownership only on success.
Command buffers carry their owning allocator through final cleanup.

The existing C entrypoints retain their signatures and nullable failure result.
Their device error scopes now receive the original allocation or validation
cause. No public descriptor fields, production toggles, or trace schemas change.
The allocator-fault regressions cover object allocation, later list growth,
aliased copy buffers, abandoned construction, publication, and cleanup. The
native C boundary regression checks failed-copy diagnostics. Canonical test
results belong to `debug.log` and `release-fast.log`.

`native-recorded-compute` is built from
`runtime/zig/tests/native_recorded_compute.c` using the pinned WebGPU header.
It calls the single and batched native constructors directly, rejects failed
construction, releases caller-owned shader/pipeline/binding/buffer references,
submits retained work, and compares readback against independent integer
results. The physical AMD Vulkan results are in `native-run.log`.
`native.jsonl`, retained SPIR-V, and `native-validation.json` bind dispatch
execution and completion. Adapter description is not a driver-version field.

`loaded-libraries.log` records dynamic linkage; `native-library.sha256` matches
the library hash in every host row of
`../20260906-recorded-allocation-qualified/summary.json`. The archives there
retain the actual package bytes. The addon's similarly named convenience
function encodes ordinary WebGPU commands; it is a separate execution path.
Retained Node/Bun/Electron qualification therefore checks shared command-buffer
cleanup and existing package behavior, while the C fixture checks the fused
native entrypoints. Electron qualification covers its main process.

Reproduce from the repository root:

```bash
cd runtime/zig
zig build test test-wgsl dropin dropin-compute dropin-full -Doptimize=ReleaseFast --summary all
zig build test test-wgsl --summary all
cd ../..
cc -std=c11 -Wall -Wextra -Werror runtime/zig/tests/native_recorded_compute.c \
  -I runtime/zig/vendor/webgpu-headers -L runtime/zig/zig-out/lib \
  -Wl,-rpath,"$PWD/runtime/zig/zig-out/lib" -lwebgpu_doe \
  -o /tmp/doe-native-recorded-compute
timeout 30 /tmp/doe-native-recorded-compute
cd packages/doe-gpu-linux-x64
node ../doe-gpu/scripts/stage-platform-package.js
cd ../..
mkdir -p bench/out/compute-program/recorded-qualification-tmp
TMPDIR="$PWD/bench/out/compute-program/recorded-qualification-tmp" \
python3 bench/cli.py program qualify-package \
  --output bench/out/compute-program/recorded-allocation-reproduction \
  --node /usr/bin/node --bun /home/x/.bun/bin/bun \
  --electron /home/x/deco/doe/bench/out/toolchains/electron-43.4.0/node_modules/electron/dist/electron \
  --platform-package doe-gpu-linux-x64 --lifecycle-cycles 3 --timeout-ms 120000
python3 bench/cli.py program verify-native \
  --trace bench/out/compute-program/20260906-recorded-allocation/native.jsonl \
  --out /tmp/doe-recorded-native-validation.json
```

The retained qualification used the already-created disk-backed scratch
directory `bench/out/compute-program/depth-qualification-tmp` as `TMPDIR`.
This affects installation scratch storage only. `qualification.log`,
`stage.log`, `schema.log`, and `docs.log` retain the corresponding results.

This checkpoint does not repair ordinary encoder, render-bundle, or query
recording allocation failures. It does not establish physical Metal/D3D12,
driver-loss recovery, peak GPU memory, WebGPU conformance, publication, or a
performance advantage. Earlier evidence retains its original scope and hashes.

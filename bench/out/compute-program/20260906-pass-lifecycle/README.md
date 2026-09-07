# Active pass ownership

`baseline.txt` and `source.patch` bind the source correction and its acceptance
contract. `SHA256SUMS` binds the retained checkpoint files. The command encoder
owns a tagged recording state containing its active pass identity. Pass end
unlocks the encoder. Caller reference release does not imply end, and an older
ended pass cannot mutate a later pass sharing that encoder. Recording failures
remain terminal and preserve the existing error-object submission rejection.

Canonical regressions check nested passes, encoder copies and command timestamps
inside a pass, finish before end, repeated end, stale pass mutation, abandoned
pass references, and retained-resource cleanup. Pure render fixtures declare
their active pass explicitly. They do not bypass the ownership check. Native
debug and immediate-data entrypoints check lifetime before reading pass state.
`debug.log` and `release-fast.log` retain the canonical results and optimized
native build tiers. Existing WebGPU signatures, descriptors, configuration,
trace fields, and receipts are unchanged. Previously accepted invalid pass
sequences now report through the existing validation error scope and cannot
produce executable partial command buffers.

`runtime/zig/tests/native_recorded_compute.c` crosses the actual WebGPU C ABI.
It checks rejection at recording and submission for invalid pass lifetimes,
then executes fused compute and ordinary dispatch/texture-copy/readback on the
same physical device. Caller shader, pipeline, binding, buffer, texture, and
encoder references are released at the appropriate boundaries. The numerical
result is checked independently in the C fixture.

`baseline-native-run.log` retains the failing open-pass assertion against the
preceding checkpoint's packaged library, extracted from the platform archive
in `../20260906-ordinary-recording-qualified/` and bound by
`baseline-library.sha256`. `native-run.log` retains the corrected physical AMD
Vulkan run of the same fixture executable. `native.jsonl`, retained SPIR-V, and
`native-validation.json` bind recorded compute execution and completion; the
validator does not replace the C output assertions.

`native-library.sha256` and `loaded-libraries.log` identify the corrected loaded
library. Its hash matches every host row in
`../20260906-pass-lifecycle-qualified/summary.json`; the package archives there
retain the exact Node/Bun/Electron installation inputs. Electron qualification
covers the main process. `qualification.log` and `stage.log` retain the package
commands' outcomes. `wrong-build-directory.log` preserves an initial command
invocation from the wrong directory before testing; canonical execution uses
`runtime/zig` as its working directory.

Reproduce from the repository root:

```bash
cd runtime/zig
zig build test test-wgsl dropin dropin-compute dropin-full -Doptimize=ReleaseFast --summary all
zig build test test-wgsl --summary all
cd ../..
mkdir -p bench/out/compute-program/pass-qualification-tmp
TMPDIR="$PWD/bench/out/compute-program/pass-qualification-tmp" \
cc -std=c11 -Wall -Wextra -Werror runtime/zig/tests/native_recorded_compute.c \
  -I runtime/zig/vendor/webgpu-headers -L runtime/zig/zig-out/lib \
  -Wl,-rpath,"$PWD/runtime/zig/zig-out/lib" -lwebgpu_doe \
  -o bench/out/compute-program/pass-qualification-tmp/native-recorded-compute
timeout 30 bench/out/compute-program/pass-qualification-tmp/native-recorded-compute
cd packages/doe-gpu-linux-x64
node ../doe-gpu/scripts/stage-platform-package.js
cd ../..
TMPDIR="$PWD/bench/out/compute-program/pass-qualification-tmp" \
python3 bench/cli.py program qualify-package \
  --output bench/out/compute-program/pass-lifecycle-reproduction \
  --node /usr/bin/node --bun /home/x/.bun/bin/bun \
  --electron /home/x/deco/doe/bench/out/toolchains/electron-43.4.0/node_modules/electron/dist/electron \
  --platform-package doe-gpu-linux-x64 --lifecycle-cycles 3 --timeout-ms 120000
python3 bench/cli.py program verify-native \
  --trace bench/out/compute-program/20260906-pass-lifecycle/native.jsonl \
  --out bench/out/compute-program/pass-qualification-tmp/native-validation.json
```

The retained run used `depth-qualification-tmp` for disk-backed scratch space.
This checkpoint does not establish complete debug-group/query validation,
immediate-data execution, general render conformance, physical Metal/D3D12,
concurrent queue safety, driver-loss recovery, peak GPU memory, publication,
or an application performance advantage. Prior checkpoints remain historical
evidence with their own source identities and qualification boundaries.

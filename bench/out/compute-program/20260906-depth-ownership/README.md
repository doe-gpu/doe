# Vulkan depth attachment ownership

`baseline.txt` identifies the source before this correction. `before.log`
retains the failing near/far image regression, and `source.patch` binds the
implementation and test delta. The backend previously created an unrelated
depth target for each draw. It now borrows the caller's retained texture and
view, verifies their allocation identity, and carries load and clear values
through owned command snapshots. Image layout updates use the shared resource
owner so registered aliases receive the updated layout.

The native-addon test checks occlusion through multiple draws, later load
passes, read-only depth testing, and an empty depth clear. It copies the actual
depth texture to CPU memory as well as checking color, and releases caller
references before submission. Completed command buffers retain the required
objects independently. Temporary backend targets retain separate cleanup.

`native-run.log` records the physical regression. `native.jsonl`, the retained
SPIR-V, and `native-validation.json` identify completed non-indexed depth draws.
This journal does not cover every indexed draw or clear; image/depth readback
checks remain the correctness evidence. Exact package bytes and fresh Node,
Bun, and Electron main-process regressions are retained in
`../20260906-depth-ownership-qualified-disk/summary.json`. All hosts use the same
library hash. These are local package installations, not registry publication.

The original qualification attempt failed while npm installed archives on the
temporary filesystem, before GPU execution. Its unchanged report is
`../20260906-depth-ownership-qualified/summary.json`, with the quota error in
`node-install.stderr`. The successful rerun used disk-backed scratch storage via
the standard `TMPDIR` environment variable; runtime behavior was unchanged.
Both attempts and their logs are retained rather than replacing the failure.

Reproduce from the repository root:

```bash
cd runtime/zig
zig build test test-wgsl dropin dropin-compute dropin-full -Doptimize=ReleaseFast --summary all
zig build test test-wgsl --summary all
cd ../../packages/doe-gpu-linux-x64
node ../doe-gpu/scripts/stage-platform-package.js
cd ../..
node packages/doe-gpu/test/integration/test-integration-native-render-ownership.js
mkdir -p bench/out/compute-program/depth-qualification-tmp
TMPDIR="$PWD/bench/out/compute-program/depth-qualification-tmp" \
python3 bench/cli.py program qualify-package \
  --output bench/out/compute-program/depth-ownership-reproduction \
  --node /usr/bin/node --bun /home/x/.bun/bin/bun \
  --electron /home/x/deco/doe/bench/out/toolchains/electron-43.4.0/node_modules/electron/dist/electron \
  --platform-package doe-gpu-linux-x64 --lifecycle-cycles 3 --timeout-ms 120000
python3 bench/cli.py program verify-native \
  --trace bench/out/compute-program/20260906-depth-ownership/native.jsonl \
  --require-render-completion --out /tmp/doe-depth-native-validation.json
```

`release-fast.log`, `debug.log`, `schema.log`, and `docs.log` retain verification
results. Test counts and package identities belong to those artifacts. Existing
WebGPU descriptor fields flow through internal commands; this change adds no
public fields, trace fields, or production toggles.

This checkpoint covers the tested AMD Vulkan attachment path. Stencil
operations, depth-only passes, store/discard initialization, multisampling and
resolves, arbitrary view ranges, read-only sampling feedback, render queries,
physical Metal/D3D12, and real driver-loss recovery remain outside this
acceptance evidence. It makes no performance or complete conformance claim.

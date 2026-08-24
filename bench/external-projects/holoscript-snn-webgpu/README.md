# HoloScript SNN WebGPU harness

This harness runs the pinned HoloScript tropical-SpMV workload through an
unchanged CPU oracle, explicit WebGPU providers, and receipt-bound comparison
lanes. The governing component charter is
[`../CATSCAN.md`](../CATSCAN.md); the application oracle is
[`oracle.md`](oracle.md).

## Electron main-process P0

[`electron-main-process.plan.json`](electron-main-process.plan.json) freezes
the Electron 43.4.0 `I0`/`I1`/`W0`/`D0`/`A0`/`P0` contract. The source-built
incumbent control uses `node-webgpu` tag `v0.3.10`, commit
`c7c792ba7facd9e831a52d8e2a0c1dd166654751`, Dawn commit
`c5d549e250b9225744929ae860b369cb4304a767`, and the exact two-file patch in
[`electron-node-webgpu-p0.patch`](electron-node-webgpu-p0.patch).

Materialize the source, initialize its Dawn and depot-tools submodules, apply
the patch in `third_party/dawn`, and build with the Go archive and hash frozen
in the plan:

```bash
git clone https://github.com/dawn-gpu/node-webgpu.git "$DOE_P0_ROOT"
git -C "$DOE_P0_ROOT" checkout --detach c7c792ba7facd9e831a52d8e2a0c1dd166654751
git -C "$DOE_P0_ROOT" submodule update --init third_party/dawn third_party/depot_tools
git -C "$DOE_P0_ROOT/third_party/dawn" apply \
  "$DOE_ROOT/bench/external-projects/holoscript-snn-webgpu/electron-node-webgpu-p0.patch"
npm --prefix "$DOE_P0_ROOT" ci --ignore-scripts
PATH="$DOE_PINNED_GO/bin:$PATH" npm --prefix "$DOE_P0_ROOT" run build
```

Run the adjudication with explicit paths:

```bash
DOE_ELECTRON_EXECUTABLE="$DOE_ELECTRON_EXECUTABLE" \
DOE_HOLOSCRIPT_ELECTRON_P0_SOURCE_ROOT="$DOE_P0_ROOT" \
DOE_HOLOSCRIPT_ELECTRON_P0_GO_EXECUTABLE="$DOE_PINNED_GO/bin/go" \
node bench/external-projects/holoscript-snn-webgpu/run-electron-main-process.mjs \
  reports/benchmarks/amd-vulkan/<run-id>/holoscript-electron-main-process-p0-diagnostic.json
```

The reviewed result keeps HoloScript diagnostic. Doe and P0 both reproduce the
unchanged application exactly, so the bounded incumbent patch closes the gap
and DoeRuntime receives no ownership credit for this tuple.

## LIF determinism

[`lif-determinism.harness.json`](lif-determinism.harness.json) freezes the
upstream CPU membrane tolerance, exact spike-mask oracle, three input cases,
and the `I0`/`I1`/`W0`/`D0` comparison. Run it with:

```bash
node bench/external-projects/holoscript-snn-webgpu/run-lif-determinism-matrix.mjs \
  reports/benchmarks/amd-vulkan/<run-id>/holoscript-lif-determinism-diagnostic.json
```

The reviewed AMD Vulkan result passes all three clean processes in every lane,
passes semantic replay for `W0` and `D0`, and produces identical final GPU
membrane and spike bytes across Dawn and Doe for every frozen case. Because the
governed incumbent needs no correction and matches Doe's application outcome,
this closes the runtime-ownership hypothesis for the declared tuple. The
workload remains a correctness and determinism regression with no promotion,
performance, ownership, or release credit.

The other plans in this directory cover the public DoeProof loader, CLI,
declared-file boundary, and Linux workspace-sealing surfaces. None grants
application adoption, performance, renderer, Chromium, browser, or release
credit.

The reviewed
[`public process-observer admission`](../../../reports/ecosystem/holoscript-snn-webgpu/holoscript-doeproof-process-observer-amd-vulkan-2026-08-16-diagnostic.json)
binds the immutable tropical-SpMV oracle to the package observer's public
command and mapped-readback evidence. It grants no runtime-ownership,
performance, promotion, or release credit.

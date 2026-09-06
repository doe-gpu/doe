# Explicit shader failures, owned diagnostics, and state updates

Component: native shader creation, compiler diagnostics, device caches, and compute programs
Intent: preserved for shader/compiler failures and ownership; changed through descriptor version 3 for strict state updates
Acceptance evidence: retained commands and logs in this directory; package and numerical-audit paths below
Boundary effects: native C reflection failure sentinel, addon/FFI error propagation, and package state-update schema

`baseline.txt` identifies the starting revision. The source patch records the working changes independently of intermediate workspace commits. Compiler diagnostics own their message, source context, and stage; per-thread compatibility snapshots remain at legacy boundaries. Reflection publishes metadata only after success. Zero bindings remain a valid result. Native metadata queries return `SIZE_MAX` for failure; addon and FFI consumers reject this before consuming entries.

Shaders retain their device. Metal library caches own exact-source/configuration entries on each logical device; shader leases have independent library references. Metal archives are device-owned, with per-archive compilation locking and a non-owning registry for the legacy flush boundary. Adapters own underlying Metal devices. CPU cache reference tests do not establish physical Metal behavior. The visible Mac refused SSH connections during this task; no Windows host was identified.

Descriptor version 3 declares resident state formats. `assessUpdate()` identifies retained, replaced, discarded, and created state. Reset approval is tied to the exact descriptor, old program instance, and invocation revision. Failed or declined edits retain old state. Versions 1 and 2 keep their original update behavior. This does not yet establish background activation or a live simulation application.

## Verification

From `runtime/zig`:

```sh
zig build test test-wgsl dropin dropin-compute dropin-full -Doptimize=ReleaseFast --summary all
zig build test test-wgsl --summary all
```

The corresponding results are `owned-devices-releasefast.log` and `owned-devices-debug.log`. These include reflection allocation failures, concurrent diagnostics, cache leases and rollback, shader device ownership, and independent-device validation. Library construction and allocation tests are distinct from physical GPU qualification.

Package qualification uses fresh projects and the same retained tarballs in Node, Bun, and Electron main processes:

- Initial compiler/native corrections: `bench/out/compute-program/20260906-shader-ownership-qualified/summary.json`.
- State approval and independent devices: `bench/out/compute-program/20260906-state-update-qualified/summary.json`.
- Addon reflection failure handling: `bench/out/compute-program/20260906-explicit-failures-qualified/summary.json` (consult its status).

The initial exact-package image, heat, and continuous simulation numerical checks and native SPIR-V verification are under `bench/out/compute-program/20260906-shader-ownership-audits/`. `run-audits.py` preserves their command recipe. These runs retain independent original oracles and are correctness evidence, not incumbent speed comparisons.

## Build edit measurements

`build-measurements-v3.json` retains clean, no-change, and actual source-edit builds, including the configured fragments, before/after hashes, per-build resource use, and artifact size. `capture_build_measurements.py` is the exact tool revision bound by that receipt. Edits happened only in a private snapshot, with restoration between scenarios. The current tool fixes profile hash capture at input-read time; the retained receipt binds the earlier tool and its unchanged profile. `wait4` RSS is the maximum process memory in the build tree, not a simultaneous aggregate.

## Rendering and final package checkpoint

`render-releasefast.log` and `render-debug.log` include allocation-failure coverage for transactional render shader copies, atomic native leases, translation-cache payload cleanup, and the shared vertex-format ABI. Vulkan records draw snapshots for queue submission. Metal pipeline publication preserves prepared vertex layouts and the retained pipeline layout.

`bench/out/compute-program/20260906-render-ownership-qualified/summary.json` binds the retained package, native library, addon, GPU, driver, and fixtures across Node, Bun, and Electron main processes. Its native rendering test releases caller references before submission and checks pixels after a post-recording vertex write, through direct commands and render bundles. It also retains reflection, state-update, and lifecycle regressions. `render-application-audits.log` records renewed image, heat, and continuous simulation correctness checks against that package; `run-render-audits.py` is the command recipe.

The final application audit files are retained in `render-application-audits.tar.gz`. Extract from the repository root with `tar -xzf bench/out/shader-ownership/20260906-owned-diagnostics/render-application-audits.tar.gz`. The archive excludes only the disposable installed-package directory; the original package inputs, provider binaries, fixtures, independent expected/output bytes, native journals, and verification reports remain present. Package installation can be reproduced from the retained tarballs.

A development probe initially read a JavaScript shadow buffer after submitting through raw addon handles; the accepted test maps and copies the native buffer directly. The resulting actual GPU clear-only image exposed stale vertex-format conversion values. Correcting those values produced the accepted draw. Development probes are not performance evidence.

This checkpoint does not establish complete render-pass semantics (including load/store and resolve across multiple draws), render query coverage, explicit resource destruction behavior for every object, arbitrary concurrent queue safety, physical Metal/D3D12 qualification, driver-loss recovery, the live-edit application, bounded candidate development, composition gains, or performance leadership.

# Doe runtime zero-dispatch bug

**Status:** fixed for the minimum repro; Gemma 3 C-lane still has a
logits correctness blocker.
**Lane:** bug follow-up from Track 1 (Doe WebGPU execution trace).
**Does not block:** browser→CSL parity receipt (Track 2 + Track 3 are
the critical path to the north-star receipt; Track 1 is a portability
lane).

## Minimum repro

`bench/repros/doe-runtime-zero-dispatch/repro.mjs`

A 3-line WGSL compute kernel that writes `u32(42)` to index 0 of a
storage buffer:

```wgsl
@group(0) @binding(0) var<storage, read_write> out: array<u32>;
@compute @workgroup_size(1) fn main() { out[0] = 42u; }
```

Through `doe-gpu`'s compute facade in Node, every intermediate call
succeeds without error (createShaderModule, createComputePipeline,
createBuffer, createBindGroup, dispatchWorkgroups, queue.submit,
copyBufferToBuffer, mapAsync). The original failure read back `0`
instead of `42`.

Run:
```
node bench/repros/doe-runtime-zero-dispatch/repro.mjs
```

Exit 0 when the bug is fixed.

## Fixed in this lane

- `packages/doe-gpu/src/vendor/webgpu/compute.js:wrapAdapter` now
  exposes `info` by delegating to the raw Doe Adapter. Previously
  Doppler's `src/config/platforms/loader.js:102` threw
  `Cannot read properties of undefined (reading 'vendor')` and the
  error was swallowed by Doppler's try/catch. Fix was necessary but
  not sufficient by itself.
- Vulkan command-buffer submit replay now executes recorded compute
  dispatches and replays `copyBufferToBuffer` in command order, so
  the minimum repro readback observes the shader write.
- Vulkan `queue.writeBuffer` resolves the live compute-buffer entry
  before upload. This avoids stale host pointers after storage buffers
  are promoted to device-local memory.
- Vulkan copy replay falls back to a real `vkCmdCopyBuffer` + wait
  when either source or destination is device-local instead of silently
  skipping copies that lack CPU mappings.

## Current evidence

`env HOME=/tmp node bench/repros/doe-runtime-zero-dispatch/repro.mjs`
now prints:

```text
dispatched u32: 42 (expect 42)
```

The Gemma 3 1B Doe WebGPU lane gets past the prior Vulkan crash with
`DOE_DISABLE_SUBGROUPS=0`, advertises `hasF16=true` and
`hasSubgroups=true`, and reaches Doppler pipeline execution. It still
does not produce a promotion-ready C-lane receipt: the exporter exits
with `[Sampling] Logits has no finite candidate logits after masking
the pad token`. The follow-up first-zero diagnostic classifies the
current tensor as non-finite logits and records the tensor hash and
finite/non-finite counts. That is now a model/kernel correctness issue,
not the minimum queue-submit no-op.

## Remaining candidate surfaces

Ordered by likelihood of root cause:

1. **First zero-producing Gemma kernel** — identify which Doppler
   dispatch first leaves logits/KV state invalid or non-finite despite
   the simple 42u dispatch working.
2. **Device-local output readback coverage** — copy replay now uses
   `vkCmdCopyBuffer` for unmapped buffers, but the logits diagnostic
   shows the next failure is still upstream of the final
   readback or in the producing kernel.
3. **Subgroup/f16 kernel semantics** — the adapter now honestly reports
   subgroup and f16 support; any remaining invalid output needs a
   kernel-level first-divergence probe instead of a capability
   suppression workaround.

## What the fix unblocks

The minimum native Doe WebGPU queue path is no longer a silent no-op,
so Gemma 3 C-lane debugging can move to first-divergence tracing of
the production kernels and output buffers. This remains a portability
path; browser→CSL parity still depends on the CSL/simfabric path.

## Related signals (separate issues, not fixes yet)

- `device.adapterInfo` may still need an explicit compute-facade
  getter, analogous to the existing `adapter.info` fix.
- The remaining Gemma 3 C-lane failure should be tracked by a
  first-zero kernel receipt rather than by this minimum repro.

## Handoff artifacts

- Repro: `bench/repros/doe-runtime-zero-dispatch/repro.mjs`
- Prior stderr evidence: `/tmp/ws-c-gate-postfix1-transcript.json`
  (post-adapter.info-fix Gemma 3 1B transcript showing `[1]` +
  zero KV / zero logits)
- Track 1 diagnostic shard entry:
  `docs/status/compiler-and-webgpu.md` (2026-04-24 entry at top)

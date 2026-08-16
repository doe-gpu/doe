# Reviewed oracle

This harness uses HoloScript's pinned `@holoscript/core/math/tropical-spmv`
implementation as the upstream oracle. For every topology and every measured
GPU result, it executes `tropicalMinPlusSpmv` over the identical CSR graph and
source vector, then requires `maxAbsDiff < 0.001`.

The graph builders and seeded traversal order are unchanged from
`packages/snn-webgpu/src/__tests__/tropical-spmv-gpu.benchmark.test.ts` at
commit `337a39a869a552c814933c587fe65b34a0a2c95d`.

Review boundary: this oracle establishes numeric equivalence for tropical
SpMV. It does not establish physical-hardware execution; adapter and host
driver evidence enforce that separately.

The reviewed
[`public process-observer admission`](../../../reports/ecosystem/holoscript-snn-webgpu/holoscript-doeproof-process-observer-amd-vulkan-2026-08-16-diagnostic.json)
binds this unchanged oracle to the package observer's public command and mapped
readback evidence. It grants no runtime-ownership, performance, promotion, or
release credit.

# HoloScript LIF determinism oracle

The pinned upstream oracle is
`packages/snn-webgpu/src/paper/__tests__/LIFTwinTest.test.ts` at HoloScript
commit `337a39a869a552c814933c587fe65b34a0a2c95d`.

For each frozen case, the harness uses the unchanged exported
`CPUReferenceSimulator`, `generateSynapticInput`, `LIFSimulator`, default or
declared LIF parameters, and production `lif_step` WGSL shader. It accepts a
case only when:

- maximum membrane absolute difference is below `5e-5`;
- maximum membrane relative difference is below `1e-4`;
- every final spike decision matches exactly.

The separate canonical determinism probe must produce one membrane hash across
three independent simulators. Seed `43` and tick count `10` must each differ
from the canonical seed-`42`, 100-tick hash so a stable no-op cannot pass.

Provider identity, physical adapter evidence, shader identity, dispatch count,
synchronization, and both readbacks are required. Same-provider repetition on
one AMD adapter is not cross-vendor byte-identity evidence. CPU membrane
tolerance and exact spike parity are separate from raw GPU membrane hashes.

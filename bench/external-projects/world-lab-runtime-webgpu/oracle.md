# world-lab runtime-webgpu execution oracle

The reviewed admission oracle is the pinned upstream test workload at commit
`4ef19794501d565586a73b991ea569834c54afad`:

- `src/consumers/vegetationCandidates.test.ts` compares GPU candidate records
  with an independent CPU implementation, including exact discrete fields,
  `1e-5` numeric tolerances, the zero-candidate plateau case, and overflow;
- `src/consumers/fullscreenFragment.test.ts` executes generated vertex and
  fragment shaders, reads RGBA8 pixels, and compares the first pixel with an
  independent cosine-palette calculation within two byte values;
- `test/consumerDeviceCompile.test.ts` device-compiles six representative
  consumer shaders and requires a deliberately invalid regression shader to
  produce at least one error-severity compilation message.

The external Vitest config aliases only the existing `webgpu` package import.
All upstream TypeScript, graph fixtures, generated WGSL, CPU reference logic,
tolerances, render/compute commands, synchronization, readback, and negative
validation cases remain unchanged. `REQUIRE_WEBGPU=1` prohibits silent skips.

The workload passes only when all 16 upstream assertions pass with zero failed
or pending tests. Compile success alone is not sufficient: the vegetation and
fullscreen execution assertions must also pass.

The runtime-ownership successor preserves that oracle and adds a transparent
provider around the pinned Dawn and Doe modules. It records dynamically
assembled WGSL attempts, concrete compute and render work, queue submissions,
and exact mapped readback digests without editing upstream application or
shader source. Three clean processes in each I0, I1, W0, and D0 lane pass. W0
and D0 reproduce the same normalized shape, semantic-evidence, and exact output
identities, so the governed incumbent closes the frozen outcome and the result
grants no DoeRuntime ownership credit. The reviewed report is
[`../../../reports/ecosystem/world-lab-runtime-webgpu/world-lab-runtime-ownership-amd-vulkan-2026-08-16-diagnostic.json`](../../../reports/ecosystem/world-lab-runtime-webgpu/world-lab-runtime-ownership-amd-vulkan-2026-08-16-diagnostic.json).

The package-observer successor replaces the frozen application-specific proxy
with the public `doe-gpu/observe` contract. Its corrected `qm1` population
persists snapshots at mapped-readback checkpoints because Vitest workers do
not guarantee module-exit hooks. Pinned Dawn and Doe each pass the unchanged
16-assertion oracle with identical normalized command and mapped-output
identities. The reviewed diagnostic is
[`../../../reports/ecosystem/world-lab-runtime-webgpu/world-lab-package-observer-admission-amd-vulkan-2026-08-16-diagnostic.json`](../../../reports/ecosystem/world-lab-runtime-webgpu/world-lab-package-observer-admission-amd-vulkan-2026-08-16-diagnostic.json).
It grants public observer admission only and cannot reopen the ownership result.

The compilation-observer successor adds immediate compilation-info checkpoints
and captures the compile-only Vitest worker that the earlier mapped-readback
checkpoint could not preserve. Pinned Dawn and Doe each record 13 attempted
shaders and all eight compilation-info calls. Each exposes exactly one
error-bearing result bound to the same LF-normalized invalid runtime shader
hash, while retaining its provider-specific diagnostic wording. The reviewed
diagnostic is
[`../../../reports/ecosystem/world-lab-runtime-webgpu/world-lab-package-compilation-observer-amd-vulkan-2026-08-16-diagnostic.json`](../../../reports/ecosystem/world-lab-runtime-webgpu/world-lab-package-compilation-observer-amd-vulkan-2026-08-16-diagnostic.json).
It proves source-bound public diagnostics only and grants no ownership,
performance, promotion, or release credit.

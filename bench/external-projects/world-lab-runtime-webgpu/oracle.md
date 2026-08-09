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

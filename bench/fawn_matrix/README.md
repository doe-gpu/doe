# Fawn-Doe Four-Lane Matrix

This benchmark executes `context_snapshot_diff` through four independent lanes:

| Lane | Browser | Transport | WebGPU runtime |
| --- | --- | --- | --- |
| A | stock Chromium | Playwright | Dawn |
| B | Fawn | Playwright | Dawn |
| C | Fawn | Playwright | Doe |
| D | Fawn | raw CDP direct diff | Doe |

The timed operation is context capture and serialization. WebGPU adapter probing is
untimed and proves runtime selection only; this workload cannot award DoeRuntime a
performance claim.

Run one physical platform from the repository root:

```sh
python3 -m bench.fawn_matrix.cli run --platform-id apple-metal
python3 -m bench.fawn_matrix.cli run --platform-id amd-vulkan
```

The runner discovers the stock Chromium, Fawn, Playwright, and Doe library paths,
or accepts explicit overrides through `--stock-browser`, `--fawn-browser`,
`--playwright-root`, and `--doe-library`.

Each platform run emits raw samples, payload artifacts, hashes, runtime proof,
hardware identity, semantic-equivalence results, and a platform report beneath
`bench/out/fawn-matrix/<platform-id>/`.

Aggregate only independently produced Apple Metal and AMD Vulkan reports:

```sh
python3 -m bench.fawn_matrix.cli aggregate \
  --report bench/out/fawn-matrix/apple-metal/<run>/report.json \
  --report bench/out/fawn-matrix/amd-vulkan/<run>/report.json
```

Aggregation fails closed when a required platform is absent, hardware identities
are not distinct, a lane fell back, evidence is simulated, samples are not
interleaved, payload hashes disagree with artifacts, or the semantic oracle fails.
Aggregate output still requires independent review before publication.


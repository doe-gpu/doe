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
  --platform-report bench/out/fawn-matrix/apple-metal/<run>/context_snapshot_diff.platform-report.json \
  --platform-report bench/out/fawn-matrix/amd-vulkan/<run>/context_snapshot_diff.platform-report.json \
  --out bench/out/fawn-matrix/context_snapshot_diff.aggregate-report.json
```

Aggregation fails closed when a required platform is absent, hardware identities
are not distinct, a lane fell back, evidence is simulated, samples are not
interleaved, payload hashes disagree with artifacts, or the semantic oracle fails.
Aggregate output still requires independent review before publication.

## GPU, agent, and passport workloads

Run the remaining live workloads on a physical platform:

```sh
python3 -m bench.fawn_matrix.live_cli run --workload webgpu_model_preprocessing --platform-id apple-metal
python3 -m bench.fawn_matrix.live_cli run --workload multi_step_agent_interaction --platform-id apple-metal
```

`webgpu_model_preprocessing` times shader compilation, asynchronous pipeline
creation, upload, dispatch, synchronization, readback, and complete operation
latency. Its primary comparison is Lane C versus Lane B, so it can award or deny
DoeRuntime performance status independently of the Fawn shell.

`multi_step_agent_interaction` executes cold and warm deterministic agent sessions
through inspect, incremental diff, GPU preprocessing, action selection, dispatch,
and final task verification. Its primary comparison is Lane D versus Lane A.

The `suite`, `aggregate`, and `passport` commands then join the three workload
reports, require Apple Metal plus AMD Vulkan on distinct physical hardware, emit a
promotion receipt, and reject unsigned or unearned release claims. Windows D3D12 is
tracked as the desktop promotion tier and cannot be inferred from another backend.

GPU input size and dispatch repetition are governed by `live-workloads.json`; both
values are recorded and checked in every sample. Promotion receipts use Ed25519
SSHSIG signatures through `ssh-keygen -Y sign`, embed the public key, and are
cryptographically reverified by the release-passport gate. The signing environment
variable contains a private-key path, never private-key contents committed to Git.

`python3 -m pipeline.agent.fawn_matrix_learning_bridge` converts failed samples into a
deterministic hash-chained DoeLab learning manifest. A signed platform suite becomes
a promotion event only after its receipt verifies. The physical-runner workflow
executes the same three workloads on explicitly labeled self-hosted hardware and
uploads raw evidence without widening its claim scope.

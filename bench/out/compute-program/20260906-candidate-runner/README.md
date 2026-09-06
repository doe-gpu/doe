# Bounded candidate execution checkpoint

This checkpoint exercises the repository candidate runner against the exact
packages in `../20260906-candidate-qualified/summary.json` on the locally
identified AMD Vulkan device. It is diagnostic CPU-reference evidence, not a
Dawn/wgpu comparison, third-party adoption, or production promotion.

Extract from the repository root:

```bash
tar -xf bench/out/compute-program/20260906-candidate-runner/candidate-evidence.tar.xz
python3 bench/out/compute-program/20260906-candidate-runner/verify-archive.py
```

`archive-verification.log` records verification of every archived summary's
artifact references. Identical files use archive hard links while retaining all
original paths and hashes. Disposable `installed-package/` directories are
excluded; exact npm inputs, install logs, loaded provider/addon binaries, source
snapshots, native journals, SPIR-V, raw numerical outputs, and reports remain.

| Retained summary | Purpose |
| --- | --- |
| `single/summary.json` | Single-query useful-operation acceptance, including copying and hashing |
| `batched-gpu/summary.json` | Distinct batched-search job through recorded GPU commands |
| `batched-repeat/summary.json` | Fresh execution with the same recorded environment |
| `batched-webgpu/summary.json` | Changed execution configuration and ordinary encoding |
| `batched-native/summary.json` | Changed execution configuration and native command replay |
| `invalid/summary.json` | Compiler failure and completed cleanup |
| `wrong/summary.json` | Compiling candidate rejected by the original numerical oracle |

Each directory contains `execution.json` with raw samples, numerical acceptance,
process preparation, device initialization, repeated latency, CPU time, sampled
RSS, and teardown. Its first phase is the first invocation of that case; the
prepared program survives across cases. The candidate's native journal remains
enabled during timing. Preparation recovery includes process preparation and
first-invocation differences. Parent RPC cost is reported separately from the
worker invocation metric. The frozen job defines the acceptance threshold.

The jobs have different work and must retain separate conclusions. Physical
outputs do not establish kernel preemption, driver-loss recovery, peak GPU
memory, OS isolation, or hardware portability. Environment-change examples
change execution mode; the driver-byte identity test is a host-logic test, not
a physical driver upgrade. Unfamiliar research routines still require their own
independent acceptance jobs and measurements.

Reproduction starts with `bench/fixtures/program-candidate/prepare.py` followed
by `prepare-batched.py`. Keep the printed acceptance hashes fixed during
candidate edits. `reproduce.py` records exact invocations; use new output paths
when rerunning, because existing evidence is never overwritten. Each run also
retains its executed command. Invalid and wrong candidate bytes are available
in the corresponding directory's `candidate.wgsl`.

Validation logs retain the package contract suite, schema gate, candidate and
schema-routing regressions, documentation links, and artifact-tampering probes.
The tampering probes modify disposable copies of physical evidence and reject
omitted cases, changed summaries, skipped work, and forged output identities.
SHA256SUMS binds checkpoint files and the compressed evidence.

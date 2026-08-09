# External project harnesses

This directory contains checked-in, reviewable provider substitutions for
upstream projects listed in `config/ecosystem-registry.json`. Each actor owns a
directory named with its registry ID. Ready harness manifests end in
`.harness.json` and validate against
`config/external-project-harness.schema.json`.

A harness must pin the upstream repository, commit, and license; describe the
smallest provider seam and patch set; require hardware execution; reject CPU,
mock, software-renderer, and unknown-provider fallback; and bind immutable
inputs to a reviewed output oracle. Dawn and Doe must execute the same command,
dispatch, synchronization, and readback shape.

Required evidence includes clean-process success, crashes, hangs, timeouts,
peak memory, cold and warm p50/p95/p99 latency, adapter and driver identity,
provider identity, shader hashes, dispatch shape, synchronization, readback,
output identity, and receipt overhead. Timing from failed correctness,
provider-identity, fallback, or structural-equivalence checks remains
diagnostic.

Each manifest also declares the production installation status, physical
support targets, concurrency, teardown, stress, memory-growth, performance,
receipt replay, and release policies. These declarations are obligations, not
results. Reviewed results live in ecosystem reports and carry a separate
promotion assessment. The governed minimums are in
`config/external-project-promotion-policy.json`.

When an upstream workload finds a Doe defect, add a schema-backed record under
`<actor-id>/failures/` that binds the failing evidence to the minimized repro,
implementation fix, and regression test. Do not mark a failure protected until
all referenced source paths exist and the fixed harness passes.

Generated clones and run evidence do not belong here. Write them to
`bench/out/external-projects/<actor-id>/<run-id>/`, then promote only reviewed,
schema-backed summaries to `reports/ecosystem/<actor-id>/`.

`bench/gates/external_project_release_gate.py` rejects incoherent promotion.
`bench/runners/run_external_project_release_suite.py` executes every promoted
harness as a blocking release dependency.

Physical AMD Vulkan continuation is documented in
[`AMD_VULKAN_HANDOFF.md`](AMD_VULKAN_HANDOFF.md). It keeps host admission,
external-workload evidence, native smoke evidence, and promotion review as
separate boundaries.

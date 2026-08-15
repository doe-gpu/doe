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

A promotion candidate must also predeclare `runtimeOwnershipPlan`. The plan
freezes the claimed DoeRuntime property, incumbent limitation, application
consequence, material outcome, ownership costs, and the `I0`, `I1`, `W0`,
`D0`, and conditional `P0` constructions from
[`docs/runtime-ownership-decision.md`](../../docs/runtime-ownership-decision.md).
Reviewed reports record the terminal ownership assessment. Diagnostic runs may
leave it `not-run`, but the release gate rejects promotion without passing,
evidence-linked lane, material-outcome, and cost-acceptance decisions.

## Portable preparation and reproduction

The canonical machine-independent entrypoint is:

```bash
python3 bench/cli.py external reproduce \
  --actor <actor-id> \
  --harness <harness-id> \
  --run-id <stable-run-id>
```

Inspect the exact command plan without changing the checkout or downloading
dependencies with the same command plus `--dry-run`. Use `external prepare`
when the operator needs only the pinned source, host/tool identity, dependency
installation, Doe build, and preparation receipt. `--offline` forbids a clone
or fetch and requires the pinned commit to exist in the local upstream clone.

Harness schema version 4 declares installation as an ordered list of named,
shell-free steps. Every step owns its working-directory scope and timeout so a
pinned monorepo can install and build its workspace before installing an
isolated application fixture. The CLI schema-validates these fields and does
not infer legacy defaults.

The orchestration is manifest-driven. It bootstraps declared tools, captures
tool versions, verifies physical hardware, clones or reuses the registry URL,
checks out the exact registry commit, rejects local source changes, executes
the manifest-declared installation steps in order, builds Doe, hashes required runtime
and provider artifacts, runs policy gates, executes the workload command, and
hashes every declared evidence file. Commands are argument arrays rather than
shell strings, and each process has a declared working directory and timeout.

Each run writes:

- `preparation.json`, binding source, contracts, tools, host, hardware,
  support-target eligibility, process logs, and Doe/provider artifacts;
- `reproduction.json`, binding the verified preparation receipt, gates,
  workload process, and output evidence; and
- complete stdout and stderr logs below `logs/preparation/` and
  `logs/reproduction/`.

The preparation receipt is reloaded and content-hash verified before gates or
workload execution. A physical hardware probe does not by itself make a run
claim-eligible: the host must match a manifest support target whose status is
promoted. Reproduction can emit only a claimable candidate; a reviewed
ecosystem report and the normal release and claim gates own promotion.

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
